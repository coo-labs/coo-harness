#!/usr/bin/env bash
# session-idle-watchdog.sh — coo-labs/coo-logs#67.
#
# Background daemon that fires the mechanical session-end protocol when
# a Claude Code session goes idle without an explicit Stop. Solves the
# "I forget to trigger end" failure: without this, a session that goes
# quiet leaves no exported transcript, no session log, and no episodic
# Mem0 handoff for the next boot to pick up.
#
# Lifecycle:
#   1. SessionStart launches `session-idle-watchdog.sh --start` (the
#      bootstrap form). Bootstrap kills any prior watchdog by PID-file,
#      forks a `--run` worker via nohup, and exits 0 so the hook chain
#      doesn't block.
#   2. The `--run` worker polls
#      `~/.claude/projects/<slug>/<id>.jsonl` mtime every CHECK_SECONDS.
#      When (now - mtime) >= IDLE_THRESHOLD_MINUTES, it enters a grace
#      window of GRACE_MINUTES; any mtime advance during grace aborts
#      grace and resumes polling.
#   3. If grace passes without activity, the worker fires the close
#      sequence (--close), then exits 0.
#
# Close sequence (mark-only since coo-harness#204):
#   a. Write a stub session log at
#      <coo-logs>/sessions/YYYY/MM/DD/coo-idle-close-<id>.md
#      with status=incomplete, started_at/ended_at from jsonl event
#      timestamps, and a pointer to the meta.json sidecar IF one
#      already exists (from a prior SessionEnd that ran inside this
#      session's lifetime).
#   b. POST a minimal Mem0 episodic entry (event=session_summary,
#      idle_close=true, summary_pending=true, artifact_refs=[stub-log,
#      sidecar]) via the Mem0 REST API with $MEM0_API_KEY from coo-env.
#      Tier-1 safe text only — no transcript content (MEMO-2026-04-11-10).
#   c. git add + commit + push the stub-log and any new sidecar files
#      under `<coo-logs>/transcripts/**/<id>.{meta,export-error}.{json,txt}`.
#      Identity is the cloud container's vade-coo gitconfig + PAT, so
#      attribution stays correct.
#   d. PID-file cleanup, exit 0.
#
# Mark-only rationale (coo-harness#204, MEMO 2026-05-03-bgk3):
# Pre-#204 the watchdog also invoked session-end-transcript-export.sh
# from cmd_close — a second writer racing the SessionEnd-final hook
# against the same R2 key. Under age's non-deterministic encryption,
# the second write replaced the ciphertext bytes that the first
# writer's meta.json's `ciphertext_sha256` referenced — endemic 65%
# SHA mismatch (W18d data). The architectural fix pairs storage-level
# IfNoneMatch (in session-end-transcript-export.py:_r2_upload) with
# canonical-writer designation: SessionEnd-final wins, watchdog
# records intent only. The SIGTERM trap in cmd_run remains a
# last-resort export under container teardown — safe under
# IfNoneMatch since a parallel SessionEnd-final will cede cleanly.
#
# SessionStart on the next session reads any prior `coo-idle-close-*.md`
# files via `session-lifecycle.sh --start` and surfaces a boot reminder
# so the interactive COO can write the real summary as a sibling
# `coo-summary-on-<id>.md`.
#
# Config (via env, all optional):
#   VADE_SESSION_IDLE_MINUTES        idle threshold; default 60
#   VADE_SESSION_IDLE_GRACE_MINUTES  grace window;   default 5
#   VADE_SESSION_IDLE_CHECK_SECONDS  poll interval;  default 60
#   VADE_SESSION_IDLE_DISABLE=1      no-op the daemon (CI / local dev)
#   VADE_AGENT_LOGS_DIR              override agent-logs working tree
#
# This script never blocks the session-start hook chain — `--start`
# always exits 0, even when prerequisites are missing. The integrity-
# check probe surfaces gaps loudly so ops sees them on next boot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ---------------------------------------------------------------------------
# Constants + paths
# ---------------------------------------------------------------------------

STATE_DIR="${HOME}/.vade/agent-state"
LOG_DIR="${HOME}/.vade/idle-watchdog-logs"
COO_ENV="${HOME}/.vade/coo-env"
EXPORT_HOOK="$SCRIPT_DIR/session-end-transcript-export.sh"

IDLE_THRESHOLD_MINUTES="${VADE_SESSION_IDLE_MINUTES:-60}"
GRACE_MINUTES="${VADE_SESSION_IDLE_GRACE_MINUTES:-5}"
CHECK_SECONDS="${VADE_SESSION_IDLE_CHECK_SECONDS:-60}"

mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Logging — append-only, per-session log file
# ---------------------------------------------------------------------------

# Set after session id resolves; logs land in $LOG_DIR/<id>.log.
WATCHDOG_LOG=""

log() {
  local ts msg
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  msg="$ts session-idle-watchdog[$$]: $*"
  if [ -n "$WATCHDOG_LOG" ]; then
    printf '%s\n' "$msg" >> "$WATCHDOG_LOG" 2>/dev/null || true
  fi
  printf '%s\n' "$msg" >&2 || true
}

# ---------------------------------------------------------------------------
# jsonl resolution — most-recent under ~/.claude/projects/*/*.jsonl
# ---------------------------------------------------------------------------

resolve_active_jsonl() {
  local projects="$HOME/.claude/projects"
  local sid="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"

  # If an explicit session id was provided and a matching jsonl exists,
  # prefer that. Otherwise fall back to most-recent mtime — same logic
  # as session-end-transcript-export.py.
  if [ -d "$projects" ] && [ -n "$sid" ]; then
    local match
    match="$(find "$projects" -maxdepth 2 -type f -name "${sid}.jsonl" 2>/dev/null | head -1)"
    if [ -n "$match" ]; then
      printf '%s\n' "$match"
      return 0
    fi
  fi

  if [ -d "$projects" ]; then
    find "$projects" -maxdepth 2 -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | head -1 | cut -d' ' -f2-
  fi
}

jsonl_basename_id() {
  local p="$1"
  basename "$p" .jsonl
}

# Cross-platform mtime in seconds.
mtime_seconds() {
  local f="$1"
  if stat -c '%Y' -- "$f" >/dev/null 2>&1; then
    stat -c '%Y' -- "$f"
  else
    stat -f '%m' -- "$f"
  fi
}

# ---------------------------------------------------------------------------
# Bootstrap mode (--start): kill any prior watchdog, fork --run
# ---------------------------------------------------------------------------

cmd_start() {
  if [ "${VADE_SESSION_IDLE_DISABLE:-}" = "1" ]; then
    log "VADE_SESSION_IDLE_DISABLE=1 — skipping watchdog start"
    return 0
  fi

  local jsonl session_id pidfile
  jsonl="$(resolve_active_jsonl)"
  if [ -z "$jsonl" ] || [ ! -f "$jsonl" ]; then
    # No active transcript yet (first hook invocation can race). Don't
    # error — the watchdog has nothing to bind to. Next session will
    # find one.
    log "no active jsonl found under ~/.claude/projects; skipping start"
    return 0
  fi
  session_id="$(jsonl_basename_id "$jsonl")"
  pidfile="$STATE_DIR/idle-watchdog.${session_id}.pid"
  WATCHDOG_LOG="$LOG_DIR/${session_id}.log"

  # Kill any prior watchdog for this same session id. Idempotent
  # SessionStart re-fires (e.g. /resume) shouldn't accumulate workers.
  if [ -f "$pidfile" ]; then
    local prior_pid
    prior_pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$prior_pid" ] && kill -0 "$prior_pid" 2>/dev/null; then
      kill "$prior_pid" 2>/dev/null || true
      log "killed prior watchdog pid=$prior_pid"
    fi
    rm -f "$pidfile" 2>/dev/null || true
  fi

  log "starting watchdog for session_id=$session_id jsonl=$jsonl threshold=${IDLE_THRESHOLD_MINUTES}m grace=${GRACE_MINUTES}m"

  # Fork the worker. Pass the resolved jsonl path so the worker doesn't
  # re-resolve later (and pick a sibling under racy multi-instance use).
  nohup bash "$SCRIPT_DIR/session-idle-watchdog.sh" --run "$jsonl" \
    >> "$WATCHDOG_LOG" 2>&1 &
  disown $! 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# Run mode (--run <jsonl>): the polling worker
# ---------------------------------------------------------------------------

cmd_run() {
  local jsonl="${1:-}"
  if [ -z "$jsonl" ] || [ ! -f "$jsonl" ]; then
    log "cmd_run: missing or unreadable jsonl path: $jsonl"
    return 0
  fi

  local session_id pidfile
  session_id="$(jsonl_basename_id "$jsonl")"
  pidfile="$STATE_DIR/idle-watchdog.${session_id}.pid"
  WATCHDOG_LOG="$LOG_DIR/${session_id}.log"

  # Single-writer: refuse if a live PID-file exists.
  if [ -f "$pidfile" ]; then
    local prior_pid
    prior_pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$prior_pid" ] && [ "$prior_pid" != "$$" ] && kill -0 "$prior_pid" 2>/dev/null; then
      log "another watchdog is live (pid=$prior_pid); refusing to start"
      return 0
    fi
  fi
  echo "$$" > "$pidfile"
  trap 'rm -f "$pidfile" 2>/dev/null || true' EXIT
  trap 'log "SIGTERM received; running best-effort export-only close"; bash "$EXPORT_HOOK" </dev/null >/dev/null 2>&1 || true; rm -f "$pidfile" 2>/dev/null || true; exit 0' TERM

  local idle_sec=$(( IDLE_THRESHOLD_MINUTES * 60 ))
  local grace_sec=$(( GRACE_MINUTES * 60 ))

  log "worker live pid=$$ idle_sec=$idle_sec grace_sec=$grace_sec check_sec=$CHECK_SECONDS"

  while true; do
    sleep "$CHECK_SECONDS"
    if [ ! -f "$jsonl" ]; then
      log "jsonl disappeared at $jsonl; exiting"
      return 0
    fi
    local mtime now elapsed
    mtime="$(mtime_seconds "$jsonl")"
    now="$(date -u +%s)"
    elapsed=$(( now - mtime ))
    if [ "$elapsed" -lt "$idle_sec" ]; then
      continue
    fi

    # Threshold reached — enter grace.
    log "idle threshold reached (elapsed=${elapsed}s); entering grace=${grace_sec}s"
    local grace_start grace_now grace_mtime
    grace_start="$(date -u +%s)"
    while true; do
      sleep "$CHECK_SECONDS"
      grace_mtime="$(mtime_seconds "$jsonl")"
      if [ "$grace_mtime" -gt "$mtime" ]; then
        log "activity during grace (mtime advanced ${mtime} -> ${grace_mtime}); aborting close"
        break
      fi
      grace_now="$(date -u +%s)"
      if [ $(( grace_now - grace_start )) -ge "$grace_sec" ]; then
        log "grace expired without activity; firing close sequence"
        cmd_close "$session_id" "$jsonl" || true
        return 0
      fi
    done
  done
}

# ---------------------------------------------------------------------------
# Close sequence (--close <id> <jsonl>): the mechanical session-end work
# ---------------------------------------------------------------------------

cmd_close() {
  local session_id="${1:-}" jsonl="${2:-}"
  if [ -z "$session_id" ] || [ -z "$jsonl" ]; then
    log "cmd_close: missing args (session_id=$session_id jsonl=$jsonl)"
    return 0
  fi
  WATCHDOG_LOG="$LOG_DIR/${session_id}.log"

  # Phase 2 (coo-memory#873): coo-env retired. Secrets live in process env
  # (exported by bootstrap, inherited by this subprocess via normal fork).
  # The watchdog inherits MEM0_API_KEY, GITHUB_MCP_PAT, R2_* from the
  # session process tree — no explicit source needed. If coo-env still
  # exists from a Phase 1 bootstrap (e.g., upgrade path mid-session),
  # source it as a fallback, but do not log a degradation on absence.
  if [ -f "$COO_ENV" ]; then
    # shellcheck disable=SC1090,SC1091
    set +u; . "$COO_ENV"; set -u
    log "sourced legacy coo-env (Phase 1 snapshot)"
  else
    log "coo-env absent (Phase 2: secrets in process env via bootstrap inheritance)"
  fi

  # ---- a. Mark-only — no R2 export from cmd_close (coo-harness#204) ------
  # The watchdog records intent and writes the stub session log; the
  # canonical R2 write belongs to SessionEnd-final (or to the SIGTERM
  # trap in cmd_run if the container is tearing down with us alive).
  # Pre-#204 this step invoked session-end-transcript-export.sh and
  # raced the SessionEnd-final hook for the same session_id, producing
  # the W18d 65%-mismatch population. Removed deliberately.
  log "mark-only close (coo-harness#204): not invoking export hook from cmd_close"

  # Resolve agent-logs working tree once — both the closer-spawn path
  # and the stub-fallback path need it.
  local agent_logs_dir
  agent_logs_dir="$(_resolve_agent_logs_dir)"
  if [ -z "$agent_logs_dir" ]; then
    log "coo-logs working tree not found; cannot drop stub log"
    return 0
  fi

  # ---- a.5 Try the session-closer agent (coo-harness#148 Part B) ---------
  # If the closer succeeds, it writes a real session-log .md, the Mem0
  # episodic entry, and opens a PR — return early. If it fails or is
  # unavailable, fall through to the stub-write path (steps b/c/d).
  if _try_spawn_session_closer "$session_id" "$agent_logs_dir"; then
    log "session-closer succeeded; skipping stub fallback"
    return 0
  fi
  log "session-closer unavailable or failed; falling back to stub-write path"

  # ---- b. Stub session log -------------------------------------------------

  local first_ts last_ts ev_count idle_close_ts date_path
  first_ts="$(_jsonl_first_timestamp "$jsonl")"
  last_ts="$(_jsonl_last_timestamp "$jsonl")"
  ev_count="$(_jsonl_event_count "$jsonl")"
  idle_close_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Date for the path comes from the FIRST event so a long-running
  # session stays in its starting day (matching the export hook).
  date_path="$(_date_path_from_ts "$first_ts")"

  local sessions_dir stub_path
  sessions_dir="$agent_logs_dir/sessions/$date_path"
  mkdir -p "$sessions_dir" 2>/dev/null || true
  stub_path="$sessions_dir/coo-idle-close-${session_id}.md"

  # Locate the meta.json sidecar (if the export hook wrote one) so we
  # can reference it in the stub. Search transcripts/ rather than just
  # the date-path because clock skew or first-event-fallback can land
  # the sidecar one day off.
  local meta_path export_error_path
  meta_path="$(find "$agent_logs_dir/transcripts" -maxdepth 4 -type f -name "${session_id}.meta.json" 2>/dev/null | head -1)"
  export_error_path="$(find "$agent_logs_dir/transcripts" -maxdepth 4 -type f -name "${session_id}.export-error.txt" 2>/dev/null | head -1)"
  local idle_minutes
  idle_minutes=$(( (IDLE_THRESHOLD_MINUTES + GRACE_MINUTES) ))

  {
    echo "# COO session — idle close (incomplete)"
    echo
    echo "**Status:** incomplete — ended on idle timeout, summary deferred"
    echo "**Session ID:** \`$session_id\`"
    echo "**Started:** ${first_ts:-unknown}"
    echo "**Ended:**   ${last_ts:-unknown}"
    echo "**Idle close fired at:** $idle_close_ts"
    echo "**Idle minutes at close:** ~${idle_minutes} (threshold=${IDLE_THRESHOLD_MINUTES}m + grace=${GRACE_MINUTES}m)"
    echo "**Event count:** ${ev_count:-unknown}"
    echo
    if [ -n "$meta_path" ]; then
      echo "**Transcript sidecar:** \`${meta_path#"$agent_logs_dir/"}\`"
    fi
    if [ -n "$export_error_path" ]; then
      echo "**Transcript export error:** \`${export_error_path#"$agent_logs_dir/"}\`"
    fi
    echo
    echo "## How to continue"
    echo
    echo "The interactive COO on the next session should append a sibling"
    echo "\`coo-summary-on-${session_id}.md\` (or amend this file in place)"
    echo "with the real session summary — what was worked on, decisions made,"
    echo "open threads — so adoption-tracker grep paths still resolve."
    echo
    echo "Authoring this stub: \`coo-harness/scripts/lifecycle/session-idle-watchdog.sh\`"
    echo "(coo-labs/coo-logs#67)."
  } > "$stub_path"
  log "wrote stub session log: $stub_path"

  # ---- c. Mem0 minimal episodic entry --------------------------------------
  _mem0_post_idle_close "$session_id" "$first_ts" "$last_ts" "$idle_close_ts" \
    "$stub_path" "$meta_path" "$agent_logs_dir" || true

  # ---- d. git commit + push ------------------------------------------------
  _git_commit_and_push "$agent_logs_dir" "$stub_path" "$meta_path" "$export_error_path" "$session_id" || true

  log "close sequence complete for session_id=$session_id"
  return 0
}

# ---------------------------------------------------------------------------
# Helpers — closer-agent spawn, agent-logs resolution, jsonl
#          introspection, Mem0 POST, git push
# ---------------------------------------------------------------------------

# coo-harness#148 Part B: try to elevate from stub to real synthesized
# log by spawning the session-closer sub-agent. Returns 0 on success
# (closer wrote log + Mem0 + PR; caller should skip the stub path);
# returns 1 on any failure or unavailability (caller falls back to
# stub-write).
#
# Budget cap is bounded explicitly to avoid the closer running away —
# Sonnet at $3/Mtok input + max ~30 turns worth of work for a session
# log keeps each fire under ~$0.50 in the worst case.
_try_spawn_session_closer() {
  local session_id="${1:-}" agent_logs_dir="${2:-}"
  if [ -z "$session_id" ] || [ -z "$agent_logs_dir" ]; then
    log "_try_spawn_session_closer: missing args"
    return 1
  fi

  if [ "${VADE_SESSION_CLOSER_DISABLE:-}" = "1" ]; then
    log "session-closer disabled by VADE_SESSION_CLOSER_DISABLE=1"
    return 1
  fi

  if ! command -v claude >/dev/null 2>&1; then
    log "claude binary not on PATH; closer unavailable"
    return 1
  fi

  # Locate the meta.json the closer needs as input. Search transcripts/
  # rather than just the date-path because the export hook's date-path
  # is derived from first-event timestamp, not now.
  local meta_path
  meta_path="$(find "$agent_logs_dir/transcripts" -maxdepth 4 -type f \
    -name "${session_id}.meta.json" 2>/dev/null | head -1)"
  if [ -z "$meta_path" ]; then
    log "no meta.json for session_id=$session_id; closer cannot synthesize"
    return 1
  fi

  local prompt closer_log timeout_seconds
  closer_log="$LOG_DIR/${session_id}.closer.log"
  timeout_seconds="${VADE_SESSION_CLOSER_TIMEOUT_SECONDS:-900}"  # 15 min
  prompt="Synthesize a closer session log for session_id ${session_id}.

The meta.json is at ${meta_path}.

Follow your standard pipeline. Return the session-log path + PR URL."

  log "spawning session-closer (timeout=${timeout_seconds}s, log=$closer_log)"

  # Use --print for non-interactive mode + --max-budget-usd as a
  # belt-and-braces safety net. PAT is in env from bootstrap (Phase 2:
  # inherited via process env, not from coo-env file);
  # the closer reads MEM0_API_KEY + GITHUB_MCP_PAT directly.
  local rc=0
  timeout "${timeout_seconds}" claude \
      --agent session-closer \
      --print \
      --max-budget-usd "${VADE_SESSION_CLOSER_BUDGET_USD:-1.00}" \
      "$prompt" \
      >> "$closer_log" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ]; then
    log "session-closer returned rc=0; treating as success"
    return 0
  fi
  log "session-closer rc=$rc — falling back to stub-write path"
  return 1
}

_resolve_agent_logs_dir() {
  if [ -n "${VADE_AGENT_LOGS_DIR:-}" ] && [ -d "$VADE_AGENT_LOGS_DIR" ]; then
    printf '%s\n' "$VADE_AGENT_LOGS_DIR"; return 0
  fi
  for cand in \
    "$(dirname "$VADE_COO_MEMORY_DIR")/coo-logs" \
    "$HOME/GitHub/coo-labs/coo-logs"; do
    if [ -d "$cand" ]; then printf '%s\n' "$cand"; return 0; fi
  done
  return 1
}

_jsonl_first_timestamp() {
  local f="$1"
  awk '
    /^[[:space:]]*$/ { next }
    {
      if (match($0, /"timestamp"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^"timestamp"[[:space:]]*:[[:space:]]*"/, "", s)
        sub(/"$/, "", s)
        print s
        exit
      }
    }
  ' "$f" 2>/dev/null
}

_jsonl_last_timestamp() {
  local f="$1"
  awk '
    {
      if (match($0, /"timestamp"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^"timestamp"[[:space:]]*:[[:space:]]*"/, "", s)
        sub(/"$/, "", s)
        last = s
      }
    }
    END { if (last != "") print last }
  ' "$f" 2>/dev/null
}

_jsonl_event_count() {
  local f="$1"
  awk 'NF { n++ } END { print n+0 }' "$f" 2>/dev/null
}

_date_path_from_ts() {
  local ts="${1:-}"
  if [ -z "$ts" ]; then
    date -u +'%Y/%m/%d'
    return 0
  fi
  # ISO-8601 → YYYY/MM/DD. Best-effort string slicing avoids the
  # platform-dependent `date -d` flag.
  printf '%s\n' "$ts" | awk -F'[-T]' 'NF>=3 { printf "%s/%s/%s\n", $1, $2, $3; exit } { print "" }'
}

_mem0_post_idle_close() {
  local session_id="$1" first_ts="$2" last_ts="$3" close_ts="$4"
  local stub_path="$5" meta_path="$6" agent_logs_dir="$7"

  if [ -z "${MEM0_API_KEY:-}" ]; then
    log "MEM0_API_KEY not set; skipping Mem0 episodic write"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    log "jq or curl missing; skipping Mem0 episodic write"
    return 0
  fi

  local stub_ref meta_ref refs
  stub_ref="coo-logs/${stub_path#"$agent_logs_dir/"}"
  if [ -n "$meta_path" ]; then
    meta_ref="coo-logs/${meta_path#"$agent_logs_dir/"}"
    refs="$(jq -nc --arg a "$stub_ref" --arg b "$meta_ref" '[$a,$b]')"
  else
    refs="$(jq -nc --arg a "$stub_ref" '[$a]')"
  fi

  # Tier-1 safe content: structural facts about the session, no
  # transcript content (MEMO-2026-04-11-10).
  local message_text expiration
  message_text="Idle close fired for COO session_id=${session_id}; transcript-export hook ran mechanically. Summary pending — next interactive session owes the real summary. Started=${first_ts:-unknown} ended=${last_ts:-unknown} closed=${close_ts}."
  # 30 days out (approximate; ISO date only).
  expiration="$(date -u -d '+30 days' +%Y-%m-%d 2>/dev/null || date -u -v+30d +%Y-%m-%d 2>/dev/null || true)"

  local body
  body="$(jq -nc \
    --arg msg "$message_text" \
    --arg sid "$session_id" \
    --arg ftt "${first_ts:-}" \
    --arg ltt "${last_ts:-}" \
    --arg cts "$close_ts" \
    --arg exp "$expiration" \
    --argjson refs "$refs" \
    '{
      messages: [{ role: "assistant", content: $msg }],
      user_id: "ven",
      agent_id: "claude-code",
      infer: false,
      metadata: {
        memory_type: "episodic",
        event: "session_summary",
        idle_close: true,
        summary_pending: true,
        created_by: "coo",
        retention: "ephemeral",
        source_session: $sid,
        first_event_ts: $ftt,
        last_event_ts: $ltt,
        closed_at: $cts,
        artifact_refs: $refs,
        expiration_date: $exp
      }
    }')"

  local http_code
  http_code="$(curl -sS -o "$LOG_DIR/${session_id}.mem0-response.json" -w '%{http_code}' \
    -X POST "https://api.mem0.ai/v1/memories/" \
    -H "Authorization: Token ${MEM0_API_KEY}" \
    -H 'Content-Type: application/json' \
    --data "$body" 2>>"$WATCHDOG_LOG" || echo '000')"
  case "$http_code" in
    2*) log "mem0 episodic write ok (HTTP $http_code)";;
    *)  log "mem0 episodic write failed (HTTP $http_code); response in $LOG_DIR/${session_id}.mem0-response.json";;
  esac
  return 0
}

_git_commit_and_push() {
  local repo="$1" stub_path="$2" meta_path="$3" export_error_path="$4" session_id="$5"

  if [ ! -d "$repo/.git" ]; then
    log "git: $repo is not a git working tree; skipping commit/push"
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    log "git binary missing; skipping commit/push"
    return 0
  fi

  # Pre-flight: are we on a branch we can push? Default expectation is
  # main; the cloud container's gitconfig + PAT attribute as vade-coo.
  local branch
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"

  # Stage the stub log, the meta.json (if present), and an
  # export-error.txt (if present). Don't stage anything else — the
  # daemon must not surface unrelated dirty state.
  local rel
  for path in "$stub_path" "$meta_path" "$export_error_path"; do
    [ -z "$path" ] && continue
    [ ! -e "$path" ] && continue
    rel="${path#"$repo/"}"
    git -C "$repo" add -- "$rel" 2>>"$WATCHDOG_LOG" || true
  done

  if git -C "$repo" diff --cached --quiet 2>/dev/null; then
    log "git: nothing staged (no stub or sidecar changes); skipping commit"
    return 0
  fi

  local msg_subject msg_body commit_rc
  msg_subject="watchdog: idle close for ${session_id}"
  msg_body=$'Mechanical session-end protocol fired by\ncoo-harness/scripts/lifecycle/session-idle-watchdog.sh — the interactive\nCOO did not call /end before the idle threshold expired.\n\nNext interactive session owes the real summary; see the\ncoo-idle-close-*.md stub for the handoff.\n\ncoo-labs/coo-logs#67'

  if git -C "$repo" -c commit.gpgsign=false commit \
       -m "$msg_subject" -m "$msg_body" >>"$WATCHDOG_LOG" 2>&1; then
    log "git: committed on branch=$branch"
  else
    commit_rc=$?
    log "git: commit failed rc=$commit_rc; aborting push"
    return 0
  fi

  if git -C "$repo" push origin "$branch" >>"$WATCHDOG_LOG" 2>&1; then
    log "git: pushed to origin/$branch"
  else
    log "git: push failed (will retry on next interactive session via normal commit flow)"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Stop mode — kill the live worker for a given session id (for tests)
# ---------------------------------------------------------------------------

cmd_stop() {
  local session_id="${1:-}"
  if [ -z "$session_id" ]; then
    # Stop all watchdogs in $STATE_DIR.
    local pf
    for pf in "$STATE_DIR"/idle-watchdog.*.pid; do
      [ -f "$pf" ] || continue
      local pid
      pid="$(cat "$pf" 2>/dev/null || true)"
      [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
      rm -f "$pf" 2>/dev/null || true
    done
    return 0
  fi
  local pf="$STATE_DIR/idle-watchdog.${session_id}.pid"
  if [ -f "$pf" ]; then
    local pid
    pid="$(cat "$pf" 2>/dev/null || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$pf" 2>/dev/null || true
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
  local mode="${1:---start}"
  shift || true
  case "$mode" in
    --start|start|"")
      cmd_start
      ;;
    --run|run)
      cmd_run "$@"
      ;;
    --close|close)
      cmd_close "$@"
      ;;
    --stop|stop)
      cmd_stop "$@"
      ;;
    -h|--help|help)
      cat <<'EOF'
session-idle-watchdog.sh — coo-labs/coo-logs#67.

Usage:
  session-idle-watchdog.sh --start
      Bootstrap form (called from SessionStart hook). Kills any prior
      watchdog by PID-file, forks a --run worker, exits 0.
  session-idle-watchdog.sh --run <jsonl-path>
      Internal worker loop. Polls mtime; fires --close on idle.
  session-idle-watchdog.sh --close <session-id> <jsonl-path>
      Run the close sequence directly (used by the worker and by CI).
  session-idle-watchdog.sh --stop [<session-id>]
      Kill the live worker for a session id (or all, if omitted).

Env:
  VADE_SESSION_IDLE_MINUTES        idle threshold; default 60
  VADE_SESSION_IDLE_GRACE_MINUTES  grace window;   default 5
  VADE_SESSION_IDLE_CHECK_SECONDS  poll interval;  default 60
  VADE_SESSION_IDLE_DISABLE=1      no-op the daemon (CI / local dev)
  VADE_AGENT_LOGS_DIR              override agent-logs working tree
EOF
      exit 0
      ;;
    *)
      echo "session-idle-watchdog: unknown mode '$mode' (try --help)" >&2
      exit 0
      ;;
  esac
  return 0
}

main "$@"
