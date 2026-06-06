#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
"""
list-r2-transcripts.py — coo-memory#499.

Print R2 transcript keys under a given prefix, one per line (text mode)
or as a JSON array of {key, size, last_modified} (--json mode).

R2 credential plumbing comes from `lib/transcripts/r2.py` (consolidated
per coo-labs/coo-memory#1147 / coo-labs/coo-harness#531). The lib's
`list_keys` primitive owns the paginated list_objects_v2 walk; this
script is a thin CLI wrapper around it.

Why a separate script: the nightly task previously inlined the R2
enumeration as a `python3 - <<PY` heredoc with a bare `import boto3`,
which fails because the ambient Python lacks boto3 (vrt#203 only
prewarms uv's cache). Calling this script via the shebang
(`#!/usr/bin/env -S uv run --script`) routes through uv with the
PEP-723 deps block, so boto3 resolves cleanly.

Usage:
  list-r2-transcripts.py transcripts/2026/05/06/
  list-r2-transcripts.py --json transcripts/2026/05/06/
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Locate coo-harness/lib/ on sys.path so `from transcripts import ...` resolves
# under the uv-run venv this script spawns into. See lib/transcripts/README.md
# §"Importing" for the parents[N] table; this script lives at
# scripts/lib/<top>.py so parents[2] is the repo root.
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR.parent.parent / "lib"))

from transcripts import list_keys  # noqa: E402


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument(
        "prefix",
        help="R2 key prefix, e.g. transcripts/2026/05/06/",
    )
    p.add_argument(
        "--json",
        action="store_true",
        help="emit JSON array of {key, size, last_modified}",
    )
    args = p.parse_args()

    keys = list_keys(args.prefix)
    if args.json:
        json.dump(keys, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        for k in keys:
            print(k["key"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
