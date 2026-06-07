#!/usr/bin/env bash
# claude-wrap.sh — PATH shim for cloud Claude Code launches. Intercepts
# agent-shaped invocations and injects CLI flags before exec'ing the real
# `claude` binary. General-purpose: each injection is its own block, gated
# independently. Subcommands and probes pass through untouched.
#
# Installation: `cloud-setup.sh` copies this file to `/root/.local/bin/claude`,
# which precedes `/opt/node22/bin/claude` in env-manager's PATH.
#
# Common preconditions (every injection block requires both):
#   - First arg is not a subcommand or probe (mcp, config, doctor, --version, …).
#   - Args carry an agent-invocation marker (--sdk-url, -p/--print,
#     --output-format=, --thinking adaptive|enabled, --resume=, --model …).
#
# Injection blocks:
#
#   1. `--thinking-display summarized` — MEMO-2026-06-07-4bat.
#      So Opus 4.7+ Web/SDK/headless sessions still render thinking summaries
#      (the binary's API default for `thinking.display` flipped to `"omitted"`).
#         if (z.thinkingDisplay === "summarized" || z.thinkingDisplay === "omitted")
#           pz.display = z.thinkingDisplay;       // CLI flag — wins on every surface
#         else if (!p6() && hK8())
#           pz.display = "summarized";            // settings flag — gated to interactive
#      The CLI-flag branch bypasses the `p6()` non-interactive short-circuit.
#      Extra conditions: CC_THINKING_DISPLAY != "omitted"; --thinking-display
#      not already in args; --thinking disabled not in args.
#
#   2. `Workflow` appended to `--tools` / `--allowed-tools` / `--allowedTools`
#      values — MEMO-2026-06-07-fkef.
#      The cloud env-manager's launcher allowlist omits `Workflow` even when
#      the in-process gate (policy `L7("allow_workflows")` + GrowthBook
#      `tengu_workflows_enabled` + `settings.enableWorkflows`) is satisfied;
#      this adds it back at the launcher arg layer. Extra conditions:
#      CC_INJECT_WORKFLOW != "0"; a target arg is present whose value is
#      neither empty nor literal "default", and does not already include "Workflow".
#
# Override knobs:
#   CC_THINKING_DISPLAY=omitted   — disable thinking-display injection
#   CC_INJECT_WORKFLOW=0          — disable Workflow tool injection
#   CLAUDE_WRAP_REAL_BINARY       — exec target (default /opt/node22/bin/claude)

set -euo pipefail

REAL_BINARY="${CLAUDE_WRAP_REAL_BINARY:-/opt/node22/bin/claude}"
DISPLAY_VALUE="${CC_THINKING_DISPLAY:-summarized}"
INJECT_WORKFLOW="${CC_INJECT_WORKFLOW:-1}"

case "${1:-}" in
  ""|mcp|config|migrate-installer|doctor|update|install|setup-token|--version|-v|--help|-h)
    exec "$REAL_BINARY" "$@"
    ;;
esac

# Single pass: detect flags, agent-marker, and build new args with Workflow
# appended to --tools / --allowed-tools / --allowedTools values when applicable.
have_display=false
thinking_disabled=false
has_agent_marker=false
new_args=()
prev=""
for a in "$@"; do
  case "$a" in
    --thinking-display|--thinking-display=*) have_display=true ;;
    --sdk-url|--sdk-url=*|--resume|--resume=*|-p|--print) has_agent_marker=true ;;
    --output-format=*|--input-format=*) has_agent_marker=true ;;
    --model|--model=*) has_agent_marker=true ;;
  esac
  if [[ "$prev" == "--thinking" ]]; then
    case "$a" in
      disabled) thinking_disabled=true ;;
      adaptive|enabled) has_agent_marker=true ;;
    esac
  fi

  if [[ "$INJECT_WORKFLOW" != "0" ]]; then
    case "$prev" in
      --tools|--allowed-tools|--allowedTools)
        if [[ "$a" != "" && "$a" != "default" && ",$a," != *",Workflow,"* ]]; then
          a="$a,Workflow"
        fi
        ;;
    esac
    case "$a" in
      --tools=*|--allowed-tools=*|--allowedTools=*)
        wflag="${a%%=*}"
        wval="${a#*=}"
        if [[ "$wval" != "" && "$wval" != "default" && ",$wval," != *",Workflow,"* ]]; then
          a="$wflag=$wval,Workflow"
        fi
        ;;
    esac
  fi

  new_args+=("$a")
  prev="$a"
done

set -- "${new_args[@]}"

if [[ "$DISPLAY_VALUE" != "omitted" \
   && "$have_display" == false \
   && "$thinking_disabled" == false \
   && "$has_agent_marker" == true ]]; then
  exec "$REAL_BINARY" --thinking-display "$DISPLAY_VALUE" "$@"
fi

exec "$REAL_BINARY" "$@"
