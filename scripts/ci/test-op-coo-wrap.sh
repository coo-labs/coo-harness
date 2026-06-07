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
#   MOCK_OP_TOKEN_A_VALUE / _B_VALUE / _C_VALUE — the strings the test will set
#     OP_SERVICE_ACCOUNT_TOKEN / OP_SERVICE_ACCOUNT_TOKEN_BACKUP /
#     OP_SERVICE_ACCOUNT_TOKEN_BACKUP2 to. Mock reports which bucket the actual
#     OP_SERVICE_ACCOUNT_TOKEN matches ("A", "B", "C", or "OTHER") by value.
#   MOCK_OP_FAIL_A / _B / _C — set to "rate_limit" / "other_error" / "ok".
#     Controls exit code + stderr based on which bucket was passed.
cat > "$WORK/op-real" <<'EOF'
#!/usr/bin/env bash
got="${OP_SERVICE_ACCOUNT_TOKEN:-<unset>}"
if   [ "$got" = "${MOCK_OP_TOKEN_A_VALUE:-__no_a__}" ]; then bucket="A"
elif [ "$got" = "${MOCK_OP_TOKEN_B_VALUE:-__no_b__}" ]; then bucket="B"
elif [ "$got" = "${MOCK_OP_TOKEN_C_VALUE:-__no_c__}" ]; then bucket="C"
else bucket="OTHER"
fi
printf 'TOKEN_BUCKET=%s\n' "$bucket"
printf 'ARGV=%s\n' "$*"

# Behavior per bucket.
case "$bucket" in
  A) fail_mode="${MOCK_OP_FAIL_A:-ok}" ;;
  B) fail_mode="${MOCK_OP_FAIL_B:-ok}" ;;
  C) fail_mode="${MOCK_OP_FAIL_C:-ok}" ;;
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

# Pre-export the SA-token bucket vars so each per-case `VAR=value \`
# reassignment-without-export preserves the export attribute and the
# wrapper subprocess actually sees the test's mock values. On a host
# where OP_SERVICE_ACCOUNT_TOKEN is already exported (the dev container),
# this is a no-op; on a clean runner (CI), the omission would make every
# reassignment a non-exported local → wrapper sees the var as unset →
# mock op-real reports bucket=OTHER and every assertion fails.
export OP_SERVICE_ACCOUNT_TOKEN="" OP_SERVICE_ACCOUNT_TOKEN_BACKUP="" OP_SERVICE_ACCOUNT_TOKEN_BACKUP2=""
export MOCK_OP_TOKEN_C_VALUE="backup2_token_CCCCCC"

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

# ---- TEST 10: A+B rate-limited, C ok → cascades to C, marker=C ----
# Re-export the SA-token vars in case prior tests unset OP_SERVICE_ACCOUNT_TOKEN_BACKUP
# (TEST 7 does so); a plain prefix-assignment after unset doesn't restore the export
# attribute, and the subshell wouldn't see B as a result.
fresh_env
export MOCK_OP_FAIL_A="rate_limit"; export MOCK_OP_FAIL_B="rate_limit"; unset MOCK_OP_FAIL_C
export OP_SERVICE_ACCOUNT_TOKEN OP_SERVICE_ACCOUNT_TOKEN_BACKUP OP_SERVICE_ACCOUNT_TOKEN_BACKUP2
OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP="$MOCK_OP_TOKEN_B_VALUE" \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP2="$MOCK_OP_TOKEN_C_VALUE" \
rc=0; out="$("$WRAPPER" read 'op://fake/x' 2>&1)" || rc=$?
assert_contains "A+B RL, C ok: attempted A" "$out" "TOKEN_BUCKET=A"
assert_contains "A+B RL, C ok: attempted B" "$out" "TOKEN_BUCKET=B"
assert_contains "A+B RL, C ok: cascaded to C" "$out" "TOKEN_BUCKET=C"
assert_eq "A+B RL, C ok: rc=0" "$rc" "0"
assert_eq "A+B RL, C ok: marker=C" "$(cat "$XDG_RUNTIME_DIR/coo-op-wrap/active" 2>/dev/null)" "C"

# ---- TEST 11: all three rate-limited → all attempted, rc=1, marker unchanged ----
fresh_env
export MOCK_OP_FAIL_A="rate_limit"; export MOCK_OP_FAIL_B="rate_limit"; export MOCK_OP_FAIL_C="rate_limit"
export OP_SERVICE_ACCOUNT_TOKEN OP_SERVICE_ACCOUNT_TOKEN_BACKUP OP_SERVICE_ACCOUNT_TOKEN_BACKUP2
mkdir -p "$XDG_RUNTIME_DIR/coo-op-wrap"
printf A > "$XDG_RUNTIME_DIR/coo-op-wrap/active"
OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP="$MOCK_OP_TOKEN_B_VALUE" \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP2="$MOCK_OP_TOKEN_C_VALUE" \
rc=0; out="$("$WRAPPER" read 'op://fake/x' 2>&1)" || rc=$?
assert_contains "all RL: attempted A" "$out" "TOKEN_BUCKET=A"
assert_contains "all RL: attempted B" "$out" "TOKEN_BUCKET=B"
assert_contains "all RL: attempted C" "$out" "TOKEN_BUCKET=C"
assert_eq "all RL: rc=1" "$rc" "1"
assert_eq "all RL: marker unchanged=A" "$(cat "$XDG_RUNTIME_DIR/coo-op-wrap/active" 2>/dev/null)" "A"

# ---- TEST 12: marker=C + C ok → uses C straight away, no A/B probe ----
fresh_env
unset MOCK_OP_FAIL_A MOCK_OP_FAIL_B MOCK_OP_FAIL_C
mkdir -p "$XDG_RUNTIME_DIR/coo-op-wrap"
printf C > "$XDG_RUNTIME_DIR/coo-op-wrap/active"
OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP="$MOCK_OP_TOKEN_B_VALUE" \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP2="$MOCK_OP_TOKEN_C_VALUE" \
rc=0; out="$("$WRAPPER" read 'op://fake/x' 2>&1)" || rc=$?
assert_contains "marker=C: uses bucket=C" "$out" "TOKEN_BUCKET=C"
if printf '%s' "$out" | grep -qE "TOKEN_BUCKET=(A|B)"; then
  FAIL=$((FAIL+1)); FAILURES+=("marker=C: should not probe A or B")
  printf '  FAIL  marker=C: should not probe A or B\n'
else
  PASS=$((PASS+1)); printf '  PASS  marker=C: no A/B probe\n'
fi
assert_eq "marker=C: rc=0" "$rc" "0"

# ---- TEST 13: marker=C circular wrap on C-RL → tries C then A then B ----
fresh_env
export MOCK_OP_FAIL_C="rate_limit"; unset MOCK_OP_FAIL_A MOCK_OP_FAIL_B
mkdir -p "$XDG_RUNTIME_DIR/coo-op-wrap"
printf C > "$XDG_RUNTIME_DIR/coo-op-wrap/active"
OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP="$MOCK_OP_TOKEN_B_VALUE" \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP2="$MOCK_OP_TOKEN_C_VALUE" \
rc=0; out="$("$WRAPPER" read 'op://fake/x' 2>&1)" || rc=$?
# Order should be C (first, RL), then A (next, ok). Should NOT reach B.
assert_contains "circular C: tried C first" "$out" "TOKEN_BUCKET=C"
assert_contains "circular C: swapped to A" "$out" "TOKEN_BUCKET=A"
if printf '%s' "$out" | grep -q "TOKEN_BUCKET=B"; then
  FAIL=$((FAIL+1)); FAILURES+=("circular C: should not reach B after A succeeded")
  printf '  FAIL  circular C: should not reach B after A succeeded\n'
else
  PASS=$((PASS+1)); printf '  PASS  circular C: stopped at A (no B probe)\n'
fi
assert_eq "circular C: rc=0" "$rc" "0"
assert_eq "circular C: marker=A" "$(cat "$XDG_RUNTIME_DIR/coo-op-wrap/active" 2>/dev/null)" "A"

# ---- TEST 14: BACKUP2 set but BACKUP unset → A → C (skips B slot cleanly) ----
fresh_env
export MOCK_OP_FAIL_A="rate_limit"; unset MOCK_OP_FAIL_C
unset OP_SERVICE_ACCOUNT_TOKEN_BACKUP
OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
OP_SERVICE_ACCOUNT_TOKEN_BACKUP2="$MOCK_OP_TOKEN_C_VALUE" \
rc=0; out="$("$WRAPPER" read 'op://fake/x' 2>&1)" || rc=$?
assert_contains "skip B: attempted A" "$out" "TOKEN_BUCKET=A"
assert_contains "skip B: cascaded directly to C" "$out" "TOKEN_BUCKET=C"
if printf '%s' "$out" | grep -q "TOKEN_BUCKET=B"; then
  FAIL=$((FAIL+1)); FAILURES+=("skip B: should not attempt B (unset)")
  printf '  FAIL  skip B: attempted B despite being unset\n'
else
  PASS=$((PASS+1)); printf '  PASS  skip B: B slot pruned (unset)\n'
fi
assert_eq "skip B: rc=0" "$rc" "0"
assert_eq "skip B: marker=C" "$(cat "$XDG_RUNTIME_DIR/coo-op-wrap/active" 2>/dev/null)" "C"

# ---- TEST 15: COO_OP_WRAP_LOG_READS=1 → L2 jsonl event written ----
# Verify the instrumentation shipped by coo-harness#540 / briefing-40:
# every op invocation emits one jsonl event per attempt to
# /dev/shm/coo-op-reads-L2.<session>.jsonl with the documented schema.
# Use explicit `env` so the prefix scopes to the wrapper subshell rather
# than the local `rc=0` command (which would not propagate).
fresh_env
unset MOCK_OP_FAIL_A MOCK_OP_FAIL_B MOCK_OP_FAIL_C
LOG_SESSION="ci-test-540-$$"
LOG_PATH="/dev/shm/coo-op-reads-L2.${LOG_SESSION}.jsonl"
rm -f "$LOG_PATH"
rc=0
out="$(env -u OP_SERVICE_ACCOUNT_TOKEN_BACKUP2 \
           CLAUDE_CODE_SESSION_ID="$LOG_SESSION" \
           COO_OP_WRAP_LOG_READS=1 \
           OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
           OP_SERVICE_ACCOUNT_TOKEN_BACKUP="$MOCK_OP_TOKEN_B_VALUE" \
           "$WRAPPER" read 'op://COO/test/path' 2>&1)" || rc=$?
assert_eq "instrumentation: rc=0" "$rc" "0"
if [ ! -f "$LOG_PATH" ]; then
  FAIL=$((FAIL+1)); FAILURES+=("instrumentation: log file not written at $LOG_PATH")
  printf '  FAIL  instrumentation: log file not written at %s\n' "$LOG_PATH"
else
  PASS=$((PASS+1)); printf '  PASS  instrumentation: log file written\n'
  event_count="$(wc -l < "$LOG_PATH")"
  assert_eq "instrumentation: exactly 1 event for 1 attempt" "$event_count" "1"
  event_line="$(head -1 "$LOG_PATH")"
  assert_contains "instrumentation: layer=L2" "$event_line" '"layer":"L2"'
  assert_contains "instrumentation: session_id" "$event_line" "\"session_id\":\"$LOG_SESSION\""
  assert_contains "instrumentation: op_path captured" "$event_line" '"op_path":"op://COO/test/path"'
  assert_contains "instrumentation: token_slot=A" "$event_line" '"token_slot":"A"'
  assert_contains "instrumentation: rc=0" "$event_line" '"rc":0'
  assert_contains "instrumentation: rate_limited=false" "$event_line" '"rate_limited":false'
  assert_contains "instrumentation: retry_attempt_index=0" "$event_line" '"retry_attempt_index":0'
fi
rm -f "$LOG_PATH"

# ---- TEST 16: COO_OP_WRAP_LOG_READS=0 → no jsonl event ----
fresh_env
LOG_PATH="/dev/shm/coo-op-reads-L2.${LOG_SESSION}.jsonl"
rm -f "$LOG_PATH"
rc=0
out="$(env -u OP_SERVICE_ACCOUNT_TOKEN_BACKUP2 \
           CLAUDE_CODE_SESSION_ID="$LOG_SESSION" \
           COO_OP_WRAP_LOG_READS=0 \
           OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
           OP_SERVICE_ACCOUNT_TOKEN_BACKUP="$MOCK_OP_TOKEN_B_VALUE" \
           "$WRAPPER" read 'op://COO/test/path' 2>&1)" || rc=$?
assert_eq "instrumentation off: rc=0" "$rc" "0"
if [ -f "$LOG_PATH" ]; then
  FAIL=$((FAIL+1)); FAILURES+=("instrumentation off: log file written despite COO_OP_WRAP_LOG_READS=0")
  printf '  FAIL  instrumentation off: log file written despite COO_OP_WRAP_LOG_READS=0\n'
else
  PASS=$((PASS+1)); printf '  PASS  instrumentation off: log file suppressed\n'
fi

# ---- TEST 17: rate-limit retry → one event per attempt, retry_attempt_index counts ----
fresh_env
LOG_PATH="/dev/shm/coo-op-reads-L2.${LOG_SESSION}.jsonl"
rm -f "$LOG_PATH"
export MOCK_OP_FAIL_A="rate_limit"; unset MOCK_OP_FAIL_B MOCK_OP_FAIL_C
rc=0
out="$(env -u OP_SERVICE_ACCOUNT_TOKEN_BACKUP2 \
           CLAUDE_CODE_SESSION_ID="$LOG_SESSION" \
           COO_OP_WRAP_LOG_READS=1 \
           OP_SERVICE_ACCOUNT_TOKEN="$MOCK_OP_TOKEN_A_VALUE" \
           OP_SERVICE_ACCOUNT_TOKEN_BACKUP="$MOCK_OP_TOKEN_B_VALUE" \
           "$WRAPPER" read 'op://COO/test/path' 2>&1)" || rc=$?
assert_eq "rate-limit retry: rc=0" "$rc" "0"
if [ ! -f "$LOG_PATH" ]; then
  FAIL=$((FAIL+1)); FAILURES+=("rate-limit retry: log file not written")
  printf '  FAIL  rate-limit retry: log file not written\n'
else
  event_count="$(wc -l < "$LOG_PATH")"
  assert_eq "rate-limit retry: 2 events (1 fail + 1 success)" "$event_count" "2"
  attempt_0="$(sed -n '1p' "$LOG_PATH")"
  attempt_1="$(sed -n '2p' "$LOG_PATH")"
  assert_contains "rate-limit retry: attempt 0 = A" "$attempt_0" '"token_slot":"A"'
  assert_contains "rate-limit retry: attempt 0 rate-limited" "$attempt_0" '"rate_limited":true'
  assert_contains "rate-limit retry: attempt 0 retry_attempt_index=0" "$attempt_0" '"retry_attempt_index":0'
  assert_contains "rate-limit retry: attempt 1 = B" "$attempt_1" '"token_slot":"B"'
  assert_contains "rate-limit retry: attempt 1 success" "$attempt_1" '"rc":0'
  assert_contains "rate-limit retry: attempt 1 retry_attempt_index=1" "$attempt_1" '"retry_attempt_index":1'
fi
rm -f "$LOG_PATH"

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
