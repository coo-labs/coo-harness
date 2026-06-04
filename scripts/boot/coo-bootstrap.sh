#!/usr/bin/env bash
# COO identity bootstrap for cloud Claude Code sessions.
#
# Called by cloud-setup.sh when OP_SERVICE_ACCOUNT_TOKEN is present.
# Pulls COO credentials from 1Password (vault "COO") via the op CLI,
# writes SSH keys + gitconfig + env file, validates GitHub identity.
# Architecture rationale: MEMO-2026-04-22-03.
#
# Fail modes are loud (exit non-zero) so the caller can decide whether
# to continue the VADE setup without COO identity.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

boot_log_record coo-bootstrap start

# Record every exit path in ~/.vade/coo-bootstrap.log so silent failures
# still leave a trail. The identity-digest hook surfaces the tail of
# this file on each session start.
COO_BOOTSTRAP_STEP="init"
_on_exit() {
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    bootstrap_log_record OK "step=${COO_BOOTSTRAP_STEP} rc=0"
    boot_log_record coo-bootstrap end ok "step=${COO_BOOTSTRAP_STEP}"
  else
    bootstrap_log_record FAIL "step=${COO_BOOTSTRAP_STEP} rc=${rc}"
    boot_log_record coo-bootstrap end fail "step=${COO_BOOTSTRAP_STEP}" "rc=${rc}"
    # Track 4 Phase 1 — coo-harness#66 strip-on-failure (Deliverable c).
    # The env-merge-before-validate ordering (fetch → validate → merge) prevents
    # a wrong-identity PAT from reaching settings.json on a fresh bootstrap.
    # But if a prior bootstrap left a stale/wrong PAT in settings.json and
    # THIS bootstrap fails at validate_coo_identity, the stale PAT must be
    # stripped so the next session fails closed (no PAT) rather than open
    # (wrong-identity PAT). Without this, the poisoned state survives.
    # Only strip if we actually reached fetch_coo_secrets (step is past that).
    case "$COO_BOOTSTRAP_STEP" in
      validate_coo_identity|merge_coo_settings_env|merge_coo_settings_paths|summarize_coo_identity|complete)
        local settings_file="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/settings.json"
        if [ -f "$settings_file" ] && check_cmd python3; then
          log "coo-bootstrap: validate failed; stripping GITHUB_MCP_PAT/GITHUB_TOKEN from $settings_file (#66 fail-closed)"
          python3 -c "
import json, sys, os
path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
    env = cfg.get('env', {})
    stripped = False
    for key in ['GITHUB_MCP_PAT', 'GITHUB_TOKEN']:
        if key in env:
            del env[key]
            stripped = True
    cfg['env'] = env
    with open(path, 'w') as f:
        json.dump(cfg, f, indent=2)
        f.write('\n')
    if stripped:
        print('[coo-bootstrap] stripped GITHUB_MCP_PAT/GITHUB_TOKEN from settings.json', file=sys.stderr)
except Exception as e:
    print(f'[coo-bootstrap] warn: strip failed: {e}', file=sys.stderr)
" "$settings_file" 2>&1 || true
        fi
        ;;
    esac
  fi
  return $rc
}
trap _on_exit EXIT

# Cloud-detection gate: coo-bootstrap is a no-op outside a cloud session.
# Anthropic sets CLAUDE_CODE_REMOTE=true in cloud Claude Code (coo-harness#274).
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  log "coo-bootstrap: CLAUDE_CODE_REMOTE!=true; skipping COO bootstrap."
  COO_BOOTSTRAP_STEP="skip-not-remote"
  bootstrap_log_record SKIP "CLAUDE_CODE_REMOTE!=true"
  _write_skip_reason \
    "CLAUDE_CODE_REMOTE!=true — coo-bootstrap exited before identity load" \
    "Fix: VADE_FORCE_COO_BOOTSTRAP=1 CLAUDE_CODE_REMOTE=true bash $VADE_RUNTIME_DIR/scripts/boot/coo-bootstrap.sh; bash $VADE_RUNTIME_DIR/scripts/boot/integrity-check.sh"
  trap - EXIT
  exit 0
fi

# Baseline COO identity in gitconfig BEFORE any early-exit gate. Signing keys
# stay gated behind write_coo_gitconfig (needs OP_SERVICE_ACCOUNT_TOKEN); this
# minimal write only sets attribution name/email so commits survive no-op-token
# boots without the container default ("Test <test@test.com>").
COO_BOOTSTRAP_STEP="ensure_coo_identity_minimal"
GC="${VADE_COO_GITCONFIG:-${HOME}/.gitconfig}"
mkdir -p "$(dirname "$GC")"
# Belt-and-suspenders guard: refuse to overwrite a gitconfig owned by
# someone other than COO. Catches the edge case where VADE_COO_GITCONFIG
# is unset and GC defaults to a personal $HOME/.gitconfig (manual
# debugging, future regression). Anthropic cloud snapshots ship a baseline
# user.email=noreply@anthropic.com from the harness base image — that
# is overwrite-safe (harness-default, not a real user identity) and
# was the regression that broke 2026-05-13 cloud sessions when the
# original "fresh snapshot has empty gitconfig" assumption failed.
existing_email="$(git config --file "$GC" --get user.email 2>/dev/null || true)"
if [ -n "$existing_email" ] \
   && [ "$existing_email" != "coo@vade-app.dev" ] \
   && [ "$existing_email" != "noreply@anthropic.com" ]; then
  log "coo-bootstrap: refusing to overwrite $GC (existing user.email=$existing_email is not COO)"
  bootstrap_log_record SKIP "refused to overwrite non-COO gitconfig $GC"
  # Cloud-aware loud-skip sentinel. This branch fires when an
  # unexpected user.email squats in $GC — the 2026-05-13 class but
  # for a non-Anthropic baseline. Mac silent-skips remain silent.
  _write_skip_reason \
    "coo-bootstrap refused to overwrite $GC (existing user.email=$existing_email)" \
    "Fix: inspect $GC, remove the non-COO user section (git config --file $GC --remove-section user), then VADE_FORCE_COO_BOOTSTRAP=1 bash \$VADE_RUNTIME_DIR/scripts/boot/coo-bootstrap.sh"
  trap - EXIT
  exit 0
fi
git config --file "$GC" user.name "COO"
git config --file "$GC" user.email "coo@vade-app.dev"

if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  log "coo-bootstrap: OP_SERVICE_ACCOUNT_TOKEN unset; skipping COO identity setup."
  COO_BOOTSTRAP_STEP="skip-no-op-token"
  bootstrap_log_record SKIP "OP_SERVICE_ACCOUNT_TOKEN unset"
  # Cloud-aware loud-skip sentinel. Without OP_SERVICE_ACCOUNT_TOKEN
  # there's no 1Password access and the secret-fetch chain cannot
  # complete. Surface this loudly on cloud so the operator knows to
  # provision the env (Anthropic cloud "Setup script" env var).
  _write_skip_reason \
    "OP_SERVICE_ACCOUNT_TOKEN unset — coo-bootstrap cannot fetch secrets" \
    "Fix: provision OP_SERVICE_ACCOUNT_TOKEN in the Anthropic cloud 'Setup script' env, then resume the container. For ad-hoc recovery, export the token then VADE_FORCE_COO_BOOTSTRAP=1 bash \$VADE_RUNTIME_DIR/scripts/boot/coo-bootstrap.sh"
  trap - EXIT
  exit 0
fi

# Defense in depth behind the SessionStart matcher: secrets don't
# rotate within a container's lifetime, and every artifact this
# script writes (SSH keys, gitconfig, env file, settings.json env
# block) is durable across resumes. Skip the whole pipeline if it
# already ran in this container. Escape hatch:
# VADE_FORCE_COO_BOOTSTRAP=1.
#
# Also verify the settings.json env block actually contains the keys
# a successful bootstrap would have written. A bare marker is not
# enough: if an earlier bootstrap ran under pre-#18 code it left the
# marker without populating GITHUB_MCP_PAT into ~/.claude/settings.json,
# and the session resume came up with github MCP unauth. If any expected
# key is absent, treat the marker as stale and re-run. run-2026-04-22T073717
# hit exactly this: marker present, settings.json env had only
# AGENTMAIL_API_KEY, GITHUB_MCP_PAT was unset, vade-coo identity dark.
COO_BOOT_MARKER="${HOME}/.vade/.coo-bootstrap-done"
_settings_env_complete() {
  local settings="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/settings.json"
  [ -f "$settings" ] || return 1
  check_cmd node || return 0  # node missing: fall back to marker-only trust
  node -e '
    const fs = require("fs");
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8")) || {}; }
    catch { process.exit(1); }
    const env = cfg.env || {};
    // Phase 2 (coo-memory#873): secrets no longer live in settings.json.
    // The required-list is limited to the non-secret path vars that
    // _write_claude_settings_paths persists. The secret vars (GITHUB_MCP_PAT,
    // AGENTMAIL_API_KEY, MEM0_API_KEY, etc.) are exported in-process only
    // by fetch_coo_secrets and must NOT appear here.
    const required = ["VADE_CLOUD_STATE_DIR", "PATH"];
    for (const k of required) { if (!env[k]) process.exit(1); }
    // PATH content sanity: Claude Code does not shell-expand env values,
    // so a literal "${PATH}" in this position is the broken-output of an
    // earlier bootstrap (coo-harness#83 first-cut bug). Force re-run so
    // _write_claude_settings_paths overwrites with the expanded form.
    if (env.PATH.includes("${PATH}")) {
      process.exit(1);
    }
    process.exit(0);
  ' "$settings" 2>/dev/null
}
if [ "${VADE_FORCE_COO_BOOTSTRAP:-0}" != "1" ] \
   && [ -f "$COO_BOOT_MARKER" ] \
   && _settings_env_complete \
   && _cached_pat_still_valid; then
  log "coo-bootstrap: already complete this container; skipping."
  COO_BOOTSTRAP_STEP="skip-marker-present"
  bootstrap_log_record SKIP "marker present at $COO_BOOT_MARKER (cached PAT validated)"
  # Benign skip: identity is already loaded. Clear any stale skip
  # sentinel from a prior failing boot so the digest banner reflects
  # current state.
  _clear_skip_reason
  trap - EXIT
  exit 0
fi
if [ -f "$COO_BOOT_MARKER" ] && [ "${VADE_FORCE_COO_BOOTSTRAP:-0}" != "1" ]; then
  # Marker exists but at least one shortcut precondition failed:
  # settings.json env block is missing a path var, or the cached PAT
  # no longer authenticates as vade-coo (#72 — revocation/scope-change/
  # expiry between snapshots). Fall through to the full bootstrap.
  # Phase 2 (coo-memory#873): coo-env file no longer exists; skip-check
  # no longer requires it.
  if _settings_env_complete && ! _cached_pat_still_valid; then
    log "coo-bootstrap: marker present but cached GITHUB_MCP_PAT no longer authenticates as vade-coo; re-running"
    bootstrap_log_record START "marker stale (cached PAT failed validation); forcing re-run"
  else
    log "coo-bootstrap: marker present but settings.json env incomplete; re-running"
    bootstrap_log_record START "marker stale (settings.json env missing path vars); forcing re-run"
  fi
fi

log "coo-bootstrap: starting"
bootstrap_log_record START "VADE_FORCE_COO_BOOTSTRAP=${VADE_FORCE_COO_BOOTSTRAP:-0}"

COO_BOOTSTRAP_STEP="ensure_op_cli"
ensure_op_cli

# ── SA-token break-glass (Track 4 Phase 1, coo-memory#871 §b) ────────────
# Two-token-overlap support: if OP_SERVICE_ACCOUNT_TOKEN_NEW is set,
# try authenticating with it first. On success, accept it as the active
# token (overwrite the persisted coo-env entry) and unset the _NEW var
# so subsequent runs don't retry the rotation dance. On failure, fall
# back to the current OP_SERVICE_ACCOUNT_TOKEN.
COO_BOOTSTRAP_STEP="sa_token_rotation_check"
if [ -n "${OP_SERVICE_ACCOUNT_TOKEN_NEW:-}" ]; then
  log "coo-bootstrap: OP_SERVICE_ACCOUNT_TOKEN_NEW set; testing rotated token"
  if OP_SERVICE_ACCOUNT_TOKEN="$OP_SERVICE_ACCOUNT_TOKEN_NEW" retry 3 op whoami >/dev/null 2>&1; then
    log "coo-bootstrap: rotated SA token validates; accepting as canonical"
    export OP_SERVICE_ACCOUNT_TOKEN="$OP_SERVICE_ACCOUNT_TOKEN_NEW"
    unset OP_SERVICE_ACCOUNT_TOKEN_NEW
    # Phase 2 (coo-memory#873): coo-env file retired. The new SA token is
    # now in the process env (exported above). No disk persistence needed —
    # on the next container boot the cloud-env config injects the current
    # OP_SERVICE_ACCOUNT_TOKEN. Document the rotation in the bootstrap log.
    log "coo-bootstrap: rotated SA token accepted (in-process only; no coo-env file to update)"
  else
    log "coo-bootstrap: rotated SA token (OP_SERVICE_ACCOUNT_TOKEN_NEW) failed; falling back to current token"
    unset OP_SERVICE_ACCOUNT_TOKEN_NEW
  fi
fi

# Verify the service-account token before attempting any reads. Retry
# to absorb transient 1Password API errors (503s). 5 attempts
# (~15s tolerance) matches _op_to_file's already-tuned budget
# (lib/common.sh _op_to_file) — same flake mode. #76 propagates the
# proven budget here after run-2026-04-25T182206 exhausted the
# prior 3-attempt budget on a transient api.1password.com hiccup.
#
# Track 4 Phase 1 (coo-memory#871 §b1): enhanced op whoami probe with
# JSON-format identity check. We verify the authenticated SA account
# matches the expected vade-coo service account identity. This closes
# the chicken-and-egg break-glass hole: a stale SA token would pass
# the old `op whoami >/dev/null` but return a different-account JSON,
# and all subsequent op reads would silently return wrong-vault data.
COO_BOOTSTRAP_STEP="op_whoami"
if ! retry 5 op whoami >/dev/null; then
  log "FATAL: op whoami failed after retries. Check OP_SERVICE_ACCOUNT_TOKEN and vault access."
  log "  Recovery: OP_SERVICE_ACCOUNT_TOKEN=<new-token> bash ${VADE_RUNTIME_DIR:-/home/user/coo-harness}/scripts/boot/coo-bootstrap.sh"
  log "  See: coo-memory/operations/secrets/README.md §3.6"
  exit 1
fi

# Identity check via JSON output. The SA token's `op whoami --format=json`
# returns the service account's name. We check it matches the expected
# vade-coo pattern (tolerates the exact name changing slightly as long as
# "vade-coo" appears in the ServiceAccount field).
#
# Self-discovering approach: on first successful boot, we accept whatever
# identity the SA token returns and record it. Subsequent boots compare.
# If the identity shifts (token rotated to a different SA), we surface
# the recovery procedure.
#
# Note: `op whoami --format=json` may not be available on all op CLI
# versions. The existing `op whoami` (text) already passed above; this
# is defense-in-depth. Fail-open on parse errors (non-JSON output) so
# a CLI version difference doesn't block boot.
COO_BOOTSTRAP_STEP="op_whoami_identity_check"
_sa_identity_file="${HOME}/.vade/.op-sa-identity"
_whoami_json=""
if _whoami_json="$(op whoami --format=json 2>/dev/null)"; then
  # Extract service account identifier from JSON output. op whoami --format=json
  # returns different schemas across versions; try multiple field names.
  # op 2.31+ live: {'url','URL','user_uuid','account_uuid','user_type','ServiceAccountType'}
  # — `user_uuid` is the stable per-integration identifier and the right
  # unit for SA-rotation detection. Older schemas exposing `ServiceAccount`
  # / `name` are kept for forward-compat across CLI versions.
  _sa_name="$(printf '%s' "$_whoami_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for key in ['user_uuid', 'account_uuid', 'ServiceAccount', 'service_account', 'name', 'email', 'user_email']:
        if key in d and d[key]:
            print(d[key]); break
except Exception:
    pass
" 2>/dev/null || true)"

  if [ -n "$_sa_name" ]; then
    if [ -f "$_sa_identity_file" ]; then
      _expected_identity="$(cat "$_sa_identity_file" 2>/dev/null || true)"
      if [ -n "$_expected_identity" ] && [ "$_sa_name" != "$_expected_identity" ]; then
        log "FATAL: SA identity mismatch (got='${_sa_name}', expected='${_expected_identity}')"
        log "  The OP_SERVICE_ACCOUNT_TOKEN authenticates as a different account than expected."
        log "  Recovery: OP_SERVICE_ACCOUNT_TOKEN=<correct-token> bash ${VADE_RUNTIME_DIR:-/home/user/coo-harness}/scripts/boot/coo-bootstrap.sh"
        log "  See: coo-memory/operations/secrets/README.md §3.6"
        exit 1
      fi
    fi
    # Record the identity for future boots (idempotent write).
    mkdir -p "$(dirname "$_sa_identity_file")"
    printf '%s\n' "$_sa_name" > "$_sa_identity_file" 2>/dev/null || true
    log "1Password service account authenticated: ${_sa_name}"
  else
    # JSON parsed but no identity field found — CLI version difference.
    log "1Password service account authenticated (identity field not found in JSON; skipping identity check)"
  fi
else
  # op whoami --format=json not supported (old CLI) or failed. The
  # plain `op whoami` already passed above, so we know the token works.
  log "1Password service account authenticated: $(op whoami 2>/dev/null | head -1)"
fi
unset _whoami_json _sa_name _sa_identity_file

COO_BOOTSTRAP_STEP="install_coo_ssh_keys"
install_coo_ssh_keys

COO_BOOTSTRAP_STEP="fetch_coo_secrets"
fetch_coo_secrets

COO_BOOTSTRAP_STEP="write_coo_gitconfig"
write_coo_gitconfig

# Make `git push` route through git-push-with-fallback.sh by default
# (coo-harness#67 adoption-as-default). Non-fatal: if the install
# refuses (e.g. user already has a custom $bindir/git), the bootstrap
# continues. Pushes still work via system git; they just won't auto-
# fallback when the cloud git-proxy 403s.
COO_BOOTSTRAP_STEP="install_coo_git_shim"
install_coo_git_shim || log "coo-bootstrap: git shim install skipped/failed; continuing"

# Validate BEFORE merging into ~/.claude/settings.json (#66): a
# wrong-identity PAT must never land in the harness's persistent env
# block. fetch_coo_secrets stages secrets in ~/.vade/coo-env and exports
# them to this shell so validate_coo_identity can hit api.github.com;
# only after that succeeds does merge_coo_settings_env write the PAT
# into settings.json. set -e ensures we exit before merge on validate
# failure.
COO_BOOTSTRAP_STEP="validate_coo_identity"
validate_coo_identity

COO_BOOTSTRAP_STEP="merge_coo_settings_env"
merge_coo_settings_env

# Persist non-secret path state (VADE_CLOUD_STATE_DIR + PATH with the
# snapshot user bindir prepended) into ~/.claude/settings.json env so
# fresh shells inherit it on first try. coo-harness#83.
COO_BOOTSTRAP_STEP="merge_coo_settings_paths"
merge_coo_settings_paths

# Pre-materialize MCP env-file templates to tmpfs with op:// refs replaced
# by the values fetch_coo_secrets just exported. Phase 2 follow-up: kills
# the per-MCP-spawn op-read load (each `op run --env-file` now sees a file
# with no op:// refs and passes through without API calls). 1P account-level
# rate-limit (1000 read+write per 24h on Personal/Teams) was being approached
# by the per-spawn pattern. coo-memory#871 follow-up.
COO_BOOTSTRAP_STEP="materialize_mcp_env_files"
materialize_mcp_env_files

# Cache the GitHub App private key to tmpfs so gh-app-token.sh's installation-
# token mints don't cost an op-read per re-mint. App private key rotates
# yearly; installation tokens last 1 hour; the GitHub App token cache already
# amortizes mints but each cache-miss currently costs 1 op-read of the App
# private key. Tmpfs cache eliminates that per-mint cost for the session.
COO_BOOTSTRAP_STEP="materialize_app_key_cache"
materialize_app_key_cache

COO_BOOTSTRAP_STEP="summarize_coo_identity"
summarize_coo_identity

mkdir -p "$(dirname "$COO_BOOT_MARKER")"
touch "$COO_BOOT_MARKER"

# Clear any stale loud-skip sentinel from a prior failing boot now that
# the full bootstrap has completed successfully. Digest banner picks up
# the absence on the next session-start.
_clear_skip_reason

COO_BOOTSTRAP_STEP="complete"
log "coo-bootstrap: complete"
