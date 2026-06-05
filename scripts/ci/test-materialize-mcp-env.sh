#!/usr/bin/env bash
# test-materialize-mcp-env: unit-test materialize_mcp_env_files() from
# scripts/lib/common.sh.
#
# Phase 2 follow-up (coo-memory#871): pre-materializes MCP env templates
# to tmpfs at bootstrap time so subsequent `op run --env-file` invocations
# see a file with no op:// refs and pass through without API calls. The
# function is called from coo-bootstrap.sh after fetch_coo_secrets has
# populated the secret env vars.
#
# Tests:
#   1. Resolves op:// refs from the current process env.
#   2. Passes through comments and blank lines unchanged.
#   3. Writes files with 0600 mode, directory 0700.
#   4. Sets VADE_MCP_ENV_DIR to the chosen tmpfs path.
#   5. Handles templates with no op:// refs (passes through unchanged).
#   6. Keeps op:// ref intact when the env var is unset (visible failure
#      mode so op run can either resolve at spawn or fail loudly).
#   7. Idempotent: re-running overwrites without error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMON="$REPO_ROOT/scripts/lib/common.sh"

[ -r "$COMMON" ] || { echo "FAIL: common.sh not readable at $COMMON"; exit 1; }

TEST_ROOT="${TEST_ROOT:-/tmp/test-materialize-mcp-env-$$}"
mkdir -p "$TEST_ROOT"
trap 'rm -rf "$TEST_ROOT" /dev/shm/test-coo-mcp-env-$$' EXIT

PASS=0
FAIL=0
declare -a FAILURES=()

_pass() { PASS=$((PASS + 1)); printf '  ok: %s\n' "$1"; }
_fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); printf '  FAIL: %s\n' "$1"; }

_assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    _pass "$label"
  else
    _fail "$label (expected=$expected actual=$actual)"
  fi
}

_assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    _pass "$label"
  else
    _fail "$label (needle=$needle not found in: ${haystack:0:80})"
  fi
}

# Stage a fake VADE_RUNTIME_DIR with mcp-env-templates/.
_stage_templates() {
  local dir="$1"
  mkdir -p "$dir/scripts/lib/mcp-env-templates"
  cat > "$dir/scripts/lib/mcp-env-templates/mem0.env" <<'EOF'
# MCP env template for mem0.
# Comment line preserved.
MEM0_API_KEY=op://COO/mem0-api-vade-coo/credential
EOF
  cat > "$dir/scripts/lib/mcp-env-templates/agentmail.env" <<'EOF'
# MCP env template for agentmail.
AGENTMAIL_API_KEY=op://COO/agentmail-api-vade-coo/credential
EOF
  cat > "$dir/scripts/lib/mcp-env-templates/1password.env" <<'EOF'
# No op:// refs — passes through unchanged.
# OP_SERVICE_ACCOUNT_TOKEN inherited from process env.
EOF
}

# Run materialize in a subshell with the function loaded and env staged.
# Sets _OUT_DIR to the resulting VADE_MCP_ENV_DIR.
_run_materialize() {
  local stage_dir="$1"
  shift
  local out
  out="$(
    "$@" bash -c "
      set -uo pipefail
      # Stub log() to no-op (function uses log() for status output).
      log() { :; }
      source '$COMMON' 2>/dev/null
      VADE_RUNTIME_DIR='$stage_dir'
      materialize_mcp_env_files
      printf 'VADE_MCP_ENV_DIR=%s\n' \"\$VADE_MCP_ENV_DIR\"
    " 2>&1
  )"
  _OUT_DIR="$(printf '%s\n' "$out" | grep -E '^VADE_MCP_ENV_DIR=' | head -1 | cut -d= -f2-)"
}

# ============================================================
# TEST 1 — happy path: op:// refs resolved from env
# ============================================================
printf '\n== test 1: op:// refs resolved from env ==\n'
TEST1_DIR="$TEST_ROOT/test1"
_stage_templates "$TEST1_DIR"
TEST1_TMPFS="/dev/shm/test-coo-mcp-env-$$/test1"
rm -rf "$TEST1_TMPFS"
mkdir -p "$TEST1_TMPFS"

_run_materialize "$TEST1_DIR" env \
  MEM0_API_KEY="m0_FAKE_TEST_MEM0_aaaaaaaaaa" \
  AGENTMAIL_API_KEY="am_FAKE_TEST_AGENTMAIL_bbb" \
  XDG_RUNTIME_DIR="$TEST1_TMPFS"

# materialize_mcp_env_files writes to /dev/shm/coo-mcp-env if /dev/shm is
# writable; check that path.
[ -f "$_OUT_DIR/mem0.env" ] && _pass "mem0.env created at $_OUT_DIR" || _fail "mem0.env missing at $_OUT_DIR"
[ -f "$_OUT_DIR/agentmail.env" ] && _pass "agentmail.env created" || _fail "agentmail.env missing"
[ -f "$_OUT_DIR/1password.env" ] && _pass "1password.env created" || _fail "1password.env missing"

mem0_content="$(cat "$_OUT_DIR/mem0.env")"
_assert_contains "mem0.env: MEM0_API_KEY resolved" "MEM0_API_KEY=m0_FAKE_TEST_MEM0_aaaaaaaaaa" "$mem0_content"
_assert_contains "mem0.env: comment preserved" "# MCP env template for mem0." "$mem0_content"
if printf '%s' "$mem0_content" | grep -q "op://COO/mem0"; then
  _fail "mem0.env: op:// ref should be replaced, not preserved"
else
  _pass "mem0.env: op:// ref replaced"
fi

am_content="$(cat "$_OUT_DIR/agentmail.env")"
_assert_contains "agentmail.env: AGENTMAIL_API_KEY resolved" "AGENTMAIL_API_KEY=am_FAKE_TEST_AGENTMAIL_bbb" "$am_content"

# 1password.env has no op:// refs — passes through verbatim.
op_content="$(cat "$_OUT_DIR/1password.env")"
_assert_contains "1password.env: comment preserved" "# No op:// refs" "$op_content"

# Permissions: dir 0700, files 0600.
dir_mode="$(stat -c '%a' "$_OUT_DIR" 2>/dev/null || stat -f '%Lp' "$_OUT_DIR" 2>/dev/null)"
_assert_eq "out dir mode" "700" "$dir_mode"
for f in mem0.env agentmail.env 1password.env; do
  file_mode="$(stat -c '%a' "$_OUT_DIR/$f" 2>/dev/null || stat -f '%Lp' "$_OUT_DIR/$f" 2>/dev/null)"
  _assert_eq "$f mode" "600" "$file_mode"
done

# ============================================================
# TEST 2 — env var unset: op:// ref preserved (fallback)
# ============================================================
printf '\n== test 2: missing env var preserves op:// ref ==\n'
TEST2_DIR="$TEST_ROOT/test2"
_stage_templates "$TEST2_DIR"

# Run with MEM0_API_KEY unset (env -u) to simulate fetch_coo_secrets gap.
_run_materialize "$TEST2_DIR" env -u MEM0_API_KEY \
  AGENTMAIL_API_KEY="am_TEST2_VALUE" \
  XDG_RUNTIME_DIR="$TEST_ROOT/runtime2"

mem0_content="$(cat "$_OUT_DIR/mem0.env")"
_assert_contains "test 2: unresolved MEM0 op:// ref preserved" "MEM0_API_KEY=op://COO/mem0-api-vade-coo/credential" "$mem0_content"
am_content="$(cat "$_OUT_DIR/agentmail.env")"
_assert_contains "test 2: AGENTMAIL still resolves" "AGENTMAIL_API_KEY=am_TEST2_VALUE" "$am_content"

# ============================================================
# TEST 3 — idempotency: re-run overwrites cleanly
# ============================================================
printf '\n== test 3: idempotency ==\n'
TEST3_DIR="$TEST_ROOT/test3"
_stage_templates "$TEST3_DIR"

# First materialization with one set of values.
_run_materialize "$TEST3_DIR" env \
  MEM0_API_KEY="m0_FIRST_RUN_VALUE" \
  AGENTMAIL_API_KEY="am_FIRST_RUN_VALUE" \
  XDG_RUNTIME_DIR="$TEST_ROOT/runtime3"
OUT_DIR_1="$_OUT_DIR"
mem0_first="$(cat "$OUT_DIR_1/mem0.env")"
_assert_contains "first run: MEM0 has first value" "MEM0_API_KEY=m0_FIRST_RUN_VALUE" "$mem0_first"

# Second run with different values (simulates stale-PAT re-bootstrap).
_run_materialize "$TEST3_DIR" env \
  MEM0_API_KEY="m0_SECOND_RUN_VALUE" \
  AGENTMAIL_API_KEY="am_SECOND_RUN_VALUE" \
  XDG_RUNTIME_DIR="$TEST_ROOT/runtime3"
OUT_DIR_2="$_OUT_DIR"
mem0_second="$(cat "$OUT_DIR_2/mem0.env")"
_assert_contains "second run: MEM0 has second value" "MEM0_API_KEY=m0_SECOND_RUN_VALUE" "$mem0_second"
_assert_eq "second run: same output dir" "$OUT_DIR_1" "$OUT_DIR_2"

if printf '%s' "$mem0_second" | grep -q "m0_FIRST_RUN_VALUE"; then
  _fail "second run: stale first value still present"
else
  _pass "second run: first value overwritten cleanly"
fi

# ============================================================
# TEST 4 — templates dir absent: skip cleanly
# ============================================================
printf '\n== test 4: missing templates dir ==\n'
TEST4_DIR="$TEST_ROOT/test4"
mkdir -p "$TEST4_DIR"
# Do NOT create $TEST4_DIR/scripts/lib/mcp-env-templates/ — exercise the
# templates-absent skip path.
out4="$(
  env XDG_RUNTIME_DIR="$TEST_ROOT/runtime4" bash -c "
    set -uo pipefail
    log() { :; }
    source '$COMMON' 2>/dev/null
    VADE_RUNTIME_DIR='$TEST4_DIR'
    materialize_mcp_env_files
    printf 'exit=%s\n' \$?
  " 2>&1
)"
_assert_contains "test 4: function exits 0 cleanly when templates dir absent" "exit=0" "$out4"

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
