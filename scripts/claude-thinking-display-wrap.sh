#!/usr/bin/env bash
# claude-thinking-display-wrap.sh — PATH shim that injects
# `--thinking-display summarized` into Claude Code launches on non-interactive
# surfaces (Web SDK, headless `-p`, IDE extensions), so that Opus 4.7+ sessions
# (whose API default for `thinking.display` is `"omitted"`) still render
# thinking summaries.
#
# Mechanism — extracted from the binary at coo-harness HEAD:
#
#   if (z.thinkingDisplay === "summarized" || z.thinkingDisplay === "omitted")
#     pz.display = z.thinkingDisplay;       // CLI flag — wins on every surface
#   else if (!p6() && hK8())
#     pz.display = "summarized";            // settings flag — gated to interactive
#
# The CLI-flag branch bypasses the `p6()` non-interactive short-circuit entirely.
# This wrapper places that flag on launches that look like agent invocations,
# leaving subcommands / probes / explicit overrides untouched.
#
# Installation (Claude Code on the Web): `cloud-setup.sh` copies this file to
# `/root/.local/bin/claude`. That path precedes `/opt/node22/bin/claude` (the
# Anthropic-managed symlink) in env-manager's PATH, so future session launches
# resolve through the wrapper.
#
# Override knobs:
#   CC_THINKING_DISPLAY=omitted       — hide summaries; pass through unchanged
#   CLAUDE_THINKING_WRAP_REAL_BINARY  — exec target (default /opt/node22/bin/claude)
#
# Inject conditions (all must hold):
#   1. CC_THINKING_DISPLAY != "omitted"
#   2. First arg is not a subcommand/probe (mcp, config, doctor, --version, …)
#   3. --thinking-display is not already in args
#   4. --thinking disabled is not in args
#   5. Args carry an agent-invocation marker (--sdk-url, -p/--print,
#      --output-format=, --thinking adaptive|enabled, …)

set -euo pipefail

REAL_BINARY="${CLAUDE_THINKING_WRAP_REAL_BINARY:-/opt/node22/bin/claude}"
DISPLAY_VALUE="${CC_THINKING_DISPLAY:-summarized}"

if [[ "$DISPLAY_VALUE" == "omitted" ]]; then
  exec "$REAL_BINARY" "$@"
fi

case "${1:-}" in
  ""|mcp|config|migrate-installer|doctor|update|install|setup-token|--version|-v|--help|-h)
    exec "$REAL_BINARY" "$@"
    ;;
esac

have_display=false
thinking_disabled=false
has_agent_marker=false
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
  prev="$a"
done

if [[ "$have_display" == false \
   && "$thinking_disabled" == false \
   && "$has_agent_marker" == true ]]; then
  exec "$REAL_BINARY" --thinking-display "$DISPLAY_VALUE" "$@"
fi

exec "$REAL_BINARY" "$@"
