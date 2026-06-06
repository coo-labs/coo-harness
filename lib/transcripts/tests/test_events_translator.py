"""Translator tests — synthetic shapes + round-trip against the pinned fixture.

The fixture lives at `fixtures/events-api/session_0146...events.json.gz` and
carries the 3438-event, 9-distinct-type ground truth from the 2026-06-05 probe.
The fixture-round-trip test is the load-bearing one: it catches any change to
the translator that would silently break the events-API recovery driver.
"""

from __future__ import annotations

import gzip
import json
from pathlib import Path
from typing import Any

import pytest

from transcripts.events.translator import (
    EventsMetadata,
    events_to_entries,
    extract_metadata,
)

_FIXTURE_PATH = (
    Path(__file__).resolve().parents[3]
    / "fixtures"
    / "events-api"
    / "session_0146dWU8wPHNwLyNLLJLuTYL.events.json.gz"
)


def _load_fixture() -> tuple[str, list[dict[str, Any]]]:
    with gzip.open(_FIXTURE_PATH, "rt", encoding="utf-8") as f:
        raw = json.load(f)
    return raw["sid"], raw["events"]


@pytest.fixture(scope="module")
def fixture_events() -> tuple[str, list[dict[str, Any]]]:
    return _load_fixture()


class TestEventsToEntriesShape:
    def test_user_event_becomes_user_entry(self) -> None:
        events = [
            {
                "type": "user",
                "created_at": "2026-05-31T01:24:57.825423Z",
                "uuid": "u1",
                "session_id": "sid",
                "message": {"content": "hello", "role": "user"},
                "client_platform": "web_claude_ai",
            }
        ]
        entries = events_to_entries(events, "sid")
        assert len(entries) == 1
        entry = entries[0]
        assert entry["type"] == "user"
        assert entry["timestamp"] == "2026-05-31T01:24:57.825423Z"
        assert entry["uuid"] == "u1"
        assert entry["message"] == {"content": "hello", "role": "user"}
        assert entry["client_platform"] == "web_claude_ai"
        assert entry["sessionId"] == "sid"

    def test_empty_session_id_falls_back_to_arg(self) -> None:
        events = [{"type": "user", "created_at": "ts", "uuid": "u", "session_id": ""}]
        entries = events_to_entries(events, "canonical-sid")
        assert entries[0]["sessionId"] == "canonical-sid"

    def test_assistant_event_passes_through_message(self) -> None:
        msg = {
            "content": [{"type": "text", "text": "hi"}],
            "model": "claude-opus-4-7",
            "role": "assistant",
        }
        events = [
            {
                "type": "assistant",
                "created_at": "ts",
                "uuid": "a1",
                "session_id": "sid",
                "message": msg,
                "request_id": "req_x",
            }
        ]
        entries = events_to_entries(events, "sid")
        assert entries[0]["message"] == msg
        assert entries[0]["requestId"] == "req_x"

    def test_system_init_becomes_summary_meta(self) -> None:
        events = [
            {
                "type": "system",
                "subtype": "init",
                "created_at": "ts",
                "uuid": "i1",
                "cwd": "/home/user",
                "claude_code_version": "2.1.158",
                "permissionMode": "default",
            }
        ]
        entries = events_to_entries(events, "sid")
        assert entries[0]["type"] == "summary"
        assert entries[0]["cwd"] == "/home/user"
        assert entries[0]["version"] == "2.1.158"
        assert "perm=default" in entries[0]["summary"]

    def test_system_non_init_dropped(self) -> None:
        events = [
            {
                "type": "system",
                "subtype": "hook_started",
                "created_at": "ts",
                "uuid": "h1",
            }
        ]
        entries = events_to_entries(events, "sid")
        assert entries == []

    def test_telemetry_event_types_dropped(self) -> None:
        events = [
            {"type": "result", "created_at": "ts", "uuid": "r1"},
            {"type": "env_manager_log", "created_at": "ts", "uuid": "e1"},
            {"type": "tool_progress", "created_at": "ts", "uuid": "p1"},
            {"type": "control_request", "created_at": "ts", "uuid": "c1"},
            {"type": "rate_limit_event", "created_at": "ts", "uuid": "rl1"},
        ]
        entries = events_to_entries(events, "sid")
        assert entries == []

    def test_ordering_preserved(self) -> None:
        events = [
            {"type": "user", "created_at": "1", "uuid": "u1"},
            {"type": "assistant", "created_at": "2", "uuid": "a1"},
            {"type": "user", "created_at": "3", "uuid": "u2"},
        ]
        entries = events_to_entries(events, "sid")
        assert [e["uuid"] for e in entries] == ["u1", "a1", "u2"]

    def test_optional_fields_omitted_when_absent(self) -> None:
        events = [{"type": "user", "created_at": "ts", "uuid": "u1"}]
        entry = events_to_entries(events, "sid")[0]
        assert "parentUuid" not in entry
        assert "requestId" not in entry
        assert "isSynthetic" not in entry

    def test_synthetic_user_marked(self) -> None:
        events = [{"type": "user", "created_at": "ts", "uuid": "u1", "isSynthetic": True}]
        entry = events_to_entries(events, "sid")[0]
        assert entry["isSynthetic"] is True


class TestExtractMetadataShape:
    def test_empty_events_returns_zeros(self) -> None:
        meta = extract_metadata([], "sid")
        assert meta.session_id == "sid"
        assert meta.entry_count == 0
        assert meta.duration_seconds == 0
        assert meta.first_user_preview == ""
        assert meta.models == []

    def test_first_user_uuid_skips_synthetic(self) -> None:
        events: list[dict[str, Any]] = [
            {
                "type": "user",
                "created_at": "ts",
                "uuid": "synth",
                "isSynthetic": True,
            },
            {"type": "user", "created_at": "ts", "uuid": "real"},
        ]
        meta = extract_metadata(events, "sid")
        assert meta.first_user_uuid == "real"
        assert meta.user_turn_count == 1

    def test_models_union_from_assistant_and_result(self) -> None:
        events = [
            {
                "type": "assistant",
                "created_at": "ts",
                "uuid": "a1",
                "message": {"model": "claude-opus-4-7", "content": []},
            },
            {
                "type": "result",
                "created_at": "ts",
                "uuid": "r1",
                "modelUsage": {"claude-opus-4-7[1m]": {"costUSD": 0.1}},
            },
        ]
        meta = extract_metadata(events, "sid")
        assert set(meta.models) == {"claude-opus-4-7", "claude-opus-4-7[1m]"}

    def test_cwds_from_init_events(self) -> None:
        events = [
            {
                "type": "system",
                "subtype": "init",
                "created_at": "ts",
                "uuid": "i1",
                "cwd": "/home/user",
                "claude_code_version": "2.1.158",
            },
            {
                "type": "system",
                "subtype": "init",
                "created_at": "ts",
                "uuid": "i2",
                "cwd": "/home/user",
                "claude_code_version": "2.1.158",
            },
            {
                "type": "system",
                "subtype": "init",
                "created_at": "ts",
                "uuid": "i3",
                "cwd": "/tmp",
                "claude_code_version": "2.1.159",
            },
        ]
        meta = extract_metadata(events, "sid")
        assert meta.cwds == ["/home/user", "/tmp"]
        assert meta.cc_version == "2.1.159"

    def test_tool_call_count_from_assistant_blocks(self) -> None:
        events = [
            {
                "type": "assistant",
                "created_at": "ts",
                "uuid": "a1",
                "message": {
                    "content": [
                        {"type": "tool_use", "name": "Bash"},
                        {"type": "tool_use", "name": "Read"},
                        {"type": "text", "text": "x"},
                    ]
                },
            }
        ]
        meta = extract_metadata(events, "sid")
        assert meta.tool_call_count == 2

    def test_error_count_from_tool_results(self) -> None:
        events = [
            {
                "type": "user",
                "created_at": "ts",
                "uuid": "u1",
                "message": {
                    "content": [
                        {"type": "tool_result", "content": "ok", "is_error": False},
                        {"type": "tool_result", "content": "bad", "is_error": True},
                    ]
                },
            }
        ]
        meta = extract_metadata(events, "sid")
        assert meta.error_count == 1

    def test_first_user_preview_truncates_long_text(self) -> None:
        long_text = "x" * 200
        events = [
            {
                "type": "user",
                "created_at": "ts",
                "uuid": "u1",
                "message": {"content": long_text},
            }
        ]
        meta = extract_metadata(events, "sid")
        assert len(meta.first_user_preview) == 140
        assert meta.first_user_preview.endswith("...")

    def test_first_user_preview_first_line_only(self) -> None:
        events = [
            {
                "type": "user",
                "created_at": "ts",
                "uuid": "u1",
                "message": {"content": "line1\nline2\nline3"},
            }
        ]
        meta = extract_metadata(events, "sid")
        assert meta.first_user_preview == "line1"

    def test_duration_seconds_from_ISO_timestamps(self) -> None:
        events = [
            {"type": "user", "created_at": "2026-05-31T01:00:00Z", "uuid": "u1"},
            {"type": "assistant", "created_at": "2026-05-31T01:00:30Z", "uuid": "a1"},
        ]
        meta = extract_metadata(events, "sid")
        assert meta.duration_seconds == 30

    def test_duration_zero_on_unparseable_timestamp(self) -> None:
        events = [{"type": "user", "created_at": "not-iso", "uuid": "u1"}]
        meta = extract_metadata(events, "sid")
        assert meta.duration_seconds == 0


class TestFixtureRoundTrip:
    """The load-bearing test: a real 3438-event session translates cleanly.

    These assertions match the schema.json reference and the manual probe
    output. Any divergence is either a schema-drift signal (in which case the
    probe.py module's compare_to_schema should also fail) or a translator
    regression (in which case this test is the falsifier).
    """

    def test_session_id_present(self, fixture_events: tuple[str, list[dict[str, Any]]]) -> None:
        sid, _ = fixture_events
        assert sid.startswith("session_")

    def test_translation_yields_renderer_compatible_entries(
        self, fixture_events: tuple[str, list[dict[str, Any]]]
    ) -> None:
        sid, events = fixture_events
        entries = events_to_entries(events, sid)
        # user + assistant + system:init counts per schema.json
        assert len(entries) > 0
        types = {e["type"] for e in entries}
        assert types <= {"user", "assistant", "summary"}

    def test_every_entry_has_renderer_required_fields(
        self, fixture_events: tuple[str, list[dict[str, Any]]]
    ) -> None:
        sid, events = fixture_events
        entries = events_to_entries(events, sid)
        for entry in entries:
            assert isinstance(entry["type"], str)
            assert isinstance(entry["timestamp"], str)
            assert isinstance(entry["uuid"], str)
            assert isinstance(entry["sessionId"], str)

    def test_metadata_matches_known_counts(
        self, fixture_events: tuple[str, list[dict[str, Any]]]
    ) -> None:
        sid, events = fixture_events
        meta = extract_metadata(events, sid)
        # Per schema.json: 249 user events; some may be synthetic.
        assert meta.user_turn_count > 0
        assert meta.user_turn_count <= 249
        # 494 assistant events per schema.json.
        assert meta.assistant_turn_count == 494
        assert meta.first_user_uuid != ""
        assert meta.first_user_preview != ""

    def test_metadata_models_includes_opus_variant(
        self, fixture_events: tuple[str, list[dict[str, Any]]]
    ) -> None:
        sid, events = fixture_events
        meta = extract_metadata(events, sid)
        # The fixture's modelUsage carries the [1m] suffix variant.
        assert any("[1m]" in m for m in meta.models)

    def test_metadata_cc_version_recovered(
        self, fixture_events: tuple[str, list[dict[str, Any]]]
    ) -> None:
        sid, events = fixture_events
        meta = extract_metadata(events, sid)
        assert meta.cc_version != ""

    def test_metadata_cwds_recovered(
        self, fixture_events: tuple[str, list[dict[str, Any]]]
    ) -> None:
        sid, events = fixture_events
        meta = extract_metadata(events, sid)
        assert len(meta.cwds) > 0
        for cwd in meta.cwds:
            assert cwd.startswith("/")


class TestEventsMetadataDataclass:
    def test_default_lists_are_independent_instances(self) -> None:
        a = EventsMetadata(
            session_id="a",
            started_at="",
            ended_at="",
            duration_seconds=0,
            entry_count=0,
            user_turn_count=0,
            assistant_turn_count=0,
            tool_call_count=0,
            error_count=0,
            first_user_preview="",
            first_user_uuid="",
        )
        b = EventsMetadata(
            session_id="b",
            started_at="",
            ended_at="",
            duration_seconds=0,
            entry_count=0,
            user_turn_count=0,
            assistant_turn_count=0,
            tool_call_count=0,
            error_count=0,
            first_user_preview="",
            first_user_uuid="",
        )
        a.models.append("x")
        assert b.models == []
