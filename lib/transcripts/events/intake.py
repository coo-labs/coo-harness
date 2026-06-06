"""Dump-file parsing for `snippets/events-dump.js` output.

The operator runs `events-dump.js` in claude.ai DevTools, scp's the resulting
JSON file to the container, and the backfill driver consumes it through this
module. The snippet's output shape:

```json
{
  "parser_version": 2,
  "dumped_at": "ISO-8601 UTC",
  "org_uuid": "<operator org uuid>",
  "sessions": {"session_01abc...": [<events>], ...},
  "errors": [{"sid": "...", "page": N, "error": "..."}]
}
```

The pinned probe fixture under `fixtures/events-api/` carries a single-session
shape (one `sid` + `events[]` at the top level) — useful for probe/round-trip
tests, kept supported here so a future single-session debug dump round-trips
through the same loader.

Both shapes normalize to `list[SessionPayload]`. Per-session errors recorded by
the snippet during fetch are surfaced on the matching payload so the driver
can flag partial dumps without re-parsing the envelope.
"""

from __future__ import annotations

import gzip
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from transcripts.events.client import PARSER_VERSION


class DumpEnvelopeError(ValueError):
    """Raised when a dump file fails envelope validation.

    Validation is intentionally strict — a malformed dump is operator-fixable
    (rerun the snippet) and we'd rather refuse cleanly than corrupt the
    backfill manifest with half-translated junk.
    """


@dataclass
class SessionPayload:
    """One session's worth of events from a dump file.

    `events` is the raw list — translation happens later. `fetch_errors` is the
    subset of dump-envelope `errors[]` whose `sid` matches this session;
    typically empty on a clean dump, populated when the cookie expired mid-fetch
    or the gateway returned an HTTP error on a specific page.
    """

    session_id: str
    events: list[dict[str, Any]]
    fetch_errors: list[dict[str, Any]] = field(default_factory=list)


def load_dump(path: Path) -> tuple[list[SessionPayload], dict[str, Any]]:
    """Parse a dump file into per-session payloads + envelope metadata.

    `path` may be plain JSON or gzipped JSON (`.json.gz`); the format is
    detected by extension. Returns `(payloads, envelope_meta)` where
    `envelope_meta` carries the dump-level fields the caller may want to
    log or store on the backfill manifest (`parser_version`, `dumped_at`,
    `org_uuid`).

    Raises `DumpEnvelopeError` on:
      - parser_version mismatch (loud failure — translator's contract is
        version-pinned; silent acceptance would risk schema-drift corruption)
      - missing required envelope fields
      - non-dict session payloads in the multi-session shape
    """
    raw = _read_json(path)
    if not isinstance(raw, dict):
        raise DumpEnvelopeError(f"dump {path} is not a JSON object")

    version = raw.get("parser_version")
    if version != PARSER_VERSION:
        raise DumpEnvelopeError(
            f"dump {path} parser_version={version!r} but loader expects "
            f"{PARSER_VERSION} — re-run the snippet from "
            "snippets/events-dump.js or update the loader in lockstep"
        )

    envelope: dict[str, Any] = {
        "parser_version": version,
        "dumped_at": raw.get("dumped_at", ""),
        "org_uuid": raw.get("org_uuid", ""),
        "source_path": str(path),
    }

    sessions = raw.get("sessions")
    if isinstance(sessions, dict):
        payloads = _from_multi_session(sessions, raw.get("errors") or [])
    elif "sid" in raw and "events" in raw:
        payloads = _from_single_session(raw)
    else:
        raise DumpEnvelopeError(
            f"dump {path} has neither 'sessions' (multi) nor 'sid'+'events' "
            "(single) shape — re-run the snippet"
        )

    return payloads, envelope


def _read_json(path: Path) -> Any:
    if path.suffix == ".gz":
        with gzip.open(path, "rt", encoding="utf-8") as f:
            return json.load(f)
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _from_multi_session(
    sessions: dict[str, Any], errors: list[dict[str, Any]]
) -> list[SessionPayload]:
    by_sid: dict[str, list[dict[str, Any]]] = {}
    for err in errors:
        if not isinstance(err, dict):
            continue
        sid = err.get("sid")
        if not isinstance(sid, str):
            continue
        by_sid.setdefault(sid, []).append(err)

    payloads: list[SessionPayload] = []
    for sid, events in sessions.items():
        if not isinstance(events, list):
            raise DumpEnvelopeError(
                f"session {sid}: events is not a list (got {type(events).__name__})"
            )
        payloads.append(
            SessionPayload(
                session_id=sid,
                events=events,
                fetch_errors=by_sid.get(sid, []),
            )
        )
    return payloads


def _from_single_session(raw: dict[str, Any]) -> list[SessionPayload]:
    sid = raw["sid"]
    events = raw["events"]
    if not isinstance(sid, str):
        raise DumpEnvelopeError(f"single-session dump: sid is {type(sid).__name__}, expected str")
    if not isinstance(events, list):
        raise DumpEnvelopeError(
            f"single-session dump: events is {type(events).__name__}, expected list"
        )
    return [SessionPayload(session_id=sid, events=events)]
