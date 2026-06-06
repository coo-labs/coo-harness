#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
"""
integrity-check-e8-r2-orphan.py — R2 ciphertext-without-meta orphan probe.

Sibling to:
  - integrity-check-e7-r2-sha.py (#209) — SHA-mismatch detection.
  - the proposed E6 absence detector (#201) — total-loss-of-export.

E8 catches the **partial-export hazard**: an R2 ciphertext lands without
its `vade-meta-json` object metadata, leaving an orphan that fetch +
analyzer pipelines cannot decrypt without the meta sidecar.

Pre-coo-harness#216 this was the dominant failure mode of the
transcript-export saga (three known orphans on R2: session_ids
`8b2913a0-cd23-4f4d-bd67-35a91bce0009`,
`2a6cb65a-6d6d-4884-943a-b764cff4740e`,
`b43eda2e-6163-424e-b512-29b44f457912`). #216 collapsed body+meta
into one atomic PUT (object metadata via `x-amz-meta-vade-meta-json`),
so post-#216 sessions cannot produce orphans by construction. Per
MEMO-2026-05-04-mzeq principle 2 ("'closed' requires both a fix AND
a continuous detector"), this probe turns the structural argument
into substrate state.

Pipeline:
  1. List R2 objects under transcripts/<today>/ and transcripts/<yesterday>/
     (UTC date prefixes). Bucket layout is transcripts/YYYY/MM/DD/<id>.jsonl.gz.age.
  2. Filter to `.jsonl.gz.age` keys whose LastModified is within the last
     VADE_E8_WINDOW_H hours (default 24).
  3. Drop any key whose LastModified < VADE_E8_PRE_FIX_CUTOFF (cutoff
     defaults to coo-harness#216 merge time; pre-fix sessions cannot
     self-heal and aren't this detector's responsibility). The allowlist
     of 3 pre-#216 orphan session_ids is documentary — the cutoff does
     the actual filtering.
  4. For each surviving key, head_object and assert
     `Metadata.vade-meta-json` is present and JSON-parseable.

Output: a single JSON object on stdout
    {"ok": bool, "orphan_count": int, "checked_count": int, "detail": str}
Plus a one-line human summary on stderr.

Exits 0 always — the wrapper interprets `ok`. The wrapper also fences
on R2 creds + uv + timeout availability.

coo-harness#217 — E8 boot-time integrity invariant.
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

# Pre-#216 orphan session_ids (substring-matched against keys). These
# predate the embedding code and cannot self-heal; the cutoff +
# allowlist combination ensures they never trip the detector.
PRE_FIX_ORPHAN_SESSION_IDS = (
    "8b2913a0-cd23-4f4d-bd67-35a91bce0009",
    "2a6cb65a-6d6d-4884-943a-b764cff4740e",
    "b43eda2e-6163-424e-b512-29b44f457912",
)


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[integrity-check-e8] {msg}\n")


def _emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def _parse_iso(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def _date_prefixes(now: datetime) -> list[str]:
    """Return today's and yesterday's R2 prefixes in UTC."""
    today = now.strftime("transcripts/%Y/%m/%d/")
    yesterday = (now - timedelta(days=1)).strftime("transcripts/%Y/%m/%d/")
    # Order matters only for the stderr log; collapse duplicates if the
    # caller somehow runs at exactly midnight UTC with day-rollover edge.
    return list(dict.fromkeys([yesterday, today]))


def _is_allowlisted(key: str) -> bool:
    return any(sid in key for sid in PRE_FIX_ORPHAN_SESSION_IDS)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--window-h",
        type=int,
        default=int(os.environ.get("VADE_E8_WINDOW_H", "24")),
        help="Only inspect ciphertexts whose LastModified is within this "
        "many hours of now. Default 24 (also via VADE_E8_WINDOW_H).",
    )
    ap.add_argument(
        "--pre-fix-cutoff",
        default=os.environ.get(
            "VADE_E8_PRE_FIX_CUTOFF", "2026-05-04T07:30:00+00:00"
        ),
        help="ISO8601 timestamp; allowlisted session_ids whose LastModified "
        "is before this are excluded from the orphan count. Default "
        "2026-05-04T07:30:00Z (= coo-harness#216 merge time). Also "
        "via VADE_E8_PRE_FIX_CUTOFF.",
    )
    ap.add_argument("--verbose", action="store_true", help="Per-row detail to stderr.")
    args = ap.parse_args()

    try:
        coords = r2_coordinates()
    except R2Error as e:
        _emit(
            {
                "ok": True,
                "orphan_count": 0,
                "checked_count": 0,
                "detail": f"skip: {e}",
            }
        )
        return 0

    try:
        cutoff = _parse_iso(args.pre_fix_cutoff)
    except ValueError:
        _emit(
            {
                "ok": False,
                "orphan_count": 0,
                "checked_count": 0,
                "detail": f"invalid --pre-fix-cutoff: {args.pre_fix_cutoff}",
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
                "orphan_count": 0,
                "checked_count": 0,
                "detail": f"boto3 import failed: {e}",
            }
        )
        return 0

    s3 = r2_client(coords)
    bucket = coords.bucket
    now = datetime.now(timezone.utc)
    window_start = now - timedelta(hours=args.window_h)
    prefixes = _date_prefixes(now)

    candidates: list[tuple[str, datetime]] = []
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
                    # boto3 returns tz-aware datetimes for LastModified.
                    if last_modified < window_start:
                        continue
                    candidates.append((key, last_modified))
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "unknown")
            _stderr(f"list_objects_v2 ClientError on {prefix}: {code}")
            # Soft-fail: a transient list error shouldn't false-fire E8
            # in the wrapper. Report degraded so it's visible but don't
            # claim orphan_count > 0 we can't verify.
            _emit(
                {
                    "ok": False,
                    "orphan_count": 0,
                    "checked_count": 0,
                    "detail": f"list_objects_v2 failed on prefix {prefix}: {code}",
                }
            )
            return 0

    orphan_keys: list[str] = []
    checked_count = 0
    for key, last_modified in candidates:
        # Pre-fix cutoff: any key whose LastModified is before the cutoff
        # is a pre-#216 artifact and cannot self-heal — exclude regardless
        # of session_id. The allowlist constants document the canonical
        # known-orphan set for human readers; the cutoff is what does the
        # actual filtering.
        if last_modified < cutoff:
            if args.verbose:
                tag = "ALLOWLIST" if _is_allowlisted(key) else "PRE-FIX-CUTOFF"
                _stderr(f"{tag} {key} (LastModified={last_modified.isoformat()})")
            continue
        checked_count += 1
        try:
            head = s3.head_object(Bucket=bucket, Key=key)
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "unknown")
            _stderr(f"head_object ClientError on {key}: {code}")
            # Treat HEAD failure on a key we just listed as a probe error,
            # not an orphan finding. Return degraded with detail.
            _emit(
                {
                    "ok": False,
                    "orphan_count": 0,
                    "checked_count": checked_count,
                    "detail": f"head_object failed on {key}: {code}",
                }
            )
            return 0
        metadata = head.get("Metadata") or {}
        encoded = metadata.get("vade-meta-json")
        if not encoded:
            orphan_keys.append(key)
            if args.verbose:
                _stderr(f"ORPHAN {key}: vade-meta-json absent")
            continue
        try:
            json.loads(encoded)
        except json.JSONDecodeError:
            orphan_keys.append(key)
            if args.verbose:
                _stderr(f"ORPHAN {key}: vade-meta-json not JSON-parseable")
            continue
        if args.verbose:
            _stderr(f"OK {key}")

    orphan_count = len(orphan_keys)
    if orphan_count == 0:
        detail = (
            f"{checked_count}/{checked_count} post-#216 ciphertexts in last "
            f"{args.window_h}h carry vade-meta-json object metadata "
            f"(prefixes: {','.join(prefixes)})"
        )
        if checked_count == 0:
            detail = (
                f"no post-#216 ciphertexts in last {args.window_h}h to check "
                f"(prefixes: {','.join(prefixes)})"
            )
        _emit(
            {
                "ok": True,
                "orphan_count": 0,
                "checked_count": checked_count,
                "detail": detail,
            }
        )
        _stderr(detail)
        return 0

    # Cap the listed orphan keys in the detail string so a wide breach
    # doesn't blow out the integrity-check.json size budget.
    sample = ",".join(Path(k).name for k in orphan_keys[:5])
    if orphan_count > 5:
        sample += f",… (+{orphan_count - 5} more)"
    detail = (
        f"{orphan_count}/{checked_count} post-#216 ciphertexts in last "
        f"{args.window_h}h missing or invalid vade-meta-json: {sample}"
    )
    _emit(
        {
            "ok": False,
            "orphan_count": orphan_count,
            "checked_count": checked_count,
            "detail": detail,
        }
    )
    _stderr(detail)
    return 0


if __name__ == "__main__":
    sys.exit(main())
