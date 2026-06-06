#!/usr/bin/env python3
"""Smoke test for the lib-ported transcript-render-backfill.py.

The script ports its R2 plumbing to `from transcripts import ...` per
coo-labs/coo-memory#1147; this test exercises the surviving inlined
helper (`_list_sessions`) against a boto3-shaped fake to confirm the
regex filtering + SESSION_ID_RE validation still picks the expected
sids — the anti-regression layer for the per-port parity discipline.

No live R2. No `op` calls. Loads the script as a module, monkey-patches
the transcripts package's bucket resolver to a fixed value, runs
`_list_sessions` against a FakeS3Client, asserts the result set.

Exits 0 on full parity, 1 on any divergence.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import Any
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parents[2]
LIB_DIR = REPO_ROOT / "lib"
SCRIPT = REPO_ROOT / "scripts" / "transcript-render-backfill.py"

sys.path.insert(0, str(LIB_DIR))


def _load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeS3:
    """boto3-S3-shaped fake — only the `get_paginator` + `paginate` surface
    that lib's list_keys exercises.
    """

    def __init__(self, objects: dict[str, bytes]) -> None:
        self.objects = objects

    def get_paginator(self, op: str) -> FakePaginator:
        return FakePaginator(self)


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

    mod = _load_module("transcript_render_backfill", SCRIPT)

    valid_sid = "01234567-89ab-cdef-0123-456789abcdef"
    other_sid = "fedcba98-7654-3210-fedc-ba9876543210"
    not_a_sid_format = "01234567-89ab-cdef-0123-456789abcdez"  # 'z' at end
    objects = {
        f"transcripts/2026/06/06/{valid_sid}.jsonl.gz.age": b"x",
        f"transcripts/2026/06/06/{other_sid}.jsonl.gz.age": b"x",
        f"transcripts/2026/06/06/{not_a_sid_format}.jsonl.gz.age": b"x",
        "transcripts/2026/06/06/not-a-uuid.jsonl.gz.age": b"x",
        f"rendered/{valid_sid}.html": b"x",
        f"rendered/{other_sid}.meta.json": b"x",  # wrong suffix
        "other-prefix/x.jsonl.gz.age": b"x",
    }

    with patch("transcripts.r2._bucket_from_env_or_op", return_value="bkt"):
        cipher = mod._list_sessions("transcripts/", mod.CIPHERTEXT_KEY_RE, FakeS3(objects))
        rendered = mod._list_sessions(
            "rendered/", mod.RENDERED_KEY_RE, FakeS3(objects)
        )

    if cipher != {valid_sid, other_sid}:
        failures.append(
            f"ciphertext set drift — got={sorted(cipher)} "
            f"expected={sorted([valid_sid, other_sid])}"
        )
    if rendered != {valid_sid}:
        failures.append(
            f"rendered set drift — got={sorted(rendered)} expected=[{valid_sid}]"
        )

    if failures:
        sys.stderr.write("RENDER-BACKFILL PARITY FAILURES:\n")
        for f in failures:
            sys.stderr.write(f"  - {f}\n")
        return 1

    print(f"render-backfill OK — cipher={len(cipher)} rendered={len(rendered)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
