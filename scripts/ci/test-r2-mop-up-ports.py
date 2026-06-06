#!/usr/bin/env python3
"""Smoke test for the lib-ported R2-mop-up scripts (coo-labs/coo-harness#531).

Four scripts ported their inlined `_op_read` + `_r2_creds` + `_r2_client` to
`from transcripts import r2_client, r2_coordinates`:

  - scripts/boot/integrity-check-e6-r2-absence.py
  - scripts/boot/integrity-check-e8-r2-orphan.py
  - scripts/lib/list-r2-transcripts.py
  - scripts/lib/transcript-meta-backfill.py

The mechanical diff is identical across all four (drop helpers, import lib,
call `r2_coordinates()` + `r2_client(coords)` once, thread `s3` + bucket
through any iteration helpers). A single combined smoke is sufficient:

  1. Each script loads as a module (import-shape regression — the
     `sys.path.insert(0, .../lib)` line resolves; `from transcripts import ...`
     does not raise).
  2. Each script no longer carries the old inlined helpers (`_op_read`,
     `_r2_creds`, `_r2_client` are not defined on the module). Catches a
     mistaken half-port that leaves both code paths live.
  3. The two boot integrity checks (e6, e8) skip cleanly with detail=`skip: ...`
     when `r2_coordinates()` raises `R2Error` — replaces the prior env-missing
     + op-missing dual probe with one path through the lib.
  4. `transcript-meta-backfill._r2_iter` accepts the new pre-built
     `(s3, bucket, endpoint, date, sid)` signature and yields entries by
     R2 key regex match.

No live R2. No `op` calls. Stubs the lib's credential resolver via
`unittest.mock.patch`.

Exits 0 on full parity, 1 on any divergence.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from io import StringIO
from pathlib import Path
from typing import Any
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parents[2]
LIB_DIR = REPO_ROOT / "lib"
SCRIPTS = {
    "integrity_check_e6": REPO_ROOT / "scripts" / "boot" / "integrity-check-e6-r2-absence.py",
    "integrity_check_e8": REPO_ROOT / "scripts" / "boot" / "integrity-check-e8-r2-orphan.py",
    "list_r2_transcripts": REPO_ROOT / "scripts" / "lib" / "list-r2-transcripts.py",
    "transcript_meta_backfill": REPO_ROOT / "scripts" / "lib" / "transcript-meta-backfill.py",
}

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
    exercised by `_list_r2_keys` / lib's `list_keys`.
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
                return "2026-06-06T00:00:00+00:00"

        contents = [
            {"Key": k, "Size": len(v), "LastModified": _Dt()}
            for k, v in self.client.objects.items()
            if k.startswith(Prefix)
        ]
        return [{"Contents": contents}] if contents else [{}]


def main() -> int:
    failures: list[str] = []

    # --- (1) Each script loads cleanly (sys.path + lib import resolve).
    modules: dict[str, Any] = {}
    for name, path in SCRIPTS.items():
        try:
            modules[name] = _load_module(name, path)
        except Exception as e:
            failures.append(f"{name}: import failed — {e!r}")
            continue

    # --- (2) Old inlined helpers are gone.
    OBSOLETE = ("_op_read", "_r2_creds", "_r2_client")
    for name, mod in modules.items():
        for attr in OBSOLETE:
            if hasattr(mod, attr):
                failures.append(
                    f"{name}: stale inlined helper still present — {attr}"
                )

    # --- (3) Boot integrity checks skip cleanly on R2Error.
    from transcripts import R2Error

    def _fake_coords_raise() -> None:
        raise R2Error("test: env unset")

    for name in ("integrity_check_e6", "integrity_check_e8"):
        mod = modules.get(name)
        if mod is None:
            continue
        # Capture stdout; integrity checks emit one JSON line.
        saved_stdout, saved_argv = sys.stdout, sys.argv
        sys.stdout = StringIO()
        sys.argv = [SCRIPTS[name].name]
        try:
            with patch.object(mod, "r2_coordinates", side_effect=_fake_coords_raise):
                rc = mod.main()
            payload = json.loads(sys.stdout.getvalue().strip())
        finally:
            sys.stdout, sys.argv = saved_stdout, saved_argv
        if rc != 0:
            failures.append(f"{name}: skip-on-R2Error returned rc={rc}, want 0")
        if not payload.get("ok"):
            failures.append(
                f"{name}: skip-on-R2Error emitted ok=False (want True): {payload!r}"
            )
        detail = payload.get("detail", "")
        if not detail.startswith("skip:") or "test: env unset" not in detail:
            failures.append(
                f"{name}: skip-on-R2Error detail drift: {detail!r}"
            )

    # --- (4) transcript-meta-backfill._r2_iter accepts the new signature.
    backfill = modules.get("transcript_meta_backfill")
    if backfill is not None:
        valid_sid = "01234567-89ab-cdef-0123-456789abcdef"
        other_sid = "fedcba98-7654-3210-fedc-ba9876543210"
        objects = {
            # Date-prefixed ciphertext on the requested date — yielded.
            f"transcripts/2026/06/06/{valid_sid}.jsonl.gz.age": b"x",
            # Wrong-extension (lib's iter filters by R2_KEY_PATTERN, not yielded).
            "transcripts/2026/06/06/wrong-suffix.jsonl": b"x",
            # Different date, would-yield without --date filter; not yielded here.
            f"transcripts/2026/06/05/{other_sid}.jsonl.gz.age": b"x",
            # Outside the transcripts/ prefix — not yielded.
            "rendered/other.html": b"x",
        }
        s3 = FakeS3(objects)
        try:
            results = list(
                backfill._r2_iter(
                    s3, "bkt", "https://r2.example", "2026/06/06", None
                )
            )
        except TypeError as e:
            failures.append(f"transcript_meta_backfill._r2_iter signature drift: {e}")
            results = []
        sids = sorted(sid for _, _, sid, _, _ in results)
        if sids != [valid_sid]:
            failures.append(
                f"transcript_meta_backfill._r2_iter date-prefix filter drift: "
                f"got={sids} expected=[{valid_sid}]"
            )

        # --session-id filter narrows the date-prefix result.
        results_filtered = list(
            backfill._r2_iter(
                s3, "bkt", "https://r2.example", None, other_sid
            )
        )
        sids_filtered = sorted(sid for _, _, sid, _, _ in results_filtered)
        if sids_filtered != [other_sid]:
            failures.append(
                f"transcript_meta_backfill._r2_iter sid filter drift: "
                f"got={sids_filtered} expected=[{other_sid}]"
            )

    if failures:
        sys.stderr.write("R2 MOP-UP PARITY FAILURES:\n")
        for f in failures:
            sys.stderr.write(f"  - {f}\n")
        return 1

    print(
        "r2-mop-up OK — 4 scripts ported (e6/e8 skip-on-R2Error + "
        "transcript-meta-backfill iter-signature)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
