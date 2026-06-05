#!/usr/bin/env bash
# test-op-coo-wrap: smoke-test the op wrapper that transparently
# falls back from OP_SERVICE_ACCOUNT_TOKEN to
# OP_SERVICE_ACCOUNT_TOKEN_BACKUP on 1Password rate-limit.
#
# Strategy: install a mock `op-real` whose behavior is controlled by
# env vars (MOCK_OP_FAIL_TOKEN_A / _B set to one of {rate_limit,
# other_error, ok}; MOCK_OP_ECHO_TOKEN_NAME=1 makes it print which
# token bucket it received on stdout). Then run the wrapper with
# various marker / env-var permutations and assert the swap behavior.
#
# Run: bash scripts/ci/test-op-coo-wrap.sh
# Exit: 0 if all assertions pass, non-zero otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../op-coo-wrap.sh"

[ -x "$WRAPPER" ] || { echo "FAIL: wrapper not executable at $WRAPPER"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Mock op-real: behaves per env switches.
#   MOCK_OP_TOKEN_A_VALUE / _B_VALUE — the strings the test will set
#     OP_SERVICE_ACCOUNT_TOKEN / OP_SERVICE_ACCOUNT_TOKEN_BACKUP to.
#     Mock reports which bucket the actual OP_SERVICE_ACCOUNT_TOKEN
#     matches ("A", "B", or "OTHER") by comparing values.
#   MOCK_OP_FAIL_A / _B — set to "rate_limit" / "other_error" / "ok".
#     Controls exit code + stderr based on which bucket was passed.
cat > "$WORK/op-real" <<'EOF'
#!/usr/bin/env bash
got="${OP_SERVICE_ACCOUNT_TOKEN:-<unset>}"
if   [ "$got" = "${MOCK_OP_TOKEN_A_VALUE:-__no_a__}" ]; then bucket="A"
elif [ "$got" = "${MOCK_OP_TOKEN_B_VALUE:-__no_b__}" ]; then bucket="B"
else bucket="OTHER"
fi
printf 'TOKEN_BUCKET=%s\n' "$bucket"
printf 'ARGV=%s\n' "$*"

# Behavior per bucket.
case "$bucket" in
  A) fail_mode="${MOCK_OP_FAIL_A:-ok}" ;;
  B) fail_mode="${MOCK_OP_FAIL_B:-ok}" ;;
  *) fail_mode="${MOCK_OP_FAIL_OTHER:-ok}" ;;
esac

case "$fail_mode" in
  rate_limit)
    printf '[ERROR] could not read secret: Too many requests. Your client has been rate-limited. Try again in 60 seconds\n' >&2
    exit 1
    ;;
  other_error)
    printf '[ERROR] could not read secret: not found\n' >&2
    exit 1
    ;;
  ok)
    printf '[OK] mock op-real succeeded with bucket=%s\n' "$bucket" >&2
    exit 0
    ;;
esac
EOF
chmod 0755 "$WORK/op-real"

PASS=0
FAIL=0
declare -a FAILURES=()

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS+1))
    printf '  PASS  %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$name")
    printf '  FAIL  %s\n' "$name"
    printf '         expected to contain: %s\n' "$needle"
    printf '         got:\n'
    printf '%s\n' "$haystack" | sed 's/^/           /'
  fi
}

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
    printf '  PASS  %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$name")
    printf '  FAIL  %s\n' "$name"
    printf '         want: %s\n' "$want"
    printf '         got:  %s\n' "$got"
  fi
}

# Fresh marker dir per test so state doesn't bleed.
fresh_env() {
  XDG_RUNTIME_DIR="$(mktemp -d)"
  export XDG_RUNTIME_DIR
}

# Common env: real-binary path + token values.
export COO_OP_REAL="$WORK/op-real"
export MOCK_OP_TOKEN_A_VALUE="primary_token_AAAAAA"
export MOCK_OP_TOKEN_B_VALUE="backup_token_BBBBBB"

# ---- TEST 1: primary OK → uses A, no marker write ----
fresh_env
unset MOCK_OP_FAIL_A MOCK_OP_FAIL_B
OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP="$MOCK_OP_TOKEN_B_VALUE" \
rc=0; out="$("$WRAPPER" read 'op://fake/x' 2>&1)" || rc=$?
assert_contains "primary OK: bucket=A" "$out" "TOKEN_BUCKET=A"
assert_eq "primary OK: rc=0" "$rc" "0"
assert_eq "primary OK: marker not written" "$(cat "$XDG_RUNTIME_DIR/coo-op-wrap/active" 2>/dev/null || echo NONE)" "NONE"

# ---- TEST 2: primary rate-limited, backup OK → swap, marker=B ----
fresh_env
export MOCK_OP_FAIL_A="rate_limit"; unset MOCK_OP_FAIL_B
OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP="$MOCK_OP_TOKEN_B_VALUE" \
rc=0; out="$("$WRAPPER" read 'op://fake/x' 2>&1)" || rc=$?
assert_contains "RL primary: attempted A" "$out" "TOKEN_BUCKET=A"
assert_contains "RL primary: swapped to B" "$out" "TOKEN_BUCKET=B"
assert_eq "RL primary: final rc=0" "$rc" "0"
assert_eq "RL primary: marker=B" "$(cat "$XDG_RUNTIME_DIR/coo-op-wrap/active" 2>/dev/null)" "B"

# ---- TEST 3: marker=B + backup OK → uses B straight away, no probe of A ----
fresh_env
unset MOCK_OP_FAIL_A MOCK_OP_FAIL_B
mkdir -p "$XDG_RUNTIME_DIR/coo-op-wrap"
printf B > "$XDG_RUNTIME_DIR/coo-op-wrap/active"
OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP="$MOCK_OP_TOKEN_B_VALUE" \
rc=0; out="$("$WRAPPER" read 'op://fake/x' 2>&1)" || rc=$?
assert_contains "marker=B: uses bucket=B" "$out" "TOKEN_BUCKET=B"
# Should NOT have probed A.
if printf '%s' "$out" | grep -q "TOKEN_BUCKET=A"; then
  FAIL=$((FAIL+1)); FAILURES+=("marker=B: should not probe A")
  printf '  FAIL  marker=B: should not probe A\n'
else
  PASS=$((PASS+1)); printf '  PASS  marker=B: no A probe\n'
fi
assert_eq "marker=B: rc=0" "$rc" "0"

# ---- TEST 4: marker=B + backup rate-limited, primary OK → swap back to A, marker=A ----
fresh_env
unset MOCK_OP_FAIL_A; export MOCK_OP_FAIL_B="rate_limit"
mkdir -p "$XDG_RUNTIME_DIR/coo-op-wrap"
printf B > "$XDG_RUNTIME_DIR/coo-op-wrap/active"
OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP="$MOCK_OP_TOKEN_B_VALUE" \
rc=0; out="$("$WRAPPER" read 'op://fake/x' 2>&1)" || rc=$?
assert_contains "RL backup: attempted B first" "$out" "TOKEN_BUCKET=B"
assert_contains "RL backup: swapped to A" "$out" "TOKEN_BUCKET=A"
assert_eq "RL backup: rc=0" "$rc" "0"
assert_eq "RL backup: marker=A" "$(cat "$XDG_RUNTIME_DIR/coo-op-wrap/active" 2>/dev/null)" "A"

# ---- TEST 5: both rate-limited → both attempted, final rc=1, marker unchanged ----
fresh_env
export MOCK_OP_FAIL_A="rate_limit"; export MOCK_OP_FAIL_B="rate_limit"
mkdir -p "$XDG_RUNTIME_DIR/coo-op-wrap"
printf A > "$XDG_RUNTIME_DIR/coo-op-wrap/active"
OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP="$MOCK_OP_TOKEN_B_VALUE" \
rc=0; out="$("$WRAPPER" read 'op://fake/x' 2>&1)" || rc=$?
assert_contains "both RL: attempted A" "$out" "TOKEN_BUCKET=A"
assert_contains "both RL: attempted B" "$out" "TOKEN_BUCKET=B"
assert_eq "both RL: rc=1" "$rc" "1"
assert_eq "both RL: marker unchanged=A" "$(cat "$XDG_RUNTIME_DIR/coo-op-wrap/active" 2>/dev/null)" "A"
assert_contains "both RL: stderr replayed" "$out" "Too many requests"

# ---- TEST 6: non-rate-limit error → no swap, surface error ----
fresh_env
export MOCK_OP_FAIL_A="other_error"; unset MOCK_OP_FAIL_B
OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP="$MOCK_OP_TOKEN_B_VALUE" \
rc=0; out="$("$WRAPPER" read 'op://fake/x' 2>&1)" || rc=$?
assert_contains "non-RL err: attempted A" "$out" "TOKEN_BUCKET=A"
# Must NOT swap.
if printf '%s' "$out" | grep -q "TOKEN_BUCKET=B"; then
  FAIL=$((FAIL+1)); FAILURES+=("non-RL err: should not swap")
  printf '  FAIL  non-RL err: should not swap\n'
else
  PASS=$((PASS+1)); printf '  PASS  non-RL err: no swap\n'
fi
assert_eq "non-RL err: rc=1" "$rc" "1"
assert_eq "non-RL err: marker untouched" "$(cat "$XDG_RUNTIME_DIR/coo-op-wrap/active" 2>/dev/null || echo NONE)" "NONE"

# ---- TEST 7: only primary set, RL → no swap available, single attempt ----
fresh_env
export MOCK_OP_FAIL_A="rate_limit"; unset MOCK_OP_FAIL_B
unset OP_SERVICE_ACCOUNT_TOKEN_BACKUP
OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
rc=0; out="$("$WRAPPER" read 'op://fake/x' 2>&1)" || rc=$?
attempts="$(printf '%s' "$out" | grep -c '^TOKEN_BUCKET=' || true)"
assert_eq "only A set: exactly 1 attempt" "$attempts" "1"
assert_eq "only A set: rc=1" "$rc" "1"

# ---- TEST 8: COO_OP_WRAP_DISABLE=1 → exec real, no shim logic ----
fresh_env
unset MOCK_OP_FAIL_A MOCK_OP_FAIL_B
OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP="$MOCK_OP_TOKEN_B_VALUE" \
COO_OP_WRAP_DISABLE=1 \
rc=0; out="$("$WRAPPER" read 'op://fake/x' 2>&1)" || rc=$?
assert_contains "disable=1: still uses A (no marker check)" "$out" "TOKEN_BUCKET=A"
assert_eq "disable=1: marker not created" "$(cat "$XDG_RUNTIME_DIR/coo-op-wrap/active" 2>/dev/null || echo NONE)" "NONE"

# ---- TEST 9: idempotent stderr replay (rate-limit + retry) ----
# The wrapper replays only the FINAL attempt's stderr — the primary's
# rate-limit chatter should not leak through on a successful retry.
fresh_env
export MOCK_OP_FAIL_A="rate_limit"; unset MOCK_OP_FAIL_B
rc=0
out_stderr="$(OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
              OP_SERVICE_ACCOUNT_TOKEN_BACKUP="$MOCK_OP_TOKEN_B_VALUE" \
              "$WRAPPER" read 'op://fake/x' 2>&1 1>/dev/null)" || rc=$?
assert_eq "RL swap success: rc=0" "$rc" "0"
assert_contains "RL swap success: B stderr present" "$out_stderr" "bucket=B"
if printf '%s' "$out_stderr" | grep -q "Too many requests"; then
  FAIL=$((FAIL+1)); FAILURES+=("RL swap success: should not leak primary stderr")
  printf '  FAIL  RL swap success: should not leak primary RL stderr\n'
else
  PASS=$((PASS+1)); printf '  PASS  RL swap success: primary RL stderr suppressed\n'
fi

# ---- Summary ----
echo
echo "----------------------------------------"
echo "op-coo-wrap test summary: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failing tests:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
