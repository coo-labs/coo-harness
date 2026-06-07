#!/usr/bin/env bash
# Local (macOS) equivalent of cloud-setup.sh. Runs the same pipeline
# cloud-setup.sh runs at snapshot-build time, with one substitution:
# $DEV_DIR/coo-labs takes the place of /home/user as the workspace root
# where sibling repos (coo-harness, coo-memory, vade-canvas) live
# and where the workspace-root symlinks (.mcp.json, CLAUDE.md) land.
#
# Unlike cloud, the synced .claude/ goes to project-scope
# $WORKSPACE_ROOT/.claude/ rather than user-scope $HOME/.claude/, so the
# user's personal Claude Code config (Warp plugin, personal permissions,
# autoMemoryEnabled, etc.) is untouched. settings.json hook commands
# reference $CLAUDE_PROJECT_DIR/.claude/vade-hooks/dispatch.sh — Claude
# Code sets $CLAUDE_PROJECT_DIR to the project root at hook-fire time,
# which resolves to $WORKSPACE_ROOT on local and $HOME on cloud.
#
# Two env-var redirects keep the run from touching the user's personal
# state: VADE_CLOUD_STATE_DIR sends the build receipt and build.log to
# ~/.vade/local-state/ instead of /home/user/.vade-cloud-state/, and
# VADE_COO_GITCONFIG routes Claude's git config to ~/.vade/gitconfig-coo
# (already the shell's GIT_CONFIG_GLOBAL under the coo-labs dotfiles
# wrapper) so ~/.gitconfig is untouched.
#
# Expects OP_SERVICE_ACCOUNT_TOKEN in the process env. The dotfiles
# claude() wrapper is the intended provisioner: it `op read`s the COO
# vault's sandbox SA token into OP_SERVICE_ACCOUNT_TOKEN only when $PWD
# is under ~/GitHub/coo-labs/, so non-vade projects stay untouched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Workspace root: /home/user in cloud, $DEV_DIR/coo-labs locally. Default
# derived from $DEV_DIR with a final fallback to $SCRIPT_DIR/../../.. so
# this runs even if the shell wrapper hasn't exported $DEV_DIR.
: "${DEV_DIR:=${HOME}/GitHub}"
WORKSPACE_ROOT="${VADE_WORKSPACE_ROOT:-${DEV_DIR}/coo-labs}"
[ -d "$WORKSPACE_ROOT" ] || WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

export VADE_CLOUD_STATE_DIR="${VADE_CLOUD_STATE_DIR:-${HOME}/.vade/local-state}"
export VADE_COO_GITCONFIG="${VADE_COO_GITCONFIG:-${HOME}/.vade/gitconfig-coo}"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

log "Local environment setup starting (workspace=$WORKSPACE_ROOT)"
build_log_record START "local-setup: begin (mode=local)"
log "Baseline: node=$(node --version 2>/dev/null || echo 'missing') npm=$(npm --version 2>/dev/null || echo 'missing')"

ensure_dirs
# Scope the sync to the project-scope .claude under the workspace root so
# the user's personal $HOME/.claude/settings.json (Warp plugin, personal
# permissions, autoMemoryEnabled, etc.) stays untouched. Claude Code
# still reads this config when launched with cwd under $WORKSPACE_ROOT.
sync_claude_config "$WORKSPACE_ROOT/coo-harness/.claude" "$WORKSPACE_ROOT/.claude"
# Aggregate per-repo primitives (slash commands, agents, skills, hooks)
# from data-owning repos into the workspace .claude/ via per-file
# symlinks. Source order = priority; first-wins on name conflicts.
# coo-harness is listed first because plumbing (settings.json hooks,
# agentmail) shouldn't lose to a same-named primitive
# in a data repo. Repo list is loaded from config/aggregator.yml so
# future joins are a config edit, not a script change (coo-memory#952).
mapfile -t _AGGREGATOR_REPOS < <(load_aggregator_repos)
aggregate_workspace_claude_config "$WORKSPACE_ROOT" "$WORKSPACE_ROOT/.claude" \
  "${_AGGREGATOR_REPOS[@]}"
# The synced settings.json's hook commands reference
# $CLAUDE_PROJECT_DIR/.claude/vade-hooks/dispatch.sh — sync_claude_config
# above already installs that shim at $WORKSPACE_ROOT/.claude/vade-hooks/
# (which is what $CLAUDE_PROJECT_DIR resolves to on local), so no extra
# install at $HOME is needed.
ensure_workspace_mcp_config "$WORKSPACE_ROOT/coo-harness/.mcp.json" "$WORKSPACE_ROOT/.mcp.json"
ensure_workspace_identity_link "$WORKSPACE_ROOT/coo-memory/CLAUDE.md" "$WORKSPACE_ROOT/CLAUDE.md"

# Validate the synced settings.json actually parses as JSON and has a
# populated SessionStart:startup hook chain. Same probe cloud-setup.sh
# runs at line 31-48 — file-exists alone passes on a truncated file.
SETTINGS_SYNC_OK=false
if [ -f "$WORKSPACE_ROOT/.claude/settings.json" ]; then
  if check_cmd node; then
    if node -e '
      const fs = require("fs");
      const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const chains = (cfg.hooks && cfg.hooks.SessionStart) || [];
      for (const c of chains) {
        if (c.matcher === "startup" && Array.isArray(c.hooks) && c.hooks.length > 0) process.exit(0);
      }
      process.exit(1);
    ' "$WORKSPACE_ROOT/.claude/settings.json" 2>/dev/null; then
      SETTINGS_SYNC_OK=true
    fi
  else
    SETTINGS_SYNC_OK=true
  fi
fi

WORKSPACE_MCP_SYMLINKED=false
[ -L "$WORKSPACE_ROOT/.mcp.json" ] && \
  [ "$(readlink -f "$WORKSPACE_ROOT/.mcp.json" 2>/dev/null)" = "$(readlink -f "$WORKSPACE_ROOT/coo-harness/.mcp.json" 2>/dev/null)" ] && \
  WORKSPACE_MCP_SYMLINKED=true

IDENTITY_LINK_OK=false
[ -L "$WORKSPACE_ROOT/CLAUDE.md" ] && \
  [ "$(readlink -f "$WORKSPACE_ROOT/CLAUDE.md" 2>/dev/null)" = "$(readlink -f "$WORKSPACE_ROOT/coo-memory/CLAUDE.md" 2>/dev/null)" ] && \
  IDENTITY_LINK_OK=true

# Workspace deps opt-in (same gate as cloud). Nothing in the SessionStart
# hook pipeline imports from node_modules, and MCP runs remote; contributors
# who want the full toolchain set VADE_BOOT_INSTALL=1.
if [ "${VADE_BOOT_INSTALL:-0}" = "1" ]; then
  ensure_tsx
  install_deps "$WORKSPACE_ROOT/vade-canvas"
fi

print_versions

# op CLI: on macOS we expect it from brew. ensure_op_cli's installer
# path (/home/user/.local/bin + linux binary) doesn't apply; check
# presence and log guidance if missing instead of failing the run.
if check_cmd op; then
  build_log_record OK "local-setup: op CLI present ($(op --version 2>&1 | head -1))"
elif [ "$(uname -s)" = "Linux" ] && ensure_op_cli; then
  build_log_record OK "local-setup: op CLI installed at setup time"
else
  build_log_record WARN "local-setup: op CLI unavailable; install via: brew install 1password-cli"
  log "Warning: op CLI unavailable; install via: brew install 1password-cli"
fi

# gh CLI: ensure_gh_cli already returns cleanly on macOS with a brew hint.
if ensure_gh_cli; then
  build_log_record OK "local-setup: gh CLI present"
else
  build_log_record WARN "local-setup: gh CLI unavailable; install via: brew install gh"
  log "Warning: gh CLI unavailable; install via: brew install gh"
fi

OP_TOKEN_VISIBLE=false
COO_BOOTSTRAP_RAN=false
if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  OP_TOKEN_VISIBLE=true
  build_log_record PROBE "local-setup: OP_SERVICE_ACCOUNT_TOKEN present (len=${#OP_SERVICE_ACCOUNT_TOKEN})"
  if bash "$SCRIPT_DIR/coo-bootstrap.sh"; then
    COO_BOOTSTRAP_RAN=true
    build_log_record OK "local-setup: coo-bootstrap completed"
  else
    build_log_record FAIL "local-setup: coo-bootstrap failed; continuing without COO identity"
    log "Warning: coo-bootstrap failed; continuing without COO identity."
  fi
else
  build_log_record PROBE "local-setup: OP_SERVICE_ACCOUNT_TOKEN unset; skipping"
  log "OP_SERVICE_ACCOUNT_TOKEN unset; skipping COO bootstrap. (Claude launched outside the claude() wrapper?)"
fi

GIT_SHA="$(git -C "$WORKSPACE_ROOT/coo-harness" rev-parse --short HEAD 2>/dev/null || echo unknown)"
build_receipt_write \
  built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  mode=local \
  workspace_root="$WORKSPACE_ROOT" \
  op_token_visible="$OP_TOKEN_VISIBLE" \
  coo_bootstrap_ran="$COO_BOOTSTRAP_RAN" \
  workspace_mcp_symlinked="$WORKSPACE_MCP_SYMLINKED" \
  identity_link_ok="$IDENTITY_LINK_OK" \
  settings_sync_ok="$SETTINGS_SYNC_OK" \
  git_sha="$GIT_SHA"

build_log_record OK "local-setup: complete (op_token=$OP_TOKEN_VISIBLE coo_bootstrap=$COO_BOOTSTRAP_RAN mcp_link=$WORKSPACE_MCP_SYMLINKED id_link=$IDENTITY_LINK_OK)"
log "Done."
