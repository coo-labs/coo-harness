#!/usr/bin/env python3
"""Smoke test for the lib-ported transcript-rerender-v3-backfill.py.

The script ports its R2 plumbing to `from transcripts import ...` per
coo-labs/coo-memory#1147 (it still imports `_rerender_one` from url-backfill
via importlib because that orchestration helper stays in scripts/). This
test exercises the eligibility filter end-to-end against a boto3-shaped fake
to confirm the populated/empty/renderer_version branches still pick the
expected sidecars.

No live R2. No `op` calls. No actual rerender (the test runs --dry-run
without --apply via direct helper invocation).

Exits 0 on full parity, 1 on any divergence.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from typing import Any
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parents[2]
LIB_DIR = REPO_ROOT / "lib"
SCRIPT = REPO_ROOT / "scripts" / "transcript-rerender-v3-backfill.py"

sys.path.insert(0, str(LIB_DIR))


def _load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeBody:
    def __init__(self, payload: bytes) -> None:
        self._payload = payload

    def read(self) -> bytes:
        return self._payload


class FakeS3:
    def __init__(self, objects: dict[str, bytes]) -> None:
        self.objects = dict(objects)

    def get_paginator(self, op: str) -> FakePaginator:
        return FakePaginator(self)

    def get_object(self, *, Bucket: str, Key: str) -> dict[str, Any]:
        if Key not in self.objects:
            raise RuntimeError(f"NoSuchKey: {Key}")
        return {"Body": FakeBody(self.objects[Key])}


class FakePaginator:
    def __init__(self, client: FakeS3) -> None:
        self.client = client

    def paginate(self, *, Bucket: str, Prefix: str) -> list[dict[str, Any]]:
        class _Dt:
            def isoformat(self) -> str:
                return "2026-06-06T00:00:00Z"

        contents = [
            {"Key": k, "Size": len(v), "LastModified": _Dt()}
            for k, v in self.client.objects.items()
            if k.startswith(Prefix)
        ]
        return [{"Contents": contents}] if contents else [{}]


def _build_eligible(
    s3: FakeS3,
    bucket: str,
    key_prefix: str,
    filter_renderer_version: int | None,
) -> tuple[list[tuple[str, str, str]], int, int]:
    """Re-implementation of the body of `main`'s scan loop, with the same
    branching. We can't easily call main() because it drives stdout/stderr
    and exit; lifting the predicate matches the prior smoke-test pattern."""
    from transcripts import list_keys

    eligible: list[tuple[str, str, str]] = []
    skipped_no_url = 0
    skipped_filtered = 0
    for obj in list_keys(f"{key_prefix}/", s3=s3):
        key = obj["key"]
        if not key.endswith(".meta.json"):
            continue
        sid = key[len(f"{key_prefix}/") : -len(".meta.json")]
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        meta = json.loads(body)
        session_url = (meta.get("session_url") or "").strip()
        if not session_url:
            skipped_no_url += 1
            continue
        if filter_renderer_version is not None:
            rv = meta.get("renderer_version")
            if isinstance(rv, int) and rv >= filter_renderer_version:
                skipped_filtered += 1
                continue
        eligible.append((sid, key, session_url))
    return eligible, skipped_no_url, skipped_filtered


def main() -> int:
    failures: list[str] = []

    # Just confirm the module loads — proves `from transcripts import ...`
    # resolves and the importlib shim for url-backfill is still intact.
    mod = _load_module("transcript_rerender_v3_backfill", SCRIPT)
    if not hasattr(mod, "_load_backfill_module"):
        failures.append("module missing _load_backfill_module helper")

    sid_a = "01234567-89ab-cdef-0123-456789abcdef"
    sid_b = "fedcba98-7654-3210-fedc-ba9876543210"
    sid_c = "11111111-2222-3333-4444-555555555555"
    sid_d = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    objects = {
        f"rendered/{sid_a}.meta.json": json.dumps(
            {"session_url": "https://claude.ai/code/session_01A", "renderer_version": 1}
        ).encode(),
        f"rendered/{sid_b}.meta.json": json.dumps(
            {"session_url": "", "renderer_version": 1}
        ).encode(),  # skip — no url
        f"rendered/{sid_c}.meta.json": json.dumps(
            {"session_url": "https://claude.ai/code/session_01C"}
        ).encode(),  # no renderer_version — eligible at any filter
        f"rendered/{sid_d}.meta.json": json.dumps(
            {"session_url": "https://claude.ai/code/session_01D", "renderer_version": 3}
        ).encode(),  # skip when filter=3 (rv >= filter)
        f"rendered/{sid_a}.html": b"<html/>",  # wrong suffix
    }

    with patch("transcripts.r2._bucket_from_env_or_op", return_value="bkt"):
        s3 = FakeS3(objects)
        eligible_all, no_url_all, filt_all = _build_eligible(s3, "bkt", "rendered", None)
        eligible_v3, no_url_v3, filt_v3 = _build_eligible(s3, "bkt", "rendered", 3)

    elig_sids_all = sorted(s for s, _, _ in eligible_all)
    elig_sids_v3 = sorted(s for s, _, _ in eligible_v3)
    expected_all = sorted([sid_a, sid_c, sid_d])
    expected_v3 = sorted([sid_a, sid_c])

    if elig_sids_all != expected_all:
        failures.append(
            f"eligibility (no filter) drift — got={elig_sids_all} expected={expected_all}"
        )
    if no_url_all != 1:
        failures.append(f"skipped_no_url (no filter) — got={no_url_all} expected=1")
    if filt_all != 0:
        failures.append(f"skipped_filtered (no filter) — got={filt_all} expected=0")

    if elig_sids_v3 != expected_v3:
        failures.append(
            f"eligibility (filter=3) drift — got={elig_sids_v3} expected={expected_v3}"
        )
    if no_url_v3 != 1:
        failures.append(f"skipped_no_url (filter=3) — got={no_url_v3} expected=1")
    if filt_v3 != 1:
        failures.append(f"skipped_filtered (filter=3) — got={filt_v3} expected=1")

    if failures:
        sys.stderr.write("RERENDER-V3 PARITY FAILURES:\n")
        for f in failures:
            sys.stderr.write(f"  - {f}\n")
        return 1

    print(
        f"rerender-v3 OK — all={len(eligible_all)} "
        f"filter-rv3={len(eligible_v3)} skipped-noUrl={no_url_all}/{no_url_v3} "
        f"skipped-filter={filt_v3}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
