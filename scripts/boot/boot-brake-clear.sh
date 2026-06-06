#!/usr/bin/env bash
# SessionStart hook: per-session brake sentinel hygiene.
#
# Responsibilities:
#   - Initialize a PENDING sentinel for this session at
#     $VADE_CLOUD_STATE_DIR/boot-brake.<session_id>.json with the
#     boot_started_at timestamp set. The PreToolUse guard transitions
#     it to OK or FAIL on the first tool call after manifest validation.
#   - Clean up stale sentinels and expired override sentinels from
#     prior sessions in this container. Keeps state-dir bounded.
#   - Rotate brake-events.jsonl on UTC-day boundaries; compact daily
#     files older than the current month into a single .jsonl.gz
#     (coo-memory#1168 O6).
#   - Sweep aged-out validator-self-fault diagnostics in
#     boot-brake-faults/ (coo-memory#1168 O8).
#
# Always exits 0. Boot-impacting failures are logged but never block
# the session from starting.
#
# Reference: coo-memory#1082 v2 §6 (sentinel lifecycle);
# coo-memory#1168 (storage hygiene).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

boot_log_record boot-brake-clear start

VADE_CLOUD_STATE_DIR="${VADE_CLOUD_STATE_DIR:-$HOME/.vade-cloud-state}"
mkdir -p "$VADE_CLOUD_STATE_DIR" 2>/dev/null || true

# session_id: prefer SessionStart event JSON on stdin; fall back to env.
session_id=""
if [ ! -t 0 ]; then
  input="$(cat 2>/dev/null || true)"
  if [ -n "$input" ]; then
    session_id="$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || true)"
  fi
fi
[ -z "$session_id" ] && session_id="${CLAUDE_CODE_SESSION_ID:-unknown}"

# Initial PENDING sentinel — first PreToolUse will rewrite with OK/FAIL.
now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
sentinel="$VADE_CLOUD_STATE_DIR/boot-brake.${session_id}.json"

tmp="$sentinel.tmp.$$"
cat > "$tmp" 2>/dev/null <<EOF
{"state":"PENDING","checked_at":"$now","checked_at_epoch":0,"manifest_version":0,"failures":[],"boot_started_at":"$now","content_hashes":{}}
EOF
chmod 600 "$tmp" 2>/dev/null || true
mv -f "$tmp" "$sentinel" 2>/dev/null || rm -f "$tmp"

# SH2 (coo-memory#1167): mint per-session brake-key. 32 random bytes
# hex-encoded into $HOME/.vade/brake-key.<sid> mode 0600. Replaces the
# prior HMAC derivation that reused OP_SERVICE_ACCOUNT_TOKEN — that
# widened the SA-token exposure surface to anything that can Read
# /proc/self/environ and let any holder forge overrides. Per-session
# keying scopes forgery resistance to the file system, where
# read-boot-inlined-guard.sh denies Read on brake-key.* paths.
mkdir -p "$HOME/.vade" 2>/dev/null || true
key_file="$HOME/.vade/brake-key.${session_id}"
if [ ! -s "$key_file" ]; then
  key_tmp="$key_file.tmp.$$"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32 > "$key_tmp" 2>/dev/null || true
  elif command -v xxd >/dev/null 2>&1 && [ -r /dev/urandom ]; then
    head -c 32 /dev/urandom | xxd -p -c 100 > "$key_tmp" 2>/dev/null || true
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import secrets, sys; sys.stdout.write(secrets.token_hex(32))' > "$key_tmp" 2>/dev/null || true
  fi
  if [ -s "$key_tmp" ]; then
    chmod 600 "$key_tmp" 2>/dev/null || true
    mv -f "$key_tmp" "$key_file" 2>/dev/null || rm -f "$key_tmp"
  else
    rm -f "$key_tmp" 2>/dev/null || true
  fi
fi

# Stale-sentinel sweep: remove sentinels older than 24h whose session_id
# is not this one. Bounded; never deletes the live session's state.
find "$VADE_CLOUD_STATE_DIR" -maxdepth 1 -name "boot-brake.*.json" -mmin +1440 2>/dev/null \
  | while IFS= read -r path; do
      case "$(basename "$path")" in
        "boot-brake.${session_id}.json") continue ;;
      esac
      rm -f "$path" 2>/dev/null || true
    done

# Expired override-sentinel sweep in $HOME/.vade/.
# An empty/missing expires_at is treated as already-expired (security
# review SC2: empty expires_at must never imply "permanent").
mkdir -p "$HOME/.vade" 2>/dev/null || true
find "$HOME/.vade" -maxdepth 1 -name "boot-brake-override.*.json" 2>/dev/null \
  | while IFS= read -r path; do
      exp="$(jq -r '.expires_at // ""' "$path" 2>/dev/null || true)"
      if [ -z "$exp" ] || [ "$exp" \< "$now" ]; then
        rm -f "$path" 2>/dev/null || true
      fi
    done

# Old session-reads logs sweep (older than 24h)
find "$HOME/.vade" -maxdepth 1 -name "session-reads.*.log" -mmin +1440 2>/dev/null \
  -exec rm -f {} \; 2>/dev/null || true

# Old brake-keys sweep (older than 24h, never this session's). SH2.
find "$HOME/.vade" -maxdepth 1 -name "brake-key.*" -mmin +1440 2>/dev/null \
  | while IFS= read -r path; do
      case "$(basename "$path")" in
        "brake-key.${session_id}") continue ;;
      esac
      rm -f "$path" 2>/dev/null || true
    done

# Aged-out validator-self-fault diagnostics (coo-memory#1168 O8). A
# misconfigured manifest faults on every PreToolUse — without a sweep,
# boot-brake-faults/ accumulates thousands of files per day. Bound at
# 24h same as the sentinel sweep so a triage window survives long
# enough to inspect.
faults_dir="$VADE_CLOUD_STATE_DIR/boot-brake-faults"
if [ -d "$faults_dir" ]; then
  find "$faults_dir" -mindepth 1 -mmin +1440 -delete 2>/dev/null || true
fi

# Daily rotation of brake-events.jsonl (coo-memory#1168 O6). When the
# live event log straddles a UTC-day boundary, rename it to a dated
# sibling so the live file stays bounded and historical days are
# addressable by name. Idempotent: same-day re-fire is a no-op.
events_log="$VADE_CLOUD_STATE_DIR/brake-events.jsonl"
if [ -s "$events_log" ]; then
  today_utc="$(date -u +%Y-%m-%d 2>/dev/null || true)"
  mtime_utc="$(date -u -r "$events_log" +%Y-%m-%d 2>/dev/null || true)"
  if [ -n "$today_utc" ] && [ -n "$mtime_utc" ] && [ "$mtime_utc" != "$today_utc" ]; then
    dated="$VADE_CLOUD_STATE_DIR/brake-events.${mtime_utc}.jsonl"
    if [ -f "$dated" ]; then
      # Re-rotation to a date that already has a daily sibling
      # (shouldn't happen in practice — would require the clock to
      # walk backward, which boot-time hygiene shouldn't tolerate
      # silently). Concatenate rather than clobber so accumulated
      # events survive.
      cat "$events_log" >> "$dated" 2>/dev/null && : > "$events_log" 2>/dev/null
    else
      mv -f "$events_log" "$dated" 2>/dev/null && : > "$events_log" 2>/dev/null
    fi
    chmod 600 "$dated" 2>/dev/null || true
    : > "$events_log" 2>/dev/null
    chmod 600 "$events_log" 2>/dev/null || true
  fi
fi

# Monthly compaction (coo-memory#1168 O6). Daily files from months
# strictly older than the current YYYY-MM get concatenated into a
# single gzipped sibling — ~10x storage saving without losing any
# event. Idempotent: re-running on an already-compacted month folds
# any stray daily files in; the current month is never touched, so
# in-flight days are preserved.
current_ym="$(date -u +%Y-%m 2>/dev/null || echo 9999-99)"
for daily in "$VADE_CLOUD_STATE_DIR"/brake-events.????-??-??.jsonl; do
  [ -f "$daily" ] || continue
  fname="$(basename "$daily")"
  date_part="${fname#brake-events.}"
  date_part="${date_part%.jsonl}"
  ym="${date_part%-*}"
  [ "$ym" \< "$current_ym" ] || continue
  monthly_gz="$VADE_CLOUD_STATE_DIR/brake-events.${ym}.jsonl.gz"
  new_tmp="$monthly_gz.tmp.$$"
  {
    [ -f "$monthly_gz" ] && gunzip -c "$monthly_gz" 2>/dev/null
    cat "$daily" 2>/dev/null
  } | gzip > "$new_tmp" 2>/dev/null
  if [ -s "$new_tmp" ]; then
    mv -f "$new_tmp" "$monthly_gz" 2>/dev/null
    chmod 600 "$monthly_gz" 2>/dev/null || true
    rm -f "$daily" 2>/dev/null
  else
    rm -f "$new_tmp" 2>/dev/null
  fi
done

boot_log_record boot-brake-clear end ok "session=$session_id"
exit 0
