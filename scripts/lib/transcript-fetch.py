#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
"""
transcript-fetch.py — coo-labs/coo-logs#64 Batch 3.

Pair to session-end-transcript-export.py. Given a session_id, fetches
the encrypted ciphertext from R2, verifies its sha256 against the
sidecar's ciphertext_sha256, decrypts via TRANSCRIPTS_AGE_IDENTITY,
gunzips, and prints the absolute path to the redacted jsonl on stdout.

Designed for the Stage-1 transcript-analyzer sub-agent
(`.claude/agents/transcript-analyzer.md` in coo-memory) but
works as a standalone debugging CLI too.

Usage:
  bash scripts/lib/transcript-fetch.sh <session_id> [--meta <path>] \\
       [--on-mismatch={fail,skip,warn-decrypt}]
  bash scripts/lib/transcript-fetch.sh --cleanup <jsonl_path>

Meta resolution order (when --meta is omitted):
  1. coo-logs/transcripts/**/<id>.meta.json walk (fast local path).
  2. R2 GetObject at transcripts/meta/<id>.meta.json (coo-harness#207
     fix shape (b), 2026-05-03 — flat-key fast-resolve index;
     best-effort secondary post-this-PR).
  3. R2 list_objects_v2 + head_object on the ciphertext: parse the
     embedded `x-amz-meta-vade-meta-json` user-metadata value
     (this PR — atomic body+meta single-PUT eliminates the cross-PUT
     SIGKILL window that left tier 2 sessions orphaned in
     2026-05-03 round-2 verification). Slower (one list + one head)
     but always works for any session whose ciphertext landed.

The decrypted jsonl is written to a per-invocation temp file under
$HOME/.vade/transcript-cache/. Callers should `--cleanup` it when
done — otherwise the OS rotates /tmp on its own schedule and the
cache directory can accumulate. Per the security review for #64,
decrypted jsonl is "strictly more revealing than session summaries"
and should not sit on disk indefinitely.

Required env (exported by the bash wrapper's inline op-read resolver;
Phase 2 — `~/.vade/coo-env` retired per coo-memory#873):
  R2_TRANSCRIPTS_ACCESS_KEY_ID, R2_TRANSCRIPTS_SECRET_ACCESS_KEY
  TRANSCRIPTS_AGE_IDENTITY      — full AGE-SECRET-KEY-1... line
Read at run time via op (no env exposure):
  op://COO/r2-transcripts/endpoint, /bucket

Exits non-zero on any failure with a diagnostic to stderr. Unlike the
export hook (which never blocks session end), this script is invoked
synchronously by the analyzer and surfaces failure to the caller so
the caller can decide whether to retry or skip.

Mismatch policy (coo-harness#210, 2026-05-03):
  --on-mismatch=fail (default) — raise + exit 1 (pre-#210 behavior).
  --on-mismatch=skip            — log + empty stdout + exit 0; sweep
                                  callers detect skip via empty stdout.
  --on-mismatch=warn-decrypt    — log + decrypt anyway; age's
                                  authenticated decryption is the
                                  secondary integrity check.
"""

from __future__ import annotations

import argparse
import datetime
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CACHE_DIR = Path.home() / ".vade" / "transcript-cache"


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[transcript-fetch] {msg}\n")


def _resolve_agent_logs_dir() -> Path:
    """Mirror of session-end-transcript-export's resolver."""
    explicit = os.environ.get("VADE_AGENT_LOGS_DIR", "").strip()
    if explicit:
        p = Path(explicit)
        if p.is_dir():
            return p
        raise FileNotFoundError(f"VADE_AGENT_LOGS_DIR={p} does not exist")

    candidates = [
        Path.home() / "GitHub" / "coo-labs" / "coo-logs",
        Path("/home/user/coo-logs"),
    ]
    for c in candidates:
        if c.is_dir():
            return c
    raise FileNotFoundError(
        "coo-logs working tree not found; tried "
        + ", ".join(str(c) for c in candidates)
    )


def _find_meta(session_id: str) -> Path:
    """Walk coo-logs/transcripts/**/<id>.meta.json."""
    root = _resolve_agent_logs_dir() / "transcripts"
    if not root.is_dir():
        raise FileNotFoundError(f"transcripts dir missing: {root}")
    matches = list(root.glob(f"**/{session_id}.meta.json"))
    if not matches:
        raise FileNotFoundError(
            f"no meta.json for session_id={session_id} under {root}"
        )
    if len(matches) > 1:
        # Should not happen — session_ids are UUIDs. Surface and pick newest.
        _stderr(f"WARN: {len(matches)} meta.json matches; picking newest by mtime")
        matches.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return matches[0]


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


def _r2_client(endpoint: str):
    """Build an R2 boto3 client for the transcripts bucket. Caller passes
    the endpoint (already resolved via op or otherwise) so this function
    has no implicit 1Password dependency — important for the
    R2-meta-fallback path which needs to fetch meta before any sidecar
    is parsed."""
    access_key = os.environ.get("R2_TRANSCRIPTS_ACCESS_KEY_ID", "").strip()
    secret_key = os.environ.get("R2_TRANSCRIPTS_SECRET_ACCESS_KEY", "").strip()
    if not access_key or not secret_key:
        raise RuntimeError(
            "R2_TRANSCRIPTS_ACCESS_KEY_ID / R2_TRANSCRIPTS_SECRET_ACCESS_KEY "
            "missing — fetch_coo_secrets did not populate them"
        )

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


def _r2_download(bucket: str, key: str, endpoint: str, dst: Path) -> None:
    s3 = _r2_client(endpoint)
    s3.download_file(bucket, key, str(dst))


def _find_ciphertext_key_by_session_id(s3, bucket: str, session_id: str) -> str | None:
    """List `transcripts/` and return the first ciphertext key whose
    filename matches `<session_id>.jsonl.gz.age`. Returns None if no
    such key exists.

    Used by the object-metadata fallback tier (this PR). Bucket
    lifecycle keeps the listed surface bounded; if it grows we can
    add a `--window-days` bound by walking date prefixes instead.
    """
    suffix = f"/{session_id}.jsonl.gz.age"
    for page in s3.get_paginator("list_objects_v2").paginate(
        Bucket=bucket, Prefix="transcripts/"
    ):
        for obj in page.get("Contents", []):
            if obj["Key"].endswith(suffix):
                return obj["Key"]
    return None


def _fetch_meta_from_r2_object_metadata(
    s3, bucket: str, session_id: str
) -> dict | None:
    """Tier 3: list R2 for the ciphertext, head_object, parse the
    embedded `vade-meta-json` user-metadata value.

    Returns parsed sidecar dict on success, None when no ciphertext
    exists for `session_id` or no embedded meta is present (caller
    raises FileNotFoundError after exhausting all tiers).

    R2/S3 lowercases user-metadata keys on read, so we look up the
    lowercase form. If the export script truncated `redaction_hits`
    to fit the 2 KB user-metadata cap, the marker key
    `vade-meta-truncated` carries the dropped field name.
    """
    ciphertext_key = _find_ciphertext_key_by_session_id(s3, bucket, session_id)
    if not ciphertext_key:
        return None
    head = s3.head_object(Bucket=bucket, Key=ciphertext_key)
    metadata = head.get("Metadata") or {}
    encoded = metadata.get("vade-meta-json")
    if not encoded:
        return None
    try:
        sidecar = json.loads(encoded)
    except json.JSONDecodeError as e:
        raise RuntimeError(
            f"R2 object-metadata vade-meta-json on {ciphertext_key} "
            f"is not valid JSON: {e!r}"
        ) from e
    truncated = metadata.get("vade-meta-truncated")
    if truncated:
        # Synthesize the dropped field as empty so downstream consumers
        # don't blow up on KeyError. The flat-key + sidecar tiers carry
        # the un-truncated copy if the operator needs full data.
        sidecar.setdefault(truncated, {} if truncated == "redaction_hits" else None)
        sidecar["_object_metadata_truncated"] = truncated
    sidecar["_recovered_from_object_metadata"] = True
    return sidecar


def _fetch_meta_from_r2(session_id: str) -> dict:
    """Resolve meta.json for `session_id` directly from R2.

    Two tiers (coo-logs walk is upstream of this function):
      a. flat-key GET at `transcripts/meta/<id>.meta.json` — fast,
         single GetObject; populated by the export hook's secondary
         meta PUT (post-#215). Best-effort.
      b. object-metadata HEAD on the ciphertext (this PR): list
         `transcripts/` for the session's `.jsonl.gz.age`, head_object,
         parse the embedded `vade-meta-json`. Slower (one list + one
         head) but is the canonical durability path — the export hook
         embeds meta on the ciphertext PUT itself, so any session whose
         ciphertext landed has meta here regardless of whether tier (a)
         succeeded.

    Returns the parsed sidecar dict; raises FileNotFoundError if
    neither tier resolves.
    """
    endpoint = _op_read("op://COO/r2-transcripts/endpoint")
    bucket = _op_read("op://COO/r2-transcripts/bucket")
    if not endpoint or not bucket:
        raise RuntimeError(
            "R2 endpoint or bucket not readable from "
            "op://COO/r2-transcripts/{endpoint,bucket}"
        )

    meta_key = f"transcripts/meta/{session_id}.meta.json"
    s3 = _r2_client(endpoint)
    try:
        obj = s3.get_object(Bucket=bucket, Key=meta_key)
    except Exception as flatkey_err:
        # Tier (a) miss — fall through to tier (b).
        _stderr(
            f"flat-key meta GET miss ({meta_key!r}); "
            "falling through to object-metadata on the ciphertext"
        )
        sidecar = _fetch_meta_from_r2_object_metadata(s3, bucket, session_id)
        if sidecar is None:
            raise FileNotFoundError(
                f"meta.json not resolvable for session_id={session_id} on R2: "
                f"flat-key {meta_key!r} miss ({flatkey_err!r}); "
                "no ciphertext with embedded vade-meta-json found either"
            ) from flatkey_err
        return sidecar

    body = obj["Body"].read()
    try:
        return json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise RuntimeError(
            f"R2 meta at {meta_key} not valid utf-8 JSON: {e!r}"
        ) from e


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(64 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _age_decrypt(ciphertext: Path, dst_gz: Path) -> None:
    identity = os.environ.get("TRANSCRIPTS_AGE_IDENTITY", "").strip()
    if not identity:
        raise RuntimeError(
            "TRANSCRIPTS_AGE_IDENTITY missing — op://COO/transcripts-age-key/credential "
            "may not have been provisioned (see fetch_coo_secrets WARN at bootstrap)"
        )
    if not identity.startswith("AGE-SECRET-KEY-1"):
        raise RuntimeError(
            "TRANSCRIPTS_AGE_IDENTITY does not look like an age identity "
            "(expected leading 'AGE-SECRET-KEY-1')"
        )
    if not shutil.which("age"):
        raise RuntimeError("age binary not on PATH")

    # Write identity to a per-invocation tempfile (chmod 0600), invoke age,
    # then explicitly remove. Identity must not leak via process listing
    # so we don't pass it on argv.
    fd, id_path_str = tempfile.mkstemp(prefix="transcript-age-id-", suffix=".key")
    id_path = Path(id_path_str)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(identity)
            if not identity.endswith("\n"):
                f.write("\n")
        subprocess.run(
            ["age", "-d", "-i", str(id_path), "-o", str(dst_gz), str(ciphertext)],
            check=True,
        )
    finally:
        try:
            id_path.unlink(missing_ok=True)
        except OSError:
            pass


def _gunzip(src: Path, dst: Path) -> None:
    with gzip.open(src, "rb") as fin, open(dst, "wb") as fout:
        shutil.copyfileobj(fin, fout)


ON_MISMATCH_CHOICES = ("fail", "skip", "warn-decrypt")


def _fetch(
    session_id: str,
    meta_arg: str | None,
    on_mismatch: str = "fail",
) -> Path | None:
    """Fetch + decrypt a session jsonl from R2.

    Returns the cache path on success, None when the SHA mismatched and
    `on_mismatch="skip"` (caller treats as quarantine).

    `on_mismatch` policy (coo-harness#210):
      - "fail" (default): raise RuntimeError, preserving the
        pre-#210 hard-bail contract for callers that need pre-decrypt
        integrity (the original Batch-3 spec).
      - "skip": log mismatch to stderr, return None. Caller continues
        with other sessions. Used by Night's Watch / Weekly Watch
        sweeps where one bad session shouldn't block the rest.
      - "warn-decrypt": log mismatch, attempt decrypt anyway. age
        decryption is authenticated (Poly1305 over the ciphertext +
        AEAD frame); a non-authentic ciphertext will still fail at
        the age step, so this policy only succeeds when the SHA
        record is stale relative to the canonical R2 bytes — useful
        for forensic / manual-recovery flows that need decrypted
        content even when the meta.json's SHA is known-drifted
        (coo-harness#204 historical population).
    """
    if on_mismatch not in ON_MISMATCH_CHOICES:
        raise ValueError(
            f"on_mismatch={on_mismatch!r} not in {ON_MISMATCH_CHOICES}"
        )

    if meta_arg:
        meta_path = Path(meta_arg)
        if not meta_path.is_file():
            raise FileNotFoundError(f"meta.json not found at {meta_path}")
        meta = json.loads(meta_path.read_text())
    else:
        # Try coo-logs first (fast local file walk); fall back to
        # R2 GetObject when the local walk misses. Post-#207 fix shape (b)
        # made R2 the canonical durable record; the coo-logs copy
        # is best-effort secondary, so the R2 fallback is required for
        # any session whose auto-PR chain failed.
        try:
            meta_path = _find_meta(session_id)
            meta = json.loads(meta_path.read_text())
        except FileNotFoundError as local_err:
            _stderr(
                f"meta not in coo-logs ({local_err}); "
                "falling back to R2 (post-#207 canonical record)"
            )
            meta = _fetch_meta_from_r2(session_id)

    if meta.get("session_id") != session_id:
        raise RuntimeError(
            f"meta.session_id={meta.get('session_id')!r} does not match arg {session_id!r}"
        )

    r2 = meta.get("r2") or {}
    if not r2.get("uploaded"):
        raise RuntimeError(
            f"meta.r2.uploaded is false for session_id={session_id} "
            "— ciphertext was never pushed to R2; nothing to fetch"
        )

    bucket = r2.get("bucket", "").strip()
    key = r2.get("key", "").strip()
    if not bucket or not key:
        raise RuntimeError(f"meta.r2.bucket / key missing on {meta_path}")

    endpoint = _op_read("op://COO/r2-transcripts/endpoint")
    if not endpoint:
        raise RuntimeError(
            "R2 endpoint not readable from op://COO/r2-transcripts/endpoint "
            "(op CLI absent or 1Password slot empty)"
        )

    expected_sha = (meta.get("ciphertext_sha256") or "").strip().lower()
    if not expected_sha:
        raise RuntimeError(f"meta.ciphertext_sha256 missing on {meta_path}")

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=f"transcript-fetch-{session_id}-", dir=str(CACHE_DIR)
    ) as tmp:
        tmp_path = Path(tmp)
        ciphertext = tmp_path / f"{session_id}.jsonl.gz.age"
        gz = tmp_path / f"{session_id}.jsonl.gz"

        _r2_download(bucket, key, endpoint, ciphertext)

        actual_sha = _sha256(ciphertext)
        if actual_sha != expected_sha:
            mismatch_msg = (
                f"ciphertext_integrity_mismatch: meta sha256={expected_sha} "
                f"download sha256={actual_sha} key={key}"
            )
            if on_mismatch == "fail":
                raise RuntimeError(mismatch_msg)
            if on_mismatch == "skip":
                _stderr(f"{mismatch_msg} — skipping (--on-mismatch=skip)")
                return None
            # warn-decrypt: log + fall through to age step. age's
            # authenticated decryption is the second integrity layer;
            # a non-authentic ciphertext will still fail at `age -d`.
            _stderr(
                f"{mismatch_msg} — proceeding to decrypt (--on-mismatch=warn-decrypt); "
                "age authenticated-decryption is the integrity check from here"
            )

        _age_decrypt(ciphertext, gz)

        # Final destination: stable per-session cache path. Caller cleans up.
        out = CACHE_DIR / f"{session_id}.jsonl"
        _gunzip(gz, out)

    return out


def _cleanup(jsonl_arg: str) -> None:
    p = Path(jsonl_arg).resolve()
    cache = CACHE_DIR.resolve()
    if cache not in p.parents and p.parent != cache:
        raise RuntimeError(
            f"refusing to cleanup path outside cache dir: path={p} cache={cache}"
        )
    if p.exists():
        p.unlink()
        _stderr(f"removed {p}")
    else:
        _stderr(f"not present (already cleaned?): {p}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="transcript-fetch",
        description="Fetch + decrypt + gunzip a redacted Claude Code session jsonl from R2.",
    )
    parser.add_argument(
        "session_id",
        nargs="?",
        help="Session UUID (matches the meta.json filename). Omit when using --cleanup.",
    )
    parser.add_argument(
        "--meta",
        help="Path to the meta.json sidecar (default: walk coo-logs/transcripts/**).",
    )
    parser.add_argument(
        "--cleanup",
        help="Delete the named cached jsonl path (must live under ~/.vade/transcript-cache/).",
    )
    parser.add_argument(
        "--on-mismatch",
        choices=ON_MISMATCH_CHOICES,
        default="fail",
        help=(
            "Policy when meta.json's ciphertext_sha256 does not match the "
            "downloaded R2 object: 'fail' (default; pre-#210 behavior — "
            "raise + non-zero exit), 'skip' (log + empty stdout + exit 0; "
            "for sweep callers that quarantine and continue), 'warn-decrypt' "
            "(log + decrypt anyway; age's authenticated decryption is the "
            "secondary integrity check). Refs coo-harness#210."
        ),
    )
    args = parser.parse_args(argv)

    if args.cleanup:
        try:
            _cleanup(args.cleanup)
        except Exception as e:
            _stderr(f"cleanup failed: {e}")
            return 1
        return 0

    if not args.session_id:
        parser.error("session_id is required unless --cleanup is given")

    try:
        out = _fetch(args.session_id, args.meta, args.on_mismatch)
    except Exception as e:
        _stderr(f"fetch failed: {e}")
        return 1

    if out is None:
        # Skipped under --on-mismatch=skip. Empty stdout, exit 0 — caller
        # detects skip via empty stdout. Stderr has the mismatch detail.
        return 0
    sys.stdout.write(f"{out}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
