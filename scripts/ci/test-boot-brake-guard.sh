#!/usr/bin/env bash
# CI tests for boot-brake-guard.py + boot-brake-clear.sh.
#
# Covers v2 §7 tests 1, 2, 3, 5, 6, 7, 8, 9, 10 (Phase 0 minimum + the
# Phase 1 deferred trio landed for coo-memory#1174 TST1), plus the
# post-review regression patches:
#
#   1.  Per-producer fault injection — each manifest entry, missing.
#   2.  PreToolUse refusal smoke — block-on-FAIL + FAIL → deny.
#   3.  Whitelist allows diagnostics — Read + Grep in FAIL state.
#   5.  (Phase 1) Manifest static cross-check — each entry's path
#       basename appears in its producer source; read_observed
#       entries' check_arg regex matches the producer string.
#   6.  Sub-agent isolation — Task denied; override does not propagate
#       to different session_id.
#   7.  Parallel-session isolation — sentinels keyed per-session AND
#       cache-invalidation: a cached OK does NOT survive deletion of
#       a previously-OK deliverable (Sys-Eng C1 regression test).
#   8.  (Phase 1) Prompt-injection sanitization — a malicious manifest
#       field cannot reach the agent's deny-reason context with shell
#       metachars or instruction-injection text intact.
#   9.  Unparseable sentinel re-validates + writes fault diagnostic.
#   10. (Phase 1) Legacy-format collision — brake's deny output is
#       canonical modern PreToolUse shape with no legacy keys; the
#       full Claude-Code chain-merge empirical check is opt-in via
#       VADE_TEST_LEGACY_COLLISION=1 + CLAUDE_BIN.
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
  local state_dir="$1" home_dir="$2" sid="${3:-}"
  printf '{"summary":{"ok":true}}' > "$state_dir/integrity-check.json"
  touch "$home_dir/.vade/.coo-bootstrap-done"
  printf '{}' > "$home_dir/.claude/settings.json"
  # When a session id is supplied, also satisfy the Phase 1 always-on
  # identity-stack read_observed entries (coo-memory#1169) by seeding the
  # per-session Read log with the four identity files. Without this,
  # "all deliverables present" would still FAIL the read-gated entries
  # and any OK-expecting assertion would break.
  if [ -n "$sid" ]; then
    mkdir -p "$home_dir/.vade"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local f
    for f in charter governance preferences episodic_memory; do
      printf '%s\t%s/identity/%s.md\n' "$ts" "$COO_MEMORY_DIR" "$f" \
        >> "$home_dir/.vade/session-reads.$sid.log"
    done
  fi
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
_make_all_deliverables_present "$state_dir" "$home_dir" "t7-A"
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
_make_all_deliverables_present "$state_dir" "$home_dir" "t7-B"
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
_make_all_deliverables_present "$state_dir" "$home_dir" "t9"
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
_make_all_deliverables_present "$state_dir" "$home_dir" "t15"
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

# ─── Test 19 (NEW): identity-stack always-on read gate (coo-memory#1169) ─
echo "Test 19 — identity-stack read_observed entries gate until Read (coo-memory#1169)"
set -- $(echo "$(_setup_session_dirs "t19")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
# File deliverables present, but NO identity reads yet → the 4 always-on
# *_consumed entries must FAIL.
_make_all_deliverables_present "$state_dir" "$home_dir"
_invoke_guard t19 Bash block-on-FAIL "$state_dir" "$home_dir" "ls" > /dev/null
unread_all=1
for d in charter_consumed governance_consumed preferences_consumed episodic_memory_consumed; do
  grep -q "\"deliverable\":\"$d\"" "$state_dir/boot-brake.t19.json" 2>/dev/null || unread_all=0
done
if [ "$unread_all" = "1" ]; then
  _pass "Identity stack unread → all 4 *_consumed entries recorded as failed"
else
  _fail "Not all 4 *_consumed entries failed (sentinel: $(cat "$state_dir/boot-brake.t19.json" 2>/dev/null))"
fi
# Deny reason collapses the 4 into a single aggregate directive (ergonomics)
out19="$(_invoke_guard t19 Bash block-on-FAIL "$state_dir" "$home_dir" "ls")"
if printf '%s' "$out19" | grep -q "identity stack not consumed"; then
  _pass "Deny reason aggregates *_consumed entries into one directive"
else
  _fail "Deny reason did not aggregate *_consumed entries (got: $out19)"
fi
# Read all 4 identity files → state transitions to OK, Bash allowed.
ts19="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for f in charter governance preferences episodic_memory; do
  printf '%s\t%s/identity/%s.md\n' "$ts19" "$COO_MEMORY_DIR" "$f" \
    >> "$home_dir/.vade/session-reads.t19.log"
done
sleep 1.1  # past 1s backpressure cap so the next fire re-validates
out19b="$(_invoke_guard t19 Bash block-on-FAIL "$state_dir" "$home_dir" "ls")"
state_t19="$(python3 -c "import json; print(json.load(open('$state_dir/boot-brake.t19.json'))['state'])")"
if [ "$state_t19" = "OK" ] && [ -z "$out19b" ]; then
  _pass "All 4 identity files Read → state=OK, Bash allowed"
else
  _fail "Identity stack Read but not OK (state=$state_t19, out=$out19b)"
fi
# Partial read: only 3 of 4 → FAIL naming the unread entry (acceptance).
set -- $(echo "$(_setup_session_dirs "t19c")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
_make_all_deliverables_present "$state_dir" "$home_dir"
ts19c="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for f in charter governance preferences; do
  printf '%s\t%s/identity/%s.md\n' "$ts19c" "$COO_MEMORY_DIR" "$f" \
    >> "$home_dir/.vade/session-reads.t19c.log"
done
_invoke_guard t19c Bash block-on-FAIL "$state_dir" "$home_dir" "ls" > /dev/null
state_t19c="$(python3 -c "import json; print(json.load(open('$state_dir/boot-brake.t19c.json'))['state'])")"
if [ "$state_t19c" = "FAIL" ] && grep -q '"deliverable":"episodic_memory_consumed"' "$state_dir/boot-brake.t19c.json"; then
  _pass "Read 3 of 4 → FAIL naming the unread episodic_memory_consumed"
else
  _fail "Partial read did not FAIL on the unread entry (state=$state_t19c)"
fi

# ─── Test 20 (NEW): every event carries schema version v (#1168 O1) ─
echo "Test 20 — every brake event carries schema version v (coo-memory#1168 O1)"
set -- $(echo "$(_setup_session_dirs "t20")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
# Warn-mode FAIL fire → would_have_denied (+ predicate_unmatched).
_invoke_guard t20 Bash warn "$state_dir" "$home_dir" "ls" > /dev/null
# Satisfy everything + reads, revalidate → FAIL->OK (all_satisfied transition).
_make_all_deliverables_present "$state_dir" "$home_dir" "t20"
sleep 1.1
_invoke_guard t20 Bash block-on-FAIL "$state_dir" "$home_dir" "ls" > /dev/null
total_ev="$(wc -l < "$state_dir/brake-events.jsonl")"
with_v="$(jq -c 'select(.v==1)' "$state_dir/brake-events.jsonl" 2>/dev/null | wc -l)"
if [ "$total_ev" -gt 0 ] && [ "$total_ev" = "$with_v" ]; then
  _pass "all $total_ev events carry v==1"
else
  _fail "not all events carry v==1 ($with_v/$total_ev): $(cat "$state_dir/brake-events.jsonl")"
fi

# ─── Test 21 (NEW): sentinel records cause on OK and FAIL (#1168 O4) ─
echo "Test 21 — sentinel records cause on OK and FAIL (coo-memory#1168 O4)"
set -- $(echo "$(_setup_session_dirs "t21")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
_invoke_guard t21 Bash block-on-FAIL "$state_dir" "$home_dir" "ls" > /dev/null
cause_fail="$(jq -r '.cause' "$state_dir/boot-brake.t21.json" 2>/dev/null)"
_make_all_deliverables_present "$state_dir" "$home_dir" "t21"
sleep 1.1
_invoke_guard t21 Bash block-on-FAIL "$state_dir" "$home_dir" "ls" > /dev/null
cause_ok="$(jq -r '.cause' "$state_dir/boot-brake.t21.json" 2>/dev/null)"
if [ "$cause_fail" = "deliverable_missing" ] && [ "$cause_ok" = "all_satisfied" ]; then
  _pass "sentinel cause: FAIL->deliverable_missing, OK->all_satisfied"
else
  _fail "sentinel cause wrong (fail=$cause_fail, ok=$cause_ok)"
fi

# ─── Test 22 (NEW): invalid override logs override_invalidated (#1168 O10) ─
echo "Test 22 — invalid override logs cause=override_invalidated (coo-memory#1168 O10)"
set -- $(echo "$(_setup_session_dirs "t22")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
# Far-future expiry but bogus HMAC → check_override returns hmac_mismatch.
cat > "$home_dir/.vade/boot-brake-override.t22.json" <<EOF
{"granted_at":"2026-01-01T00:00:00Z","expires_at":"2099-12-31T23:59:59Z","session_id":"t22","reason":"bogus","hmac":"deadbeef"}
EOF
chmod 600 "$home_dir/.vade/boot-brake-override.t22.json"
_invoke_guard t22 Bash block-on-FAIL "$state_dir" "$home_dir" "ls" > /dev/null
if grep -q '"cause":"override_invalidated"' "$state_dir/brake-events.jsonl" 2>/dev/null \
   && grep -q '"failure_kind":"hmac_mismatch"' "$state_dir/brake-events.jsonl" 2>/dev/null; then
  _pass "invalid override (bad HMAC) → cause=override_invalidated, failure_kind=hmac_mismatch"
else
  _fail "override_invalidated not logged: $(cat "$state_dir/brake-events.jsonl" 2>/dev/null)"
fi

# ─── Test 23 (NEW): warn-mode mirrors block-mode for whitelisted tools ─
echo "Test 23 — warn-mode taxonomy mirrors block-mode (coo-memory#1168 soak-fix)"
set -- $(echo "$(_setup_session_dirs "t23")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
# Deliverables missing → state will land FAIL. Read is whitelisted in
# block-on-FAIL, so warn-mode must classify it as whitelisted_in_fail,
# not would_have_denied. Same for Glob / AskUserQuestion / TodoWrite.
for tool in Read Grep Glob AskUserQuestion TodoWrite; do
  arg=""
  [ "$tool" = "Read" ] && arg="/etc/hostname"
  [ "$tool" = "Grep" ] && arg="pattern"
  _invoke_guard t23 "$tool" warn "$state_dir" "$home_dir" "$arg" > /dev/null
  sleep 1.1  # past backpressure cap so each call re-validates cleanly
done
# Bash is not whitelisted → must classify as would_have_denied.
_invoke_guard t23 Bash warn "$state_dir" "$home_dir" "ls" > /dev/null
wic="$(grep -c '"cause":"whitelisted_in_fail"' "$state_dir/brake-events.jsonl" 2>/dev/null || echo 0)"
wdc="$(grep -c '"cause":"would_have_denied"' "$state_dir/brake-events.jsonl" 2>/dev/null || echo 0)"
if [ "$wic" -ge 5 ] && [ "$wdc" -ge 1 ]; then
  _pass "warn-mode: $wic whitelisted_in_fail (Read/Grep/Glob/AUQ/TodoWrite), $wdc would_have_denied (Bash)"
else
  _fail "warn-mode misclassified (whitelisted_in_fail=$wic, would_have_denied=$wdc); events: $(cat "$state_dir/brake-events.jsonl")"
fi

# ─── Test 24 (NEW): Read bypasses backpressure on FAIL with read_observed ─
echo "Test 24 — Read against cached FAIL with read_observed bypasses backpressure (coo-memory#1168 soak-fix)"
set -- $(echo "$(_setup_session_dirs "t24")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
# Stage file deliverables + 1 of 4 identity reads → FAIL on remaining 3.
_make_all_deliverables_present "$state_dir" "$home_dir"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\t%s/identity/charter.md\n' "$ts" "$COO_MEMORY_DIR" \
  >> "$home_dir/.vade/session-reads.t24.log"
# First fire → sentinel FAIL (charter satisfied, 3 *_consumed unsatisfied)
_invoke_guard t24 Bash warn "$state_dir" "$home_dir" "ls" > /dev/null
state_before="$(python3 -c "import json; print(json.load(open('$state_dir/boot-brake.t24.json'))['state'])")"
if [ "$state_before" != "FAIL" ]; then
  _fail "Test 24 precondition: expected FAIL after 1-of-4 identity read, got $state_before"
fi
# Within 1s (backpressure window), satisfy the other 3 via Reads and
# fire the guard for each. Without the bypass, the cached FAIL would
# survive all three Reads. With the bypass, the brake re-validates and
# transitions FAIL → OK by the last Read.
for f in governance preferences episodic_memory; do
  printf '%s\t%s/identity/%s.md\n' "$ts" "$COO_MEMORY_DIR" "$f" \
    >> "$home_dir/.vade/session-reads.t24.log"
  _invoke_guard t24 Read warn "$state_dir" "$home_dir" "$COO_MEMORY_DIR/identity/$f.md" > /dev/null
done
state_after="$(python3 -c "import json; print(json.load(open('$state_dir/boot-brake.t24.json'))['state'])")"
if [ "$state_after" = "OK" ]; then
  _pass "Read in FAIL re-validates within backpressure window → FAIL→OK"
else
  _fail "Cached FAIL survived satisfying Reads (state=$state_after); backpressure bypass not effective"
fi
# Sanity: a non-Read tool with no satisfying read does NOT bypass — the
# bypass is targeted to the gate-closing case, not a general escape hatch.
set -- $(echo "$(_setup_session_dirs "t24b")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
_make_all_deliverables_present "$state_dir" "$home_dir"
_invoke_guard t24b Bash warn "$state_dir" "$home_dir" "ls" > /dev/null
checked_at_1="$(python3 -c "import json; print(json.load(open('$state_dir/boot-brake.t24b.json'))['checked_at_epoch'])")"
_invoke_guard t24b Bash warn "$state_dir" "$home_dir" "ls" > /dev/null
checked_at_2="$(python3 -c "import json; print(json.load(open('$state_dir/boot-brake.t24b.json'))['checked_at_epoch'])")"
if [ "$checked_at_1" = "$checked_at_2" ]; then
  _pass "Non-Read within backpressure window does not re-validate (bypass is targeted)"
else
  _fail "Non-Read also bypassed backpressure (over-broad bypass; checked_at changed)"
fi

# ─── Test 25 (NEW): clear-hook rotates brake-events.jsonl across UTC-day (#1168 O6) ─
echo "Test 25 — clear-hook rotates brake-events.jsonl on day boundary (coo-memory#1168 O6)"
set -- $(echo "$(_setup_session_dirs "t25")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
events_log="$state_dir/brake-events.jsonl"
printf '{"v":1,"ts":"2026-06-04T08:00:00Z","cause":"deliverable_missing"}\n' > "$events_log"
# Backdate mtime by 48h so it's strictly before today (UTC).
touch -d "2 days ago" "$events_log"
mtime_date="$(date -u -r "$events_log" +%Y-%m-%d)"
VADE_CLOUD_STATE_DIR="$state_dir" HOME="$home_dir" \
  CLAUDE_CODE_SESSION_ID="t25" \
  bash "$CLEAR" 2>/dev/null </dev/null
dated="$state_dir/brake-events.${mtime_date}.jsonl"
if [ -f "$dated" ] && grep -q "deliverable_missing" "$dated" 2>/dev/null; then
  _pass "stale jsonl rotated to brake-events.${mtime_date}.jsonl with content preserved"
else
  _fail "rotation didn't produce ${dated} (state_dir: $(ls "$state_dir"))"
fi
if [ ! -s "$events_log" ]; then
  _pass "live events.jsonl drained after rotation (next session writes from empty)"
else
  _fail "live events.jsonl still has bytes after rotation"
fi
# Same-day re-fire: no further rotation should happen.
printf '{"v":1,"ts":"%s","cause":"all_satisfied"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$events_log"
size_before="$(wc -c < "$events_log")"
VADE_CLOUD_STATE_DIR="$state_dir" HOME="$home_dir" \
  CLAUDE_CODE_SESSION_ID="t25" \
  bash "$CLEAR" 2>/dev/null </dev/null
size_after="$(wc -c < "$events_log")"
if [ "$size_before" = "$size_after" ]; then
  _pass "same-day re-fire leaves today's events.jsonl untouched (idempotent)"
else
  _fail "re-fire mutated today's events.jsonl ($size_before → $size_after)"
fi

# ─── Test 26 (NEW): clear-hook sweeps faults-dir entries older than 24h (#1168 O8) ─
echo "Test 26 — clear-hook sweeps boot-brake-faults/ entries > 24h (coo-memory#1168 O8)"
set -- $(echo "$(_setup_session_dirs "t26")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
faults_dir="$state_dir/boot-brake-faults"
mkdir -p "$faults_dir"
touch -d "48 hours ago" "$faults_dir/old.log"
touch "$faults_dir/recent.log"
VADE_CLOUD_STATE_DIR="$state_dir" HOME="$home_dir" \
  CLAUDE_CODE_SESSION_ID="t26" \
  bash "$CLEAR" 2>/dev/null </dev/null
if [ ! -e "$faults_dir/old.log" ] && [ -e "$faults_dir/recent.log" ]; then
  _pass "old fault diagnostic swept; recent one preserved"
else
  _fail "fault sweep wrong: old.log=$([ -e $faults_dir/old.log ] && echo present || echo gone), recent.log=$([ -e $faults_dir/recent.log ] && echo present || echo gone)"
fi

# ─── Test 27 (NEW): clear-hook compacts old-month daily files to .jsonl.gz (#1168 O6) ─
echo "Test 27 — clear-hook compacts month-old daily files into .jsonl.gz (coo-memory#1168 O6)"
set -- $(echo "$(_setup_session_dirs "t27")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
# Stage two daily files from a month at least 2 months back so today's
# current_ym can never collide regardless of when CI runs.
old_month="2024-01"
printf '{"v":1,"ts":"2024-01-15T08:00:00Z","cause":"deliverable_missing"}\n' \
  > "$state_dir/brake-events.${old_month}-15.jsonl"
printf '{"v":1,"ts":"2024-01-22T08:00:00Z","cause":"all_satisfied"}\n' \
  > "$state_dir/brake-events.${old_month}-22.jsonl"
VADE_CLOUD_STATE_DIR="$state_dir" HOME="$home_dir" \
  CLAUDE_CODE_SESSION_ID="t27" \
  bash "$CLEAR" 2>/dev/null </dev/null
monthly_gz="$state_dir/brake-events.${old_month}.jsonl.gz"
if [ -f "$monthly_gz" ]; then
  _pass "monthly .jsonl.gz produced for ${old_month}"
else
  _fail "no monthly .jsonl.gz produced (state_dir: $(ls "$state_dir"))"
fi
if [ ! -e "$state_dir/brake-events.${old_month}-15.jsonl" ] \
   && [ ! -e "$state_dir/brake-events.${old_month}-22.jsonl" ]; then
  _pass "compacted daily files removed"
else
  _fail "daily files still present after compaction"
fi
# Round-trip: gunzip the archive and confirm both events survive.
if [ -f "$monthly_gz" ]; then
  contents="$(gunzip -c "$monthly_gz" 2>/dev/null)"
  if echo "$contents" | grep -q "2024-01-15" && echo "$contents" | grep -q "2024-01-22"; then
    _pass "compacted archive round-trips both days' events"
  else
    _fail "compacted archive missing events (got: $contents)"
  fi
fi
# Idempotency: re-fire is a no-op since there are no more old daily files.
size_before="$(wc -c < "$monthly_gz")"
VADE_CLOUD_STATE_DIR="$state_dir" HOME="$home_dir" \
  CLAUDE_CODE_SESSION_ID="t27" \
  bash "$CLEAR" 2>/dev/null </dev/null
size_after="$(wc -c < "$monthly_gz")"
if [ "$size_before" = "$size_after" ]; then
  _pass "compaction re-fire with no new dailies is idempotent"
else
  _fail "compaction re-fire mutated archive ($size_before → $size_after)"
fi

# ─── Test 28 (NEW): race-gate clears via explicit phase=end markers (#1168 O14) ─
echo "Test 28 — race-gate clears when boot.log carries phase=end for all producers (coo-memory#1168 O14)"
set -- $(echo "$(_setup_session_dirs "t28")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
_make_all_deliverables_present "$state_dir" "$home_dir" "t28"
mkdir -p "$home_dir/.vade"
ts_iso="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
# Write phase=start + phase=end pairs for each tracked producer.
# Unlike Test 15 (which exercises the start+elapsed fallback), this
# test exercises the canonical phase=end signal — the path Test 12 + 15
# never touched (coo-memory#1168 O14).
cat > "$home_dir/.vade/boot.log" <<EOF
{"ts":"$ts_iso","session":"t28","script":"session-start-sync","phase":"start"}
{"ts":"$ts_iso","session":"t28","script":"session-start-sync","phase":"end"}
{"ts":"$ts_iso","session":"t28","script":"coo-bootstrap","phase":"start"}
{"ts":"$ts_iso","session":"t28","script":"coo-bootstrap","phase":"end"}
{"ts":"$ts_iso","session":"t28","script":"coo-identity-digest","phase":"start"}
{"ts":"$ts_iso","session":"t28","script":"coo-identity-digest","phase":"end"}
EOF
# Race window large enough that absent end-markers would gate; with end
# markers present the gate must clear immediately and the state must
# settle to OK (deliverables are seeded by _make_all_deliverables_present).
out="$(printf '{"session_id":"t28","cwd":"/home/user","tool_name":"Bash","tool_input":{"command":"ls"}}' | \
  VADE_BRAKE_ENFORCE=block-on-FAIL \
  VADE_BRAKE_RACE_GRACE_SECONDS=300 \
  VADE_CLOUD_STATE_DIR="$state_dir" \
  VADE_COO_MEMORY_DIR="$COO_MEMORY_DIR" \
  HOME="$home_dir" \
  bash "$GUARD" 2>/dev/null)"
state_t28="$(python3 -c "import json; print(json.load(open('$state_dir/boot-brake.t28.json'))['state'])")"
if [ "$state_t28" = "OK" ] && [ -z "$out" ]; then
  _pass "phase=end markers → race-gate clears immediately → state=OK"
else
  _fail "phase=end markers didn't clear race-gate (state=$state_t28, out=$out)"
fi
# Negative control: drop the last end-marker → coo-identity-digest is
# considered still in-flight, race-gate engages.
cat > "$home_dir/.vade/boot.log" <<EOF
{"ts":"$ts_iso","session":"t28b","script":"session-start-sync","phase":"start"}
{"ts":"$ts_iso","session":"t28b","script":"session-start-sync","phase":"end"}
{"ts":"$ts_iso","session":"t28b","script":"coo-bootstrap","phase":"start"}
{"ts":"$ts_iso","session":"t28b","script":"coo-bootstrap","phase":"end"}
{"ts":"$ts_iso","session":"t28b","script":"coo-identity-digest","phase":"start"}
EOF
set -- $(echo "$(_setup_session_dirs "t28b")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
_make_all_deliverables_present "$state_dir" "$home_dir" "t28b"
mkdir -p "$home_dir/.vade"
# Re-emit the partial boot.log (the prior _setup_session_dirs wiped it)
cat > "$home_dir/.vade/boot.log" <<EOF
{"ts":"$ts_iso","session":"t28b","script":"session-start-sync","phase":"start"}
{"ts":"$ts_iso","session":"t28b","script":"session-start-sync","phase":"end"}
{"ts":"$ts_iso","session":"t28b","script":"coo-bootstrap","phase":"start"}
{"ts":"$ts_iso","session":"t28b","script":"coo-bootstrap","phase":"end"}
{"ts":"$ts_iso","session":"t28b","script":"coo-identity-digest","phase":"start"}
EOF
printf '{"session_id":"t28b","cwd":"/home/user","tool_name":"Bash","tool_input":{"command":"ls"}}' | \
  VADE_BRAKE_ENFORCE=block-on-FAIL \
  VADE_BRAKE_RACE_GRACE_SECONDS=300 \
  VADE_CLOUD_STATE_DIR="$state_dir" \
  VADE_COO_MEMORY_DIR="$COO_MEMORY_DIR" \
  HOME="$home_dir" \
  bash "$GUARD" 2>/dev/null > /dev/null
state_t28b="$(python3 -c "import json; print(json.load(open('$state_dir/boot-brake.t28b.json'))['state'])")"
missing_t28b="$(python3 -c "import json; d=json.load(open('$state_dir/boot-brake.t28b.json')); print(','.join((d.get('race_gate') or {}).get('missing_producers', [])))")"
if [ "$state_t28b" = "PENDING" ] && [[ "$missing_t28b" == *"coo-identity-digest"* ]]; then
  _pass "missing phase=end on coo-identity-digest → race-gate engages (negative control)"
else
  _fail "negative race-gate check (state=$state_t28b, missing=$missing_t28b)"
fi

# ─── Test 29 (NEW): has_jq_path rejects unsupported syntax (#1168 O15) ─
echo "Test 29 — has_jq_path rejects unsupported syntax with specific deny reason (coo-memory#1168 O15)"
set -- $(echo "$(_setup_session_dirs "t29")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
_make_all_deliverables_present "$state_dir" "$home_dir" "t29"
# Stage a fixture manifest with a deliberately-malformed has_jq_path entry.
malformed_manifest="$TEST_ROOT/malformed-coo-memory"
mkdir -p "$malformed_manifest/operations"
cat > "$malformed_manifest/operations/boot-deliverables.yml" <<'EOF'
manifest_version: 2
deliverables:
  - id: integrity_check_json
    path: $VADE_CLOUD_STATE_DIR/integrity-check.json
    check_kind: has_jq_path
    check_arg: "summary.ok | select(.x)"
    producer: coo-harness/scripts/boot/integrity-check.sh
    severity: critical
EOF
out="$(VADE_COO_MEMORY_DIR_OVERRIDE="$malformed_manifest" \
  _invoke_guard t29 Bash block-on-FAIL "$state_dir" "$home_dir" "ls")"
if printf '%s' "$out" | grep -q 'unsupported jq path syntax'; then
  _pass "malformed has_jq_path → deny reason names 'unsupported jq path syntax'"
else
  _fail "malformed has_jq_path didn't surface the syntax error (got: $out)"
fi
# Sanity: a well-formed has_jq_path still works.
cat > "$malformed_manifest/operations/boot-deliverables.yml" <<'EOF'
manifest_version: 2
deliverables:
  - id: integrity_check_json
    path: $VADE_CLOUD_STATE_DIR/integrity-check.json
    check_kind: has_jq_path
    check_arg: "summary.ok"
    producer: coo-harness/scripts/boot/integrity-check.sh
    severity: critical
EOF
set -- $(echo "$(_setup_session_dirs "t29b")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
# integrity-check.json with summary.ok=true satisfies the check.
mkdir -p "$state_dir" "$home_dir/.vade" "$home_dir/.claude"
printf '{"summary":{"ok":true}}' > "$state_dir/integrity-check.json"
out="$(VADE_COO_MEMORY_DIR_OVERRIDE="$malformed_manifest" \
  _invoke_guard t29b Bash block-on-FAIL "$state_dir" "$home_dir" "ls")"
if [ -z "$out" ]; then
  _pass "well-formed has_jq_path resolves to OK (no deny output)"
else
  # Could still fail on other deliverables but the syntax-check shouldn't be the cause.
  if printf '%s' "$out" | grep -q 'unsupported jq path syntax'; then
    _fail "well-formed has_jq_path mis-rejected as unsupported (got: $out)"
  else
    # Some other deliverable might be missing — that's fine, not our test.
    _pass "well-formed has_jq_path didn't trip O15 syntax check (any deny is for other deliverables)"
  fi
fi

# ─── Test 5 (v2 §7): manifest static cross-check ────────────────
# Each manifest entry's path substring appears in its producer source.
# Catches the regression where someone renames a deliverable file but
# forgets to update the manifest, or vice versa. Two sub-checks:
#
#   (a) check_kind ≠ read_observed: basename(path) appears in producer
#       source. Only runs for producers that exist on disk in this CI
#       context (coo-harness producers always; coo-memory producers
#       skipped because the CI stage only ships a stub coo-memory).
#   (b) check_kind = read_observed: the check_arg regex matches the
#       producer path. The producer for *_consumed entries IS the file
#       the agent must Read; the regex on check_arg is what the guard
#       uses to detect that Read. Misalignment = silent test bypass.
#
# Runs against the manifest the brake actually loads
# ($VADE_COO_MEMORY_DIR/operations/boot-deliverables.yml), so this tests
# the same artifact production CI exercises. Per coo-memory#1174 TST1.
echo "Test 5 — manifest static cross-check (v2 §7 #5)"
t5_manifest="$COO_MEMORY_DIR/operations/boot-deliverables.yml"
if [ ! -f "$t5_manifest" ]; then
  _fail "manifest not found at $t5_manifest"
else
  t5_result="$(MANIFEST="$t5_manifest" REPO_ROOT_HARNESS="$REPO_ROOT" REPO_ROOT_MEMORY="$COO_MEMORY_DIR" python3 -c '
import os, re, sys
try:
    import yaml
except ImportError:
    print("SKIP pyyaml-missing")
    sys.exit(0)
with open(os.environ["MANIFEST"]) as fh:
    m = yaml.safe_load(fh)
ok = []
bad = []
skipped = []
for e in m.get("deliverables", []):
    eid = e.get("id", "?")
    kind = e.get("check_kind", "exists")
    path = e.get("path", "")
    producer = e.get("producer", "")
    # Resolve producer path: harness-prefixed → REPO_ROOT_HARNESS;
    # memory-prefixed → REPO_ROOT_MEMORY; absolute → as-is.
    if producer.startswith("coo-harness/"):
        prod_path = os.path.join(os.environ["REPO_ROOT_HARNESS"], producer[len("coo-harness/"):])
    elif producer.startswith("coo-memory/"):
        prod_path = os.path.join(os.environ["REPO_ROOT_MEMORY"], producer[len("coo-memory/"):])
    elif producer.startswith("/"):
        prod_path = producer
    else:
        prod_path = producer
    if kind == "read_observed":
        # (b) the regex must match the producer path.
        arg = e.get("check_arg", "")
        try:
            rx = re.compile(arg)
        except re.error as exc:
            bad.append(f"{eid}: bad regex {arg!r}: {exc}")
            continue
        # producer for *_consumed entries is the canonical file path; the
        # regex is anchored on the path tail. Match against the producer
        # string itself.
        if rx.search(producer):
            ok.append(f"{eid} (regex match)")
        elif eid == "identity_consumed":
            # identity_consumed has predicate-gated path and a tool-results
            # regex; producer is the digest script, not a file the regex
            # targets. Documented dynamic path; cross-check is via the
            # predicate_exists_glob instead — substring of the glob.
            glob = e.get("predicate_exists_glob", "")
            if "tool-results" in glob and "hook-" in arg:
                ok.append(f"{eid} (predicate↔regex shape match)")
            else:
                bad.append(f"{eid}: predicate/regex shape mismatch (glob={glob!r}, arg={arg!r})")
        else:
            bad.append(f"{eid}: regex {arg!r} does not match producer {producer!r}")
        continue
    # (a) basename(path) appears in producer source.
    base = os.path.basename(path)
    if not base or path == "dynamic":
        skipped.append(f"{eid}: no usable basename")
        continue
    if not os.path.isfile(prod_path):
        skipped.append(f"{eid}: producer source not present in CI context ({prod_path})")
        continue
    try:
        with open(prod_path) as fh:
            src = fh.read()
    except Exception as exc:
        bad.append(f"{eid}: cannot read producer {prod_path}: {exc}")
        continue
    if base in src:
        ok.append(f"{eid} ({base} in {producer})")
    else:
        bad.append(f"{eid}: {base!r} not found in {producer}")
print("OK", len(ok))
print("BAD", len(bad))
print("SKIP", len(skipped))
for line in bad:
    print("  BAD:", line)
for line in skipped:
    print("  skip:", line)
sys.exit(1 if bad else 0)
' 2>&1)" && t5_rc=0 || t5_rc=$?
  if [ "$t5_rc" = "0" ]; then
    t5_ok="$(printf '%s\n' "$t5_result" | awk '/^OK/ {print $2}')"
    t5_skip="$(printf '%s\n' "$t5_result" | awk '/^SKIP/ {print $2}')"
    if [ "${t5_ok:-0}" -ge 1 ]; then
      _pass "manifest cross-check: $t5_ok entries verified, $t5_skip skipped"
    else
      _fail "manifest cross-check: 0 entries verified (everything skipped?). Output: $t5_result"
    fi
  else
    _fail "manifest cross-check failed: $t5_result"
  fi
fi

# ─── Test 8 (v2 §7): prompt-injection sanitization ──────────────
# A malicious manifest field (deliverable id or producer name) must not
# reach the agent's deny-reason context with shell metachars or
# instruction-injection text intact. The guard's sanitize() restricts
# interpolated values to [A-Za-z0-9 ._/:-]; this test confirms the
# restriction holds end-to-end through the deny path.
#
# Per coo-memory#1174 TST1. v2 §4 (R2#6).
echo "Test 8 — prompt-injection sanitization (v2 §7 #8)"
set -- $(echo "$(_setup_session_dirs "t8")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
_make_all_deliverables_present "$state_dir" "$home_dir" "t8"
# Stage a custom manifest with a deliverable id containing forbidden
# chars: shell metachars (;`$|&), backslashes, parens, brackets, and
# an instruction-injection phrase using non-safe-set punctuation.
t8_manifest_dir="$TEST_ROOT/t8-manifest"
mkdir -p "$t8_manifest_dir/operations"
cat > "$t8_manifest_dir/operations/boot-deliverables.yml" <<'EOF'
manifest_version: 99
deliverables:
  - id: "inject;`$|&\\(){}<>ignore=previous"
    path: /tmp/t8-deliverable-that-does-not-exist
    check_kind: exists
    producer: "producer;`$(rm)<inject>"
    severity: critical
EOF
out8="$(VADE_COO_MEMORY_DIR_OVERRIDE="$t8_manifest_dir" \
  _invoke_guard t8 Bash block-on-FAIL "$state_dir" "$home_dir" "ls")"
# Extract permissionDecisionReason — the actual string the agent sees in
# its tool-feedback context. Sanitization is asserted on THIS value, not
# on the JSON envelope ({ } are structural in the envelope and must be
# permitted there).
t8_reason="$(printf '%s' "$out8" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d["hookSpecificOutput"]["permissionDecisionReason"])
except Exception as e:
    print(f"PARSE_ERR:{e}")
')"
t8_violations=""
for ch in ';' '`' '$' '|' '&' '(' ')' '{' '}' '<' '>' '=' '\\'; do
  if printf '%s' "$t8_reason" | grep -qF "$ch"; then
    t8_violations="$t8_violations $ch"
  fi
done
if [ -z "$t8_violations" ]; then
  _pass "deny reason strips shell metachars from interpolated values"
else
  _fail "deny reason contains forbidden chars:$t8_violations  Reason: $t8_reason"
fi
# Confirm the injection text was actually stripped (not just absent
# because the test sample didn't contain it). The injected id was
# 'inject;\`\$|&\\(){}<>ignore=previous'; after sanitization only the
# safe chars [A-Za-z0-9] survive → "injectignoreprevious".
if printf '%s' "$t8_reason" | grep -q "injectignoreprevious"; then
  _pass "injected id collapsed to safe-charset residue (proves sanitize fired, not just absent input)"
else
  _fail "expected sanitized id 'injectignoreprevious' not found in reason: $t8_reason"
fi
# Positive sanity: the deny output is still a well-formed deny.
if printf '%s' "$out8" | grep -q '"permissionDecision":[[:space:]]*"deny"'; then
  _pass "deny is still emitted (sanitization does not break the deny path)"
else
  _fail "no deny emitted — sanitization broke the deny path. Output: $out8"
fi

# ─── Test 10 (v2 §7): legacy-format collision ───────────────────
# Modern PreToolUse outputs hookSpecificOutput.permissionDecision. Legacy
# outputs {"decision":"block"|"approve"}. v2 §4 (R1#1) requires
# empirical verification that on the actual Claude Code build, when
# sibling hooks emit one of each shape, most-restrictive wins.
#
# The brake guard's output shape is asserted here as a structural unit
# test (the half we CAN do in-process). The full Claude-Code-chain
# empirical check runs only when both CLAUDE_BIN points at a callable
# claude binary AND VADE_TEST_LEGACY_COLLISION=1 — gated so CI skips
# cleanly without a binary in scope. The operator procedure is
# documented inline below.
#
# Per coo-memory#1174 TST1.
echo "Test 10 — legacy-format collision: brake output shape + optional empirical (v2 §7 #10)"
set -- $(echo "$(_setup_session_dirs "t10")" | tr '|' ' ')
state_dir="$1"; home_dir="$2"
# (a) Structural: brake's deny output is canonical modern format,
# carries no legacy keys that would create ambiguity in chain-merge.
out10="$(_invoke_guard t10 Bash block-on-FAIL "$state_dir" "$home_dir" "ls")"
t10_shape="$(printf '%s' "$out10" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception as e:
    print(f"PARSE_ERR:{e}")
    sys.exit(0)
hso = d.get("hookSpecificOutput") or {}
flags = []
if hso.get("hookEventName") == "PreToolUse":
    flags.append("hookEventName=PreToolUse")
if hso.get("permissionDecision") == "deny":
    flags.append("permissionDecision=deny")
if isinstance(hso.get("permissionDecisionReason"), str) and hso["permissionDecisionReason"]:
    flags.append("permissionDecisionReason=non-empty")
# Legacy keys that would make chain-merge ambiguous if present.
for legacy in ("decision", "approve", "block", "message"):
    if legacy in d:
        flags.append(f"LEGACY_KEY:{legacy}")
print(" ".join(flags) if flags else "NO_FLAGS")
')"
case "$t10_shape" in
  "hookEventName=PreToolUse permissionDecision=deny permissionDecisionReason=non-empty")
    _pass "brake deny is canonical modern PreToolUse shape; no legacy keys" ;;
  *LEGACY_KEY:*)
    _fail "brake deny carries legacy key — chain-merge ambiguity risk: $t10_shape" ;;
  *)
    _fail "brake deny shape unexpected: $t10_shape" ;;
esac
# (b) Empirical (opt-in): if a claude binary is available, exercise the
# documented most-restrictive-wins behavior with two sibling hooks (one
# legacy block + one modern allow) and observe deny on the tool call.
# Stays a manual operator gate until a CI runner ships Claude Code.
t10_claude_bin="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
if [ "${VADE_TEST_LEGACY_COLLISION:-0}" = "1" ] && [ -n "$t10_claude_bin" ] && [ -x "$t10_claude_bin" ]; then
  echo "  running empirical legacy/modern collision check against $t10_claude_bin"
  t10_collide_dir="$TEST_ROOT/t10-collide"
  rm -rf "$t10_collide_dir"
  mkdir -p "$t10_collide_dir/.claude"
  cat > "$t10_collide_dir/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [
        {"type": "command", "command": "printf '%s' '{\"decision\":\"block\",\"message\":\"legacy block\"}'"},
        {"type": "command", "command": "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"permissionDecisionReason\":\"\"}}'"}
      ]}
    ]
  }
}
EOF
  # Try a headless tool invocation; capture exit/stderr. Treat presence
  # of "block" / "deny" / non-zero rc as evidence the deny path won.
  t10_emp="$(cd "$t10_collide_dir" && "$t10_claude_bin" -p 'run: ls /tmp' 2>&1 || true)"
  if printf '%s' "$t10_emp" | grep -qiE 'block|deny|denied|refused|legacy block'; then
    _pass "empirical: legacy block + modern allow → deny wins (claude output mentions block/deny)"
  else
    _fail "empirical: collision did not deny (claude output: $(printf '%s' "$t10_emp" | head -c 400))"
  fi
else
  _pass "empirical legacy/modern collision: skipped (set VADE_TEST_LEGACY_COLLISION=1 + claude on PATH to run)"
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
