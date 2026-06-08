"""R2 client + credential plumbing + sidecar I/O primitives.

Consolidates the _op_read / _r2_creds / _r2_client / list_keys quartet that was
copy-pasted across scripts/lib/list-r2-transcripts.py, scripts/lib/transcript-
meta-backfill.py, scripts/lib/transcript-fetch.py, and the lifecycle scripts.

Credentials sourced from:
  - env: R2_TRANSCRIPTS_ACCESS_KEY_ID, R2_TRANSCRIPTS_SECRET_ACCESS_KEY
  - 1Password: op://COO/r2-transcripts/{endpoint,bucket}

boto3 is imported lazily inside r2_client because the type stubs aren't
universally available and we want the package importable without boto3 for
pure-schema consumers (the coo-console worker hypothetically, the test
harness in CI before deps are installed).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mypy_boto3_s3.client import S3Client
else:
    S3Client = Any


class R2Error(RuntimeError):
    """Raised on R2 credential / coordinate resolution failures."""


@dataclass(frozen=True)
class R2Coordinates:
    """Resolved R2 access tuple — credentials + endpoint + bucket name.

    access_key / secret_key are excluded from repr() so the credentials don't
    leak via tracebacks, debug logs, or pytest assert-diff output. Equality
    still uses all four fields so the test round-trip assertion holds.
    """

    access_key: str = field(repr=False)
    secret_key: str = field(repr=False)
    endpoint: str
    bucket: str


def _op_read(ref: str) -> str:
    """Read a 1Password secret by op-reference. Returns "" on any failure.

    Intentionally swallows errors — callers check the empty string and raise
    a domain-specific error with full context. This matches the existing
    scripts' behavior so the consolidated primitive is drop-in compatible.
    """
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


def r2_coordinates() -> R2Coordinates:
    """Resolve R2 credentials + endpoint + bucket from env + 1Password.

    Raises R2Error with a remediation-pointing message on any missing piece.
    """
    access_key = os.environ.get("R2_TRANSCRIPTS_ACCESS_KEY_ID", "").strip()
    secret_key = os.environ.get("R2_TRANSCRIPTS_SECRET_ACCESS_KEY", "").strip()
    if not access_key or not secret_key:
        raise R2Error(
            "R2_TRANSCRIPTS_ACCESS_KEY_ID / R2_TRANSCRIPTS_SECRET_ACCESS_KEY "
            "missing — ensure the bash wrapper ran its op-read resolver "
            "(Phase 2 post-coo-memory#873) or set both vars explicitly"
        )
    endpoint = _op_read("op://COO/r2-transcripts/endpoint")
    bucket = _op_read("op://COO/r2-transcripts/bucket")
    if not endpoint or not bucket:
        raise R2Error(
            "op://COO/r2-transcripts/{endpoint,bucket} unreadable — "
            "verify OP_SERVICE_ACCOUNT_TOKEN and 1Password provisioning"
        )
    return R2Coordinates(
        access_key=access_key,
        secret_key=secret_key,
        endpoint=endpoint,
        bucket=bucket,
    )


def r2_client(coords: R2Coordinates | None = None) -> S3Client:
    """Build a boto3 S3 client wired for Cloudflare R2.

    If coords is None, calls r2_coordinates() to resolve them. boto3 imported
    lazily so the package is importable without boto3 installed.
    """
    if coords is None:
        coords = r2_coordinates()
    import boto3  # noqa: PLC0415 — lazy by design
    from botocore.config import Config  # noqa: PLC0415

    return boto3.client(
        "s3",
        endpoint_url=coords.endpoint,
        aws_access_key_id=coords.access_key,
        aws_secret_access_key=coords.secret_key,
        region_name="auto",
        config=Config(
            signature_version="s3v4",
            retries={"max_attempts": 3, "mode": "standard"},
        ),
    )


def list_keys(prefix: str, s3: S3Client | None = None) -> list[dict[str, Any]]:
    """Paginated list_objects_v2 under a prefix. Returns list of
    {key, size, last_modified} dicts (last_modified ISO-formatted).
    """
    coords: R2Coordinates | None = None
    if s3 is None:
        coords = r2_coordinates()
        s3 = r2_client(coords)
    bucket = coords.bucket if coords else _bucket_from_env_or_op()
    out: list[dict[str, Any]] = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            out.append(
                {
                    "key": obj["Key"],
                    "size": obj["Size"],
                    "last_modified": obj["LastModified"].isoformat(),
                }
            )
    return out


def _bucket_from_env_or_op() -> str:
    """Bucket name only — used when a caller passed their own s3 client.

    A caller that brings its own boto3 client still needs to tell us which
    bucket; we re-resolve it rather than threading it through every call site.
    Env-first because CI populates R2_TRANSCRIPTS_BUCKET via
    1password/load-secrets-action but the `op` CLI is gone from PATH after the
    action's tempdir is torn down.
    """
    bucket = os.environ.get("R2_TRANSCRIPTS_BUCKET", "").strip()
    if bucket:
        return bucket
    bucket = _op_read("op://COO/r2-transcripts/bucket")
    if not bucket:
        raise R2Error(
            "bucket name unresolvable via env (R2_TRANSCRIPTS_BUCKET) or 1Password"
        )
    return bucket


def read_sidecar(
    session_id: str,
    *,
    key_prefix: str = "rendered",
    s3: S3Client | None = None,
) -> dict[str, Any] | None:
    """Fetch and JSON-decode rendered/<key_prefix>/<sid>.meta.json from R2.

    Returns None on NoSuchKey (sidecar not yet written). Raises on any other
    boto3 error so callers don't conflate "missing" with "broken".
    """
    if s3 is None:
        s3 = r2_client()
    bucket = _bucket_from_env_or_op()
    key = f"{key_prefix}/{session_id}.meta.json"
    try:
        obj = s3.get_object(Bucket=bucket, Key=key)
    except Exception as e:
        if _is_no_such_key(e):
            return None
        raise
    body = obj["Body"].read()
    parsed = json.loads(body)
    if not isinstance(parsed, dict):
        raise R2Error(
            f"malformed sidecar at {key}: expected JSON object, got {type(parsed).__name__}"
        )
    return parsed


def _is_no_such_key(e: BaseException) -> bool:
    """True if a boto3-raised exception means 'the key does not exist'.

    botocore raises ClientError whose `response['Error']['Code']` is the
    canonical surface ('NoSuchKey' for missing keys); boto3 also exposes typed
    subclasses like s3.exceptions.NoSuchKey whose class name matches. Check
    both. Duck-typed on `.response` so we don't have to import botocore here.
    """
    response = getattr(e, "response", None)
    if isinstance(response, dict):
        code = response.get("Error", {}).get("Code", "")
        if code in {"NoSuchKey", "404"}:
            return True
    return type(e).__name__ == "NoSuchKey"


SIDECAR_CACHE_CONTROL = "private, max-age=0, must-revalidate"
SIDECAR_CONTENT_TYPE = "application/json; charset=utf-8"
HTML_CONTENT_TYPE = "text/html; charset=utf-8"


def write_html_object(
    session_id: str,
    html_bytes: bytes,
    *,
    key_prefix: str = "rendered",
    overwrite: bool = False,
    s3: S3Client | None = None,
) -> bool:
    """Upload rendered HTML to R2 at <key_prefix>/<sid>.html.

    Sibling of write_sidecar — same cede semantics, same atomic-create
    discipline (IfNoneMatch="*" when overwrite=False), same cache-control
    headers. Used by the events-API backfill driver and (Phase 1 port) by
    the existing render-backfill script.
    """
    if s3 is None:
        s3 = r2_client()
    bucket = _bucket_from_env_or_op()
    key = f"{key_prefix}/{session_id}.html"
    put_kwargs: dict[str, Any] = {
        "Bucket": bucket,
        "Key": key,
        "Body": html_bytes,
        "ContentType": HTML_CONTENT_TYPE,
        "CacheControl": SIDECAR_CACHE_CONTROL,
    }
    if not overwrite:
        put_kwargs["IfNoneMatch"] = "*"
    try:
        s3.put_object(**put_kwargs)
    except Exception as e:
        if not overwrite and _is_precondition_failed(e):
            return False
        raise
    return True


def write_sidecar(
    session_id: str,
    sidecar: dict[str, Any],
    *,
    key_prefix: str = "rendered",
    overwrite: bool = False,
    s3: S3Client | None = None,
) -> bool:
    """Upload a sidecar dict to R2 at <key_prefix>/<sid>.meta.json.

    Returns True on write success, False if the write was ceded because the
    key already existed and overwrite=False. Caller decides what to do with
    the cede — typically: re-fetch with read_sidecar, run the
    provenance.is_authoritative guard, and either skip or write with
    overwrite=True after the read-check-write merge.

    Production semantics this primitive enforces (parity with
    scripts/lifecycle/session-end-transcript-render.py:_r2_put_bytes and
    scripts/transcript-url-backfill.py:_patch_one):
      - CacheControl="private, max-age=0, must-revalidate" — sidecars carry
        session_url + first_user_preview, must NOT be cached at CDN/edge.
      - IfNoneMatch="*" on first-write — atomic-create discipline from
        MEMO-2026-05-03-bgk3 / coo-harness#204. 412 PreconditionFailed maps
        to a clean ceded outcome.
      - Minified JSON (separators=(",", ":")) + charset=utf-8 — keeps the
        body under the 2KB user-metadata cap used by the embedded-meta
        durability tier (see scripts/lib/transcript-fetch.py:233-249).
    """
    if s3 is None:
        s3 = r2_client()
    bucket = _bucket_from_env_or_op()
    key = f"{key_prefix}/{session_id}.meta.json"
    body = json.dumps(sidecar, separators=(",", ":")).encode("utf-8")
    put_kwargs: dict[str, Any] = {
        "Bucket": bucket,
        "Key": key,
        "Body": body,
        "ContentType": SIDECAR_CONTENT_TYPE,
        "CacheControl": SIDECAR_CACHE_CONTROL,
    }
    if not overwrite:
        put_kwargs["IfNoneMatch"] = "*"
    try:
        s3.put_object(**put_kwargs)
    except Exception as e:
        if not overwrite and _is_precondition_failed(e):
            return False
        raise
    return True


def _is_precondition_failed(e: BaseException) -> bool:
    """True if a boto3-raised exception means 'the conditional write failed'.

    botocore raises ClientError with `response['Error']['Code']` of
    'PreconditionFailed' for IfNoneMatch="*" on an existing key.
    """
    response = getattr(e, "response", None)
    if isinstance(response, dict):
        code = response.get("Error", {}).get("Code", "")
        if code in {"PreconditionFailed", "412"}:
            return True
    return type(e).__name__ == "PreconditionFailed"
