#!/usr/bin/env bash
# Claude Code web cloud environment setup.
# Runs once at snapshot build (cached ~7 days; resume restores snapshot).
#
# Entry point: paste into the cloud env "Setup script" field:
#   #!/bin/bash
#   set -e
#   bash /home/user/coo-harness/scripts/boot/cloud-setup.sh
#
# coo-harness and coo-memory are cloned into /home/user/ before this runs.
set -euo pipefail

# Cloud-detection gates downstream key on CLAUDE_CODE_REMOTE=true, which
# Anthropic sets at both snapshot-build time and Claude Code launch time
# (coo-harness#274). No export needed here.

# Derive workspace root from script location so the bootstrap-regression
# CI can stage a sandboxed tree without colliding with production paths.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$RUNTIME_DIR/.." && pwd)"

# shellcheck source=../lib/common.sh
source "$RUNTIME_DIR/scripts/lib/common.sh"

log "Cloud environment setup starting"
build_log_record START "cloud-setup: begin"
log "Baseline: node=$(node --version 2>/dev/null || echo 'missing') npm=$(npm --version 2>/dev/null || echo 'missing')"

ensure_dirs
sync_claude_config "$RUNTIME_DIR/.claude"
# Aggregate per-repo primitives from data-owning repos into the
# user-scope .claude/ via per-file symlinks. Per the data-ownership
# rule (MEMO 2026-04-25-02), slash commands and skills live in the
# repo whose data they manipulate; the aggregator surfaces them at
# user-scope so they're invokable from any session cwd. Repo list is
# loaded from scripts/aggregator.yml so future joins are a config
# edit, not a script change (coo-memory#952).
mapfile -t _AGGREGATOR_REPOS < <(load_aggregator_repos)
aggregate_workspace_claude_config "$WORKSPACE_ROOT" "$HOME/.claude" \
  "${_AGGREGATOR_REPOS[@]}"
ensure_workspace_mcp_config "$RUNTIME_DIR/.mcp.json" "$WORKSPACE_ROOT/.mcp.json"
ensure_workspace_identity_link "$VADE_COO_MEMORY_DIR/CLAUDE.md" "$WORKSPACE_ROOT/CLAUDE.md"

# Validate the synced settings.json actually parses as JSON and has a
# populated SessionStart:startup hook chain. File-exists alone would
# pass on a truncated or corrupt file. Node is guaranteed present on
# the cloud image; fall back to file-exists only if node is missing.
SETTINGS_SYNC_OK=false
if [ -f "$HOME/.claude/settings.json" ]; then
  if check_cmd node; then
    if node -e '
      const fs = require("fs");
      const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const chains = (cfg.hooks && cfg.hooks.SessionStart) || [];
      for (const c of chains) {
        if (c.matcher === "startup" && Array.isArray(c.hooks) && c.hooks.length > 0) process.exit(0);
      }
      process.exit(1);
    ' "$HOME/.claude/settings.json" 2>/dev/null; then
      SETTINGS_SYNC_OK=true
    fi
  else
    SETTINGS_SYNC_OK=true
  fi
fi

WORKSPACE_MCP_SYMLINKED=false
[ -L "$WORKSPACE_ROOT/.mcp.json" ] && \
  [ "$(readlink -f "$WORKSPACE_ROOT/.mcp.json" 2>/dev/null)" = "$(readlink -f "$RUNTIME_DIR/.mcp.json" 2>/dev/null)" ] && \
  WORKSPACE_MCP_SYMLINKED=true

IDENTITY_LINK_OK=false
[ -L "$WORKSPACE_ROOT/CLAUDE.md" ] && \
  [ "$(readlink -f "$WORKSPACE_ROOT/CLAUDE.md" 2>/dev/null)" = "$(readlink -f "$VADE_COO_MEMORY_DIR/CLAUDE.md" 2>/dev/null)" ] && \
  IDENTITY_LINK_OK=true

# Workspace deps (npm install vade-canvas, install tsx) are opt-in:
# nothing in the SessionStart hook pipeline imports from node_modules,
# and MCP runs remote (mcp.vade-app.dev). Contributors who want the
# full local toolchain set VADE_BOOT_INSTALL=1.
if [ "${VADE_BOOT_INSTALL:-0}" = "1" ]; then
  ensure_tsx
  install_deps "$WORKSPACE_ROOT/vade-canvas"
fi

print_versions

# Fetch the consolidated binary vendor bundle (op + gh + uv +
# mem0-mcp-server) in one curl from the coo-harness release asset,
# replacing four per-CDN fetches at snapshot-build time. Best-effort:
# on any failure (missing pin, network, sha mismatch) the per-binary
# ensure_*_cli paths below run as fallback. Briefing 004 / B1 reframe;
# read BINARY_VENDOR_BUNDLE_SHA256 from versions.lock if pinned and
# export so the function can sha256-verify before untar.
BINARY_VENDOR_BUNDLE_SHA256="$(awk '$1 == "binary_vendor_bundle" && $2 != "-" { print $2; exit }' "$RUNTIME_DIR/versions.lock" 2>/dev/null || true)"
export BINARY_VENDOR_BUNDLE_SHA256
if ensure_binaries_from_vendor; then
  build_log_record OK "cloud-setup: binary vendor bundle installed"
else
  build_log_record WARN "cloud-setup: binary vendor bundle unavailable; falling back to per-binary direct fetch"
fi

# Pre-warm uv cache for the boto3-dependent transcript scripts so fresh
# snapshots start with a hot cache. Closes #202. Runs after
# ensure_binaries_from_vendor (provides uv) and before any per-binary
# install path so the cache lives on the snapshot before later steps.
prewarm_uv_cache

# Install the op CLI at snapshot-build time so the SessionStart-hook
# bootstrap fallback never has to fetch it through the egress proxy
# mid-session. The binary lands in /home/user/.local/bin/op which
# survives the snapshot → resume transition. Idempotent: if a prior
# build (or the runtime Dockerfile, per epic #112 Stream 2) already
# installed it, ensure_op_cli's presence-check short-circuits.
#
# FATAL on failure (closes coo-harness#111). A snapshot without op is
# degraded by definition: every session that resumes from it has to
# re-fetch op from cache.agilebits.com mid-SessionStart, exposed to
# the same egress flake the build-time install was supposed to absorb,
# AND the COO identity load (op read … from the COO vault) cannot
# proceed without it. Failing the build forces an immediate rebuild
# rather than producing a session that's structurally guaranteed to
# fail D-group invariants.
#
# Trade-off: cloud build SLA — if cache.agilebits.com is flapping,
# build-fail-rate goes up. Mitigations: the 5-attempt retry budget in
# ensure_op_cli (coo-harness#76); the Dockerfile-baked /usr/local/bin/op
# layer (epic #112 Stream 2) which makes ensure_op_cli a no-op when the
# runtime image is in use. If neither is enough, follow-up work is
# coo-harness#111 option (b) — alternate origin / local mirror.
OP_INSTALLED_AT_BUILD=false
if ensure_op_cli; then
  OP_INSTALLED_AT_BUILD=true
  build_log_record OK "cloud-setup: op CLI installed at build time"
else
  build_log_record WARN "cloud-setup: op CLI install failed at build time; receipt will record op_installed_at_build=false"
  log "Warning: op CLI install failed at build time; snapshot ships degraded."
  log "  coo-identity-digest renders a ⚠ block at SessionStart when the receipt"
  log "  shows op_installed_at_build=false, so the operator sees the degradation"
  log "  loudly instead of mid-task. coo-bootstrap.sh re-runs ensure_op_cli at"
  log "  SessionStart — different egress window than build time, may recover."
  log "  Reverses #116's FATAL flip per BDFL: failing the build was over-strict"
  log "  given that #119 showed the cloud sandbox doesn't actually use the"
  log "  Dockerfile-baked /usr/local/bin/op, so the bake doesn't backstop a"
  log "  cache.agilebits.com flake at snapshot-build time. Bootable-but-degraded"
  log "  is strictly better than unbootable for diagnostic purposes."
fi

# Install the gh CLI for the same reason: snapshot-persistent, no
# per-resume fetch. Per Epic #112 Stream 1 (closing the cloud-boot
# flake chapter), `gh` is now the canonical GitHub write path under
# vade-coo attribution — the github-coo MCP transport was retired
# because its `type: "http"` channel kept hitting Node `undici` DNS-
# cache overflow (see #36, #109, MEMO-2026-04-24-08).
if ensure_gh_cli; then
  build_log_record OK "cloud-setup: gh CLI installed at build time"
else
  build_log_record WARN "cloud-setup: gh CLI install failed at build time; sessions will lack the attribution fallback"
  log "Warning: gh CLI install failed at build time; degraded-MCP sessions will fall through to venpopov attribution."
fi

# Install the mem0-mcp-server stdio binary. Same snapshot-persistence
# rationale as op + gh — paying the install cost at build time means
# the SessionStart hook chain never has to fetch through the egress
# proxy, and Claude Code can spawn the MCP at process start without a
# uvx-on-demand round-trip. Required for mem0 MCP availability per
# coo-harness#109; without it the .mcp.json stdio entry points at a
# missing binary and Mem0 surface stays dark.
if ensure_mem0_mcp_server; then
  build_log_record OK "cloud-setup: mem0-mcp-server installed at build time"
else
  build_log_record WARN "cloud-setup: mem0-mcp-server install failed at build time; SessionStart hook will retry"
  log "Warning: mem0-mcp-server install failed at build time; first session will boot with Mem0 MCP dark."
fi

# Install Quarto. Primary use is the read.vade-app.dev publishing site
# (bin/publish-site in coo-memory). Same snapshot-persistence rationale
# as op + gh + mem0-mcp-server: pay the ~131 MB fetch at build time so
# SessionStart stays off the egress proxy. Quarto bundles pandoc + deno.
# Best-effort: on failure the first session that needs it fetches on demand.
if ensure_quarto_cli; then
  build_log_record OK "cloud-setup: quarto installed at build time"
else
  build_log_record WARN "cloud-setup: quarto install failed at build time; first session will need to install on demand"
  log "Warning: quarto install failed at build time; first session that uses it will pay a ~131 MB direct-fetch."
fi

# Defensive PyYAML install — schema-fetch-secrets.py and several boot
# hooks `import yaml` from the system python3. The Debian base image
# currently ships python3-yaml; this re-installs PyYAML into a snapshot-
# persistent path (/home/user/.local/lib/python3.X/site-packages) so a
# future image rebuild can't silently drop it. Pinned in versions.lock.
# coo-harness#440.
#
# Best-effort: a failure here doesn't fail the build. The short-circuit
# fires when PyYAML is already importable (the common case while the
# base image ships it), so failure only matters when the defensive path
# is actually exercised — at which point fetch_coo_secrets surfaces the
# gap fatally at first use, and the brake pins to FAIL.
if ensure_pyyaml; then
  build_log_record OK "cloud-setup: PyYAML present (system or installed at build time)"
else
  build_log_record WARN "cloud-setup: ensure_pyyaml failed; schema-fetch-secrets.py will fail closed if base-image python3-yaml is absent"
  log "Warning: ensure_pyyaml failed; if the base image lacks python3-yaml, coo-bootstrap will fail at fetch_coo_secrets."
fi

# Pre-fetch the 1Password MCP server (@takescake/1password-mcp) so
# first-session `npx -y` resolves offline. Closes the rotated-PAT →
# restart class (coo-harness#164): the MCP can re-read secrets mid-session
# without the restart the cached `op` CLI requires. Read-only is enforced
# by the COO service account's vault permissions.
if npm install -g "@takescake/1password-mcp@2.4.2" --no-audit --no-fund >/dev/null 2>&1; then
  build_log_record OK "cloud-setup: @takescake/1password-mcp installed at build time"
else
  build_log_record WARN "cloud-setup: @takescake/1password-mcp install failed at build time; first-session npx will fetch on demand"
  log "Warning: @takescake/1password-mcp install failed at build time; first session will pay an npx-on-demand fetch."
fi

# COO identity bootstrap runs only when OP_SERVICE_ACCOUNT_TOKEN is set
# in the cloud environment config. Non-fatal on failure — the base VADE
# env should still come up even if 1Password is unreachable.
# See coo-memory/operations/BOOT_TOPOLOGY.md for the contract.
# Anthropic cloud envs may scope custom env vars to the session process
# only; the SessionStart hook in .claude/settings.json picks up the
# slack in that case.
#
# Probe: record token visibility and settings.json state so the next
# session's identity-digest can tell us whether setup-script time is
# a viable bootstrap site (structurally superior to the hook because
# MCP servers pick up env at Claude Code startup, not post-hook).
OP_TOKEN_VISIBLE=false
COO_BOOTSTRAP_RAN=false
if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  OP_TOKEN_VISIBLE=true
  build_log_record PROBE "cloud-setup: OP_SERVICE_ACCOUNT_TOKEN visible at setup time (len=${#OP_SERVICE_ACCOUNT_TOKEN})"
  if bash "$RUNTIME_DIR/scripts/boot/coo-bootstrap.sh"; then
    COO_BOOTSTRAP_RAN=true
    build_log_record OK "cloud-setup: coo-bootstrap completed"
  else
    build_log_record FAIL "cloud-setup: coo-bootstrap failed; continuing without COO identity"
    log "Warning: coo-bootstrap failed; continuing without COO identity."
  fi
else
  build_log_record PROBE "cloud-setup: OP_SERVICE_ACCOUNT_TOKEN unset at setup time; hook fallback required"
  log "OP_SERVICE_ACCOUNT_TOKEN not visible at setup time; SessionStart hook will run coo-bootstrap."
fi

# Pre-warm the external-touch (F6) cache into the snapshot so the first
# session of a fresh container reports F6 ok rather than "cache absent
# — refresh via bin/external-touch.py" (which required a manual handoff
# step on every cold boot). Runs after coo-bootstrap so $GITHUB_MCP_PAT
# is exported; fail-open if either is missing or external-touch.py is
# absent (CI fake-env stages a stub coo-memory without it).
# coo-memory#429 cache-refresh follow-up.
#
# Phase 2 (coo-memory#873) retired ~/.vade/coo-env. The legacy source
# line below stays as belt-and-suspenders for Phase-1-staged snapshots;
# in the Phase-2 path the inline resolver does the work. Pattern mirrors
# coo-harness#446's session-end-transcript-export.sh resolver — op-read
# routed through op-coo-wrap so primary→BACKUP SA-token failover is
# absorbed transparently. Fail-open: missing op CLI, op-read failure, or
# empty value all leave $GITHUB_MCP_PAT unset and external-touch
# degrades to its no-PAT path.
if [ -f "${HOME}/.vade/coo-env" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$HOME/.vade/coo-env" 2>/dev/null || true
fi
_resolve_external_touch_secrets() {
  command -v op >/dev/null 2>&1 || return 0
  [ -n "${GITHUB_MCP_PAT:-}" ] && return 0
  local val
  val="$(op read 'op://COO/github-pat-vade-coo/token' 2>/dev/null)" || return 0
  [ -n "$val" ] && export GITHUB_MCP_PAT="$val"
}
_resolve_external_touch_secrets
prewarm_external_touch_cache "$WORKSPACE_ROOT"

# Durable receipt so sessions can diagnose build-time state without
# parsing logs. coo-identity-digest surfaces this in the SessionStart
# digest block.
GIT_SHA="$(git -C "$RUNTIME_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
build_receipt_write \
  built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  op_token_visible="$OP_TOKEN_VISIBLE" \
  op_installed_at_build="$OP_INSTALLED_AT_BUILD" \
  coo_bootstrap_ran="$COO_BOOTSTRAP_RAN" \
  workspace_mcp_symlinked="$WORKSPACE_MCP_SYMLINKED" \
  identity_link_ok="$IDENTITY_LINK_OK" \
  settings_sync_ok="$SETTINGS_SYNC_OK" \
  git_sha="$GIT_SHA"

build_log_record OK "cloud-setup: complete (op_token=$OP_TOKEN_VISIBLE coo_bootstrap=$COO_BOOTSTRAP_RAN mcp_link=$WORKSPACE_MCP_SYMLINKED id_link=$IDENTITY_LINK_OK)"
log "Done."
