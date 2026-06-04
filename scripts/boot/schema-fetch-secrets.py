#!/usr/bin/env python3
"""
schema-fetch-secrets.py — schema-driven 1Password secret fetcher.

Reads operations/secrets/schema.yaml from the coo-memory repo, iterates
active credentials, and fetches each secret via `op read op://COO/<item>/<field>`.
Emits `export VAR='value'` shell lines to stdout for the caller to eval.

Usage:
  eval "$(python3 scripts/boot/schema-fetch-secrets.py --schema <path> [--got-file <path>])"

Behaviour per credential status:
  active                  → fetch and export all env_aliases
  dormant                 → skip (legitimately not in use; no warning)
  pending_decommission    → skip
  pending_decategorization → skip
  retired                 → skip (audit history only)
  TBD: <...>              → skip with warning (status not yet resolved)
  anything else           → warn (schema drift)

Special cases:
  - Credentials with empty env_aliases: skipped (no env surface).
  - Multi-field credentials (op_alt_fields present): each alias is
    mapped to its corresponding op_ref by the field-order convention
    documented in the schema comment block. See MULTI_FIELD_MAP below
    for the authoritative mapping.
  - rotation_class == "IV": fetched normally (Class IV = do-not-rotate,
    not do-not-read).
  - If the schema file is unreadable or unparseable: exit non-zero with
    a clear error message (fail closed).
  - If op read fails for a specific credential: warn and skip that
    credential (best-effort per the existing fetch_coo_secrets contract).
    Missing a single secret is not a fatal boot failure; missing op
    entirely is.

Exit codes:
  0  at least one secret fetched
  1  schema parse error or no secrets could be fetched at all
  2  invocation error (bad args)

Emits to stderr: log lines prefixed [schema-fetch-secrets]
Emits to stdout: export VAR='value' lines + a SCHEMA_FETCH_GOT=N line
"""

import os
import subprocess
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Multi-field credential mapping.
# The schema's env_aliases list is ordered, but the schema YAML does not
# carry a per-field→alias binding for alt-field credentials. This map
# provides that binding explicitly for credentials that have op_alt_fields.
# Key: credential id. Value: list of (op_field, env_alias) pairs, ordered
# to match the credential's env_aliases list.
#
# Only credentials with op_alt_fields that also have env_aliases need an
# entry. Credentials where op_alt_fields are fetched but not exported to
# env (e.g. github-app-vade-coo-app's private_key is in op_alt_fields but
# NOT in env_aliases — it's deliberately excluded per the schema note) do
# not need entries for those alt fields.
#
# Update this map when a new multi-field credential with env_aliases is added.
# ---------------------------------------------------------------------------
MULTI_FIELD_MAP = {
    # r2-transcripts: primary field is secret-access-key (→ SECRET_ACCESS_KEY),
    # alt field access-key-id (→ ACCESS_KEY_ID) is also fetched and exported.
    "r2-transcripts": [
        ("access-key-id",    "R2_TRANSCRIPTS_ACCESS_KEY_ID"),
        ("secret-access-key","R2_TRANSCRIPTS_SECRET_ACCESS_KEY"),
    ],
    # cloudflare-api-vade-coo: primary field is credential (→ CLOUDFLARE_API_TOKEN),
    # alt field account_id (→ CLOUDFLARE_ACCOUNT_ID) is public but
    # included in env_aliases for completeness.
    "cloudflare-api-vade-coo": [
        ("credential",   "CLOUDFLARE_API_TOKEN"),
        ("account_id",   "CLOUDFLARE_ACCOUNT_ID"),
    ],
    # github-app-vade-coo-app: primary field is private_key (→ GITHUB_APP_PRIVATE_KEY),
    # but we also read app_id and installation_id from op_alt_fields.
    # The private_key is intentionally NOT exported to env_aliases per schema note:
    # "SECRET — must NOT be in non_secret_env_allowlist". It IS in env_aliases
    # as GITHUB_APP_PRIVATE_KEY but the minter (gh-app-token.sh) reads it
    # on demand via op read, not from env. We still export it here for compat.
    "github-app-vade-coo-app": [
        ("private_key",      "GITHUB_APP_PRIVATE_KEY"),
        ("app_id",           "GITHUB_APP_ID"),
        ("installation_id",  "GITHUB_APP_INSTALLATION_ID"),
    ],
}

SKIP_STATUSES = {"dormant", "retired", "pending_decommission", "pending_decategorization"}
WARN_STATUS_PREFIX = "TBD"

log_lines = []


def log(msg):
    print(f"[schema-fetch-secrets] {msg}", file=sys.stderr)


def op_read(ref):
    """Run `op read <ref>` and return the trimmed value, or None on failure."""
    try:
        result = subprocess.run(
            ["op", "read", ref],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return None
        val = result.stdout.strip()
        return val if val else None
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None


def shell_single_quote(s):
    """Wrap s in single quotes, escaping any embedded single quotes."""
    return "'" + s.replace("'", "'\\''") + "'"


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Schema-driven secret fetcher")
    parser.add_argument("--schema", required=True, help="Path to schema.yaml")
    parser.add_argument("--got-file", default="", help="Path to write fetched count (optional)")
    args = parser.parse_args()

    schema_path = Path(args.schema)
    if not schema_path.exists():
        log(f"FATAL: schema file not found: {schema_path}")
        log(f"  Expected at: {schema_path}")
        log(f"  Ensure coo-memory is checked out and VADE_COO_MEMORY_DIR is set.")
        sys.exit(1)

    try:
        import yaml
    except ImportError:
        log("FATAL: PyYAML not available. Install: pip install pyyaml")
        log(f"  Schema path: {schema_path}")
        sys.exit(1)

    try:
        with open(schema_path) as f:
            schema = yaml.safe_load(f)
    except Exception as e:
        log(f"FATAL: schema parse error: {e}")
        log(f"  Schema path: {schema_path}")
        sys.exit(1)

    if not isinstance(schema, dict):
        log(f"FATAL: schema did not parse as a dict (got {type(schema).__name__})")
        sys.exit(1)

    credentials = schema.get("credentials", [])
    if not isinstance(credentials, list):
        log("FATAL: schema.credentials is not a list")
        sys.exit(1)

    vault = schema.get("vault", "COO")
    got = 0
    output_lines = []

    for cred in credentials:
        if not isinstance(cred, dict):
            continue

        cred_id = cred.get("id", "<unknown>")
        status = cred.get("status", "")
        env_aliases = cred.get("env_aliases", []) or []
        op_item = cred.get("op_item", "")
        op_field = cred.get("op_field", "")

        # Status discipline
        if isinstance(status, str) and status.startswith("TBD"):
            log(f"  warn: credential '{cred_id}' has unresolved status '{status}'; skipping")
            continue
        if status in SKIP_STATUSES:
            continue
        if status != "active":
            log(f"  warn: credential '{cred_id}' has unknown status '{status}'; skipping (schema drift?)")
            continue

        # No env aliases → nothing to export
        if not env_aliases:
            continue

        # No op_item → skip
        if not op_item or op_item.startswith("("):
            continue  # e.g. github-app-installation-token has "(none — minted from ...)"

        # Multi-field credentials: use explicit field→alias map
        if cred_id in MULTI_FIELD_MAP:
            field_alias_pairs = MULTI_FIELD_MAP[cred_id]
            for op_field_name, alias in field_alias_pairs:
                ref = f"op://{vault}/{op_item}/{op_field_name}"
                val = op_read(ref)
                if val is not None:
                    log(f"  read {cred_id}/{op_field_name} → {alias} (len={len(val)})")
                    output_lines.append(f"export {alias}={shell_single_quote(val)}")
                    got += 1
                else:
                    log(f"  WARN: {ref} unavailable; {alias} will be unset")
            continue

        # Single-field credential: op_item + op_field → all env_aliases get same value
        if not op_field:
            log(f"  warn: credential '{cred_id}' has no op_field; skipping")
            continue

        ref = f"op://{vault}/{op_item}/{op_field}"
        val = op_read(ref)
        if val is not None:
            log(f"  read {cred_id} (len={len(val)}) → {', '.join(env_aliases)}")
            for alias in env_aliases:
                output_lines.append(f"export {alias}={shell_single_quote(val)}")
            got += 1
        else:
            log(f"  WARN: {ref} unavailable; {', '.join(env_aliases)} will be unset")

    # Emit SCHEMA_FETCH_GOT so the caller can check overall success
    output_lines.append(f"SCHEMA_FETCH_GOT={got}")

    if args.got_file:
        try:
            Path(args.got_file).write_text(str(got))
        except OSError as e:
            log(f"  warn: could not write got-file {args.got_file}: {e}")

    print("\n".join(output_lines))

    if got == 0:
        log("  no secrets fetched from schema; fetch_coo_secrets will return 1")
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
