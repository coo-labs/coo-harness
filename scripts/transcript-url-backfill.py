#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
# migration-sweep: skip — this script handles the org-rename URL backfill; its mapping table and regexes intentionally carry vade-app/* and coo-labs/* literals.
"""
transcript-url-backfill.py — coo-labs/coo-console#23 (post-comment algorithm).

One-shot patcher that backfills `session_url` into R2
`rendered/<sid>.meta.json` sidecars for the slice of historical
sessions that produced a per-session auto-meta-PR in coo-logs.

Algorithm (per the 2026-05-30 comment on coo-console#23):

  1. Load coo-labs/coo-logs/index/session_artifacts.json — the
     nightly reverse index from session URLs to authored artifacts.
  2. Walk it once; for every coo-logs PR whose title matches
     `meta: auto-commit sidecar for <UUID>`, build the map
     sid -> session_url.
  3. List R2 `<key-prefix>/*.meta.json` sidecars; for each missing
     `session_url`, look the sid up in the map; on hit, fetch,
     patch in place, PUT back.
  4. Optional (`--rerender`): also re-run the renderer for each hit
     with `CLAUDE_CODE_SESSION_ID` + `CLAUDE_CODE_REMOTE_SESSION_ID`
     env injected so the renderer's path-1 env-recovery fires. This
     uploads a fresh HTML body whose template includes the
     `Open in Claude Code` link. Best-effort: sids whose ciphertext
     is no longer in the R2 archive log a FAIL and the sidecar
     patch still stands.
  5. Optional (`--scan-transcript`): for sidecars the title-fast-path
     missed, decrypt the ciphertext and scan the jsonl for in-transcript
     signals: (a) literal `claude.ai/code/session_<id>` URLs echoed
     into tool_results, and (b) coo-labs PR/issue references
     reverse-looked-up in `session_artifacts.json`. Accepts a URL
     when pattern A fires OR pattern B votes unanimously / by strong
     mode (≥ 2× rest). Empirically catches a small additional slice
     of cohort B+C — sessions that opened coo-labs artifacts but
     didn't produce a per-session auto-meta-PR.

Coverage caveat: only sids landed by per-session auto-meta-PRs are
in scope for the default path. The remaining missing-session_url
population splits into (a) sessions exported but never auto-PR'd
(cohort B; bulk PRs or auto-PR-step failures); (b) ciphertext-only
sessions rendered by `transcript-render-backfill.py` (cohort C;
predate the export pipeline). `--scan-transcript` recovers the
fraction of cohort B+C that referenced their own coo-labs artifacts
inside the conversation. Cohort C/B sids that opened no coo-labs
artifacts stay unrecoverable here — route to coo-labs/coo-console#22
(resume-and-recover) for per-session URL re-derivation when needed.

Usage:
  transcript-url-backfill.py [--limit N] [--dry-run] [--include-populated]
                             [--rerender] [--scan-transcript]
                             [--key-prefix rendered]

Env:
  R2_TRANSCRIPTS_ACCESS_KEY_ID      — R2 access key
  R2_TRANSCRIPTS_SECRET_ACCESS_KEY  — R2 secret key
Read at run time via `op`:
  op://COO/r2-transcripts/endpoint
  op://COO/r2-transcripts/bucket
Reads `coo-labs/coo-logs` contents via `gh api` (PAT-routed by
gh-coo-wrap.sh; no env-token prefix).

Exit 0 on success (including --dry-run); 1 on arg/env error; 2 if
any per-sidecar patch failed. Per-sidecar failures log to stderr
and continue — fail-soft.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Optional

SCRIPT_DIR = Path(__file__).resolve().parent
FETCH_SH = SCRIPT_DIR / "lib" / "transcript-fetch.sh"
RENDER_PY = SCRIPT_DIR / "lifecycle" / "session-end-transcript-render.py"
SESSION_URL_PREFIX = "https://claude.ai/code/session_"

# Locate coo-harness/lib/ on sys.path so `from transcripts import ...` resolves
# under the uv-run venv this script spawns into. See lib/transcripts/README.md
# §"Importing" for the parents[N] table; this script lives at scripts/<top>.py
# so parents[1] is the repo root.
sys.path.insert(0, str(SCRIPT_DIR.parent / "lib"))

from transcripts import (  # noqa: E402
    AUTHORITATIVE_URL_SOURCES,
    RECONCILE_ELIGIBLE_URL_SOURCES,
    VALID_URL_SOURCES,
    R2Error,
    dominant_scan_source,
    list_keys,
    r2_client,
    r2_coordinates,
)

SESSION_ID_RE = re.compile(
    r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$"
)
RENDERED_KEY_RE = re.compile(r"/([a-f0-9-]{36})\.meta\.json$")
AUTO_META_PR_TITLE_RE = re.compile(
    r"meta:\s*auto-commit\s+sidecar\s+for\s+"
    r"([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})",
    re.IGNORECASE,
)
TRANSCRIPT_SESSION_URL_RE = re.compile(
    r"https://claude\.ai/code/session_(01[A-Za-z0-9]{18,40})"
)
TRANSCRIPT_PR_URL_RE = re.compile(
    r"https://github\.com/((?:coo-labs|vade-app)/[\w.-]+)/(?:pull|issues)/(\d+)"
)
TRANSCRIPT_PR_AUTOLINK_RE = re.compile(
    r"\b((?:coo-labs|vade-app)/[\w.-]+)#(\d+)\b"
)
TOOL_RESULT_EXACT_PR_URL_RE = re.compile(
    r"^https://github\.com/((?:coo-labs|vade-app)/[\w.-]+)/(?:pull|issues)/(\d+)/?$"
)
# vade-app/* repos were renamed under coo-labs/* during the 2026-05 org cutover.
# Normalize before reverse-lookup in session_artifacts.json (built against
# current coo-labs/* names). Identity for already-coo-labs/* keys.
REPO_RENAME = {
    "vade-app/vade-agent-logs": "coo-labs/coo-logs",
    "vade-app/vade-runtime": "coo-labs/coo-harness",
    "vade-app/vade-coo-memory": "coo-labs/coo-memory",
    "vade-app/vade-canvas": "coo-labs/vade-canvas",
    "vade-app/site": "coo-labs/site",
    "vade-app/coo4one": "coo-labs/coo4one",
    "vade-app/tjsonl": "coo-labs/tjsonl",
    "vade-app/skills": "coo-labs/skills",
    "vade-app/vade-governance": "coo-labs/vade-governance",
}

# url_source taxonomy lives in lib/transcripts/provenance.py and is imported
# above (AUTHORITATIVE_URL_SOURCES, RECONCILE_ELIGIBLE_URL_SOURCES,
# VALID_URL_SOURCES, dominant_scan_source). _patch_one enforces the
# AUTHORITATIVE preservation rule. Any new mass-mutation script must respect
# the same boundary; see briefing 039 *Constraints* §"Never automatically
# clear a session_url whose url_source is …".


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[transcript-url-backfill] {msg}\n")


def _load_session_artifacts_index() -> dict:
    try:
        out = subprocess.run(
            ["gh", "api",
             "repos/coo-labs/coo-logs/contents/index/session_artifacts.json",
             "-H", "Accept: application/vnd.github.raw"],
            check=True, capture_output=True, text=True, timeout=30,
        )
    except subprocess.CalledProcessError as e:
        raise RuntimeError(
            f"gh api failed: rc={e.returncode} stderr={e.stderr.strip()[:200]}"
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("gh api timed out after 30s")
    return json.loads(out.stdout)


def _build_sid_to_url_map(index: dict) -> dict[str, str]:
    out: dict[str, str] = {}
    for session in index.get("sessions", []):
        url = (session.get("session_url") or "").strip()
        if not url:
            continue
        for art in session.get("artifacts", []):
            if art.get("type") != "pr" or art.get("repo") != "coo-labs/coo-logs":
                continue
            hit = AUTO_META_PR_TITLE_RE.search(art.get("title", ""))
            if not hit:
                continue
            sid = hit.group(1).lower()
            existing = out.get(sid)
            if existing and existing != url:
                _stderr(
                    f"conflict for {sid}: existing={existing} new={url} — keeping first"
                )
                continue
            out[sid] = url
    return out


def _list_candidate_sidecars(
    s3, bucket: str, key_prefix: str, include_populated: bool
) -> list[tuple[str, str]]:
    """Return [(sid, r2_key), ...] for sidecars eligible for patching."""
    cands: list[tuple[str, str]] = []
    for obj in list_keys(f"{key_prefix}/", s3=s3):
        key = obj["key"]
        m = RENDERED_KEY_RE.search(key)
        if not m or not SESSION_ID_RE.match(m.group(1)):
            continue
        sid = m.group(1)
        try:
            body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
            meta = json.loads(body)
        except Exception as e:
            _stderr(f"  skip {sid}: failed to read sidecar: {e}")
            continue
        if meta.get("session_url") and not include_populated:
            continue
        cands.append((sid, key))
    return cands


def _build_pr_to_url_map(index: dict) -> dict[tuple[str, str], tuple[str, str]]:
    """Map (repo, str(number)) -> (session_url, artifact_type) for every
    PR/issue authored by a session in the reverse index. artifact_type is
    'pr' or 'issue' — used to weight votes during scan-transcript resolution
    (PRs are stronger authorship signals than issues, which sessions
    frequently reference without having opened). First-write-wins on
    multi-author collisions (rare)."""
    out: dict[tuple[str, str], tuple[str, str]] = {}
    for s in index.get("sessions", []):
        url = (s.get("session_url") or "").strip()
        if not url:
            continue
        for a in s.get("artifacts", []):
            atype = a.get("type")
            if atype not in ("pr", "issue"):
                continue
            key = (a.get("repo"), str(a.get("number")))
            if key not in out:
                out[key] = (url, atype)
    return out


def _build_session_last_seen(index: dict) -> dict[str, _dt.datetime]:
    """Map session_url -> last_seen_at datetime (UTC). Used to prune
    vote candidates whose active window predates the transcript — sessions
    that boot a fresh container and observe-only still reference PRs from
    the boot digest, which would otherwise vote for long-completed sessions
    and skew the mode."""
    out: dict[str, _dt.datetime] = {}
    for s in index.get("sessions", []):
        url = (s.get("session_url") or "").strip()
        last = (s.get("last_seen_at") or "").strip()
        if not url or not last:
            continue
        try:
            out[url] = _dt.datetime.fromisoformat(last.replace("Z", "+00:00"))
        except ValueError:
            continue
    return out


def _yield_text(entry: dict, root_type: str):
    msg = entry.get("message") or {}
    content = msg.get("content")
    if isinstance(content, str):
        yield content
    elif isinstance(content, list):
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "text":
                yield block.get("text", "") or ""
            elif btype == "tool_use":
                inp = block.get("input")
                if isinstance(inp, dict):
                    yield from _flatten_strings(inp)
            elif btype == "tool_result":
                tc = block.get("content")
                if isinstance(tc, str):
                    yield tc
                elif isinstance(tc, list):
                    for sub in tc:
                        if isinstance(sub, dict) and sub.get("type") == "text":
                            yield sub.get("text", "") or ""
            elif btype == "thinking":
                yield block.get("thinking", "") or ""
    tur = entry.get("toolUseResult")
    if isinstance(tur, (dict, list)):
        yield from _flatten_strings(tur)
    elif isinstance(tur, str):
        yield tur


def _flatten_strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from _flatten_strings(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _flatten_strings(v)


def _normalize_repo(repo: str) -> str:
    return REPO_RENAME.get(repo, repo)


SCAN_WEIGHTS = {
    "pr_link": 10,
    "tool_result_exact": 10,
    "pattern_a": 5,
    "prose_pr": 3,
    "prose_issue": 1,
}


def _yield_tool_result_exact_prs(entry: dict):
    """Yield (repo, number) for tool_result blocks whose content is
    exactly a single coo-labs/vade-app PR/issue URL — the shape `gh pr
    create` etc. emits. Direct authorship signal: this session ran the
    create call. Also checks top-level toolUseResult.stdout for the same
    shape."""
    msg = entry.get("message") or {}
    content = msg.get("content")
    if isinstance(content, list):
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_result":
                continue
            tc = block.get("content")
            if isinstance(tc, str):
                m = TOOL_RESULT_EXACT_PR_URL_RE.match(tc.strip())
                if m:
                    yield m.group(1), m.group(2)
            elif isinstance(tc, list):
                for sub in tc:
                    if isinstance(sub, dict) and sub.get("type") == "text":
                        m = TOOL_RESULT_EXACT_PR_URL_RE.match(
                            (sub.get("text", "") or "").strip()
                        )
                        if m:
                            yield m.group(1), m.group(2)
    tur = entry.get("toolUseResult")
    if isinstance(tur, dict):
        stdout = tur.get("stdout")
        if isinstance(stdout, str):
            m = TOOL_RESULT_EXACT_PR_URL_RE.match(stdout.strip())
            if m:
                yield m.group(1), m.group(2)


def _scan_jsonl_for_url(
    jsonl_path: Path,
    pr_map: dict[tuple[str, str], tuple[str, str]],
    session_last_seen: dict[str, _dt.datetime] | None = None,
    prune_window_hours: int = 24,
) -> tuple[Optional[str], str]:
    """Scan a decrypted jsonl. Returns (session_url, detail, dominant_source).

    `dominant_source` is the canonical scan-* tag of the winning signal
    class (priority: pr-link > tool_result_exact > pattern_a > prose); it
    is None on every failure return. See AUTHORITATIVE_URL_SOURCES /
    RECONCILE_ELIGIBLE_URL_SOURCES at the top of this file.

    Single weighted vote across four signals, summed per candidate
    session_url:
      pr-link entries (top-level jsonl objects of type='pr-link'
        emitted by gh-coo-wrap's PostToolUse hook for PRs this session
        opened) — direct authorship, weight 10 each.
      Pattern A: literal claude.ai/code/session_<id> URLs with strict
        01-prefix — weight 5 each.
      Pattern B: prose PR refs (coo-labs/* and vade-app/* normalized)
        looked up in pr_map; PRs weight 3 each (sessions open few PRs
        and they strongly indicate authorship), issues weight 1 each
        (sessions reference many issues they didn't open).

    After scoring, prune candidates whose `last_seen_at` predates the
    transcript's first timestamp by more than `prune_window_hours`. This
    drops false candidates that arise when an observe-only session
    references PRs surfaced by the boot digest (those PRs were authored
    by long-completed sessions). pr_link and pattern_a contributions
    bypass the prune since they are direct-authorship markers.

    Accept if the top remaining candidate has >= 2x the second-place
    votes (unanimous when there's no second place). Reject as conflict
    otherwise.
    """
    pr_link_prs: set[tuple[str, str]] = set()
    tool_result_exact_prs: set[tuple[str, str]] = set()
    a_votes: Counter = Counter()
    prose_prs: set[tuple[str, str]] = set()
    first_ts: _dt.datetime | None = None
    try:
        f = open(jsonl_path)
    except OSError as e:
        return None, f"jsonl unreadable: {e}", None
    with f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if first_ts is None:
                ts = entry.get("timestamp")
                if isinstance(ts, str):
                    try:
                        first_ts = _dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    except ValueError:
                        pass
            if entry.get("type") == "pr-link":
                repo = (entry.get("prRepository") or "").strip()
                num = entry.get("prNumber")
                if repo and num is not None:
                    pr_link_prs.add((repo, str(num)))
                continue
            for repo, num in _yield_tool_result_exact_prs(entry):
                tool_result_exact_prs.add((repo, num))
            for txt in _yield_text(entry, entry.get("type", "?")):
                for m in TRANSCRIPT_SESSION_URL_RE.findall(txt):
                    a_votes[f"{SESSION_URL_PREFIX}{m}"] += 1
                for m in TRANSCRIPT_PR_URL_RE.findall(txt):
                    prose_prs.add(m)
                for m in TRANSCRIPT_PR_AUTOLINK_RE.findall(txt):
                    prose_prs.add(m)
    # Dedupe — tool_result_exact gets the strong weight; prose shouldn't
    # also score these same PRs.
    prose_prs -= tool_result_exact_prs

    votes: Counter = Counter()
    breakdown: dict[str, dict[str, int]] = {}

    def _add(url: str, kind: str, n: int = 1):
        votes[url] += n * SCAN_WEIGHTS[kind]
        breakdown.setdefault(url, {}).setdefault(kind, 0)
        breakdown[url][kind] += n

    for repo, num in pr_link_prs:
        key = (_normalize_repo(repo), str(num))
        if key in pr_map:
            url, _ = pr_map[key]
            _add(url, "pr_link")
    for repo, num in tool_result_exact_prs:
        key = (_normalize_repo(repo), str(num))
        if key in pr_map:
            url, _ = pr_map[key]
            _add(url, "tool_result_exact")
    for url, c in a_votes.items():
        _add(url, "pattern_a", c)
    for repo, num in prose_prs:
        key = (_normalize_repo(repo), str(num))
        if key in pr_map:
            url, atype = pr_map[key]
            _add(url, "prose_pr" if atype == "pr" else "prose_issue")

    if not votes:
        return None, (
            f"no signal (pr-link={len(pr_link_prs)}, "
            f"prose-PRs={len(prose_prs)}, A-literal={sum(a_votes.values())}, "
            f"none in index)"
        ), None

    pruned_count = 0
    if first_ts is not None and session_last_seen:
        cutoff = first_ts - _dt.timedelta(hours=prune_window_hours)
        kept_votes: Counter = Counter()
        kept_breakdown: dict[str, dict[str, int]] = {}
        for url, score in votes.items():
            url_parts = breakdown.get(url, {})
            url_has_direct = (
                url_parts.get("pr_link", 0) > 0
                or url_parts.get("tool_result_exact", 0) > 0
                or url_parts.get("pattern_a", 0) > 0
            )
            if url_has_direct:
                kept_votes[url] = score
                kept_breakdown[url] = url_parts
                continue
            last_seen = session_last_seen.get(url)
            if last_seen is not None and last_seen >= cutoff:
                kept_votes[url] = score
                kept_breakdown[url] = url_parts
            else:
                pruned_count += 1
        if not kept_votes:
            return None, (
                f"all {pruned_count} candidates predate transcript "
                f"(first_ts={first_ts.isoformat()}, cutoff={cutoff.isoformat()})"
            ), None
        votes = kept_votes
        breakdown = kept_breakdown

    prune_note = f" [{pruned_count} pruned by date]" if pruned_count else ""

    def _direct_score(p: dict[str, int]) -> int:
        return (p.get("pr_link", 0) * SCAN_WEIGHTS["pr_link"]
                + p.get("tool_result_exact", 0) * SCAN_WEIGHTS["tool_result_exact"]
                + p.get("pattern_a", 0) * SCAN_WEIGHTS["pattern_a"])

    # Direct-authorship early accept: a candidate with pr_link or
    # tool_result_exact entries (≥10pt direct signal) is the session that
    # actually opened those PRs. Accept it regardless of prose-only
    # competitors, which are necessarily cross-references rather than
    # authorship.
    direct_scored = sorted(
        ((u, _direct_score(breakdown[u]), votes[u]) for u in votes),
        key=lambda r: (r[1], r[2]),
        reverse=True,
    )
    if direct_scored and direct_scored[0][1] >= 10:
        url, dscore, tscore = direct_scored[0]
        runner_d = direct_scored[1][1] if len(direct_scored) > 1 else 0
        parts = breakdown.get(url, {})
        parts_str = "+".join(f"{n}{k[0]}" for k, n in parts.items())
        return url, (
            f"direct authorship ({dscore}pt direct / {tscore}pt total; "
            f"{parts_str}; runner-up direct={runner_d}pt){prune_note}"
        ), dominant_scan_source(parts)

    top = votes.most_common(2)
    top_url, top_score = top[0]
    runner_score = top[1][1] if len(top) > 1 else 0
    parts = breakdown.get(top_url, {})
    parts_str = "+".join(f"{n}{k[0]}" for k, n in parts.items())
    # Floor: 5pt for any direct signal (e.g. 1 pattern-a literal URL); 6pt
    # for prose-only candidates so a single cross-referenced PR (3pt) isn't
    # enough by itself — a real authoring session typically opens 2+
    # artifacts. After the date prune, observe-only sessions can otherwise
    # win unanimously on a single in-window prose reference, which is wrong.
    has_direct = _direct_score(parts) > 0
    floor = 5 if has_direct else 6
    if top_score < floor:
        return None, f"too weak ({top_score}pt vs floor {floor}; {parts_str}){prune_note}", None
    if runner_score == 0:
        return top_url, f"unanimous ({top_score}pt: {parts_str}){prune_note}", dominant_scan_source(parts)
    if top_score >= 2 * runner_score:
        return top_url, (
            f"strong mode ({top_score}pt vs {runner_score}pt 2nd; {parts_str}){prune_note}"
        ), dominant_scan_source(parts)
    return None, (
        f"conflict (top {top_score}pt vs 2nd {runner_score}pt; "
        f"top3={votes.most_common(3)}){prune_note}"
    ), None


def _resolve_via_scan(
    session_id: str,
    pr_map: dict[tuple[str, str], tuple[str, str]],
    session_last_seen: dict[str, _dt.datetime] | None = None,
) -> tuple[Optional[str], str, Optional[str]]:
    """Decrypt + scan + cleanup. Returns (url, detail, dominant_source)."""
    if not FETCH_SH.is_file():
        return None, f"fetch wrapper missing: {FETCH_SH}", None
    try:
        fetch = subprocess.run(
            ["bash", str(FETCH_SH), session_id],
            check=True, capture_output=True, text=True, timeout=120,
        )
    except subprocess.CalledProcessError as e:
        return None, f"fetch failed: rc={e.returncode} {e.stderr.strip()[:200]}", None
    except subprocess.TimeoutExpired:
        return None, "fetch timed out after 120s", None
    jsonl_path = fetch.stdout.strip()
    if not jsonl_path or not Path(jsonl_path).is_file():
        return None, f"fetch returned no usable path ({jsonl_path!r})", None
    try:
        url, detail, source = _scan_jsonl_for_url(
            Path(jsonl_path), pr_map, session_last_seen=session_last_seen,
        )
    finally:
        try:
            subprocess.run(
                ["bash", str(FETCH_SH), "--cleanup", jsonl_path],
                check=False, capture_output=True, timeout=10,
            )
        except subprocess.TimeoutExpired:
            pass
    return url, detail, source


def _rerender_one(
    s3, bucket: str, session_id: str, key_prefix: str, session_url: str,
) -> tuple[bool, str]:
    """Decrypt ciphertext via transcript-fetch.sh and re-run the renderer
    with env-injected CLAUDE_CODE_SESSION_ID/REMOTE_SESSION_ID so the
    renderer's path-1 env recovery fires. Uploads fresh HTML + sidecar
    to R2 via the renderer's own put pipeline.

    Preserves the pre-existing `url_source` on the sidecar when it was
    AUTHORITATIVE and not already ``env-recovery``. The renderer's
    env-injection tags every URL ``env-recovery`` by construction, which
    is correct for first-time renders but erases historical provenance
    (e.g. ``html-extract``, ``title-fast-path``, ``export-meta-fallback``)
    on subsequent rerenders. Briefing 039 *Critical* — must-preserve."""
    if not FETCH_SH.is_file():
        return False, f"fetch wrapper missing: {FETCH_SH}"
    if not RENDER_PY.is_file():
        return False, f"render script missing: {RENDER_PY}"
    remote = session_url.removeprefix(SESSION_URL_PREFIX).strip()
    if not remote:
        return False, f"could not parse remote sid from {session_url!r}"

    # Capture pre-existing authoritative url_source so we can restore it
    # after the renderer overwrites the sidecar with env-recovery.
    meta_key = f"{key_prefix}/{session_id}.meta.json"
    preserved_url_source: str | None = None
    try:
        body = s3.get_object(Bucket=bucket, Key=meta_key)["Body"].read()
        existing = json.loads(body)
        existing_src = existing.get("url_source")
        if (
            existing_src in AUTHORITATIVE_URL_SOURCES
            and existing_src != "env-recovery"
        ):
            preserved_url_source = existing_src
    except Exception:
        # No pre-existing sidecar or unreadable — fail-soft; the renderer
        # will write a fresh env-recovery tag, which is correct first-run
        # behavior.
        pass

    try:
        fetch = subprocess.run(
            ["bash", str(FETCH_SH), session_id],
            check=True, capture_output=True, text=True, timeout=120,
        )
    except subprocess.CalledProcessError as e:
        return False, f"fetch failed: rc={e.returncode} stderr={e.stderr.strip()[:200]}"
    except subprocess.TimeoutExpired:
        return False, "fetch timed out after 120s"
    jsonl_path = fetch.stdout.strip()
    if not jsonl_path or not Path(jsonl_path).is_file():
        return False, f"fetch returned no usable path ({jsonl_path!r})"

    env = os.environ.copy()
    env["CLAUDE_CODE_SESSION_ID"] = session_id
    env["CLAUDE_CODE_REMOTE_SESSION_ID"] = remote

    try:
        render = subprocess.run(
            [str(RENDER_PY),
             "--session-id", session_id,
             "--input", jsonl_path,
             "--key-prefix", key_prefix,
             "--overwrite"],
            check=True, capture_output=True, text=True, timeout=120, env=env,
        )
    except subprocess.CalledProcessError as e:
        return False, f"render failed: rc={e.returncode} stderr={e.stderr.strip()[:200]}"
    except subprocess.TimeoutExpired:
        return False, "render timed out after 120s"
    finally:
        try:
            subprocess.run(
                ["bash", str(FETCH_SH), "--cleanup", jsonl_path],
                check=False, capture_output=True, timeout=10,
            )
        except subprocess.TimeoutExpired:
            pass

    last = render.stderr.strip().splitlines()[-1] if render.stderr.strip() else ""

    if preserved_url_source is None:
        return True, f"re-rendered ({last})"

    # Restore the pre-existing authoritative url_source. Unconditional
    # write here — the rerender-restore is a known-correct override of
    # the env-recovery tag the renderer just wrote. _patch_one's
    # preservation check would refuse this write because env-recovery
    # is itself authoritative; the restore is the one place that
    # legitimately replaces one authoritative tag with another.
    try:
        body = s3.get_object(Bucket=bucket, Key=meta_key)["Body"].read()
        meta = json.loads(body)
        meta["url_source"] = preserved_url_source
        new_body = json.dumps(meta, separators=(",", ":")).encode("utf-8")
        s3.put_object(
            Bucket=bucket, Key=meta_key, Body=new_body,
            ContentType="application/json; charset=utf-8",
        )
        return True, f"re-rendered ({last}) · url_source restored: {preserved_url_source}"
    except Exception as e:
        return True, (
            f"re-rendered ({last}) · WARN: url_source restore failed: {e} "
            f"(was {preserved_url_source}, now env-recovery)"
        )


def _patch_one(
    s3, bucket: str, key: str, session_url: str, url_source: str,
) -> tuple[bool, str]:
    """Write (session_url, url_source) to a sidecar, respecting the
    authoritative-preservation rule.

    Refuses to overwrite a sidecar whose existing url_source is in
    AUTHORITATIVE_URL_SOURCES (briefing 039 reconcile invariant).
    Reconcile-eligible sources (scan-*) can be replaced by any signal.
    No-op when both session_url and url_source already match."""
    if url_source not in VALID_URL_SOURCES:
        return False, f"refusing write: unknown url_source {url_source!r}"
    try:
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        meta = json.loads(body)
    except Exception as e:
        return False, f"read failed: {e}"
    prev_url = (meta.get("session_url") or "").strip()
    prev_src = meta.get("url_source")
    if (
        prev_src in AUTHORITATIVE_URL_SOURCES
        and (prev_src, prev_url) != (url_source, session_url)
    ):
        return True, (
            f"no-op (authoritative url_source={prev_src} present; "
            f"refusing to overwrite)"
        )
    if prev_url == session_url and prev_src == url_source:
        return True, "no-op (already set)"
    meta["session_url"] = session_url
    meta["url_source"] = url_source
    body_new = json.dumps(meta, separators=(",", ":")).encode("utf-8")
    try:
        s3.put_object(
            Bucket=bucket, Key=key, Body=body_new,
            ContentType="application/json; charset=utf-8",
        )
    except Exception as e:
        return False, f"put failed: {e}"
    prev_pair = (prev_url, prev_src) if prev_url else None
    new_pair = (session_url, url_source)
    return True, (f"{prev_pair} -> {new_pair}" if prev_pair else f"set -> {new_pair}")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__.splitlines()[1] if __doc__ else "",
    )
    p.add_argument("--limit", type=int, default=None,
                   help="patch at most N sidecars (default: all hits)")
    p.add_argument("--dry-run", action="store_true",
                   help="print sid<TAB>session_url assignments without patching")
    p.add_argument("--include-populated", action="store_true",
                   help="also consider sidecars whose session_url is already set")
    p.add_argument("--rerender", action="store_true",
                   help="after patching the sidecar, also re-run the renderer "
                        "with env-injected CLAUDE_CODE_SESSION_ID/REMOTE_SESSION_ID "
                        "so the HTML body includes the 'Open in Claude Code' link")
    p.add_argument("--scan-transcript", action="store_true",
                   help="for sidecars the title-fast-path missed, decrypt the "
                        "ciphertext and scan jsonl content for literal session "
                        "URLs (strict regex) or coo-labs PR/issue refs (reverse "
                        "looked up via session_artifacts.json). Cohort B+C "
                        "fallback path.")
    p.add_argument("--key-prefix", default="rendered",
                   help="R2 key prefix for rendered HTML/meta (default: rendered)")
    args = p.parse_args(argv)

    try:
        coords = r2_coordinates()
        s3 = r2_client(coords)
    except R2Error as e:
        _stderr(str(e))
        return 1
    bucket = coords.bucket

    _stderr("loading coo-labs/coo-logs/index/session_artifacts.json…")
    try:
        index = _load_session_artifacts_index()
    except RuntimeError as e:
        _stderr(str(e))
        return 1
    sid_to_url = _build_sid_to_url_map(index)
    _stderr(f"  {len(sid_to_url)} sids carry a per-session auto-meta-PR")

    key_prefix = args.key_prefix.rstrip("/")
    _stderr(f"scanning r2://{bucket}/{key_prefix}/ for sidecars…")
    candidates = _list_candidate_sidecars(s3, bucket, key_prefix, args.include_populated)
    _stderr(
        f"  {len(candidates)} sidecar(s) eligible "
        f"({'missing or populated' if args.include_populated else 'missing'} session_url)"
    )

    hits = [(sid, key, sid_to_url[sid], "title-fast-path") for sid, key in candidates if sid in sid_to_url]
    misses = [(sid, key) for sid, key in candidates if sid not in sid_to_url]
    _stderr(
        f"  {len(hits)} resolvable via title-fast-path "
        f"({len(misses)} unresolved by title)"
    )

    scan_resolved: list[tuple[str, str, str, str]] = []
    scan_unresolved = 0
    if args.scan_transcript and misses:
        _stderr(f"scan-transcript: probing {len(misses)} title-miss sids…")
        pr_to_url = _build_pr_to_url_map(index)
        session_last_seen = _build_session_last_seen(index)
        _stderr(
            f"  pr/issue reverse-index has {len(pr_to_url)} entries; "
            f"session_last_seen has {len(session_last_seen)} entries"
        )
        for i, (sid, key) in enumerate(misses, 1):
            _stderr(f"[scan {i}/{len(misses)}] {sid}")
            url, detail, source = _resolve_via_scan(sid, pr_to_url, session_last_seen)
            if url and source:
                scan_resolved.append((sid, key, url, source))
                _stderr(f"  scan OK · {source} · {detail} -> {url}")
            else:
                scan_unresolved += 1
                _stderr(f"  scan FAIL · {detail}")
        _stderr(f"  scan resolved={len(scan_resolved)} fail={scan_unresolved}")

    all_hits = hits + scan_resolved
    if args.limit is not None:
        all_hits = all_hits[: args.limit]
        _stderr(f"  limited to {len(all_hits)}")

    if args.dry_run:
        for sid, _key, url, source in all_hits:
            sys.stdout.write(f"{sid}\t{url}\t{source}\n")
        return 0

    ok = 0
    failed = 0
    rerender_ok = 0
    rerender_fail = 0
    for i, (sid, key, url, source) in enumerate(all_hits, 1):
        _stderr(f"[{i}/{len(all_hits)}] {sid} ({source})")
        success, detail = _patch_one(s3, bucket, key, url, source)
        if success:
            ok += 1
            _stderr(f"  patch OK · {detail}")
        else:
            failed += 1
            _stderr(f"  patch FAIL · {detail}")
            continue
        if args.rerender:
            r_success, r_detail = _rerender_one(s3, bucket, sid, key_prefix, url)
            if r_success:
                rerender_ok += 1
                _stderr(f"  rerender OK · {r_detail}")
            else:
                rerender_fail += 1
                _stderr(f"  rerender FAIL · {r_detail}")

    summary = (
        f"done: patch ok={ok} fail={failed} total={len(all_hits)} "
        f"(title={len(hits)} scan={len(scan_resolved)})"
    )
    if args.rerender:
        summary += f" | rerender ok={rerender_ok} fail={rerender_fail}"
    _stderr(summary)
    if failed:
        return 2
    if args.rerender and rerender_fail:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
