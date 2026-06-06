"""Intake tests — both dump shapes + envelope validation."""

from __future__ import annotations

import gzip
import json
from pathlib import Path
from typing import Any

import pytest

from transcripts.events.client import PARSER_VERSION
from transcripts.events.intake import DumpEnvelopeError, load_dump


def _write(tmp_path: Path, name: str, payload: dict[str, Any]) -> Path:
    target = tmp_path / name
    if name.endswith(".gz"):
        with gzip.open(target, "wt", encoding="utf-8") as f:
            json.dump(payload, f)
    else:
        target.write_text(json.dumps(payload), encoding="utf-8")
    return target


class TestMultiSessionShape:
    def test_two_sessions_parse_in_declared_order(self, tmp_path: Path) -> None:
        path = _write(
            tmp_path,
            "dump.json",
            {
                "parser_version": PARSER_VERSION,
                "dumped_at": "2026-06-06T00:00:00Z",
                "org_uuid": "org-abc",
                "sessions": {
                    "session_01abc": [{"type": "user", "uuid": "u1"}],
                    "session_02def": [{"type": "assistant", "uuid": "a1"}],
                },
                "errors": [],
            },
        )
        payloads, envelope = load_dump(path)
        assert [p.session_id for p in payloads] == ["session_01abc", "session_02def"]
        assert envelope["org_uuid"] == "org-abc"
        assert envelope["dumped_at"] == "2026-06-06T00:00:00Z"
        assert envelope["parser_version"] == PARSER_VERSION

    def test_errors_routed_to_matching_session(self, tmp_path: Path) -> None:
        path = _write(
            tmp_path,
            "dump.json",
            {
                "parser_version": PARSER_VERSION,
                "dumped_at": "ts",
                "org_uuid": "x",
                "sessions": {"session_01": [], "session_02": []},
                "errors": [
                    {"sid": "session_01", "page": 0, "error": "HTTP 429"},
                    {"sid": "session_02", "page": 2, "error": "cookie expired"},
                ],
            },
        )
        payloads, _ = load_dump(path)
        by_sid = {p.session_id: p for p in payloads}
        assert by_sid["session_01"].fetch_errors[0]["error"] == "HTTP 429"
        assert by_sid["session_02"].fetch_errors[0]["error"] == "cookie expired"

    def test_orphan_errors_no_match_silently_dropped(self, tmp_path: Path) -> None:
        path = _write(
            tmp_path,
            "dump.json",
            {
                "parser_version": PARSER_VERSION,
                "dumped_at": "ts",
                "org_uuid": "x",
                "sessions": {"session_01": []},
                "errors": [{"sid": "session_other", "page": 0, "error": "x"}],
            },
        )
        payloads, _ = load_dump(path)
        assert payloads[0].fetch_errors == []

    def test_malformed_error_entry_skipped(self, tmp_path: Path) -> None:
        path = _write(
            tmp_path,
            "dump.json",
            {
                "parser_version": PARSER_VERSION,
                "dumped_at": "ts",
                "org_uuid": "x",
                "sessions": {"session_01": []},
                "errors": ["not a dict", {"no_sid_key": "x"}],
            },
        )
        payloads, _ = load_dump(path)
        assert payloads[0].fetch_errors == []

    def test_non_list_events_raises(self, tmp_path: Path) -> None:
        path = _write(
            tmp_path,
            "dump.json",
            {
                "parser_version": PARSER_VERSION,
                "dumped_at": "ts",
                "org_uuid": "x",
                "sessions": {"session_01": "not a list"},
            },
        )
        with pytest.raises(DumpEnvelopeError, match="events is not a list"):
            load_dump(path)


class TestSingleSessionShape:
    def test_parses_single_session_dump(self, tmp_path: Path) -> None:
        path = _write(
            tmp_path,
            "dump.json",
            {
                "parser_version": PARSER_VERSION,
                "dumped_at": "ts",
                "org_uuid": "x",
                "sid": "session_solo",
                "events": [{"type": "user", "uuid": "u1"}],
                "event_count": 1,
            },
        )
        payloads, envelope = load_dump(path)
        assert len(payloads) == 1
        assert payloads[0].session_id == "session_solo"
        assert envelope["parser_version"] == PARSER_VERSION

    def test_non_string_sid_raises(self, tmp_path: Path) -> None:
        path = _write(
            tmp_path,
            "dump.json",
            {
                "parser_version": PARSER_VERSION,
                "dumped_at": "ts",
                "org_uuid": "x",
                "sid": 123,
                "events": [],
            },
        )
        with pytest.raises(DumpEnvelopeError, match="sid is"):
            load_dump(path)

    def test_non_list_events_raises(self, tmp_path: Path) -> None:
        path = _write(
            tmp_path,
            "dump.json",
            {
                "parser_version": PARSER_VERSION,
                "dumped_at": "ts",
                "org_uuid": "x",
                "sid": "session_x",
                "events": {"not": "a list"},
            },
        )
        with pytest.raises(DumpEnvelopeError, match="events is"):
            load_dump(path)


class TestEnvelopeValidation:
    def test_wrong_parser_version_raises(self, tmp_path: Path) -> None:
        path = _write(
            tmp_path,
            "dump.json",
            {
                "parser_version": PARSER_VERSION + 99,
                "dumped_at": "ts",
                "org_uuid": "x",
                "sessions": {},
            },
        )
        with pytest.raises(DumpEnvelopeError, match="parser_version"):
            load_dump(path)

    def test_unrecognized_shape_raises(self, tmp_path: Path) -> None:
        path = _write(
            tmp_path,
            "dump.json",
            {
                "parser_version": PARSER_VERSION,
                "dumped_at": "ts",
                "org_uuid": "x",
                "events": [],  # no sid → not single-session; no sessions → not multi
            },
        )
        with pytest.raises(DumpEnvelopeError, match=r"multi.*single"):
            load_dump(path)

    def test_top_level_non_dict_raises(self, tmp_path: Path) -> None:
        path = tmp_path / "dump.json"
        path.write_text(json.dumps([]), encoding="utf-8")
        with pytest.raises(DumpEnvelopeError, match="not a JSON object"):
            load_dump(path)

    def test_gzip_dump_supported(self, tmp_path: Path) -> None:
        path = _write(
            tmp_path,
            "dump.json.gz",
            {
                "parser_version": PARSER_VERSION,
                "dumped_at": "ts",
                "org_uuid": "x",
                "sessions": {"session_gz": []},
            },
        )
        payloads, _ = load_dump(path)
        assert payloads[0].session_id == "session_gz"
