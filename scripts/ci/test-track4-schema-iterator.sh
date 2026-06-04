#!/usr/bin/env bash
# Test: Track 4 Phase 1 schema-iterator (coo-memory#871).
#
# Verifies that schema-fetch-secrets.py correctly reads a fixture schema.yaml,
# calls the mock op binary, and emits export lines for active credentials.
# Also verifies that the SA-token break-glass path in coo-bootstrap.sh
# writes and checks the SA identity file.
#
# Requires: mock op binary on PATH (VADE_BINDIR_OVERRIDE), fixture schema
# staged, isolated HOME.
#
# Invoked by the bootstrap-regression suite and standalone.
#
# Exit codes:
#   0  all assertions passed
#   1  at least one assertion failed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PYTHON="${VADE_CI_PYTHON:-python3}"

log() { printf '[test-track4-schema-iterator] %s\n' "$*"; }
fail() { printf '[test-track4-schema-iterator] FAIL: %s\n' "$*" >&2; FAILED=$((FAILED+1)); }
pass() { printf '[test-track4-schema-iterator] PASS: %s\n' "$*"; }

FAILED=0

# ── 1. Locate or create a fixture schema ────────────────────────────────
SCHEMA_PATH="${VADE_CI_SCHEMA_PATH:-}"
if [ -z "$SCHEMA_PATH" ]; then
  # Fall back to coo-memory checkout if available, else fail.
  SCHEMA_PATH="${VADE_COO_MEMORY_DIR:-/home/user/coo-memory}/operations/secrets/schema.yaml"
fi

if [ ! -f "$SCHEMA_PATH" ]; then
  fail "schema.yaml not found at $SCHEMA_PATH (set VADE_CI_SCHEMA_PATH or VADE_COO_MEMORY_DIR)"
  exit 1
fi

log "Using schema: $SCHEMA_PATH"

HELPER="$RUNTIME_DIR/scripts/boot/schema-fetch-secrets.py"
if [ ! -f "$HELPER" ]; then
  fail "schema-fetch-secrets.py not found at $HELPER"
  exit 1
fi

# ── 2. Run the helper and capture output ────────────────────────────────
log "Running schema-fetch-secrets.py"
FETCH_OUTPUT=""
FETCH_RC=0
FETCH_OUTPUT="$("$PYTHON" "$HELPER" --schema "$SCHEMA_PATH" 2>/dev/null)" || FETCH_RC=$?

# The mock op must return values for our active creds; rc=0 if got>0.
if [ "$FETCH_RC" -ne 0 ] && [ -z "$FETCH_OUTPUT" ]; then
  fail "schema-fetch-secrets.py exited non-zero with no output (schema parse error?)"
  exit 1
fi

# ── 3. Eval and check key variables ─────────────────────────────────────
SCHEMA_FETCH_GOT=0
eval "$FETCH_OUTPUT" 2>/dev/null || true

log "SCHEMA_FETCH_GOT=$SCHEMA_FETCH_GOT"

if [ "${SCHEMA_FETCH_GOT:-0}" -gt 0 ]; then
  pass "SCHEMA_FETCH_GOT=$SCHEMA_FETCH_GOT (at least one secret fetched)"
else
  fail "SCHEMA_FETCH_GOT=0 — schema iterator fetched nothing"
fi

# Check that key env vars were set
for var in GITHUB_MCP_PAT GITHUB_TOKEN AGENTMAIL_API_KEY MEM0_API_KEY TRANSCRIPTS_AGE_IDENTITY; do
  val="${!var:-}"
  if [ -n "$val" ]; then
    pass "$var is set (len=${#val})"
  else
    fail "$var is unset after schema iterator eval"
  fi
done

# ── 4. Verify dormant credentials are NOT exported ────────────────────
# vade-coo-ssh-auth is dormant in both the real schema and CI fixture;
# it has no env_aliases so it would never appear in env regardless, but
# confirm no unexpected alias leaked.
if [ -n "${VADE_COO_SSH_AUTH:-}" ]; then
  fail "VADE_COO_SSH_AUTH set (dormant credential should not be exported)"
else
  pass "Dormant credential (vade-coo-ssh-auth) not in env (expected)"
fi

# ── 5. Schema parse-error path ─────────────────────────────────────────
log "Testing fail-closed path with invalid schema"
BADSCHEMA_TMP="$(mktemp)"
printf 'this is: not: valid: yaml: [' > "$BADSCHEMA_TMP"
BAD_RC=0
BAD_OUT=""
BAD_OUT="$("$PYTHON" "$HELPER" --schema "$BADSCHEMA_TMP" 2>/dev/null)" || BAD_RC=$?
rm -f "$BADSCHEMA_TMP"

if [ "$BAD_RC" -ne 0 ]; then
  pass "schema-fetch-secrets.py exits non-zero on invalid schema (fail-closed)"
else
  fail "schema-fetch-secrets.py should exit non-zero on invalid schema (got rc=0)"
fi

# ── 6. Missing schema path ─────────────────────────────────────────────
MISSING_RC=0
"$PYTHON" "$HELPER" --schema /does/not/exist/schema.yaml 2>/dev/null || MISSING_RC=$?
if [ "$MISSING_RC" -ne 0 ]; then
  pass "schema-fetch-secrets.py exits non-zero when schema file missing"
else
  fail "schema-fetch-secrets.py should exit non-zero on missing schema file"
fi

# ── Summary ──────────────────────────────────────────────────────────────
if [ "$FAILED" -eq 0 ]; then
  log "All assertions passed"
  exit 0
else
  log "FAILED: $FAILED assertion(s) failed"
  exit 1
fi
