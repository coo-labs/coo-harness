#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "PyYAML>=6.0",
#   "jsonschema>=4.0",
# ]
# ///
"""secrets-schema-check — validate operations/secrets/schema.yaml against
operations/secrets/schema.schema.json.

Track 1a of the secrets-management implementation epic (coo-memory#871).
Enforces the S1 invariant from SOP §3.4 (schema.yaml parses + is
shape-valid). Catches typos (env_alias misspellings, mirror surface enum
violations, malformed credential ids) while tolerating `TBD:`-marker
strings on fields not yet backfilled.

Usage:
  python3 bin/secrets-schema-check.py [<schema.yaml>] [--schema <schema.json>]

  Default <schema.yaml>:  operations/secrets/schema.yaml
  Default <schema.json>:  operations/secrets/schema.schema.json
                         (alongside the yaml unless overridden)

Exit codes:
  0  clean — no schema violations.
  1  schema violations — report printed.
  2  invocation error (missing file, bad YAML, bad JSON Schema).

Output shape (on violations):
  <file>: <json-pointer-path>: <message>

The json-pointer is the path to the offending node inside the YAML
document; useful for grepping straight to the entry.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError as exc:
    print(
        f"secrets-schema-check: PyYAML required but not importable: {exc}",
        file=sys.stderr,
    )
    sys.exit(2)

try:
    from jsonschema import Draft202012Validator
    from jsonschema.exceptions import SchemaError
except ImportError as exc:
    print(
        f"secrets-schema-check: jsonschema required but not importable: {exc}",
        file=sys.stderr,
    )
    sys.exit(2)


def load_yaml(path: Path):
    try:
        with path.open() as fh:
            return yaml.safe_load(fh)
    except FileNotFoundError:
        print(f"secrets-schema-check: file not found: {path}", file=sys.stderr)
        sys.exit(2)
    except yaml.YAMLError as exc:
        print(f"secrets-schema-check: YAML parse error in {path}: {exc}", file=sys.stderr)
        sys.exit(2)


def load_json(path: Path):
    try:
        with path.open() as fh:
            return json.load(fh)
    except FileNotFoundError:
        print(f"secrets-schema-check: file not found: {path}", file=sys.stderr)
        sys.exit(2)
    except json.JSONDecodeError as exc:
        print(f"secrets-schema-check: JSON parse error in {path}: {exc}", file=sys.stderr)
        sys.exit(2)


def pointer_for(path_parts) -> str:
    """Render a json-pointer (RFC 6901) for a deque of path parts."""
    if not path_parts:
        return ""
    out = []
    for part in path_parts:
        s = str(part)
        s = s.replace("~", "~0").replace("/", "~1")
        out.append(s)
    return "/" + "/".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="secrets-schema-check",
        description="Validate operations/secrets/schema.yaml against its JSON Schema.",
    )
    ap.add_argument(
        "yaml_path",
        nargs="?",
        default="operations/secrets/schema.yaml",
        help="Path to schema.yaml (default: operations/secrets/schema.yaml)",
    )
    ap.add_argument(
        "--schema",
        default=None,
        help="Path to schema.schema.json (default: alongside the yaml)",
    )
    args = ap.parse_args()

    yaml_path = Path(args.yaml_path)
    if args.schema is None:
        schema_path = yaml_path.with_name("schema.schema.json")
    else:
        schema_path = Path(args.schema)

    instance = load_yaml(yaml_path)
    schema = load_json(schema_path)

    try:
        Draft202012Validator.check_schema(schema)
    except SchemaError as exc:
        print(
            f"secrets-schema-check: invalid JSON Schema at {schema_path}: {exc.message}",
            file=sys.stderr,
        )
        return 2

    validator = Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(instance), key=lambda e: list(e.absolute_path))

    if not errors:
        print(f"{yaml_path}: ok ({schema_path.name} clean)")
        return 0

    for err in errors:
        pointer = pointer_for(err.absolute_path) or "/"
        msg = err.message.replace("\n", " ")
        print(f"{yaml_path}: {pointer}: {msg}")
    print(
        f"\nsecrets-schema-check: {len(errors)} violation(s) against {schema_path.name}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
