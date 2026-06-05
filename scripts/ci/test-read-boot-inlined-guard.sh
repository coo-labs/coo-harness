#!/usr/bin/env bash
# test-read-boot-inlined-guard: smoke-test scripts/hooks/read-boot-inlined-guard.sh.
#
# Mirrors test-skill-yaml-guard.sh / test-bash-github-api-guard.sh:
# pipe PreToolUse JSON envelopes into the hook, assert block / allow
# per case.
#
# Run: bash scripts/ci/test-read-boot-inlined-guard.sh
# Exit: 0 on all pass, 1 otherwise.
#
# Reference: coo-harness#399.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/read-boot-inlined-guard.sh"

[ -x "$HOOK" ] || { echo "FAIL: hook not executable at $HOOK"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }

PASS=0
FAIL=0
declare -a FAILURES=()

# run_hook_read <file_path>
run_hook_read() {
  jq -n --arg fp "$1" \
    '{tool_name: "Read", tool_input: {file_path: $fp}}' \
    | "$HOOK" 2>/dev/null
}

# run_hook_raw <stdin-json>
run_hook_raw() {
  printf '%s' "$1" | "$HOOK" 2>/dev/null
}

assert_block() {
  local name="$1" out="$2"
  if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf '  PASS  BLOCK: %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("BLOCK: $name")
    printf '  FAIL  BLOCK: %s\n' "$name"
    printf '         hook output: %s\n' "${out:-<empty>}"
  fi
}

assert_allow() {
  local name="$1" out="$2"
  if [ -z "$out" ] || ! printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf '  PASS  ALLOW: %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("ALLOW: $name")
    printf '  FAIL  ALLOW: %s\n' "$name"
    printf '         hook output: %s\n' "$out"
  fi
}

# --- Block cases: Read on the boot-inlined files ---

printf 'Block cases (Read on boot-inlined paths):\n'

assert_block "Read memo_index.json (absolute canonical path)" \
  "$(run_hook_read /home/user/coo-memory/memos/memo_index.json)"

assert_block "Read memo_index.json (relative path)" \
  "$(run_hook_read coo-memory/memos/memo_index.json)"

assert_block "Read memo_index.json (sibling-checkout path)" \
  "$(run_hook_read /workspace/coo-memory/memos/memo_index.json)"

assert_block "Read identity_layer.md (absolute canonical path)" \
  "$(run_hook_read /home/user/coo-memory/identity/identity_layer.md)"

assert_block "Read identity_layer.md (relative path)" \
  "$(run_hook_read coo-memory/identity/identity_layer.md)"

# --- Allow cases: Read on unrelated paths, or non-Read tools ---

printf '\nAllow cases (Read on unrelated paths, or non-Read tools):\n'

assert_allow "Read CLAUDE.md (not on the block list)" \
  "$(run_hook_read /home/user/coo-memory/CLAUDE.md)"

assert_allow "Read a specific memo file (not the index)" \
  "$(run_hook_read /home/user/coo-memory/memos/2026-05-31-jhp5.md)"

assert_allow "Read an identity file other than identity_layer.md" \
  "$(run_hook_read /home/user/coo-memory/identity/governance.md)"

assert_allow "Read an unrelated JSON file with similar name" \
  "$(run_hook_read /home/user/coo-memory/briefings/briefing_index.json)"

assert_allow "Read a file whose path contains the substring but not the tail" \
  "$(run_hook_read /home/user/coo-memory/memos/memo_index.json.bak)"

# Tool-name discrimination: Edit / Write / Bash on the same paths must pass.
assert_allow "Edit on memo_index.json (committee revisions allowed)" \
  "$(run_hook_raw '{"tool_name":"Edit","tool_input":{"file_path":"/home/user/coo-memory/memos/memo_index.json","old_string":"x","new_string":"y"}}')"

assert_allow "Write on identity_layer.md (committee revisions allowed)" \
  "$(run_hook_raw '{"tool_name":"Write","tool_input":{"file_path":"/home/user/coo-memory/identity/identity_layer.md","content":"..."}}')"

assert_allow "Bash on a command that touches memo_index.json (jq/cat escape hatch)" \
  "$(run_hook_raw '{"tool_name":"Bash","tool_input":{"command":"jq . /home/user/coo-memory/memos/memo_index.json"}}')"

# --- Malformed / empty envelope safety ---

printf '\nSafety cases:\n'

assert_allow "empty stdin" \
  "$(run_hook_raw '')"

assert_allow "malformed JSON stdin" \
  "$(run_hook_raw 'not json')"

assert_allow "Read envelope with no file_path" \
  "$(run_hook_raw '{"tool_name":"Read","tool_input":{}}')"

assert_allow "unknown tool envelope" \
  "$(run_hook_raw '{"tool_name":"Glob","tool_input":{"pattern":"**/memo_index.json"}}')"

# --- Bypass env var ---

printf '\nBypass cases:\n'

bypass_out="$(VADE_BOOT_INLINED_READ_GUARD_BYPASS=1 run_hook_read /home/user/coo-memory/memos/memo_index.json)"
assert_allow "VADE_BOOT_INLINED_READ_GUARD_BYPASS=1 allows blocked Read (memo_index)" \
  "$bypass_out"

bypass_out="$(VADE_BOOT_INLINED_READ_GUARD_BYPASS=1 run_hook_read /home/user/coo-memory/identity/identity_layer.md)"
assert_allow "VADE_BOOT_INLINED_READ_GUARD_BYPASS=1 allows blocked Read (identity_layer)" \
  "$bypass_out"

# --- Block-reason content sanity check ---

printf '\nBlock-reason content:\n'

memo_out="$(run_hook_read /home/user/coo-memory/memos/memo_index.json)"
if printf '%s' "$memo_out" | jq -e '.reason | contains("read-boot-inlined-guard") and contains("jq") and contains("/memo-query") and contains("VADE_BOOT_INLINED_READ_GUARD_BYPASS")' >/dev/null 2>&1; then
  PASS=$((PASS+1))
  printf '  PASS  memo_index reason names hook, jq escape, /memo-query, and bypass\n'
else
  FAIL=$((FAIL+1))
  FAILURES+=("REASON memo_index content")
  printf '  FAIL  memo_index reason content missing expected fragments\n'
  printf '         reason: %s\n' "$(printf '%s' "$memo_out" | jq -r '.reason')"
fi

ident_out="$(run_hook_read /home/user/coo-memory/identity/identity_layer.md)"
if printf '%s' "$ident_out" | jq -e '.reason | contains("read-boot-inlined-guard") and contains("CB-") and contains("cat") and contains("VADE_BOOT_INLINED_READ_GUARD_BYPASS")' >/dev/null 2>&1; then
  PASS=$((PASS+1))
  printf '  PASS  identity_layer reason names hook, CB-* surface, cat escape, and bypass\n'
else
  FAIL=$((FAIL+1))
  FAILURES+=("REASON identity_layer content")
  printf '  FAIL  identity_layer reason content missing expected fragments\n'
  printf '         reason: %s\n' "$(printf '%s' "$ident_out" | jq -r '.reason')"
fi

# --- Summary ---

printf '\nTotal: %d pass, %d fail\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed cases:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
