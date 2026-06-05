#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
"""
transcript-meta-backfill.py — coo-memory#243.

Real-meta-or-stub generator. The Stop hook (session-end-transcript-export.py)
writes <id>.meta.json locally but doesn't commit it; until coo-harness#148
Part A lands and is reliable, sessions can leave R2 ciphertext orphaned
from any sidecar in the agent-logs working tree. This script enumerates
R2 directly, finds session_ids without a sibling meta.json in
coo-logs/transcripts/<date>/, and writes a meta.json — using the
real meta embedded as R2 object-metadata when present (this PR), falling
back to a stub when not.

Pipeline per session_id:
  1. boto3 list_objects_v2 against the configured R2 prefix.
  2. For each ciphertext key transcripts/YYYY/MM/DD/<id>.jsonl.gz.age:
     - If the agent-logs working tree already holds a real meta.json
       at the same date-path, skip.
     - If a stub meta.json already exists (carrying _stub: true), skip.
     - head_object on the ciphertext: if `x-amz-meta-vade-meta-json`
       is present (export hook PRs since this one), parse and write
       the REAL meta with `_recovered_from_object_metadata: true`.
       Skip SHA recompute — the embedded ciphertext_sha256 is canonical.
     - Otherwise download the ciphertext, compute sha256, write a
       stub meta.json with the fields the analyzer reads (legacy path
       for sessions written before object-metadata embedding shipped).

The stub is intentionally shallow — the analyzer doesn't need
events_processed or bytes_post_redaction; it computes those itself
when it parses the redacted jsonl. The fields the analyzer DOES rely
on are r2.bucket / r2.key / r2.endpoint / r2.uploaded /
ciphertext_sha256 / age_recipient_pubkey, all populated here.

CLI:
  --date YYYY/MM/DD              process one R2 date prefix
  --session-id <id>              process exactly one session (locates
                                 R2 key by walking the prefix)
  --dry-run                      report what would be written without
                                 writing
  --agent-logs-dir <path>        override resolution (else ENV
                                 VADE_AGENT_LOGS_DIR or default candidates)

--date and --session-id are NOT mutually exclusive. At-least-one is required;
supplying both narrows the R2 prefix (--date) AND filters during iteration
(--session-id), which is cheaper than walking the whole bucket for a known
date+id pair. The coo-harness#150 PR body mis-stated this as mutually-
exclusive (refs coo-harness#151).

Env (exported by the bash wrapper's inline op-read resolver, mirroring
the export hook; Phase 2 — `~/.vade/coo-env` retired per coo-memory#873):
  R2_TRANSCRIPTS_ACCESS_KEY_ID / R2_TRANSCRIPTS_SECRET_ACCESS_KEY
Read at run time via `op read`:
  op://COO/r2-transcripts/endpoint
  op://COO/r2-transcripts/bucket
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PARSER_VERSION = 1
SCHEMA_VERSION = 1
SCRIPT_DIR = Path(__file__).resolve().parent
RUNTIME_ROOT = SCRIPT_DIR.parent.parent
RECIPIENT_FILE = RUNTIME_ROOT / "scripts" / "lib" / "transcripts-recipient.age"

R2_KEY_PATTERN = re.compile(
    r"^transcripts/(?P<date>\d{4}/\d{2}/\d{2})/(?P<sid>[A-Za-z0-9_\-]+)\.jsonl\.gz\.age$"
)


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[transcript-meta-backfill] {msg}\n")


def _resolve_agent_logs_dir(explicit: str | None) -> Path:
    if explicit:
        p = Path(explicit).expanduser()
        if p.is_dir():
            return p
        raise FileNotFoundError(f"--agent-logs-dir={p} does not exist")
    env = os.environ.get("VADE_AGENT_LOGS_DIR", "").strip()
    if env:
        p = Path(env)
        if p.is_dir():
            return p
        raise FileNotFoundError(f"VADE_AGENT_LOGS_DIR={p} does not exist")
    candidates = [
        Path.home() / "GitHub" / "coo-labs" / "coo-logs",
        Path("/home/user/coo-logs"),
        RUNTIME_ROOT.parent / "coo-logs",
    ]
    for c in candidates:
        if c.is_dir():
            return c
    raise FileNotFoundError(
        "coo-logs working tree not found; tried "
        + ", ".join(str(c) for c in candidates)
    )


def _op_read(ref: str) -> str:
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


def _r2_creds() -> tuple[str, str, str, str]:
    access_key = os.environ.get("R2_TRANSCRIPTS_ACCESS_KEY_ID", "").strip()
    secret_key = os.environ.get("R2_TRANSCRIPTS_SECRET_ACCESS_KEY", "").strip()
    if not access_key or not secret_key:
        raise RuntimeError(
            "R2_TRANSCRIPTS_ACCESS_KEY_ID / R2_TRANSCRIPTS_SECRET_ACCESS_KEY "
            "missing — ensure the bash wrapper ran its op-read resolver "
            "(Phase 2 post-coo-memory#873) or set both vars explicitly"
        )
    endpoint = _op_read("op://COO/r2-transcripts/endpoint")
    bucket = _op_read("op://COO/r2-transcripts/bucket")
    if not endpoint or not bucket:
        raise RuntimeError(
            "op://COO/r2-transcripts/{endpoint,bucket} unreadable — "
            "verify OP_SERVICE_ACCOUNT_TOKEN and 1Password provisioning"
        )
    return access_key, secret_key, endpoint, bucket


def _r2_client(access_key: str, secret_key: str, endpoint: str):
    import boto3
    from botocore.config import Config

    return boto3.client(
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


def _list_r2_keys(s3, bucket: str, prefix: str) -> list[dict]:
    """Return [{key, size, last_modified}, ...] under prefix."""
    out: list[dict] = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            out.append(
                {
                    "key": obj["Key"],
                    "size": obj["Size"],
                    "last_modified": obj["LastModified"],
                }
            )
    return out


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(64 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _read_recipient_pubkey() -> str:
    """Mirror of session-end-transcript-export._read_recipient_pubkey."""
    try:
        for line in reversed(RECIPIENT_FILE.read_text().splitlines()):
            s = line.strip()
            if s and not s.startswith("#"):
                return s
    except OSError:
        pass
    return ""


def _meta_already_present(sidecar_dir: Path, session_id: str) -> tuple[bool, str]:
    """Returns (skip, reason). Skip when a real or stub meta is already on disk."""
    meta_path = sidecar_dir / f"{session_id}.meta.json"
    if not meta_path.exists():
        return False, ""
    try:
        existing = json.loads(meta_path.read_text())
    except (OSError, json.JSONDecodeError):
        return True, "existing meta.json unparseable; refusing to overwrite"
    if existing.get("_stub") is True:
        return True, "stub already present"
    return True, "real meta.json already present"


def _r2_iter(date_filter: str | None, session_id_filter: str | None):
    """Yield (key, size, last_modified, date_path, sid) tuples that match
    the requested scope. `date_filter` is YYYY/MM/DD; `session_id_filter`
    is the bare session id (we walk the bucket and grep by sid)."""
    access_key, secret_key, endpoint, bucket = _r2_creds()
    s3 = _r2_client(access_key, secret_key, endpoint)

    if date_filter:
        prefix = f"transcripts/{date_filter}/"
    else:
        # Single-session search: walk the whole transcripts/ tree.
        # Bucket lifecycle keeps this small; if it grows we can add a
        # --window-days bound.
        prefix = "transcripts/"

    for entry in _list_r2_keys(s3, bucket, prefix):
        m = R2_KEY_PATTERN.match(entry["key"])
        if not m:
            continue
        date_path = m.group("date")
        sid = m.group("sid")
        if session_id_filter and sid != session_id_filter:
            continue
        yield (entry, date_path, sid, bucket, endpoint)


def _write_stub(
    sidecar_dir: Path,
    session_id: str,
    bucket: str,
    endpoint: str,
    r2_key: str,
    ciphertext_size: int,
    ciphertext_sha256: str,
    last_modified: datetime.datetime,
) -> Path:
    sidecar_dir.mkdir(parents=True, exist_ok=True)
    sidecar_path = sidecar_dir / f"{session_id}.meta.json"
    stub = {
        "_stub": True,
        "schema_version": SCHEMA_VERSION,
        "parser_version": PARSER_VERSION,
        "session_id": session_id,
        "exported_at": last_modified.astimezone(datetime.timezone.utc).isoformat(),
        "source_jsonl": None,
        "events_processed": None,
        "events_with_unparseable_json": None,
        "bytes_pre_redaction": None,
        "bytes_post_redaction": None,
        "bytes_post_gzip": None,
        "bytes_ciphertext": ciphertext_size,
        "ciphertext_sha256": ciphertext_sha256,
        "redaction_hits": None,
        "r2": {
            "bucket": bucket,
            "key": r2_key,
            "endpoint": endpoint,
            "uploaded": True,
        },
        "age_recipient_file": str(RECIPIENT_FILE.relative_to(RUNTIME_ROOT))
        if RECIPIENT_FILE.exists()
        else None,
        "age_recipient_pubkey": _read_recipient_pubkey(),
        "stub_generator": "coo-harness/scripts/lib/transcript-meta-backfill.py",
        "stub_generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    with open(sidecar_path, "w") as f:
        json.dump(stub, f, indent=2)
        f.write("\n")
    return sidecar_path


def _try_recover_real_meta_from_object_metadata(
    s3, bucket: str, key: str
) -> tuple[dict | None, str | None]:
    """HEAD the ciphertext key; if the export hook embedded the full
    meta as `x-amz-meta-vade-meta-json` (this PR), parse and return it.

    Returns (sidecar_dict, truncation_marker) on success, (None, None)
    when the metadata header is absent (legacy session). Raises only
    on non-recoverable parse errors so the caller can fall through to
    the stub path on missing-metadata, vs. surfacing on corruption.

    R2/S3 lowercases user-metadata keys on read.
    """
    head = s3.head_object(Bucket=bucket, Key=key)
    metadata = head.get("Metadata") or {}
    encoded = metadata.get("vade-meta-json")
    if not encoded:
        return None, None
    sidecar = json.loads(encoded)  # let JSONDecodeError propagate
    truncated = metadata.get("vade-meta-truncated")
    return sidecar, truncated


def _write_recovered(
    sidecar_dir: Path,
    session_id: str,
    sidecar: dict,
    truncated: str | None,
) -> Path:
    """Write a recovered-from-object-metadata sidecar to disk.

    Adds two forensic markers:
      - `_recovered_from_object_metadata: true`
      - `_object_metadata_truncated: <field>` when the export hook
        dropped a field to fit the 2 KB user-metadata cap.

    The dict is otherwise byte-identical to what the export hook would
    have written to flat-key + local sidecar — this is the REAL meta,
    not a stub. Distinguished from `_stub: true` for downstream forensics.
    """
    sidecar_dir.mkdir(parents=True, exist_ok=True)
    sidecar_path = sidecar_dir / f"{session_id}.meta.json"
    enriched = dict(sidecar)
    enriched["_recovered_from_object_metadata"] = True
    if truncated:
        enriched["_object_metadata_truncated"] = truncated
        # Synthesize the dropped field as an empty container so the
        # analyzer doesn't trip over a missing key.
        enriched.setdefault(
            truncated, {} if truncated == "redaction_hits" else None
        )
    enriched["recovered_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    enriched["recovery_source"] = "coo-harness/scripts/lib/transcript-meta-backfill.py"
    with open(sidecar_path, "w") as f:
        json.dump(enriched, f, indent=2)
        f.write("\n")
    return sidecar_path


def _backfill_one(
    entry: dict,
    date_path: str,
    session_id: str,
    bucket: str,
    endpoint: str,
    sidecar_dir: Path,
    s3,
    dry_run: bool,
) -> str:
    """Returns a one-line status string for the report."""
    skip, reason = _meta_already_present(sidecar_dir, session_id)
    if skip:
        return f"SKIP {date_path}/{session_id} ({reason})"

    # Tier 1 (this PR): try to recover the REAL meta from R2 object
    # metadata embedded by the export hook on the ciphertext PUT.
    # When present, this is byte-identical to what the export hook
    # would have written — preferred over stub generation, which loses
    # all the runtime telemetry (events_processed, bytes_*, redaction_hits).
    try:
        recovered, truncated = _try_recover_real_meta_from_object_metadata(
            s3, bucket, entry["key"]
        )
    except json.JSONDecodeError as e:
        return (
            f"FAIL {date_path}/{session_id} "
            f"object-metadata vade-meta-json unparseable: {e!r}"
        )
    if recovered is not None:
        if dry_run:
            return (
                f"DRY  {date_path}/{session_id} "
                "would write REAL meta from object-metadata"
                + (f" (truncated: {truncated})" if truncated else "")
            )
        sidecar = _write_recovered(sidecar_dir, session_id, recovered, truncated)
        return f"WROTE {date_path}/{session_id} ({sidecar}) [recovered from object-metadata]"

    # Tier 2 (legacy): no embedded meta — generate a stub from the
    # ciphertext bytes. Sessions written before object-metadata
    # embedding shipped, or sessions whose meta exceeded the 2 KB cap
    # entirely.
    if dry_run:
        return (
            f"DRY  {date_path}/{session_id} "
            f"would write stub ({entry['size']} bytes; no object-metadata)"
        )

    with tempfile.TemporaryDirectory(prefix=f"meta-backfill-{session_id}-") as tmp:
        ciphertext = Path(tmp) / f"{session_id}.jsonl.gz.age"
        s3.download_file(bucket, entry["key"], str(ciphertext))
        sha = _sha256(ciphertext)
        size = ciphertext.stat().st_size

    sidecar = _write_stub(
        sidecar_dir,
        session_id,
        bucket,
        endpoint,
        entry["key"],
        size,
        sha,
        entry["last_modified"],
    )
    return f"WROTE {date_path}/{session_id} ({sidecar}) [stub]"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="R2-first stub meta.json generator (coo-memory#243).",
    )
    parser.add_argument(
        "--date",
        help="R2 date prefix to process (YYYY/MM/DD).",
    )
    parser.add_argument(
        "--session-id",
        help="Process exactly one session_id (search the bucket for its key); "
        "may combine with --date to narrow the search to that date prefix.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report would-write actions without writing.",
    )
    parser.add_argument(
        "--agent-logs-dir",
        help="Override coo-logs working tree resolution.",
    )
    args = parser.parse_args(argv)

    if not args.date and not args.session_id:
        parser.error("either --date or --session-id is required")

    agent_logs_dir = _resolve_agent_logs_dir(args.agent_logs_dir)
    transcripts_root = agent_logs_dir / "transcripts"

    access_key, secret_key, endpoint, bucket = _r2_creds()
    s3 = _r2_client(access_key, secret_key, endpoint)

    seen = 0
    written = 0
    skipped = 0
    for entry, date_path, sid, _, _ in _r2_iter(args.date, args.session_id):
        seen += 1
        sidecar_dir = transcripts_root / date_path
        line = _backfill_one(
            entry, date_path, sid, bucket, endpoint, sidecar_dir, s3, args.dry_run
        )
        if line.startswith("WROTE"):
            written += 1
        elif line.startswith("DRY"):
            written += 1  # would-have-written
        else:
            skipped += 1
        print(line)

    print(
        f"\nsummary: seen={seen} written={written} skipped={skipped} "
        f"dry_run={args.dry_run}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
