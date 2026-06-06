#!/usr/bin/env bash
# test-bash-token-guard: smoke-test scripts/hooks/bash-token-guard.sh.
#
# For each fixture, build a Claude Code PreToolUse JSON envelope
# `{"tool_input": {"command": "..."}}`, pipe it into the hook, and
# assert the hook either emits a `{"decision": "block"}` object
# (for BLOCK cases) or emits no JSON (for ALLOW cases).
#
# Run: bash scripts/hooks/test-bash-token-guard.sh
# Exit: 0 if all assertions pass, 1 otherwise.
#
# Reference: coo-harness#165.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/bash-token-guard.sh"

[ -x "$HOOK" ] || { echo "FAIL: hook not executable at $HOOK"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 required"; exit 1; }

PASS=0
FAIL=0
declare -a FAILURES=()

# Run the hook against a command string. Returns the hook's stdout
# (possibly empty for allow, JSON for block).
run_hook() {
  local cmd="$1"
  jq -n --arg c "$cmd" '{tool_input: {command: $c}}' | "$HOOK" 2>/dev/null
}

# Each fixture is given a label and expected decision (block | allow).
expect_block() {
  local name="$1" cmd="$2"
  local out
  out="$(run_hook "$cmd")"
  if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf '  PASS  BLOCK: %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("BLOCK: $name")
    printf '  FAIL  BLOCK: %s\n' "$name"
    printf '         command: %s\n' "$cmd"
    printf '         hook output: %s\n' "$out"
  fi
}

expect_allow() {
  local name="$1" cmd="$2"
  local out
  out="$(run_hook "$cmd")"
  if [ -z "$out" ] || ! printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf '  PASS  ALLOW: %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("ALLOW: $name")
    printf '  FAIL  ALLOW: %s\n' "$name"
    printf '         command: %s\n' "$cmd"
    printf '         hook output: %s\n' "$out"
  fi
}

printf 'BLOCK fixtures (must be refused):\n'
expect_block "echo \$GITHUB_MCP_PAT" \
  'echo $GITHUB_MCP_PAT'
expect_block "echo \"\$GITHUB_TOKEN\"" \
  'echo "$GITHUB_TOKEN"'
expect_block "printf '%s\\n' \$MEM0_API_KEY" \
  "printf '%s\\n' \$MEM0_API_KEY"
expect_block "cat <<EOF / \$OP_SERVICE_ACCOUNT_TOKEN / EOF" \
  $'cat <<EOF\n$OP_SERVICE_ACCOUNT_TOKEN\nEOF'
expect_block "echo \$AGENTMAIL_API_KEY > /tmp/leak.txt" \
  'echo $AGENTMAIL_API_KEY > /tmp/leak.txt'

printf '\nALLOW fixtures (must pass through):\n'
expect_allow "[ -n \"\$GITHUB_MCP_PAT\" ] && echo set" \
  '[ -n "$GITHUB_MCP_PAT" ] && echo set'
expect_allow "echo \"\${#GITHUB_TOKEN}\"" \
  'echo "${#GITHUB_TOKEN}"'
expect_allow "echo \$GITHUB_MCP_PAT > /dev/null" \
  'echo $GITHUB_MCP_PAT > /dev/null'
expect_allow "echo \"\$GITHUB_MCP_PAT\" | gh auth login --with-token" \
  'echo "$GITHUB_MCP_PAT" | gh auth login --with-token'
expect_allow "op read 'op://COO/...'" \
  "op read 'op://COO/...'"
expect_allow "git status" \
  "git status"

printf '\nTotal: %d pass, %d fail (5 BLOCK, 6 ALLOW)\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed cases:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
