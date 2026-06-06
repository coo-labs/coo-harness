"""Mass-mutation drivers — orchestrators that batch primitive operations.

Each module here owns one driver:
  - `events` — events-API dump → translated entries → render → R2 write.

Public surface is intentionally narrow: the driver entry points + their
result types. Implementation helpers stay module-private.
"""

from __future__ import annotations

from transcripts.backfill.events import (
    BackfillReport,
    BackfillResult,
    BackfillStatus,
    backfill_dump,
)

__all__ = [
    "BackfillReport",
    "BackfillResult",
    "BackfillStatus",
    "backfill_dump",
]
