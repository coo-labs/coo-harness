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
#      N=2 (first two op-reads fail, third succeeds) — rc=0, target
#      file written with expected content.
#   2. _op_to_file fails cleanly when N=5 (every attempt exhausts the
#      budget) — rc=1, no half-written target file.
#   3. The structured observability event lands in
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
printf '\nTest 1: _op_to_file recovers when first 2 op-reads fail\n'
COUNTER="$WORK/counter1"
echo 0 > "$COUNTER"

# Override `op` as a bash function that consults the counter. First
# N invocations exit 1 with rate-limit stderr (matching the wrapper's
# rate-limit detection regex); subsequent invocations succeed.
op() {
  if [ "${1:-}" = "read" ]; then
    local cur next
    cur="$(cat "$COUNTER" 2>/dev/null || echo 0)"
    next=$((cur + 1))
    echo "$next" > "$COUNTER"
    if [ "$cur" -lt 2 ]; then
      printf '[ERROR] could not read secret: Too many requests. Your client has been rate-limited.\n' >&2
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
printf '\nTest 2: _op_to_file fails cleanly when all 5 retries fail\n'
echo 0 > "$COUNTER"

# Same override; raise the failure budget so all 5 attempts fail.
op() {
  if [ "${1:-}" = "read" ]; then
    local cur next
    cur="$(cat "$COUNTER" 2>/dev/null || echo 0)"
    next=$((cur + 1))
    echo "$next" > "$COUNTER"
    if [ "$cur" -lt 5 ]; then
      printf '[ERROR] could not read secret: Too many requests.\n' >&2
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

# ── Summary ──────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
