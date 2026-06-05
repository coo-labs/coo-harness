#!/usr/bin/env bash
# subscribe-discussion: poll a GitHub discussion thread; emit one stdout
# line per new top-level comment or reply.
#
# Analog to the harness `mcp__github__subscribe_pr_activity` primitive,
# closing the v0 of coo-harness#206. There is no upstream MCP tool for
# discussion activity yet; this script is the bridge until one lands.
#
# Suitable for the `Monitor` tool: each printed line is one event
# notification, flushed.
#
# Usage:
#   subscribe-discussion.sh <owner/repo> <number> [poll_seconds]
#
# Defaults: poll every 60s. Lower the interval for active dialogue;
# raise it for slow Q&A threads.
#
# State: per-thread "seen" file under
# ${VADE_CLOUD_STATE_DIR:-$HOME/.vade-cloud-state}/discussion-watch/
# records IDs of comments and replies already emitted, so restarts
# don't re-emit history. First run records the current state silently
# (no events emitted) and only future activity surfaces.
#
# Authentication: GITHUB_MCP_PAT or GH_TOKEN if set; otherwise falls back
# to `op read op://COO/github-pat-vade-coo/token` (the canonical PAT path
# used by gh-coo-wrap.sh) so Monitor-tool subshells, which post-Phase-2
# (coo-memory#873) don't inherit the PAT, still authenticate.
#
# Exit codes:
#   0  graceful shutdown (SIGINT/SIGTERM)
#   1  no GitHub token (env unset and op-read fallback failed)
#   2  argument error

set -eu

usage() {
  cat <<'EOF'
Usage: subscribe-discussion.sh <owner/repo> <number> [poll_seconds]

Poll a GitHub discussion thread; emit one stdout line per new comment
or reply, suitable for `Monitor` tail-streaming.

Arguments:
  <owner/repo>     Target repository (e.g. coo-labs/vade-canvas)
  <number>         Discussion number
  [poll_seconds]   Polling interval, default 60

Environment:
  GITHUB_MCP_PAT   GitHub PAT (preferred)
  GH_TOKEN         Fallback if MCP PAT unset
  (neither set)    Falls back to op read op://COO/github-pat-vade-coo/token
  VADE_CLOUD_STATE_DIR  State directory root (defaults to ~/.vade-cloud-state)

Examples:
  subscribe-discussion.sh coo-labs/vade-canvas 126
  subscribe-discussion.sh coo-labs/vade-canvas 999 30
EOF
}

if [ $# -lt 2 ]; then
  usage >&2
  exit 2
fi

case "$1" in -h|--help) usage; exit 0 ;; esac

repo="$1"
number="$2"
poll="${3:-60}"

if ! [[ "$repo" == */* ]]; then
  echo "error: repo must be in <owner/name> form (got: $repo)" >&2
  exit 2
fi
if ! [[ "$number" =~ ^[0-9]+$ ]]; then
  echo "error: number must be a positive integer (got: $number)" >&2
  exit 2
fi
if ! [[ "$poll" =~ ^[0-9]+$ ]]; then
  echo "error: poll_seconds must be a positive integer (got: $poll)" >&2
  exit 2
fi

owner="${repo%%/*}"
name="${repo##*/}"

token="${GITHUB_MCP_PAT:-${GH_TOKEN:-}}"
if [ -z "$token" ] && command -v op >/dev/null 2>&1; then
  # Post-Phase-2 (coo-memory#873) the PAT is not in tool-subshell env;
  # gh-coo-wrap.sh resolves it from 1Password at call time, but this
  # script's env-check runs before any wrapped `gh` call, so Monitor-tool
  # invocations see no PAT. Single-shot op-read fallback (no retry).
  token="$(op read op://COO/github-pat-vade-coo/token 2>/dev/null || true)"
fi
if [ -z "$token" ]; then
  echo "error: no GitHub token — GITHUB_MCP_PAT/GH_TOKEN unset and op read op://COO/github-pat-vade-coo/token failed" >&2
  exit 1
fi

state_root="${VADE_CLOUD_STATE_DIR:-$HOME/.vade-cloud-state}"
state_dir="$state_root/discussion-watch"
mkdir -p "$state_dir"
state_file="$state_dir/${owner}_${name}_${number}.seen"
touch "$state_file"

trap 'echo "[discussion-watch] shutdown ($repo#$number)" >&2; exit 0' INT TERM

read -r -d '' QUERY <<'GQL' || true
query($owner:String!,$repo:String!,$num:Int!){
  repository(owner:$owner,name:$repo){
    discussion(number:$num){
      title
      url
      comments(first:100){
        nodes{
          id
          databaseId
          author{login}
          createdAt
          url
          bodyText
          replies(first:50){
            nodes{
              id
              databaseId
              author{login}
              createdAt
              url
              bodyText
            }
          }
        }
      }
    }
  }
}
GQL

echo "[discussion-watch] subscribed: $repo#$number (poll ${poll}s)" >&2

while true; do
  if ! resp=$(GH_TOKEN="$token" gh api graphql \
      -f "query=$QUERY" \
      -F "owner=$owner" \
      -F "repo=$name" \
      -F "num=$number" 2>/dev/null); then
    echo "[discussion-watch] poll failed; retrying in ${poll}s" >&2
    sleep "$poll"
    continue
  fi

  STATE_FILE="$state_file" python3 - "$resp" <<'PY'
import json, os, sys

resp = json.loads(sys.argv[1])
state_file = os.environ['STATE_FILE']

with open(state_file, 'r') as f:
    seen = {line.strip() for line in f if line.strip()}

first_run = not seen
new_ids = []

discussion = resp.get('data', {}).get('repository', {}).get('discussion')
if not discussion:
    sys.exit(0)

def emit(kind, node):
    preview = (node.get('bodyText') or '').replace('\n', ' ').strip()
    if len(preview) > 140:
        preview = preview[:137] + '...'
    login = (node.get('author') or {}).get('login') or '<unknown>'
    print(f"[{kind}] {login} @ {node['createdAt']}: {preview}", flush=True)
    print(f"  {node['url']}", flush=True)

for c in discussion.get('comments', {}).get('nodes', []) or []:
    if c['id'] not in seen:
        new_ids.append(c['id'])
        if not first_run:
            emit('comment', c)
    for r in (c.get('replies', {}).get('nodes', []) or []):
        if r['id'] not in seen:
            new_ids.append(r['id'])
            if not first_run:
                emit('reply  ', r)

if new_ids:
    with open(state_file, 'a') as f:
        for nid in new_ids:
            f.write(nid + '\n')

if first_run and new_ids:
    print(f"[discussion-watch] initial state recorded: {len(new_ids)} existing items", file=sys.stderr, flush=True)
PY

  sleep "$poll"
done
