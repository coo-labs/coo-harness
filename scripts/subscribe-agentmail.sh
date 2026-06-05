#!/usr/bin/env bash
# subscribe-agentmail: poll an AgentMail inbox; emit one stdout line per
# new received message.
#
# Analog to subscribe-discussion.sh — same Monitor-friendly shape: each
# printed line is one event notification, flushed.
#
# Usage:
#   subscribe-agentmail.sh <inbox> [poll_seconds]
#
# Defaults: poll every 60s.
#
# State: per-inbox "seen" file under
# ${VADE_CLOUD_STATE_DIR:-$HOME/.vade-cloud-state}/agentmail-watch/
# records message IDs already emitted, so restarts don't re-emit
# history. First run records the current state silently (no events
# emitted) and only future activity surfaces.
#
# Filter: only emits messages labelled "received" (inbound). Skips
# outbound `sent` from the same inbox; webhook noise (drafts, etc.)
# is excluded by the same filter.
#
# Authentication: AGENTMAIL_API_KEY if set; otherwise falls back to
# `op read op://COO/agentmail-api-vade-coo/credential` (the canonical key
# path), so Monitor-tool subshells — which post-Phase-2 (coo-memory#873)
# don't inherit the key in their env — still authenticate.
#
# Exit codes:
#   0  graceful shutdown (SIGINT/SIGTERM)
#   1  no AgentMail key (env unset and op-read fallback failed)
#   2  argument error

set -eu

usage() {
  cat <<'EOF'
Usage: subscribe-agentmail.sh <inbox> [poll_seconds]

Poll an AgentMail inbox; emit one stdout line per new received
message, suitable for `Monitor` tail-streaming.

Arguments:
  <inbox>          Inbox address (e.g. vade-coo@agentmail.to)
  [poll_seconds]   Polling interval, default 60

Environment:
  AGENTMAIL_API_KEY     AgentMail API key (preferred)
  (unset)               Falls back to op read op://COO/agentmail-api-vade-coo/credential
  VADE_CLOUD_STATE_DIR  State directory root (defaults to ~/.vade-cloud-state)

Examples:
  subscribe-agentmail.sh vade-coo@agentmail.to
  subscribe-agentmail.sh vade-coo@agentmail.to 30
EOF
}

if [ $# -lt 1 ]; then
  usage >&2
  exit 2
fi

case "$1" in -h|--help) usage; exit 0 ;; esac

inbox="$1"
poll="${2:-60}"

if ! [[ "$inbox" == *@* ]]; then
  echo "error: inbox must be in <user>@<domain> form (got: $inbox)" >&2
  exit 2
fi
if ! [[ "$poll" =~ ^[0-9]+$ ]]; then
  echo "error: poll_seconds must be a positive integer (got: $poll)" >&2
  exit 2
fi

if [ -z "${AGENTMAIL_API_KEY:-}" ] && command -v op >/dev/null 2>&1; then
  # Post-Phase-2 (coo-memory#873) the key is not in tool-subshell env;
  # the MCP env materializer resolves it from 1Password, but this Monitor
  # script reads the env directly. Single-shot op-read fallback, no retry.
  AGENTMAIL_API_KEY="$(op read op://COO/agentmail-api-vade-coo/credential 2>/dev/null || true)"
fi
if [ -z "${AGENTMAIL_API_KEY:-}" ]; then
  echo "error: no AgentMail key — AGENTMAIL_API_KEY unset and op read op://COO/agentmail-api-vade-coo/credential failed" >&2
  exit 1
fi

state_root="${VADE_CLOUD_STATE_DIR:-$HOME/.vade-cloud-state}"
state_dir="$state_root/agentmail-watch"
mkdir -p "$state_dir"
safe_name=$(echo "$inbox" | tr '@/' '__')
state_file="$state_dir/${safe_name}.seen"
touch "$state_file"

trap 'echo "[agentmail-watch] shutdown ($inbox)" >&2; exit 0' INT TERM

echo "[agentmail-watch] subscribed: $inbox (poll ${poll}s)" >&2

while true; do
  if ! resp=$(curl -s -H "Authorization: Bearer $AGENTMAIL_API_KEY" \
      "https://api.agentmail.to/v0/inboxes/$inbox/messages?limit=20" 2>/dev/null); then
    echo "[agentmail-watch] poll failed; retrying in ${poll}s" >&2
    sleep "$poll"
    continue
  fi

  STATE_FILE="$state_file" python3 - "$resp" <<'PY'
import json, os, sys

try:
    resp = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

state_file = os.environ['STATE_FILE']

with open(state_file, 'r') as f:
    seen = {line.strip() for line in f if line.strip()}

first_run = not seen
new_ids = []

messages = resp.get('messages', []) or []

def emit(m):
    labels = m.get('labels', []) or []
    if 'received' not in labels:
        return
    sender = m.get('from') or ''
    # Suppress GitHub notification mirrors that arrive in the agentmail
    # inbox via coo@vade-app.dev forwarding. They are too frequent to be
    # useful as event signal — PR / issue activity has its own webhook
    # primitive (mcp__github__subscribe_pr_activity). The same exclusion
    # also covers `noreply.github.com` and `reply.github.com` for
    # robustness across header variants.
    if any(s in sender for s in (
        'notifications@github.com',
        '@noreply.github.com',
        '@reply.github.com',
    )):
        return
    preview = (m.get('preview') or '').replace('\n', ' ').strip()
    if len(preview) > 140:
        preview = preview[:137] + '...'
    sender = m.get('from') or '<unknown>'
    subject = m.get('subject') or '(no subject)'
    print(f"[message] {sender} @ {m.get('timestamp', '?')}: {subject}", flush=True)
    print(f"  preview: {preview}", flush=True)
    print(f"  thread:  {m.get('thread_id')}", flush=True)
    print(f"  msg_id:  {m.get('message_id')}", flush=True)

for m in messages:
    mid = m.get('message_id')
    if not mid:
        continue
    if mid not in seen:
        new_ids.append(mid)
        if not first_run:
            emit(m)

if new_ids:
    with open(state_file, 'a') as f:
        for nid in new_ids:
            f.write(nid + '\n')

if first_run and new_ids:
    print(f"[agentmail-watch] initial state recorded: {len(new_ids)} existing items", file=sys.stderr, flush=True)
PY

  sleep "$poll"
done
