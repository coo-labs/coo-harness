#!/usr/bin/env bash
# test-op-retry-recovery: exercise the _op_to_file retry path so
# regressions in install_coo_ssh_keys' transient-recovery behavior
# (coo-harness#451) get caught at PR time.
#
# Strategy: source scripts/lib/common.sh, override `op` with a bash
# function that fails its first N invocations then succeeds (cheaper
# than wiring up the PATH-shadowed mock binary for the production
# bootstrap-regression suite). Verify:
#
#   1. _op_to_file recovers within the 5-attempt retry budget when
#      N=2 (first two op-reads fail with a transient 503, third
#      succeeds) — rc=0, target file written with expected content.
#   2. _op_to_file fails cleanly when N=5 (every transient attempt
#      exhausts the budget) — rc=1, no half-written target file.
#   3. _op_to_file fast-fails on rate-limit (post briefing-40 T1.2):
#      the first op-read attempt returns rate-limit stderr; the loop
#      breaks immediately without burning the full budget. Wrap shim's
#      3-token swap-and-retry has already exhausted the cascade by
#      the time rate-limit surfaces here, so further retries are
#      pure waste. See coo-harness#545.
#   4. The structured observability event lands in
#      ~/.vade/op-read-failures.jsonl with the expected schema.
#
# Run: bash scripts/ci/test-op-retry-recovery.sh
# Exit: 0 if all assertions pass, non-zero otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMON="$REPO_ROOT/scripts/lib/common.sh"

[ -f "$COMMON" ] || { echo "FAIL: common.sh not found at $COMMON" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Isolated $HOME so the test's op-read-failures.jsonl writes don't
# touch the operator's real ~/.vade directory.
export HOME="$WORK/home"
mkdir -p "$HOME/.vade"

# common.sh sources a bunch of env it expects from cloud-setup. Provide
# the minimum.
export VADE_RUNTIME_DIR="$REPO_ROOT"
export VADE_COO_MEMORY_DIR="${VADE_COO_MEMORY_DIR:-$REPO_ROOT/../coo-memory}"
export VADE_CLOUD_STATE_DIR="$WORK/cloud-state"
mkdir -p "$VADE_CLOUD_STATE_DIR"

# shellcheck disable=SC1090
source "$COMMON"

PASS=0
FAIL=0
declare -a FAILURES=()

_pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
_fail() { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  FAIL  %s\n' "$1"; }

# ── Test 1: N=2 → recovers within retry budget ───────────────────
printf '\nTest 1: _op_to_file recovers when first 2 op-reads fail (transient)\n'
COUNTER="$WORK/counter1"
echo 0 > "$COUNTER"

# Override `op` as a bash function that consults the counter. First
# N invocations exit 1 with a transient stderr (503 Service Unavailable
# — must NOT match the wrapper's `rate.?limit|too many requests` regex
# or T1.2 fast-fail kicks in); subsequent invocations succeed.
op() {
  if [ "${1:-}" = "read" ]; then
    local cur next
    cur="$(cat "$COUNTER" 2>/dev/null || echo 0)"
    next=$((cur + 1))
    echo "$next" > "$COUNTER"
    if [ "$cur" -lt 2 ]; then
      printf '[ERROR] could not read secret: HTTP 503 Service Unavailable\n' >&2
      return 1
    fi
    # Successful path: echo the expected canned content for the ref.
    echo "fake-secret-content-for-${2}"
    return 0
  fi
  return 0
}
export -f op

TARGET1="$WORK/target1"
rm -f "$TARGET1" "$HOME/.vade/op-read-failures.jsonl"
RC1=0
_op_to_file "op://COO/test-ref/value" "$TARGET1" 0600 || RC1=$?

if [ "$RC1" -eq 0 ]; then
  _pass "N=2: _op_to_file returned rc=0"
else
  _fail "N=2: _op_to_file rc=$RC1 (expected 0)"
fi

if [ -f "$TARGET1" ] && grep -q 'fake-secret-content-for-' "$TARGET1"; then
  _pass "N=2: target file written with expected content"
else
  _fail "N=2: target file missing or wrong content"
fi

# Counter should read 3: two failures + one success.
COUNTER_FINAL="$(cat "$COUNTER" 2>/dev/null || echo 0)"
if [ "$COUNTER_FINAL" = "3" ]; then
  _pass "N=2: exactly 3 op-read attempts consumed (2 fail + 1 succeed)"
else
  _fail "N=2: counter=$COUNTER_FINAL (expected 3)"
fi

# Observability event should be written (call took >1s due to retry backoff).
if [ -f "$HOME/.vade/op-read-failures.jsonl" ]; then
  if grep -q '"kind":"op_read"' "$HOME/.vade/op-read-failures.jsonl" \
     && grep -q '"ref":"op://COO/test-ref/value"' "$HOME/.vade/op-read-failures.jsonl" \
     && grep -q '"rc":0' "$HOME/.vade/op-read-failures.jsonl"; then
    _pass "N=2: jsonl event written with kind/ref/rc=0"
  else
    _fail "N=2: jsonl present but schema mismatch ($(cat "$HOME/.vade/op-read-failures.jsonl"))"
  fi
else
  _fail "N=2: ~/.vade/op-read-failures.jsonl not written"
fi

# ── Test 2: N=5 → exhausts budget, _op_to_file fails ─────────────
printf '\nTest 2: _op_to_file fails cleanly when all 5 transient retries fail\n'
echo 0 > "$COUNTER"

# Same override; raise the failure budget so all 5 attempts fail. Use
# a transient stderr (502) — rate-limit would short-circuit at attempt 1.
op() {
  if [ "${1:-}" = "read" ]; then
    local cur next
    cur="$(cat "$COUNTER" 2>/dev/null || echo 0)"
    next=$((cur + 1))
    echo "$next" > "$COUNTER"
    if [ "$cur" -lt 5 ]; then
      printf '[ERROR] could not read secret: HTTP 502 Bad Gateway\n' >&2
      return 1
    fi
    echo "should-not-be-reached"
    return 0
  fi
  return 0
}
export -f op

TARGET2="$WORK/target2"
rm -f "$TARGET2"
RC2=0
_op_to_file "op://COO/exhaust-ref/value" "$TARGET2" 0600 || RC2=$?

if [ "$RC2" -ne 0 ]; then
  _pass "N=5: _op_to_file returned rc=$RC2 (expected non-zero)"
else
  _fail "N=5: _op_to_file rc=0 (expected non-zero — all 5 retries should fail)"
fi

if [ ! -f "$TARGET2" ]; then
  _pass "N=5: target file not written (no half-state)"
else
  _fail "N=5: target file written at $TARGET2 despite failure"
fi

COUNTER_FINAL2="$(cat "$COUNTER" 2>/dev/null || echo 0)"
if [ "$COUNTER_FINAL2" = "5" ]; then
  _pass "N=5: exactly 5 op-read attempts consumed (full retry budget)"
else
  _fail "N=5: counter=$COUNTER_FINAL2 (expected 5)"
fi

# A FAIL event should also be in the jsonl (rc != 0).
if grep -q '"ref":"op://COO/exhaust-ref/value"' "$HOME/.vade/op-read-failures.jsonl" 2>/dev/null \
   && grep -q '"ref":"op://COO/exhaust-ref/value".*"rc":[^0]' "$HOME/.vade/op-read-failures.jsonl"; then
  _pass "N=5: jsonl event recorded with rc!=0 for exhaust-ref"
else
  _fail "N=5: jsonl missing rc!=0 event for exhaust-ref"
fi

# ── Test 3: rate-limit → fast-fail (briefing-40 T1.2) ────────────
printf '\nTest 3: _op_to_file fast-fails on rate-limit (no full-budget burn)\n'
COUNTER3="$WORK/counter3"
echo 0 > "$COUNTER3"

# Every attempt returns rate-limit stderr. With T1.2 in place, the loop
# must break after attempt 1, leaving the counter at exactly 1. With
# the prior `retry 5 op read`, the counter would reach 5.
op() {
  if [ "${1:-}" = "read" ]; then
    local cur next
    cur="$(cat "$COUNTER3" 2>/dev/null || echo 0)"
    next=$((cur + 1))
    echo "$next" > "$COUNTER3"
    printf '[ERROR] could not read secret: Too many requests. Your client has been rate-limited.\n' >&2
    return 1
  fi
  return 0
}
export -f op

TARGET3="$WORK/target3"
rm -f "$TARGET3"
RC3=0
_op_to_file "op://COO/rate-limit-ref/value" "$TARGET3" 0600 || RC3=$?

if [ "$RC3" -ne 0 ]; then
  _pass "rate-limit: _op_to_file returned rc=$RC3 (expected non-zero)"
else
  _fail "rate-limit: _op_to_file rc=0 (expected non-zero — wrap shim cascade exhausted)"
fi

if [ ! -f "$TARGET3" ]; then
  _pass "rate-limit: target file not written"
else
  _fail "rate-limit: target file written at $TARGET3 despite rate-limit"
fi

COUNTER_FINAL3="$(cat "$COUNTER3" 2>/dev/null || echo 0)"
if [ "$COUNTER_FINAL3" = "1" ]; then
  _pass "rate-limit: exactly 1 op-read attempt consumed (T1.2 fast-fail)"
else
  _fail "rate-limit: counter=$COUNTER_FINAL3 (expected 1; full-budget burn implies T1.2 regression)"
fi

# ── Summary ──────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
