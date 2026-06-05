#!/usr/bin/env bash
# Bash wrapper invoked by the SessionEnd-hook chain (via vade-hooks/dispatch.sh).
# Sources ~/.vade/coo-env so R2_TRANSCRIPTS_* and TRANSCRIPTS_AGE_IDENTITY
# are populated, then runs the Python implementation.
#
# Detach discipline (coo-harness#181/#182, 2026-04-30):
# Under CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 (PR #177 / commit 9f706d7,
# 2026-04-29 03:23 UTC) the harness kills the SessionEnd hook process
# group before the Python export can finish — caught a 48-hour outage
# (R2 has zero objects from 2026-04-29 onward; eight parallel COO
# play-afternoon sessions of 2026-04-29 lost permanently). Foreground
# `exec` did not survive the kill.
#
# Fix: fork the Python via `setsid -f` into a new process session so
# the wrapper can return 0 quickly and the export survives the harness
# killing the SessionEnd hook process group.
#
# Wait-with-detach (coo-harness#198, 2026-05-03):
# `setsid -f` detach survives signal-based PG teardown but cannot
# survive PID-namespace destruction when a hosted Claude Code container
# terminates shortly after SessionEnd returns. 2026-05-02 saw 0/7
# hosted sessions export to R2 — the export pipeline takes ~5–10s
# (boto3 import, redact, encrypt, op-read, R2 PutObject, meta.json
# auto-commit) and the container outlived <1s of that. Same
# diagnostic shape as #181 (no <id>.export-error.txt drops because
# SIGKILL fires before signal handlers).
#
# This wrapper now block-waits for the detached child up to
# VADE_TRANSCRIPT_EXPORT_BUDGET_SEC (default 20s), holding the
# SessionEnd hook open so the container's grace window covers the
# export. Properties:
#   - agent-teams local: harness PG-kills the wrapper; child survives
#     via setsid -f (#182 behavior preserved).
#   - hosted with grace window: wrapper waits, child completes, clean
#     R2 export. ~5–10s user-visible session-end pause.
#   - hosted with immediate teardown: no worse than today.
#
# The Python script's own contract — always exit 0, drop
# <id>.export-error.txt on internal failure — is preserved.
#
# The fail-open contract holds: env-sourcing failure is non-fatal;
# the Python script handles missing R2/age creds by writing
# export-error.txt rather than raising.
#
# coo-labs/coo-logs#64 Batch 2; detach fix coo-harness#182;
# wait-with-detach coo-harness#198.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cold-start precondition (coo-harness#208): on a fresh hosted
# container the SessionEnd hook fires before Claude Code creates
# ~/.claude/projects/. Without this gate the Python script bails with
# "~/.claude/projects not found" and writes a cosmetic
# unknown.export-error.txt that pollutes operator dashboards. Treat
# the missing-projects case as a no-op: there's no live transcript to
# export, by definition.
if [ ! -d "${HOME}/.claude/projects" ]; then
  exit 0
fi

# Source coo-env if present (provides R2 + age secrets). Fail-open: if
# the file is missing, the Python script sees empty env vars and
# degrades to writing export-error.txt (per design — never blocks).
if [ -f "${HOME}/.vade/coo-env" ]; then
  # shellcheck disable=SC1090,SC1091
  . "${HOME}/.vade/coo-env" 2>/dev/null || true
fi

# Phase 2 (coo-memory#873) retired ~/.vade/coo-env. Resolve required
# secrets at call time via op read — routed through op-coo-wrap
# (coo-harness#443), so 1P SA-token rate-limit between primary and
# OP_SERVICE_ACCOUNT_TOKEN_BACKUP is absorbed transparently. Only
# sets vars that are currently unset, so callers (tests, manual
# re-runs) can override via env. Fail-open: missing op CLI, op-read
# failure, or empty values all leave the var unset; the Python
# script then writes export-error.txt per the existing contract.
_resolve_transcript_secrets() {
  command -v op >/dev/null 2>&1 || return 0
  _maybe_set() {
    local var="$1" ref="$2" val
    eval "test -n \"\${$var:-}\"" && return 0
    val="$(op read "$ref" 2>/dev/null)" || return 0
    [ -n "$val" ] && export "$var=$val"
  }
  _maybe_set R2_TRANSCRIPTS_ACCESS_KEY_ID     op://COO/r2-transcripts/access-key-id
  _maybe_set R2_TRANSCRIPTS_SECRET_ACCESS_KEY op://COO/r2-transcripts/secret-access-key
  _maybe_set R2_TRANSCRIPTS_ENDPOINT          op://COO/r2-transcripts/endpoint
  _maybe_set R2_TRANSCRIPTS_BUCKET            op://COO/r2-transcripts/bucket
  _maybe_set TRANSCRIPTS_AGE_IDENTITY         op://COO/transcripts-age-key/credential
  _maybe_set GITHUB_MCP_PAT                   op://COO/github-pat-vade-coo/token
}
_resolve_transcript_secrets

# Per-invocation log directory; created lazily so dry-run callers
# don't litter $HOME on first import.
LOG_DIR="${HOME}/.vade/transcript-export-logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Timestamped log filename so concurrent invocations don't collide and
# so post-hoc debugging is easy. Includes wrapper PID for cross-ref
# with /proc/<pid> when the process is still alive.
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/${TS}-$$.log"

# Marker file the detached child touches on completion. The wrapper
# polls for it inside the budget loop below.
MARKER="$LOG_DIR/${TS}-$$.done"

# Fork the Python child into a new session/PG so it survives the
# harness killing the SessionEnd hook process group. setsid -f
# (fork) is the load-bearing flag here — `nohup ... &; disown`
# alone wasn't enough under agent-teams (the harness kills by PG,
# not by signaling the wrapper). stdin closed; stdout/stderr to log.
# The child wrapper-script touches MARKER after the Python exits so
# the parent can detect completion without holding a child PID
# (setsid -f exits before exec'ing, so $! isn't the python's PID).
setsid -f bash -c \
  "\"$SCRIPT_DIR/session-end-transcript-export.py\" \"\$@\"; touch \"$MARKER\"" \
  -- "$@" \
  </dev/null >"$LOG_FILE" 2>&1

# Block-wait for the marker file up to BUDGET_SEC. On hosted
# ephemeral containers this holds the SessionEnd hook open so the
# container teardown grace window covers the export. On agent-teams
# local sessions the harness will PG-kill the wrapper before the
# budget elapses; the detached child survives via setsid -f and
# completes anyway (#182 behavior preserved).
#
# Budget sizing (coo-harness#207, 2026-05-03): the marker is
# touched after the entire Python pipeline exits, including
# _open_meta_pr's git fetch/switch/commit/push + gh pr create.
# Empirical worst case on cold cache: ~5-10s pre-R2 + ~5-15s for
# auto-PR git ops + ~3-5s for `gh pr create` = up to ~30s. The
# original 20s default left auto-PR to die mid-flight on hosted
# teardown (R2 PUT yes, meta.json git-push no — the asymmetry
# documented in #207). 60s covers the empirical worst case with
# margin while keeping the user-visible session-end pause bounded.
BUDGET_SEC="${VADE_TRANSCRIPT_EXPORT_BUDGET_SEC:-60}"
i=0
while [ "$i" -lt "$BUDGET_SEC" ]; do
  if [ -f "$MARKER" ]; then
    rm -f "$MARKER"
    break
  fi
  sleep 1
  i=$((i + 1))
done

# Whether the child completed within budget or not, return 0. The
# detached child keeps running on persistent envs; on hosted-teardown
# we did our best with the available grace window.
exit 0
