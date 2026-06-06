#!/usr/bin/env python3
"""Structural parity check: every ported script imports its primitives from lib.

Originally a value-equality check between the renderer's inlined definitions
and the lib copies — but every script that touched the lib has now been
ported (coo-memory#1147 series), so the parity check pivots to a structural
shape: confirm the script attributes still resolve, and the values they
expose match what lib provides.

Checks:
  1. The renderer's PARSER_VERSION (kept as a backward-compat alias) matches
     transcripts.render.RENDERER_VERSION.
  2. The renderer's compute_metadata + render_html are the same callables
     lib publishes (not script-local re-implementations).
  3. The lib's RENDERER_VERSION matches the (re-exported) PARSER_VERSION in
     schema — guards against the renderer-version constant drifting between
     render.py and schema.py.

Exits 0 on full parity, 1 on any divergence.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
LIB_DIR = REPO_ROOT / "lib"
RENDERER = REPO_ROOT / "scripts" / "lifecycle" / "session-end-transcript-render.py"

sys.path.insert(0, str(LIB_DIR))


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    failures: list[str] = []

    from transcripts.render import (
        RENDERER_VERSION as LIB_RV,
        compute_metadata as lib_compute_metadata,
        render_html as lib_render_html,
    )
    from transcripts.schema import PARSER_VERSION as SCHEMA_PV

    renderer = _load_module("session_end_transcript_render", RENDERER)
    if renderer.PARSER_VERSION != LIB_RV:
        failures.append(
            f"renderer.PARSER_VERSION (back-compat alias) drift — "
            f"script={renderer.PARSER_VERSION} lib={LIB_RV}"
        )
    if renderer.compute_metadata is not lib_compute_metadata:
        failures.append(
            "renderer.compute_metadata is not transcripts.render.compute_metadata"
        )
    if renderer.render_html is not lib_render_html:
        failures.append(
            "renderer.render_html is not transcripts.render.render_html"
        )
    if SCHEMA_PV != LIB_RV:
        failures.append(
            f"schema.PARSER_VERSION drift vs render.RENDERER_VERSION — "
            f"schema={SCHEMA_PV} render={LIB_RV}"
        )

    if failures:
        sys.stderr.write("PARITY FAILURES:\n")
        for f in failures:
            sys.stderr.write(f"  - {f}\n")
        return 1

    print(f"parity OK — renderer ports → lib; RENDERER_VERSION={LIB_RV}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
