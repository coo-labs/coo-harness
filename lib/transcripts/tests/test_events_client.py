"""Client constants tests — the lockstep contract with the JS snippet.

PARSER_VERSION here MUST match snippets/events-dump.js. This test reads the
snippet directly and asserts equality so a future bump in only one place fires
loudly at PR-open time.
"""

from __future__ import annotations

import re
from pathlib import Path

from transcripts.events.client import (
    CCR_HEADERS,
    EVENTS_ENDPOINT_TEMPLATE,
    PARSER_VERSION,
    REQUIRED_RESPONSE_KEYS,
)

_SNIPPET_PATH = Path(__file__).resolve().parents[3] / "snippets" / "events-dump.js"


class TestParserVersionLockstep:
    """If this fails, the JS snippet and the Python loader disagree.

    Bump both in the same PR or the dump file the operator generates will
    fail intake validation with `parser_version` mismatch.
    """

    def test_python_constant_matches_snippet(self) -> None:
        snippet = _SNIPPET_PATH.read_text(encoding="utf-8")
        match = re.search(r"_PARSER_VERSION\s*=\s*(\d+)", snippet)
        assert match is not None, "could not find _PARSER_VERSION in snippets/events-dump.js"
        assert int(match.group(1)) == PARSER_VERSION


class TestCcrHeaders:
    def test_beta_flag_present(self) -> None:
        assert CCR_HEADERS["anthropic-beta"] == "ccr-byoc-2025-07-29"

    def test_client_feature_ccr(self) -> None:
        assert CCR_HEADERS["anthropic-client-feature"] == "ccr"

    def test_platform_web_claude_ai(self) -> None:
        assert CCR_HEADERS["anthropic-client-platform"] == "web_claude_ai"

    def test_version_2023_06_01(self) -> None:
        assert CCR_HEADERS["anthropic-version"] == "2023-06-01"

    def test_no_organization_uuid_in_static_dict(self) -> None:
        # x-organization-uuid is per-operator; must NOT be a constant.
        assert "x-organization-uuid" not in CCR_HEADERS


class TestEndpointTemplate:
    def test_template_takes_sid(self) -> None:
        url = EVENTS_ENDPOINT_TEMPLATE.format(sid="session_01abc")
        assert url == "https://claude.ai/v1/sessions/session_01abc/events"

    def test_template_uses_claude_ai_host(self) -> None:
        assert EVENTS_ENDPOINT_TEMPLATE.startswith("https://claude.ai/")


class TestRequiredResponseKeys:
    def test_contains_data(self) -> None:
        assert "data" in REQUIRED_RESPONSE_KEYS

    def test_contains_has_more(self) -> None:
        assert "has_more" in REQUIRED_RESPONSE_KEYS

    def test_does_not_contain_last_id(self) -> None:
        # last_id is conditionally required — only when has_more=True.
        assert "last_id" not in REQUIRED_RESPONSE_KEYS
