"""Tests for lib/transcripts/render.py."""

from __future__ import annotations

import datetime

from transcripts.render import (
    CSS,
    JS,
    RENDERER_VERSION,
    build_toc,
    compute_metadata,
    esc,
    first_line,
    format_elapsed,
    format_session_url,
    format_ts,
    json_pretty,
    render_assistant,
    render_attachment,
    render_html,
    render_meta,
    render_text_with_reminders,
    render_tool_result,
    render_user,
    tool_args_summary,
    tool_result_text,
    truncate,
    ts_to_dt,
)

# ---------------------------------------------------------------------------
# Time + string formatting
# ---------------------------------------------------------------------------


def test_format_ts_iso() -> None:
    assert format_ts("2026-06-06T12:34:56Z") == "2026-06-06 12:34:56 UTC"


def test_format_ts_empty() -> None:
    assert format_ts(None) == ""
    assert format_ts("") == ""


def test_format_ts_malformed() -> None:
    assert format_ts("not-a-timestamp") == "not-a-timestamp"


def test_ts_to_dt_iso() -> None:
    dt = ts_to_dt("2026-06-06T12:34:56Z")
    assert dt is not None
    assert dt.year == 2026 and dt.month == 6 and dt.day == 6


def test_ts_to_dt_empty() -> None:
    assert ts_to_dt(None) is None
    assert ts_to_dt("") is None


def test_format_elapsed_seconds() -> None:
    t0 = datetime.datetime(2026, 6, 6, 0, 0, 0, tzinfo=datetime.timezone.utc)
    t1 = datetime.datetime(2026, 6, 6, 0, 0, 5, tzinfo=datetime.timezone.utc)
    assert format_elapsed(t0, t1) == "5s"


def test_format_elapsed_minutes() -> None:
    t0 = datetime.datetime(2026, 6, 6, 0, 0, 0, tzinfo=datetime.timezone.utc)
    t1 = datetime.datetime(2026, 6, 6, 0, 5, 30, tzinfo=datetime.timezone.utc)
    assert format_elapsed(t0, t1) == "5m30s"


def test_format_elapsed_hours() -> None:
    t0 = datetime.datetime(2026, 6, 6, 0, 0, 0, tzinfo=datetime.timezone.utc)
    t1 = datetime.datetime(2026, 6, 6, 2, 15, 0, tzinfo=datetime.timezone.utc)
    assert format_elapsed(t0, t1) == "2h15m"


def test_format_elapsed_sub_second() -> None:
    t0 = datetime.datetime(2026, 6, 6, 0, 0, 0, tzinfo=datetime.timezone.utc)
    t1 = datetime.datetime(2026, 6, 6, 0, 0, 0, 500000, tzinfo=datetime.timezone.utc)
    assert format_elapsed(t0, t1) == "<1s"


def test_format_elapsed_none() -> None:
    assert format_elapsed(None, None) == ""
    t = datetime.datetime(2026, 6, 6, 0, 0, 0, tzinfo=datetime.timezone.utc)
    assert format_elapsed(None, t) == ""
    assert format_elapsed(t, None) == ""


def test_format_elapsed_negative() -> None:
    t0 = datetime.datetime(2026, 6, 6, 0, 0, 10, tzinfo=datetime.timezone.utc)
    t1 = datetime.datetime(2026, 6, 6, 0, 0, 5, tzinfo=datetime.timezone.utc)
    assert format_elapsed(t0, t1) == ""


def test_truncate_short() -> None:
    assert truncate("hello", 10) == ("hello", False)


def test_truncate_long() -> None:
    assert truncate("hello world", 5) == ("hello", True)


def test_truncate_trims_trailing_whitespace() -> None:
    assert truncate("hi   ", 4) == ("hi", True)


def test_first_line_short() -> None:
    assert first_line("hello world") == "hello world"


def test_first_line_multiline() -> None:
    assert first_line("line one\nline two") == "line one"


def test_first_line_non_str() -> None:
    assert first_line(None) == ""
    assert first_line({"a": 1}) in ("{", '{"a": 1}')


def test_first_line_truncates() -> None:
    assert first_line("x" * 200, max_len=10) == "xxxxxxxxxx"


def test_esc_html() -> None:
    assert esc("<b>x</b>") == "&lt;b&gt;x&lt;/b&gt;"


def test_esc_none() -> None:
    assert esc(None) == ""


def test_esc_non_str() -> None:
    assert esc(42) == "42"


def test_json_pretty_dict() -> None:
    out = json_pretty({"a": 1})
    assert '"a"' in out and "1" in out


def test_json_pretty_unencodable() -> None:
    # Unencodable inputs (non-JSON-serializable) fall back to repr.
    class Weird:
        def __repr__(self) -> str:
            return "<weird>"

    assert json_pretty(Weird()) == "<weird>"


def test_format_session_url_plain() -> None:
    assert format_session_url("abc") == "https://claude.ai/code/session_abc"


def test_format_session_url_cse_prefix() -> None:
    assert format_session_url("cse_xyz") == "https://claude.ai/code/session_xyz"


def test_format_session_url_empty() -> None:
    assert format_session_url("") == ""
    assert format_session_url("   ") == ""


# ---------------------------------------------------------------------------
# Tool args / result
# ---------------------------------------------------------------------------


def test_tool_args_summary_empty() -> None:
    assert tool_args_summary(None) == ""
    assert tool_args_summary({}) == ""


def test_tool_args_summary_basic() -> None:
    out = tool_args_summary({"a": "hello", "b": 1, "c": True, "d": [1, 2]})
    assert "a=hello" in out
    assert "b=1" in out
    assert "c=True" in out
    assert "d=…" in out


def test_tool_args_summary_truncates_long_string() -> None:
    out = tool_args_summary({"k": "x" * 200})
    assert "…" in out


def test_tool_result_text_string() -> None:
    assert tool_result_text("hi") == "hi"


def test_tool_result_text_blocks() -> None:
    blocks = [
        {"type": "text", "text": "alpha"},
        {"type": "image"},
        {"type": "weird", "k": 1},
    ]
    out = tool_result_text(blocks)
    assert "alpha" in out and "[image]" in out and "weird" in out


def test_tool_result_text_dict() -> None:
    out = tool_result_text({"k": 1})
    assert '"k"' in out


# ---------------------------------------------------------------------------
# Per-entry rendering
# ---------------------------------------------------------------------------


def test_render_user_string_content() -> None:
    out = render_user(
        0,
        {"message": {"content": "hello"}, "timestamp": "2026-06-06T00:00:00Z"},
        elapsed="",
    )
    assert "entry-0" in out
    assert "user" in out
    assert "hello" in out


def test_render_user_list_content_with_text_block() -> None:
    out = render_user(
        1,
        {
            "message": {
                "content": [{"type": "text", "text": "<b>x</b>"}],
            },
            "timestamp": "2026-06-06T00:00:00Z",
        },
        elapsed="2s",
    )
    assert "&lt;b&gt;" in out
    assert "+" not in out or "2s" in out  # elapsed badge is decorated


def test_render_user_with_system_reminder() -> None:
    out = render_user(
        2,
        {"message": {"content": "<system-reminder>secret</system-reminder>after"}},
        elapsed="",
    )
    assert "system-reminder" in out
    assert "secret" in out
    assert "after" in out


def test_render_assistant_text() -> None:
    out = render_assistant(
        3,
        {
            "message": {
                "content": [{"type": "text", "text": "hi"}],
                "usage": {"input_tokens": 10, "output_tokens": 5},
            },
            "timestamp": "2026-06-06T00:00:00Z",
        },
        elapsed="",
    )
    assert "assistant" in out
    assert "in 10" in out and "out 5" in out
    assert "hi" in out


def test_render_assistant_thinking() -> None:
    out = render_assistant(
        4,
        {
            "message": {
                "content": [{"type": "thinking", "thinking": "reasoning"}],
            }
        },
        elapsed="",
    )
    assert "thinking" in out
    assert "reasoning" in out


def test_render_assistant_tool_use() -> None:
    out = render_assistant(
        5,
        {
            "message": {
                "content": [{"type": "tool_use", "name": "Bash", "input": {"command": "ls"}}]
            }
        },
        elapsed="",
    )
    assert "Bash" in out
    assert "command=ls" in out


def test_render_tool_result_basic() -> None:
    out = render_tool_result(
        6,
        {
            "message": {
                "content": [{"type": "tool_result", "content": "output", "tool_use_id": "abcd1234"}]
            }
        },
        elapsed="",
    )
    assert "tool_result" in out or "tool-result" in out
    assert "output" in out
    assert "abcd1234" in out or "abcd1234"[:8] in out


def test_render_tool_result_error() -> None:
    out = render_tool_result(
        7,
        {
            "message": {
                "content": [
                    {
                        "type": "tool_result",
                        "content": "boom",
                        "is_error": True,
                        "tool_use_id": "x",
                    }
                ]
            }
        },
        elapsed="",
    )
    assert "ERROR" in out
    assert "error" in out


def test_render_attachment_with_exit_code() -> None:
    out = render_attachment(
        8,
        {
            "attachment": {
                "hookName": "pre-tool",
                "stdout": "ok",
                "stderr": "warn",
                "exitCode": 1,
            }
        },
        elapsed="",
    )
    assert "pre-tool" in out
    assert " error" in out
    assert "ok" in out
    assert "STDERR" in out


def test_render_meta_summary() -> None:
    out = render_meta(9, {"type": "summary", "seq": 1}, "")
    assert "summary" in out
    assert "seq" in out


def test_render_text_with_reminders_no_reminder() -> None:
    out = render_text_with_reminders("plain text")
    assert "plain text" in out


def test_render_text_with_reminders_only_whitespace() -> None:
    assert render_text_with_reminders("") == ""
    assert render_text_with_reminders("   ") == ""


# ---------------------------------------------------------------------------
# TOC
# ---------------------------------------------------------------------------


def test_build_toc_no_users() -> None:
    out = build_toc([(0, "assistant", "")])
    assert "no user turns" in out


def test_build_toc_user_turns() -> None:
    out = build_toc([(0, "user", "first"), (1, "assistant", ""), (2, "user", "second")])
    assert "1. first" in out
    assert "2. second" in out
    assert "entry-0" in out
    assert "entry-2" in out


# ---------------------------------------------------------------------------
# compute_metadata
# ---------------------------------------------------------------------------


def test_compute_metadata_empty_entries() -> None:
    md = compute_metadata("sid", [])
    assert md["session_id"] == "sid"
    assert md["entry_count"] == 0
    assert md["user_turn_count"] == 0
    assert md["assistant_turn_count"] == 0
    assert md["renderer_version"] == RENDERER_VERSION
    assert md["session_url"] == ""
    assert "url_source" not in md


def test_compute_metadata_basic_counts() -> None:
    entries = [
        {
            "type": "user",
            "uuid": "u1",
            "message": {"content": "hello"},
            "timestamp": "2026-06-06T00:00:00Z",
        },
        {
            "type": "assistant",
            "message": {
                "content": [
                    {"type": "text", "text": "hi"},
                    {"type": "tool_use", "name": "Bash", "input": {}},
                ],
                "model": "claude-opus-4-7",
            },
            "timestamp": "2026-06-06T00:00:10Z",
        },
        {
            "type": "user",
            "message": {
                "content": [
                    {
                        "type": "tool_result",
                        "content": "ok",
                        "is_error": False,
                    }
                ]
            },
            "timestamp": "2026-06-06T00:00:20Z",
        },
    ]
    md = compute_metadata(
        "sid", entries, session_url="https://claude.ai/code/session_x", url_source="env-recovery"
    )
    assert md["user_turn_count"] == 1
    assert md["assistant_turn_count"] == 1
    assert md["tool_call_count"] == 1
    assert md["error_count"] == 0
    assert md["first_user_preview"] == "hello"
    assert md["first_user_uuid"] == "u1"
    assert md["models"] == ["claude-opus-4-7"]
    assert md["session_url"] == "https://claude.ai/code/session_x"
    assert md["url_source"] == "env-recovery"
    assert md["duration_seconds"] == 20


def test_compute_metadata_skips_auto_notification_user_entries() -> None:
    entries = [
        {
            "type": "user",
            "message": {"content": "<github-webhook-activity>x</github-webhook-activity>"},
        },
        {
            "type": "user",
            "message": {"content": "real user message"},
        },
    ]
    md = compute_metadata("sid", entries)
    assert md["user_turn_count"] == 1
    assert md["first_user_preview"] == "real user message"


def test_compute_metadata_error_count_from_tool_result() -> None:
    entries = [
        {
            "type": "user",
            "message": {"content": [{"type": "tool_result", "content": "x", "is_error": True}]},
        }
    ]
    md = compute_metadata("sid", entries)
    assert md["error_count"] == 1


def test_compute_metadata_error_count_from_attachment_exit_code() -> None:
    entries = [
        {
            "type": "attachment",
            "attachment": {"exitCode": 1},
        }
    ]
    md = compute_metadata("sid", entries)
    assert md["error_count"] == 1


def test_compute_metadata_collects_cc_version_and_cwds() -> None:
    entries = [
        {
            "type": "user",
            "version": "1.2.3",
            "cwd": "/home/user/a",
            "message": {"content": "hi"},
        },
        {
            "type": "user",
            "version": "1.2.4",
            "cwd": "/home/user/b",
            "message": {"content": "hi2"},
        },
        {
            "type": "user",
            "cwd": "/home/user/a",  # duplicate; should dedupe
            "message": {"content": "hi3"},
        },
    ]
    md = compute_metadata("sid", entries)
    assert md["cc_version"] == "1.2.4"
    assert md["cwds"] == ["/home/user/a", "/home/user/b"]


# ---------------------------------------------------------------------------
# render_html
# ---------------------------------------------------------------------------


def test_render_html_smoke() -> None:
    entries = [
        {"type": "user", "message": {"content": "hi"}, "timestamp": "2026-06-06T00:00:00Z"},
        {
            "type": "assistant",
            "message": {"content": [{"type": "text", "text": "hello"}]},
            "timestamp": "2026-06-06T00:00:01Z",
        },
    ]
    doc = render_html("sid", entries)
    assert doc.startswith("<!DOCTYPE html>")
    assert "Transcript sid" in doc
    assert CSS.split("\n")[1] in doc
    assert "1 entries" not in doc  # plural check
    assert "2 entries" in doc


def test_render_html_session_url_chrome() -> None:
    entries = [{"type": "user", "message": {"content": "hi"}}]
    doc = render_html("sid", entries, session_url="https://claude.ai/code/session_01ABC")
    assert "Open in Claude Code" in doc
    assert "/sessions/01ABC" in doc


def test_render_html_no_session_url() -> None:
    entries = [{"type": "user", "message": {"content": "hi"}}]
    doc = render_html("sid", entries, session_url="")
    assert "Open in Claude Code" not in doc


def test_render_html_includes_css_js() -> None:
    doc = render_html("sid", [])
    assert "<style>" in doc and "</style>" in doc
    assert "<script>" in doc and "</script>" in doc
    assert "search-box" in doc


def test_renderer_version_constant() -> None:
    """Guard against accidental version bumps without paired memo + parity update."""
    assert RENDERER_VERSION == 3


def test_js_constant_not_empty() -> None:
    assert JS.strip()
    assert "search-box" in JS or "runSearch" in JS
