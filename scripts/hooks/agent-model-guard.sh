#!/usr/bin/env bash
# PreToolUse Agent hook: auto-inject `model: "sonnet"` for built-in
# subagents that default to Haiku ({Explore, claude-code-guide}) when
# the caller omits the model parameter. Preserves cost-safety from the
# silent-Haiku failure mode without forcing a refuse-and-retry round-
# trip on every honest forgetting.
#
# Why: Per https://code.claude.com/docs/en/sub-agents.md the built-in
# `Explore` and `claude-code-guide` subagents are pinned to Haiku. The
# Agent tool's `model:` parameter, when omitted, falls back to that
# pin — so an unannotated `Agent({subagent_type: "Explore", ...})`
# call silently runs on Haiku. Across multiple sessions Ven observed
# the failure profile this produces: high-confidence shallow
# heuristics, uncalibrated assertions, plausible hallucinations that
# fail under verification. The motivating audit is
# coo-labs/coo-logs#347.
#
# The pre-coo-harness#501 version REFUSED these calls and demanded a
# retry. That forced a round-trip on every honest omission. This
# version preserves the safety property — Haiku is never silently used
# — by injecting `model: "sonnet"` via `updatedInput`. The caller can
# still pass `model: "haiku"` explicitly for narrow lookups; the
# discipline shifts from "must type to choose" to "safe default with
# documented override."
#
# Auto-inject rule:
#   tool_input.subagent_type ∈ {"Explore", "claude-code-guide"}
#   AND (tool_input.model is missing OR empty string)
#   → emit updatedInput with .model = "sonnet" + additionalContext
#
# Allow rules:
#   - tool_input.model is any non-empty string. The act of typing it
#     IS the calibrated choice; the hook does not override.
#   - subagent_type is any other value (Plan and general-purpose
#     inherit the parent's model; statusline-setup is Sonnet by
#     default; all custom `.claude/agents/*.md` agents in this
#     substrate pin `model:` in frontmatter).
#
# Reference: coo-harness#501; coo-memory#781;
# operations/parallel_instance_protocol.md §8.6.

set -uo pipefail

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

subagent_type="$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || true)"

case "$subagent_type" in
  Explore|claude-code-guide) ;;
  *) exit 0 ;;
esac

model="$(printf '%s' "$input" | jq -r '.tool_input.model // ""' 2>/dev/null || true)"

if [ -n "$model" ]; then
  exit 0
fi

context="[agent-model-guard] Auto-injected model=\"sonnet\" for built-in subagent '${subagent_type}' (omitted on the call). Override with \`model: \"haiku\"\` only when the result is independently verifiable (narrow file-existence check, one-line lookup). See operations/parallel_instance_protocol.md §8.6."

printf '%s' "$input" | jq --arg ctx "$context" '
  .tool_input.model = "sonnet" |
  {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      updatedInput: .tool_input,
      additionalContext: $ctx
    }
  }
'
exit 0
