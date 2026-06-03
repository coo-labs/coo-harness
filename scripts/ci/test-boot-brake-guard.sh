#!/usr/bin/env bash
# CI tests for boot-brake-guard.py + boot-brake-clear.sh.
#
# Covers v2 §7 tests 1, 2, 3, 6, 7, 9 (Phase 0 minimum), plus four
# regression tests for the post-review patches:
#
#   1.  Per-producer fault injection — each manifest entry, missing.
#   2.  PreToolUse refusal smoke — block-on-FAIL + FAIL → deny.
#   3.  Whitelist allows diagnostics — Read + Grep in FAIL state.
#   6.  Sub-agent isolation — Task denied; override does not propagate
#       to different session_id.
#   7.  Parallel-session isolation — sentinels keyed per-session AND
#       cache-invalidation: a cached OK does NOT survive deletion of
#       a previously-OK deliverable (Sys-Eng C1 regression test).
#   9.  Unparseable sentinel re-validates + writes fault diagnostic.
#   11. (new) Manifest unreadable (pyyaml-fault simulated) → self-fault
#       sentinel + cause=validator_self_fault event (Sys-Eng C2).
#   12. (new) Race gate engaged — first PreToolUse while producers are
#       still running stays PENDING; doesn't emit phantom FAIL
#       (Sys-Eng C3).
#   13. (new) identity_consumed predicate-unmatched emits
#       cause=identity_predicate_unmatched event (SRE F5).
#   14. (new) Override-sentinel tamper resistance — flipping expires_at
#       in a captured override invalidates the HMAC (Security SC1+SC3).
#
# Most tests run with VADE_BRAKE_RACE_GRACE_SECONDS=0 to bypass the
# wall-clock race window (tests don't write boot.log producer
# end-markers; the race-window test exercises the gate explicitly).
#
# Exit 0 if all assertions pass, non-zero on first failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/hooks/boot-brake-guard.sh"
CLEAR="$REPO_ROOT/scripts/boot/boot-brake-clear.sh"

TEST_ROOT="${TEST_ROOT:-/tmp/boot-brake-test-$$}"
mkdir -p "$TEST_ROOT"

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

# Default invocation: race-gate disabled, fixture manifest. Override
# VADE_BRAKE_RACE_GRACE_SECONDS or VADE_COO_MEMORY_DIR per-call.
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
    VADE_BRAKE_RACE_GRACE_SECONDS="${VADE_BRAKE_RACE_GRACE_SECONDS:-0}" \
    VADE_CLOUD_STATE_DIR="$state_dir" \
    VADE_COO_MEMORY_DIR="${VADE_COO_MEMORY_DIR_OVERRIDE:-$COO_MEMORY_DIR}" \
    HOME="$home_dir" \
    bash "$GUARD" 2>/dev/null
}

# Stage a fixture manifest with a custom path so we can test
# unreadable-manifest semantics independently. Returns the manifest dir.
_stage_fixture_manifest() {
  local target_dir="$1"
  mkdir -p "$target_dir/operations"
  cp "$SCRIPT_DIR/fixtures/boot-deliverables.yml" "$target_dir/operations/boot-deliverables.yml"
}

# ─── Test 1: per-producer fault injection ────────────────────────
echo "Test 1 — per-producer fault injection"
for fault in integrity_check_json bootstrap_marker user_settings_json; do
  set -- $(echo "$(_setup_session_dirs "t1-$fault")" | tr '|' ' ')
  state_dir="$1"; home_dir="$2"
  _make_all_deliverables_present "$state_dir" "$home_dir"
  case "$fault" in
    integrity_check_json)  rm -f "$state_dir/integrity-check.json" ;;
    bootstrap_marker)      rm -f "$home_dir/.vade/.coo-bootstrap-done" ;;
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

# ─── Test 6: sub-agent (Task) stays denied + override scoping ────
echo "Test 6 — Task denied in FAIL; override does not propagate"
out_task="$(_invoke_guard t2 Task block-on-FAIL "$state_dir" "$home_dir" "")"
if printf '%s' "$out_task" | grep -q '"permissionDecision":[[:space:]]*"deny"'; then
  _pass "Task denied in FAIL state"
else
  _fail "Task NOT denied in FAIL state (got: $out_task)"
fi

# Override sentinel scoped to parent session. Compute HMAC using the
# same length-prefixed payload as guard.py and unbrake.sh — security
# review SC1 (expires_at in MAC scope) + SC3 (length-prefixing).
parent_sid=t2
child_sid=t2-child
granted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
expires_at="$(date -u -d '+30 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v +30M +%Y-%m-%dT%H:%M:%SZ)"
hmac_v="$(GRANTED_AT="$granted_at" EXPIRES_AT="$expires_at" SID="$parent_sid" REASON="test override for ci" python3 -c '
import hashlib, hmac, os, sys
src = (os.environ.get("OP_SERVICE_ACCOUNT_TOKEN")
       or os.environ.get("MEM0_API_KEY")
       or os.environ.get("GITHUB_MCP_PAT")
       or "vade-boot-brake-default-no-secrets")
key = hashlib.sha256(src.encode()).digest()
parts = (os.environ["GRANTED_AT"], os.environ["EXPIRES_AT"], os.environ["SID"], os.environ["REASON"])
msg = "|".join(str(len(p)) + ":" + p for p in parts).encode()
sys.stdout.write(hmac.new(key, msg, hashlib.sha256).hexdigest())
')"
cat > "$home_dir/.vade/boot-brake-override.${parent_sid}.json" <<EOF
{"granted_at":"$granted_at","expires_at":"$expires_at","session_id":"$parent_sid","reason":"test override for ci","hmac":"$hmac_v"}
EOF
chmod 600 "$home_dir/.vade/boot-brake-override.${parent_sid}.json"
out_parent="$(_invoke_guard $parent_sid Bash block-on-FAIL "$state_dir" "$home_dir" "ls")"
if [ -z "$out_parent" ]; then
  _pass "Parent override allows parent's Bash"
else
  _fail "Parent override did not allow parent's Bash (got: $out_parent)"
fi
out_child="$(_invoke_guard $child_sid Bash block-on-FAIL "$state_dir" "$home_dir" "ls")"
if printf '%s' "$out_child" | grep -q '"permissionDecision":[[:space:]]*"deny"'; then
  _pass "Sub-agent (different session_id) still denied — override does not propagate"
else
  _fail "Sub-agent override leaked from parent (got: $out_child)"
fi

# ─── Test 7: parallel-session isolation + cache invalidation ─────
echo "Test 7 — parallel-session isolation + cache invalidation"
set -- $(echo "$(_setup_session_dirs "t7")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
_make_all_deliverables_present "$state_dir" "$home_dir"
# Session A first fire → all-OK
_invoke_guard t7-A Bash block-on-FAIL "$state_dir" "$home_dir" "ls" > /dev/null
sleep 1.1  # past 1s backpressure cap so the next fire re-checks hashes
# Remove a deliverable, re-fire A → cached OK must NOT survive
rm -f "$state_dir/integrity-check.json"
_invoke_guard t7-A Bash block-on-FAIL "$state_dir" "$home_dir" "ls" > /dev/null
state_a_after="$(python3 -c "import json; print(json.load(open('$state_dir/boot-brake.t7-A.json'))['state'])")"
if [ "$state_a_after" = "FAIL" ]; then
  _pass "Cached-OK invalidated when previously-hashed deliverable deleted (Sys-Eng C1)"
else
  _fail "Cached-OK survived deletion (state=$state_a_after; Sys-Eng C1 regression)"
fi
# Now session B sees its own sentinel independently — restore deliverable
_make_all_deliverables_present "$state_dir" "$home_dir"
_invoke_guard t7-B Bash block-on-FAIL "$state_dir" "$home_dir" "ls" > /dev/null
state_b="$(python3 -c "import json; print(json.load(open('$state_dir/boot-brake.t7-B.json'))['state'])")"
if [ "$state_b" = "OK" ]; then
  _pass "Session B's sentinel records OK independently of A's history"
else
  _fail "Session B sentinel cross-polluted with A's state (state_b=$state_b)"
fi

# ─── Test 9: unparseable sentinel ────────────────────────────────
echo "Test 9 — unparseable sentinel re-validates without locking out"
set -- $(echo "$(_setup_session_dirs "t9")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
_make_all_deliverables_present "$state_dir" "$home_dir"
printf '{"state":"OK"' > "$state_dir/boot-brake.t9.json"
out="$(_invoke_guard t9 Bash block-on-FAIL "$state_dir" "$home_dir" "ls")"
if [ -z "$out" ]; then
  if python3 -c "import json; json.load(open('$state_dir/boot-brake.t9.json'))" 2>/dev/null; then
    _pass "Unparseable sentinel re-validated, new sentinel is well-formed"
  else
    _fail "Sentinel still unparseable after guard ran"
  fi
else
  _fail "Guard emitted unexpected output on unparseable sentinel: $out"
fi
if [ -d "$state_dir/boot-brake-faults" ] && [ -n "$(ls -A "$state_dir/boot-brake-faults" 2>/dev/null)" ]; then
  _pass "Unparseable sentinel wrote a fault diagnostic"
else
  _fail "No fault diagnostic written for unparseable sentinel"
fi

# ─── Test 11 (NEW): manifest unreadable → validator self-fault ──
echo "Test 11 — manifest unreadable → validator self-fault (Sys-Eng C2)"
set -- $(echo "$(_setup_session_dirs "t11")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
_make_all_deliverables_present "$state_dir" "$home_dir"
# Point at a non-existent manifest dir
fake_manifest_dir="$TEST_ROOT/no-such-coo-memory"
VADE_COO_MEMORY_DIR_OVERRIDE="$fake_manifest_dir" \
  _invoke_guard t11 Bash block-on-FAIL "$state_dir" "$home_dir" "ls" > /dev/null
state_t11="$(python3 -c "import json; d=json.load(open('$state_dir/boot-brake.t11.json')); print(d.get('cause','?'), d.get('state','?'))")"
case "$state_t11" in
  "validator_self_fault FAIL")
    _pass "Manifest unreadable → state=FAIL with cause=validator_self_fault" ;;
  *)
    _fail "Manifest unreadable did not produce self-fault (got: $state_t11)" ;;
esac

# After self-fault, exercise the cached-revalidation path: re-fire
# while manifest still unreadable. The previously-OK cached sentinel
# from a prior test would NOT exist here (fresh state_dir), but the
# self-fault sentinel itself must re-validate (Sys-Eng C2 second leg).
sleep 1.1
VADE_COO_MEMORY_DIR_OVERRIDE="$fake_manifest_dir" \
  _invoke_guard t11 Bash block-on-FAIL "$state_dir" "$home_dir" "ls" > /dev/null
state_t11_second="$(python3 -c "import json; d=json.load(open('$state_dir/boot-brake.t11.json')); print(d.get('cause','?'))")"
if [ "$state_t11_second" = "validator_self_fault" ]; then
  _pass "Subsequent fire with unreadable manifest stays self-fault (not stuck-PENDING)"
else
  _fail "Subsequent fire did not preserve self-fault (got cause=$state_t11_second)"
fi

# ─── Test 12 (NEW): race gate engaged ────────────────────────────
echo "Test 12 — race gate engaged when producers haven't completed (Sys-Eng C3)"
set -- $(echo "$(_setup_session_dirs "t12")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
# Note: all deliverables PRESENT, but no boot.log → fall back to
# wall-clock grace. With grace_seconds=300 the race gate engages.
_make_all_deliverables_present "$state_dir" "$home_dir"
# Force a recent boot_started_at via a pre-staged sentinel
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$state_dir/boot-brake.t12.json" <<EOF
{"state":"PENDING","checked_at":"$now_iso","checked_at_epoch":0,"manifest_version":0,"failures":[],"boot_started_at":"$now_iso","content_hashes":{}}
EOF
# Invoke with grace=300 so the race window is active
out="$(printf '{"session_id":"t12","cwd":"/home/user","tool_name":"Bash","tool_input":{"command":"ls"}}' | \
  VADE_BRAKE_ENFORCE=block-on-FAIL \
  VADE_BRAKE_RACE_GRACE_SECONDS=300 \
  VADE_CLOUD_STATE_DIR="$state_dir" \
  VADE_COO_MEMORY_DIR="$COO_MEMORY_DIR" \
  HOME="$home_dir" \
  bash "$GUARD" 2>/dev/null)"
state_t12="$(python3 -c "import json; d=json.load(open('$state_dir/boot-brake.t12.json')); print(d['state'])")"
race_reason="$(python3 -c "import json; d=json.load(open('$state_dir/boot-brake.t12.json')); print((d.get('race_gate') or {}).get('reason','no'))")"
if [ "$state_t12" = "PENDING" ] && [ "$race_reason" = "wall-clock grace" ]; then
  _pass "Race gate engaged → state stays PENDING (no phantom FAIL)"
else
  _fail "Race gate did not engage (state=$state_t12, reason=$race_reason)"
fi
# PENDING + block-on-FAIL must allow (only block-strict denies PENDING)
if [ -z "$out" ]; then
  _pass "PENDING under block-on-FAIL allows tool call (block-strict denies)"
else
  _fail "PENDING under block-on-FAIL emitted output: $out"
fi

# ─── Test 13 (NEW): identity_consumed predicate-unmatched event ─
echo "Test 13 — identity_consumed predicate-unmatched emits diagnostic (SRE F5)"
set -- $(echo "$(_setup_session_dirs "t13")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
_make_all_deliverables_present "$state_dir" "$home_dir"
# No persisted-output files exist for session t13. The predicate glob
# expands to a path under home_dir that has nothing → predicate unmatched.
_invoke_guard t13 Bash block-on-FAIL "$state_dir" "$home_dir" "ls" > /dev/null
if grep -q '"cause":"identity_predicate_unmatched"' "$state_dir/brake-events.jsonl" 2>/dev/null; then
  _pass "predicate-unmatched event emitted in brake-events.jsonl"
else
  _fail "predicate-unmatched event NOT emitted (events.jsonl content: $(cat "$state_dir/brake-events.jsonl" 2>/dev/null | tail -3))"
fi

# ─── Test 14 (NEW): override tamper resistance ──────────────────
echo "Test 14 — tampering with override expires_at invalidates HMAC (Security SC1)"
set -- $(echo "$(_setup_session_dirs "t14")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
# Reuse the test-6 override-write logic with a 1-minute TTL
parent_sid=t14
granted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
expires_at="$(date -u -d '+1 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v +1M +%Y-%m-%dT%H:%M:%SZ)"
hmac_v="$(GRANTED_AT="$granted_at" EXPIRES_AT="$expires_at" SID="$parent_sid" REASON="testing tamper resistance" python3 -c '
import hashlib, hmac, os, sys
src = (os.environ.get("OP_SERVICE_ACCOUNT_TOKEN") or os.environ.get("MEM0_API_KEY") or os.environ.get("GITHUB_MCP_PAT") or "vade-boot-brake-default-no-secrets")
key = hashlib.sha256(src.encode()).digest()
parts = (os.environ["GRANTED_AT"], os.environ["EXPIRES_AT"], os.environ["SID"], os.environ["REASON"])
msg = "|".join(str(len(p)) + ":" + p for p in parts).encode()
sys.stdout.write(hmac.new(key, msg, hashlib.sha256).hexdigest())
')"
# Forge: change expires_at to far-future, keep HMAC computed with the
# original. The guard MUST reject because expires_at is in the MAC scope.
future_expires="2099-12-31T23:59:59Z"
cat > "$home_dir/.vade/boot-brake-override.${parent_sid}.json" <<EOF
{"granted_at":"$granted_at","expires_at":"$future_expires","session_id":"$parent_sid","reason":"testing tamper resistance","hmac":"$hmac_v"}
EOF
chmod 600 "$home_dir/.vade/boot-brake-override.${parent_sid}.json"
out_tamper="$(_invoke_guard $parent_sid Bash block-on-FAIL "$state_dir" "$home_dir" "ls")"
if printf '%s' "$out_tamper" | grep -q '"permissionDecision":[[:space:]]*"deny"'; then
  _pass "Tampered expires_at → HMAC mismatch → override rejected → deny"
else
  _fail "Tampered override was honored — HMAC scope does not protect expires_at"
fi
# Also: empty expires_at must be treated as expired
cat > "$home_dir/.vade/boot-brake-override.${parent_sid}.json" <<EOF
{"granted_at":"$granted_at","expires_at":"","session_id":"$parent_sid","reason":"testing tamper resistance","hmac":"$hmac_v"}
EOF
chmod 600 "$home_dir/.vade/boot-brake-override.${parent_sid}.json"
out_empty="$(_invoke_guard $parent_sid Bash block-on-FAIL "$state_dir" "$home_dir" "ls")"
if printf '%s' "$out_empty" | grep -q '"permissionDecision":[[:space:]]*"deny"'; then
  _pass "Empty expires_at → treated as expired → override rejected"
else
  _fail "Empty expires_at was treated as permanent — SC2 regression"
fi

# ─── Test 15 (NEW): producer-complete tolerates skip-paths ─────
echo "Test 15 — boot_producers_complete treats start+elapsed as done (soak-fix #A)"
set -- $(echo "$(_setup_session_dirs "t15")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
_make_all_deliverables_present "$state_dir" "$home_dir"
# Stage a boot.log with phase=start for each tracked producer and
# NO phase=end (simulating coo-bootstrap's marker-present-skip path).
# Backdate the start timestamps so elapsed > PRODUCER_DONE_THRESHOLD.
mkdir -p "$home_dir/.vade"
old_iso="$(date -u -d '-60 seconds' +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
  || date -u -v -60S +%Y-%m-%dT%H:%M:%S.000Z)"
cat > "$home_dir/.vade/boot.log" <<EOF
{"ts":"$old_iso","session":"t15","script":"session-start-sync","phase":"start"}
{"ts":"$old_iso","session":"t15","script":"coo-bootstrap","phase":"start"}
{"ts":"$old_iso","session":"t15","script":"coo-identity-digest","phase":"start"}
EOF
# Invoke with race-gate ENABLED (grace=300). With the fix, the start+elapsed
# path treats producers as done; race-gate clears; state transitions to OK.
out="$(printf '{"session_id":"t15","cwd":"/home/user","tool_name":"Bash","tool_input":{"command":"ls"}}' | \
  VADE_BRAKE_ENFORCE=block-on-FAIL \
  VADE_BRAKE_RACE_GRACE_SECONDS=300 \
  VADE_CLOUD_STATE_DIR="$state_dir" \
  VADE_COO_MEMORY_DIR="$COO_MEMORY_DIR" \
  HOME="$home_dir" \
  bash "$GUARD" 2>/dev/null)"
state_t15="$(python3 -c "import json; d=json.load(open('$state_dir/boot-brake.t15.json')); print(d['state'])")"
if [ "$state_t15" = "OK" ]; then
  _pass "Producers with start+elapsed > threshold treated as done; race-gate cleared"
else
  _fail "Race-gate stayed engaged despite producer-start being 60s old (state=$state_t15)"
fi

# Negative case: a producer that JUST started (no elapsed) keeps the race-gate engaged.
set -- $(echo "$(_setup_session_dirs "t15b")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
_make_all_deliverables_present "$state_dir" "$home_dir"
mkdir -p "$home_dir/.vade"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
cat > "$home_dir/.vade/boot.log" <<EOF
{"ts":"$now_iso","session":"t15b","script":"session-start-sync","phase":"start"}
EOF
printf '{"session_id":"t15b","cwd":"/home/user","tool_name":"Bash","tool_input":{"command":"ls"}}' | \
  VADE_BRAKE_ENFORCE=block-on-FAIL \
  VADE_BRAKE_RACE_GRACE_SECONDS=300 \
  VADE_CLOUD_STATE_DIR="$state_dir" \
  VADE_COO_MEMORY_DIR="$COO_MEMORY_DIR" \
  HOME="$home_dir" \
  bash "$GUARD" 2>/dev/null > /dev/null
state_t15b="$(python3 -c "import json; d=json.load(open('$state_dir/boot-brake.t15b.json')); print(d['state'])")"
missing_t15b="$(python3 -c "import json; d=json.load(open('$state_dir/boot-brake.t15b.json')); print(','.join((d.get('race_gate') or {}).get('missing_producers', [])))")"
if [ "$state_t15b" = "PENDING" ] && [[ "$missing_t15b" == *"coo-bootstrap"* ]]; then
  _pass "Producers with recent start still missing → race-gate stays engaged (negative case)"
else
  _fail "Negative race-gate check failed (state=$state_t15b, missing=$missing_t15b)"
fi

# ─── Test 16 (NEW): warn-mode event taxonomy split ──────────────
echo "Test 16 — warn-mode tags PENDING as race_gate_observed (not would_have_denied) (soak-fix #C)"
# Use t15b's PENDING sentinel from above; fire under VADE_BRAKE_ENFORCE=warn
set -- $(echo "$(_setup_session_dirs "t16")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
_make_all_deliverables_present "$state_dir" "$home_dir"
mkdir -p "$home_dir/.vade"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
cat > "$home_dir/.vade/boot.log" <<EOF
{"ts":"$now_iso","session":"t16","script":"session-start-sync","phase":"start"}
EOF
printf '{"session_id":"t16","cwd":"/home/user","tool_name":"Bash","tool_input":{"command":"ls"}}' | \
  VADE_BRAKE_ENFORCE=warn \
  VADE_BRAKE_RACE_GRACE_SECONDS=300 \
  VADE_CLOUD_STATE_DIR="$state_dir" \
  VADE_COO_MEMORY_DIR="$COO_MEMORY_DIR" \
  HOME="$home_dir" \
  bash "$GUARD" 2>/dev/null > /dev/null
if grep -q '"cause":"race_gate_observed"' "$state_dir/brake-events.jsonl"; then
  _pass "PENDING in warn mode → cause=race_gate_observed"
else
  _fail "PENDING in warn mode did not emit race_gate_observed (events: $(cat "$state_dir/brake-events.jsonl"))"
fi
if grep -q '"cause":"would_have_denied"' "$state_dir/brake-events.jsonl"; then
  _fail "PENDING in warn mode incorrectly emitted would_have_denied (soak-signal pollution)"
else
  _pass "PENDING in warn mode does NOT emit would_have_denied (clean soak signal)"
fi
# FAIL in warn mode still emits would_have_denied
rm -f "$state_dir/integrity-check.json"
sleep 1.1  # past backpressure cap
printf '{"session_id":"t16","cwd":"/home/user","tool_name":"Bash","tool_input":{"command":"ls"}}' | \
  VADE_BRAKE_ENFORCE=warn \
  VADE_BRAKE_RACE_GRACE_SECONDS=0 \
  VADE_CLOUD_STATE_DIR="$state_dir" \
  VADE_COO_MEMORY_DIR="$COO_MEMORY_DIR" \
  HOME="$home_dir" \
  bash "$GUARD" 2>/dev/null > /dev/null
if grep -q '"cause":"would_have_denied"' "$state_dir/brake-events.jsonl"; then
  _pass "FAIL in warn mode → cause=would_have_denied (real denial signal preserved)"
else
  _fail "FAIL in warn mode did not emit would_have_denied (events: $(cat "$state_dir/brake-events.jsonl"))"
fi

# ─── Test 17 (NEW): clear-hook is idempotent on resume/compaction ─
echo "Test 17 — boot-brake-clear is idempotent (re-run after sentinel exists; soak-fix #B)"
set -- $(echo "$(_setup_session_dirs "t17")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
# First run: clear-hook installs initial PENDING sentinel.
VADE_CLOUD_STATE_DIR="$state_dir" HOME="$home_dir" \
  CLAUDE_CODE_SESSION_ID="t17" \
  bash "$CLEAR" 2>/dev/null </dev/null
if [ -f "$state_dir/boot-brake.t17.json" ]; then
  _pass "Clear-hook installs initial sentinel"
else
  _fail "Clear-hook did not install initial sentinel"
fi
# Second run: should be safe (same sentinel rewritten with current ts)
VADE_CLOUD_STATE_DIR="$state_dir" HOME="$home_dir" \
  CLAUDE_CODE_SESSION_ID="t17" \
  bash "$CLEAR" 2>/dev/null </dev/null
state_t17="$(python3 -c "import json; d=json.load(open('$state_dir/boot-brake.t17.json')); print(d['state'])")"
if [ "$state_t17" = "PENDING" ]; then
  _pass "Clear-hook re-run on existing sentinel is idempotent (PENDING preserved)"
else
  _fail "Clear-hook re-run corrupted sentinel (state=$state_t17)"
fi

# ─── Test 18 (NEW): expanded whitelist for non-substrate tools ──
echo "Test 18 — AskUserQuestion / TodoWrite / Glob whitelisted in FAIL"
set -- $(echo "$(_setup_session_dirs "t18")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
# Leave deliverables missing → state will be FAIL
for tool in AskUserQuestion TodoWrite Glob; do
  input="{\"session_id\":\"t18\",\"cwd\":\"/home/user\",\"tool_name\":\"$tool\",\"tool_input\":{}}"
  out="$(printf '%s' "$input" | \
    VADE_BRAKE_ENFORCE=block-on-FAIL \
    VADE_BRAKE_RACE_GRACE_SECONDS=0 \
    VADE_CLOUD_STATE_DIR="$state_dir" \
    VADE_COO_MEMORY_DIR="$COO_MEMORY_DIR" \
    HOME="$home_dir" \
    bash "$GUARD" 2>/dev/null)"
  if [ -z "$out" ]; then
    _pass "$tool silent-allow in FAIL (substrate-non-affecting)"
  else
    _fail "$tool produced unexpected output: $out"
  fi
done
# Confirm a substrate-affecting tool is still denied for contrast
input='{"session_id":"t18","cwd":"/home/user","tool_name":"Write","tool_input":{}}'
out="$(printf '%s' "$input" | \
  VADE_BRAKE_ENFORCE=block-on-FAIL \
  VADE_BRAKE_RACE_GRACE_SECONDS=0 \
  VADE_CLOUD_STATE_DIR="$state_dir" \
  VADE_COO_MEMORY_DIR="$COO_MEMORY_DIR" \
  HOME="$home_dir" \
  bash "$GUARD" 2>/dev/null)"
if printf '%s' "$out" | grep -q '"permissionDecision":[[:space:]]*"deny"'; then
  _pass "Write still denied in FAIL (whitelist hasn't widened to writes)"
else
  _fail "Write was not denied — whitelist may have over-widened"
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
