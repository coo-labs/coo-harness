#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
"""
session-end-transcript-render.py — coo-labs/coo-console#12 sub-task 1.

Renders a Claude Code session jsonl to a self-contained HTML viewer and
uploads it to R2 at `rendered/<sessionId>.html`. The Worker proxies
that key under `GET /transcripts/<sessionId>` on console.vade-app.dev.

Standalone for now — invoke manually or from a script. Wiring into the
Stop-hook chain (alongside session-end-transcript-export) is a separate
PR once the renderer's output stabilizes on real sessions.

Usage:
  # Render the most-recent local jsonl, upload to R2.
  session-end-transcript-render.py

  # Render a specific session.
  session-end-transcript-render.py --session-id <uuid>

  # Render an arbitrary jsonl path (does not require it under ~/.claude/projects).
  session-end-transcript-render.py --input /path/to/transcript.jsonl

  # Skip upload — write HTML to stdout (or --output PATH).
  session-end-transcript-render.py --no-upload --output /tmp/preview.html

Env:
  R2_TRANSCRIPTS_ACCESS_KEY_ID      — R2 access key (32 hex)
  R2_TRANSCRIPTS_SECRET_ACCESS_KEY  — R2 secret key (64 hex)
Read at run time via `op`:
  op://COO/r2-transcripts/endpoint  — R2 S3 URL
  op://COO/r2-transcripts/bucket    — bucket name

R2 layout:
  rendered/<sessionId>.html         — flat key, served by the Worker

Exits 0 on success or skip-without-error; 1 on argument or input error;
2 on R2 upload error (when not in --no-upload mode).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
RUNTIME_ROOT = SCRIPT_DIR.parent.parent

# Locate coo-harness/lib/ on sys.path so `from transcripts import ...` resolves
# under the uv-run venv this script spawns into.
sys.path.insert(0, str(RUNTIME_ROOT / "lib"))

from transcripts import (  # noqa: E402
    R2Error,
    r2_client,
    r2_coordinates,
    write_html_object,
    write_sidecar,
)
from transcripts.render import (  # noqa: E402
    RENDERER_VERSION,
    compute_metadata,
    format_session_url,
    render_html,
)

# Backward-compat alias — keep the script's PARSER_VERSION attribute name so
# any external probe (legacy CI, transcript-export parity, etc.) still finds it.
PARSER_VERSION = RENDERER_VERSION


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[session-end-transcript-render] {msg}\n")


def _resolve_session_id_and_jsonl(
    session_id_override: str | None,
    input_override: Path | None,
) -> tuple[str, Path]:
    if input_override is not None:
        if not input_override.is_file():
            raise FileNotFoundError(f"--input {input_override} not found")
        sid = session_id_override or input_override.stem
        return sid, input_override

    projects = Path.home() / ".claude" / "projects"
    if not projects.is_dir():
        raise FileNotFoundError(f"~/.claude/projects not found at {projects}")

    sid = session_id_override or os.environ.get("CLAUDE_SESSION_ID", "").strip()
    if sid:
        candidates = list(projects.glob(f"*/{sid}.jsonl"))
        if not candidates:
            raise FileNotFoundError(
                f"session-id={sid} but no matching jsonl under {projects}"
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


def _read_entries(jsonl_path: Path) -> list[dict]:
    entries = []
    with open(jsonl_path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError as e:
                _stderr(f"skipping malformed line {lineno}: {e}")
    return entries


# ---------------------------------------------------------------------------
# Session-URL resolution (orchestration: env + R2 lookup)
# ---------------------------------------------------------------------------


def _fetch_remote_sid_from_export_meta(
    session_id: str, s3=None, bucket: str | None = None
) -> str:
    """Best-effort lookup of CLAUDE_CODE_REMOTE_SESSION_ID from the
    export pipeline's meta.json at transcripts/meta/<sid>.meta.json.
    Returns "" on any failure or absence. Schema version 3 added the
    field; older sidecars return "" silently.

    Accepts an optional s3 + bucket so the caller can resolve R2 once and
    reuse the client. Falls back to its own resolution when called solo.
    """
    if s3 is None or bucket is None:
        try:
            coords = r2_coordinates()
            s3 = r2_client(coords)
            bucket = coords.bucket
        except R2Error:
            return ""
    try:
        from botocore.exceptions import ClientError
    except ImportError:
        return ""
    try:
        resp = s3.get_object(Bucket=bucket, Key=f"transcripts/meta/{session_id}.meta.json")
        body = resp["Body"].read()
        meta = json.loads(body)
        return str(meta.get("claude_code_remote_session_id") or "")
    except (ClientError, KeyError, ValueError):
        return ""


def _compute_session_url(
    session_id: str, s3=None, bucket: str | None = None
) -> tuple[str, str]:
    """Derive the claude.ai/code session URL for `session_id`.

    Lookup order:
      1. Env (CLAUDE_CODE_SESSION_ID matches target → use
         CLAUDE_CODE_REMOTE_SESSION_ID). Stop-hook path is here.
         Source tag: "env-recovery".
      2. Export meta.json sidecar in R2 (schema v3+ carries the
         remote-session-id). Backfill `_rerender_one` path is here.
         Source tag: "export-meta-fallback".

    Returns ``(url, source)``. ``("", "")`` when neither source has it.
    Both source tags name authoritative provenance — sidecars carrying
    them are immutable from any future reconcile pass; only ``scan-*``
    sources are reconcile-eligible. See the briefing-039 url_source
    enum for the full source taxonomy.
    """
    env_sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()
    if env_sid and env_sid == session_id:
        remote = os.environ.get("CLAUDE_CODE_REMOTE_SESSION_ID", "").strip()
        url = format_session_url(remote)
        if url:
            return url, "env-recovery"
    url = format_session_url(_fetch_remote_sid_from_export_meta(session_id, s3, bucket))
    if url:
        return url, "export-meta-fallback"
    return "", ""


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else "")
    p.add_argument("--session-id", help="explicit session uuid (overrides $CLAUDE_SESSION_ID)")
    p.add_argument("--input", type=Path, help="path to .jsonl (overrides session-id resolution)")
    p.add_argument("--output", type=Path, help="write HTML to PATH instead of stdout")
    p.add_argument("--no-upload", action="store_true",
                   help="skip R2 upload (default if --output is set)")
    p.add_argument("--overwrite", action="store_true",
                   help="overwrite an existing key in R2 (default: first-write-wins)")
    p.add_argument("--key-prefix", default="rendered",
                   help="R2 key prefix (default: rendered)")
    args = p.parse_args(argv)

    try:
        session_id, jsonl_path = _resolve_session_id_and_jsonl(
            args.session_id, args.input
        )
    except FileNotFoundError as e:
        _stderr(str(e))
        return 1

    _stderr(f"rendering {session_id} from {jsonl_path}")
    entries = _read_entries(jsonl_path)
    if not entries:
        _stderr(f"no entries in {jsonl_path}")
        return 1

    skip_upload = args.no_upload or args.output is not None
    if skip_upload:
        # Output paths skip R2 entirely — render without an R2 client.
        session_url, _ = _compute_session_url(session_id)
        html_doc = render_html(session_id, entries, session_url=session_url)
        html_bytes = html_doc.encode("utf-8")
        _stderr(f"rendered {len(entries)} entries → {len(html_bytes)} bytes")
        if args.output is not None:
            args.output.write_bytes(html_bytes)
            _stderr(f"wrote {args.output}")
        else:
            sys.stdout.write(html_doc)
        return 0

    try:
        coords = r2_coordinates()
        s3 = r2_client(coords)
    except R2Error as e:
        _stderr(str(e))
        return 2

    session_url, url_source = _compute_session_url(
        session_id, s3=s3, bucket=coords.bucket,
    )
    html_doc = render_html(session_id, entries, session_url=session_url)
    html_bytes = html_doc.encode("utf-8")
    _stderr(f"rendered {len(entries)} entries → {len(html_bytes)} bytes")

    key_prefix = args.key_prefix.rstrip("/")
    html_key = f"{key_prefix}/{session_id}.html"
    meta_key = f"{key_prefix}/{session_id}.meta.json"

    try:
        html_written = write_html_object(
            session_id, html_bytes,
            key_prefix=key_prefix, overwrite=args.overwrite, s3=s3,
        )
    except Exception as e:
        _stderr(f"R2 upload (html) failed: {e}")
        return 2
    _stderr(
        f"uploaded → {coords.endpoint}/{coords.bucket}/{html_key}"
        + ("" if html_written else " (ceded)")
    )

    metadata = compute_metadata(
        session_id, entries, session_url=session_url, url_source=url_source,
    )

    # Retry the sidecar upload — without it the list page's union-find
    # can't group rotation siblings (it joins on session_url /
    # first_user_uuid from the sidecar), so the row falls out as an
    # orphan "(no metadata)" entry. Boto3's max_attempts=3 covers
    # transient TLS/socket errors at the layer below; the loop here
    # covers errors that escape that (auth blips, brief endpoint
    # outages). Surface exit 2 if all three attempts fail rather than
    # silently absorbing — the Stop-hook caller logs the non-zero rc.
    last_err: Exception | None = None
    for attempt in range(3):
        try:
            meta_written = write_sidecar(
                session_id, metadata,
                key_prefix=key_prefix, overwrite=args.overwrite, s3=s3,
            )
            _stderr(
                f"uploaded → {coords.endpoint}/{coords.bucket}/{meta_key}"
                + ("" if meta_written else " (ceded)")
            )
            return 0
        except Exception as e:
            last_err = e
            _stderr(f"R2 upload (meta sidecar) attempt {attempt + 1}/3 failed: {e}")
            if attempt < 2:
                time.sleep(2 ** attempt)
    _stderr(f"R2 upload (meta sidecar) gave up after 3 attempts; last error: {last_err}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
