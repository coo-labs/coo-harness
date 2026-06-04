#!/usr/bin/env bash
# test-bootstrap-op-caches: unit-tests for the bootstrap-side op-read
# cache functions added as Phase 2 follow-ups to coo-memory#871:
#
#   - materialize_app_key_cache (in common.sh) — writes GITHUB_APP_PRIVATE_KEY
#     to tmpfs at boot so gh-app-token.sh's installation-token cache misses
#     don't cost an op-read per re-mint.
#
#   - schema-fetch session cache (in fetch_coo_secrets in common.sh) —
#     caches the python iterator's eval-able output in tmpfs for the
#     session. Re-bootstraps within TTL use the cache instead of re-running
#     ~12 op-reads. Schema-hash-keyed so schema edits invalidate.
#
# Companions to test-materialize-mcp-env.sh (#437) which covers the MCP
# env-file pre-materialization. Same tmpfs posture across all three.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMON="$REPO_ROOT/scripts/lib/common.sh"

[ -r "$COMMON" ] || { echo "FAIL: common.sh not readable at $COMMON"; exit 1; }

TEST_ROOT="${TEST_ROOT:-/tmp/test-bootstrap-op-caches-$$}"
mkdir -p "$TEST_ROOT"
trap 'rm -rf "$TEST_ROOT" /dev/shm/coo-app-key-cache /dev/shm/coo-secret-cache' EXIT

PASS=0
FAIL=0
declare -a FAILURES=()

_pass() { PASS=$((PASS + 1)); printf '  ok: %s\n' "$1"; }
_fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); printf '  FAIL: %s\n' "$1"; }
_assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] && _pass "$label" || _fail "$label (expected=$expected actual=$actual)"
}
_assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  printf '%s' "$haystack" | grep -qF "$needle" && _pass "$label" || _fail "$label (needle=$needle not in: ${haystack:0:80})"
}

# ============================================================
# Part 1 — materialize_app_key_cache
# ============================================================
printf '\n== materialize_app_key_cache ==\n'

# Test A1 — env unset: skip cleanly, no file written.
rm -rf /dev/shm/coo-app-key-cache
out="$(
  env -u GITHUB_APP_PRIVATE_KEY bash -c "
    set -uo pipefail
    log() { :; }
    source '$COMMON' 2>/dev/null
    materialize_app_key_cache
    printf 'exit=%s' \$?
  " 2>&1
)"
_assert_contains "A1: function exits 0 when env unset" "exit=0" "$out"
[ ! -e /dev/shm/coo-app-key-cache/private_key ] && _pass "A1: no file created" || _fail "A1: file created when env unset"

# Test A2 — env set: file written with 0600, dir 0700.
rm -rf /dev/shm/coo-app-key-cache
out="$(
  GITHUB_APP_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----
FAKE_KEY_FOR_TEST_A2_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
-----END RSA PRIVATE KEY-----" bash -c "
    set -uo pipefail
    log() { :; }
    source '$COMMON' 2>/dev/null
    materialize_app_key_cache
  " 2>&1
)"
[ -f /dev/shm/coo-app-key-cache/private_key ] && _pass "A2: file created" || _fail "A2: file not created"
if [ -f /dev/shm/coo-app-key-cache/private_key ]; then
  file_mode="$(stat -c '%a' /dev/shm/coo-app-key-cache/private_key 2>/dev/null || stat -f '%Lp' /dev/shm/coo-app-key-cache/private_key 2>/dev/null)"
  dir_mode="$(stat -c '%a' /dev/shm/coo-app-key-cache 2>/dev/null || stat -f '%Lp' /dev/shm/coo-app-key-cache 2>/dev/null)"
  _assert_eq "A2: file mode" "600" "$file_mode"
  _assert_eq "A2: dir mode" "700" "$dir_mode"
  body="$(cat /dev/shm/coo-app-key-cache/private_key)"
  _assert_contains "A2: body preserved" "FAKE_KEY_FOR_TEST_A2" "$body"
fi

# Test A3 — idempotency.
out="$(
  GITHUB_APP_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----
SECOND_RUN_KEY_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
-----END RSA PRIVATE KEY-----" bash -c "
    set -uo pipefail
    log() { :; }
    source '$COMMON' 2>/dev/null
    materialize_app_key_cache
  " 2>&1
)"
body="$(cat /dev/shm/coo-app-key-cache/private_key 2>/dev/null)"
_assert_contains "A3: re-run overwrites with second value" "SECOND_RUN_KEY_" "$body"
if printf '%s' "$body" | grep -q "FAKE_KEY_FOR_TEST_A2"; then
  _fail "A3: stale first value still present"
else
  _pass "A3: first value overwritten cleanly"
fi

# ============================================================
# Part 2 — schema-fetch session cache (in fetch_coo_secrets)
# ============================================================
# We stub the python iterator helper to emit known output, then call
# fetch_coo_secrets twice — first call populates cache, second hits it
# (verified by removing the helper so any python invocation would fail).
printf '\n== schema-fetch session cache ==\n'

STUB_ROOT="$TEST_ROOT/schema-stub"
mkdir -p "$STUB_ROOT/scripts/boot"
mkdir -p "$STUB_ROOT/operations/secrets"

# Stub helper: emit known eval-able output + SCHEMA_FETCH_GOT marker.
cat > "$STUB_ROOT/scripts/boot/schema-fetch-secrets.py" <<'EOF'
#!/usr/bin/env python3
import sys
sys.stdout.write("export TEST_FETCHED_VAR='stub_value_from_helper'\n")
sys.stdout.write("SCHEMA_FETCH_GOT=1\n")
sys.exit(0)
EOF
chmod +x "$STUB_ROOT/scripts/boot/schema-fetch-secrets.py"

# Stub schema file.
cat > "$STUB_ROOT/operations/secrets/schema.yaml" <<'EOF'
# stub schema for test
credentials: []
EOF

# Clean cache.
rm -rf /dev/shm/coo-secret-cache

# Test B1 — first call: cache miss, helper runs, cache written.
out="$(
  env -u TEST_FETCHED_VAR bash -c "
    set -uo pipefail
    log() { printf '[log] %s\n' \"\$*\" >&2; }
    check_cmd() { command -v \"\$1\" >/dev/null 2>&1; }
    retry() { shift; \"\$@\"; }
    source '$COMMON' 2>/dev/null
    VADE_RUNTIME_DIR='$STUB_ROOT'
    VADE_COO_MEMORY_DIR='$STUB_ROOT'
    fetch_coo_secrets
    printf 'GOT=%s VAR=%s\n' \"\${SCHEMA_FETCH_GOT:-0}\" \"\${TEST_FETCHED_VAR:-unset}\"
  " 2>&1
)"
_assert_contains "B1: SCHEMA_FETCH_GOT set" "GOT=1" "$out"
_assert_contains "B1: TEST_FETCHED_VAR exported from helper" "VAR=stub_value_from_helper" "$out"
[ -f /dev/shm/coo-secret-cache/schema-fetch.sh ] && _pass "B1: cache file created" || _fail "B1: cache file not created"
[ -f /dev/shm/coo-secret-cache/schema-fetch.meta ] && _pass "B1: cache meta created" || _fail "B1: cache meta not created"

# Test B2 — second call: cache hit, helper NOT invoked.
# Proof: replace the helper with one that exits non-zero. If cache works,
# fetch_coo_secrets still succeeds because it doesn't call the helper.
cat > "$STUB_ROOT/scripts/boot/schema-fetch-secrets.py" <<'EOF'
#!/usr/bin/env python3
import sys
sys.stderr.write("HELPER SHOULD NOT BE CALLED\n")
sys.exit(99)
EOF
chmod +x "$STUB_ROOT/scripts/boot/schema-fetch-secrets.py"

out="$(
  env -u TEST_FETCHED_VAR bash -c "
    set -uo pipefail
    log() { printf '[log] %s\n' \"\$*\" >&2; }
    check_cmd() { command -v \"\$1\" >/dev/null 2>&1; }
    retry() { shift; \"\$@\"; }
    source '$COMMON' 2>/dev/null
    VADE_RUNTIME_DIR='$STUB_ROOT'
    VADE_COO_MEMORY_DIR='$STUB_ROOT'
    fetch_coo_secrets
    printf 'GOT=%s VAR=%s\n' \"\${SCHEMA_FETCH_GOT:-0}\" \"\${TEST_FETCHED_VAR:-unset}\"
  " 2>&1
)"
_assert_contains "B2: SCHEMA_FETCH_GOT set from cache" "GOT=1" "$out"
_assert_contains "B2: TEST_FETCHED_VAR from cached eval" "VAR=stub_value_from_helper" "$out"
_assert_contains "B2: cache-hit log line emitted" "schema-fetch cache hit" "$out"
if printf '%s' "$out" | grep -q "HELPER SHOULD NOT BE CALLED"; then
  _fail "B2: helper was invoked despite cache hit"
else
  _pass "B2: helper not invoked (cache served the eval)"
fi

# Test B3 — schema hash changes invalidate the cache.
# Edit the schema (any change → different sha256). The next call should
# bypass the cache and re-run the (now-failing) helper, surfacing the
# bypass via the helper's exit-99 path.
echo "# new content" >> "$STUB_ROOT/operations/secrets/schema.yaml"
out="$(
  env -u TEST_FETCHED_VAR bash -c "
    set -uo pipefail
    log() { printf '[log] %s\n' \"\$*\" >&2; }
    check_cmd() { command -v \"\$1\" >/dev/null 2>&1; }
    retry() { shift; \"\$@\"; }
    source '$COMMON' 2>/dev/null
    VADE_RUNTIME_DIR='$STUB_ROOT'
    VADE_COO_MEMORY_DIR='$STUB_ROOT'
    fetch_coo_secrets || true
  " 2>&1
)"
if printf '%s' "$out" | grep -q "schema-fetch cache hit"; then
  _fail "B3: cache hit despite schema change (sha-keying broken)"
else
  _pass "B3: cache invalidated on schema change"
fi

# ============================================================
# Summary
# ============================================================
printf '\n== Summary ==\n'
printf 'Total: %d pass, %d fail\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed cases:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
