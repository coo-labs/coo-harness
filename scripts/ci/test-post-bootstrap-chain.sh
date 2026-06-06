#!/usr/bin/env bash
# CI test for post-bootstrap-chain.sh — Layer-1.5 ordering + failure
# isolation (coo-memory#1250 R9).
#
# What's under test:
#   1. The 5-ordered-children pattern from MEMO-2026-06-05-ootw:
#      coo-identity-digest → discussions → project-board → idle-watchdog
#      → integrity-check-live. Order is part of the contract; this test
#      is the mechanical guarantee that reviewers can point at when
#      rejecting parallel-sibling additions.
#   2. Failure isolation: any single child failing must not block the
#      rest. The chain's _run_child wraps each invocation in a
#      `|| log ... continuing` envelope; this test exercises that.
#
# How:
#   Stage a self-contained workspace under $TEST_ROOT with the real
#   scripts/boot/post-bootstrap-chain.sh + scripts/lib/common.sh,
#   plus stub lifecycle children that exit 0 and a stub integrity-check
#   that also exits 0. Run the chain twice — once clean, once with a
#   fault-injected child — and assert against the JSONL trace the
#   chain emits when VADE_POST_BOOTSTRAP_TRACE_OUT is set.
#
# Exit 0 on success, non-zero on first assertion failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROD_CHAIN="$REPO_ROOT/scripts/boot/post-bootstrap-chain.sh"
PROD_COMMON="$REPO_ROOT/scripts/lib/common.sh"

TEST_ROOT="${TEST_ROOT:-/tmp/post-bootstrap-chain-test-$$}"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0
FAILURES=()

_pass() {
  PASS=$((PASS + 1))
  echo "  ok: $1"
}

_fail() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$1")
  echo "  FAIL: $1"
}

# Stage a minimal coo-harness mirror at $TEST_ROOT/coo-harness with:
#   - the real post-bootstrap-chain.sh under scripts/boot/
#   - the real lib/common.sh under scripts/lib/
#   - stub lifecycle children that each `echo $name; exit 0`
#   - stub integrity-check.sh that exits 0 (chain backgrounds it via
#     nohup; we just need the file to exist + execute)
_stage() {
  local mirror="$TEST_ROOT/coo-harness"
  rm -rf "$mirror"
  mkdir -p "$mirror/scripts/boot" "$mirror/scripts/lib" "$mirror/scripts/lifecycle"
  cp "$PROD_CHAIN" "$mirror/scripts/boot/post-bootstrap-chain.sh"
  cp "$PROD_COMMON" "$mirror/scripts/lib/common.sh"
  chmod +x "$mirror/scripts/boot/post-bootstrap-chain.sh"

  local child
  for child in coo-identity-digest discussions-digest project-board-digest session-idle-watchdog; do
    cat > "$mirror/scripts/lifecycle/$child.sh" <<EOF
#!/usr/bin/env bash
echo "[stub] $child ran (\$*)" >&2
exit 0
EOF
    chmod +x "$mirror/scripts/lifecycle/$child.sh"
  done

  cat > "$mirror/scripts/boot/integrity-check.sh" <<'EOF'
#!/usr/bin/env bash
# Stub for the chain's live-phase backgrounded integrity-check.
# Production version runs E5–E9 network probes; CI stub exits 0.
exit 0
EOF
  chmod +x "$mirror/scripts/boot/integrity-check.sh"

  printf '%s' "$mirror"
}

_invoke_chain() {
  local mirror="$1" trace_out="$2" fault="${3:-}"
  local home_dir="$TEST_ROOT/home"
  rm -rf "$home_dir"
  mkdir -p "$home_dir/.vade"
  VADE_POST_BOOTSTRAP_TRACE_OUT="$trace_out" \
  VADE_POST_BOOTSTRAP_FAULT_INJECT="$fault" \
  HOME="$home_dir" \
    bash "$mirror/scripts/boot/post-bootstrap-chain.sh" >/dev/null 2>&1
}

# Assert that the trace file has exactly the expected (order, child, rc)
# triples in sequence. Format per record:
#   {"ts":"...","order":N,"child":"<name>","rc":N}
# Pass expected triples as repeated 3-arg sets: order child rc ...
_assert_trace() {
  local trace="$1"; shift
  if [ ! -f "$trace" ]; then
    _fail "trace file $trace not created"
    return 1
  fi
  local actual_lines expected_count
  actual_lines="$(wc -l < "$trace")"
  expected_count=$(( $# / 3 ))
  if [ "$actual_lines" -ne "$expected_count" ]; then
    _fail "trace has $actual_lines lines, expected $expected_count"
    echo "    trace contents:" >&2
    cat "$trace" >&2
    return 1
  fi
  local line_no=1
  while [ "$#" -gt 0 ]; do
    local exp_order="$1" exp_child="$2" exp_rc="$3"
    shift 3
    local line
    line="$(sed -n "${line_no}p" "$trace")"
    if ! printf '%s' "$line" | grep -q "\"order\":$exp_order,"; then
      _fail "line $line_no: order != $exp_order  (line: $line)"
      return 1
    fi
    if ! printf '%s' "$line" | grep -q "\"child\":\"$exp_child\""; then
      _fail "line $line_no: child != $exp_child  (line: $line)"
      return 1
    fi
    if ! printf '%s' "$line" | grep -q "\"rc\":$exp_rc"; then
      _fail "line $line_no: rc != $exp_rc  (line: $line)"
      return 1
    fi
    line_no=$((line_no + 1))
  done
  return 0
}

mirror="$(_stage)"

# ─── Test 1: clean run — all 5 children in canonical order, all rc=0 ──
echo "Test 1 — clean run: 5 ordered children, all rc=0"
trace1="$TEST_ROOT/trace1.jsonl"
_invoke_chain "$mirror" "$trace1"
if _assert_trace "$trace1" \
  1 coo-identity-digest 0 \
  2 discussions-digest 0 \
  3 project-board-digest 0 \
  4 session-idle-watchdog 0 \
  5 integrity-check-live 0; then
  _pass "5 children executed in canonical order, all rc=0"
fi

# ─── Test 2: fault-inject child #3 — assert failure isolation ────────
echo "Test 2 — fault-inject project-board-digest: children 4,5 still run"
trace2="$TEST_ROOT/trace2.jsonl"
_invoke_chain "$mirror" "$trace2" "project-board-digest"
if _assert_trace "$trace2" \
  1 coo-identity-digest 0 \
  2 discussions-digest 0 \
  3 project-board-digest 7 \
  4 session-idle-watchdog 0 \
  5 integrity-check-live 0; then
  _pass "child 3 forced fail (rc=7); children 4,5 still ran (rc=0)"
fi

# ─── Test 3: fault-inject earlier child — same isolation contract ────
echo "Test 3 — fault-inject coo-identity-digest: children 2-5 still run"
trace3="$TEST_ROOT/trace3.jsonl"
_invoke_chain "$mirror" "$trace3" "coo-identity-digest"
if _assert_trace "$trace3" \
  1 coo-identity-digest 7 \
  2 discussions-digest 0 \
  3 project-board-digest 0 \
  4 session-idle-watchdog 0 \
  5 integrity-check-live 0; then
  _pass "child 1 forced fail (rc=7); children 2-5 still ran (rc=0)"
fi

# ─── Test 4: trace knob unset — no trace file written ────────────────
echo "Test 4 — trace knob unset: no trace file"
trace4="$TEST_ROOT/trace4.jsonl"
home_dir="$TEST_ROOT/home-t4"
rm -rf "$home_dir"
mkdir -p "$home_dir/.vade"
unset VADE_POST_BOOTSTRAP_TRACE_OUT
HOME="$home_dir" bash "$mirror/scripts/boot/post-bootstrap-chain.sh" >/dev/null 2>&1
if [ ! -f "$trace4" ]; then
  _pass "no trace file when VADE_POST_BOOTSTRAP_TRACE_OUT unset"
else
  _fail "trace file appeared at $trace4 despite knob unset"
fi

# ─── Summary ─────────────────────────────────────────────────────────
echo ""
echo "post-bootstrap-chain test: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
exit 0
