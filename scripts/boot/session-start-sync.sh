#!/usr/bin/env bash
# Defensive re-sync on every SessionStart.
#
# Snapshots go stale: the committed repo advances, but the baked-in
# workspace .claude/settings.json and workspace symlinks reflect whatever
# was in coo-harness at build time. This script closes the gap by
# re-running the idempotent pieces of cloud-setup.sh that don't need
# 1Password access:
#
#   1. sync_claude_config — mirror coo-harness/.claude into workspace .claude
#   2. ensure_workspace_mcp_config — workspace .mcp.json symlink
#   3. ensure_workspace_identity_link — workspace CLAUDE.md symlink
#
# Path conventions: $VADE_RUNTIME_DIR (coo-harness checkout) and
# $VADE_COO_MEMORY_DIR (coo-memory checkout) are injected by Anthropic's
# container UI .env block on every Claude Code launch (coo-harness#274).
# Runs first in the SessionStart:startup chain so later hooks see the
# freshest config. Safe to re-run; exits 0 on every path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

WORKSPACE_ROOT_DERIVED="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# common.sh seeds VADE_CLOUD_STATE_DIR with a cloud-host default (/home/user/.vade-cloud-state);
# on Mac local-setup.sh exports ~/.vade/local-state but hook subprocesses don't inherit its env.
# Redirect when the cloud path is absent and the local path exists so integrity-check.sh (and
# other hooks) write to the correct location. coo-harness#171.
if [ ! -d "$VADE_CLOUD_STATE_DIR" ] && [ -d "$HOME/.vade/local-state" ]; then
  VADE_CLOUD_STATE_DIR="$HOME/.vade/local-state"
fi

boot_log_record session-start-sync start
sync_claude_config "$SCRIPT_DIR/../../.claude" "$WORKSPACE_ROOT_DERIVED/.claude"
# Heal $HOME/.claude/settings.json hooks block on cloud. Without this
# resume-time re-sync, hooks-block commits landing between bake and
# resume leave the user-scope settings frozen at bake-time SHA;
# integrity-check B4 trips. CLAUDE_CODE_REMOTE gates "we're in the
# Anthropic cloud"; the $HOME-inequality clause is defense-in-depth
# (on cloud $HOME=/root and $WORKSPACE_ROOT_DERIVED=/home/user diverge).
if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && [ "$HOME" != "$WORKSPACE_ROOT_DERIVED" ]; then
  sync_claude_config "$SCRIPT_DIR/../../.claude" "$HOME/.claude"
fi
# Aggregate per-repo primitives from data-owning repos. Per the
# data-ownership rule (MEMO 2026-04-25-02), slash commands and skills
# live in the repo whose data they manipulate; the aggregator surfaces
# them at the workspace .claude/ so they're invokable from any cwd
# under the workspace. Repo list is loaded from
# scripts/aggregator.yml so future joins are a config edit, not a
# script change (coo-memory#952).
mapfile -t _AGGREGATOR_REPOS < <(load_aggregator_repos)
aggregate_workspace_claude_config "$WORKSPACE_ROOT_DERIVED" "$WORKSPACE_ROOT_DERIVED/.claude" \
  "${_AGGREGATOR_REPOS[@]}"
ensure_workspace_mcp_config "$SCRIPT_DIR/../../.mcp.json" "$WORKSPACE_ROOT_DERIVED/.mcp.json"
ensure_workspace_identity_link "$WORKSPACE_ROOT_DERIVED/coo-memory/CLAUDE.md" "$WORKSPACE_ROOT_DERIVED/CLAUDE.md"
# Stale-snapshot fallback for the mem0 stdio MCP (coo-harness#109).
# cloud-setup.sh is the canonical installer; this catches snapshots
# built before that change, or local dev environments where build-time
# setup doesn't run. Idempotent — short-circuits when the binary is
# already present. Failure is non-fatal: integrity-check E5 will
# surface the gap loudly via the coo-identity-digest banner so the
# next session triggers a /resume rather than wedging silently.
ensure_mem0_mcp_server || true
# Bridge /home/user/.local/bin/gh (persistent install target) onto
# /root/.local/bin (already on PATH for Claude's Bash tool) so the
# MEMO 2026-04-23-02 gh-CLI fallback is callable without the agent
# having to rediscover the install path every session.
ensure_gh_symlink_on_path
# Install the gh-coo-wrap wrapper so every attributable `gh` write
# auto-carries the Claude Code session URL. MEMO 2026-04-26-02
# (issue #150). Idempotent via marker grep.
ensure_gh_coo_wrap "$SCRIPT_DIR/../gh-coo-wrap.sh"
# Path-shadow op with op-coo-wrap so every `op` consumer gets
# transparent rate-limit fallback between OP_SERVICE_ACCOUNT_TOKEN
# and OP_SERVICE_ACCOUNT_TOKEN_BACKUP. Installs before
# coo-bootstrap.sh runs (next in the SessionStart hook chain), so
# bootstrap's own op-reads go through the shim from the start.
ensure_op_coo_wrap "$SCRIPT_DIR/../op-coo-wrap.sh"
# Refresh the external-touch (F6) cache when it's older than 24h.
# Build-time prewarm in cloud-setup.sh handles the fresh-snapshot case;
# this catches snapshots resumed after the cache has gone stale and
# session-resume environments where the build skipped the prewarm
# (no PAT at build time, etc.). Fail-open: if gh/PAT missing or refresh
# fails, F6 falls back to its own "cache absent" skip path.
prewarm_external_touch_cache "$WORKSPACE_ROOT_DERIVED" 24
# integrity-check.sh runs in coo-identity-digest.sh instead of here,
# so the check fires after the platform's repo-sync has settled
# (coo-harness#XXX; moved from here to eliminate boot-time false alarms).
boot_log_record session-start-sync end ok
