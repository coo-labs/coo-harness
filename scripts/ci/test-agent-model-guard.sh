#!/usr/bin/env bash
# test-agent-model-guard: smoke-test scripts/hooks/agent-model-guard.sh.
#
# Verifies the auto-inject behavior introduced in coo-harness#501:
# Explore and claude-code-guide subagent calls without an explicit
# `model:` get `sonnet` auto-injected via updatedInput. Calls that
# already have model set, or that target other subagent types, pass
# through unchanged.
#
# Run: bash scripts/ci/test-agent-model-guard.sh
# Exit: 0 if all assertions pass, 1 otherwise.
#
# Reference: coo-harness#501.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/agent-model-guard.sh"

[ -x "$HOOK" ] || { echo "FAIL: hook not executable at $HOOK"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }

PASS=0
FAIL=0

run_hook() {
  local input="$1"
  printf '%s' "$input" | "$HOOK" 2>/dev/null
}

expect_inject() {
  local name="$1" input="$2"
  local out injected decision
  out="$(run_hook "$input")"
  injected="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.model // ""' 2>/dev/null)"
  decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)"
  if [ "$injected" = "sonnet" ] && [ "$decision" = "allow" ]; then
    PASS=$((PASS+1))
    printf '  PASS  INJECT: %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    printf '  FAIL  INJECT: %s\n' "$name"
    printf '         input: %s\n' "$input"
    printf '         output: %s\n' "$out"
  fi
}

expect_allow() {
  local name="$1" input="$2"
  local out
  out="$(run_hook "$input")"
  if [ -z "$out" ]; then
    PASS=$((PASS+1))
    printf '  PASS  ALLOW: %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    printf '  FAIL  ALLOW: %s\n' "$name"
    printf '         input: %s\n' "$input"
    printf '         output: %s\n' "$out"
  fi
}

printf 'INJECT fixtures (must auto-inject sonnet):\n'
expect_inject "Explore, no model" \
  '{"tool_input": {"subagent_type": "Explore", "prompt": "find X"}}'
expect_inject "claude-code-guide, no model" \
  '{"tool_input": {"subagent_type": "claude-code-guide", "prompt": "lookup Y"}}'
expect_inject "Explore, model empty string" \
  '{"tool_input": {"subagent_type": "Explore", "model": "", "prompt": "find X"}}'

printf '\nALLOW fixtures (must pass through unchanged):\n'
expect_allow "Explore + model=sonnet (caller-set)" \
  '{"tool_input": {"subagent_type": "Explore", "model": "sonnet", "prompt": "find X"}}'
expect_allow "Explore + model=haiku (caller-chosen)" \
  '{"tool_input": {"subagent_type": "Explore", "model": "haiku", "prompt": "find X"}}'
expect_allow "Plan, no model (not in inject list)" \
  '{"tool_input": {"subagent_type": "Plan", "prompt": "design X"}}'
expect_allow "general-purpose, no model (not in inject list)" \
  '{"tool_input": {"subagent_type": "general-purpose", "prompt": "research X"}}'
expect_allow "empty subagent_type" \
  '{"tool_input": {"prompt": "do X"}}'

printf '\nPRESERVE fixture (other tool_input fields kept intact on inject):\n'
out="$(run_hook '{"tool_input": {"subagent_type": "Explore", "prompt": "find X", "description": "search task"}}')"
preserved_prompt="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.prompt')"
preserved_desc="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.description')"
if [ "$preserved_prompt" = "find X" ] && [ "$preserved_desc" = "search task" ]; then
  PASS=$((PASS+1))
  printf '  PASS  PRESERVE: prompt + description intact\n'
else
  FAIL=$((FAIL+1))
  printf '  FAIL  PRESERVE: prompt=%s description=%s\n' "$preserved_prompt" "$preserved_desc"
fi

printf '\nResults: %d pass, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
