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
    write_sidecar,
)
from transcripts.schema import (
    PARSER_VERSION,
    Sidecar,
    UrlSource,
)

__all__ = [
    "AUTHORITATIVE_URL_SOURCES",
    "AUTO_NOTIFICATION_RES",
    "PARSER_VERSION",
    "RECONCILE_ELIGIBLE_URL_SOURCES",
    "SYSTEM_REMINDER_RE",
    "VALID_URL_SOURCES",
    "R2Coordinates",
    "R2Error",
    "Sidecar",
    "UrlSource",
    "classify",
    "dominant_scan_source",
    "is_authoritative",
    "is_auto_notification_user_entry",
    "list_keys",
    "r2_client",
    "r2_coordinates",
    "read_entries",
    "read_sidecar",
    "strip_auto_notifications",
    "write_sidecar",
]
