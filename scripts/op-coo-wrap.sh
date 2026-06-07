#!/usr/bin/env bash
# op-coo-wrap: transparent 1Password SA-token rate-limit fallback.
#
# 1Password enforces a per-SA 24h read/write quota. Once the standard
# OP_SERVICE_ACCOUNT_TOKEN trips it, every `op read` returns rc=1 with
# stderr "Too many requests. Your client has been rate-limited" — which
# breaks gh-coo-wrap's _resolve_pat, breaks the schema-driven secret
# fetch in coo-bootstrap.sh, and breaks every consumer that does an
# on-demand op-read.
#
# Phase 2 (#873) made the latency exposure worse because it retired
# the settings.json::env mirror — every gh / Bash-tool subprocess now
# has to op-read at call time, multiplying the rate-limit blast radius.
#
# The structural fix: a second SA token (OP_SERVICE_ACCOUNT_TOKEN_BACKUP)
# is already provisioned. Its SA identity sits in the .op-sa-identity
# allowlist alongside the primary's. coo-bootstrap.sh swaps to it
# in-process when the primary is rate-limited at session start, but
# the swap doesn't escape the bootstrap's process tree — every
# subsequent Bash-tool subprocess sees the rate-limited primary again.
#
# This shim closes that gap. It path-shadows `op` at
# /home/user/.local/bin/op; the real binary moves to
# /home/user/.local/bin/op-real (mirrors gh-coo-wrap). On every
# invocation:
#
#   1. Pick a token by marker preference (or primary if no marker).
#   2. Run op-real. If rc=0 or non-rate-limit error, exit through.
#   3. On rate-limit AND a different alternate token is available,
#      swap to the alternate, retry once. On retry success (or any
#      non-rate-limit retry outcome) update the marker so subsequent
#      invocations skip the probe. On retry rate-limit, leave the
#      marker untouched (no point ping-ponging) and surface the error.
#
# The shim is transparent to callers: stdout streams as-is, stderr is
# buffered then replayed verbatim, exit code is the real op's exit
# code (from the final attempt). The only externally observable
# behavior change is "rate-limit no longer breaks calls when the
# alternate token has budget."
#
# Marker: tmpfs file at $XDG_RUNTIME_DIR/coo-op-wrap/active (falls back
# to /tmp/coo-op-wrap/active). Contents: "A" (use OP_SERVICE_ACCOUNT_TOKEN)
# or "B" (use OP_SERVICE_ACCOUNT_TOKEN_BACKUP). Container-ephemeral by
# design: rebooting the container forgets the preference, which is fine
# — fresh probe on first call, the rate-limit clears on a 24h window
# anyway.
#
# Caller overrides:
#   COO_OP_REAL=/path/to/op-real   — alternate real-binary path
#   COO_OP_WRAP_DISABLE=1          — bypass the shim entirely (exec op-real)
#   COO_OP_WRAP_TRACE=1            — write decisions to /dev/shm/coo-op-wrap.trace
#
# Marker (DO NOT REMOVE): COO-OP-COO-WRAP-MARKER-v1

set -u

WRAPPER_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
WRAPPER_DIR="$(dirname "$WRAPPER_PATH")"

# Resolve the real op binary.
REAL_OP="${COO_OP_REAL:-/home/user/.local/bin/op-real}"
if [ ! -x "$REAL_OP" ]; then
  REAL_OP=""
  oldifs="$IFS"; IFS=:
  for d in $PATH; do
    IFS="$oldifs"
    [ "$d" = "$WRAPPER_DIR" ] && { IFS=:; continue; }
    if [ -x "$d/op" ] && ! grep -q 'COO-OP-COO-WRAP-MARKER-v1' "$d/op" 2>/dev/null; then
      REAL_OP="$d/op"
      break
    fi
    IFS=:
  done
  IFS="$oldifs"
fi

if [ -z "$REAL_OP" ] || [ ! -x "$REAL_OP" ]; then
  printf 'op-coo-wrap: real op binary not found (COO_OP_REAL=%s); refusing to run.\n' "${COO_OP_REAL:-unset}" >&2
  exit 127
fi

# Bypass on request — used by self-tests of the real op binary.
if [ "${COO_OP_WRAP_DISABLE:-0}" = "1" ]; then
  exec "$REAL_OP" "$@"
fi

# Marker setup.
PREF_DIR="${XDG_RUNTIME_DIR:-/tmp}/coo-op-wrap"
PREF_FILE="$PREF_DIR/active"
mkdir -p "$PREF_DIR" 2>/dev/null || true
chmod 0700 "$PREF_DIR" 2>/dev/null || true

# Capture all candidate tokens as locals so we can swap freely without
# losing track of any. If a slot is unset we skip it in the rotation;
# if only one is set, we degrade to single-attempt.
_token_a="${OP_SERVICE_ACCOUNT_TOKEN:-}"
_token_b="${OP_SERVICE_ACCOUNT_TOKEN_BACKUP:-}"
_token_c="${OP_SERVICE_ACCOUNT_TOKEN_BACKUP2:-}"

# Read marker preference. Default to A (the env's OP_SERVICE_ACCOUNT_TOKEN).
_pref="A"
if [ -f "$PREF_FILE" ]; then
  _pref="$(cat "$PREF_FILE" 2>/dev/null || echo A)"
  case "$_pref" in A|B|C) ;; *) _pref="A" ;; esac
fi

# Build the attempt order as a circular rotation starting at the marker.
# Order A: A B C | order B: B C A | order C: C A B. Unset slots get pruned
# below so a single configured token still works as a single-attempt path.
case "$_pref" in
  A) _order="A B C" ;;
  B) _order="B C A" ;;
  C) _order="C A B" ;;
esac

# Resolve names to tokens, skipping unset slots. Parallel arrays for token
# value and name; iterated in attempt order.
_names=()
_toks=()
for _n in $_order; do
  case "$_n" in
    A) _t="$_token_a" ;;
    B) _t="$_token_b" ;;
    C) _t="$_token_c" ;;
  esac
  if [ -n "$_t" ]; then
    _names+=("$_n")
    _toks+=("$_t")
  fi
done

_trace() {
  [ "${COO_OP_WRAP_TRACE:-0}" = "1" ] || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> /dev/shm/coo-op-wrap.trace 2>/dev/null || true
}

# Rate-limit shape detection.
_is_rate_limit() {
  printf '%s' "${1:-}" | grep -qiE 'rate.?limit|too many requests'
}

# ── Per-call jsonl event sink (coo-harness#540 / briefing-40 §2) ──
# Emits one jsonl event per `op` invocation to
# /dev/shm/coo-op-reads-L2.<session>.jsonl when COO_OP_WRAP_LOG_READS=1.
# Default-on for sessions; CI fixtures set it to 0 to keep mock-op
# output deterministic. Failure to write the event never propagates —
# logging is best-effort, the op call's contract is unchanged.
#
# Cap per session at 10K events to bound worst case (~3 MB).
COO_OP_WRAP_LOG_READS="${COO_OP_WRAP_LOG_READS:-1}"
_log_max=10000
_log_path=""
_session_id=""
_container_id=""
_phase=""
_caller_cmd=""
_op_sub=""
_op_path=""

# Minimal JSON escape — subset of common.sh::_json_escape, inlined to
# avoid sourcing common.sh on the op hot path. Handles the five cases
# that recur in caller_cmd / stderr_tail.
_je() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

_log_setup() {
  [ "$COO_OP_WRAP_LOG_READS" = "1" ] || return 0
  _session_id="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_CODE_REMOTE_SESSION_ID:-unknown}}"
  _session_id="${_session_id#cse_}"
  _container_id="${CLAUDE_CODE_CONTAINER_ID:-unknown}"
  _log_path="/dev/shm/coo-op-reads-L2.${_session_id}.jsonl"

  # Phase classification: bootstrap (pre-marker or ancestry contains
  # coo-bootstrap.sh), monitor (subscribe-*.sh ancestor), hook (postuse-
  # or preuse-*), default steady-state.
  if [ ! -f "$HOME/.vade/.coo-bootstrap-done" ]; then
    _phase="bootstrap"
  else
    _phase="steady-state"
  fi
  local _ancestor_cmd="" _wp="$PPID" _hop _new_p _ac
  for _hop in 1 2 3 4; do
    [ -r "/proc/$_wp/status" ] || break
    _new_p="$(awk '/^PPid:/ {print $2}' "/proc/$_wp/status" 2>/dev/null)"
    [ -z "$_new_p" ] || [ "$_new_p" = "0" ] && break
    _wp="$_new_p"
    if [ -r "/proc/$_wp/cmdline" ]; then
      _ac="$(tr '\0' ' ' < "/proc/$_wp/cmdline" 2>/dev/null)"
      _ancestor_cmd="$_ancestor_cmd $_ac"
    fi
  done
  case "$_ancestor_cmd" in
    *coo-bootstrap.sh*)   _phase="bootstrap" ;;
    *subscribe-*.sh*)     _phase="monitor" ;;
    *postuse-*|*preuse-*) _phase="hook" ;;
  esac

  _caller_cmd="$(tr '\0' ' ' < "/proc/$PPID/cmdline" 2>/dev/null | head -c 240)"

  # Extract op subcommand + op:// path (first matching argv positional).
  # Paths are data, not secrets; ok to log. Values would be secrets and
  # are never captured here (stdout flows past us unread).
  local _a
  for _a in "$@"; do
    case "$_a" in
      -*) continue ;;
      *)
        if [ -z "$_op_sub" ]; then
          _op_sub="$_a"
        elif [ -z "$_op_path" ]; then
          case "$_a" in op://*) _op_path="$_a" ;; esac
        fi
        ;;
    esac
  done
}

# Emit one Layer 2 jsonl event. Arguments: rc, token_slot, latency_ms,
# attempt_index (1-based), stderr_tail (truncated). No-op when logging
# disabled, log_path unresolvable, or cap reached.
_emit_event() {
  [ "$COO_OP_WRAP_LOG_READS" = "1" ] || return 0
  [ -n "$_log_path" ] || return 0

  if [ -f "$_log_path" ]; then
    local _count
    _count="$(wc -l < "$_log_path" 2>/dev/null || echo 0)"
    [ "$_count" -ge "$_log_max" ] 2>/dev/null && return 0
  fi

  local rc="$1" token="$2" latency_ms="$3" attempt="$4" stderr_tail="${5:-}"
  local ts rate_limited=false
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  _is_rate_limit "$stderr_tail" && rate_limited=true

  # Truncate stderr_tail to 240 chars before escaping.
  stderr_tail="${stderr_tail:0:240}"

  printf '{"ts":"%s","layer":"L2","session_id":"%s","container_id":"%s","phase":"%s","caller_pid":%d,"caller_cmd":"%s","op_subcommand":"%s","op_path":"%s","token_slot":"%s","latency_ms":%d,"rc":%d,"rate_limited":%s,"retry_attempt_index":%d,"stderr_tail":"%s"}\n' \
    "$ts" \
    "$(_je "$_session_id")" \
    "$(_je "$_container_id")" \
    "$_phase" \
    "$PPID" \
    "$(_je "$_caller_cmd")" \
    "$(_je "$_op_sub")" \
    "$(_je "$_op_path")" \
    "$token" \
    "$latency_ms" \
    "$rc" \
    "$rate_limited" \
    "$((attempt - 1))" \
    "$(_je "$stderr_tail")" \
    >> "$_log_path" 2>/dev/null || true
}

# One-shot setup (resolves session, phase, caller info, op-sub/path).
_log_setup "$@"

# Buffer stderr so we can inspect for rate-limit while still replaying
# verbatim. Stdout flows through directly — op's interesting payload is
# on stdout, and capturing it would risk truncating large reads.
_err_tmp=""
_cleanup() { [ -n "$_err_tmp" ] && rm -f "$_err_tmp" || true; }
trap _cleanup EXIT

_err_tmp="$(mktemp 2>/dev/null || echo "/tmp/op-coo-wrap.$$.err")"
: > "$_err_tmp"

# Iterate through configured tokens. Each attempt:
#   - rc=0 OR non-rate-limit error → stop (don't keep probing on legitimate failures)
#   - rate-limit AND another token available → advance to next
#   - rate-limit AND last token → surface rate-limit error
# On a stop, if the stopping token differs from the marker preference,
# update the marker so subsequent invocations skip the doomed-token probe.
_rc=0
_stopped_name=""
_attempt=0
_n_tokens=${#_toks[@]}

if [ "$_n_tokens" -eq 0 ]; then
  # No tokens at all — let op surface its own auth error.
  _trace "attempt 1: no tokens configured; running real op without OP_SERVICE_ACCOUNT_TOKEN"
  _start_ms="$(date -u +%s%3N 2>/dev/null || echo 0)"
  "$REAL_OP" "$@" 2>"$_err_tmp"
  _rc=$?
  _end_ms="$(date -u +%s%3N 2>/dev/null || echo 0)"
  _emit_event "$_rc" "?" "$((_end_ms - _start_ms))" 1 "$(head -c 240 "$_err_tmp" 2>/dev/null || true)"
else
  for _i in "${!_toks[@]}"; do
    _attempt=$((_attempt + 1))
    _n="${_names[$_i]}"
    _t="${_toks[$_i]}"
    [ "$_attempt" -gt 1 ] && : > "$_err_tmp"
    _trace "attempt $_attempt: token=$_n argv=$*"
    _start_ms="$(date -u +%s%3N 2>/dev/null || echo 0)"
    OP_SERVICE_ACCOUNT_TOKEN="$_t" "$REAL_OP" "$@" 2>"$_err_tmp"
    _rc=$?
    _end_ms="$(date -u +%s%3N 2>/dev/null || echo 0)"
    _emit_event "$_rc" "$_n" "$((_end_ms - _start_ms))" "$_attempt" "$(head -c 240 "$_err_tmp" 2>/dev/null || true)"
    if [ "$_rc" -eq 0 ] || ! _is_rate_limit "$(cat "$_err_tmp" 2>/dev/null)"; then
      _stopped_name="$_n"
      break
    fi
    # Rate-limited: if a next token exists, advance and retry.
    if [ "$((_i + 1))" -lt "$_n_tokens" ]; then
      _next_n="${_names[$((_i + 1))]}"
      _trace "attempt $_attempt rate-limited; advancing $_n -> $_next_n"
    else
      _trace "attempt $_attempt rate-limited; no further tokens; marker unchanged ($_pref)"
    fi
  done

  # Update marker if we stopped on a token other than the preferred one.
  # If _stopped_name is empty, every token rate-limited; leave marker untouched.
  if [ -n "$_stopped_name" ] && [ "$_stopped_name" != "$_pref" ]; then
    printf '%s' "$_stopped_name" > "$PREF_FILE" 2>/dev/null || true
    _trace "marker -> $_stopped_name (was $_pref)"
  fi
fi

# Replay stderr verbatim.
cat "$_err_tmp" >&2 2>/dev/null || true
exit "$_rc"
