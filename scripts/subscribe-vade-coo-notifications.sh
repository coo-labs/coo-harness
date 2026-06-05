#!/usr/bin/env bash
# subscribe-vade-coo-notifications: poll GitHub's notifications API for the
# vade-coo user; emit one stdout line per new participating notification.
#
# Closes coo-memory#841: a session-side push-shaped primitive for
# @vade-coo mentions across all repos, without depending on a session-spawn
# (coo-on-assign workflow) or a per-issue subscription. Cloud sessions can't
# be pushed to; this is the cleanest pull-as-push the cloud product permits.
#
# Suitable for the `Monitor` tool: each printed line is one event
# notification, flushed.
#
# Usage:
#   subscribe-vade-coo-notifications.sh [poll_seconds]
#
# Defaults: poll every 60s.
#
# State: single timestamp file under
# ${VADE_CLOUD_STATE_DIR:-$HOME/.vade-cloud-state}/notifications-watch/
# records the high-watermark `updated_at` we've already emitted. On each
# poll the script asks GitHub `?since=<watermark>` and only fresh activity
# comes back. First run records the current time silently (no events
# emitted) and only future activity surfaces.
#
# Scope: queries `notifications?participating=true&all=false`. That filter
# is server-side and returns only notifications where the user is directly
# participating or mentioned — exactly the surface we want. Notifications
# from passive repo-watch don't fire. The script does not mark notifications
# as read on GitHub (that's Ven's UI's responsibility); the high-watermark
# is the only state.
#
# Authentication: GITHUB_PUBLIC_PAT (the COO's classic-shape PAT). The
# notifications endpoint is a user-level API; user-level scopes only exist on
# classic PATs or on fine-grained PATs whose Resource Owner is the user
# (not the org). GITHUB_MCP_PAT — the org-scoped fine-grained PAT used for
# attributable writes — only exposes Repository + Organization permissions
# and returns 403 on /notifications. GH_TOKEN is the final fallback for
# non-COO contexts. When none of these is in the env (e.g. a Monitor-tool
# subshell post-Phase-2, coo-memory#873), the script falls back to
# `op read op://COO/github-pat-classic-public/credential` — the classic
# PAT's canonical path. Script detects 403 and exits with a FATAL message.
#
# Exit codes:
#   0  graceful shutdown (SIGINT/SIGTERM)
#   1  no GitHub token (env unset and op-read fallback failed)  OR  token lacks notifications scope
#   2  argument error

set -eu

usage() {
  cat <<'EOF'
Usage: subscribe-vade-coo-notifications.sh [poll_seconds]

Poll the vade-coo user's GitHub notifications feed; emit one stdout line
per new participating notification (mention, assign, review_requested,
comment, etc.), suitable for `Monitor` tail-streaming.

Arguments:
  [poll_seconds]   Polling interval, default 60

Environment:
  GITHUB_PUBLIC_PAT     COO classic-shape PAT (required — the notifications
                        endpoint is a user-level API and GITHUB_MCP_PAT
                        lacks the scope; see header comment)
  GH_TOKEN              Final fallback for non-COO contexts
  (none set)            Falls back to op read op://COO/github-pat-classic-public/credential
  VADE_CLOUD_STATE_DIR  State directory root (defaults to ~/.vade-cloud-state)

Examples:
  subscribe-vade-coo-notifications.sh
  subscribe-vade-coo-notifications.sh 30
EOF
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

poll="${1:-60}"

if ! [[ "$poll" =~ ^[0-9]+$ ]]; then
  echo "error: poll_seconds must be a positive integer (got: $poll)" >&2
  exit 2
fi

token="${GITHUB_PUBLIC_PAT:-${GH_TOKEN:-}}"
if [ -z "$token" ] && command -v op >/dev/null 2>&1; then
  # Post-Phase-2 (coo-memory#873) the PAT is not in tool-subshell env;
  # this endpoint needs the classic public-repo PAT (see header), so fall
  # back to its canonical 1Password path. Single-shot, no retry.
  token="$(op read op://COO/github-pat-classic-public/credential 2>/dev/null || true)"
fi
if [ -z "$token" ]; then
  echo "error: no GitHub token — GITHUB_PUBLIC_PAT/GH_TOKEN unset and op read op://COO/github-pat-classic-public/credential failed" >&2
  exit 1
fi

state_root="${VADE_CLOUD_STATE_DIR:-$HOME/.vade-cloud-state}"
state_dir="$state_root/notifications-watch"
mkdir -p "$state_dir"
state_file="$state_dir/since.txt"

# First-run gate: if there's no watermark yet, write the current time and
# proceed. The first /notifications?since=<now> call returns only items
# updated after this moment, so the first poll is a silent baseline.
if [ ! -s "$state_file" ]; then
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "$now" >"$state_file"
  echo "[notifications-watch] initial state recorded at $now (no events emitted)" >&2
fi

trap 'echo "[notifications-watch] shutdown" >&2; exit 0' INT TERM

echo "[notifications-watch] subscribed: vade-coo participating notifications (poll ${poll}s)" >&2

poll_attempt=0
while true; do
  poll_attempt=$((poll_attempt + 1))
  since=$(cat "$state_file")

  if ! resp=$(GH_TOKEN="$token" gh api \
      "notifications?all=false&participating=true&per_page=50&since=${since}" \
      2>/tmp/notif-stderr.$$); then
    err=$(cat /tmp/notif-stderr.$$ 2>/dev/null || echo "")
    rm -f /tmp/notif-stderr.$$
    if echo "$err" | grep -q 'Resource not accessible by personal access token'; then
      echo "[notifications-watch] FATAL: token lacks notifications scope." >&2
      echo "[notifications-watch] Notifications is a user-level API; org-scoped fine-grained" >&2
      echo "[notifications-watch] PATs (like GITHUB_MCP_PAT) return 403. Use GITHUB_PUBLIC_PAT" >&2
      echo "[notifications-watch] (the COO classic-shape PAT) or a fine-grained PAT whose" >&2
      echo "[notifications-watch] Resource Owner is the user with Account.Notifications.Read." >&2
      exit 1
    fi
    echo "[notifications-watch] poll failed (attempt ${poll_attempt}); retrying in ${poll}s: $err" >&2
    sleep "$poll"
    continue
  fi
  rm -f /tmp/notif-stderr.$$

  resp_file=$(mktemp -t notif-resp.XXXXXX)
  watermark_file=$(mktemp -t notif-wm.XXXXXX)
  printf '%s' "$resp" >"$resp_file"

  RESP_FILE="$resp_file" WM_FILE="$watermark_file" python3 - <<'PY'
import json, os, sys

try:
    with open(os.environ['RESP_FILE'], 'r') as f:
        items = json.load(f)
except Exception:
    sys.exit(0)

if not isinstance(items, list) or not items:
    sys.exit(0)

def emit(n):
    reason = n.get('reason') or '<unknown>'
    repo = (n.get('repository') or {}).get('full_name') or '<unknown>'
    subject = n.get('subject') or {}
    title = (subject.get('title') or '').replace('\n', ' ').strip()
    if len(title) > 120:
        title = title[:117] + '...'
    stype = subject.get('type') or ''
    url = subject.get('latest_comment_url') or subject.get('url') or ''
    updated = n.get('updated_at') or ''

    # Translate the API url to the human-readable html_url for
    # convenience: api.github.com/repos/X/Y/issues/N/comments/Z →
    # github.com/X/Y/issues/N#issuecomment-Z. Best-effort; if it doesn't
    # match the expected shape, emit the API URL unchanged.
    html_url = url
    if 'api.github.com/repos/' in url:
        rest = url.split('api.github.com/repos/', 1)[1]
        if '/issues/comments/' in rest:
            issue_api = subject.get('url') or ''
            if 'api.github.com/repos/' in issue_api:
                issue_path = issue_api.split('api.github.com/repos/', 1)[1]
                comment_id = rest.rsplit('/', 1)[-1]
                html_url = f'https://github.com/{issue_path}#issuecomment-{comment_id}'
        elif '/issues/' in rest and '/comments/' in rest:
            parts = rest.split('/comments/')
            issue_path = parts[0]
            comment_id = parts[1]
            html_url = f'https://github.com/{issue_path}#issuecomment-{comment_id}'
        elif '/pulls/' in rest:
            html_url = f'https://github.com/{rest.replace("/pulls/", "/pull/", 1)}'
        elif '/issues/' in rest:
            html_url = f'https://github.com/{rest}'

    print(f'[notification:{reason}] {repo} {stype}: {title} @ {updated}', flush=True)
    print(f'  {html_url}', flush=True)

# API returns newest first — reverse so events arrive chronologically.
items.reverse()
max_updated = ''
for n in items:
    updated = n.get('updated_at') or ''
    if updated and updated > max_updated:
        max_updated = updated
    emit(n)

if max_updated:
    with open(os.environ['WM_FILE'], 'w') as f:
        f.write(max_updated)
PY

  # If the python child wrote a new high-watermark, advance state.
  # GitHub uses RFC3339 timestamps which sort lexically — comparing
  # since-as-string to new-watermark-as-string is correct.
  if [ -s "$watermark_file" ]; then
    new_wm=$(cat "$watermark_file")
    # Advance by 1 second to avoid re-fetching the same boundary item.
    # GitHub's `since` is inclusive: items with updated_at == since are
    # returned. Advancing ensures monotonic forward progress.
    if command -v date >/dev/null 2>&1; then
      new_wm_advanced=$(date -u -d "$new_wm 1 second" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$new_wm")
      echo "$new_wm_advanced" >"$state_file"
    else
      echo "$new_wm" >"$state_file"
    fi
  fi

  rm -f "$resp_file" "$watermark_file"

  sleep "$poll"
done
