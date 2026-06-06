"""coo-harness internal transcripts library.

Primitive layer for the VADE transcript pipeline. Consolidates the R2 / schema /
provenance code that was previously copy-pasted across scripts/lib/ and
scripts/lifecycle/. Hooks and CLI scripts import primitives from here;
orchestration (the SessionEnd hook, mass-mutation drivers) stays in scripts/.

Public surface is what's re-exported below. Anything not in __all__ is private
to the module and may change without notice.
"""

from __future__ import annotations

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
from transcripts.schema import (
    PARSER_VERSION,
    Sidecar,
    UrlSource,
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
