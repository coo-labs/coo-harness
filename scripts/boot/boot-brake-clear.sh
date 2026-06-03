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
#
# Always exits 0. Boot-impacting failures are logged but never block
# the session from starting.
#
# Reference: coo-memory#1082 v2 §6 (sentinel lifecycle).

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

boot_log_record boot-brake-clear end ok "session=$session_id"
exit 0
