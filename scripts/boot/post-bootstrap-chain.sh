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

# Trace + fault-inject knobs for the Layer-1.5 ordering test (coo-memory#1250).
# Both are env-gated: unset = no overhead, no behavior change. The trace file
# is JSONL — one record per child — so the test can assert order + rc cleanly
# without parsing the production boot.log noise.
_chain_order=0
_trace_record() {
  local child="$1" rc="$2"
  [ -z "${VADE_POST_BOOTSTRAP_TRACE_OUT:-}" ] && return 0
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$VADE_POST_BOOTSTRAP_TRACE_OUT")" 2>/dev/null || return 0
  printf '{"ts":"%s","order":%d,"child":"%s","rc":%d}\n' \
    "$ts" "$_chain_order" "$child" "$rc" \
    >> "$VADE_POST_BOOTSTRAP_TRACE_OUT" 2>/dev/null || return 0
}

_run_child() {
  local name="$1" path="$2"
  shift 2
  _chain_order=$((_chain_order + 1))
  if [ "${VADE_POST_BOOTSTRAP_FAULT_INJECT:-}" = "$name" ]; then
    log "post-bootstrap-chain: $name fault-injected (rc=7); continuing"
    _trace_record "$name" 7
    return 0
  fi
  if [ ! -x "$path" ] && [ ! -r "$path" ]; then
    log "post-bootstrap-chain: $name missing at $path; skipping"
    _trace_record "$name" 0
    return 0
  fi
  local rc=0
  bash "$path" "$@" || { rc=$?; log "post-bootstrap-chain: $name exited non-zero (rc=$rc); continuing"; }
  _trace_record "$name" "$rc"
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
_chain_order=$((_chain_order + 1))
if [ "${VADE_POST_BOOTSTRAP_FAULT_INJECT:-}" = "integrity-check-live" ]; then
  log "post-bootstrap-chain: integrity-check-live fault-injected (skip); continuing"
  _trace_record "integrity-check-live" 7
else
  _trace_record "integrity-check-live" 0
  nohup bash "$SCRIPT_DIR/integrity-check.sh" >/dev/null 2>&1 < /dev/null &
  disown 2>/dev/null || true
fi

exit 0
