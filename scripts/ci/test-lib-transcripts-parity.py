#!/usr/bin/env python3
"""Parity check: lib/transcripts/ matches the inlined definitions in scripts/.

Confirms that the consolidated primitives in lib/transcripts/ match the values
the existing scripts hardcode. Run before any script-port PR ships — if this
fails, the port would silently change behavior.

Checks (post-coo-memory#1147 url-backfill port — the script now imports the
url_source taxonomy and dominant_scan_source from lib; what remains here is
the renderer-side parity, which still inlines):

  1. PARSER_VERSION in lib/transcripts/schema.py matches the integer
     scripts/lifecycle/session-end-transcript-render.py uses.
  2. jsonl.py primitives (read_entries, strip_auto_notifications,
     is_auto_notification_user_entry, classify) match the renderer's
     inlined _read_entries / _strip_auto_notifications /
     _is_auto_notification_user_entry / _classify across a fixture set.
  3. SYSTEM_REMINDER_RE and AUTO_NOTIFICATION_RES regex patterns in the
     renderer match the lib values.

The url-backfill checks (AUTHORITATIVE_URL_SOURCES drift,
_dominant_scan_source) are removed — the script now imports those names
directly from lib, so the parity is structural rather than value-equality.

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

    from transcripts.jsonl import (
        classify as lib_classify,
        is_auto_notification_user_entry as lib_is_auto,
        read_entries as lib_read_entries,
        strip_auto_notifications as lib_strip,
    )
    from transcripts.provenance import (
        AUTHORITATIVE_URL_SOURCES as LIB_AUTH,
        RECONCILE_ELIGIBLE_URL_SOURCES as LIB_RECON,
    )
    from transcripts.schema import PARSER_VERSION as LIB_PV

    renderer = _load_module("session_end_transcript_render", RENDERER)
    if renderer.PARSER_VERSION != LIB_PV:
        failures.append(
            f"PARSER_VERSION drift — script={renderer.PARSER_VERSION} lib={LIB_PV}"
        )

    # jsonl primitives: regex pattern equivalence first (catches a drift the
    # downstream behavioral fixtures might miss if their inputs don't exercise
    # the changed branch).
    if renderer.SYSTEM_REMINDER_RE.pattern != "<system-reminder>(.*?)</system-reminder>":
        failures.append(
            f"SYSTEM_REMINDER_RE drift — script={renderer.SYSTEM_REMINDER_RE.pattern!r}"
        )
    script_auto_patterns = [r.pattern for r in renderer.AUTO_NOTIFICATION_RES]
    expected_auto_patterns = [
        r"<github-webhook-activity>.*?</github-webhook-activity>",
        r"<task-notification>.*?</task-notification>",
    ]
    if script_auto_patterns != expected_auto_patterns:
        failures.append(
            f"AUTO_NOTIFICATION_RES drift — script={script_auto_patterns}"
        )

    # strip_auto_notifications + is_auto_notification_user_entry: behavioral parity
    # across the cases the renderer's classifier touches.
    strip_cases = [
        "plain text",
        "",
        "before <system-reminder>x</system-reminder> after",
        "<github-webhook-activity>x</github-webhook-activity>",
        "<task-notification>x</task-notification>",
        "<system-reminder>x</system-reminder>text<github-webhook-activity>y</github-webhook-activity>",
    ]
    for case in strip_cases:
        s_val = renderer._strip_auto_notifications(case)
        l_val = lib_strip(case)
        if s_val != l_val:
            failures.append(
                f"strip_auto_notifications({case!r}) — script={s_val!r} lib={l_val!r}"
            )

    is_auto_cases = [
        {"message": {"content": "hello"}},
        {"message": {"content": "<system-reminder>x</system-reminder>"}},
        {"message": {"content": "   "}},
        {
            "message": {
                "content": [{"type": "text", "text": "real"}],
            }
        },
        {
            "message": {
                "content": [
                    {
                        "type": "text",
                        "text": "<github-webhook-activity>x</github-webhook-activity>",
                    }
                ],
            }
        },
        {"message": {"content": [{"type": "tool_result", "content": "..."}]}},
        {},
    ]
    for case in is_auto_cases:
        s_val = renderer._is_auto_notification_user_entry(case)
        l_val = lib_is_auto(case)
        if s_val != l_val:
            failures.append(
                f"is_auto_notification_user_entry({case!r}) — script={s_val} lib={l_val}"
            )

    # classify: cover each branch of the renderer's _classify.
    classify_cases = [
        {"type": "attachment"},
        {"type": "queue-operation"},
        {"type": "last-prompt"},
        {"type": "mode"},
        {"type": "summary"},
        {"type": "user", "message": {"content": "hi"}},
        {"type": "user", "message": {"content": [{"type": "text", "text": "x"}]}},
        {
            "type": "user",
            "message": {"content": [{"type": "tool_result", "content": "..."}]},
        },
        {"type": "user"},
        {"type": "assistant", "message": {"content": [{"type": "text", "text": "x"}]}},
        {
            "type": "assistant",
            "message": {"content": [{"type": "thinking", "thinking": "x"}]},
        },
        {
            "type": "assistant",
            "message": {
                "content": [
                    {"type": "tool_use", "id": "a", "name": "b", "input": {}}
                ]
            },
        },
        {
            "type": "assistant",
            "message": {
                "content": [
                    {"type": "text", "text": "x"},
                    {"type": "tool_use", "id": "a", "name": "b", "input": {}},
                ]
            },
        },
        {"type": "assistant", "message": {"content": []}},
        {"type": "system"},
        {},
    ]
    for case in classify_cases:
        s_val = renderer._classify(case)
        l_val = lib_classify(case)
        if s_val != l_val:
            failures.append(f"classify({case!r}) — script={s_val!r} lib={l_val!r}")

    # read_entries: behavioral parity on a synthetic fixture.
    import tempfile

    fixture = (
        '{"type":"user","message":{"content":"hi"}}\n'
        "\n"
        '{"type":"assistant","message":{"content":[]}}\n'
        "{not-json}\n"
        '{"type":"summary","seq":42}\n'
    )
    with tempfile.NamedTemporaryFile(
        "w", suffix=".jsonl", delete=False
    ) as f:
        f.write(fixture)
        fixture_path = Path(f.name)
    try:
        s_entries = renderer._read_entries(fixture_path)
        l_entries = lib_read_entries(fixture_path)
        if s_entries != l_entries:
            failures.append(
                f"read_entries fixture parity — script={s_entries} lib={l_entries}"
            )
    finally:
        fixture_path.unlink(missing_ok=True)

    if failures:
        sys.stderr.write("PARITY FAILURES:\n")
        for f in failures:
            sys.stderr.write(f"  - {f}\n")
        return 1

    print(
        f"parity OK — {len(LIB_AUTH)} auth, {len(LIB_RECON)} reconcile, "
        f"PARSER_VERSION={LIB_PV}, jsonl primitives match"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
