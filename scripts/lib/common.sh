#!/usr/bin/env bash
# Shared functions for VADE environment setup scripts.
# Sourced by bootstrap.sh (devcontainer) and cloud-setup.sh (web).

# Status messages from setup scripts go to stderr, not stdout. SessionStart
# hooks capture stdout into the agent's persisted-output digest; routing
# `log` through stderr keeps boot chatter (29+ lines per coo-bootstrap run,
# plus session-start-sync.sh, etc.) out of context while preserving the
# meaningful digest banners (which `echo` to stdout directly). Shell
# convention: stderr for logs, stdout for data. `log_err` is kept as an
# alias for callers that document a stderr-only intent explicitly.
log() { echo "[vade-setup] $*" >&2; }
log_err() { echo "[vade-setup] $*" >&2; }

# Persistent bootstrap log. Every coo-bootstrap invocation appends one
# line with a timestamp, status (OK / FAIL / SKIP), and a short message.
# Identity-digest reads the tail of this file to surface the last
# outcome on each session start, so silent failures leave a trail.
COO_BOOTSTRAP_LOG="${HOME}/.vade/coo-bootstrap.log"

bootstrap_log_record() {
  local status="$1"; shift
  local message="$*"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$COO_BOOTSTRAP_LOG")" 2>/dev/null || return 0
  printf '%s %s %s\n' "$ts" "$status" "$message" >> "$COO_BOOTSTRAP_LOG" 2>/dev/null || return 0
  # Keep the log bounded. 200 lines is ~10 KB, plenty for recent history.
  if [ "$(wc -l < "$COO_BOOTSTRAP_LOG" 2>/dev/null || echo 0)" -gt 200 ]; then
    tail -n 200 "$COO_BOOTSTRAP_LOG" > "${COO_BOOTSTRAP_LOG}.tmp" 2>/dev/null \
      && mv -f "${COO_BOOTSTRAP_LOG}.tmp" "$COO_BOOTSTRAP_LOG" 2>/dev/null
  fi
}

# Cloud-context fingerprint. True when this host is (a) the Anthropic
# cloud snapshot — fingerprinted by /home/user/.vade-cloud-state existing
# as a directory — or (b) a fresh Anthropic snapshot where the gitconfig
# baseline carries user.email=noreply@anthropic.com. Used by
# _write_skip_reason to decide whether a silent coo-bootstrap skip
# should leave a loud surface (cloud: yes; Mac: no — Mac silent-skips
# are intentional, e.g. bare `claude` from any cwd outside a COO context).
#
# Detection deliberately does NOT use OP_SERVICE_ACCOUNT_TOKEN: that env
# var is itself one of the silent-skip gates (line 84 in coo-bootstrap.sh).
# Any cloud failure mode where env didn't propagate (the 2026-05-13
# regression class) would have OP_SERVICE_ACCOUNT_TOKEN unset and would
# read as Mac under a token-based check, silently skip without a
# sentinel, and reproduce the same opaque failure. Filesystem and
# gitconfig fingerprints are reliable across that class.
_is_cloud_context() {
  [ -d /home/user/.vade-cloud-state ] && return 0
  local gc="${VADE_COO_GITCONFIG:-${HOME}/.gitconfig}"
  if [ -f "$gc" ]; then
    local em
    em="$(git config --file "$gc" --get user.email 2>/dev/null || true)"
    [ "$em" = "noreply@anthropic.com" ] && return 0
  fi
  return 1
}

# Loud-skip surfacing. When coo-bootstrap takes a silent-skip path in a
# cloud context, write a sentinel file the identity-digest hook reads
# to surface the skip reason + recovery hint at the TOP of the digest
# banner. Closes the surface gap that allowed the 2026-05-13 boot-skip
# incident to run for ~30 min as generic Claude Code before BDFL caught
# it. On non-cloud contexts (Mac, local devcontainer outside COO mode)
# the sentinel is not written — silent skips remain silent because the
# skip is the correct behavior outside an explicit COO session.
#
# Sentinel format: two-line text, "reason" then "hint". The digest hook
# reads via head/sed; keep both lines short and shell-safe.
#
# Idempotent: callers overwrite on every skip pass so the file always
# reflects the most recent skip. The digest hook clears it when
# bootstrap eventually completes ok (see coo-identity-digest.sh banner).
VADE_COO_SKIP_SENTINEL="${HOME}/.vade/.coo-bootstrap-skip-reason"
_write_skip_reason() {
  local reason="$1" hint="$2"
  _is_cloud_context || return 0
  mkdir -p "$(dirname "$VADE_COO_SKIP_SENTINEL")" 2>/dev/null || return 0
  {
    printf '%s\n' "$reason"
    printf '%s\n' "$hint"
  } > "$VADE_COO_SKIP_SENTINEL" 2>/dev/null || return 0
}

# Clear the loud-skip sentinel. Called on a successful bootstrap so a
# subsequent digest banner doesn't show stale skip reasons after the
# operator (or VADE_FORCE_COO_BOOTSTRAP=1 re-run) recovers the session.
_clear_skip_reason() {
  rm -f "$VADE_COO_SKIP_SENTINEL" 2>/dev/null || true
}

# Durable cloud-state directory. Lives under /home/user/ so it survives
# the snapshot-build → session-resume transition; ~/.vade/ is under
# /root/ in the cloud image and gets fresh on every session boot, which
# is useful for session-scope logs but useless for recording what
# cloud-setup.sh actually did at build time. Keep session-scope state in
# ~/.vade/, snapshot-scope state here. Overridable so local-setup.sh
# can point it at ~/.vade/local-state on macOS.
VADE_CLOUD_STATE_DIR="${VADE_CLOUD_STATE_DIR:-/home/user/.vade-cloud-state}"
VADE_BUILD_LOG="${VADE_CLOUD_STATE_DIR}/build.log"
VADE_SETUP_RECEIPT="${VADE_CLOUD_STATE_DIR}/setup-receipt.json"

# coo-harness working tree path. Settings.json hook commands resolve via
# "$VADE_RUNTIME_DIR/scripts/<subfolder>/<script>.sh"; the var is injected
# into Claude Code's process at every launch via the Anthropic container UI
# .env block (coo-harness#274). Cloud default is /home/user/coo-harness;
# the fallback here keeps non-cloud invocations (CI, ad-hoc shells) working.
VADE_RUNTIME_DIR="${VADE_RUNTIME_DIR:-/home/user/coo-harness}"

# coo-memory working tree path. Sibling parity with VADE_RUNTIME_DIR;
# gh-coo-wrap.sh and various skills/hooks resolve memory-repo paths via
# $VADE_COO_MEMORY_DIR. Same UI .env-block injection mechanism as above.
VADE_COO_MEMORY_DIR="${VADE_COO_MEMORY_DIR:-/home/user/coo-memory}"

# Same shape as bootstrap_log_record but writes to the durable build log.
# Use from cloud-setup.sh and anything else running at snapshot-build
# time — PROBE entries, step transitions, timing — so sessions can
# diagnose "did build time actually run" without archaeology.
build_log_record() {
  local status="$1"; shift
  local message="$*"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! mkdir -p "$VADE_CLOUD_STATE_DIR" 2>/dev/null; then
    log "Warning: could not create $VADE_CLOUD_STATE_DIR; build log entry dropped"
    return 0
  fi
  if ! printf '%s %s %s\n' "$ts" "$status" "$message" >> "$VADE_BUILD_LOG" 2>/dev/null; then
    log "Warning: could not append to $VADE_BUILD_LOG; entry dropped"
    return 0
  fi
  if [ "$(wc -l < "$VADE_BUILD_LOG" 2>/dev/null || echo 0)" -gt 500 ]; then
    tail -n 500 "$VADE_BUILD_LOG" > "${VADE_BUILD_LOG}.tmp" 2>/dev/null \
      && mv -f "${VADE_BUILD_LOG}.tmp" "$VADE_BUILD_LOG" 2>/dev/null
  fi
}

# Per-session structured boot log. One JSON line per event, written by
# every SessionStart/Stop hook at key phases (start, major step, end).
# Lets integrity-check.sh reconstruct the boot timeline from a single
# file rather than correlating across claude-code.log, env-manager.log,
# and the per-script logs. Safe to call without node (pure printf).
#
# Usage:
#   boot_log_record session-start-sync start
#   boot_log_record session-start-sync sync_claude_config ok
#   boot_log_record session-start-sync end ok duration_ms=9
VADE_BOOT_LOG="${HOME}/.vade/boot.log"

# Minimal JSON-string escape: backslash, double-quote, and the four
# control chars that bash callers might plausibly pass (newline, CR,
# tab, backspace). Keeps each boot.log line a valid JSON object even
# when callers pass unescaped detail strings (e.g. shell command output,
# error messages with quotes).
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\b'/\\b}"
  printf '%s' "$s"
}

boot_log_record() {
  local script="$1" phase="$2"; shift 2
  local status="${1:-}"
  [ "$#" -gt 0 ] && shift
  local extras="" k v
  for kv in "$@"; do
    case "$kv" in
      *=*)
        k="$(_json_escape "${kv%%=*}")"
        v="$(_json_escape "${kv#*=}")"
        extras="$extras,\"$k\":\"$v\""
        ;;
    esac
  done
  local ts ok_field=""
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  case "$status" in
    ok|OK)   ok_field=',"ok":true' ;;
    fail|FAIL) ok_field=',"ok":false' ;;
    skip|SKIP) ok_field=',"ok":true,"skipped":true' ;;
    "")      ok_field='' ;;
    *)       ok_field=",\"status\":\"$(_json_escape "$status")\"" ;;
  esac
  mkdir -p "$(dirname "$VADE_BOOT_LOG")" 2>/dev/null || return 0
  printf '{"ts":"%s","session":"%s","script":"%s","phase":"%s"%s%s}\n' \
    "$ts" "$(_json_escape "${CLAUDE_CODE_SESSION_ID:-unknown}")" \
    "$(_json_escape "$script")" "$(_json_escape "$phase")" \
    "$ok_field" "$extras" \
    >> "$VADE_BOOT_LOG" 2>/dev/null || return 0
  # Bounded retention: 1000 lines ~ 100 KB, a few hundred sessions worth.
  if [ "$(wc -l < "$VADE_BOOT_LOG" 2>/dev/null || echo 0)" -gt 1000 ]; then
    tail -n 1000 "$VADE_BOOT_LOG" > "${VADE_BOOT_LOG}.tmp" 2>/dev/null \
      && mv -f "${VADE_BOOT_LOG}.tmp" "$VADE_BOOT_LOG" 2>/dev/null
  fi
}

# Write a JSON receipt at the end of cloud-setup.sh recording what
# succeeded. coo-identity-digest reads this to surface build-time state
# in the SessionStart digest block; missing file = cloud-setup didn't
# run (or failed before reaching the end). Accepts pairs of key=value
# args; values are emitted as booleans when "true"/"false", as numbers
# when all digits, as JSON strings otherwise.
#
# Usage:
#   build_receipt_write \
#     built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
#     op_token_visible=true \
#     coo_bootstrap_ran=false \
#     git_sha=abc123
build_receipt_write() {
  if ! mkdir -p "$VADE_CLOUD_STATE_DIR" 2>/dev/null; then
    log "Warning: could not create $VADE_CLOUD_STATE_DIR; setup-receipt skipped"
    return 0
  fi
  if ! check_cmd node; then
    log "Warning: node missing; writing receipt as plain key=value list"
    if ! printf '%s\n' "$@" > "$VADE_SETUP_RECEIPT" 2>/dev/null; then
      log "Warning: could not write $VADE_SETUP_RECEIPT; receipt skipped"
    fi
    return 0
  fi
  node -e '
    const fs = require("fs");
    const [dst, ...pairs] = process.argv.slice(1);
    const out = {};
    for (const p of pairs) {
      const eq = p.indexOf("=");
      if (eq < 0) continue;
      const k = p.slice(0, eq);
      const v = p.slice(eq + 1);
      if (v === "true") out[k] = true;
      else if (v === "false") out[k] = false;
      else if (/^-?\d+$/.test(v)) out[k] = Number(v);
      else out[k] = v;
    }
    fs.writeFileSync(dst, JSON.stringify(out, null, 2) + "\n");
  ' "$VADE_SETUP_RECEIPT" "$@" 2>/dev/null || {
    log "Warning: build_receipt_write via node failed; skipping"
    return 0
  }
  chmod 644 "$VADE_SETUP_RECEIPT" 2>/dev/null || true
}

# Retry a command with exponential backoff. Absorbs transient 1Password
# API failures (503s, network blips) that killed past bootstrap runs —
# one 503 on `op read` under `set -euo pipefail` was enough to bail the
# whole chain silently. Stdout of the successful attempt is passed
# through unchanged so callers can still do `x="$(retry 3 op read ref)"`.
# All log output goes to stderr.
#
# Usage: retry <tries> <cmd...>
#   retry 3 op read 'op://COO/foo/credential'
#   retry 3 op whoami >/dev/null
retry() {
  local tries="${1:-3}"
  shift
  local delay=1 attempt=0 rc=0
  local err_file
  err_file="$(mktemp 2>/dev/null)" || { "$@"; return $?; }
  while [ "$attempt" -lt "$tries" ]; do
    attempt=$((attempt+1))
    # Capture the actual exit of "$@" via `|| rc=$?`. The prior
    # `if "$@"; then ...; fi; rc=$?` pattern is a bash gotcha: after
    # an if-compound where no branch was taken, $? is 0, not the
    # failed command's exit. That made `retry` log rc=0 on every
    # retry line AND made `return "$rc"` after a full-failure loop
    # return 0, silently signalling success. Callers like `_op_to_file`
    # with `if ! content="$(retry 3 op read "$ref")"; then return 1`
    # never saw the failure: content came back empty, the ssh key
    # file got a bare newline, and install_coo_ssh_keys FATALed at
    # the fingerprint check instead of upstream at _op_to_file.
    # Witnessed on snapshot run-2026-04-22T091701.
    rc=0
    "$@" 2>"$err_file" || rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f "$err_file"
      return 0
    fi
    if [ "$attempt" -lt "$tries" ]; then
      log_err "  retry ${attempt}/${tries} for: $* (rc=$rc; sleeping ${delay}s)"
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done
  local last_err
  last_err="$(tr '\n' ' ' < "$err_file" 2>/dev/null | cut -c1-240)"
  log_err "  FAIL after ${tries} attempts: $* (last err: ${last_err:-<empty>}; final rc=$rc)"
  cat "$err_file" >&2 2>/dev/null || true
  rm -f "$err_file"
  return "$rc"
}

# Phase 2 (coo-memory#873): coo-env plaintext mirror retired.
# Secrets are exported to the process env in-memory only by fetch_coo_secrets;
# no disk persistence under ~/.vade/coo-env. The autosource block that was here
# is removed — hook subprocesses that need GITHUB_TOKEN / GITHUB_MCP_PAT /
# AGENTMAIL_API_KEY must obtain them via op read or wait_for_coo_bootstrap,
# not by sourcing a plaintext file. The VADE_NO_COO_ENV_AUTOSOURCE opt-out
# env var is retained for backward compat in test scripts that set it, but
# the source call itself is gone so it has no effect.

# Block until coo-bootstrap.sh reaches a terminal state (OK/FAIL/SKIP)
# in this session, then re-source coo-env so vars written during the
# wait land in the calling process. SessionStart hooks run in parallel,
# so any hook that consumes GITHUB_TOKEN / GITHUB_MCP_PAT / AGENTMAIL_API_KEY
# (e.g. discussions-digest, coo-identity-digest's posture block) would
# otherwise sample before bootstrap finishes and falsely report
# "unset / degraded". Fast-exits after a 2s grace if no coo-bootstrap.sh
# process is running (covers standalone invocations, hook disabled,
# and bootstrap-already-finished cases).
#
# Args: $1 = timeout in seconds (default 60)
# Exposes:
#   VADE_BOOTSTRAP_WAIT_SAW_FRESH  — 1 if a fresh terminal state was seen, else 0
#   VADE_BOOTSTRAP_WAIT_ELAPSED    — seconds actually waited
#   VADE_BOOTSTRAP_WAIT_TIMEOUT    — configured timeout
# Always returns 0.
wait_for_coo_bootstrap() {
  local timeout="${1:-60}"
  local bootstrap_log="${HOME}/.vade/coo-bootstrap.log"
  local start_epoch elapsed=0
  start_epoch="$(date -u +%s)"
  VADE_BOOTSTRAP_WAIT_SAW_FRESH=0
  VADE_BOOTSTRAP_WAIT_TIMEOUT="$timeout"
  while [ "$elapsed" -lt "$timeout" ]; do
    if [ -f "$bootstrap_log" ]; then
      local last_line last_ts last_state last_epoch
      last_line="$(tail -n 1 "$bootstrap_log" 2>/dev/null || true)"
      last_ts="${last_line%% *}"
      last_state="$(printf '%s' "$last_line" | awk '{print $2}')"
      case "$last_state" in
        OK|FAIL|SKIP)
          # Portable ISO-8601 → epoch via node (already a hard dep of
          # the digest scripts; `date -d` is GNU-only).
          last_epoch="$(node -e 'const t=Date.parse(process.argv[1]); process.stdout.write(isNaN(t)?"0":String(Math.floor(t/1000)))' "$last_ts" 2>/dev/null || echo 0)"
          if [ "$last_epoch" -ge "$start_epoch" ]; then
            VADE_BOOTSTRAP_WAIT_SAW_FRESH=1
            break
          fi
          ;;
      esac
    fi
    if [ "$elapsed" -ge 2 ] && ! pgrep -f coo-bootstrap.sh >/dev/null 2>&1; then
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  VADE_BOOTSTRAP_WAIT_ELAPSED="$elapsed"
  # Phase 2 (coo-memory#873): coo-env retired; no re-source here.
  # Secrets live in process env (exported by fetch_coo_secrets) — hooks
  # that waited for bootstrap now inherit them via normal env inheritance.
  return 0
}

check_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_dirs() {
  mkdir -p "$HOME/.vade/library/canvases" \
           "$HOME/.vade/library/entities" 2>/dev/null || \
    log "Warning: could not create $HOME/.vade subdirs. Check permissions."
}

install_deps() {
  local dir="${1:-.}"
  if [ -f "$dir/package.json" ]; then
    log "Installing npm dependencies in $dir..."
    (cd "$dir" && npm install --no-audit --no-fund)
  fi
}

# Mirror the committed .claude/ directory into Claude Code's user-scope
# config dir. Subdirs (skills/, agents/, commands/, hooks/, output-styles/) are
# symlinked so edits in the repo are live next SessionStart.
# settings.json is copied so coo-bootstrap can mutate the env block
# without dirtying the git working tree. Plans/, projects/, todos/,
# statsig/ and other Claude Code-managed dirs are left alone.
#
# Subdir strategy: Claude Code itself ships some of these dirs
# pre-populated (e.g. ~/.claude/skills/session-start-hook/). Replacing
# a real directory with a symlink via `ln -snf` silently nests
# instead, so when the destination already exists as a real dir we
# merge per-entry: each source child is symlinked in alongside the
# built-ins. Name collisions with a built-in are skipped with a
# warning rather than clobbered.
#
# settings.json: the source tree's copy is the source of truth for
# hooks and other top-level keys, but the destination's `.env` is
# populated at runtime by coo-bootstrap and must survive a re-sync
# (coo-bootstrap's idempotency marker short-circuits re-merging on
# subsequent runs). We preserve dest env via a node-based merge when
# both files exist; otherwise we fall back to a plain copy.
sync_claude_config() {
  local src="${1:-$VADE_RUNTIME_DIR/.claude}"
  local dst="${2:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
  if [ ! -d "$src" ]; then
    log "sync_claude_config: source $src missing; skipping"
    return 0
  fi
  mkdir -p "$dst"
  for sub in skills agents commands hooks output-styles; do
    [ -d "$src/$sub" ] || continue
    _sync_claude_subdir "$src/$sub" "$dst/$sub"
  done
  if [ -f "$src/settings.json" ]; then
    _sync_claude_settings "$src/settings.json" "$dst/settings.json"
  fi
  log "Synced $src → $dst (subdirs symlinked, settings.json copied)"
}

_sync_claude_subdir() {
  local src_sub="$1" dst_sub="$2"
  if [ -L "$dst_sub" ] || [ ! -e "$dst_sub" ]; then
    ln -snf "$src_sub" "$dst_sub"
    return 0
  fi
  # Destination exists as a real directory (e.g. Claude Code built-in
  # skills). Merge per-entry so both coexist.
  local entry name target
  for entry in "$src_sub"/*; do
    [ -e "$entry" ] || continue
    name="$(basename "$entry")"
    target="$dst_sub/$name"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
      log "  warn: $target exists and is not a symlink; skipping to avoid clobbering built-in"
      continue
    fi
    ln -snf "$entry" "$target"
  done
}

# Print the list of repos to aggregate, one per line.
#
# Reads coo-harness/scripts/aggregator.yml (a flat YAML list under
# the `repos:` key). Falls back to the hardcoded default
# `coo-harness coo-memory` if the manifest is missing or unparseable,
# preserving back-compat with pre-aggregator-config snapshots and
# unblocking CI runs that stage a sandbox without the manifest.
#
# Resolves the manifest path from this file's location (one dir up
# from lib/common.sh), not from $WORKSPACE_ROOT or a caller-supplied
# $RUNTIME_DIR, so the manifest travels with the boot kernel
# (coo-harness) and the helper is callable from any of cloud-setup.sh,
# session-start-sync.sh, or local-setup.sh without extra wiring.
#
# Prefers yq when present (already on the Ubuntu runner and cloud
# image); falls back to an awk parse that recognises `- name` entries
# under a `repos:` key. The awk path tolerates leading whitespace and
# inline `# comment` suffixes, but it intentionally does NOT support
# flow-style sequences (`repos: [a, b]`) — keep the file block-style.
load_aggregator_repos() {
  # Resolve sibling-of-common.sh: this file lives at coo-harness/scripts/lib/,
  # so the manifest is one directory up. Independent of caller's $RUNTIME_DIR
  # / $SCRIPT_DIR so the helper works from cloud-setup, session-start-sync,
  # and local-setup without each having to set RUNTIME_DIR.
  local manifest="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/aggregator.yml"
  if [ ! -f "$manifest" ]; then
    log_err "  warn: aggregator manifest not found at $manifest; falling back to default repo list"
    printf '%s\n' coo-harness coo-memory
    return 0
  fi
  local repos=""
  if check_cmd yq; then
    repos="$(yq -r '.repos[]' "$manifest" 2>/dev/null || true)"
  fi
  if [ -z "$repos" ]; then
    # Awk fallback: walk the file, capture `- entry` lines that follow
    # the `repos:` key, stop on the next top-level key or EOF.
    repos="$(awk '
      /^[[:space:]]*#/ { next }
      /^repos:[[:space:]]*$/ { in_block=1; next }
      in_block && /^[^[:space:]-]/ { in_block=0 }
      in_block && /^[[:space:]]*-[[:space:]]*/ {
        sub(/^[[:space:]]*-[[:space:]]*/, "")
        sub(/[[:space:]]*#.*$/, "")
        sub(/[[:space:]]+$/, "")
        if (length($0) > 0) print
      }
    ' "$manifest" 2>/dev/null || true)"
  fi
  if [ -z "$repos" ]; then
    log_err "  warn: aggregator manifest at $manifest parsed empty; falling back to default repo list"
    printf '%s\n' coo-harness coo-memory
    return 0
  fi
  printf '%s\n' "$repos"
}

# Aggregate per-repo .claude/{commands,agents,skills,hooks,output-styles} into the
# workspace .claude/ via per-file symlinks.
#
# Why: under the data-ownership rule (MEMO 2026-04-25-02), slash
# commands and skills live in the repo whose data they manipulate
# (e.g. /memo-query in coo-memory). For Ven to invoke them
# regardless of which repo he launched Claude Code from, the workspace
# .claude/ must surface every per-repo primitive in one place. This
# function does that with per-file symlinks — Claude Code resolves the
# symlink and finds the command in its source repo, no copy drift.
#
# Conflict policy: first-source-wins (sources are walked in arg order).
# Conflicts are logged but don't fail. Real-file conflicts (a non-symlink
# at the destination) are skipped to avoid clobbering harness built-ins.
#
# Usage: aggregate_workspace_claude_config <workspace_root> <dst_root> <repo1> [repo2] ...
#   workspace_root  — directory containing the repo dirs (e.g. /home/user
#                     on cloud, ~/GitHub/coo-labs on local).
#   dst_root        — where the aggregated .claude/ should land. On cloud
#                     this is $HOME/.claude (user-scope); on local this is
#                     $WORKSPACE_ROOT/.claude (project-scope).
#   repo1, ...      — repo directory names under workspace_root. The
#                     canonical source for this list is the manifest at
#                     coo-harness/scripts/aggregator.yml (see
#                     load_aggregator_repos); callers should read it from
#                     there rather than hardcoding repo names.
aggregate_workspace_claude_config() {
  local workspace_root="$1"; shift
  local dst_root="$1"; shift
  mkdir -p "$dst_root"
  local sub
  for sub in commands agents skills hooks output-styles; do
    local dst_sub="$dst_root/$sub"
    # If dst is a symlink (legacy single-source layout), materialize it
    # into a real directory so we can union multiple sources into it.
    if [ -L "$dst_sub" ]; then
      local prev_target; prev_target="$(readlink -f "$dst_sub" 2>/dev/null || true)"
      rm "$dst_sub"
      mkdir -p "$dst_sub"
      if [ -n "$prev_target" ] && [ -d "$prev_target" ]; then
        local prev_entry prev_name
        for prev_entry in "$prev_target"/*; do
          [ -e "$prev_entry" ] || continue
          prev_name="$(basename "$prev_entry")"
          ln -snf "$prev_entry" "$dst_sub/$prev_name"
        done
      fi
    else
      mkdir -p "$dst_sub"
    fi
    local repo src entry name target
    for repo in "$@"; do
      src="$workspace_root/$repo/.claude/$sub"
      [ -d "$src" ] || continue
      for entry in "$src"/*; do
        [ -e "$entry" ] || continue
        name="$(basename "$entry")"
        target="$dst_sub/$name"
        if [ -L "$target" ]; then
          local cur; cur="$(readlink -f "$target" 2>/dev/null || true)"
          local want; want="$(readlink -f "$entry" 2>/dev/null || true)"
          [ "$cur" = "$want" ] && continue
          # First-source-wins; later repo skipped with note.
          log "  aggregate: $sub/$name conflict; keeping $cur, skipping $want"
          continue
        fi
        if [ -e "$target" ] && [ ! -L "$target" ]; then
          log "  warn: $target exists and is not a symlink; skipping"
          continue
        fi
        ln -snf "$entry" "$target"
      done
    done
  done
  log "Aggregated workspace .claude/ from: $*"
}

_sync_claude_settings() {
  local src_file="$1" dst_file="$2"
  if [ -f "$dst_file" ] && check_cmd node; then
    if node -e '
      const fs = require("fs");
      const [srcPath, dstPath] = process.argv.slice(1);
      const src = JSON.parse(fs.readFileSync(srcPath, "utf8"));
      let dstEnv = {};
      try {
        const dst = JSON.parse(fs.readFileSync(dstPath, "utf8")) || {};
        dstEnv = dst.env || {};
      } catch {}
      const merged = Object.assign({}, src);
      merged.env = Object.assign({}, src.env || {}, dstEnv);
      fs.writeFileSync(dstPath, JSON.stringify(merged, null, 2) + "\n");
    ' "$src_file" "$dst_file" 2>/dev/null; then
      chmod 600 "$dst_file"
      return 0
    fi
    log "  warn: settings.json merge via node failed; falling back to plain copy"
  fi
  cp -f "$src_file" "$dst_file"
  chmod 600 "$dst_file"
}

# Ensure /home/user/.mcp.json is a symlink to the runtime repo's
# .mcp.json. Claude Code loads project-scope .mcp.json from its cwd,
# and in the cloud env cwd is /home/user, which has no .mcp.json of
# its own — so project MCPs stay dark even when env vars are populated.
# Symlinking to coo-harness/.mcp.json fixes this and keeps a single
# source of truth: the same file loads at cwd=/home/user (via symlink)
# and at cwd=/home/user/coo-harness (natively). Before MEMO 2026-04-22-08
# the shared config lived in a separate workspace-mcp.json; the two
# were unified.
# Idempotent: if the symlink already points at the right target, no-op.
ensure_workspace_mcp_config() {
  local src="${1:-$VADE_RUNTIME_DIR/.mcp.json}"
  local dst="${2:-$(dirname "$VADE_RUNTIME_DIR")/.mcp.json}"
  if [ ! -f "$src" ]; then
    log "mcp-link: source $src missing; skipping"
    return 0
  fi
  if [ -L "$dst" ] && [ "$(readlink -f "$dst" 2>/dev/null)" = "$(readlink -f "$src" 2>/dev/null)" ]; then
    return 0
  fi
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    log "mcp-link: $dst exists and is not a symlink; leaving it alone"
    return 0
  fi
  ln -snf "$src" "$dst"
  log "mcp-link: linked $dst → $src"
}

# Ensure /home/user/CLAUDE.md symlinks to coo-memory/CLAUDE.md so
# Claude Code's built-in memory auto-loader picks up the COO identity
# instructions at session start (cwd=/home/user). Without this,
# identity surfaces only via coo-identity-digest's echo, which fires
# after MCP resolution and isn't visible to the harness memory system.
# Idempotent, mirrors ensure_workspace_mcp_config's guards.
ensure_workspace_identity_link() {
  local src="${1:-$VADE_COO_MEMORY_DIR/CLAUDE.md}"
  local dst="${2:-$(dirname "$VADE_COO_MEMORY_DIR")/CLAUDE.md}"
  if [ ! -f "$src" ]; then
    log "identity-link: source $src missing; skipping"
    return 0
  fi
  if [ -L "$dst" ] && [ "$(readlink -f "$dst" 2>/dev/null)" = "$(readlink -f "$src" 2>/dev/null)" ]; then
    return 0
  fi
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    log "identity-link: $dst exists and is not a symlink; leaving it alone"
    return 0
  fi
  ln -snf "$src" "$dst"
  log "identity-link: linked $dst → $src"
}

print_versions() {
  local claude_version

  if check_cmd claude; then
    claude_version="$(claude --version 2>/dev/null || true)"
    if [ -n "$claude_version" ]; then
      claude_version="$claude_version (run: claude login if needed)"
    else
      claude_version="available (run: claude login)"
    fi
  else
    claude_version="not available"
  fi

  log "Tool versions:"
  log "  node: $(node --version 2>/dev/null || echo 'not found')"
  log "  npm:  $(npm --version 2>/dev/null || echo 'not found')"
  log "  git:  $(git --version 2>/dev/null || echo 'not found')"
  log "  claude: $claude_version"
}

# ===== COO identity bootstrap helpers =====
# Used by scripts/coo-bootstrap.sh when OP_SERVICE_ACCOUNT_TOKEN is set.
# Fetch COO identity material from a 1Password vault named "COO" via the
# op CLI. Vault/item contract and the cloud-env boot flow are documented
# in coo-memory/operations/BOOT_TOPOLOGY.md.

OP_VERSION_DEFAULT="2.31.0"
GH_VERSION_DEFAULT="2.91.0"
# Mem0 stdio MCP server. Bypasses the Node `undici` DNS-cache-overflow
# failure that kills Claude Code's MCP HTTP transport against
# api.mem0.ai (coo-harness#36/#109). Pinned because the upstream repo
# (mem0ai/mem0-mcp) was archived in 2025-12 — bump deliberately.
MEM0_MCP_SERVER_VERSION_DEFAULT="0.2.1"
# Quarto CLI for markdown → slide-deck rendering. Bundles its own
# pandoc and deno. Introduced for the 2026-shiffrin-conference deck;
# kept as a standing tool for any future markdown-to-{pptx,pdf}
# workflow. ~131 MB tarball — the largest single tool in the snapshot.
# Track upstream at github.com/quarto-dev/quarto-cli.
QUARTO_VERSION_DEFAULT="1.9.37"
# PyYAML — system-Python YAML parser. Required by schema-fetch-secrets.py
# (boot path; fail-closed without it) and by every hook that parses the
# secrets schema (boot-brake-guard.py, skill-yaml-guard.sh,
# bash-token-guard.sh, preuse-agent-env-scrub.sh, postuse-bash-redactor.sh).
# Currently satisfied by the Debian base image's python3-yaml package; this
# pin defends against a future image rebuild silently dropping it.
# ensure_pyyaml installs to /home/user/.local/lib/python3.X/site-packages
# via `pip install --user --break-system-packages` with PYTHONUSERBASE
# pointed at /home/user/.local so the install survives snapshot → resume.
# coo-harness#440.
PYYAML_VERSION_DEFAULT="6.0.2"
# Binary vendor bundle. Single tarball published by
# .github/workflows/publish-binary-vendor.yml containing op + gh + uv +
# mem0-mcp-server (with mem0's uv-managed venv tree) at production
# layout under .local/. ensure_binaries_from_vendor curls it from this
# repo's GitHub Release asset endpoint with $GITHUB_MCP_PAT and untars
# to /home/user/, replacing four per-CDN fetches with one
# release-assets.githubusercontent.com fetch. github.com-class origin,
# already-authenticated, snapshot-cache compatible (the untarred
# /home/user/.local/ tree survives snapshot → resume). Adopted via B1
# reframe of briefing 004-cloud-binary-vendor (docker-pull variant
# infeasible on cloud_default; see follow-up issue).
BINARY_VENDOR_REPO_DEFAULT="coo-labs/coo-harness"
BINARY_VENDOR_TAG_DEFAULT="binary-vendor-latest"
BINARY_VENDOR_ASSET_DEFAULT="binary-vendor.tar.gz"
# Hardcoded production fingerprints; env-overridable so the bootstrap-
# regression CI (.github/workflows/bootstrap-regression.yml) can
# substitute fixture-key fingerprints without forking install_coo_ssh_keys.
# Production paths leave these unset and fall through to the literals.
COO_AUTH_FP_EXPECTED="${COO_AUTH_FP_EXPECTED:-SHA256:9vxJc6c69L8eaR6CvwdZoYDco24W6yN6GkKwnsm8Uys}"
COO_SIGN_FP_EXPECTED="${COO_SIGN_FP_EXPECTED:-SHA256:pZeA8xycAtIsVGwhMzR3mg4KG05n9ksFuy4F1ZVXn3A}"

# Snapshot-persistent user bindir. Cloud harness runs as root and the
# /home/user/ tree survives snapshot → resume; local Mac has no
# /home/user/ and runs as the operator's user, so $HOME/.local/bin is
# the right target. Both ensure_op_cli and ensure_gh_cli install here.
#
# Env override: VADE_BINDIR_OVERRIDE lets the bootstrap-regression CI
# point at a sandbox dir pre-populated with mock op/gh binaries so
# ensure_*_cli short-circuits without touching /home/user/.local/bin.
# Production paths leave it unset.
_snapshot_user_bindir() {
  if [ -n "${VADE_BINDIR_OVERRIDE:-}" ]; then
    printf '%s' "$VADE_BINDIR_OVERRIDE"
    return
  fi
  if [ "$(id -u)" = "0" ] && [ -d /home/user ]; then
    printf '/home/user/.local/bin'
  else
    printf '%s/.local/bin' "$HOME"
  fi
}

# Fetch the consolidated binary vendor bundle (op + gh + uv +
# mem0-mcp-server) from this repo's GitHub Release and untar it into
# the snapshot-persistent .local/ tree. One github.com-class fetch
# replaces four per-CDN fetches; ensure_op_cli / ensure_gh_cli /
# ensure_mem0_mcp_server short-circuit on `check_cmd` after this runs.
#
# Cloud-only (root + /home/user). On macOS / non-cloud the bundle's
# Linux binaries and absolute /home/user/.local/... paths don't apply,
# so this function returns 0 without action and the per-binary
# ensure_*_cli paths handle install (brew on macOS, direct fetch on
# Linux non-cloud).
#
# Best-effort. On any failure (curl, sha mismatch, untar) returns 1
# without mutating the bindir; cloud-setup.sh logs the warning and
# continues to ensure_*_cli direct-fetch as fallback. Per the briefing
# 004 lean (item 4): keep direct-fetch fallback for the first iteration
# until ghcr.io / release-asset reliability is measured in production.
#
# Disable: set VADE_BINARY_VENDOR_DISABLE=1 to skip entirely. Used by
# bootstrap-regression CI where the release-asset fetch isn't mocked.
#
# Pin: BINARY_VENDOR_BUNDLE_SHA256 (set from versions.lock or env)
# is sha256-verified against the downloaded tarball before untar.
# Without a pin, the function logs a warning and proceeds — first-PR
# adoption ships before the first publish has produced a SHA.
ensure_binaries_from_vendor() {
  if [ "${VADE_BINARY_VENDOR_DISABLE:-0}" = "1" ]; then
    log "binary vendor: VADE_BINARY_VENDOR_DISABLE=1; skipping"
    return 0
  fi

  # Cloud-only gate. Local Mac and CI sandboxes (non-root or no
  # /home/user) fall through to the per-binary ensure_*_cli paths.
  if [ "$(id -u)" != "0" ] || [ ! -d /home/user ]; then
    return 0
  fi

  local bindir
  bindir="$(_snapshot_user_bindir)"
  case ":$PATH:" in
    *":$bindir:"*) ;;
    *) export PATH="$bindir:$PATH" ;;
  esac

  # Idempotent short-circuit: if all four binaries are already present
  # (prior bundle untar, Dockerfile bake, or per-binary ensure_*_cli),
  # skip the fetch. Saves the round-trip on every snapshot rebuild and
  # keeps the cloud-setup.sh log quiet on the steady-state path.
  if check_cmd op && check_cmd gh && check_cmd uv && check_cmd mem0-mcp-server; then
    log "binary vendor: all four binaries present at $bindir; skipping fetch"
    return 0
  fi

  if [ -z "${GITHUB_MCP_PAT:-}" ]; then
    log "binary vendor: GITHUB_MCP_PAT unset; cannot fetch private release asset"
    return 1
  fi

  local repo="${BINARY_VENDOR_REPO:-$BINARY_VENDOR_REPO_DEFAULT}"
  local tag="${BINARY_VENDOR_TAG:-$BINARY_VENDOR_TAG_DEFAULT}"
  local asset="${BINARY_VENDOR_ASSET:-$BINARY_VENDOR_ASSET_DEFAULT}"
  local expected_sha="${BINARY_VENDOR_BUNDLE_SHA256:-}"

  local tmp
  tmp="$(mktemp -d)"
  local bundle="$tmp/bundle.tar.gz"

  log "binary vendor: fetching $repo@$tag/$asset"

  # Resolve asset_id, then download via the API octet-stream endpoint.
  # Two-step rather than `gh release download` because gh isn't
  # guaranteed present yet (this function runs before ensure_gh_cli).
  local release_json
  if ! release_json="$(retry 3 curl -fsSL \
      -H "Authorization: token $GITHUB_MCP_PAT" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$repo/releases/tags/$tag" 2>/dev/null)"; then
    log "binary vendor: release lookup failed for $repo@$tag"
    rm -rf "$tmp"
    return 1
  fi

  local asset_id
  # jq isn't guaranteed on cloud either; use python3 (always present
  # per Dockerfile and Anthropic base image).
  asset_id="$(printf '%s' "$release_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for a in data.get("assets", []):
    if a.get("name") == sys.argv[1]:
        print(a.get("id"))
        break
' "$asset" 2>/dev/null)"

  if [ -z "$asset_id" ]; then
    log "binary vendor: asset $asset not found in release $tag"
    rm -rf "$tmp"
    return 1
  fi

  if ! retry 3 curl -fsSL \
      -H "Authorization: token $GITHUB_MCP_PAT" \
      -H "Accept: application/octet-stream" \
      -o "$bundle" \
      "https://api.github.com/repos/$repo/releases/assets/$asset_id"; then
    log "binary vendor: bundle download failed (asset_id=$asset_id)"
    rm -rf "$tmp"
    return 1
  fi

  local actual_sha
  actual_sha="$(sha256sum "$bundle" | awk '{print $1}')"
  if [ -n "$expected_sha" ]; then
    if [ "$actual_sha" != "$expected_sha" ]; then
      log "binary vendor: sha256 mismatch (expected=$expected_sha actual=$actual_sha)"
      rm -rf "$tmp"
      return 1
    fi
    log "binary vendor: sha256 verified"
  else
    log "binary vendor: no BINARY_VENDOR_BUNDLE_SHA256 pin; proceeding (sha=$actual_sha)"
  fi

  # Untar to /home/user; tarball contains .local/{bin,share}/...
  if ! tar -xzf "$bundle" -C /home/user; then
    log "binary vendor: untar failed"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"

  # Verify each binary is now present and executable.
  local missing=""
  for b in op gh uv mem0-mcp-server; do
    if [ ! -x "$bindir/$b" ]; then
      missing="$missing $b"
    fi
  done
  if [ -n "$missing" ]; then
    log "binary vendor: untar succeeded but missing:$missing"
    return 1
  fi

  log "binary vendor: installed op gh uv mem0-mcp-server to $bindir"
}

# Pre-warm the uv cache so fresh snapshots don't pay a cold PyPI fetch
# the first time a uv-shebang script runs. SessionEnd transcript export,
# transcript-fetch (Night's Watch / Weekly Watch / transcript-analyzer),
# and transcript-meta-backfill share `boto3>=1.34,<2`; on a flaky-egress
# fresh container the first invocation can fail with `boto3 missing`
# (issue #202). PR #190 added UV_CACHE_DIR=/home/user/.cache/uv to
# settings.json env so the cache survives the snapshot → resume
# transition; this function seeds that path at build time.
#
# Approach: run a dummy uv-script with the same PEP 723 metadata as the
# three real scripts so uv resolves boto3>=1.34,<2 and persists the
# wheel/sdist into UV_CACHE_DIR. The dummy exits immediately; the cache
# survives.
#
# Fail-open: if uv is missing or the resolve fails (e.g., PyPI flake at
# build time), per-script first-run PyPI fetch remains the fallback. No
# additional error surface.
prewarm_uv_cache() {
  if ! check_cmd uv; then
    build_log_record WARN "cloud-setup: uv not present; skipping uv cache pre-warm"
    return 0
  fi
  local cache_dir="${UV_CACHE_DIR:-/home/user/.cache/uv}"
  mkdir -p "$cache_dir" 2>/dev/null || true

  local prewarm_script
  prewarm_script="$(mktemp --suffix=.py)" || return 0
  cat >"$prewarm_script" <<'PREWARM_PY'
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
# uv-cache pre-warm sentinel — see scripts/lib/common.sh prewarm_uv_cache.
# Mirrors the PEP 723 metadata of the three boto3-using scripts:
#   session-end-transcript-export.py, transcript-fetch.py,
#   transcript-meta-backfill.py
# Running this resolves boto3>=1.34,<2 into UV_CACHE_DIR so the real
# scripts get a warm cache on first invocation.
import sys
sys.exit(0)
PREWARM_PY

  if UV_CACHE_DIR="$cache_dir" uv run --script "$prewarm_script" >/dev/null 2>&1; then
    build_log_record OK "cloud-setup: uv cache pre-warmed (boto3>=1.34,<2 in $cache_dir)"
  else
    build_log_record WARN "cloud-setup: uv cache pre-warm failed; first uv-script run on this snapshot will fetch from PyPI (issue #202)"
  fi
  rm -f "$prewarm_script"
}

# Refresh the external-touch (F6) cache by invoking
# coo-memory/bin/external-touch.py --refresh-cache. Two callers:
#
#   1. cloud-setup.sh after coo-bootstrap → builds the cache into the
#      snapshot so F6 reports ok on the first session of a fresh
#      container (rather than skipping with "cache absent — refresh via
#      bin/external-touch.py" until manually run).
#   2. session-start-sync.sh → refreshes if the cache is older than
#      $2 hours, catching long-running snapshots whose baked-in cache
#      has gone stale.
#
# Args: $1 workspace_root (e.g., /home/user); $2 max_age_hours (optional —
# refresh only if the cache is older than this; omit to always refresh).
#
# Fail-open on every gate (gh missing, PAT missing, script absent, refresh
# fails) so a degraded snapshot doesn't block boot. Non-zero exits log a
# WARN; F6 will fall back to its own "cache absent" skip path.
prewarm_external_touch_cache() {
  local workspace_root="${1:-}"
  local max_age_hours="${2:-}"
  if [ -z "$workspace_root" ]; then
    build_log_record WARN "external-touch: prewarm called without workspace_root; skipping"
    return 0
  fi
  local script="$workspace_root/coo-memory/bin/external-touch.py"
  local cache_path="${VADE_EXTERNAL_TOUCH_CACHE:-$VADE_CLOUD_STATE_DIR/external-touch-cache.json}"

  if [ ! -f "$script" ]; then
    build_log_record WARN "external-touch: $script absent; F6 cache pre-warm skipped"
    return 0
  fi
  if ! check_cmd python3 || ! check_cmd gh; then
    build_log_record WARN "external-touch: python3/gh missing; F6 cache pre-warm skipped"
    return 0
  fi
  # Need either an exported PAT (build-time after coo-bootstrap; or
  # session-start with coo-env autosourced) or an interactively-authed gh.
  if [ -z "${GITHUB_MCP_PAT:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}" ] \
      && ! gh auth status >/dev/null 2>&1; then
    build_log_record WARN "external-touch: no gh auth; F6 cache pre-warm skipped"
    return 0
  fi

  # Freshness gate — only when max_age_hours is given. mtime comparison
  # is portable across GNU/BSD stat by trying both flags.
  if [ -n "$max_age_hours" ] && [ -f "$cache_path" ]; then
    local cache_mtime now_secs age_hours
    cache_mtime=$(stat -c %Y "$cache_path" 2>/dev/null \
                || stat -f %m "$cache_path" 2>/dev/null \
                || echo 0)
    now_secs=$(date +%s)
    age_hours=$(( (now_secs - cache_mtime) / 3600 ))
    if [ "$age_hours" -lt "$max_age_hours" ] 2>/dev/null; then
      build_log_record OK "external-touch: cache age ${age_hours}h < ${max_age_hours}h floor; refresh skipped"
      return 0
    fi
  fi

  mkdir -p "$VADE_CLOUD_STATE_DIR" 2>/dev/null || true
  if GH_TOKEN="${GITHUB_MCP_PAT:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}" \
      python3 "$script" --refresh-cache "$cache_path" >/dev/null 2>>"$VADE_BUILD_LOG"; then
    build_log_record OK "external-touch: cache pre-warmed at $cache_path"
  else
    build_log_record WARN "external-touch: cache pre-warm failed; F6 will skip on next session"
  fi
  return 0
}

ensure_op_cli() {
  # Install into a snapshot-persistent path so a build-time install is
  # still on disk at session-resume time. /root/ resets each resume in
  # the cloud image; /home/user/ survives the snapshot. Without this,
  # the SessionStart-hook bootstrap fallback has to re-fetch op from
  # cache.agilebits.com mid-session and dies whenever Anthropic's
  # egress proxy is flaky (see run-2026-04-22T062313 and
  # run-2026-04-22T213126: "DNS cache overflow" 503 from the egress
  # gateway, both times).
  #
  # Linux-only auto-install. On macOS (Darwin) the expectation is that
  # `brew install 1password-cli` has already satisfied check_cmd; if it
  # hasn't, this function refuses rather than dropping a non-runnable
  # Linux binary into ${HOME}/.local/bin (coo-harness#81).
  local bindir
  bindir="$(_snapshot_user_bindir)"
  case ":$PATH:" in
    *":$bindir:"*) ;;
    *) export PATH="$bindir:$PATH" ;;
  esac

  if check_cmd op; then
    log "op CLI present: $(op --version 2>&1 | head -1)"
    return 0
  fi

  local os
  os="$(uname -s)"
  case "$os" in
    Linux) ;;
    Darwin)
      log "op CLI not present on macOS; install via: brew install 1password-cli"
      return 1
      ;;
    *)
      log "op CLI: unsupported OS '$os'"
      return 1
      ;;
  esac

  local version="${OP_VERSION:-$OP_VERSION_DEFAULT}"
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) log "op CLI: unsupported arch '$arch'"; return 1 ;;
  esac

  mkdir -p "$bindir"

  local url="https://cache.agilebits.com/dist/1P/op2/pkg/v${version}/op_linux_${arch}_v${version}.zip"
  local tmp
  tmp="$(mktemp -d)"
  log "Downloading op CLI v${version} (${arch}) → $bindir"
  # cache.agilebits.com occasionally returns 5xx; retry absorbs the
  # transient window. 5 attempts (~15s tolerance) matches _op_to_file's
  # already-tuned budget (line ~942) — same egress origin class, same
  # flake pattern. Witnessed exhaustion of the prior 3-attempt budget
  # in run-2026-04-25T182206; #76 propagates the proven budget here.
  if ! retry 5 curl -sfL "$url" -o "$tmp/op.zip"; then
    log "op CLI download failed after retries: $url"
    rm -rf "$tmp"
    return 1
  fi

  if check_cmd unzip; then
    unzip -qo "$tmp/op.zip" -d "$tmp"
  elif check_cmd python3; then
    python3 -m zipfile -e "$tmp/op.zip" "$tmp"
  else
    log "op CLI extraction failed: need 'unzip' or 'python3'."
    rm -rf "$tmp"
    return 1
  fi

  install -m 0755 "$tmp/op" "$bindir/op"
  rm -rf "$tmp"

  if ! op --version >/dev/null 2>&1; then
    log "op CLI install appears broken"
    return 1
  fi
  log "Installed op CLI: $(op --version 2>&1 | head -1)"
}

# Durable GitHub write path for COO attribution.
#
# Installs the gh CLI into a snapshot-persistent path under the user's
# .local/bin (/home/user/.local/bin when running as root with a
# /home/user tree — cloud harness; ${HOME}/.local/bin otherwise) so it
# survives the snapshot → resume transition with no per-resume fetch.
# check_cmd gh short-circuits when gh is already present (local macOS
# via brew, devcontainer pre-install, or a prior build).
#
# Linux-only auto-install. On macOS (Darwin) the expectation is that
# `brew install gh` has already satisfied check_cmd; if it hasn't, this
# function refuses rather than dropping a non-runnable Linux binary
# into ${HOME}/.local/bin. Bindir resolution is shared with ensure_op_cli
# via _snapshot_user_bindir.
#
# Rationale: coo-harness#36 documented the streamable-HTTP transport
# failure ("DNS cache overflow") that motivated `gh` as a parallel path.
# Epic #112 Stream 1 retired the github-coo MCP entirely; `gh` is now
# the sole GitHub write path under vade-coo attribution. Authenticated
# with $GITHUB_MCP_PAT via short-lived HTTPS request/response cycles —
# same token, same identity, immune to the undici DNS-cache class.
# MEMO-2026-04-22-04 attribution invariant remains load-bearing.
ensure_gh_cli() {
  local bindir
  bindir="$(_snapshot_user_bindir)"
  case ":$PATH:" in
    *":$bindir:"*) ;;
    *) export PATH="$bindir:$PATH" ;;
  esac

  if check_cmd gh; then
    log "gh CLI present: $(gh --version 2>&1 | head -1)"
    return 0
  fi

  local os
  os="$(uname -s)"
  case "$os" in
    Linux) ;;
    Darwin)
      log "gh CLI not present on macOS; install via: brew install gh"
      return 1
      ;;
    *)
      log "gh CLI: unsupported OS '$os'"
      return 1
      ;;
  esac

  local version="${GH_VERSION:-$GH_VERSION_DEFAULT}"
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) log "gh CLI: unsupported arch '$arch'"; return 1 ;;
  esac

  mkdir -p "$bindir"

  local url="https://github.com/cli/cli/releases/download/v${version}/gh_${version}_linux_${arch}.tar.gz"
  local tmp
  tmp="$(mktemp -d)"
  log "Downloading gh CLI v${version} (${os}/${arch}) → $bindir"
  if ! retry 3 curl -sfL "$url" -o "$tmp/gh.tar.gz"; then
    log "gh CLI download failed after retries: $url"
    rm -rf "$tmp"
    return 1
  fi

  if ! tar -xzf "$tmp/gh.tar.gz" -C "$tmp"; then
    log "gh CLI extraction failed"
    rm -rf "$tmp"
    return 1
  fi

  local gh_bin
  gh_bin="$(find "$tmp" -type f -name gh -path '*/bin/gh' | head -1)"
  if [ -z "$gh_bin" ] || [ ! -f "$gh_bin" ]; then
    log "gh CLI: extracted tarball missing bin/gh"
    rm -rf "$tmp"
    return 1
  fi
  install -m 0755 "$gh_bin" "$bindir/gh"
  rm -rf "$tmp"

  if ! gh --version >/dev/null 2>&1; then
    log "gh CLI install appears broken"
    return 1
  fi
  log "Installed gh CLI: $(gh --version 2>&1 | head -1)"
}

# Durable Mem0 MCP read/write surface for COO identity & episodic recall.
#
# Installs the `mem0-mcp-server` Python package (PyPI) into a
# snapshot-persistent path under the user's .local tree via `uv tool
# install`, exposing the binary at <bindir>/mem0-mcp-server. The .mcp.json
# stdio entry points at this binary directly so Claude Code spawns it
# as a subprocess at process start — bypassing the Node `undici`
# DNS-cache-overflow failure that kills the streamable-HTTP transport
# against api.mem0.ai (coo-harness#36 class extended to non-MCP egress
# in #109). Same egress as the failing transport, different wire: the
# stdio server uses Python `httpx` for its REST hop, which is not
# subject to undici's bug.
#
# Linux + macOS auto-install (uv is cross-platform). uv is required;
# this function refuses if it can't find uv on PATH after the install
# attempt. The Anthropic cloud image already has uv at
# /root/.local/bin/uv; for local dev install via `curl -LsSf
# https://astral.sh/uv/install.sh | sh` first.
#
# Tool dir is pinned to <bindir>/.. so the venv lives under the same
# snapshot-persistent path as the binary symlink. Without an explicit
# UV_TOOL_DIR, uv puts the venv under $XDG_DATA_HOME (typically
# ~/.local/share/uv/) which on the cloud harness lives under /root/
# and gets erased per resume.
ensure_mem0_mcp_server() {
  local bindir
  bindir="$(_snapshot_user_bindir)"
  case ":$PATH:" in
    *":$bindir:"*) ;;
    *) export PATH="$bindir:$PATH" ;;
  esac

  local version="${MEM0_MCP_SERVER_VERSION:-$MEM0_MCP_SERVER_VERSION_DEFAULT}"
  local target="$bindir/mem0-mcp-server"

  # Idempotent short-circuit. Don't re-install if the binary is already
  # in place — uv tool install is non-trivial (resolves a ~50-package
  # dep tree) and the snapshot has already paid that cost. Version-pin
  # check is best-effort: there's no --version flag on this server, so
  # we trust the symlink target.
  if [ -x "$target" ]; then
    log "mem0-mcp-server present: $target"
    return 0
  fi

  if ! check_cmd uv; then
    log "mem0-mcp-server: uv not on PATH; install it first (https://astral.sh/uv)"
    return 1
  fi

  # uv tool install resolves and installs into UV_TOOL_DIR/<package>/
  # and links console_scripts into UV_TOOL_BIN_DIR. Both must point at
  # the snapshot-persistent tree.
  local tool_dir="${bindir%/bin}/share/uv-tools"
  mkdir -p "$tool_dir" "$bindir"

  log "Installing mem0-mcp-server v${version} via uv tool → $target"
  if ! UV_TOOL_DIR="$tool_dir" UV_TOOL_BIN_DIR="$bindir" \
       uv tool install "mem0-mcp-server==${version}" >/dev/null 2>&1; then
    log "mem0-mcp-server: uv tool install failed"
    return 1
  fi

  if [ ! -x "$target" ]; then
    log "mem0-mcp-server: install reported success but $target missing"
    return 1
  fi
  log "Installed mem0-mcp-server v${version}"
}

# Durable Quarto CLI for slide-deck and document rendering.
#
# Installs the Quarto CLI tarball (~131 MB) into a snapshot-persistent
# path under the user's .local/share/quarto, with a symlink at
# <bindir>/quarto. The tarball bundles its own pandoc and deno, so a
# successful install also gives subsequent code paths pandoc-on-PATH
# transitively (via the bundled binary, not via a separate install).
#
# Linux-only auto-install. On macOS (Darwin) the expectation is that
# `brew install --cask quarto` has already satisfied check_cmd; if it
# hasn't, this function refuses rather than dropping a non-runnable
# Linux tarball. Bindir resolution is shared with ensure_op_cli /
# ensure_gh_cli via _snapshot_user_bindir. Install dir resolution is
# parallel to ensure_mem0_mcp_server's UV_TOOL_DIR — share/quarto under
# the snapshot-persistent tree so the bundle survives resume.
#
# Rationale: introduced for the 2026-shiffrin-conference deck
# (coo-memory/_drafts/2026-shiffrin-conference/), kept as a
# standing tool for future markdown-to-{revealjs,pptx,pdf} workflows.
# Best-effort at build time; cloud-setup logs a warning on failure and
# the first session that needs Quarto fetches on demand.
ensure_quarto_cli() {
  local bindir
  bindir="$(_snapshot_user_bindir)"
  case ":$PATH:" in
    *":$bindir:"*) ;;
    *) export PATH="$bindir:$PATH" ;;
  esac

  if check_cmd quarto; then
    log "quarto present: $(quarto --version 2>&1 | head -1)"
    return 0
  fi

  local os
  os="$(uname -s)"
  case "$os" in
    Linux) ;;
    Darwin)
      log "quarto not present on macOS; install via: brew install --cask quarto"
      return 1
      ;;
    *)
      log "quarto: unsupported OS '$os'"
      return 1
      ;;
  esac

  local version="${QUARTO_VERSION:-$QUARTO_VERSION_DEFAULT}"
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) log "quarto: unsupported arch '$arch'"; return 1 ;;
  esac

  # Install layout: <bindir>/../share/quarto/ holds the bundle (bin/,
  # share/, ...); <bindir>/quarto is a symlink to the bundle's bin/quarto.
  # Mirrors the convention ensure_mem0_mcp_server uses for its uv-tool
  # share dir, so both tools' state lives under the same .local/share/.
  local install_dir
  install_dir="${bindir%/bin}/share/quarto"

  mkdir -p "$install_dir" "$bindir"

  local url="https://github.com/quarto-dev/quarto-cli/releases/download/v${version}/quarto-${version}-linux-${arch}.tar.gz"
  local tmp
  tmp="$(mktemp -d)"
  log "Downloading quarto v${version} (${arch}) → $install_dir"
  if ! retry 5 curl -sfL "$url" -o "$tmp/quarto.tar.gz"; then
    log "quarto download failed after retries: $url"
    rm -rf "$tmp"
    return 1
  fi

  if ! tar -xzf "$tmp/quarto.tar.gz" -C "$install_dir" --strip-components=1; then
    log "quarto extraction failed"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"

  ln -sfn "$install_dir/bin/quarto" "$bindir/quarto"

  if ! quarto --version >/dev/null 2>&1; then
    log "quarto install appears broken"
    return 1
  fi
  log "Installed quarto v${version}"
}

# Snapshot-persistent PyYAML for the system python3 interpreter.
#
# schema-fetch-secrets.py and several PreToolUse / PostToolUse hooks
# (boot-brake-guard.py, skill-yaml-guard.sh, bash-token-guard.sh,
# preuse-agent-env-scrub.sh, postuse-bash-redactor.sh) all `import yaml`
# from the system python3. Currently satisfied by the Debian base image's
# `python3-yaml` package; this function defends against a future image
# rebuild that drops it.
#
# Install layout: PYTHONUSERBASE=/home/user/.local with
# `pip install --user --break-system-packages PyYAML==<pin>`. The user
# site lands at /home/user/.local/lib/python3.X/site-packages, under the
# snapshot-persistent /home/user tree. PYTHONUSERBASE in settings.json
# env (written by _write_claude_settings_paths) lets Claude Code's tool
# hooks pick it up on resume; common.sh-sourcing scripts inherit it via
# the export below.
#
# Short-circuits when system python3 already has PyYAML >= 6 importable —
# the common case while the base image still ships python3-yaml. In the
# defensive case (base image drops PyYAML), the install runs once at
# build time and the resulting site-packages survives every resume.
#
# Returns 0 when PyYAML is importable at the end of the run; 1 on a
# total failure (no pip-resolvable PyYAML and no fallback). Fail-open at
# the caller: a 1 return is loud (logs FATAL) but lets cloud-setup.sh
# continue — fetch_coo_secrets surfaces the gap fatally at first use.
ensure_pyyaml() {
  local userbase="/home/user/.local"
  # Export for the rest of this shell (and any child processes invoked
  # before _write_claude_settings_paths runs) so python3 finds the
  # snapshot-persistent user-site without an extra env nudge per call.
  export PYTHONUSERBASE="$userbase"

  if python3 -c "import yaml, sys; sys.exit(0 if tuple(int(p) for p in yaml.__version__.split('.')[:2]) >= (6, 0) else 1)" 2>/dev/null; then
    local existing_version existing_path
    existing_version="$(python3 -c 'import yaml; print(yaml.__version__)' 2>/dev/null)"
    existing_path="$(python3 -c 'import yaml, os; print(os.path.dirname(yaml.__file__))' 2>/dev/null)"
    log "PyYAML present: ${existing_version} (${existing_path})"
    return 0
  fi

  if ! check_cmd python3; then
    log "ensure_pyyaml: FATAL — python3 missing; cannot install PyYAML"
    return 1
  fi

  local version="${PYYAML_VERSION:-$PYYAML_VERSION_DEFAULT}"
  log "Installing PyYAML==${version} → ${userbase}/lib/python\$X/site-packages"
  # --break-system-packages bypasses PEP 668's EXTERNALLY-MANAGED marker
  # on Debian. We're installing to the user site (not /usr/lib), so this
  # does not actually overwrite any Debian-managed package.
  if PYTHONUSERBASE="$userbase" python3 -m pip install \
       --user --break-system-packages --no-cache-dir --upgrade \
       "PyYAML==${version}" >/dev/null 2>&1; then
    if python3 -c "import yaml" 2>/dev/null; then
      log "Installed PyYAML: $(python3 -c 'import yaml; print(yaml.__version__)' 2>/dev/null) ($(python3 -c 'import yaml, os; print(os.path.dirname(yaml.__file__))' 2>/dev/null))"
      return 0
    fi
    log "ensure_pyyaml: install reported success but import still fails"
    return 1
  fi
  log "ensure_pyyaml: FATAL — PyYAML install failed (network or PyPI flake at build time?)"
  return 1
}

# Expose gh on Claude Code's Bash-tool PATH every session.
#
# ensure_gh_cli installs to /home/user/.local/bin so the binary survives
# cloud snapshot rebuilds, but the shell Claude spawns only has
# /root/.local/bin on PATH. Bridge the two with a symlink so `gh`
# resolves without the agent having to mutate PATH or discover the
# install path. Cloud-only (root + /home/user present); on macOS/local
# gh comes from brew and $HOME/.local/bin is already on PATH.
# Idempotent via ln -sfn; no-op with a quiet log if the target is
# missing (ensure_gh_cli is the installer).
ensure_gh_symlink_on_path() {
  [ "$(id -u)" = "0" ] && [ -d /home/user ] || return 0
  local target="/home/user/.local/bin/gh"
  local link="/root/.local/bin/gh"
  if [ ! -x "$target" ]; then
    log "gh symlink: $target missing; skipping (run ensure_gh_cli to install)"
    return 0
  fi
  mkdir -p "$(dirname "$link")"
  ln -sfn "$target" "$link"
}

# Install the gh-coo-wrap wrapper at /home/user/.local/bin/gh so every
# attributable `gh` write auto-carries the Claude Code session URL.
# Substrate enforcement of coo-memory MEMO 2026-04-26-02 (issue
# #150). The real gh binary moves to /home/user/.local/bin/gh-real;
# the wrapper exec's it after augmenting --body / --body-file.
#
# Idempotent: subsequent runs detect the wrapper marker and only
# refresh the wrapper content (in case the source script has been
# updated). Cloud-only path guard (root + /home/user); macOS/local
# uses brew gh and is left untouched.
ensure_gh_coo_wrap() {
  [ "$(id -u)" = "0" ] && [ -d /home/user ] || return 0
  local gh_path="/home/user/.local/bin/gh"
  local real_path="/home/user/.local/bin/gh-real"
  local wrapper_src="${1:-}"
  if [ -z "$wrapper_src" ] || [ ! -f "$wrapper_src" ]; then
    log "gh-coo-wrap: source script missing; skipping"
    return 0
  fi
  if [ ! -x "$gh_path" ]; then
    log "gh-coo-wrap: $gh_path missing; skipping (ensure_gh_cli installs gh)"
    return 0
  fi
  if grep -q 'COO-GH-COO-WRAP-MARKER-v1' "$gh_path" 2>/dev/null; then
    # Wrapper already installed — refresh content in case the source has changed.
    install -m 0755 "$wrapper_src" "$gh_path"
    return 0
  fi
  # First-time install: rename real binary and place wrapper.
  if [ ! -x "$real_path" ]; then
    mv "$gh_path" "$real_path"
  else
    # Real binary already present (recovery from a partial state):
    # back up whatever is at gh_path and replace with the wrapper.
    rm -f "$gh_path"
  fi
  install -m 0755 "$wrapper_src" "$gh_path"
  log "gh-coo-wrap: installed (wrapper at $gh_path, real binary at $real_path)"
}

# Install the op-coo-wrap shim at /home/user/.local/bin/op so every
# `op` invocation gets transparent rate-limit fallback between
# OP_SERVICE_ACCOUNT_TOKEN and OP_SERVICE_ACCOUNT_TOKEN_BACKUP. The
# real op binary moves to /home/user/.local/bin/op-real.
#
# Closes the gap left by coo-bootstrap's in-process swap, which
# doesn't propagate to subsequent Bash-tool subprocesses. Same
# install pattern as ensure_gh_coo_wrap; marker grep keeps it
# idempotent. Cloud-only path guard (root + /home/user); macOS/local
# uses brew/system op and is left untouched.
ensure_op_coo_wrap() {
  [ "$(id -u)" = "0" ] && [ -d /home/user ] || return 0
  local op_path="/home/user/.local/bin/op"
  local real_path="/home/user/.local/bin/op-real"
  local wrapper_src="${1:-}"
  if [ -z "$wrapper_src" ] || [ ! -f "$wrapper_src" ]; then
    log "op-coo-wrap: source script missing; skipping"
    return 0
  fi
  if [ ! -x "$op_path" ]; then
    log "op-coo-wrap: $op_path missing; skipping (ensure_op_cli installs op)"
    return 0
  fi
  if grep -q 'COO-OP-COO-WRAP-MARKER-v1' "$op_path" 2>/dev/null; then
    install -m 0755 "$wrapper_src" "$op_path"
    return 0
  fi
  if [ ! -x "$real_path" ]; then
    mv "$op_path" "$real_path"
  else
    rm -f "$op_path"
  fi
  install -m 0755 "$wrapper_src" "$op_path"
  log "op-coo-wrap: installed (wrapper at $op_path, real binary at $real_path)"
}

# Fetch COO secrets from 1Password via a schema-driven iterator.
#
# Reads operations/secrets/schema.yaml (Track 4 Phase 1 refactor,
# coo-memory#871) and calls schema-fetch-secrets.py, which iterates
# active credentials and emits `export VAR=VALUE` lines. The Python
# helper handles status discipline (dormant/retired/pending_* are
# skipped) and multi-field credentials (r2-transcripts, cloudflare,
# github-app-vade-coo-app). All reads are best-effort — a missing
# item warns and leaves the var unset; only a total-fetch-zero is fatal.
#
# The schema path is resolved via $VADE_COO_MEMORY_DIR (injected by the
# cloud UI .env block; defaults to /home/user/coo-memory). Fail-closed
# if the schema file is unreadable or PyYAML is missing — boot should
# not continue without a working secrets pipeline (coo-memory#871).
#
# Output shape is identical to the old hardcoded implementation:
# Phase 2 (coo-memory#873): coo-env plaintext mirror retired.
# Secrets are exported in-memory only (eval into current shell process);
# no disk persistence. MCP children receive secrets via op run --env-file
# at spawn time. The parent shell (gh, op, COO tools) inherits directly
# from this process after bootstrap completes.
#
# Returns 0 if at least one secret was fetched; exits non-zero on
# schema-parse failure; returns 1 if every op read failed.
fetch_coo_secrets() {
  log "Fetching COO secrets from 1Password vault COO (schema-iterator)"

  local schema_path="${VADE_COO_MEMORY_DIR:-/home/user/coo-memory}/operations/secrets/schema.yaml"
  local helper="${VADE_RUNTIME_DIR:-/home/user/coo-harness}/scripts/boot/schema-fetch-secrets.py"

  # Fail closed: schema unreadable = bootstrap cannot continue.
  if [ ! -f "$schema_path" ]; then
    log "FATAL: schema file not found: $schema_path"
    log "  Ensure VADE_COO_MEMORY_DIR points at a coo-memory checkout."
    return 1
  fi
  if [ ! -f "$helper" ]; then
    log "FATAL: schema-fetch-secrets.py not found: $helper"
    log "  Ensure VADE_RUNTIME_DIR points at the coo-harness checkout."
    return 1
  fi
  if ! check_cmd python3; then
    log "FATAL: python3 not on PATH; cannot run schema-fetch-secrets.py"
    return 1
  fi

  # Phase 2 (coo-memory#873): no coo-env file. Secrets live in-memory only.
  mkdir -p "${HOME}/.vade"

  # Run the schema iterator. Its stdout is eval-safe export lines plus a
  # SCHEMA_FETCH_GOT=N line; stderr carries the per-credential log lines.
  # Capture stdout; let stderr flow to the caller's log (same as retry's
  # log_err pattern). Fail-open on individual credential failures (each
  # warn is emitted by the helper); fail-closed only on schema error (rc=1).
  #
  # Phase 2 follow-up cache: schema-fetch output is cached in tmpfs for
  # the session. Re-bootstraps (stale-PAT detection, settings.json env
  # incomplete) within the TTL eval the cache instead of re-running the
  # python iterator's ~12 op-reads. Cache invalidates on schema hash
  # change or TTL expiry. Container-ephemeral; dies on reboot.
  local fetch_cache_dir
  if [ -d /dev/shm ] && [ -w /dev/shm ]; then
    fetch_cache_dir="/dev/shm/coo-secret-cache"
  else
    fetch_cache_dir="/tmp/coo-secret-cache"
  fi
  local fetch_cache="$fetch_cache_dir/schema-fetch.sh"
  local fetch_cache_meta="$fetch_cache_dir/schema-fetch.meta"
  local fetch_cache_ttl=86400
  local fetch_output=""
  local fetch_rc=0
  local fetch_now
  fetch_now="$(date +%s 2>/dev/null || echo 0)"
  local schema_sha
  schema_sha="$(sha256sum "$schema_path" 2>/dev/null | cut -c1-16)"
  local cache_hit=0

  if [ -f "$fetch_cache" ] && [ -f "$fetch_cache_meta" ]; then
    local meta_sha meta_expiry
    meta_sha="$(awk -F= '$1=="schema_sha"{print $2; exit}' "$fetch_cache_meta" 2>/dev/null)"
    meta_expiry="$(awk -F= '$1=="expiry"{print $2; exit}' "$fetch_cache_meta" 2>/dev/null)"
    if [ "$meta_sha" = "$schema_sha" ] && [ "${meta_expiry:-0}" -gt "$fetch_now" ] 2>/dev/null; then
      fetch_output="$(cat "$fetch_cache" 2>/dev/null || true)"
      [ -n "$fetch_output" ] && cache_hit=1
    fi
  fi

  if [ "$cache_hit" -eq 0 ]; then
    fetch_output="$(python3 "$helper" --schema "$schema_path")" || fetch_rc=$?
    # Populate cache on a successful fetch with output.
    if [ -n "$fetch_output" ] && [ "$fetch_rc" -ne 1 ]; then
      mkdir -p "$fetch_cache_dir" 2>/dev/null || true
      chmod 0700 "$fetch_cache_dir" 2>/dev/null || true
      local umask_save; umask_save="$(umask)"
      umask 0177
      printf '%s' "$fetch_output" > "$fetch_cache" 2>/dev/null || true
      {
        printf 'schema_sha=%s\n' "$schema_sha"
        printf 'expiry=%s\n' "$((fetch_now + fetch_cache_ttl))"
      } > "$fetch_cache_meta" 2>/dev/null || true
      umask "$umask_save"
    fi
  else
    log "  schema-fetch cache hit (TTL ${fetch_cache_ttl}s, schema sha8 ${schema_sha:0:8})"
  fi

  if [ "$fetch_rc" -eq 1 ] && [ -z "$fetch_output" ]; then
    # Schema parse error: the helper printed nothing useful and exited 1.
    log "FATAL: schema-fetch-secrets.py failed with no output (schema parse error)"
    return 1
  fi

  # Eval the export lines into the current shell. Eval of attacker-controlled
  # input would be dangerous, but this output is produced by our own helper
  # from 1Password reads — same trust level as the prior op read pipeline.
  # The helper shell-single-quotes all values so injection via token content
  # is not possible (a literal single-quote in a token value is handled by
  # the helper's shell_single_quote function).
  #
  # The eval also exports SCHEMA_FETCH_GOT=N (not exported, just a shell var).
  SCHEMA_FETCH_GOT=0
  eval "$fetch_output" 2>/dev/null || true

  if [ "${SCHEMA_FETCH_GOT:-0}" -eq 0 ]; then
    log "  no COO secrets could be fetched"
    return 1
  fi

  # Phase 2 (coo-memory#873): no coo-env file write. Secrets are in the
  # current shell process env only (exported by eval above). MCP children
  # receive secrets via op run --env-file at spawn time. The parent shell
  # (gh, op, COO tools) inherits from this process after bootstrap completes.
  log "  fetched SCHEMA_FETCH_GOT=${SCHEMA_FETCH_GOT} secrets (in-process only; no coo-env file)"

  # Bootstrap-exports keynames sentinel for integrity-check S2.
  # The integrity-check.sh subprocess runs in a sibling hook with its own
  # env — Phase 2 retired the settings.json::env mirror for secrets, so
  # the subprocess can't see what fetch_coo_secrets just exported.
  # Write a keynames-only file (no values; safe at rest in tmpfs/$HOME)
  # so S2 can verify the bootstrap successfully exported each declared
  # env-alias instead of trying to read the alias from its own process env
  # (which is structurally empty post-Phase-2).
  local exports_file="${HOME}/.vade/.bootstrap-exports"
  if printf '%s\n' "$fetch_output" \
      | awk -F'=' '/^export [A-Z][A-Z0-9_]*=/ { sub(/^export /, "", $1); print $1 }' \
      | sort -u \
      > "$exports_file" 2>/dev/null; then
    chmod 600 "$exports_file" 2>/dev/null || true
    log "  wrote bootstrap-exports keynames sentinel ($(wc -l < "$exports_file" | tr -d ' ') keys) → $exports_file"
  fi

  # vars already exported to current shell by eval above.
  # Mirror GITHUB_TOKEN = GITHUB_MCP_PAT if the helper didn't emit it
  # separately (schema alias: both are listed under github-pat-vade-coo,
  # but the helper emits each alias separately so they should both be set).
  if [ -n "${GITHUB_MCP_PAT:-}" ] && [ -z "${GITHUB_TOKEN:-}" ]; then
    export GITHUB_TOKEN="${GITHUB_MCP_PAT}"
  fi

  return 0
}

# Merge non-secret COO env vars into ~/.claude/settings.json. Called
# from coo-bootstrap.sh AFTER validate_coo_identity.
#
# Phase 2 (coo-memory#873): only non-secret vars go into settings.json.
# Secret-bearing vars (PATs, API keys, tokens) are NO LONGER persisted
# to settings.json — they live in process env only (exported by
# fetch_coo_secrets). MCP children receive secrets via op run --env-file
# at spawn time.
#
# Non-secret vars written here:
#   - GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID (public identifiers)
#   - CLOUDFLARE_ACCOUNT_ID (public identifier per non_secret_env_allowlist)
merge_coo_settings_env() {
  _write_claude_settings_env \
    "${GITHUB_APP_ID:-}" \
    "${GITHUB_APP_INSTALLATION_ID:-}" \
    "${CLOUDFLARE_ACCOUNT_ID:-}"
}

# Persist non-secret bootstrap-derived path state into ~/.claude/settings.json
# env so every shell the harness spawns (sub-agents, Bash tool calls,
# Skill invocations) inherits it on first try. Without this the bootstrap
# knows VADE_CLOUD_STATE_DIR and the snapshot user bindir during its own
# run, but they evaporate after exit — leaving CLAUDE.md fallbacks
# (which assume $HOME == cwd) and `command -v op` to fail in fresh shells.
# coo-harness#83.
merge_coo_settings_paths() {
  local bindir
  bindir="$(_snapshot_user_bindir)"
  _write_claude_settings_paths "$VADE_CLOUD_STATE_DIR" "$bindir"
}

# Pre-materialize MCP env-file templates to tmpfs, replacing op:// refs
# with the already-fetched values in the current process env. Called
# AFTER fetch_coo_secrets so $MEM0_API_KEY etc. are populated.
#
# Phase 2 follow-up to coo-memory#871: the per-MCP-spawn `op run --env-file`
# pattern resolves every op:// ref on each spawn, hitting 1P's account-level
# rate-limit (1000 read+write per 24h on Personal/Teams plans, undocumented).
# MCP servers respawn under disconnect/reconnect, sub-agent spawns, and
# stale-PAT re-bootstraps — compounding. Pre-materializing the resolved
# env-file once at boot means subsequent `op run` invocations see a file
# with no op:// refs and pass through without API calls.
#
# Output: $VADE_MCP_ENV_DIR/<basename>.env (one per template). The directory
# is tmpfs (/dev/shm on Linux containers), 0700, files 0600 — within Phase 2's
# "no plaintext at rest" spirit: in-memory, container-ephemeral, dies on reboot,
# no backup surface. Same security posture as MCP server in-process secret residence.
#
# Idempotent: re-running on stale-PAT-detected re-bootstrap simply re-writes
# the resolved files.
materialize_mcp_env_files() {
  local templates_dir="${VADE_RUNTIME_DIR:-/home/user/coo-harness}/scripts/lib/mcp-env-templates"
  if [ ! -d "$templates_dir" ]; then
    log "  materialize_mcp_env_files: templates dir absent at $templates_dir; skip"
    return 0
  fi

  # Pick tmpfs target: /dev/shm preferred (typical Linux container tmpfs),
  # fall back to /tmp. Both are container-ephemeral.
  local out_dir
  if [ -d /dev/shm ] && [ -w /dev/shm ]; then
    out_dir="/dev/shm/coo-mcp-env"
  else
    out_dir="/tmp/coo-mcp-env"
  fi

  mkdir -p "$out_dir" 2>/dev/null || true
  chmod 0700 "$out_dir" 2>/dev/null || true

  local count=0 missing=0
  local umask_save; umask_save="$(umask)"
  umask 0177

  local template
  for template in "$templates_dir"/*.env; do
    [ -f "$template" ] || continue
    local basename="${template##*/}"
    local out_file="$out_dir/$basename"

    {
      local line key resolved
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          \#*|"")
            printf '%s\n' "$line"
            ;;
          *=op://*)
            key="${line%%=*}"
            resolved="${!key:-}"
            if [ -n "$resolved" ]; then
              printf '%s=%s\n' "$key" "$resolved"
            else
              # Resolution missing — keep the op:// ref so `op run` either
              # resolves it at spawn (fallback) or fails loudly (visible gap).
              printf '%s\n' "$line"
              missing=$((missing + 1))
            fi
            ;;
          *)
            printf '%s\n' "$line"
            ;;
        esac
      done < "$template"
    } > "$out_file"

    count=$((count + 1))
  done

  umask "$umask_save"

  export VADE_MCP_ENV_DIR="$out_dir"
  if [ "$missing" -gt 0 ]; then
    log "  materialized $count MCP env file(s) to $out_dir ($missing op:// ref(s) unresolved — will fall back to op run)"
  else
    log "  materialized $count MCP env file(s) to $out_dir (all op:// refs pre-resolved)"
  fi
}

# Cache the GitHub App private key to tmpfs so gh-app-token.sh can mint
# installation tokens without an op-read per re-mint. The private key
# rotates ~yearly; the installation-token mint cycle is hourly. Without
# this cache, every gh-app-token cache miss costs one op-read.
#
# Bootstrap calls this AFTER fetch_coo_secrets has populated
# GITHUB_APP_PRIVATE_KEY in process env. Writes to a tmpfs path
# gh-app-token.sh checks before its own op-read fallback.
#
# Same Phase-2-spirit posture as materialize_mcp_env_files: in-memory,
# container-ephemeral, 0600 file inside 0700 dir.
materialize_app_key_cache() {
  local key="${GITHUB_APP_PRIVATE_KEY:-}"
  if [ -z "$key" ]; then
    log "  materialize_app_key_cache: GITHUB_APP_PRIVATE_KEY not in env; skip"
    return 0
  fi

  local cache_dir
  if [ -d /dev/shm ] && [ -w /dev/shm ]; then
    cache_dir="/dev/shm/coo-app-key-cache"
  else
    cache_dir="/tmp/coo-app-key-cache"
  fi

  mkdir -p "$cache_dir" 2>/dev/null || true
  chmod 0700 "$cache_dir" 2>/dev/null || true

  local umask_save; umask_save="$(umask)"
  umask 0177
  printf '%s' "$key" > "$cache_dir/private_key" 2>/dev/null || true
  umask "$umask_save"

  export VADE_APP_KEY_CACHE_DIR="$cache_dir"
  log "  materialized App private key to $cache_dir/private_key"
}

# Write non-secret COO identifier vars into ~/.claude/settings.json "env".
# Phase 2 (coo-memory#873): secrets removed from settings.json entirely.
# Only public identifiers (GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID,
# CLOUDFLARE_ACCOUNT_ID) and tool-path vars (NODE_PATH,
# PLAYWRIGHT_BROWSERS_PATH) are written here. Any secret vars that were
# written by a prior Phase 1 bootstrap are scrubbed on first run.
#
# Args:
#   $1 = GITHUB_APP_ID
#   $2 = GITHUB_APP_INSTALLATION_ID
#   $3 = CLOUDFLARE_ACCOUNT_ID
_write_claude_settings_env() {
  # Defense-in-depth gate: only fire inside an Anthropic cloud session.
  # Anthropic sets CLAUDE_CODE_REMOTE=true in cloud (coo-harness#274);
  # outside that context this writer no-ops so it cannot contaminate
  # any user's personal ~/.claude/settings.json.
  [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || return 0
  local github_app_id="${1:-}"
  local github_app_installation_id="${2:-}"
  local cloudflare_account_id="${3:-}"
  if ! check_cmd node; then
    log "Warning: node missing; skipping ~/.claude/settings.json env merge"
    return 0
  fi
  local settings_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
  local settings_file="$settings_dir/settings.json"
  mkdir -p "$settings_dir"
  [ -f "$settings_file" ] || echo '{}' > "$settings_file"

  local node_path=""
  [ -d "/opt/node22/lib/node_modules" ] && node_path="/opt/node22/lib/node_modules"
  local pw_browsers=""
  [ -d "/opt/pw-browsers" ] && pw_browsers="/opt/pw-browsers"

  GITHUB_APP_ID="$github_app_id" \
  GITHUB_APP_INSTALLATION_ID="$github_app_installation_id" \
  CLOUDFLARE_ACCOUNT_ID="$cloudflare_account_id" \
  NODE_PATH="$node_path" PLAYWRIGHT_BROWSERS_PATH="$pw_browsers" node -e '
    const fs = require("fs");
    const path = process.argv[1];
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(path, "utf8")) || {}; }
    catch (e) {
      console.error("[vade-setup] " + path + " unparseable; aborting env merge.");
      process.exit(1);
    }
    const merged = Object.assign({}, cfg.env || {});
    // Phase 2 (coo-memory#873): scrub any secret vars from Phase 1
    // that may still be present in a prior-bootstrap settings.json.
    const secretVars = [
      "GITHUB_MCP_PAT", "GITHUB_TOKEN", "GITHUB_PUBLIC_PAT",
      "AGENTMAIL_API_KEY", "MEM0_API_KEY",
      "R2_TRANSCRIPTS_ACCESS_KEY_ID", "R2_TRANSCRIPTS_SECRET_ACCESS_KEY",
      "TRANSCRIPTS_AGE_IDENTITY",
      "VADE_AUTH_TOKEN", "VADE_BEARER_TOKEN", "VADE_MCP_URL",
      "CLOUDFLARE_API_TOKEN", "GITHUB_APP_PRIVATE_KEY"
    ];
    for (const v of secretVars) { delete merged[v]; }
    // Write non-secret public identifiers only.
    if (process.env.GITHUB_APP_ID) {
      merged.GITHUB_APP_ID = process.env.GITHUB_APP_ID;
    }
    if (process.env.GITHUB_APP_INSTALLATION_ID) {
      merged.GITHUB_APP_INSTALLATION_ID = process.env.GITHUB_APP_INSTALLATION_ID;
    }
    if (process.env.CLOUDFLARE_ACCOUNT_ID) {
      merged.CLOUDFLARE_ACCOUNT_ID = process.env.CLOUDFLARE_ACCOUNT_ID;
    }
    if (process.env.NODE_PATH) {
      merged.NODE_PATH = process.env.NODE_PATH;
    }
    if (process.env.PLAYWRIGHT_BROWSERS_PATH) {
      merged.PLAYWRIGHT_BROWSERS_PATH = process.env.PLAYWRIGHT_BROWSERS_PATH;
    }
    cfg.env = merged;
    fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n");
  ' "$settings_file"
  chmod 600 "$settings_file"
  log "  merged non-secret COO env vars into $settings_file (Phase 2: secrets scrubbed)"
}

# Persist non-secret path state into the same settings.json env block.
# Split from _write_claude_settings_env because it has no PAT validation
# dependency — it can run any time after _snapshot_user_bindir is
# resolvable, including a re-run on cached-PAT skip path. Idempotent.
#
# - VADE_CLOUD_STATE_DIR: where integrity-check.json, setup-receipt.json,
#   and build.log live. Without this in env, CLAUDE.md's documented
#   ${VADE_CLOUD_STATE_DIR:-$HOME/.vade-cloud-state} fallback resolves
#   to /root/.vade-cloud-state on the cloud harness (HOME=/root) — wrong
#   tree. coo-harness#83.
# - PATH: prepend the snapshot user bindir so `op`, `gh` (when installed
#   here), and any other ensure_*_cli tooling resolve in shells the
#   harness spawns after bootstrap exits. ensure_op_cli prepends to its
#   own shell only; settings.json env is the durable surface.
#
#   Critical: Claude Code does NOT shell-expand env values from
#   settings.json — it passes them as-is to subprocesses. So we must
#   write the *literal expanded* PATH at bootstrap time, not a
#   "${PATH}" placeholder. The first cut of coo-harness#83 wrote
#   the literal string "/home/user/.local/bin:${PATH}" and broke fresh
#   sessions (ls/which/bash all "command not found" because ${PATH}
#   was treated as a directory name). This pass captures the actual
#   bootstrap-shell PATH and serializes it.
_write_claude_settings_paths() {
  [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || return 0
  local cloud_state_dir="$1" bindir="$2"
  if ! check_cmd node; then
    log "Warning: node missing; skipping ~/.claude/settings.json paths merge"
    return 0
  fi
  local settings_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
  local settings_file="$settings_dir/settings.json"
  mkdir -p "$settings_dir"
  [ -f "$settings_file" ] || echo '{}' > "$settings_file"

  # Capture the live PATH for the node child to embed verbatim. Strip
  # any pre-existing bindir prefix so we don't double-prepend across
  # bootstrap re-runs (e.g., after marker invalidation).
  local live_path="${PATH}"
  case ":${live_path}:" in
    ":${bindir}:"*) live_path="${live_path#${bindir}:}" ;;
    *":${bindir}:"*) live_path="${live_path//:${bindir}:/:}" ;;
    *":${bindir}") live_path="${live_path%:${bindir}}" ;;
  esac

  # UV_CACHE_DIR redirects uv's script-environment cache (used by
  # `uv run --script` shebangs in transcript-meta-backfill.py and
  # session-end-transcript-export.py) to a snapshot-persistent path
  # under /home/user/. Default uv cache lands at /root/.cache/uv/
  # which is ephemeral on cloud-sandbox resume — every nightly resume
  # would otherwise pay a fresh boto3 resolve + install + egress hop.
  # Set here in the paths block (not the env-secrets block) because
  # this is a non-secret path-state value with no PAT-validation gate.
  local uv_cache_dir="/home/user/.cache/uv"

  # PYTHONUSERBASE points the system python3's user site at the
  # snapshot-persistent /home/user/.local/ tree. ensure_pyyaml installs
  # PyYAML there at build time as a defensive backstop against a future
  # base image dropping python3-yaml; the export here lets Claude Code's
  # tool hooks (boot-brake-guard.py, skill-yaml-guard.sh, etc.) find the
  # install on every resume without sourcing common.sh. Default user-base
  # would be /root/.local/, which is reset on each cloud resume — useless
  # for snapshot persistence. coo-harness#440.
  local python_userbase="/home/user/.local"

  VADE_CLOUD_STATE_DIR="$cloud_state_dir" VADE_BINDIR="$bindir" \
  VADE_LIVE_PATH="$live_path" UV_CACHE_DIR="$uv_cache_dir" \
  PYTHONUSERBASE="$python_userbase" node -e '
    const fs = require("fs");
    const path = process.argv[1];
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(path, "utf8")) || {}; }
    catch (e) {
      console.error("[vade-setup] " + path + " unparseable; aborting paths merge.");
      process.exit(1);
    }
    const merged = Object.assign({}, cfg.env || {});
    if (process.env.VADE_CLOUD_STATE_DIR) {
      merged.VADE_CLOUD_STATE_DIR = process.env.VADE_CLOUD_STATE_DIR;
    }
    if (process.env.VADE_BINDIR && process.env.VADE_LIVE_PATH !== undefined) {
      // Always rewrite from a known-good base (the captured shell PATH
      // with our bindir stripped) — never inherit a prior settings.json
      // PATH value, because that value may itself be the broken
      // "${PATH}"-literal output of a previous bootstrap run.
      const bindir = process.env.VADE_BINDIR;
      const live = process.env.VADE_LIVE_PATH;
      merged.PATH = live ? bindir + ":" + live : bindir;
    }
    if (process.env.UV_CACHE_DIR) {
      merged.UV_CACHE_DIR = process.env.UV_CACHE_DIR;
    }
    if (process.env.PYTHONUSERBASE) {
      merged.PYTHONUSERBASE = process.env.PYTHONUSERBASE;
    }
    cfg.env = merged;
    fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n");
  ' "$settings_file"
  chmod 600 "$settings_file"
  log "  merged COO path vars into $settings_file"
}

# Ensure openssh-client is present (provides ssh-keygen + ssh-keyscan).
# Returns 0 if available (or successfully installed), 1 otherwise.
# Absence is tolerated by install_coo_ssh_keys (fingerprint check is
# skipped with a warning) — we don't want a minimal base image to
# block identity provisioning.
ensure_openssh_client() {
  if check_cmd ssh-keygen; then
    return 0
  fi
  if ! check_cmd apt-get; then
    log "openssh-client missing and apt-get unavailable; fingerprint check will be skipped"
    return 1
  fi
  log "Installing openssh-client (needed for ssh-keygen fingerprint validation)"
  if sudo -n true 2>/dev/null; then
    sudo apt-get update -qq >/dev/null 2>&1 || true
    sudo apt-get install -y --no-install-recommends openssh-client >/dev/null 2>&1
  else
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y --no-install-recommends openssh-client >/dev/null 2>&1
  fi
  if check_cmd ssh-keygen; then
    log "openssh-client installed"
    return 0
  fi
  log "openssh-client install failed (no sudo or apt denied); fingerprint check will be skipped"
  return 1
}

# Compute ssh-key fingerprint from a pubkey file. Returns empty on
# failure. Wraps the pipeline so we can call it without tripping
# pipefail/set -e in the caller.
_fingerprint_of() {
  local pub="$1"
  ssh-keygen -lf "$pub" 2>/dev/null | awk '{print $2}' || true
}

# Install COO SSH keys from 1Password into ~/.ssh/. Validates
# fingerprints against expected values when ssh-keygen is available;
# logs a warning and continues when it is not (see ensure_openssh_client).
install_coo_ssh_keys() {
  local ssh_dir="${HOME}/.ssh"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  log "Installing COO SSH keys into $ssh_dir"

  _op_to_file "op://COO/vade-coo-ssh-auth/private key" "$ssh_dir/vade-coo-auth"     0600 || return 1
  _op_to_file "op://COO/vade-coo-ssh-auth/public key"  "$ssh_dir/vade-coo-auth.pub" 0644 || return 1
  _op_to_file "op://COO/vade-coo-ssh-sign/private key" "$ssh_dir/vade-coo-sign"     0600 || return 1
  _op_to_file "op://COO/vade-coo-ssh-sign/public key"  "$ssh_dir/vade-coo-sign.pub" 0644 || return 1

  if ensure_openssh_client; then
    local fp_auth fp_sign
    fp_auth="$(_fingerprint_of "$ssh_dir/vade-coo-auth.pub")"
    fp_sign="$(_fingerprint_of "$ssh_dir/vade-coo-sign.pub")"
    if [ "$fp_auth" != "$COO_AUTH_FP_EXPECTED" ]; then
      log "FATAL: auth key fingerprint mismatch (got '${fp_auth:-empty}', expected $COO_AUTH_FP_EXPECTED)"
      return 1
    fi
    if [ "$fp_sign" != "$COO_SIGN_FP_EXPECTED" ]; then
      log "FATAL: signing key fingerprint mismatch (got '${fp_sign:-empty}', expected $COO_SIGN_FP_EXPECTED)"
      return 1
    fi
    log "SSH key fingerprints validated"
  else
    log "WARNING: skipping SSH key fingerprint validation (ssh-keygen unavailable)"
  fi

  local allowed="$ssh_dir/allowed_signers"
  {
    echo "coo@vade-app.dev $(cat "$ssh_dir/vade-coo-auth.pub")"
    echo "coo@vade-app.dev $(cat "$ssh_dir/vade-coo-sign.pub")"
  } > "$allowed"
  chmod 644 "$allowed"
  log "Wrote $allowed"

  if check_cmd ssh-keyscan && ! grep -q '^github.com ' "$ssh_dir/known_hosts" 2>/dev/null; then
    local scan
    # Capture stdout separately so an empty result (e.g. port 22 blocked
    # in the Claude cloud sandbox) doesn't silently touch known_hosts
    # and then lie about success.
    scan="$(ssh-keyscan -T 5 -t rsa,ecdsa,ed25519 github.com 2>/dev/null || true)"
    if [ -n "$scan" ]; then
      printf '%s\n' "$scan" >> "$ssh_dir/known_hosts"
      chmod 644 "$ssh_dir/known_hosts"
      log "Added github.com to $ssh_dir/known_hosts"
    else
      log "WARNING: ssh-keyscan github.com returned nothing (port 22 blocked?); SSH git ops will fail in this environment"
    fi
  fi
}

# Record a per-call op-read observability event to
# ~/.vade/op-read-failures.jsonl. Called by _op_to_file when the
# enclosing retry loop either failed outright or burned non-trivial
# wall time (>1s, indicating at least one retry fired). Pairs with the
# op-coo-wrap tracer (/dev/shm/coo-op-wrap.trace) to surface the actual
# error shape behind the install_coo_ssh_keys first-attempt FAIL pattern
# (coo-harness#451). The jsonl is read by integrity-check.sh's D7 probe;
# operators can also tail it directly to triage a single boot.
_record_op_read_event() {
  local ref="$1" rc="$2" elapsed_ms="$3" pref_before="$4" pref_after="$5"
  local err_file="${6:-/dev/null}"
  local log_file="${HOME}/.vade/op-read-failures.jsonl"
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
  check_cmd python3 || return 0
  python3 - "$ref" "$rc" "$elapsed_ms" "$pref_before" "$pref_after" "$err_file" "$log_file" <<'PY' 2>/dev/null || true
import sys, json, datetime
ref, rc, elapsed_ms, pref_before, pref_after, err_file, log_file = sys.argv[1:]
err_tail = ""
try:
    with open(err_file, "r", errors="replace") as f:
        err_tail = f.read()[-240:]
except Exception:
    pass
def _int(v, default=0):
    try: return int(v)
    except Exception: return default
event = {
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "kind": "op_read",
    "ref": ref,
    "rc": _int(rc, rc),
    "elapsed_ms": _int(elapsed_ms),
    "op_wrap_pref_before": pref_before,
    "op_wrap_pref_after": pref_after,
    "stderr_tail": err_tail,
}
with open(log_file, "a") as f:
    f.write(json.dumps(event, separators=(",", ":")) + "\n")
PY
}

_op_to_file() {
  local ref="$1" path="$2" mode="$3"
  local content rc=0 err_file pref_before pref_after start_ms end_ms elapsed_ms
  # 5 attempts (sleeps 1+2+4+8 = 15s of tolerance) absorbs 1Password
  # service-account cold-start latency on first `op read` of a fresh
  # container. Observed on run-2026-04-22T091701: first bootstrap
  # attempt FAILED at install_coo_ssh_keys; second attempt
  # (`VADE_FORCE_COO_BOOTSTRAP=1`) succeeded after 2 retries on the
  # same ref, suggesting 3 attempts was inside the cold-start window
  # but 5 clears it comfortably.
  err_file="$(mktemp 2>/dev/null || echo "/tmp/op-to-file.$$.err")"
  : > "$err_file"
  pref_before="$(cat "${XDG_RUNTIME_DIR:-/tmp}/coo-op-wrap/active" 2>/dev/null || echo "?")"
  start_ms="$(date -u +%s%3N 2>/dev/null || echo 0)"
  # Capture stderr from the retry chain to err_file so we can both
  # (a) replay it to the operator (preserving prior log behavior) and
  # (b) record its tail in the structured jsonl event for #451.
  content="$(retry 5 op read "$ref" 2>"$err_file")" || rc=$?
  end_ms="$(date -u +%s%3N 2>/dev/null || echo 0)"
  pref_after="$(cat "${XDG_RUNTIME_DIR:-/tmp}/coo-op-wrap/active" 2>/dev/null || echo "?")"
  elapsed_ms=$((end_ms - start_ms))
  # Preserve prior stderr behavior — retry already wrote its diagnostic
  # lines to err_file; replay them so existing log consumers see them.
  cat "$err_file" >&2 2>/dev/null || true
  # Observability: record when the call failed or took non-trivial time
  # (>1s strongly suggests at least one retry attempt; a clean cold cache
  # hit is sub-second). Logging every success would be too noisy.
  if [ "$rc" -ne 0 ] || [ "$elapsed_ms" -gt 1000 ]; then
    _record_op_read_event "$ref" "$rc" "$elapsed_ms" "$pref_before" "$pref_after" "$err_file"
  fi
  rm -f "$err_file"
  if [ "$rc" -ne 0 ]; then
    log "Failed to read $ref after retries"
    return 1
  fi
  # Empty content from a rc=0 `op read` indicates a 1Password API
  # soft-fail that didn't set an exit code — fail loudly rather than
  # writing a bare-newline file that trips the fingerprint check
  # downstream with a confusing error.
  if [ -z "$content" ]; then
    log "Failed to read $ref: empty content (op read returned rc=0 with no output)"
    return 1
  fi
  (
    umask 077
    printf '%s\n' "$content" > "$path"
  )
  chmod "$mode" "$path"
  log "  wrote $path ($mode)"
}

# Write gitconfig with COO identity + SSH signing + auth-key push.
# Target path is overridable via VADE_COO_GITCONFIG so local-setup.sh can
# route Claude's git through ~/.vade/gitconfig-coo (via GIT_CONFIG_GLOBAL)
# without touching the user's personal ~/.gitconfig.
#
# Signing posture is platform-dependent (MEMO 2026-04-23-04).
# The Claude Code cloud harness sets `gpg.ssh.program=/tmp/code-sign`, a
# wrapper that intercepts `ssh-keygen -Y sign` and substitutes a
# harness-managed key for the one user.signingkey names. Signed output
# produced in cloud is therefore bound to a key that is not on any
# GitHub account and can never pass verification (observed: local key
# SHA256:pZeA8xyc…3nA; signer in signature SHA256:32dP45eS…2wc).
# We detect the harness by the presence of the wrapper at /tmp/code-sign
# OR CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE being set, and turn
# commit.gpgsign/tag.gpgsign off there. Keys, allowed-signers file, and
# core.sshCommand stay set on both platforms so Mac sessions still sign
# normally and SSH auth works on both.
_coo_signing_is_intercepted() {
  [ -x /tmp/code-sign ] || [ -n "${CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE:-}" ]
}

write_coo_gitconfig() {
  local gc="${VADE_COO_GITCONFIG:-${HOME}/.gitconfig}"
  mkdir -p "$(dirname "$gc")"
  git config --file "$gc" user.name "COO"
  git config --file "$gc" user.email "coo@vade-app.dev"
  git config --file "$gc" gpg.format ssh
  git config --file "$gc" user.signingkey "${HOME}/.ssh/vade-coo-sign.pub"
  if _coo_signing_is_intercepted; then
    git config --file "$gc" commit.gpgsign false
    git config --file "$gc" tag.gpgsign false
    log "Configured $gc (user=COO, signing=OFF — cloud harness detected; MEMO 2026-04-23-04)"
  else
    git config --file "$gc" commit.gpgsign true
    git config --file "$gc" tag.gpgsign true
    log "Configured $gc (user=COO, signing=ssh via vade-coo-sign.pub)"
  fi
  git config --file "$gc" gpg.ssh.allowedSignersFile "${HOME}/.ssh/allowed_signers"
  git config --file "$gc" core.sshCommand "ssh -i ${HOME}/.ssh/vade-coo-auth -o IdentitiesOnly=yes -o UserKnownHostsFile=${HOME}/.ssh/known_hosts"
}

# Install the vade-coo git shim at the snapshot-persistent bindir,
# making `git push` route through git-push-with-fallback.sh by default
# (coo-harness#67 adoption-as-default — the wrapper has been merged
# since #74, but no path made it the default until this shim).
#
# The shim is a symlink to scripts/git-shim.sh in this repo. Removing
# the symlink restores the system git. Set VADE_DISABLE_GIT_SHIM=1 in
# the bootstrap env to skip installation entirely (useful for debug
# sessions where intercepting git push is undesirable).
#
# Idempotent: if the symlink already points to the right source, no-op.
# Fail-soft: refuses to clobber a non-symlink at the install path.
install_coo_git_shim() {
  if [ "${VADE_DISABLE_GIT_SHIM:-0}" = "1" ]; then
    log "git shim install: skipped (VADE_DISABLE_GIT_SHIM=1)"
    return 0
  fi

  local bindir shim_src wrapper shim_dst current_target
  bindir="$(_snapshot_user_bindir)"
  shim_src="$SCRIPT_DIR/git-shim.sh"
  wrapper="$SCRIPT_DIR/git-push-with-fallback.sh"

  if [ ! -x "$shim_src" ]; then
    log_err "git shim install: source not executable at $shim_src; skipping"
    return 1
  fi
  if [ ! -x "$wrapper" ]; then
    log_err "git shim install: wrapper missing at $wrapper; shim would no-op, skipping"
    return 1
  fi

  mkdir -p "$bindir"
  shim_dst="$bindir/git"

  if [ -e "$shim_dst" ] && [ ! -L "$shim_dst" ]; then
    log_err "git shim install: $shim_dst exists and is not a symlink; refusing to clobber"
    log_err "  remove it manually if you want the shim, or set VADE_DISABLE_GIT_SHIM=1"
    return 1
  fi

  if [ -L "$shim_dst" ]; then
    current_target="$(readlink -- "$shim_dst" 2>/dev/null || true)"
    if [ "$current_target" = "$shim_src" ]; then
      log "git shim install: already current at $shim_dst → $shim_src"
      return 0
    fi
  fi

  ln -sfn -- "$shim_src" "$shim_dst"
  log "git shim installed at $shim_dst → $shim_src (intercepts \`git push\`; bypass with VADE_GIT_SHIM_BYPASS=1)"
}

validate_coo_identity() {
  if [ -z "${GITHUB_MCP_PAT:-}" ]; then
    log "Skipping GitHub PAT validation (GITHUB_MCP_PAT unset; degraded bootstrap)"
    return 0
  fi
  local body login
  if ! body="$(retry 3 curl -sfH "Authorization: Bearer ${GITHUB_MCP_PAT}" https://api.github.com/user)"; then
    log "FATAL: GitHub /user lookup failed after retries; cannot confirm identity"
    return 1
  fi
  # GitHub's JSON is indented with spaces around the colon ("login": "...").
  # Tolerate optional whitespace so this doesn't silently fail.
  login="$(printf '%s' "$body" | grep -oE '"login"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/')"
  if [ "$login" != "vade-coo" ]; then
    log "FATAL: GitHub PAT validates as '${login:-unknown}', expected 'vade-coo'"
    return 1
  fi
  log "GitHub PAT valid for: $login"
}

# Quiet variant for the marker-shortcut precondition (#72): probes the
# already-cached $GITHUB_MCP_PAT and returns 0 only when GitHub
# confirms login=vade-coo. No retries (the marker shortcut is a fast
# path; if the network is down, fall through to the full bootstrap
# which has its own retry budget). No log output on the happy path —
# only on fail-and-fall-through, so the operator sees why the marker
# was bypassed. Single curl, hard 5s timeout — keeps the SessionStart
# happy path within the existing budget envelope.
_cached_pat_still_valid() {
  [ -n "${GITHUB_MCP_PAT:-}" ] || return 1
  local body login
  body="$(curl -sfH "Authorization: Bearer ${GITHUB_MCP_PAT}" --max-time 5 \
                  https://api.github.com/user 2>/dev/null)" || return 1
  login="$(printf '%s' "$body" | grep -oE '"login"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/')"
  [ "$login" = "vade-coo" ]
}

summarize_coo_identity() {
  local mode="active"
  [ -z "${GITHUB_MCP_PAT:-}" ] && mode="degraded (GITHUB_MCP_PAT unset)"
  log "COO identity $mode"
  if check_cmd ssh-keygen; then
    log "  auth  $(_fingerprint_of "${HOME}/.ssh/vade-coo-auth.pub" 2>/dev/null || echo unknown)"
    log "  sign  $(_fingerprint_of "${HOME}/.ssh/vade-coo-sign.pub" 2>/dev/null || echo unknown)"
  else
    log "  auth  (ssh-keygen unavailable; fingerprint not shown)"
    log "  sign  (ssh-keygen unavailable; fingerprint not shown)"
  fi
  log "  github pat:    $([ -n "${GITHUB_MCP_PAT:-}" ]  && echo present || echo MISSING)"
  log "  agentmail key: $([ -n "${AGENTMAIL_API_KEY:-}" ] && echo present || echo MISSING)"
}
