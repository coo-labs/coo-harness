#!/usr/bin/env python3
"""
Drift check between coo-harness's transcript-redaction.json and coo-memory's
operations/secrets/schema.yaml::secret_shapes registry.

Asserts the two registries cross-reference cleanly:

  - For every active (match_required != false) secret_shape declared in
    schema.yaml, at least one transcript-redaction.json pattern must
    declare `schema_shape: <name>` referencing it. (A defense-only shape
    with match_required=false is OK uncovered; coverage is reported
    informationally.)

  - For every transcript-redaction.json pattern that declares a
    `schema_shape` value, the named shape must exist in schema.yaml.

  - Patterns without a `schema_shape` are treated as defensive-only
    (stripe / slack / hf / npm / pypi / gcp-refresh / jwt / etc.) and
    are not required to map.

Closes the meta-bug originally documented in coo-labs/coo-harness#361.
The runtime "registered-but-non-matching" failure surfaces in
test-transcript-redaction.py via synthetic positive cases; this script
covers the orthogonal "registries diverged silently" failure mode.

Schema path defaults to $VADE_COO_MEMORY_DIR/operations/secrets/schema.yaml
(or /home/user/coo-memory/... if the env var is unset). In CI environments
without a coo-memory checkout, pass --allow-skip to exit 0 with a warning
instead of failing.

Exit codes:
  0  no drift (or skipped per --allow-skip)
  1  drift detected
  2  invocation error (missing files, unparseable, etc.)
"""

from __future__ import annotations

import argparse
import json
import os
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DEFAULT_JSON = os.path.join(REPO_ROOT, "scripts", "lib", "transcript-redaction.json")
DEFAULT_SCHEMA = os.path.join(
    os.environ.get("VADE_COO_MEMORY_DIR", "/home/user/coo-memory"),
    "operations",
    "secrets",
    "schema.yaml",
)


def load_schema_shapes(path: str) -> list[dict]:
    try:
        import yaml
    except ImportError:
        print(
            f"ERROR: PyYAML required to parse {path} (pip install pyyaml)",
            file=sys.stderr,
        )
        sys.exit(2)
    with open(path) as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        print(f"ERROR: {path} did not parse as a dict", file=sys.stderr)
        sys.exit(2)
    return data.get("secret_shapes", []) or []


def load_json_patterns(path: str) -> list[dict]:
    with open(path) as f:
        cfg = json.load(f)
    return cfg.get("patterns", []) or []


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Drift check: transcript-redaction.json <-> schema.yaml::secret_shapes",
    )
    ap.add_argument(
        "--schema",
        default=DEFAULT_SCHEMA,
        help=f"path to schema.yaml (default: {DEFAULT_SCHEMA})",
    )
    ap.add_argument(
        "--json",
        default=DEFAULT_JSON,
        help=f"path to transcript-redaction.json (default: {DEFAULT_JSON})",
    )
    ap.add_argument(
        "--allow-skip",
        action="store_true",
        help="If schema.yaml is unreachable, exit 0 with a warning instead of failing.",
    )
    args = ap.parse_args()

    if not os.path.exists(args.schema):
        msg = f"schema.yaml not found at {args.schema}"
        if args.allow_skip:
            print(f"[check-redaction-schema-drift] {msg} — skipping (--allow-skip)")
            return 0
        print(f"ERROR: {msg}", file=sys.stderr)
        return 2

    if not os.path.exists(args.json):
        print(f"ERROR: transcript-redaction.json not found at {args.json}", file=sys.stderr)
        return 2

    schema_shapes = load_schema_shapes(args.schema)
    json_patterns = load_json_patterns(args.json)

    schema_by_name: dict[str, dict] = {s["name"]: s for s in schema_shapes if "name" in s}

    json_by_schema_shape: dict[str, list[str]] = {}
    for p in json_patterns:
        s = p.get("schema_shape")
        if s:
            json_by_schema_shape.setdefault(s, []).append(p["id"])

    failures: list[str] = []

    print(f"Schema:  {args.schema}")
    print(f"JSON:    {args.json}")
    print(f"Shapes:  {len(schema_shapes)} declared in schema; "
          f"{len(json_by_schema_shape)} cross-referenced from JSON patterns")
    print("")
    print("Coverage:")

    for shape in schema_shapes:
        name = shape.get("name")
        if not name:
            continue
        required = shape.get("match_required", True) is not False
        covered_by = json_by_schema_shape.get(name, [])
        if required and not covered_by:
            failures.append(
                f"schema secret_shape '{name}' is active (match_required=true) but no "
                f"transcript-redaction.json pattern declares `schema_shape: {name}`"
            )
            print(f"  X {name:<35} MISSING JSON coverage (active shape)")
        elif covered_by:
            tag = "(active)" if required else "(defense-only)"
            print(f"  + {name:<35} {tag} -> {', '.join(covered_by)}")
        else:
            print(f"  - {name:<35} (defense-only, uncovered — OK)")

    for shape_name, json_ids in json_by_schema_shape.items():
        if shape_name not in schema_by_name:
            for jid in json_ids:
                failures.append(
                    f"transcript-redaction.json pattern '{jid}' declares "
                    f"`schema_shape: {shape_name}` but no such shape exists in "
                    f"schema.yaml::secret_shapes"
                )

    print("")
    if failures:
        print(f"FAIL ({len(failures)} drift issue(s)):")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("no drift detected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
