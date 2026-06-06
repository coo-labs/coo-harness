"""Transport constants and shape contracts for the events-API.

The operator-facing fetch happens in `snippets/events-dump.js` (browser-paste
under the operator's session cookie). This module mirrors the constants the
snippet enforces so that `probe.py` and any future Python-side fetcher (a
short-lived debug probe carrying the operator's cookie via env) speak the same
gate.

`PARSER_VERSION` is the single coordinating number across the JS snippet, the
Python translator, and the on-disk dump envelope. Any change here must move in
lockstep with `snippets/events-dump.js _PARSER_VERSION` (asserted at startup
when the snippet's output is loaded — see intake.py).

`CCR_HEADERS` + `x-organization-uuid` are the load-bearing authentication gate
per [MEMO-2026-06-05-dyb0](../../../../coo-memory/memos/2026-06-05-dyb0.md).
Cookie auth alone returns 404; the gateway routes the un-CCR-gated request to a
generic list-handler that 400s with a misleading "Unknown query parameter"
referencing an unrelated param taxonomy.
"""

from __future__ import annotations

from typing import Final

PARSER_VERSION: Final[int] = 2

CCR_HEADERS: Final[dict[str, str]] = {
    "anthropic-beta": "ccr-byoc-2025-07-29",
    "anthropic-client-feature": "ccr",
    "anthropic-client-platform": "web_claude_ai",
    "anthropic-version": "2023-06-01",
}

EVENTS_ENDPOINT_TEMPLATE: Final[str] = "https://claude.ai/v1/sessions/{sid}/events"

REQUIRED_RESPONSE_KEYS: Final[frozenset[str]] = frozenset({"data", "has_more"})
"""Keys the events-API response envelope must carry.

`last_id` is checked separately — it's only required when `has_more` is true, so
treating it as universally required would false-positive on the final page.
"""
