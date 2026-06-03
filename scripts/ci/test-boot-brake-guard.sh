#!/usr/bin/env bash
# CI tests for boot-brake-guard.py + boot-brake-clear.sh.
#
# Covers v2 §7 tests 1, 2, 3, 6, 7, 9 from the boot-brake architecture
# (coo-memory#1082); the rest are Phase 1+.
#
#   1. Per-producer fault injection — for each manifest entry, run
#      the guard with that deliverable missing; assert state=FAIL with
#      the deliverable in failures.
#   2. PreToolUse refusal smoke — in block-on-FAIL mode with FAIL state,
#      attempt Bash → assert hookSpecificOutput.permissionDecision=deny
#      with the failing deliverable in the reason.
#   3. Whitelist allows diagnostics — same state, attempt Read and Grep
#      → assert exit 0 with no deny output.
#   6. Sub-agent isolation — verify Task tool stays denied in FAIL.
#   7. Parallel-session isolation — two sessions sharing a state-dir
#      get distinct per-session sentinels and don't cross-pollute.
#   9. Unparseable sentinel — corrupt sentinel re-triggers validation
#      and writes a fault diagnostic; does NOT lock the agent out.
#
# Exit 0 if all assertions pass, non-zero on first failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/hooks/boot-brake-guard.sh"
CLEAR="$REPO_ROOT/scripts/boot/boot-brake-clear.sh"

# Test workspace — distinct per run to avoid cross-test contamination.
TEST_ROOT="${TEST_ROOT:-/tmp/boot-brake-test-$$}"
mkdir -p "$TEST_ROOT"

# Manifest lives under VADE_COO_MEMORY_DIR. For CI, we point to the
# real coo-memory checkout's operations/ directory. The repo layout
# (coo-harness ./ + coo-memory ./../coo-memory) is the cloud convention.
COO_MEMORY_DIR="${VADE_COO_MEMORY_DIR:-$(cd "$REPO_ROOT/../coo-memory" && pwd)}"

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

_setup_session_dirs() {
  local n="$1"
  local state_dir="$TEST_ROOT/state-$n"
  local home_dir="$TEST_ROOT/home-$n"
  rm -rf "$state_dir" "$home_dir"
  mkdir -p "$state_dir" "$home_dir/.vade" "$home_dir/.claude"
  echo "$state_dir|$home_dir"
}

_make_all_deliverables_present() {
  local state_dir="$1" home_dir="$2"
  printf '{"summary":{"ok":true}}' > "$state_dir/integrity-check.json"
  touch "$home_dir/.vade/.coo-bootstrap-done"
  printf '{}' > "$home_dir/.claude/settings.json"
}

_invoke_guard() {
  local sid="$1" tool="$2" mode="$3" state_dir="$4" home_dir="$5"
  local arg6="${6:-}"
  local input
  case "$tool" in
    Read)  input="{\"session_id\":\"$sid\",\"cwd\":\"/home/user\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$arg6\"}}" ;;
    Grep)  input="{\"session_id\":\"$sid\",\"cwd\":\"/home/user\",\"tool_name\":\"Grep\",\"tool_input\":{\"pattern\":\"$arg6\"}}" ;;
    *)     input="{\"session_id\":\"$sid\",\"cwd\":\"/home/user\",\"tool_name\":\"$tool\",\"tool_input\":{\"command\":\"$arg6\"}}" ;;
  esac
  printf '%s' "$input" | \
    VADE_BRAKE_ENFORCE="$mode" \
    VADE_CLOUD_STATE_DIR="$state_dir" \
    VADE_COO_MEMORY_DIR="$COO_MEMORY_DIR" \
    HOME="$home_dir" \
    bash "$GUARD" 2>/dev/null
}

# ─── Test 1: per-producer fault injection ────────────────────────
echo "Test 1 — per-producer fault injection"
for fault in integrity_check_json coo_bootstrap_marker user_settings_json; do
  set -- $(echo "$(_setup_session_dirs "t1-$fault")" | tr '|' ' ')
  state_dir="$1"; home_dir="$2"
  _make_all_deliverables_present "$state_dir" "$home_dir"
  # Remove the targeted deliverable
  case "$fault" in
    integrity_check_json)  rm -f "$state_dir/integrity-check.json" ;;
    coo_bootstrap_marker)  rm -f "$home_dir/.vade/.coo-bootstrap-done" ;;
    user_settings_json)    rm -f "$home_dir/.claude/settings.json" ;;
  esac
  _invoke_guard "t1-$fault" Bash block-on-FAIL "$state_dir" "$home_dir" "ls" > /dev/null
  if grep -q "\"deliverable\":\"$fault\"" "$state_dir/boot-brake.t1-$fault.json" 2>/dev/null; then
    _pass "fault=$fault → sentinel records $fault as failed"
  else
    _fail "fault=$fault → sentinel did NOT record $fault as failed"
  fi
done

# ─── Test 2: PreToolUse refusal smoke ────────────────────────────
echo "Test 2 — PreToolUse refusal smoke"
set -- $(echo "$(_setup_session_dirs "t2")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
# All deliverables MISSING — first PreToolUse should write FAIL + deny
out="$(_invoke_guard t2 Bash block-on-FAIL "$state_dir" "$home_dir" "ls")"
if printf '%s' "$out" | grep -q '"permissionDecision":[[:space:]]*"deny"'; then
  _pass "block-on-FAIL deny emitted"
else
  _fail "block-on-FAIL did NOT emit permissionDecision=deny  (got: $out)"
fi
if printf '%s' "$out" | grep -q "integrity_check_json"; then
  _pass "deny reason names integrity_check_json"
else
  _fail "deny reason did NOT name integrity_check_json"
fi

# ─── Test 3: whitelist allows diagnostics ────────────────────────
echo "Test 3 — Read/Grep whitelisted in FAIL"
out_read="$(_invoke_guard t2 Read block-on-FAIL "$state_dir" "$home_dir" "/etc/hostname")"
out_grep="$(_invoke_guard t2 Grep block-on-FAIL "$state_dir" "$home_dir" "pattern")"
if [ -z "$out_read" ]; then
  _pass "Read silent-allow (no deny output)"
else
  _fail "Read produced unexpected output: $out_read"
fi
if [ -z "$out_grep" ]; then
  _pass "Grep silent-allow (no deny output)"
else
  _fail "Grep produced unexpected output: $out_grep"
fi

# ─── Test 6: sub-agent (Task) stays denied in FAIL ───────────────
echo "Test 6 — Task tool stays denied in FAIL"
out_task="$(_invoke_guard t2 Task block-on-FAIL "$state_dir" "$home_dir" "")"
if printf '%s' "$out_task" | grep -q '"permissionDecision":[[:space:]]*"deny"'; then
  _pass "Task denied in FAIL state"
else
  _fail "Task NOT denied in FAIL state (got: $out_task)"
fi
# Override sentinel scoped to parent session should NOT propagate to a
# different session_id. Write a valid override for the parent, then
# attempt with a sub-agent's session_id (different).
mkdir -p "$home_dir/.vade"
parent_sid=t2
child_sid=t2-child
# Compose a valid override for parent_sid via the same HMAC derivation
granted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
expires_at="$(date -u -d '+30 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v +30M +%Y-%m-%dT%H:%M:%SZ)"
hmac_v="$(GRANTED_AT="$granted_at" SID="$parent_sid" REASON="test override for ci" python3 -c '
import hashlib, hmac, os, sys
src = os.environ.get("OP_SERVICE_ACCOUNT_TOKEN") or os.environ.get("MEM0_API_KEY") or os.environ.get("GITHUB_MCP_PAT") or "vade-boot-brake-default-no-secrets"
key = hashlib.sha256(src.encode()).digest()
ga = os.environ["GRANTED_AT"]
sid = os.environ["SID"]
rs = os.environ["REASON"]
msg = (ga + "|" + sid + "|" + rs).encode()
sys.stdout.write(hmac.new(key, msg, hashlib.sha256).hexdigest())
')"
cat > "$home_dir/.vade/boot-brake-override.${parent_sid}.json" <<EOF
{"granted_at":"$granted_at","expires_at":"$expires_at","session_id":"$parent_sid","reason":"test override for ci","hmac":"$hmac_v"}
EOF
chmod 600 "$home_dir/.vade/boot-brake-override.${parent_sid}.json"
# Parent's override should allow Bash for parent_sid
out_parent="$(_invoke_guard $parent_sid Bash block-on-FAIL "$state_dir" "$home_dir" "ls")"
if [ -z "$out_parent" ]; then
  _pass "Parent override allows parent's Bash"
else
  _fail "Parent override did not allow parent's Bash (got: $out_parent)"
fi
# Child session (different sid) should still be denied — override does not propagate
out_child="$(_invoke_guard $child_sid Bash block-on-FAIL "$state_dir" "$home_dir" "ls")"
if printf '%s' "$out_child" | grep -q '"permissionDecision":[[:space:]]*"deny"'; then
  _pass "Sub-agent (different session_id) still denied — override does not propagate"
else
  _fail "Sub-agent override leaked from parent (got: $out_child)"
fi

# ─── Test 7: parallel-session isolation ──────────────────────────
echo "Test 7 — parallel-session sentinel isolation"
set -- $(echo "$(_setup_session_dirs "t7")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
_make_all_deliverables_present "$state_dir" "$home_dir"
# Session A — all good → OK
_invoke_guard t7-A Bash block-on-FAIL "$state_dir" "$home_dir" "ls" > /dev/null
# Session B — corrupt its environment (remove deliverable AFTER A wrote sentinel)
rm -f "$state_dir/integrity-check.json"
_invoke_guard t7-B Bash block-on-FAIL "$state_dir" "$home_dir" "ls" > /dev/null
# Assert A's sentinel still records OK, B's records FAIL
state_a="$(python3 -c "import json; print(json.load(open('$state_dir/boot-brake.t7-A.json'))['state'])")"
state_b="$(python3 -c "import json; print(json.load(open('$state_dir/boot-brake.t7-B.json'))['state'])")"
if [ "$state_a" = "OK" ]; then
  _pass "Session A sentinel unchanged at OK after session B's failure"
else
  _fail "Session A sentinel cross-polluted (state=$state_a)"
fi
if [ "$state_b" = "FAIL" ]; then
  _pass "Session B sentinel records FAIL independently"
else
  _fail "Session B sentinel did not record FAIL (state=$state_b)"
fi

# ─── Test 9: unparseable sentinel ────────────────────────────────
echo "Test 9 — unparseable sentinel re-validates without locking out"
set -- $(echo "$(_setup_session_dirs "t9")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
_make_all_deliverables_present "$state_dir" "$home_dir"
# Write a truncated/garbage sentinel
printf '{"state":"OK"' > "$state_dir/boot-brake.t9.json"
# Invoke — should NOT crash, should re-validate, should write a valid sentinel
out="$(_invoke_guard t9 Bash block-on-FAIL "$state_dir" "$home_dir" "ls")"
if [ -z "$out" ]; then
  # Allowed (because deliverables are all present now after re-validation)
  if python3 -c "import json; json.load(open('$state_dir/boot-brake.t9.json'))" 2>/dev/null; then
    _pass "Unparseable sentinel re-validated, new sentinel is well-formed"
  else
    _fail "Sentinel still unparseable after guard ran"
  fi
else
  _fail "Guard emitted unexpected output on unparseable sentinel: $out"
fi
# Fault log should exist
if [ -d "$state_dir/boot-brake-faults" ] && [ -n "$(ls -A "$state_dir/boot-brake-faults" 2>/dev/null)" ]; then
  _pass "Unparseable sentinel wrote a fault diagnostic"
else
  _fail "No fault diagnostic written for unparseable sentinel"
fi

# ─── Summary ────────────────────────────────────────────────────
echo
echo "===================================="
echo "boot-brake CI tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
echo "All tests passed."
exit 0
