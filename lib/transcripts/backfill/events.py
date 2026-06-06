"""Events-API → R2 backfill driver.

Per session in a dump file:

  1. Translate events to renderer-compatible jsonl entries
     (`transcripts.events.translator.events_to_entries`).
  2. Extract v3 sidecar metadata directly from events
     (`transcripts.events.translator.extract_metadata`); stamp
     `url_source="claudeai-events-uuid"` + `session_url`.
  3. Hand the translated entries to the existing renderer
     (`scripts/lifecycle/session-end-transcript-render.py` via subprocess
     with `--no-upload --output`) to produce HTML.
  4. Upload HTML + sidecar to R2 with first-write-wins semantics, respecting
     `provenance.is_authoritative` on the existing sidecar (no overwrite of
     authoritative tags).

Default is `--dry-run`: translate + render but don't upload. Apply with
`apply=True`. The driver returns a structured `BackfillReport` the CLI prints
and the operator commits to `coo-harness/state/events-backfill/manifest.jsonl`.

Renderer invocation is subprocess (not import) for the same reason
`transcript-render-backfill.py` does it: the renderer's argparse main is the
authoritative interface and stays so until the Phase 1 port lands a callable
`render_html` re-export under the lib.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any

from transcripts.events.intake import SessionPayload, load_dump
from transcripts.events.translator import events_to_entries, extract_metadata
from transcripts.provenance import is_authoritative
from transcripts.r2 import (
    R2Error,
    r2_client,
    read_sidecar,
    write_html_object,
    write_sidecar,
)
from transcripts.schema import PARSER_VERSION as RENDERER_VERSION

EVENTS_URL_SOURCE = "claudeai-events-uuid"


class BackfillStatus(str, Enum):
    """Per-session outcome bucket.

    `applied` — translated, rendered, both keys written to R2.
    `dry_run` — translated + rendered; no R2 writes attempted.
    `ceded_authoritative` — existing sidecar carries an authoritative tag from
        a different source (e.g., env-recovery from a live session); the driver
        refuses to overwrite. The HTML write was skipped for consistency.
    `skipped_no_entries` — no user/assistant/init events survived translation
        (typical for control-plane-only sessions).
    `skipped_fetch_error` — the dump envelope flagged fetch errors against this
        session id (cookie expired mid-page); operator re-runs after refreshing.
    `error` — translation or render subprocess failed; details in `error_detail`.
    """

    APPLIED = "applied"
    DRY_RUN = "dry_run"
    CEDED_AUTHORITATIVE = "ceded_authoritative"
    SKIPPED_NO_ENTRIES = "skipped_no_entries"
    SKIPPED_FETCH_ERROR = "skipped_fetch_error"
    ERROR = "error"


@dataclass
class BackfillResult:
    """Per-session record written to the backfill manifest."""

    session_id: str
    status: BackfillStatus
    entry_count: int = 0
    user_turn_count: int = 0
    assistant_turn_count: int = 0
    html_bytes: int = 0
    error_detail: str = ""

    def to_jsonl(self) -> str:
        """One-line JSON serialization for the append-only manifest."""
        payload = {
            "session_id": self.session_id,
            "status": self.status.value,
            "entry_count": self.entry_count,
            "user_turn_count": self.user_turn_count,
            "assistant_turn_count": self.assistant_turn_count,
            "html_bytes": self.html_bytes,
        }
        if self.error_detail:
            payload["error_detail"] = self.error_detail
        return json.dumps(payload, separators=(",", ":"))


@dataclass
class BackfillReport:
    """Aggregate result of one driver invocation."""

    started_at: str
    finished_at: str
    dump_path: str
    org_uuid: str
    apply: bool
    results: list[BackfillResult] = field(default_factory=list)

    def counts_by_status(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for r in self.results:
            counts[r.status.value] = counts.get(r.status.value, 0) + 1
        return counts


def backfill_dump(
    dump_path: Path,
    *,
    apply: bool = False,
    renderer_script: Path | None = None,
    s3: Any = None,
    only_session_ids: set[str] | None = None,
) -> BackfillReport:
    """Process every session in a dump file.

    `apply=False` (default) translates and renders but writes nothing to R2.
    `only_session_ids`, if set, filters the dump to a subset — useful for
    iterating on a single problem session without re-processing 80.

    `renderer_script` overrides the default path lookup; tests pass a fake.
    Passing `s3=` injects a pre-built boto3 client (tests use a mock).
    """
    started = _iso_now()
    payloads, envelope = load_dump(dump_path)

    if apply and s3 is None:
        s3 = r2_client()

    report = BackfillReport(
        started_at=started,
        finished_at="",
        dump_path=str(dump_path),
        org_uuid=envelope.get("org_uuid", ""),
        apply=apply,
    )

    renderer = renderer_script or _default_renderer_script()

    for payload in payloads:
        if only_session_ids is not None and payload.session_id not in only_session_ids:
            continue
        result = _process_session(payload, renderer=renderer, apply=apply, s3=s3)
        report.results.append(result)

    report.finished_at = _iso_now()
    return report


def _process_session(  # noqa: PLR0911 — one return per outcome bucket; refactoring obscures the gate sequence
    payload: SessionPayload,
    *,
    renderer: Path,
    apply: bool,
    s3: Any,
) -> BackfillResult:
    sid = payload.session_id

    if payload.fetch_errors:
        return BackfillResult(
            session_id=sid,
            status=BackfillStatus.SKIPPED_FETCH_ERROR,
            error_detail=_summarize_fetch_errors(payload.fetch_errors),
        )

    entries = events_to_entries(payload.events, sid)
    if not entries:
        return BackfillResult(
            session_id=sid,
            status=BackfillStatus.SKIPPED_NO_ENTRIES,
        )

    meta = extract_metadata(payload.events, sid)

    try:
        html_bytes = _render_via_subprocess(renderer, sid, entries)
    except _RenderError as e:
        return BackfillResult(
            session_id=sid,
            status=BackfillStatus.ERROR,
            entry_count=meta.entry_count,
            user_turn_count=meta.user_turn_count,
            assistant_turn_count=meta.assistant_turn_count,
            error_detail=f"render: {e}",
        )

    if not apply:
        return BackfillResult(
            session_id=sid,
            status=BackfillStatus.DRY_RUN,
            entry_count=meta.entry_count,
            user_turn_count=meta.user_turn_count,
            assistant_turn_count=meta.assistant_turn_count,
            html_bytes=len(html_bytes),
        )

    try:
        existing = read_sidecar(sid, s3=s3)
    except R2Error as e:
        return BackfillResult(
            session_id=sid,
            status=BackfillStatus.ERROR,
            entry_count=meta.entry_count,
            error_detail=f"read existing sidecar: {e}",
        )

    if existing is not None:
        existing_source = existing.get("url_source")
        if (
            isinstance(existing_source, str)
            and is_authoritative(existing_source)
            and existing_source != EVENTS_URL_SOURCE
        ):
            return BackfillResult(
                session_id=sid,
                status=BackfillStatus.CEDED_AUTHORITATIVE,
                entry_count=meta.entry_count,
                user_turn_count=meta.user_turn_count,
                assistant_turn_count=meta.assistant_turn_count,
                error_detail=f"existing url_source={existing_source!r}",
            )

    overwrite = existing is not None
    write_html_object(sid, html_bytes, overwrite=overwrite, s3=s3)
    sidecar = _build_sidecar(meta)
    write_sidecar(sid, sidecar, overwrite=overwrite, s3=s3)

    return BackfillResult(
        session_id=sid,
        status=BackfillStatus.APPLIED,
        entry_count=meta.entry_count,
        user_turn_count=meta.user_turn_count,
        assistant_turn_count=meta.assistant_turn_count,
        html_bytes=len(html_bytes),
    )


def _build_sidecar(meta: Any) -> dict[str, Any]:
    """Render the v3 sidecar dict, with events-API provenance stamped on."""
    return {
        "session_id": meta.session_id,
        "started_at": meta.started_at or None,
        "ended_at": meta.ended_at or None,
        "duration_seconds": meta.duration_seconds,
        "entry_count": meta.entry_count,
        "user_turn_count": meta.user_turn_count,
        "assistant_turn_count": meta.assistant_turn_count,
        "tool_call_count": meta.tool_call_count,
        "error_count": meta.error_count,
        "first_user_preview": meta.first_user_preview,
        "first_user_uuid": meta.first_user_uuid,
        "models": meta.models,
        "cwds": meta.cwds,
        "cc_version": meta.cc_version,
        "session_url": f"https://claude.ai/code/{meta.session_id}",
        "url_source": EVENTS_URL_SOURCE,
        "renderer_version": RENDERER_VERSION,
    }


class _RenderError(RuntimeError):
    """Raised when the renderer subprocess fails."""


def _render_via_subprocess(renderer: Path, sid: str, entries: list[dict[str, Any]]) -> bytes:
    """Write entries to a tmp jsonl, invoke the renderer, capture HTML output.

    Returns the rendered HTML bytes. Raises `_RenderError` on subprocess
    failure or empty output. Temp files are cleaned up on every path.
    """
    with tempfile.TemporaryDirectory(prefix="events-backfill-") as td:
        td_path = Path(td)
        jsonl_path = td_path / f"{sid}.jsonl"
        html_path = td_path / f"{sid}.html"

        with open(jsonl_path, "w", encoding="utf-8") as f:
            for entry in entries:
                f.write(json.dumps(entry, separators=(",", ":")))
                f.write("\n")

        cmd = [
            sys.executable,
            str(renderer),
            "--input",
            str(jsonl_path),
            "--session-id",
            sid,
            "--no-upload",
            "--output",
            str(html_path),
        ]
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        if result.returncode != 0:
            raise _RenderError(f"renderer rc={result.returncode}: {result.stderr.strip()[:240]}")
        if not html_path.exists():
            raise _RenderError("renderer wrote no output file")
        return html_path.read_bytes()


def _default_renderer_script() -> Path:
    """Path to scripts/lifecycle/session-end-transcript-render.py from this file.

    Three layers up from lib/transcripts/backfill/events.py reaches the repo root.
    """
    return (
        Path(__file__).resolve().parents[3]
        / "scripts"
        / "lifecycle"
        / "session-end-transcript-render.py"
    )


_FETCH_ERROR_SAMPLE_SIZE = 2


def _summarize_fetch_errors(errors: list[dict[str, Any]]) -> str:
    head = errors[:_FETCH_ERROR_SAMPLE_SIZE]
    rendered = "; ".join(f"page={e.get('page')} err={e.get('error', '')[:80]}" for e in head)
    extra = len(errors) - _FETCH_ERROR_SAMPLE_SIZE
    if extra > 0:
        rendered += f" (+{extra} more)"
    return rendered


def _iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()
