#!/usr/bin/env bash
# CI test for the boot-brake deny-on-FAIL contract at the workflow-step
# surface (coo-memory#1250 R8.full, MEMO-2026-06-04-nzxf).
#
# What's under test:
#   The PreToolUse-denies-tool-call-when-integrity-FAIL contract, asserted
#   end-to-end as a workflow step rather than only from the unit harness
#   (test-boot-brake-guard.sh). The existing harness exercises the guard
#   in isolation; this step is the Layer-1.5 round-trip: stage a failing
#   boot state, pipe a representative tool envelope, assert the brake
#   refuses it under VADE_BRAKE_ENFORCE=block-on-FAIL (the production mode
#   per the memo).
#
# Failing boot state:
#   - integrity-check.json present but with summary.ok=false (deliverable
#     parses_json check passes — the JSON is valid — but the structural
#     marker the AC names is staged for completeness)
#   - .coo-bootstrap-done marker present
#   - settings.json present
#   - identity reads NOT seeded → the four Phase 1 *_consumed deliverables
#     (charter, governance, preferences, episodic_memory) all fail, which
#     is what actually trips the brake. The summary.ok=false fixture is
#     the AC's named structural signal; the identity-consumed entries are
#     the failing critical invariants that drive the deny response.
#
# Exit 0 on success, non-zero on first assertion failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/hooks/boot-brake-guard.sh"

TEST_ROOT="${TEST_ROOT:-/tmp/boot-brake-roundtrip-$$}"
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

# Stage: a state_dir + home_dir + fixture coo-memory under TEST_ROOT.
_stage_failing_boot() {
  local state_dir="$1" home_dir="$2" memory_dir="$3"
  rm -rf "$state_dir" "$home_dir" "$memory_dir"
  mkdir -p "$state_dir" "$home_dir/.vade" "$home_dir/.claude" "$memory_dir/operations"

  # AC-named structural signal: integrity-check.json present with
  # summary.ok=false. The brake's parses_json deliverable check accepts
  # this as "parses" — it's the missing identity reads (below) that
  # drive the FAIL state, but staging this file matches the AC literally
  # and documents intent.
  printf '{"summary":{"ok":false,"degraded_count":4}}\n' \
    > "$state_dir/integrity-check.json"
  touch "$home_dir/.vade/.coo-bootstrap-done"
  printf '{}\n' > "$home_dir/.claude/settings.json"

  cp "$SCRIPT_DIR/fixtures/boot-deliverables.yml" \
     "$memory_dir/operations/boot-deliverables.yml"
}

_invoke_brake() {
  local sid="$1" tool="$2" state_dir="$3" home_dir="$4" memory_dir="$5"
  local arg="${6:-}"
  local input
  case "$tool" in
    Read)  input="{\"session_id\":\"$sid\",\"cwd\":\"/home/user\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$arg\"}}" ;;
    *)     input="{\"session_id\":\"$sid\",\"cwd\":\"/home/user\",\"tool_name\":\"$tool\",\"tool_input\":{\"command\":\"$arg\"}}" ;;
  esac
  printf '%s' "$input" | \
    VADE_BRAKE_ENFORCE=block-on-FAIL \
    VADE_BRAKE_RACE_GRACE_SECONDS=0 \
    VADE_CLOUD_STATE_DIR="$state_dir" \
    VADE_COO_MEMORY_DIR="$memory_dir" \
    HOME="$home_dir" \
    bash "$GUARD" 2>/dev/null
}

state_dir="$TEST_ROOT/state"
home_dir="$TEST_ROOT/home"
memory_dir="$TEST_ROOT/coo-memory"
_stage_failing_boot "$state_dir" "$home_dir" "$memory_dir"

# ─── Test 1: representative Bash call denied ────────────────────────
echo "Test 1 — Bash call denied under block-on-FAIL when boot is FAIL"
out_bash="$(_invoke_brake t1 Bash "$state_dir" "$home_dir" "$memory_dir" "ls -la")"
if printf '%s' "$out_bash" | grep -q '"permissionDecision":[[:space:]]*"deny"'; then
  _pass "Bash call refused: permissionDecision=deny emitted"
else
  _fail "Bash call NOT refused (got: $out_bash)"
fi
if printf '%s' "$out_bash" | grep -q '"permissionDecisionReason"'; then
  _pass "deny carries permissionDecisionReason"
else
  _fail "deny output missing permissionDecisionReason"
fi

# ─── Test 2: whitelisted Read silently allowed ──────────────────────
# Whitelist is the operator's escape hatch — Read/Grep stay open in FAIL
# so the operator can diagnose. This asserts the whitelist contract at
# the same surface as Test 1, completing the round-trip story.
echo "Test 2 — Read whitelisted under block-on-FAIL"
out_read="$(_invoke_brake t1 Read "$state_dir" "$home_dir" "$memory_dir" "/etc/hostname")"
if [ -z "$out_read" ]; then
  _pass "Read silent-allow (no deny output)"
else
  _fail "Read produced unexpected output: $out_read"
fi

# ─── Summary ────────────────────────────────────────────────────────
echo ""
echo "boot-brake roundtrip test: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
exit 0
