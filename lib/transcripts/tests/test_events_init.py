"""Smoke tests for the transcripts.events public surface."""

from __future__ import annotations

import transcripts.events as events_pkg
from transcripts import write_html_object, write_sidecar

_EXPECTED_PUBLIC = {
    "CCR_HEADERS",
    "EVENTS_ENDPOINT_TEMPLATE",
    "PARSER_VERSION",
    "REQUIRED_RESPONSE_KEYS",
    "DumpEnvelopeError",
    "EventsMetadata",
    "SessionPayload",
    "events_to_entries",
    "extract_metadata",
    "load_dump",
}


class TestEventsPackageSurface:
    def test_all_lists_the_public_surface(self) -> None:
        assert set(events_pkg.__all__) == _EXPECTED_PUBLIC

    def test_each_member_resolvable(self) -> None:
        for name in events_pkg.__all__:
            assert hasattr(events_pkg, name), f"missing public export: {name}"


class TestTopLevelLibReExports:
    """The events module is reachable as `transcripts.events`; primitives
    used by hooks (e.g., write_html_object) re-export from the package root."""

    def test_write_html_object_reachable_from_lib_root(self) -> None:
        assert callable(write_html_object)

    def test_write_sidecar_still_reachable(self) -> None:
        assert callable(write_sidecar)
