#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
"""
list-r2-transcripts.py — coo-memory#499.

Print R2 transcript keys under a given prefix, one per line (text mode)
or as a JSON array of {key, size, last_modified} (--json mode).

Reads R2 credentials and bucket coordinates from 1Password
(`op read op://COO/r2-transcripts/{endpoint,bucket}`) and the env vars
`R2_TRANSCRIPTS_ACCESS_KEY_ID` / `R2_TRANSCRIPTS_SECRET_ACCESS_KEY`,
matching `transcript-meta-backfill.py`'s helper functions.

Why a separate script: the nightly task previously inlined the R2
enumeration as a `python3 - <<PY` heredoc with a bare `import boto3`,
which fails because the ambient Python lacks boto3 (vrt#203 only
prewarms uv's cache). Calling this script via the shebang
(`#!/usr/bin/env -S uv run --script`) routes through uv with the
PEP-723 deps block, so boto3 resolves cleanly.

Usage:
  list-r2-transcripts.py transcripts/2026/05/06/
  list-r2-transcripts.py --json transcripts/2026/05/06/
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys


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


def list_keys(prefix: str) -> list[dict]:
    access_key, secret_key, endpoint, bucket = _r2_creds()
    s3 = _r2_client(access_key, secret_key, endpoint)
    out: list[dict] = []
    for page in s3.get_paginator("list_objects_v2").paginate(
        Bucket=bucket, Prefix=prefix
    ):
        for obj in page.get("Contents", []):
            out.append(
                {
                    "key": obj["Key"],
                    "size": obj["Size"],
                    "last_modified": obj["LastModified"].isoformat(),
                }
            )
    return out


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument(
        "prefix",
        help="R2 key prefix, e.g. transcripts/2026/05/06/",
    )
    p.add_argument(
        "--json",
        action="store_true",
        help="emit JSON array of {key, size, last_modified}",
    )
    args = p.parse_args()

    keys = list_keys(args.prefix)
    if args.json:
        json.dump(keys, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        for k in keys:
            print(k["key"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
