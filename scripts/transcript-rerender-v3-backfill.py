#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
"""
transcript-rerender-v3-backfill.py — briefing 039 Phase 4 driver.

Walks `r2://<bucket>/<key-prefix>/*.meta.json` sidecars with
`session_url` populated and re-runs the renderer on each. Idempotent —
re-renders existing populated sidecars to capture v3 schema fields
(`first_user_uuid`, `models`, `cwds`, `cc_version`) and ensure the
sidecar carries a canonical `url_source` tag.

The actual rerender call is `transcript_url_backfill._rerender_one`,
which:
  - Captures the pre-existing `url_source` if it's AUTHORITATIVE and
    not already `env-recovery` (preservation rule from briefing 039
    *Critical* — must-preserve).
  - Decrypts the ciphertext, spawns the renderer with env-injected
    `CLAUDE_CODE_SESSION_ID` / `CLAUDE_CODE_REMOTE_SESSION_ID`.
  - Restores the preserved `url_source` after the renderer writes its
    own `env-recovery` tag.

Defaults to `--dry-run`. Use `--apply` for the actual rerender pass.

Env: R2_TRANSCRIPTS_ACCESS_KEY_ID / R2_TRANSCRIPTS_SECRET_ACCESS_KEY.
op-reads endpoint + bucket from op://COO/r2-transcripts/{endpoint,bucket}.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
BACKFILL_PY = SCRIPT_DIR / "transcript-url-backfill.py"

# Locate coo-harness/lib/ on sys.path so `from transcripts import ...` resolves
# under the uv-run venv this script spawns into.
sys.path.insert(0, str(SCRIPT_DIR.parent / "lib"))

from transcripts import R2Error, list_keys, r2_client, r2_coordinates  # noqa: E402


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[transcript-rerender-v3-backfill] {msg}\n")


def _load_backfill_module():
    """Load transcript-url-backfill.py as a module so we can call
    `_rerender_one` directly. The rerender helper is orchestration (subprocess
    + R2 writes) and stays in scripts/ per the lib README's primitive/
    orchestration split; we keep importing it through importlib because the
    hyphenated filename isn't a valid Python module name."""
    spec = importlib.util.spec_from_file_location("transcript_url_backfill", BACKFILL_PY)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {BACKFILL_PY}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else "")
    p.add_argument("--apply", action="store_true",
                   help="actually re-render (default is --dry-run summary only)")
    p.add_argument("--key-prefix", default="rendered",
                   help="R2 key prefix for rendered HTML/meta (default: rendered)")
    p.add_argument("--limit", type=int, default=None,
                   help="rerender at most N sidecars (default: all populated)")
    p.add_argument("--filter-renderer-version", type=int, default=None,
                   help="only rerender sidecars whose existing renderer_version "
                        "is less than this (default: rerender every populated sidecar)")
    args = p.parse_args(argv)

    try:
        coords = r2_coordinates()
        s3 = r2_client(coords)
    except R2Error as e:
        _stderr(str(e))
        return 1
    bucket = coords.bucket

    bf = _load_backfill_module()

    key_prefix = args.key_prefix.rstrip("/")
    _stderr(f"scanning r2://{bucket}/{key_prefix}/ for populated sidecars…")

    eligible: list[tuple[str, str, str]] = []  # (sid, key, session_url)
    skipped_no_url = 0
    skipped_filtered = 0

    for obj in list_keys(f"{key_prefix}/", s3=s3):
        key = obj["key"]
        if not key.endswith(".meta.json"):
            continue
        sid = key[len(f"{key_prefix}/"):-len(".meta.json")]
        try:
            body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
            meta = json.loads(body)
        except Exception as e:
            _stderr(f"  skip {sid}: read failed ({e})")
            continue
        session_url = (meta.get("session_url") or "").strip()
        if not session_url:
            skipped_no_url += 1
            continue
        if args.filter_renderer_version is not None:
            rv = meta.get("renderer_version")
            if isinstance(rv, int) and rv >= args.filter_renderer_version:
                skipped_filtered += 1
                continue
        eligible.append((sid, key, session_url))

    _stderr(
        f"  eligible={len(eligible)} skipped_no_url={skipped_no_url} "
        f"skipped_filtered={skipped_filtered}"
    )

    if args.limit is not None:
        eligible = eligible[: args.limit]
        _stderr(f"  limited to {len(eligible)}")

    if not args.apply:
        _stderr("DRY-RUN — would rerender:")
        for sid, _key, url in eligible:
            sys.stdout.write(f"{sid}\t{url}\n")
        _stderr(f"DRY-RUN summary: would rerender {len(eligible)} sidecar(s).")
        _stderr("Re-run with --apply to actually re-render.")
        return 0

    ok = 0
    failed = 0
    for i, (sid, _key, url) in enumerate(eligible, 1):
        _stderr(f"[{i}/{len(eligible)}] {sid}")
        success, detail = bf._rerender_one(s3, bucket, sid, key_prefix, url)
        if success:
            ok += 1
            _stderr(f"  OK · {detail}")
        else:
            failed += 1
            _stderr(f"  FAIL · {detail}")

    _stderr(f"done: ok={ok} fail={failed} total={len(eligible)}")
    return 2 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
