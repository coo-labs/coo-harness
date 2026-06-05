#!/usr/bin/env bash
# post-bootstrap-chain.sh — ordered execution of bootstrap-dependent hooks.
#
# Why this exists: Claude Code's SessionStart:startup matcher runs all
# hooks in parallel (docs.claude.com/en/docs/claude-code/hooks: "All
# matching hooks run in parallel"). Hooks that depend on coo-bootstrap-
# written state (settings.json env, .vade-cloud-state/integrity-check.json,
# the coo-bootstrap.log terminal entry) cannot reliably read that state
# as parallel siblings — the resulting wait+sentinel patches stacked four
# times in six weeks (#427, #442, #445, plus the brake's identity_consumed
# race). The architectural rule: bootstrap-dependent hooks run as ordered
# children of coo-bootstrap.sh, not as parallel siblings under SessionStart.
#
# coo-bootstrap.sh's _on_exit trap calls this script after fast integrity-
# check has written its JSON. Each child inherits bootstrap's env directly
# (PATs, MEM0_API_KEY, etc) without polling for a sentinel.
#
# Children, in order:
#   1. coo-identity-digest    — boot banner; renders integrity-check
#                               summary, identity layer, memos, etc.
#   2. discussions-digest     — recent coo-labs discussions
#   3. project-board-digest   — VADE board In-Progress items
#   4. session-idle-watchdog  — daemon start; the script's --start
#                               form forks a worker via nohup and
#                               returns immediately
#   5. integrity-check live   — E5–E9 network probes; backgrounded
#                               so it doesn't tail the chain
#
# Failure isolation: any single child failing must not block the rest.
# Each invocation is wrapped to swallow non-zero exits.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

boot_log_record post-bootstrap-chain start
trap '_rc=$?; boot_log_record post-bootstrap-chain end $([ $_rc -eq 0 ] && echo ok || echo fail) rc=$_rc' EXIT

LIFECYCLE_DIR="$SCRIPT_DIR/../lifecycle"

_run_child() {
  local name="$1" path="$2"
  shift 2
  if [ ! -x "$path" ] && [ ! -r "$path" ]; then
    log "post-bootstrap-chain: $name missing at $path; skipping"
    return 0
  fi
  bash "$path" "$@" || log "post-bootstrap-chain: $name exited non-zero (rc=$?); continuing"
}

_run_child coo-identity-digest    "$LIFECYCLE_DIR/coo-identity-digest.sh"
_run_child discussions-digest     "$LIFECYCLE_DIR/discussions-digest.sh"
_run_child project-board-digest   "$LIFECYCLE_DIR/project-board-digest.sh"
_run_child session-idle-watchdog  "$LIFECYCLE_DIR/session-idle-watchdog.sh" --start

# integrity-check live phase: backgrounded, output discarded.
# Updates integrity-check.json in place with E5–E9 results once probes
# complete. The boot banner (from the digest above) has already rendered
# fast-phase results; consumers reading later (debug-mode skill,
# /verify-secrets, etc.) get the merged result.
nohup bash "$SCRIPT_DIR/integrity-check.sh" >/dev/null 2>&1 < /dev/null &
disown 2>/dev/null || true

exit 0
