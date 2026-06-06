#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
"""
integrity-check-e6-r2-absence.py — R2 transcript-absence alarm.

Sibling to:
  - integrity-check-e7-r2-sha.py (#209) — SHA-mismatch detection.
  - integrity-check-e8-r2-orphan.py (#217) — partial-export (orphan meta).

E6 catches **total-loss-of-export**: local Claude Code session jsonls
exist under ~/.claude/projects within the last window, but R2 has zero
objects in the matching date prefixes. That is the failure mode of
coo-harness#181 (agent-teams SIGKILL, 48h outage 2026-04-29 → 04-30)
and coo-harness#198 (recurrence). Both went undetected for ~24h
because the only signal was the next nightly run finding no R2 objects.

E6 turns that signal into a boot-time invariant. Post-coo-harness#216
the partial-export hazard is structurally impossible (E8 covers the
residual), but the *absence* hazard — hook never runs at all because
of a future container-teardown bug, env-var rename, or settings.json
regression — remains until detected. Per MEMO-2026-05-04-mzeq
principle 2, "closed" requires both a fix AND a continuous detector.

Pipeline:
  1. Count *.jsonl files under PROJECTS_DIR (default ~/.claude/projects)
     whose mtime is within the last VADE_E6_WINDOW_H hours (default 24).
  2. If zero — skip cleanly. No upstream sessions to alarm on.
  3. Otherwise: list R2 objects under transcripts/<today>/ and
     transcripts/<yesterday>/ (UTC date partitions); count those whose
     LastModified is within the same window.
  4. If R2 count == 0 while local count > 0 — orphan-pipeline alarm.
     Otherwise — ok with summary.

Output: a single JSON object on stdout
    {"ok": bool, "local_count": int, "r2_count": int, "detail": str}
Plus a one-line human summary on stderr.

Exits 0 always — the wrapper interprets `ok`. The wrapper also fences
on R2 creds + uv + timeout availability.

coo-harness#201 — E6 boot-time integrity invariant.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Locate coo-harness/lib/ on sys.path so `from transcripts import ...` resolves
# under the uv-run venv this script spawns into. See lib/transcripts/README.md
# §"Importing" for the parents[N] table; this script lives at
# scripts/boot/<top>.py so parents[2] is the repo root.
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR.parent.parent / "lib"))

from transcripts import R2Error, r2_client, r2_coordinates  # noqa: E402


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[integrity-check-e6] {msg}\n")


def _emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def _date_prefixes(now: datetime) -> list[str]:
    """Return today's and yesterday's R2 prefixes in UTC."""
    today = now.strftime("transcripts/%Y/%m/%d/")
    yesterday = (now - timedelta(days=1)).strftime("transcripts/%Y/%m/%d/")
    return list(dict.fromkeys([yesterday, today]))


def _in_flight_jsonls() -> set[str]:
    """Return realpaths of *.jsonl files currently held open by any
    process — i.e. the harness's in-flight session log(s).

    Linux /proc-based; returns empty set on systems without /proc
    (macOS, BSD). The check is bounded by the number of running
    processes; integrity-check is short-lived so this is cheap.
    """
    open_paths: set[str] = set()
    proc = Path("/proc")
    if not proc.is_dir():
        return open_paths
    for pid_dir in proc.iterdir():
        if not pid_dir.name.isdigit():
            continue
        fd_dir = pid_dir / "fd"
        if not fd_dir.is_dir():
            continue
        try:
            for fd in fd_dir.iterdir():
                try:
                    target = os.readlink(fd)
                except OSError:
                    continue
                if target.endswith(".jsonl"):
                    try:
                        open_paths.add(str(Path(target).resolve()))
                    except OSError:
                        open_paths.add(target)
        except (OSError, PermissionError):
            continue
    return open_paths


def _count_local_jsonls(
    projects_dir: Path,
    window_start: datetime,
    now: datetime,
    exclude_session: str = "",
    in_flight: set[str] | None = None,
    inflight_recency_s: int = 60,
) -> int:
    """Count *.jsonl under projects_dir with mtime >= window_start.

    The current session's jsonl is being written continuously (mtime always
    fresh) but its Stop-hook export hasn't fired yet, so counting it
    inflates local_count and produces a false E6 alarm on quiet days where
    the only "recent local activity" is the in-flight session itself
    (coo-harness#229). Three exclusion paths, in order:

    1. `in_flight` (set of realpaths): /proc-based; catches any jsonl
       currently held open by any process (harness's active session log).
       Most precise when it works, but the cloud harness opens-write-closes
       per append rather than holding the fd, so this returns empty there
       (coo-harness#232).
    2. `exclude_session`: env-var-driven; skips jsonls whose stem matches
       the given id. Works when `CLAUDE_CODE_SESSION_ID` matches the jsonl
       filename UUID (interactive Bash subprocess), but unreliable at
       SessionStart hook time on cloud where the harness exposes the
       cloud event-style id (`cse_*`) instead.
    3. `inflight_recency_s`: any jsonl with mtime within the last N
       seconds is considered in-flight regardless of name or fd state
       (coo-harness#232). The fd-less, env-form-agnostic backstop —
       catches the in-flight session at SessionStart hook time on cloud
       where the first two paths fail. 60s default covers boot-time
       runs (jsonl mtime ~1s old when there's activity) without masking
       legitimately-stale never-exported jsonls (export normally fires
       seconds after Stop). Set to 0 to disable.
    """
    count = 0
    if not projects_dir.is_dir():
        return 0
    cutoff_ts = window_start.timestamp()
    now_ts = now.timestamp()
    in_flight = in_flight or set()
    for path in projects_dir.rglob("*.jsonl"):
        try:
            st = path.stat()
            if st.st_mtime >= cutoff_ts:
                try:
                    if str(path.resolve()) in in_flight:
                        continue
                except OSError:
                    pass
                if exclude_session and path.stem == exclude_session:
                    continue
                if (
                    inflight_recency_s > 0
                    and (now_ts - st.st_mtime) <= inflight_recency_s
                ):
                    continue
                count += 1
        except OSError:
            continue
    return count


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--window-h",
        type=int,
        default=int(os.environ.get("VADE_E6_WINDOW_H", "24")),
        help="Window in hours for both the local jsonl mtime filter and "
        "the R2 LastModified filter. Default 24 (also via VADE_E6_WINDOW_H).",
    )
    ap.add_argument(
        "--projects-dir",
        default=os.environ.get(
            "VADE_E6_PROJECTS_DIR", str(Path.home() / ".claude" / "projects")
        ),
        help="Path to the Claude Code per-project jsonl tree. Default "
        "~/.claude/projects (also via VADE_E6_PROJECTS_DIR).",
    )
    ap.add_argument(
        "--exclude-session",
        default=os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip(),
        help="Session id (jsonl stem) to exclude from local_count. The "
        "in-flight session's jsonl is being written continuously and "
        "would otherwise inflate the count on quiet days. Defaults to "
        "$CLAUDE_CODE_SESSION_ID. coo-harness#229.",
    )
    ap.add_argument(
        "--inflight-recency-s",
        type=int,
        default=int(os.environ.get("VADE_E6_INFLIGHT_RECENCY_S", "60")),
        help="Treat any jsonl whose mtime is within N seconds of now as "
        "in-flight and exclude it from local_count, regardless of name "
        "or /proc state. The fd-less, env-form-agnostic backstop for "
        "harnesses where the first two exclusion paths fail (cloud, where "
        "$CLAUDE_CODE_SESSION_ID at hook time is `cse_*` rather than the "
        "jsonl UUID, and where no process holds the jsonl fd open). "
        "Default 60 (also via VADE_E6_INFLIGHT_RECENCY_S). Set to 0 to "
        "disable. coo-harness#232.",
    )
    ap.add_argument("--verbose", action="store_true", help="Per-row detail to stderr.")
    args = ap.parse_args()

    try:
        coords = r2_coordinates()
    except R2Error as e:
        _emit(
            {
                "ok": True,
                "local_count": 0,
                "r2_count": 0,
                "detail": f"skip: {e}",
            }
        )
        return 0

    projects_dir = Path(args.projects_dir)
    now = datetime.now(timezone.utc)
    window_start = now - timedelta(hours=args.window_h)

    in_flight = _in_flight_jsonls()
    local_count = _count_local_jsonls(
        projects_dir,
        window_start,
        now,
        exclude_session=args.exclude_session,
        in_flight=in_flight,
        inflight_recency_s=args.inflight_recency_s,
    )
    if args.verbose:
        excl_bits = []
        if in_flight:
            excl_bits.append(f"in_flight={len(in_flight)}")
        if args.exclude_session:
            excl_bits.append(f"session={args.exclude_session}")
        if args.inflight_recency_s > 0:
            excl_bits.append(f"recency<={args.inflight_recency_s}s")
        excl = f" (excl {', '.join(excl_bits)})" if excl_bits else ""
        _stderr(
            f"local jsonls in last {args.window_h}h under {projects_dir}{excl}: "
            f"{local_count}"
        )

    if local_count == 0:
        detail = (
            f"no recent jsonls under {projects_dir} in last {args.window_h}h; "
            f"nothing to alarm on"
        )
        _emit(
            {
                "ok": True,
                "local_count": 0,
                "r2_count": 0,
                "detail": detail,
            }
        )
        return 0

    try:
        import boto3  # noqa: F401  (imported for side-effect of asserting availability)
        from botocore.exceptions import ClientError
    except ImportError as e:
        _emit(
            {
                "ok": False,
                "local_count": local_count,
                "r2_count": 0,
                "detail": f"boto3 import failed: {e}",
            }
        )
        return 0

    s3 = r2_client(coords)
    bucket = coords.bucket
    prefixes = _date_prefixes(now)

    r2_count = 0
    for prefix in prefixes:
        try:
            for page in s3.get_paginator("list_objects_v2").paginate(
                Bucket=bucket, Prefix=prefix
            ):
                for obj in page.get("Contents", []):
                    key = obj["Key"]
                    if not key.endswith(".jsonl.gz.age"):
                        continue
                    last_modified = obj["LastModified"]
                    if last_modified < window_start:
                        continue
                    r2_count += 1
                    if args.verbose:
                        _stderr(
                            f"R2 {key} (LastModified={last_modified.isoformat()})"
                        )
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "unknown")
            _stderr(f"list_objects_v2 ClientError on {prefix}: {code}")
            # Soft-fail: a transient list error shouldn't false-fire E6
            # in the wrapper. Report degraded with detail so it's visible
            # but don't claim r2_count we can't verify.
            _emit(
                {
                    "ok": False,
                    "local_count": local_count,
                    "r2_count": 0,
                    "detail": f"list_objects_v2 failed on prefix {prefix}: {code}",
                }
            )
            return 0

    if r2_count == 0:
        detail = (
            f"{local_count} local jsonls in last {args.window_h}h under "
            f"{projects_dir} but R2 has 0 objects (prefixes: "
            f"{','.join(prefixes)}) — transcript-export pipeline silent; "
            f"see coo-harness#201, MEMO-2026-05-04-mzeq"
        )
        _emit(
            {
                "ok": False,
                "local_count": local_count,
                "r2_count": 0,
                "detail": detail,
            }
        )
        _stderr(detail)
        return 0

    detail = (
        f"{r2_count} R2 ciphertexts and {local_count} local jsonls in last "
        f"{args.window_h}h (prefixes: {','.join(prefixes)}); pipeline live"
    )
    _emit(
        {
            "ok": True,
            "local_count": local_count,
            "r2_count": r2_count,
            "detail": detail,
        }
    )
    if args.verbose:
        _stderr(detail)
    return 0


if __name__ == "__main__":
    sys.exit(main())
