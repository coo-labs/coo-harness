"""Server-side events → renderer-compatible jsonl entries + sidecar metadata.

The renderer at `scripts/lifecycle/session-end-transcript-render.py` expects
jsonl entries shaped like the local Claude Code transcript: top-level `type`,
`timestamp`, `uuid`, plus `message.content` carrying the per-role payload. The
events stream uses `created_at` instead of `timestamp` and emits a wider type
taxonomy (system / env_manager_log / result / tool_progress / ...). This module
maps one to the other.

## Translation rules (v1)

| Event type                | Becomes              | Why                                       |
|---------------------------|----------------------|-------------------------------------------|
| `user`                    | type=`user`          | content already renderer-shaped           |
| `assistant`               | type=`assistant`     | content already renderer-shaped           |
| `system` subtype=`init`   | type=`summary` meta  | source of cwd + claude_code_version       |
| `system` (other subtypes) | dropped              | telemetry — future v2 if value emerges    |
| `result`                  | dropped              | metadata-only via `extract_metadata`      |
| `env_manager_log`         | dropped              | container telemetry, not renderer-fidelity|
| `tool_progress`           | dropped              | streaming partials; archival via result   |
| `control_request|response`| dropped              | session-control plane                     |
| `rate_limit_event`        | dropped              | telemetry                                 |

`extract_metadata` is the canonical v3 sidecar source for events-recovered
sessions — the renderer's `compute_metadata` operates on entries and would
miss the richer model variants surfaced by `result.modelUsage` keys (the local
`message.model` lacks the `[1m]` suffix on the 1M-context Opus variant).

## Stability

- `events_to_entries` is pure: same input always produces the same output.
- Field renames are documented inline. If the events-API drifts, the probe
  (`transcripts.events.probe`) surfaces it before the next backfill.
- Per Decision: synthetic init entries carry only the subset the renderer reads
  (`cwd`, `version`, `uuid`, `timestamp`, `type`) — not the full init payload.
  Full init payload retention is a follow-up if the v3 sidecar gains fields.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

_PREVIEW_MAX_LEN = 140


@dataclass(frozen=True)
class EventsMetadata:
    """v3 sidecar fields extracted directly from the events stream.

    Mirrors the renderer-computed metadata block but sourced from the raw events
    (richer than the renderer's per-entry walk because `result.modelUsage` keys
    carry the `[1m]` variant the assistant message-level `model` field omits).

    `started_at` / `ended_at` are ISO-8601 strings or empty when no timestamped
    event was present. `duration_seconds` is 0 in that case.
    """

    session_id: str
    started_at: str
    ended_at: str
    duration_seconds: int
    entry_count: int
    user_turn_count: int
    assistant_turn_count: int
    tool_call_count: int
    error_count: int
    first_user_preview: str
    first_user_uuid: str
    models: list[str] = field(default_factory=list)
    cwds: list[str] = field(default_factory=list)
    cc_version: str = ""


_RENDERER_PASS_THROUGH: frozenset[str] = frozenset({"user", "assistant"})


def events_to_entries(events: list[dict[str, Any]], session_id: str) -> list[dict[str, Any]]:
    """Map events stream → renderer-compatible jsonl entries.

    `session_id` is the canonical session id — used to fill the `sessionId`
    field on entries whose event payload had an empty `session_id` (the leading
    bootstrap events on a freshly-created session can carry `""`).

    Output ordering follows event ordering (events are server-ordered by
    `created_at`); the renderer's elapsed-time computation depends on this.
    """
    entries: list[dict[str, Any]] = []
    for ev in events:
        kind = ev.get("type")
        if kind in _RENDERER_PASS_THROUGH:
            entries.append(_pass_through(ev, session_id))
        elif kind == "system" and ev.get("subtype") == "init":
            entries.append(_init_meta(ev, session_id))
    return entries


def _pass_through(ev: dict[str, Any], session_id: str) -> dict[str, Any]:
    """Rename event fields onto a jsonl-shaped entry without semantic change.

    `created_at` → `timestamp` is the only structural rename; everything else
    is preserved verbatim so the renderer's classifier and per-role formatters
    see exactly what they would on a local jsonl.
    """
    entry: dict[str, Any] = {
        "type": ev["type"],
        "timestamp": ev.get("created_at", ""),
        "uuid": ev.get("uuid", ""),
        "sessionId": ev.get("session_id") or session_id,
    }
    if "message" in ev:
        entry["message"] = ev["message"]
    if ev.get("parent_tool_use_id"):
        entry["parentUuid"] = ev["parent_tool_use_id"]
    if ev.get("request_id"):
        entry["requestId"] = ev["request_id"]
    if "isSynthetic" in ev:
        entry["isSynthetic"] = ev["isSynthetic"]
    if "client_platform" in ev:
        entry["client_platform"] = ev["client_platform"]
    return entry


def _init_meta(ev: dict[str, Any], session_id: str) -> dict[str, Any]:
    """Synthetic meta entry from a `system` `subtype=init` event.

    `type=summary` is the renderer's existing meta classification (one of the
    four bucketed under `_classify` → "meta"). Carries `cwd` + `version` at
    the top level so the renderer's `compute_metadata` populates the v3
    `cwds` / `cc_version` fields without bespoke logic.
    """
    return {
        "type": "summary",
        "timestamp": ev.get("created_at", ""),
        "uuid": ev.get("uuid", ""),
        "sessionId": session_id,
        "cwd": ev.get("cwd", ""),
        "version": ev.get("claude_code_version", ""),
        "summary": _init_summary(ev),
    }


def _init_summary(ev: dict[str, Any]) -> str:
    """Short human-readable label for an init meta entry.

    Surfaces in the renderer's `_render_meta` summary slot; keeps the rendered
    HTML scannable without bloating the entry payload.
    """
    cwd = ev.get("cwd", "")
    ver = ev.get("claude_code_version", "")
    perm = ev.get("permissionMode", "")
    bits = []
    if cwd:
        bits.append(f"cwd={cwd}")
    if ver:
        bits.append(f"cc={ver}")
    if perm:
        bits.append(f"perm={perm}")
    return "init: " + ", ".join(bits) if bits else "init"


@dataclass
class _MetadataAccumulator:
    """Mutable scratch state for one `extract_metadata` pass.

    Split out so per-type handlers stay small enough to read; lives entirely
    inside the module — not part of the public surface.
    """

    first_ts: str = ""
    last_ts: str = ""
    user_count: int = 0
    assistant_count: int = 0
    tool_call_count: int = 0
    error_count: int = 0
    entry_count: int = 0
    first_user_uuid: str = ""
    first_user_preview: str = ""
    models: list[str] = field(default_factory=list)
    cwds: list[str] = field(default_factory=list)
    cc_version: str = ""


def _add_unique(lst: list[str], val: str) -> None:
    if val and val not in lst:
        lst.append(val)


def _update_user(acc: _MetadataAccumulator, ev: dict[str, Any]) -> None:
    acc.entry_count += 1
    if ev.get("isSynthetic"):
        return
    acc.user_count += 1
    if not acc.first_user_uuid:
        acc.first_user_uuid = ev.get("uuid", "")
    if not acc.first_user_preview:
        acc.first_user_preview = _user_preview(ev)
    acc.error_count += _count_tool_result_errors(ev)


def _update_assistant(acc: _MetadataAccumulator, ev: dict[str, Any]) -> None:
    acc.entry_count += 1
    acc.assistant_count += 1
    msg = ev.get("message", {}) or {}
    model = msg.get("model")
    if isinstance(model, str):
        _add_unique(acc.models, model)
    acc.tool_call_count += _count_tool_uses(ev)


def _update_system(acc: _MetadataAccumulator, ev: dict[str, Any]) -> None:
    if ev.get("subtype") != "init":
        return
    acc.entry_count += 1
    ver = ev.get("claude_code_version", "")
    if isinstance(ver, str) and ver:
        acc.cc_version = ver
    cwd = ev.get("cwd", "")
    if isinstance(cwd, str):
        _add_unique(acc.cwds, cwd)


def _update_result(acc: _MetadataAccumulator, ev: dict[str, Any]) -> None:
    """result events surface the [1m] model variants the assistant key omits."""
    mu = ev.get("modelUsage") or {}
    for model_key in mu:
        if isinstance(model_key, str):
            _add_unique(acc.models, model_key)


_KIND_HANDLERS: dict[str, Any] = {
    "user": _update_user,
    "assistant": _update_assistant,
    "system": _update_system,
}


def extract_metadata(events: list[dict[str, Any]], session_id: str) -> EventsMetadata:
    """Compute v3 sidecar fields directly from the events stream.

    Authoritative for events-recovered sessions. The renderer's
    `compute_metadata` can be run on the translated entries as a parity check,
    but the canonical sidecar comes from here because `result.modelUsage` keys
    carry the `[1m]` variant the per-entry walk misses.
    """
    acc = _MetadataAccumulator()

    for ev in events:
        ts = ev.get("created_at", "")
        if ts:
            if not acc.first_ts:
                acc.first_ts = ts
            acc.last_ts = ts

        kind = ev.get("type")
        handler = _KIND_HANDLERS.get(kind) if isinstance(kind, str) else None
        if handler is None:
            if kind == "result":
                _update_result(acc, ev)
            continue
        handler(acc, ev)

    duration = _compute_duration_seconds(acc.first_ts, acc.last_ts)

    return EventsMetadata(
        session_id=session_id,
        started_at=acc.first_ts,
        ended_at=acc.last_ts,
        duration_seconds=duration,
        entry_count=acc.entry_count,
        user_turn_count=acc.user_count,
        assistant_turn_count=acc.assistant_count,
        tool_call_count=acc.tool_call_count,
        error_count=acc.error_count,
        first_user_preview=acc.first_user_preview,
        first_user_uuid=acc.first_user_uuid,
        models=acc.models,
        cwds=acc.cwds,
        cc_version=acc.cc_version,
    )


def _user_preview(ev: dict[str, Any]) -> str:
    """First-line preview of a user event's content, truncated to 140 chars.

    Mirrors the renderer's `_first_line(text, 140)` convention so events-recovered
    sidecars don't visibly differ from locally-rendered sidecars on the list page.
    """
    msg = ev.get("message", {}) or {}
    content = msg.get("content")
    text = ""
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text", "")
                break
    text = text.strip()
    if not text:
        return ""
    first_line = text.split("\n", 1)[0]
    if len(first_line) > _PREVIEW_MAX_LEN:
        return first_line[: _PREVIEW_MAX_LEN - 3] + "..."
    return first_line


def _count_tool_uses(ev: dict[str, Any]) -> int:
    msg = ev.get("message", {}) or {}
    content = msg.get("content")
    if not isinstance(content, list):
        return 0
    return sum(1 for b in content if isinstance(b, dict) and b.get("type") == "tool_use")


def _count_tool_result_errors(ev: dict[str, Any]) -> int:
    msg = ev.get("message", {}) or {}
    content = msg.get("content")
    if not isinstance(content, list):
        return 0
    return sum(
        1
        for b in content
        if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error")
    )


def _compute_duration_seconds(first_ts: str, last_ts: str) -> int:
    if not first_ts or not last_ts:
        return 0
    try:
        start = datetime.fromisoformat(first_ts.replace("Z", "+00:00"))
        end = datetime.fromisoformat(last_ts.replace("Z", "+00:00"))
    except ValueError:
        return 0
    return max(0, int((end - start).total_seconds()))
