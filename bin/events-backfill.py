#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "boto3>=1.34,<2",
#   "pydantic>=2.6,<3",
# ]
# ///
"""events-backfill — translate an events-API dump and write HTML + sidecar to R2.

Operator runs `snippets/events-dump.js` in claude.ai DevTools, scp's the
resulting JSON to the container, then invokes this CLI:

  events-backfill --dump path/to/dump.json              # dry-run by default
  events-backfill --dump path/to/dump.json --apply      # write to R2
  events-backfill --dump dump.json --only-session-ids session_01ab,session_02cd

Per-session result is printed as JSONL on stdout (one line per session); the
operator pipes this to `coo-harness/state/events-backfill/manifest.jsonl`
and commits the append. Exit 0 iff every session landed in a non-error
status (`applied`, `dry_run`, `ceded_authoritative`, `skipped_*`).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def _setup_path() -> None:
    """Insert coo-harness/lib on sys.path so `from transcripts import …` works.

    Two parents up from `bin/events-backfill.py` is the repo root; `lib` lives
    there. This is the same dance documented in `lib/transcripts/README.md`,
    repeated here because PEP 723 venvs don't see editable installs.
    """
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))


_setup_path()

from transcripts.backfill import backfill_dump  # noqa: E402


def _parse_only_session_ids(raw: str | None) -> set[str] | None:
    if not raw:
        return None
    return {sid.strip() for sid in raw.split(",") if sid.strip()}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else "")
    parser.add_argument(
        "--dump",
        type=Path,
        required=True,
        help="path to the JSON (or .json.gz) dump produced by snippets/events-dump.js",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="write to R2 (default: dry-run; translate + render but no upload)",
    )
    parser.add_argument(
        "--only-session-ids",
        help="comma-separated session ids; restricts the run to a subset",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="suppress the human-readable footer summary; JSONL on stdout still emits",
    )
    args = parser.parse_args(argv)

    if not args.dump.is_file():
        sys.stderr.write(f"[events-backfill] --dump {args.dump} not found\n")
        return 2

    report = backfill_dump(
        dump_path=args.dump,
        apply=args.apply,
        only_session_ids=_parse_only_session_ids(args.only_session_ids),
    )

    error_count = 0
    for result in report.results:
        sys.stdout.write(result.to_jsonl())
        sys.stdout.write("\n")
        if result.status.value == "error":
            error_count += 1

    if not args.quiet:
        counts = report.counts_by_status()
        summary = ", ".join(f"{k}={v}" for k, v in sorted(counts.items()))
        sys.stderr.write(
            f"[events-backfill] {report.dump_path}: {len(report.results)} sessions"
            f" — {summary}{' (DRY RUN)' if not args.apply else ''}\n"
        )

    return 1 if error_count else 0


if __name__ == "__main__":
    raise SystemExit(main())
