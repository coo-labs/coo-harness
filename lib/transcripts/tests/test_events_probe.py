"""Schema-drift probe tests — fixture vs reference + envelope validation."""

from __future__ import annotations

import gzip
import json
from pathlib import Path
from typing import Any

from transcripts.events.probe import (
    SchemaDiff,
    compare_to_schema,
    default_reference_schema_path,
    load_reference_schema,
    validate_response_envelope,
)

_FIXTURE_PATH = (
    Path(__file__).resolve().parents[3]
    / "fixtures"
    / "events-api"
    / "session_0146dWU8wPHNwLyNLLJLuTYL.events.json.gz"
)


def _fixture_events() -> list[dict[str, Any]]:
    with gzip.open(_FIXTURE_PATH, "rt", encoding="utf-8") as f:
        raw = json.load(f)
    events: list[dict[str, Any]] = raw["events"]
    return events


class TestReferenceSchema:
    def test_default_path_resolves_to_existing_file(self) -> None:
        assert default_reference_schema_path().is_file()

    def test_load_returns_dict(self) -> None:
        schema = load_reference_schema()
        assert isinstance(schema, dict)
        assert "event_types_observed" in schema
        assert "translator_targets" in schema


class TestCompareToSchemaFixture:
    """The fixture is what the reference was derived from — diff must be clean."""

    def test_fixture_round_trip_is_clean(self) -> None:
        diff = compare_to_schema(_fixture_events())
        assert diff.is_clean(), (
            f"fixture-vs-reference drift detected:\n"
            f"  unknown: {diff.unknown_types}\n"
            f"  missing: {diff.missing_required_types}\n"
            f"  fields: {diff.unexpected_fields_by_type}"
        )


class TestCompareToSchemaSynthetic:
    def test_unknown_type_surfaces(self) -> None:
        events = [{"type": "novel_event_type", "uuid": "n1"}]
        diff = compare_to_schema(events)
        assert "novel_event_type" in diff.unknown_types

    def test_unexpected_field_surfaces(self) -> None:
        events = [
            {
                "type": "user",
                "uuid": "u1",
                "created_at": "ts",
                "message": {"content": "x"},
                "novel_field": "x",
            }
        ]
        diff = compare_to_schema(events)
        assert "user" in diff.unexpected_fields_by_type
        assert "novel_field" in diff.unexpected_fields_by_type["user"]

    def test_missing_required_type_surfaces(self) -> None:
        # Only user/system, no assistant → "assistant" missing per renderer_compatible.
        events: list[dict[str, Any]] = [
            {"type": "user", "uuid": "u1", "created_at": "ts", "message": {}},
            {"type": "system", "uuid": "s1", "subtype": "init"},
        ]
        diff = compare_to_schema(events)
        assert "assistant" in diff.missing_required_types

    def test_empty_events_misses_all_required_types(self) -> None:
        diff = compare_to_schema([])
        assert "user" in diff.missing_required_types
        assert "assistant" in diff.missing_required_types
        assert "system" in diff.missing_required_types

    def test_non_string_type_skipped(self) -> None:
        events = [{"type": 123, "uuid": "x"}]
        diff = compare_to_schema(events)
        # The malformed event doesn't count as an observed type.
        assert all(not isinstance(t, int) for t in diff.unknown_types)


class TestSchemaDiffIsClean:
    def test_all_empty_is_clean(self) -> None:
        diff = SchemaDiff()
        assert diff.is_clean() is True

    def test_unknown_dirty(self) -> None:
        diff = SchemaDiff(unknown_types=["x"])
        assert diff.is_clean() is False

    def test_missing_dirty(self) -> None:
        diff = SchemaDiff(missing_required_types=["x"])
        assert diff.is_clean() is False

    def test_fields_dirty(self) -> None:
        diff = SchemaDiff(unexpected_fields_by_type={"user": ["x"]})
        assert diff.is_clean() is False


class TestValidateResponseEnvelope:
    def test_clean_envelope_no_issues(self) -> None:
        issues = validate_response_envelope({"data": [{}], "has_more": False})
        assert issues == []

    def test_missing_data_flagged(self) -> None:
        issues = validate_response_envelope({"has_more": False})
        assert any("missing required envelope keys" in i for i in issues)

    def test_data_not_list_flagged(self) -> None:
        issues = validate_response_envelope({"data": "string", "has_more": False})
        assert any("data is str" in i for i in issues)

    def test_has_more_without_last_id_flagged(self) -> None:
        issues = validate_response_envelope({"data": [], "has_more": True})
        assert any("no last_id" in i for i in issues)

    def test_has_more_false_no_last_id_ok(self) -> None:
        issues = validate_response_envelope({"data": [], "has_more": False})
        assert issues == []
