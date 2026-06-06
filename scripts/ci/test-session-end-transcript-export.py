#!/usr/bin/env python3
"""Smoke test for the lib-ported session-end-transcript-export.py.

The Stop-hook script ports its R2 credential plumbing to
`from transcripts import r2_coordinates, r2_client` per
coo-labs/coo-memory#1147. This test exercises the surviving inlined
helpers against boto3-shaped fakes:

  - `_encode_meta_for_object_metadata` — pure: covers the full-encode,
    drop-redaction-hits truncation, and None-on-overflow branches.
  - `_r2_upload` — verifies the IfNoneMatch="*" + Metadata=... PUT shape,
    the ceded=True return on PreconditionFailed, the ceded=False on
    success, and that the file is read from the passed Path.
  - `_r2_head_object_metadata` — returns dict on success, None on
    head_object failure (the cede-branch recovery path).

No live R2. No `op` calls. Stop-hook semantics (gzip/age/sha256/redaction)
are out of scope — those are tested separately by the redact engine
suite. This is the lib-port parity layer.

Exits 0 on full parity, 1 on any divergence.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
LIB_DIR = REPO_ROOT / "lib"
SCRIPT = REPO_ROOT / "scripts" / "lifecycle" / "session-end-transcript-export.py"

sys.path.insert(0, str(LIB_DIR))


def _load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeClientError(Exception):
    def __init__(self, code: str, status: int) -> None:
        super().__init__(code)
        self.response = {
            "Error": {"Code": code},
            "ResponseMetadata": {"HTTPStatusCode": status},
        }


class FakeS3:
    """Records put_object calls; can be primed to raise on a specific key."""

    def __init__(self, raise_on_keys: dict[str, FakeClientError] | None = None,
                 head_metadata: dict[str, dict[str, str]] | None = None) -> None:
        self.puts: list[dict[str, Any]] = []
        self.raise_on_keys = raise_on_keys or {}
        self.head_metadata = head_metadata or {}

    def put_object(self, *, Bucket: str, Key: str, Body: Any, **kw: Any) -> dict[str, Any]:
        if Key in self.raise_on_keys:
            raise self.raise_on_keys[Key]
        self.puts.append(
            {
                "Bucket": Bucket,
                "Key": Key,
                "Body": Body.read() if hasattr(Body, "read") else Body,
                **kw,
            }
        )
        return {}

    def head_object(self, *, Bucket: str, Key: str) -> dict[str, Any]:
        if Key not in self.head_metadata:
            raise RuntimeError(f"NoSuchKey: {Key}")
        return {"Metadata": self.head_metadata[Key]}


def main() -> int:
    failures: list[str] = []

    mod = _load_module("session_end_transcript_export", SCRIPT)

    # --- Patch botocore.exceptions.ClientError so _r2_upload catches our fake.
    # _r2_upload imports ClientError from botocore.exceptions lazily; we need
    # the same class for isinstance to work. The clean way: monkey-patch
    # botocore.exceptions.ClientError to FakeClientError for the duration of
    # the test, so the try/except in _r2_upload catches the fake.
    import botocore.exceptions

    saved_client_error = botocore.exceptions.ClientError
    botocore.exceptions.ClientError = FakeClientError  # type: ignore[misc]

    try:
        # --- _encode_meta_for_object_metadata: full encode happy path.
        small_sidecar = {
            "schema_version": 3,
            "session_id": "01234567-89ab-cdef-0123-456789abcdef",
            "events_processed": 5,
            "ciphertext_sha256": "a" * 64,
        }
        enc = mod._encode_meta_for_object_metadata(small_sidecar)
        if not isinstance(enc, dict) or "vade-meta-json" not in enc:
            failures.append(f"_encode_meta full-encode dropped keys: {enc!r}")
        else:
            if enc.get("vade-meta-schema") != "3":
                failures.append(f"_encode_meta schema marker drift: {enc!r}")
            if "vade-meta-truncated" in enc:
                failures.append(f"_encode_meta should not truncate small sidecar: {enc!r}")
            if json.loads(enc["vade-meta-json"]) != small_sidecar:
                failures.append("_encode_meta json round-trip diverged")

        # _encode_meta with redaction_hits big enough to require truncation
        # but the truncated version fits. Build a sidecar whose redaction_hits
        # alone push past LIMIT (1900B) but the rest stays under.
        big_hits = {f"pattern_{i}": i for i in range(400)}  # ~6KB JSON
        big_sidecar = dict(small_sidecar)
        big_sidecar["redaction_hits"] = big_hits
        enc_trunc = mod._encode_meta_for_object_metadata(big_sidecar)
        if not isinstance(enc_trunc, dict):
            failures.append("_encode_meta should truncate but returned None")
        elif enc_trunc.get("vade-meta-truncated") != "redaction_hits":
            failures.append(
                f"_encode_meta truncation marker missing/wrong: {enc_trunc!r}"
            )
        else:
            recovered = json.loads(enc_trunc["vade-meta-json"])
            if "redaction_hits" in recovered:
                failures.append("_encode_meta truncation should drop redaction_hits")
            if recovered.get("session_id") != small_sidecar["session_id"]:
                failures.append("_encode_meta truncation lost session_id")

        # _encode_meta where even the truncated version overflows: load every
        # field with bulk data so dropping redaction_hits doesn't fix it.
        bulk = {f"f{i}": "x" * 100 for i in range(50)}  # ~5KB just in extra fields
        overflow_sidecar = {**small_sidecar, **bulk, "redaction_hits": big_hits}
        enc_over = mod._encode_meta_for_object_metadata(overflow_sidecar)
        if enc_over is not None:
            failures.append(
                f"_encode_meta should return None on overflow: got {enc_over!r}"
            )

        # --- _r2_upload happy path
        with tempfile.NamedTemporaryFile("wb", delete=False) as f:
            f.write(b"ciphertext-bytes")
            local = Path(f.name)
        try:
            s3 = FakeS3()
            result = mod._r2_upload(
                local, "transcripts/2026/06/06/sid.jsonl.gz.age",
                metadata={"vade-meta-json": '{"k":1}', "vade-meta-schema": "3"},
                s3=s3, bucket="bkt", endpoint="https://r2.example",
            )
            if result.get("ceded"):
                failures.append(f"_r2_upload happy path returned ceded=True: {result!r}")
            if result.get("bucket") != "bkt" or result.get("key") != "transcripts/2026/06/06/sid.jsonl.gz.age":
                failures.append(f"_r2_upload result drift: {result!r}")
            if len(s3.puts) != 1:
                failures.append(f"_r2_upload put-count drift: {len(s3.puts)}")
            elif s3.puts[0].get("IfNoneMatch") != "*":
                failures.append(f"_r2_upload missing IfNoneMatch=*: {s3.puts[0]!r}")
            elif s3.puts[0].get("Metadata") != {"vade-meta-json": '{"k":1}', "vade-meta-schema": "3"}:
                failures.append(f"_r2_upload metadata drift: {s3.puts[0]!r}")
            elif s3.puts[0].get("Body") != b"ciphertext-bytes":
                failures.append(f"_r2_upload body drift: {s3.puts[0]!r}")

            # _r2_upload cede branch — PreconditionFailed → ceded=True
            s3_cede = FakeS3(raise_on_keys={
                "transcripts/2026/06/06/sid.jsonl.gz.age": FakeClientError(
                    "PreconditionFailed", 412
                )
            })
            result_cede = mod._r2_upload(
                local, "transcripts/2026/06/06/sid.jsonl.gz.age",
                metadata=None,
                s3=s3_cede, bucket="bkt", endpoint="https://r2.example",
            )
            if not result_cede.get("ceded"):
                failures.append(
                    f"_r2_upload should return ceded=True on 412: {result_cede!r}"
                )

            # _r2_upload non-precondition error — re-raises
            s3_err = FakeS3(raise_on_keys={
                "transcripts/2026/06/06/sid.jsonl.gz.age": FakeClientError("InternalError", 500)
            })
            raised = False
            try:
                mod._r2_upload(
                    local, "transcripts/2026/06/06/sid.jsonl.gz.age",
                    metadata=None,
                    s3=s3_err, bucket="bkt", endpoint="https://r2.example",
                )
            except FakeClientError:
                raised = True
            if not raised:
                failures.append("_r2_upload should re-raise non-precondition errors")
        finally:
            local.unlink(missing_ok=True)

        # --- _r2_head_object_metadata: returns dict on success.
        s3h = FakeS3(head_metadata={
            "transcripts/2026/06/06/sid.jsonl.gz.age": {
                "vade-meta-json": '{"session_id":"x"}',
                "vade-meta-schema": "3",
            }
        })
        md = mod._r2_head_object_metadata(
            "transcripts/2026/06/06/sid.jsonl.gz.age",
            s3=s3h, bucket="bkt",
        )
        if md != {"vade-meta-json": '{"session_id":"x"}', "vade-meta-schema": "3"}:
            failures.append(f"_r2_head_object_metadata happy path drift: {md!r}")

        # _r2_head_object_metadata: returns None on head_object failure
        s3h_miss = FakeS3()
        md_miss = mod._r2_head_object_metadata(
            "transcripts/missing-key.jsonl.gz.age",
            s3=s3h_miss, bucket="bkt",
        )
        if md_miss is not None:
            failures.append(f"_r2_head_object_metadata should return None on failure: {md_miss!r}")
    finally:
        botocore.exceptions.ClientError = saved_client_error  # type: ignore[misc]

    if failures:
        sys.stderr.write("EXPORT PARITY FAILURES:\n")
        for f in failures:
            sys.stderr.write(f"  - {f}\n")
        return 1

    print(
        "export OK — _encode_meta(full+truncate+overflow) + _r2_upload(happy+cede+raise) "
        "+ _r2_head_object_metadata(hit+miss) parity"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
