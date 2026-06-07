#!/usr/bin/env bash
# test-coo-bootstrap-allowlist-sync: assert the op_marker_identity_sync
# block in coo-bootstrap.sh appends the active SA identity to
# .op-sa-identity when op-coo-wrap has transparently swapped tokens.
#
# Covers coo-labs/coo-harness#524: the shim absorbs rate-limit on the
# sentinel-read and returns success — bootstrap's _try_sa_fallback branch
# never fires — so without this block, op_whoami_identity_check below
# FATALs on the BACKUP token's user_uuid not being in the allowlist.
#
# The test inlines the same block from coo-bootstrap.sh; the script
# block is the canonical source of truth. If production drifts, this
# test mirrors the legacy shape and will need updating.
#
# Run: bash scripts/ci/test-coo-bootstrap-allowlist-sync.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP="$REPO_ROOT/scripts/boot/coo-bootstrap.sh"

[ -r "$BOOTSTRAP" ] || { echo "FAIL: coo-bootstrap.sh not readable at $BOOTSTRAP"; exit 1; }

PASS=0
FAIL=0
declare -a FAILURES=()

_pass() { PASS=$((PASS + 1)); printf '  ok: %s\n' "$1"; }
_fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); printf '  FAIL: %s\n' "$1"; }
_assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] && _pass "$label" || _fail "$label (expected=$expected actual=$actual)"
}
_assert_file_lines() {
  local label="$1" file="$2" expected_lines="$3"
  local actual
  actual="$(wc -l < "$file" 2>/dev/null | tr -d ' ')"
  _assert_eq "$label" "$expected_lines" "$actual"
}

# Sanity: the production block still contains the marker we're testing
# against — surfaces accidental removal.
if ! grep -q 'op_marker_identity_sync' "$BOOTSTRAP"; then
  echo "FAIL: production block 'op_marker_identity_sync' not found in $BOOTSTRAP — test stub out of sync"
  exit 1
fi
echo "Production block 'op_marker_identity_sync' present in coo-bootstrap.sh"

# Stage a sandbox HOME + XDG_RUNTIME_DIR per case so state doesn't bleed.
SANDBOX_ROOT="${SANDBOX_ROOT:-/tmp/test-coo-bootstrap-allowlist-sync-$$}"
trap 'rm -rf "$SANDBOX_ROOT" /tmp/test-coo-marker-mock-op-$$' EXIT

_setup_case() {
  local case_dir="$1"
  rm -rf "$SANDBOX_ROOT/$case_dir"
  mkdir -p "$SANDBOX_ROOT/$case_dir/home/.vade"
  mkdir -p "$SANDBOX_ROOT/$case_dir/runtime/coo-op-wrap"
  mkdir -p "$SANDBOX_ROOT/$case_dir/bin"
}

# Install a mock `op` that returns canned `whoami --format=json` output
# for the token currently in OP_SERVICE_ACCOUNT_TOKEN. The mock encodes
# its identity from the token-value prefix so the test can simulate
# A, B, or C identities without the wrap shim.
_install_mock_op() {
  local bin_dir="$1"
  cat > "$bin_dir/op" <<'MOCK_OP'
#!/usr/bin/env bash
# Mock op: routes whoami --format=json by the OP_SERVICE_ACCOUNT_TOKEN prefix.
case "${1:-}" in
  whoami)
    case "${2:-}" in
      --format=json)
        # Look at the token value to decide which identity to return.
        # In production, this is what op-real returns when the shim
        # has picked a specific token. Test tokens carry a known
        # prefix so the mock knows which UUID to print.
        case "${OP_SERVICE_ACCOUNT_TOKEN:-}" in
          ops_AAA*) printf '{"user_uuid":"PRIMARY_UUID"}\n' ;;
          ops_BBB*) printf '{"user_uuid":"BACKUP_UUID"}\n' ;;
          ops_CCC*) printf '{"user_uuid":"BACKUP2_UUID"}\n' ;;
          *)        printf '{"user_uuid":"UNKNOWN_UUID"}\n' ;;
        esac
        ;;
      *) printf 'ok\n' ;;
    esac
    ;;
  *) printf 'ok\n' ;;
esac
exit 0
MOCK_OP
  chmod +x "$bin_dir/op"
}

# Run the marker-sync block in isolation. Sources the production block
# from coo-bootstrap.sh by sed-extracting the labeled section between
# COO_BOOTSTRAP_STEP="op_marker_identity_sync" and the next
# COO_BOOTSTRAP_STEP= line. This keeps the test exercising the actual
# production logic without booting the full script.
_run_marker_sync_block() {
  local case_dir="$1"
  local home_dir="$SANDBOX_ROOT/$case_dir/home"
  local runtime_dir="$SANDBOX_ROOT/$case_dir/runtime"
  local bin_dir="$SANDBOX_ROOT/$case_dir/bin"

  # Extract the production block (sed-pulled section) and evaluate it
  # under the staged HOME / XDG_RUNTIME_DIR / mock op.
  local extracted
  extracted="$(
    awk '
      /COO_BOOTSTRAP_STEP="op_marker_identity_sync"/ {capture=1}
      capture {print}
      capture && /^  unset _op_pref_file$/ {exit}
    ' "$BOOTSTRAP"
  )"

  if [ -z "$extracted" ]; then
    echo "  FAIL: failed to extract op_marker_identity_sync block from $BOOTSTRAP" >&2
    return 1
  fi

  HOME="$home_dir" \
    XDG_RUNTIME_DIR="$runtime_dir" \
    PATH="$bin_dir:$PATH" \
    bash -c '
      set -uo pipefail
      log() { :; }
      '"$extracted"'
    '
}

# ============================================================
# Test 1: marker=B + BACKUP set → identity appended
# ============================================================
printf '\n== T1: marker=B + BACKUP set → identity appended ==\n'
_setup_case t1
_install_mock_op "$SANDBOX_ROOT/t1/bin"
printf 'B' > "$SANDBOX_ROOT/t1/runtime/coo-op-wrap/active"
printf 'PRIMARY_UUID\n' > "$SANDBOX_ROOT/t1/home/.vade/.op-sa-identity"

OP_SERVICE_ACCOUNT_TOKEN_BACKUP=ops_BBBxxx \
OP_SERVICE_ACCOUNT_TOKEN=ops_BBBxxx \
  _run_marker_sync_block t1

allowlist="$SANDBOX_ROOT/t1/home/.vade/.op-sa-identity"
if grep -Fxq "BACKUP_UUID" "$allowlist"; then
  _pass "T1: BACKUP_UUID appended to allowlist"
else
  _fail "T1: BACKUP_UUID NOT in allowlist (got: $(cat "$allowlist" 2>/dev/null | tr '\n' '|'))"
fi
if grep -Fxq "PRIMARY_UUID" "$allowlist"; then
  _pass "T1: PRIMARY_UUID still present"
else
  _fail "T1: PRIMARY_UUID lost"
fi
_assert_file_lines "T1: allowlist has exactly 2 lines" "$allowlist" "2"

# ============================================================
# Test 2: marker absent → no-op
# ============================================================
printf '\n== T2: marker absent → no-op ==\n'
_setup_case t2
_install_mock_op "$SANDBOX_ROOT/t2/bin"
printf 'PRIMARY_UUID\n' > "$SANDBOX_ROOT/t2/home/.vade/.op-sa-identity"
# Intentionally no marker file written.

OP_SERVICE_ACCOUNT_TOKEN_BACKUP=ops_BBBxxx \
OP_SERVICE_ACCOUNT_TOKEN=ops_AAAxxx \
  _run_marker_sync_block t2

allowlist="$SANDBOX_ROOT/t2/home/.vade/.op-sa-identity"
_assert_eq "T2: allowlist unchanged (single PRIMARY_UUID line)" "PRIMARY_UUID" "$(cat "$allowlist" 2>/dev/null)"

# ============================================================
# Test 3: marker=A → no-op
# ============================================================
printf '\n== T3: marker=A → no-op ==\n'
_setup_case t3
_install_mock_op "$SANDBOX_ROOT/t3/bin"
printf 'A' > "$SANDBOX_ROOT/t3/runtime/coo-op-wrap/active"
printf 'PRIMARY_UUID\n' > "$SANDBOX_ROOT/t3/home/.vade/.op-sa-identity"

OP_SERVICE_ACCOUNT_TOKEN_BACKUP=ops_BBBxxx \
OP_SERVICE_ACCOUNT_TOKEN=ops_AAAxxx \
  _run_marker_sync_block t3

allowlist="$SANDBOX_ROOT/t3/home/.vade/.op-sa-identity"
_assert_eq "T3: allowlist unchanged when marker=A" "PRIMARY_UUID" "$(cat "$allowlist" 2>/dev/null)"

# ============================================================
# Test 4: marker=B but BACKUP env var unset → no-op (stale marker)
# ============================================================
printf '\n== T4: marker=B but BACKUP unset → no-op (stale marker) ==\n'
_setup_case t4
_install_mock_op "$SANDBOX_ROOT/t4/bin"
printf 'B' > "$SANDBOX_ROOT/t4/runtime/coo-op-wrap/active"
printf 'PRIMARY_UUID\n' > "$SANDBOX_ROOT/t4/home/.vade/.op-sa-identity"

# Note: OP_SERVICE_ACCOUNT_TOKEN_BACKUP intentionally unset via env -u
env -u OP_SERVICE_ACCOUNT_TOKEN_BACKUP \
  HOME="$SANDBOX_ROOT/t4/home" \
  XDG_RUNTIME_DIR="$SANDBOX_ROOT/t4/runtime" \
  PATH="$SANDBOX_ROOT/t4/bin:$PATH" \
  OP_SERVICE_ACCOUNT_TOKEN=ops_AAAxxx \
  bash -c '
    set -uo pipefail
    log() { :; }
    '"$(awk '
      /COO_BOOTSTRAP_STEP="op_marker_identity_sync"/ {capture=1}
      capture {print}
      capture && /^  unset _op_pref_file$/ {exit}
    ' "$BOOTSTRAP")"'
  '

allowlist="$SANDBOX_ROOT/t4/home/.vade/.op-sa-identity"
_assert_eq "T4: allowlist unchanged when marker=B but BACKUP unset" "PRIMARY_UUID" "$(cat "$allowlist" 2>/dev/null)"

# ============================================================
# Test 5: marker=C + BACKUP2 set → identity appended
# ============================================================
printf '\n== T5: marker=C + BACKUP2 set → BACKUP2_UUID appended ==\n'
_setup_case t5
_install_mock_op "$SANDBOX_ROOT/t5/bin"
printf 'C' > "$SANDBOX_ROOT/t5/runtime/coo-op-wrap/active"
printf 'PRIMARY_UUID\n' > "$SANDBOX_ROOT/t5/home/.vade/.op-sa-identity"

OP_SERVICE_ACCOUNT_TOKEN_BACKUP=ops_BBBxxx \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP2=ops_CCCxxx \
OP_SERVICE_ACCOUNT_TOKEN=ops_CCCxxx \
  _run_marker_sync_block t5

allowlist="$SANDBOX_ROOT/t5/home/.vade/.op-sa-identity"
if grep -Fxq "BACKUP2_UUID" "$allowlist"; then
  _pass "T5: BACKUP2_UUID appended"
else
  _fail "T5: BACKUP2_UUID NOT in allowlist (got: $(cat "$allowlist" 2>/dev/null | tr '\n' '|'))"
fi

# ============================================================
# Test 6: idempotency — second run doesn't double-append
# ============================================================
printf '\n== T6: idempotency — second run leaves allowlist unchanged ==\n'
_setup_case t6
_install_mock_op "$SANDBOX_ROOT/t6/bin"
printf 'B' > "$SANDBOX_ROOT/t6/runtime/coo-op-wrap/active"
printf 'PRIMARY_UUID\n' > "$SANDBOX_ROOT/t6/home/.vade/.op-sa-identity"

OP_SERVICE_ACCOUNT_TOKEN_BACKUP=ops_BBBxxx \
OP_SERVICE_ACCOUNT_TOKEN=ops_BBBxxx \
  _run_marker_sync_block t6
allowlist="$SANDBOX_ROOT/t6/home/.vade/.op-sa-identity"
_assert_file_lines "T6: first run → 2 lines" "$allowlist" "2"

OP_SERVICE_ACCOUNT_TOKEN_BACKUP=ops_BBBxxx \
OP_SERVICE_ACCOUNT_TOKEN=ops_BBBxxx \
  _run_marker_sync_block t6
_assert_file_lines "T6: second run → still 2 lines (idempotent)" "$allowlist" "2"

# ============================================================
# Test 7: identity already in allowlist → no double-append
# ============================================================
printf '\n== T7: identity already in allowlist → no double-append ==\n'
_setup_case t7
_install_mock_op "$SANDBOX_ROOT/t7/bin"
printf 'B' > "$SANDBOX_ROOT/t7/runtime/coo-op-wrap/active"
printf 'PRIMARY_UUID\nBACKUP_UUID\n' > "$SANDBOX_ROOT/t7/home/.vade/.op-sa-identity"

OP_SERVICE_ACCOUNT_TOKEN_BACKUP=ops_BBBxxx \
OP_SERVICE_ACCOUNT_TOKEN=ops_BBBxxx \
  _run_marker_sync_block t7

allowlist="$SANDBOX_ROOT/t7/home/.vade/.op-sa-identity"
_assert_file_lines "T7: allowlist still has exactly 2 lines" "$allowlist" "2"

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
