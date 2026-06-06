"""Schema-drift probe — compares observed events against the pinned reference.

The probe runs in two contexts:

1. **CI parity** — load the pinned fixture under `fixtures/events-api/` and
   verify that the canonical event-type taxonomy + per-type field union still
   round-trips through the translator. The reference schema lives at
   `fixtures/events-api/schema.json` and is the source of truth for what the
   translator is built against.

2. **Live drift** — operator runs the events snippet with logging, captures
   the live response shape, feeds it through `compare_to_schema`. Surfaces
   any new event type, missing field, or shape change before the next
   ~80-session backfill batch runs against stale assumptions.

The live form requires the operator's cookie + the CCR header gate; it is not
called from any automated path. Phase 3 will add a Cloudflare-Worker-side
canary that pins one session and re-fetches nightly.

Reference-schema location is the published bundle; consumers pin against it
to avoid silent drift when the schema file evolves on `main` ahead of a
translator update.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from transcripts.events.client import REQUIRED_RESPONSE_KEYS

_DEFAULT_SCHEMA_RELPATH = "fixtures/events-api/schema.json"


def default_reference_schema_path() -> Path:
    """Locate `fixtures/events-api/schema.json` relative to the repo root.

    Walk up from this file's location (`lib/transcripts/events/probe.py`) to the
    repo root, then descend into fixtures. Two layers up from `events/` gets to
    `lib/`; three gets to the repo root.
    """
    return Path(__file__).resolve().parents[3] / _DEFAULT_SCHEMA_RELPATH


def load_reference_schema(path: Path | None = None) -> dict[str, Any]:
    """Read the schema reference JSON. Caller passes path for non-default repos."""
    target = path or default_reference_schema_path()
    with open(target, encoding="utf-8") as f:
        loaded = json.load(f)
    if not isinstance(loaded, dict):
        raise ValueError(f"reference schema at {target} is not a JSON object")
    return loaded


@dataclass
class SchemaDiff:
    """Drift report: zero-length on a clean match, populated when fields shifted.

    `unknown_types` — event types observed in input not present in the reference.
      A non-empty list signals that the API surfaced a new event family; the
      translator either ignores it (no harm; loses fidelity) or surfaces it
      (refactor required).
    `missing_required_types` — types declared in the reference's
      `translator_targets.renderer_compatible` not present in input. Typically
      benign on short sessions (e.g. system events absent on a 1-turn session).
    `unexpected_fields_by_type` — observed fields not in the reference's
      `event_types_observed.<type>.fields` list. Same disposition as
      unknown_types — the translator passes through `message.content` verbatim,
      so unknown sibling fields rarely matter.
    """

    unknown_types: list[str] = field(default_factory=list)
    missing_required_types: list[str] = field(default_factory=list)
    unexpected_fields_by_type: dict[str, list[str]] = field(default_factory=dict)

    def is_clean(self) -> bool:
        return (
            not self.unknown_types
            and not self.missing_required_types
            and not self.unexpected_fields_by_type
        )


def compare_to_schema(
    events: list[dict[str, Any]],
    schema: dict[str, Any] | None = None,
) -> SchemaDiff:
    """Diff observed events vs the reference schema."""
    schema = schema or load_reference_schema()
    declared = schema.get("event_types_observed") or {}
    targets = schema.get("translator_targets") or {}

    observed_types: dict[str, set[str]] = {}
    for ev in events:
        kind = ev.get("type")
        if not isinstance(kind, str):
            continue
        observed_types.setdefault(kind, set()).update(ev.keys())

    diff = SchemaDiff()

    for kind in observed_types:
        if kind not in declared:
            diff.unknown_types.append(kind)

    required = targets.get("renderer_compatible") or []
    for req in required:
        if isinstance(req, str) and req not in observed_types:
            diff.missing_required_types.append(req)

    for kind, fields in observed_types.items():
        if kind not in declared:
            continue
        declared_fields = set(declared[kind].get("fields", []))
        unexpected = sorted(fields - declared_fields)
        if unexpected:
            diff.unexpected_fields_by_type[kind] = unexpected

    return diff


def validate_response_envelope(body: dict[str, Any]) -> list[str]:
    """Check a paginated response envelope for the keys the snippet depends on.

    Returns a list of human-readable drift messages; empty on a clean envelope.
    Used by the snippet's Python-side counterpart (probe.py) and by intake.py
    if a future caller hands intake() raw page bodies instead of a dump file.
    """
    issues: list[str] = []
    missing = REQUIRED_RESPONSE_KEYS - body.keys()
    if missing:
        issues.append(f"missing required envelope keys: {sorted(missing)}")
    if "data" in body and not isinstance(body["data"], list):
        issues.append(f"data is {type(body['data']).__name__}, expected list")
    if body.get("has_more") and "last_id" not in body:
        issues.append("has_more=true but no last_id for next-page cursor")
    return issues
