#!/usr/bin/env python3
"""Smoke test for the lib-ported transcript-url-backfill.py.

The script ports its R2 plumbing + url_source taxonomy to
`from transcripts import ...` per coo-labs/coo-memory#1147; this test
exercises the surviving inlined helpers (`_list_candidate_sidecars`,
`_build_sid_to_url_map`, `_patch_one` semantics) against boto3-shaped
fakes — the anti-regression layer for the per-port parity discipline.

No live R2. No `op` calls. Loads the script as a module, monkey-patches
the transcripts package's bucket resolver, runs the helpers against
FakeS3, asserts the behavior matches expectation.

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
SCRIPT = REPO_ROOT / "scripts" / "transcript-url-backfill.py"

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
    """boto3-S3-shaped fake — only the `get_paginator` + `get_object` +
    `put_object` surfaces the helpers exercise."""

    def __init__(self, objects: dict[str, bytes]) -> None:
        self.objects = dict(objects)
        self.puts: list[dict[str, Any]] = []

    def get_paginator(self, op: str) -> FakePaginator:
        return FakePaginator(self)

    def get_object(self, *, Bucket: str, Key: str) -> dict[str, Any]:
        if Key not in self.objects:
            raise RuntimeError(f"NoSuchKey: {Key}")
        return {"Body": FakeBody(self.objects[Key])}

    def put_object(self, **kwargs: Any) -> dict[str, Any]:
        self.puts.append(kwargs)
        self.objects[kwargs["Key"]] = kwargs["Body"]
        return {}


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


def main() -> int:
    failures: list[str] = []

    mod = _load_module("transcript_url_backfill", SCRIPT)

    sid_a = "01234567-89ab-cdef-0123-456789abcdef"
    sid_b = "fedcba98-7654-3210-fedc-ba9876543210"
    sid_c = "11111111-2222-3333-4444-555555555555"
    sid_d = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    not_a_uuid = "01234567-89ab-cdef-0123-456789abcdez"

    meta_a = {"session_url": ""}  # missing — eligible
    meta_b = {"session_url": "https://claude.ai/code/session_01HOLD"}  # populated
    meta_c = {}  # no session_url at all — eligible
    meta_d = {"session_url": ""}  # missing — eligible

    objects = {
        f"rendered/{sid_a}.meta.json": json.dumps(meta_a).encode(),
        f"rendered/{sid_b}.meta.json": json.dumps(meta_b).encode(),
        f"rendered/{sid_c}.meta.json": json.dumps(meta_c).encode(),
        f"rendered/{sid_d}.meta.json": json.dumps(meta_d).encode(),
        f"rendered/{not_a_uuid}.meta.json": json.dumps({}).encode(),  # bad sid
        f"rendered/{sid_a}.html": b"<html/>",  # wrong suffix
        f"other-prefix/{sid_a}.meta.json": json.dumps({}).encode(),  # wrong prefix
    }

    with patch("transcripts.r2._bucket_from_env_or_op", return_value="bkt"):
        s3 = FakeS3(objects)
        cands_missing = mod._list_candidate_sidecars(s3, "bkt", "rendered", False)
        cands_all = mod._list_candidate_sidecars(s3, "bkt", "rendered", True)

    cands_missing_sids = sorted(s for s, _ in cands_missing)
    cands_all_sids = sorted(s for s, _ in cands_all)
    expected_missing = sorted([sid_a, sid_c, sid_d])
    expected_all = sorted([sid_a, sid_b, sid_c, sid_d])

    if cands_missing_sids != expected_missing:
        failures.append(
            f"_list_candidate_sidecars(include_populated=False) drift — "
            f"got={cands_missing_sids} expected={expected_missing}"
        )
    if cands_all_sids != expected_all:
        failures.append(
            f"_list_candidate_sidecars(include_populated=True) drift — "
            f"got={cands_all_sids} expected={expected_all}"
        )

    # _build_sid_to_url_map: confirms the AUTO_META_PR_TITLE_RE + the artifact
    # filter (type='pr', repo='coo-labs/coo-logs') still pull the sid out of
    # the title.
    index = {
        "sessions": [
            {
                "session_url": "https://claude.ai/code/session_01ABC",
                "artifacts": [
                    {
                        "type": "pr",
                        "repo": "coo-labs/coo-logs",
                        "title": f"meta: auto-commit sidecar for {sid_a}",
                    },
                    {
                        "type": "pr",
                        "repo": "coo-labs/coo-memory",  # wrong repo
                        "title": f"meta: auto-commit sidecar for {sid_b}",
                    },
                    {
                        "type": "issue",  # wrong type
                        "repo": "coo-labs/coo-logs",
                        "title": f"meta: auto-commit sidecar for {sid_c}",
                    },
                ],
            },
            {
                "session_url": "",  # blank — must skip the whole session
                "artifacts": [
                    {
                        "type": "pr",
                        "repo": "coo-labs/coo-logs",
                        "title": f"meta: auto-commit sidecar for {sid_d}",
                    },
                ],
            },
        ],
    }
    sid_to_url = mod._build_sid_to_url_map(index)
    expected_map = {sid_a: "https://claude.ai/code/session_01ABC"}
    if sid_to_url != expected_map:
        failures.append(
            f"_build_sid_to_url_map drift — got={sid_to_url} expected={expected_map}"
        )

    # _patch_one: verify the AUTHORITATIVE preservation rule still fires
    # against the lib-imported set.
    objects_p = {
        f"rendered/{sid_a}.meta.json": json.dumps(
            {"session_url": "old", "url_source": "title-fast-path"}
        ).encode(),
        f"rendered/{sid_b}.meta.json": json.dumps(
            {"session_url": "old", "url_source": "scan-prose-vote"}
        ).encode(),
    }
    s3p = FakeS3(objects_p)
    ok_a, detail_a = mod._patch_one(
        s3p, "bkt", f"rendered/{sid_a}.meta.json", "new", "scan-pr-link"
    )
    if not (ok_a and "no-op" in detail_a and "authoritative" in detail_a):
        failures.append(
            f"_patch_one should refuse to overwrite authoritative — "
            f"got ok={ok_a} detail={detail_a!r}"
        )
    ok_b, detail_b = mod._patch_one(
        s3p, "bkt", f"rendered/{sid_b}.meta.json", "new", "scan-pr-link"
    )
    if not (ok_b and "->" in detail_b):
        failures.append(
            f"_patch_one should overwrite reconcile-eligible — "
            f"got ok={ok_b} detail={detail_b!r}"
        )
    # And: refuses unknown url_source.
    ok_x, detail_x = mod._patch_one(
        s3p, "bkt", f"rendered/{sid_b}.meta.json", "new", "bogus-source"
    )
    if not (not ok_x and "unknown url_source" in detail_x):
        failures.append(
            f"_patch_one should refuse unknown url_source — "
            f"got ok={ok_x} detail={detail_x!r}"
        )

    if failures:
        sys.stderr.write("URL-BACKFILL PARITY FAILURES:\n")
        for f in failures:
            sys.stderr.write(f"  - {f}\n")
        return 1

    print(
        f"url-backfill OK — missing={len(cands_missing)} all={len(cands_all)} "
        f"sid_map={len(sid_to_url)} patch-rules=3"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
