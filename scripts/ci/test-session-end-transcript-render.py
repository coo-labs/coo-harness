#!/usr/bin/env python3
"""Smoke test for the lib-ported session-end-transcript-render.py.

The Stop-hook ports its rendering helpers + R2 plumbing to
`from transcripts.render import ...` and `from transcripts import ...`
per coo-labs/coo-memory#1147. This test confirms:

  - The script loads cleanly with the lib-import surface (no stale
    references to deleted helpers like `_render_user`, `CSS`, `JS`,
    `_op_read`, `_r2_endpoint_bucket`, `_r2_put_bytes`).
  - The lib-exported `compute_metadata` + `render_html` produce the
    expected output shape against a synthetic jsonl fixture (smoke,
    not exhaustive — lib's own test suite covers the rendering core).
  - The backward-compat alias `script.PARSER_VERSION` still resolves
    to the lib `RENDERER_VERSION`.

No live R2. No `op` calls. The Stop-hook integration tests
(`test-transcript-export.py` etc.) cover the live invocation path —
this test exists to catch port-time regressions before the live
chain runs.

Exits 0 on pass, 1 on any divergence.
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
SCRIPT = REPO_ROOT / "scripts" / "lifecycle" / "session-end-transcript-render.py"

sys.path.insert(0, str(LIB_DIR))


def _load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    failures: list[str] = []

    mod = _load_module("session_end_transcript_render", SCRIPT)
    from transcripts.render import (
        RENDERER_VERSION as LIB_RV,
        compute_metadata as lib_compute_metadata,
        render_html as lib_render_html,
    )

    # 1. Backward-compat alias.
    if mod.PARSER_VERSION != LIB_RV:
        failures.append(
            f"PARSER_VERSION alias drift — script={mod.PARSER_VERSION} lib={LIB_RV}"
        )

    # 2. The script re-exports the lib symbols (used by other code that loads
    # the script as a module to access compute_metadata + render_html).
    if mod.compute_metadata is not lib_compute_metadata:
        failures.append("script.compute_metadata is not lib.compute_metadata")
    if mod.render_html is not lib_render_html:
        failures.append("script.render_html is not lib.render_html")

    # 3. Deleted helpers should not be lurking. Catching this here prevents a
    # half-finished port from shipping with both copies — the script-local
    # would silently win and lib changes would have no effect.
    for stale in (
        "_render_user", "_render_assistant", "_render_tool_result",
        "_render_attachment", "_render_meta", "_render_other",
        "_render_text_with_reminders", "_render_raw", "_render_thinking_entry",
        "_format_ts", "_ts_to_dt", "_format_elapsed", "_truncate",
        "_first_line", "_esc", "_json_pretty", "_tool_args_summary",
        "_tool_result_text", "_build_toc", "_format_session_url",
        "_op_read", "_r2_endpoint_bucket", "_r2_put_bytes",
        "_strip_auto_notifications", "_is_auto_notification_user_entry",
        "_classify", "SYSTEM_REMINDER_RE", "AUTO_NOTIFICATION_RES",
        "CSS", "JS",
    ):
        if hasattr(mod, stale):
            failures.append(f"stale symbol survived port: {stale}")

    # 4. End-to-end smoke: render a synthetic jsonl.
    fixture = (
        '{"type":"user","message":{"content":"hello"},"timestamp":"2026-06-06T00:00:00Z"}\n'
        '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]},'
        '"timestamp":"2026-06-06T00:00:05Z"}\n'
    )
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        f.write(fixture)
        fixture_path = Path(f.name)
    try:
        entries = mod._read_entries(fixture_path)
    finally:
        fixture_path.unlink(missing_ok=True)

    if len(entries) != 2:
        failures.append(f"_read_entries dropped lines: got {len(entries)} expected 2")

    html = mod.render_html("test-sid", entries)
    if not html.startswith("<!DOCTYPE html>"):
        failures.append("render_html did not produce a complete HTML document")
    if "hello" not in html or "hi" not in html:
        failures.append("render_html lost user/assistant content")

    md = mod.compute_metadata("test-sid", entries)
    if md.get("renderer_version") != LIB_RV:
        failures.append(f"compute_metadata renderer_version drift: {md.get('renderer_version')}")
    if md.get("user_turn_count") != 1:
        failures.append(f"compute_metadata user_turn_count drift: {md.get('user_turn_count')}")
    if md.get("assistant_turn_count") != 1:
        failures.append(
            f"compute_metadata assistant_turn_count drift: {md.get('assistant_turn_count')}"
        )

    if failures:
        sys.stderr.write("RENDER-PORT PARITY FAILURES:\n")
        for f in failures:
            sys.stderr.write(f"  - {f}\n")
        return 1

    print(
        f"render-port OK — RENDERER_VERSION={LIB_RV}, "
        f"entries={len(entries)}, html_bytes={len(html.encode('utf-8'))}, "
        f"meta_fields={len(md)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
