"""Tests for lib/transcripts/jsonl.py."""

from __future__ import annotations

from pathlib import Path

import pytest

from transcripts.jsonl import (
    AUTO_NOTIFICATION_RES,
    SYSTEM_REMINDER_RE,
    classify,
    is_auto_notification_user_entry,
    read_entries,
    strip_auto_notifications,
)

# ---------------------------------------------------------------------------
# read_entries
# ---------------------------------------------------------------------------


def test_read_entries_empty(tmp_path: Path) -> None:
    p = tmp_path / "empty.jsonl"
    p.write_text("")
    assert read_entries(p) == []


def test_read_entries_basic(tmp_path: Path) -> None:
    p = tmp_path / "basic.jsonl"
    p.write_text('{"type":"user","seq":1}\n{"type":"assistant","seq":2}\n')
    assert read_entries(p) == [
        {"type": "user", "seq": 1},
        {"type": "assistant", "seq": 2},
    ]


def test_read_entries_skips_blank_lines(tmp_path: Path) -> None:
    p = tmp_path / "blanks.jsonl"
    p.write_text('\n\n{"a":1}\n   \n{"b":2}\n\n')
    assert read_entries(p) == [{"a": 1}, {"b": 2}]


def test_read_entries_skips_malformed_lines(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    p = tmp_path / "mixed.jsonl"
    p.write_text('{"ok":1}\n{not-json}\n{"ok":2}\n')
    assert read_entries(p) == [{"ok": 1}, {"ok": 2}]
    err = capsys.readouterr().err
    assert "skipping malformed line 2" in err


def test_read_entries_no_trailing_newline(tmp_path: Path) -> None:
    p = tmp_path / "no-trail.jsonl"
    p.write_text('{"a":1}\n{"b":2}')
    assert read_entries(p) == [{"a": 1}, {"b": 2}]


# ---------------------------------------------------------------------------
# strip_auto_notifications
# ---------------------------------------------------------------------------


def test_strip_passthrough() -> None:
    assert strip_auto_notifications("plain text") == "plain text"


def test_strip_empty() -> None:
    assert strip_auto_notifications("") == ""


def test_strip_system_reminder() -> None:
    assert (
        strip_auto_notifications("before <system-reminder>foo</system-reminder> after")
        == "before  after"
    )


def test_strip_multiline_system_reminder() -> None:
    text = "x <system-reminder>line1\nline2</system-reminder> y"
    assert strip_auto_notifications(text) == "x  y"


def test_strip_webhook() -> None:
    assert strip_auto_notifications("<github-webhook-activity>foo</github-webhook-activity>") == ""


def test_strip_task_notification() -> None:
    assert strip_auto_notifications("<task-notification>foo</task-notification>") == ""


def test_strip_all_envelopes() -> None:
    text = (
        "<system-reminder>x</system-reminder>"
        "<github-webhook-activity>y</github-webhook-activity>"
        "<task-notification>z</task-notification>"
    )
    assert strip_auto_notifications(text) == ""


def test_strip_preserves_residue_between_envelopes() -> None:
    text = (
        "<system-reminder>x</system-reminder>"
        "real text"
        "<github-webhook-activity>y</github-webhook-activity>"
    )
    assert strip_auto_notifications(text) == "real text"


def test_regex_exports_compile() -> None:
    # Smoke-check that the public regex exports are usable patterns.
    assert SYSTEM_REMINDER_RE.search("<system-reminder>x</system-reminder>") is not None
    assert (
        AUTO_NOTIFICATION_RES[0].search("<github-webhook-activity>x</github-webhook-activity>")
        is not None
    )


# ---------------------------------------------------------------------------
# is_auto_notification_user_entry
# ---------------------------------------------------------------------------


def test_auto_notif_string_content_empty() -> None:
    entry = {"message": {"content": "<system-reminder>x</system-reminder>"}}
    assert is_auto_notification_user_entry(entry) is True


def test_auto_notif_string_content_real_text() -> None:
    assert is_auto_notification_user_entry({"message": {"content": "hello"}}) is False


def test_auto_notif_string_content_whitespace_only() -> None:
    assert is_auto_notification_user_entry({"message": {"content": "   \n  "}}) is True


def test_auto_notif_list_only_webhook_text() -> None:
    entry = {
        "message": {
            "content": [
                {
                    "type": "text",
                    "text": "<github-webhook-activity>x</github-webhook-activity>",
                }
            ]
        }
    }
    assert is_auto_notification_user_entry(entry) is True


def test_auto_notif_list_has_real_text() -> None:
    entry = {
        "message": {
            "content": [
                {"type": "text", "text": "real content"},
                {"type": "text", "text": "<system-reminder>x</system-reminder>"},
            ]
        }
    }
    assert is_auto_notification_user_entry(entry) is False


def test_auto_notif_list_no_text_blocks() -> None:
    # tool_result-only content → not auto, but also not a typed user turn.
    # Callers route these via classify() == "tool_result", not via this fn.
    entry = {"message": {"content": [{"type": "tool_result", "content": "..."}]}}
    assert is_auto_notification_user_entry(entry) is False


def test_auto_notif_missing_content() -> None:
    assert is_auto_notification_user_entry({}) is False
    assert is_auto_notification_user_entry({"message": {}}) is False


def test_auto_notif_none_message() -> None:
    assert is_auto_notification_user_entry({"message": None}) is False


# ---------------------------------------------------------------------------
# classify
# ---------------------------------------------------------------------------


def test_classify_attachment() -> None:
    assert classify({"type": "attachment"}) == "attachment"


def test_classify_meta_kinds() -> None:
    for t in ("queue-operation", "last-prompt", "mode", "summary"):
        assert classify({"type": t}) == "meta"


def test_classify_user_string() -> None:
    assert classify({"type": "user", "message": {"content": "hi"}}) == "user"


def test_classify_user_list_text() -> None:
    entry = {"type": "user", "message": {"content": [{"type": "text", "text": "hi"}]}}
    assert classify(entry) == "user"


def test_classify_user_tool_result() -> None:
    entry = {
        "type": "user",
        "message": {"content": [{"type": "tool_result", "tool_use_id": "x", "content": "..."}]},
    }
    assert classify(entry) == "tool_result"


def test_classify_user_no_message() -> None:
    assert classify({"type": "user"}) == "user"


def test_classify_assistant_text() -> None:
    entry = {
        "type": "assistant",
        "message": {"content": [{"type": "text", "text": "x"}]},
    }
    assert classify(entry) == "assistant"


def test_classify_assistant_thinking_only() -> None:
    entry = {
        "type": "assistant",
        "message": {"content": [{"type": "thinking", "thinking": "x"}]},
    }
    assert classify(entry) == "thinking"


def test_classify_assistant_tool_use_only() -> None:
    entry = {
        "type": "assistant",
        "message": {"content": [{"type": "tool_use", "id": "x", "name": "y", "input": {}}]},
    }
    assert classify(entry) == "tool_use"


def test_classify_assistant_mixed() -> None:
    # Mixed text + tool_use → "assistant" (the generic dispatch).
    entry = {
        "type": "assistant",
        "message": {
            "content": [
                {"type": "text", "text": "ok"},
                {"type": "tool_use", "id": "x", "name": "y", "input": {}},
            ]
        },
    }
    assert classify(entry) == "assistant"


def test_classify_assistant_empty_content_list() -> None:
    # Empty list — the "all kinds are X" predicates require non-empty, so
    # falls through to generic "assistant".
    entry = {"type": "assistant", "message": {"content": []}}
    assert classify(entry) == "assistant"


def test_classify_other() -> None:
    assert classify({"type": "system"}) == "other"
    assert classify({}) == "other"
