"""Events-API recovery primitives.

The claude.ai server-side events stream is the canonical source for any session
whose local jsonl is unrecoverable (cohort B/C with broken ciphertext, dark-mass
sessions never exported). Operator runs `snippets/events-dump.js` from claude.ai
DevTools, scp's the resulting JSON to the container, then `bin/events-backfill`
ingests it: per session, translate events → renderer-compatible jsonl entries,
hand to the existing renderer, write sidecar to R2.

Public surface:
  - `PARSER_VERSION` — must match `snippets/events-dump.js _PARSER_VERSION`.
  - `CCR_HEADERS` — beta-header gate; MEMO-2026-06-05-dyb0.
  - `events_to_entries(events, sid)` — jsonl-shaped entries for the renderer.
  - `extract_metadata(events, sid)` — v3 sidecar fields direct from events.
  - `load_dump(path)` — parse a dump file into per-session payloads.
  - `probe.compare_to_schema(events)` — schema-drift diff vs the pinned fixture.

The parallel package `transcripts.backfill` orchestrates the per-session
translation → render → R2 write loop; everything here is pure data.
"""

from __future__ import annotations

from transcripts.events.client import (
    CCR_HEADERS,
    EVENTS_ENDPOINT_TEMPLATE,
    PARSER_VERSION,
    REQUIRED_RESPONSE_KEYS,
)
from transcripts.events.intake import (
    DumpEnvelopeError,
    SessionPayload,
    load_dump,
)
from transcripts.events.translator import (
    EventsMetadata,
    events_to_entries,
    extract_metadata,
)

__all__ = [
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
]
