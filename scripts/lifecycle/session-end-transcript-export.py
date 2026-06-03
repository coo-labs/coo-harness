#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
"""
session-end-transcript-export.py — coo-labs/coo-logs#64 Batch 2.

Active component of the Stop-hook chain. Runs after a Claude Code
session ends; never blocks session end.

Pipeline per invocation:

  1. Resolve session id (CLAUDE_SESSION_ID > most-recent jsonl mtime).
  2. Locate the live transcript at ~/.claude/projects/<slug>/<id>.jsonl.
  3. Stream through scripts/lib/transcript-redact.py; on engine non-zero
     exit, drop <id>.export-error.txt and exit 0.
  4. gzip the redacted bytes (compression ~10× per spec).
  5. age-encrypt to scripts/lib/transcripts-recipient.age — at-rest
     encryption per BDFL approval (coo-logs#64 security review).
  6. boto3 upload to Cloudflare R2 at
     transcripts/YYYY/MM/DD/<id>.jsonl.gz.age (date from first event
     timestamp, falling back to UTC-now). The meta.json dict is built
     BEFORE this PUT and embedded as R2 user-metadata
     (`x-amz-meta-vade-meta-json`) on the same call — body and meta
     commit together in one atomic PUT (canonical durability layer
     post-this-PR; closes the cross-PUT SIGKILL window that #215's
     two-PUT layout left exposed).
  7. boto3 upload of meta.json to Cloudflare R2 at
     transcripts/meta/<id>.meta.json — best-effort secondary
     fast-resolve index for transcript-fetch (avoids list+head_object
     on the normal path). Failure here is recoverable via the embedded
     object-metadata from step 6.
  8. Write a sidecar at <coo-logs>/transcripts/YYYY/MM/DD/<id>.meta.json
     with parser_version, exported_at, event count, byte sizes,
     redaction hits, ciphertext sha256, and the R2 object keys.
     Best-effort secondary copy for GitHub-browsable history; failure
     here is recoverable via either step 6 (embedded) or step 7
     (flat-key) — the meta is durable on R2 either way.

Always exits 0. Any uncaught failure drops <id>.export-error.txt next
to where the meta.json would have gone, so the absence of meta.json +
presence of export-error.txt is the operator-visible "this hook
fired but couldn't complete" signal.

First-run cost note: on a fresh container the first invocation pays
~5–10s for uv to resolve+download boto3 (PEP 723 inline deps), plus
~1–2s for `op read` of endpoint+bucket and ~1–2s for the boto3 import.
Subsequent invocations in the same container hit the uv cache and
warm imports — typically sub-second beyond the redact-engine work.
Acceptable for a Stop hook (operator perceives session-end as already
"the slow part"); flagged here so an operator who notices the pause
on first session knows it's expected, not stuck.

Required env (sourced from ~/.vade/coo-env by the bash wrapper):
  R2_TRANSCRIPTS_ACCESS_KEY_ID      — R2 API token access key (32 hex)
  R2_TRANSCRIPTS_SECRET_ACCESS_KEY  — R2 API token secret key (64 hex)
Read at run time via `op read` (no env exposure):
  op://COO/r2-transcripts/endpoint  — R2 S3-compat URL
  op://COO/r2-transcripts/bucket    — bucket name
Optional:
  CLAUDE_SESSION_ID                  — override session-id resolution
  VADE_AGENT_LOGS_DIR                — override coo-logs working
                                       tree resolution
  VADE_TRANSCRIPT_EXPORT_DRY_RUN=1   — skip R2 upload AND skip auto-PR
                                       (CI / smoke-test)
  VADE_TRANSCRIPT_EXPORT_NO_PR=1     — skip auto-PR open only (still
                                       upload + write sidecar; useful
                                       when running locally without a
                                       network or PAT)
  GITHUB_MCP_PAT                     — required for auto-PR-on-meta;
                                       absence is a soft skip, not an
                                       error (per coo-harness#148 A)
"""

from __future__ import annotations

import datetime
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path

PARSER_VERSION = 1
SCRIPT_DIR = Path(__file__).resolve().parent
RUNTIME_ROOT = SCRIPT_DIR.parent.parent
REDACT_PY = RUNTIME_ROOT / "scripts" / "lib" / "transcript-redact.py"
RECIPIENT_FILE = RUNTIME_ROOT / "scripts" / "lib" / "transcripts-recipient.age"
REDACTION_CONFIG = RUNTIME_ROOT / "scripts" / "lib" / "transcript-redaction.json"


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[session-end-transcript-export] {msg}\n")


def _resolve_session_id_and_jsonl() -> tuple[str, Path]:
    """Locate the live session jsonl. Prefers CLAUDE_SESSION_ID; falls
    back to most-recent mtime under ~/.claude/projects/*/*.jsonl.

    Fallback safety: in current Claude Code releases the harness
    reliably sets CLAUDE_SESSION_ID for Stop hooks, so the mtime path
    is single-session-best-effort defensive code for older harness
    versions and odd surfaces. If two parallel sessions share $HOME
    (cloud cohabitation, multi-pane local Mac, the briefing-005
    dual-instance pattern), the fallback can pick the sibling's
    still-being-written transcript by mtime. The per-project glob
    narrows blast radius but doesn't eliminate it. If the harness
    drops CLAUDE_SESSION_ID guarantees, tighten this to "most recent
    jsonl in the same project slug as $PWD"."""
    projects = Path.home() / ".claude" / "projects"
    if not projects.is_dir():
        raise FileNotFoundError(f"~/.claude/projects not found at {projects}")

    sid = os.environ.get("CLAUDE_SESSION_ID", "").strip()
    if sid:
        candidates = list(projects.glob(f"*/{sid}.jsonl"))
        if not candidates:
            raise FileNotFoundError(
                f"CLAUDE_SESSION_ID={sid} but no matching jsonl under {projects}"
            )
        return sid, candidates[0]

    all_jsonl = sorted(
        projects.glob("*/*.jsonl"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not all_jsonl:
        raise FileNotFoundError(f"no .jsonl found under {projects}")
    chosen = all_jsonl[0]
    return chosen.stem, chosen


def _resolve_agent_logs_dir() -> Path:
    """Resolve coo-logs working tree (for sidecar drop-off)."""
    explicit = os.environ.get("VADE_AGENT_LOGS_DIR", "").strip()
    if explicit:
        p = Path(explicit)
        if p.is_dir():
            return p
        raise FileNotFoundError(f"VADE_AGENT_LOGS_DIR={p} does not exist")

    coo_memory_dir = os.environ.get("VADE_COO_MEMORY_DIR")
    candidates = [
        Path(coo_memory_dir).parent / "coo-logs" if coo_memory_dir else Path("/dev/null"),
        Path.home() / "GitHub" / "coo-labs" / "coo-logs",
        RUNTIME_ROOT.parent / "coo-logs",
    ]
    for c in candidates:
        if c.is_dir():
            return c
    raise FileNotFoundError(
        "coo-logs working tree not found; tried "
        + ", ".join(str(c) for c in candidates)
    )


def _first_event_date(jsonl_path: Path) -> datetime.date:
    """Read the first parseable event and extract a date from its
    timestamp. Falls back to today UTC if no parseable timestamp."""
    try:
        with open(jsonl_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = obj.get("timestamp") or obj.get("ts")
                if isinstance(ts, str):
                    try:
                        # ISO-8601 with optional Z suffix.
                        return datetime.datetime.fromisoformat(
                            ts.replace("Z", "+00:00")
                        ).date()
                    except ValueError:
                        continue
                if isinstance(ts, (int, float)):
                    return datetime.datetime.fromtimestamp(
                        ts / 1000 if ts > 1e12 else ts,
                        tz=datetime.timezone.utc,
                    ).date()
    except OSError:
        pass
    return datetime.datetime.now(datetime.timezone.utc).date()


def _run_redact(input_path: Path, output_path: Path, hits_path: Path) -> None:
    """Subprocess the redact engine. Raises CalledProcessError on
    non-zero exit; the caller turns that into an export-error.txt."""
    if not REDACT_PY.is_file():
        raise FileNotFoundError(f"redact engine missing: {REDACT_PY}")
    if not REDACTION_CONFIG.is_file():
        raise FileNotFoundError(f"redaction config missing: {REDACTION_CONFIG}")
    subprocess.run(
        [
            sys.executable,
            str(REDACT_PY),
            "--config", str(REDACTION_CONFIG),
            "--input", str(input_path),
            "--output", str(output_path),
            "--hits", str(hits_path),
        ],
        check=True,
    )


def _gzip_file(src: Path, dst: Path) -> None:
    with open(src, "rb") as fin, gzip.open(dst, "wb", compresslevel=6) as fout:
        shutil.copyfileobj(fin, fout)


def _age_encrypt(src: Path, dst: Path) -> None:
    if not RECIPIENT_FILE.is_file():
        raise FileNotFoundError(f"age recipient file missing: {RECIPIENT_FILE}")
    if not shutil.which("age"):
        raise FileNotFoundError("age binary not on PATH")
    with open(src, "rb") as fin, open(dst, "wb") as fout:
        subprocess.run(
            ["age", "-R", str(RECIPIENT_FILE)],
            stdin=fin,
            stdout=fout,
            check=True,
        )


def _read_recipient_pubkey() -> str:
    """Slurp the X25519 pubkey from RECIPIENT_FILE for sidecar embedding.
    Returns the last non-comment, non-blank line — matches `age -R`'s
    own parser convention (one recipient per line, leading `#` is a
    comment). Embedded in sidecar so a reader holding only meta.json
    can verify which recipient encrypted the ciphertext without
    cloning coo-harness at the same SHA the hook ran from."""
    try:
        for line in reversed(RECIPIENT_FILE.read_text().splitlines()):
            s = line.strip()
            if s and not s.startswith("#"):
                return s
    except OSError:
        pass
    return ""


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(64 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _op_read(ref: str) -> str:
    """Read a 1Password reference via the op CLI. Returns empty string
    on any failure (caller decides whether to abort or skip)."""
    if not shutil.which("op"):
        return ""
    try:
        out = subprocess.run(
            ["op", "read", ref],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return out.stdout.strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return ""


def _r2_endpoint_bucket() -> tuple[str, str]:
    """Resolve R2 endpoint + bucket via `op` once.

    Callers that PUT twice (ciphertext + flat-key meta) should resolve
    once here and pass the values into `_r2_upload` to avoid duplicate
    `op` invocations. Raises if either slot is empty.
    """
    endpoint = _op_read("op://COO/r2-transcripts/endpoint")
    bucket = _op_read("op://COO/r2-transcripts/bucket")
    if not endpoint or not bucket:
        raise RuntimeError(
            "R2 endpoint or bucket not readable from "
            "op://COO/r2-transcripts/{endpoint,bucket}"
        )
    return endpoint, bucket


def _r2_upload(
    local: Path,
    key: str,
    *,
    metadata: dict[str, str] | None = None,
    endpoint: str | None = None,
    bucket: str | None = None,
) -> dict:
    """Upload a local file to R2 at the given key with first-write-wins
    semantics. Returns a dict with bucket+key+endpoint for the sidecar
    plus `ceded: bool` indicating whether another writer already held
    the key. Raises on non-precondition failures.

    First-write-wins via `IfNoneMatch='*'` (coo-harness#204, MEMO 2026-05-03-bgk3):
    age encryption is non-deterministic (fresh X25519 ephemeral keypair
    per call), so two writers encrypting the same plaintext produce
    different ciphertext bytes. Without atomic-create, last-write-wins
    on R2 leaves a meta.json `ciphertext_sha256` referencing bytes that
    are no longer there. R2 honors S3's `IfNoneMatch: *` (Cloudflare
    2024+) and returns HTTP 412 PreconditionFailed when the key
    already exists; the second writer cedes silently.

    Caller MUST check `ceded` before writing meta.json — a ceded
    writer's SHA does not match what's in R2 and writing it would
    re-create the mismatch this fix prevents.

    `metadata` is the optional R2 user-metadata dict (`x-amz-meta-*`
    headers, max 2 KB total, ASCII-only values). Body and metadata
    commit together in one atomic PUT — used by the export pipeline
    to embed meta.json on the ciphertext PUT, eliminating the
    cross-PUT SIGKILL window that #215's two-PUT layout left exposed.
    Orthogonal to `IfNoneMatch="*"`: the precondition is evaluated
    server-side before commit, so a 412 cede leaves no metadata
    behind either.
    """
    access_key = os.environ.get("R2_TRANSCRIPTS_ACCESS_KEY_ID", "").strip()
    secret_key = os.environ.get("R2_TRANSCRIPTS_SECRET_ACCESS_KEY", "").strip()
    if not access_key or not secret_key:
        raise RuntimeError(
            "R2_TRANSCRIPTS_ACCESS_KEY_ID / R2_TRANSCRIPTS_SECRET_ACCESS_KEY "
            "missing — fetch_coo_secrets did not populate them"
        )
    if endpoint is None or bucket is None:
        endpoint, bucket = _r2_endpoint_bucket()
    if metadata is not None:
        # R2 user-metadata is ISO-8859-1 string-only; ascii-encoded JSON
        # caller-side keeps that constraint trivially.
        assert all(isinstance(v, str) for v in metadata.values()), (
            "R2 user-metadata values must be strings"
        )

    import boto3  # imported lazily — uv resolves on first run
    from botocore.config import Config
    from botocore.exceptions import ClientError

    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name="auto",
        config=Config(
            signature_version="s3v4",
            retries={"max_attempts": 3, "mode": "standard"},
        ),
    )

    put_kwargs = {
        "Bucket": bucket,
        "Key": key,
        "IfNoneMatch": "*",
    }
    if metadata is not None:
        put_kwargs["Metadata"] = metadata

    try:
        with open(local, "rb") as fin:
            s3.put_object(Body=fin, **put_kwargs)
        return {"bucket": bucket, "key": key, "endpoint": endpoint, "ceded": False}
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        status = e.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
        if code == "PreconditionFailed" or status == 412:
            _stderr(f"R2 PUT ceded (key exists, first-write-wins): {key}")
            return {"bucket": bucket, "key": key, "endpoint": endpoint, "ceded": True}
        raise


def _r2_head_object_metadata(
    key: str,
    *,
    endpoint: str,
    bucket: str,
) -> dict[str, str] | None:
    """Fetch R2 user-metadata for an existing key via head_object.

    Used by the cede branch (coo-harness#416): on first-write-wins cede,
    the canonical writer's sidecar JSON is embedded in
    `x-amz-meta-vade-meta-json` on the ciphertext key. Reading it back
    lets the second writer reconstruct the local sidecar from the first
    writer's dict (not its own stale dict whose ciphertext_sha256 no
    longer matches what's in R2).

    Returns the lowercased Metadata dict on success, None on any failure
    (caller falls back to breadcrumb-only behavior).
    """
    access_key = os.environ.get("R2_TRANSCRIPTS_ACCESS_KEY_ID", "").strip()
    secret_key = os.environ.get("R2_TRANSCRIPTS_SECRET_ACCESS_KEY", "").strip()
    if not access_key or not secret_key:
        return None

    try:
        import boto3
        from botocore.config import Config

        s3 = boto3.client(
            "s3",
            endpoint_url=endpoint,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
            region_name="auto",
            config=Config(
                signature_version="s3v4",
                retries={"max_attempts": 3, "mode": "standard"},
            ),
        )
        resp = s3.head_object(Bucket=bucket, Key=key)
        return resp.get("Metadata") or {}
    except BaseException:
        return None


def _encode_meta_for_object_metadata(sidecar: dict) -> dict[str, str] | None:
    """Encode the meta sidecar dict for embedding as R2 object metadata.

    Returns a dict suitable for `s3.put_object(Metadata=...)` — keys
    are the `x-amz-meta-*` user-metadata names (R2 lowercases them on
    read, so use lowercase here too), values are ASCII-only strings.

    Atomic-PUT durability: the ciphertext body and these metadata
    headers commit together in one HTTP request. This eliminates the
    cross-PUT SIGKILL window that #215's two sequential PUTs (ciphertext
    + flat-key meta.json) left exposed (round-2 verification 2026-05-03
    16:43Z: ciphertext landed, meta did not, no breadcrumb).

    Degradation ladder (R2 caps user-metadata at 2 KB total):
      1. Full encode → if ≤ 1900 B (safe margin), return.
      2. Drop `redaction_hits` (largest variable field) → retry; if
         ≤ 1900 B, return with `vade-meta-truncated` marker.
      3. Still too large → return None; caller skips the embed and
         relies on the secondary flat-key + sidecar + auto-PR layers.
    None is not a fatal error — the secondary layers carry full meta;
    the atomicity guarantee only weakens for outlier sessions, leaving
    behavior identical to today's for those.
    """
    LIMIT = 1900  # safe margin under R2's 2 KB user-metadata cap
    SCHEMA = str(sidecar.get("schema_version", 2))

    encoded = json.dumps(sidecar, separators=(",", ":"), ensure_ascii=True)
    if len(encoded.encode("utf-8")) <= LIMIT:
        return {"vade-meta-json": encoded, "vade-meta-schema": SCHEMA}

    truncated = {k: v for k, v in sidecar.items() if k != "redaction_hits"}
    encoded2 = json.dumps(truncated, separators=(",", ":"), ensure_ascii=True)
    if len(encoded2.encode("utf-8")) <= LIMIT:
        _stderr(
            f"meta exceeded {LIMIT}B; dropped redaction_hits from object-metadata "
            "(full meta still in flat-key + sidecar)"
        )
        return {
            "vade-meta-json": encoded2,
            "vade-meta-schema": SCHEMA,
            "vade-meta-truncated": "redaction_hits",
        }

    _stderr(
        f"meta still too large after dropping redaction_hits "
        f"({len(encoded2.encode('utf-8'))}B > {LIMIT}B); skipping object-metadata embed"
    )
    return None


def _emit_export_error(sidecar_dir: Path, session_id: str, exc: BaseException) -> None:
    sidecar_dir.mkdir(parents=True, exist_ok=True)
    err_path = sidecar_dir / f"{session_id}.export-error.txt"
    with open(err_path, "w") as f:
        f.write(f"# session-end-transcript-export.py failed\n")
        f.write(f"# generated: {datetime.datetime.now(datetime.timezone.utc).isoformat()}\n")
        f.write(f"# session_id: {session_id}\n")
        f.write(f"# script: {Path(__file__).resolve()}\n\n")
        f.write(str(exc))
        f.write("\n\n")
        traceback.print_exception(type(exc), exc, exc.__traceback__, file=f)
    _stderr(f"wrote export-error: {err_path}")


def _emit_meta_pr_error(sidecar_dir: Path, session_id: str, reason: str) -> None:
    """Write a durable breadcrumb when the auto-PR step fails or is
    skipped for non-design reasons. Sidecar lives next to where
    meta.json would have landed in coo-logs/transcripts/<date>/
    so the failure is visible to operators (and to a next-session-on-
    same-container debugger) even after the container that wrote it
    tears down — closing the diagnostic gap left by stderr-only logging
    in container-ephemeral LOG_FILE. Companion to _emit_export_error.

    Refs coo-harness#207 (the meta-vs-R2 asymmetry being instrumented)."""
    try:
        sidecar_dir.mkdir(parents=True, exist_ok=True)
        err_path = sidecar_dir / f"{session_id}.meta-pr-error.txt"
        with open(err_path, "w") as f:
            f.write("# session-end-transcript-export.py: meta auto-PR failed/skipped\n")
            f.write(f"# generated: {datetime.datetime.now(datetime.timezone.utc).isoformat()}\n")
            f.write(f"# session_id: {session_id}\n\n")
            f.write(f"reason: {reason}\n")
        _stderr(f"wrote meta-pr-error: {err_path} (reason: {reason})")
    except OSError as e:
        # Best-effort durable logging; don't let breadcrumb failure cascade.
        _stderr(f"could not write meta-pr-error breadcrumb: {e!r}")


def _open_meta_pr(
    agent_logs_dir: Path,
    sidecar_path: Path,
    session_id: str,
) -> str | None:
    """Open a single-file pure-add PR carrying just the new meta.json.

    Auto-merge happens via the Night's Watch §4 pure-add gate
    (MEMO-2026-04-26-04 §4 carve-out for own-author log PRs in
    coo-logs).

    Best-effort: any failure is logged via export-error.txt and we
    return None. Never raises, never blocks session end. Non-design
    failures (env regressions, git op failures) also drop a durable
    `<id>.meta-pr-error.txt` next to where meta.json would have gone
    via _emit_meta_pr_error — so the asymmetry documented at #207
    (R2 PUT yes, meta.json git-push no) becomes diagnosable rather
    than silent across container teardowns.

    Returns the PR URL on success, None otherwise.

    Skipped silently (no breadcrumb) when:
      - VADE_TRANSCRIPT_EXPORT_DRY_RUN=1 or VADE_TRANSCRIPT_EXPORT_NO_PR=1
      - the auto-meta branch already exists upstream (idempotent re-fire)

    Skipped with breadcrumb (operator should notice):
      - GITHUB_MCP_PAT not set in hook env
      - `gh` binary not on PATH
      - agent_logs_dir is not a git working tree
      - sidecar missing on disk (internal bug)
    """
    sidecar_dir = sidecar_path.parent

    if os.environ.get("VADE_TRANSCRIPT_EXPORT_DRY_RUN", "").strip() == "1":
        _stderr("auto-PR skipped (DRY_RUN=1)")
        return None
    if os.environ.get("VADE_TRANSCRIPT_EXPORT_NO_PR", "").strip() == "1":
        _stderr("auto-PR skipped (NO_PR=1)")
        return None

    pat = os.environ.get("GITHUB_MCP_PAT", "").strip()
    if not pat:
        _stderr("auto-PR skipped (GITHUB_MCP_PAT not set)")
        _emit_meta_pr_error(sidecar_dir, session_id, "GITHUB_MCP_PAT not set in hook env")
        return None
    if not shutil.which("gh"):
        _stderr("auto-PR skipped (gh binary not on PATH)")
        _emit_meta_pr_error(sidecar_dir, session_id, "gh binary not on PATH")
        return None
    if not (agent_logs_dir / ".git").exists():
        _stderr(f"auto-PR skipped ({agent_logs_dir} is not a git tree)")
        _emit_meta_pr_error(
            sidecar_dir, session_id, f"{agent_logs_dir} is not a git tree"
        )
        return None
    if not sidecar_path.is_file():
        _stderr(f"auto-PR skipped (sidecar missing: {sidecar_path})")
        _emit_meta_pr_error(
            sidecar_dir, session_id, f"sidecar missing on disk: {sidecar_path}"
        )
        return None

    short_sid = session_id[:12]
    branch = f"claude/auto-meta-{short_sid}"
    rel_sidecar = str(sidecar_path.relative_to(agent_logs_dir))

    git_env = {**os.environ, "GH_TOKEN": pat}

    def _git(*args: str, capture: bool = False) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["git", "-C", str(agent_logs_dir), *args],
            check=False,
            env=git_env,
            capture_output=capture,
            text=capture,
            timeout=30,
        )

    # Idempotent guard: if the branch exists on origin already, abort.
    ls_remote = _git("ls-remote", "--heads", "origin", branch, capture=True)
    if ls_remote.returncode == 0 and ls_remote.stdout.strip():
        _stderr(f"auto-PR skipped (branch {branch} exists on origin)")
        return None

    # Capture current HEAD so we can restore it after the auto-PR work.
    head_proc = _git("rev-parse", "HEAD", capture=True)
    if head_proc.returncode != 0:
        _stderr(f"auto-PR skipped (HEAD unresolvable: {head_proc.stderr.strip()})")
        _emit_meta_pr_error(
            sidecar_dir, session_id, f"HEAD unresolvable: {head_proc.stderr.strip()}"
        )
        return None
    original_ref_proc = _git("rev-parse", "--abbrev-ref", "HEAD", capture=True)
    original_ref = (
        original_ref_proc.stdout.strip() if original_ref_proc.returncode == 0 else ""
    )

    try:
        # Fetch origin/main and create the auto-meta branch from it. Use
        # a worktree-free flow: stash, switch, commit, switch back.
        fetch = _git("fetch", "origin", "main", capture=True)
        if fetch.returncode != 0:
            _stderr(f"auto-PR fetch origin/main failed: {fetch.stderr.strip()}")
            _emit_meta_pr_error(
                sidecar_dir,
                session_id,
                f"fetch origin/main failed: {fetch.stderr.strip()}",
            )
            return None

        # Stage just the new meta.json against the index AT origin/main
        # by doing the work on the new branch.
        switch = _git("switch", "-c", branch, "origin/main", capture=True)
        if switch.returncode != 0:
            _stderr(f"auto-PR switch -c {branch} failed: {switch.stderr.strip()}")
            _emit_meta_pr_error(
                sidecar_dir,
                session_id,
                f"switch -c {branch} failed: {switch.stderr.strip()}",
            )
            return None

        # Re-write the sidecar at the same relative path on the new
        # branch (the file may not exist on origin/main yet).
        target = agent_logs_dir / rel_sidecar
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(sidecar_path.read_text())

        add = _git("add", "--", rel_sidecar, capture=True)
        if add.returncode != 0:
            _stderr(f"auto-PR git add failed: {add.stderr.strip()}")
            _emit_meta_pr_error(
                sidecar_dir, session_id, f"git add failed: {add.stderr.strip()}"
            )
            return None

        commit_msg = (
            f"meta: auto-commit sidecar for {session_id}\n\n"
            "Stop hook auto-commit per coo-harness#148 Part A.\n"
            "Pure-add (single file) — eligible for the Night's Watch\n"
            "§4 pure-add merge gate (MEMO-2026-04-26-04 §4)."
        )
        commit = _git(
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-m",
            commit_msg,
            capture=True,
        )
        if commit.returncode != 0:
            _stderr(f"auto-PR git commit failed: {commit.stderr.strip()}")
            _emit_meta_pr_error(
                sidecar_dir, session_id, f"git commit failed: {commit.stderr.strip()}"
            )
            return None

        push = _git("push", "-u", "origin", branch, capture=True)
        if push.returncode != 0:
            _stderr(f"auto-PR git push failed: {push.stderr.strip()}")
            _emit_meta_pr_error(
                sidecar_dir, session_id, f"git push failed: {push.stderr.strip()}"
            )
            return None

        body = (
            "## Summary\n\n"
            f"Auto-commit of `{rel_sidecar}` for session `{session_id}`.\n"
            "Written by `coo-harness/scripts/lifecycle/session-end-transcript-export.py`\n"
            "per coo-harness#148 Part A. The encrypted ciphertext is\n"
            "already in R2; this PR makes the sidecar visible to the\n"
            "transcript-analyzer pipeline.\n\n"
            "## Test plan\n\n"
            "- [x] Single-file pure-add (`status == \"added\"`).\n"
            "- [ ] Auto-merges via the Night's Watch §4 pure-add gate.\n"
        )
        pr = subprocess.run(
            [
                "gh",
                "pr",
                "create",
                "-R",
                "coo-labs/coo-logs",
                "--base",
                "main",
                "--head",
                branch,
                "--title",
                f"meta: auto-commit sidecar for {session_id}",
                "--body",
                body,
            ],
            check=False,
            env=git_env,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if pr.returncode != 0:
            _stderr(f"auto-PR gh pr create failed: {pr.stderr.strip()}")
            _emit_meta_pr_error(
                sidecar_dir, session_id, f"gh pr create failed: {pr.stderr.strip()}"
            )
            return None
        url = pr.stdout.strip().splitlines()[-1] if pr.stdout.strip() else ""
        _stderr(f"auto-PR opened: {url}")
        return url or None
    finally:
        # Restore the working tree to whatever was checked out before.
        # Stop hooks fire from the active session; leaving the agent-logs
        # repo on a half-detached branch surprises the operator.
        if original_ref and original_ref != "HEAD":
            _git("switch", original_ref)
        else:
            _git("switch", "--detach", head_proc.stdout.strip())


def main() -> int:
    session_id = "unknown"
    sidecar_dir_for_error: Path | None = None
    try:
        session_id, jsonl_path = _resolve_session_id_and_jsonl()
        _stderr(f"session_id={session_id} jsonl={jsonl_path}")

        agent_logs_dir = _resolve_agent_logs_dir()
        date = _first_event_date(jsonl_path)
        date_path = f"{date.year:04d}/{date.month:02d}/{date.day:02d}"
        sidecar_dir = agent_logs_dir / "transcripts" / date_path
        sidecar_dir.mkdir(parents=True, exist_ok=True)
        sidecar_dir_for_error = sidecar_dir

        bytes_pre = jsonl_path.stat().st_size

        with tempfile.TemporaryDirectory(prefix=f"transcript-export-{session_id}-") as tmp:
            tmp_path = Path(tmp)
            redacted = tmp_path / "redacted.jsonl"
            hits = tmp_path / "hits.json"
            gz = tmp_path / "redacted.jsonl.gz"
            ciphertext = tmp_path / f"{session_id}.jsonl.gz.age"

            try:
                _run_redact(jsonl_path, redacted, hits)
            except subprocess.CalledProcessError as e:
                # Engine failure: drop export-error per the design.
                _emit_export_error(
                    sidecar_dir,
                    session_id,
                    RuntimeError(f"redact engine exited rc={e.returncode}"),
                )
                return 0

            redaction_summary = json.loads(hits.read_text())

            _gzip_file(redacted, gz)
            _age_encrypt(gz, ciphertext)
            ciphertext_sha256 = _sha256(ciphertext)
            ciphertext_size = ciphertext.stat().st_size

            r2_key = f"transcripts/{date_path}/{session_id}.jsonl.gz.age"
            meta_r2_key = f"transcripts/meta/{session_id}.meta.json"
            dry_run = os.environ.get("VADE_TRANSCRIPT_EXPORT_DRY_RUN", "").strip() == "1"

            # Pre-resolve R2 endpoint+bucket once so we can build the
            # sidecar dict BEFORE the ciphertext PUT. The sidecar gets
            # embedded as object metadata on the ciphertext PUT itself
            # (this PR) — single atomic PUT eliminates the cross-PUT
            # SIGKILL window that #215's two-PUT layout left exposed.
            if dry_run:
                r2_endpoint = "<dry-run>"
                r2_bucket = "<dry-run>"
                r2_target = {
                    "bucket": r2_bucket,
                    "key": r2_key,
                    "endpoint": r2_endpoint,
                    "uploaded": False,
                    "meta_key": meta_r2_key,
                }
            else:
                r2_endpoint, r2_bucket = _r2_endpoint_bucket()
                r2_target = {
                    "bucket": r2_bucket,
                    "key": r2_key,
                    "endpoint": r2_endpoint,
                    "uploaded": True,  # optimistic; cede branch returns 0 below
                    "meta_key": meta_r2_key,
                }

            sidecar = {
                "schema_version": 3,
                "parser_version": PARSER_VERSION,
                "session_id": session_id,
                "claude_code_remote_session_id":
                    os.environ.get("CLAUDE_CODE_REMOTE_SESSION_ID", "").strip(),
                "exported_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "source_jsonl": str(jsonl_path),
                "events_processed": redaction_summary.get("events_processed", 0),
                "events_with_unparseable_json":
                    redaction_summary.get("events_with_unparseable_json", 0),
                "bytes_pre_redaction": bytes_pre,
                "bytes_post_redaction": redaction_summary.get("bytes_post", 0),
                "bytes_post_gzip": gz.stat().st_size,
                "bytes_ciphertext": ciphertext_size,
                "ciphertext_sha256": ciphertext_sha256,
                "redaction_hits": redaction_summary.get("redaction_hits", {}),
                "r2": r2_target,
                "age_recipient_file": str(RECIPIENT_FILE.relative_to(RUNTIME_ROOT)),
                "age_recipient_pubkey": _read_recipient_pubkey(),
            }

            # Atomic ciphertext PUT carrying meta as R2 object metadata.
            # One HTTP request, one SIGKILL window: body and meta commit
            # together or not at all. This collapses the prior two-PUT
            # layout (#215) whose ~100-500ms inter-PUT gap was apparently
            # still inside the container-teardown SIGKILL window
            # (round-2 verification 2026-05-03T16:43Z: ciphertext landed,
            # meta did not, no breadcrumb).
            #
            # The flat-key meta PUT and local sidecar below remain as
            # best-effort secondary indexing layers (fast-resolve for
            # transcript-fetch + GitHub-browsable history); failures
            # there are recoverable via the embedded object-metadata.
            embed_metadata = (
                _encode_meta_for_object_metadata(sidecar) if not dry_run else None
            )

            if not dry_run:
                upload = _r2_upload(
                    ciphertext, r2_key,
                    metadata=embed_metadata,
                    endpoint=r2_endpoint, bucket=r2_bucket,
                )
                # First-write-wins cede (coo-harness#204): another writer
                # already holds this R2 key. Our ciphertext_sha256 does NOT
                # match what's in R2 — writing meta.json with our SHA would
                # re-create the mismatch the cede prevents. Instead, fetch
                # the first writer's sidecar back from object metadata via
                # head_object and continue the normal flat-key + sidecar +
                # auto-PR flow with their dict. Keeps the transcript
                # discoverable through every navigation path (coo-harness#416).
                if upload.get("ceded"):
                    md = _r2_head_object_metadata(
                        r2_key, endpoint=r2_endpoint, bucket=r2_bucket,
                    )
                    embed = (md or {}).get("vade-meta-json", "")
                    recovered: dict | None = None
                    if embed:
                        try:
                            recovered = json.loads(embed)
                        except json.JSONDecodeError:
                            recovered = None

                    if recovered is None:
                        # Outlier: first writer was too large to embed
                        # (None return from _encode_meta_for_object_metadata)
                        # or head_object itself failed. Fall through to the
                        # prior breadcrumb-only behavior.
                        _emit_meta_pr_error(
                            sidecar_dir,
                            session_id,
                            f"R2 PUT ceded to first writer (key={r2_key}); "
                            "vade-meta-json embed not recoverable; "
                            "skipped meta.json write",
                        )
                        return 0

                    _stderr(
                        f"R2 PUT ceded; recovered first writer's meta via "
                        f"head_object (key={r2_key})"
                    )
                    sidecar = recovered

            # Best-effort secondary: flat-key meta PUT (fast-resolve index
            # for transcript-fetch.py — avoids list+head_object on the
            # normal path). If this fails, fetch falls through to the
            # object-metadata tier on the ciphertext key.
            meta_temp = tmp_path / f"{session_id}.meta.json"
            meta_temp.write_text(json.dumps(sidecar, indent=2) + "\n")
            if dry_run:
                _stderr(f"R2 meta PUT skipped (DRY_RUN=1): would write to {meta_r2_key}")
            else:
                try:
                    meta_upload = _r2_upload(
                        meta_temp, meta_r2_key,
                        endpoint=r2_endpoint, bucket=r2_bucket,
                    )
                    if meta_upload.get("ceded"):
                        _stderr(
                            f"R2 meta PUT ceded (idempotent re-fire): key={meta_r2_key}"
                        )
                    else:
                        _stderr(f"wrote R2 meta: {meta_r2_key}")
                except BaseException as e:
                    # Best-effort: flat-key meta PUT failure doesn't
                    # block; the embedded object-metadata on the
                    # ciphertext PUT is the canonical durability layer.
                    # Drop a breadcrumb for operator visibility; absence
                    # of meta in flat-key + presence of object-metadata
                    # is recoverable via the fetch fallback chain.
                    _stderr(
                        f"R2 meta PUT failed: {e!r} "
                        "(best-effort secondary; object-metadata is canonical)"
                    )
                    _emit_meta_pr_error(
                        sidecar_dir,
                        session_id,
                        f"R2 meta PUT (flat-key secondary) failed: {e!r}",
                    )

            sidecar_path = sidecar_dir / f"{session_id}.meta.json"
            with open(sidecar_path, "w") as f:
                json.dump(sidecar, f, indent=2)
                f.write("\n")
            _stderr(f"wrote sidecar: {sidecar_path}")

        # Best-effort: open a single-file pure-add PR carrying just the
        # sidecar. Per coo-harness#148 Part A — closes the structural
        # gap where 78% of sessions skipped committing meta.json.
        # Failures here are logged via export-error, never raised.
        try:
            _open_meta_pr(agent_logs_dir, sidecar_path, session_id)
        except BaseException as e:
            _stderr(f"auto-PR raised unexpectedly: {e!r}; ignored")

        return 0
    except BaseException as e:
        # Never block session end. Drop an export-error wherever we can.
        target = sidecar_dir_for_error
        if target is None:
            # Pre-resolution failure: best-effort fallback to ~/.vade/transcript-export-errors.
            target = Path.home() / ".vade" / "transcript-export-errors"
        try:
            _emit_export_error(target, session_id, e)
        except BaseException:
            traceback.print_exc(file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(main())
