#!/usr/bin/env bash
# Print a compact digest of recent coo-labs org discussions.
#
# Designed to run on every Claude Code session start (via the
# SessionStart hook installed by install-agent-hooks.sh). Also safe
# to run inline from bootstrap.sh / cloud-setup.sh as a catch-up.
#
# Graceful no-op when GITHUB_TOKEN/GH_TOKEN is unset, when curl/node
# are missing, or when the GraphQL request fails. Never breaks
# session start.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

boot_log_record discussions-digest start
trap '_rc=$?; boot_log_record discussions-digest end $([ $_rc -eq 0 ] && echo ok || echo fail) rc=$_rc' EXIT

# wait_for_coo_bootstrap removed: this script now runs as an ordered
# child of coo-bootstrap.sh via post-bootstrap-chain.sh; bootstrap's
# env is in place by the time we sample the token.

TOKEN="${GITHUB_TOKEN:-${GITHUB_MCP_PAT:-}}"
if [ -z "$TOKEN" ]; then
  log "GITHUB_TOKEN unset; skipping discussions digest."
  trap - EXIT
  boot_log_record discussions-digest end skip "reason=no-token"
  exit 0
fi

if ! check_cmd curl || ! check_cmd node; then
  log "curl or node missing; skipping discussions digest."
  exit 0
fi

STATE_DIR="$HOME/.vade/agent-state"
CURSOR_FILE="$STATE_DIR/discussions-cursor"
mkdir -p "$STATE_DIR" 2>/dev/null || true

if [ -f "$CURSOR_FILE" ] && [ -s "$CURSOR_FILE" ]; then
  CURSOR="$(cat "$CURSOR_FILE")"
else
  CURSOR="$(node -e "console.log(new Date(Date.now()-7*24*3600*1000).toISOString())")"
fi

NOW="$(node -e "console.log(new Date().toISOString())")"

QUERY=$(cat <<'EOF'
{"query":"query { repository(owner: \"coo-labs\", name: \"vade-canvas\") { discussions(first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { title number url updatedAt category { name } comments { totalCount } author { login } } } } }"}
EOF
)

RESPONSE="$(curl -sS --max-time 10 \
  -H "Authorization: bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "User-Agent: vade-discussions-digest" \
  -d "$QUERY" \
  https://api.github.com/graphql 2>/dev/null || echo '')"

if [ -z "$RESPONSE" ]; then
  log "GraphQL request failed; skipping digest (cursor not advanced)."
  exit 0
fi

PARSE_OK=0
node -e '
const resp = JSON.parse(process.argv[1]);
const cursor = process.argv[2];
if (resp.errors && resp.errors.length) {
  console.error("[vade-setup] discussions GraphQL errors: " + JSON.stringify(resp.errors));
  process.exit(2);
}
const nodes = (((resp.data || {}).repository || {}).discussions || {}).nodes || [];
const cursorTs = Date.parse(cursor);
const recent = nodes.filter(n => Date.parse(n.updatedAt) > cursorTs).slice(0, 10);

function humanAgo(t) {
  const s = Math.max(1, Math.floor((Date.now() - t) / 1000));
  if (s < 60) return s + "s ago";
  if (s < 3600) return Math.floor(s/60) + "m ago";
  if (s < 86400) return Math.floor(s/3600) + "h ago";
  return Math.floor(s/86400) + "d ago";
}

if (recent.length === 0) {
  console.log("Boot: coo-labs discussions — no new since " + cursor + ".");
} else {
  console.log("Boot: coo-labs discussions, " + recent.length + " new/updated since " + cursor + ":");
  for (const n of recent) {
    const cat = (n.category || {}).name || "?";
    const author = (n.author || {}).login || "?";
    console.log("  #" + n.number + " [" + cat.toLowerCase() + "] " + n.title +
                " (" + humanAgo(Date.parse(n.updatedAt)) + ", @" + author +
                ", " + n.comments.totalCount + "c)");
  }
  console.log("URLs: github.com/orgs/coo-labs/discussions/<num>; norms: operations/agent-boot-discussions-check.md");
}
' "$RESPONSE" "$CURSOR" && PARSE_OK=1

if [ "$PARSE_OK" -eq 1 ]; then
  echo "$NOW" > "$CURSOR_FILE"
fi
