#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
"""
transcript-render-backfill.py — coo-labs/coo-console#12 sub-task 4.

One-shot orchestrator that populates `r2://<bucket>/rendered/` from
the existing encrypted archive. For each session_id that has a
`transcripts/YYYY/MM/DD/<sid>.jsonl.gz.age` ciphertext but no
`rendered/<sid>.html` peer, decrypts via `scripts/lib/transcript-fetch.sh`
and renders via `scripts/lifecycle/session-end-transcript-render.py`.

The two subprocess calls are intentional: the existing fetch script
already encapsulates the decrypt-and-gunzip pipeline including
identity handling and meta validation, and the existing render
script already encapsulates the parse-and-upload pipeline. This
script is orchestration only — no duplicated decrypt or render code.

Usage:
  transcript-render-backfill.py [--limit N] [--dry-run] [--include-existing]
                                [--key-prefix rendered]

Env:
  R2_TRANSCRIPTS_ACCESS_KEY_ID      — R2 access key (32 hex)
  R2_TRANSCRIPTS_SECRET_ACCESS_KEY  — R2 secret key (64 hex)
  TRANSCRIPTS_AGE_IDENTITY          — age private key for decrypt
Read at run time via `op`:
  op://COO/r2-transcripts/endpoint
  op://COO/r2-transcripts/bucket

Exit 0 on success (including --dry-run); 1 on arg/env error; 2 on
non-recoverable runtime error. Per-session failures log to stderr
and continue — backfill is intentionally best-effort, fail-soft.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
RUNTIME_ROOT = SCRIPT_DIR.parent
FETCH_SH = RUNTIME_ROOT / "scripts" / "lib" / "transcript-fetch.sh"
RENDER_PY = RUNTIME_ROOT / "scripts" / "lifecycle" / "session-end-transcript-render.py"

# Locate coo-harness/lib/ on sys.path so `from transcripts import ...` resolves
# under the uv-run venv this script spawns into. See lib/transcripts/README.md
# §"Importing" for the parents[N] table; this script lives at scripts/<top>.py
# so parents[1] is the repo root.
sys.path.insert(0, str(SCRIPT_DIR.parent / "lib"))

from transcripts import R2Error, list_keys, r2_client, r2_coordinates  # noqa: E402

SESSION_ID_RE = re.compile(
    r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$"
)
CIPHERTEXT_KEY_RE = re.compile(
    r"transcripts/\d{4}/\d{2}/\d{2}/([a-f0-9-]{36})\.jsonl\.gz\.age$"
)
RENDERED_KEY_RE = re.compile(r"rendered/([a-f0-9-]{36})\.html$")


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[transcript-render-backfill] {msg}\n")


def _list_sessions(prefix: str, key_re: re.Pattern[str], s3) -> set[str]:
    sids: set[str] = set()
    for obj in list_keys(prefix, s3=s3):
        m = key_re.search(obj["key"])
        if m and SESSION_ID_RE.match(m.group(1)):
            sids.add(m.group(1))
    return sids


def _render_one(session_id: str, key_prefix: str, overwrite: bool) -> tuple[bool, str]:
    """Returns (ok, detail). detail is a one-line message for stderr."""
    # 1. Fetch (decrypt) → path on stdout, lives under ~/.vade/transcript-cache/
    try:
        fetch = subprocess.run(
            ["bash", str(FETCH_SH), session_id],
            check=True,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except subprocess.CalledProcessError as e:
        return False, f"fetch failed: rc={e.returncode} stderr={e.stderr.strip()[:200]}"
    except subprocess.TimeoutExpired:
        return False, "fetch timed out after 120s"
    jsonl_path = fetch.stdout.strip()
    if not jsonl_path:
        return False, "fetch returned empty stdout (skip from on-mismatch)"
    jsonl = Path(jsonl_path)
    if not jsonl.is_file():
        return False, f"fetch claimed {jsonl_path} but file missing"

    # 2. Render → uploads to R2 under <key-prefix>/<sid>.html.
    render_cmd = [
        str(RENDER_PY),
        "--session-id", session_id,
        "--input", str(jsonl),
        "--key-prefix", key_prefix,
    ]
    if overwrite:
        render_cmd.append("--overwrite")
    try:
        render = subprocess.run(
            render_cmd,
            check=True,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except subprocess.CalledProcessError as e:
        # leave the decrypted jsonl in cache for debugging
        return False, f"render failed: rc={e.returncode} stderr={e.stderr.strip()[:200]}"
    except subprocess.TimeoutExpired:
        return False, "render timed out after 120s"
    finally:
        # Cleanup the per-session decrypted jsonl from the cache.
        try:
            subprocess.run(
                ["bash", str(FETCH_SH), "--cleanup", str(jsonl)],
                check=False,
                capture_output=True,
                timeout=10,
            )
        except subprocess.TimeoutExpired:
            pass

    last = render.stderr.strip().splitlines()[-1] if render.stderr.strip() else ""
    return True, last


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else "")
    p.add_argument("--limit", type=int, default=None,
                   help="render at most N sessions (default: all missing)")
    p.add_argument("--dry-run", action="store_true",
                   help="list what would be rendered without doing it")
    p.add_argument("--include-existing", action="store_true",
                   help="re-render sessions that already have an HTML in R2")
    p.add_argument("--overwrite", action="store_true",
                   help="pass --overwrite to the renderer (default: first-write-wins)")
    p.add_argument("--key-prefix", default="rendered",
                   help="R2 key prefix for rendered HTML (default: rendered)")
    args = p.parse_args(argv)

    if not FETCH_SH.is_file():
        _stderr(f"fetch wrapper missing: {FETCH_SH}")
        return 1
    if not RENDER_PY.is_file():
        _stderr(f"render script missing: {RENDER_PY}")
        return 1

    try:
        coords = r2_coordinates()
        s3 = r2_client(coords)
    except R2Error as e:
        _stderr(str(e))
        return 1
    bucket = coords.bucket

    _stderr(f"scanning r2://{bucket}/transcripts/ for ciphertext keys…")
    exported = _list_sessions("transcripts/", CIPHERTEXT_KEY_RE, s3)
    _stderr(f"  {len(exported)} session(s) in archive")

    _stderr(f"scanning r2://{bucket}/{args.key_prefix}/ for existing renders…")
    already_rendered = _list_sessions(f"{args.key_prefix}/", RENDERED_KEY_RE, s3)
    _stderr(f"  {len(already_rendered)} already rendered")

    if args.include_existing:
        targets = sorted(exported)
    else:
        targets = sorted(exported - already_rendered)
    _stderr(f"  {len(targets)} target(s)")

    if args.limit is not None:
        targets = targets[: args.limit]
        _stderr(f"  limited to {len(targets)}")

    if args.dry_run:
        for sid in targets:
            sys.stdout.write(f"{sid}\n")
        return 0

    ok = 0
    failed = 0
    for i, sid in enumerate(targets, 1):
        _stderr(f"[{i}/{len(targets)}] {sid}")
        success, detail = _render_one(sid, args.key_prefix, args.overwrite)
        if success:
            ok += 1
            _stderr(f"  OK · {detail}")
        else:
            failed += 1
            _stderr(f"  FAIL · {detail}")

    _stderr(f"done: ok={ok} fail={failed} total={len(targets)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
