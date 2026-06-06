"""coo-harness internal transcripts library.

Primitive layer for the VADE transcript pipeline. Consolidates the R2 / schema /
provenance code that was previously copy-pasted across scripts/lib/ and
scripts/lifecycle/. Hooks and CLI scripts import primitives from here;
orchestration (the SessionEnd hook, mass-mutation drivers) stays in scripts/.

Public surface is what's re-exported below. Anything not in __all__ is private
to the module and may change without notice.

Schema imports are lazy (PEP 562 __getattr__): the export Stop-hook runs under
`uv run --script` with PEP 723 inline deps that include only boto3, not
pydantic. An eager `from transcripts.schema import ...` here would force every
consumer to ship pydantic in its inline deps, which breaks the Stop-hook's cold
boot. Schema symbols load on first attribute access instead.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from transcripts.jsonl import (
    AUTO_NOTIFICATION_RES,
    SYSTEM_REMINDER_RE,
    classify,
    is_auto_notification_user_entry,
    read_entries,
    strip_auto_notifications,
)
from transcripts.provenance import (
    AUTHORITATIVE_URL_SOURCES,
    RECONCILE_ELIGIBLE_URL_SOURCES,
    VALID_URL_SOURCES,
    dominant_scan_source,
    is_authoritative,
)
from transcripts.r2 import (
    R2Coordinates,
    R2Error,
    list_keys,
    r2_client,
    r2_coordinates,
    read_sidecar,
    write_html_object,
    write_sidecar,
)
from transcripts.state import (
    COHORT_LABELS,
    Artifact,
    CohortAssignment,
    R2Snapshot,
    compute_snapshot,
    is_count_drift,
    recent_rendered_without_ciphertext,
    sid_from_ciphertext_key,
    sid_from_rendered_key,
    take_snapshot,
)

if TYPE_CHECKING:
    # Re-export for static type-checkers; runtime resolution happens via
    # __getattr__ below.
    from transcripts.schema import PARSER_VERSION, Sidecar, UrlSource


_LAZY_SCHEMA_NAMES = frozenset({"PARSER_VERSION", "Sidecar", "UrlSource"})


def __getattr__(name: str) -> Any:
    """Lazy-load schema symbols so consumers without pydantic still import.

    Called by Python whenever a name isn't found in the module's normal
    attribute lookup. Touching `transcripts.Sidecar` (or PARSER_VERSION /
    UrlSource) triggers the pydantic import on first use; the export
    Stop-hook never touches them and so never pays for pydantic.
    """
    if name in _LAZY_SCHEMA_NAMES:
        from transcripts import schema as _schema  # noqa: PLC0415 — lazy by design

        value = getattr(_schema, name)
        globals()[name] = value
        return value
    raise AttributeError(f"module 'transcripts' has no attribute {name!r}")


__all__ = [
    "AUTHORITATIVE_URL_SOURCES",
    "AUTO_NOTIFICATION_RES",
    "COHORT_LABELS",
    "PARSER_VERSION",
    "RECONCILE_ELIGIBLE_URL_SOURCES",
    "SYSTEM_REMINDER_RE",
    "VALID_URL_SOURCES",
    "Artifact",
    "CohortAssignment",
    "R2Coordinates",
    "R2Error",
    "R2Snapshot",
    "Sidecar",
    "UrlSource",
    "classify",
    "compute_snapshot",
    "dominant_scan_source",
    "is_authoritative",
    "is_auto_notification_user_entry",
    "is_count_drift",
    "list_keys",
    "r2_client",
    "r2_coordinates",
    "read_entries",
    "read_sidecar",
    "recent_rendered_without_ciphertext",
    "sid_from_ciphertext_key",
    "sid_from_rendered_key",
    "strip_auto_notifications",
    "take_snapshot",
    "write_html_object",
    "write_sidecar",
]
