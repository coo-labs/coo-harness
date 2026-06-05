#!/usr/bin/env bash
# Print a compact boot digest of In Progress items on the VADE project
# board, grouped by Milestone.
#
# SessionStart hook; lands in the boot context as a system-reminder so
# the agent can read "what's in flight" without running the query itself.
# Replaces the "Boot recall" instruction that used to live in CLAUDE.md
# (coo-memory#813).
#
# Graceful no-op when GITHUB_TOKEN/GH_TOKEN is unset, when gh is missing,
# or when the API call fails. Never breaks session start.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

boot_log_record project-board-digest start
trap '_rc=$?; boot_log_record project-board-digest end $([ $_rc -eq 0 ] && echo ok || echo fail) rc=$_rc' EXIT

# wait_for_coo_bootstrap removed: this script now runs as an ordered
# child of coo-bootstrap.sh via post-bootstrap-chain.sh; bootstrap's
# env is in place by the time we sample the token.

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-${GITHUB_MCP_PAT:-}}}"
if [ -z "$TOKEN" ]; then
  log "GH_TOKEN unset; skipping project-board digest."
  exit 0
fi

if ! check_cmd gh || ! check_cmd jq; then
  log "gh or jq missing; skipping project-board digest."
  exit 0
fi

# The 2026-05-30 quota incident: `gh project item-list 1 --limit 1000`
# paged the whole 819-item board for ~910 GraphQL pts to surface ~37 In
# Progress items, and a build-time warm-burst multiplied that until the
# 5000-pt/hr quota drained.
#
# Fix: server-side filter via the undocumented `query` argument on
# `ProjectV2.items` (confirmed via schema introspection 2026-05-30; not
# in the published API reference but matches the project UI filter DSL).
# Single call, ~1 GraphQL pt, returns only matching items in one page.
#
# Coverage cap: `first: 100` — alarms if In Progress ever exceeds that.
RESPONSE="$(GH_TOKEN="$TOKEN" gh api graphql -f query='
{
  organization(login: "coo-labs") {
    projectV2(number: 1) {
      items(first: 100, query: "status:\"In Progress\"") {
        totalCount
        pageInfo { hasNextPage }
        nodes {
          content {
            __typename
            ... on Issue {
              number title
              repository { name }
              milestone { title }
            }
            ... on PullRequest {
              number title
              repository { name }
              milestone { title }
            }
          }
        }
      }
    }
  }
}' 2>/dev/null || echo '')"

if [ -z "$RESPONSE" ]; then
  log "project board GraphQL fetch failed; skipping digest."
  exit 0
fi

# Format: group by issue milestone, sort milestones alphabetically with
# "(no milestone)" last via the "~no-milestone" sort key.
printf '%s' "$RESPONSE" | jq -r '
  (.data.organization.projectV2.items // {nodes: [], totalCount: 0, pageInfo: {hasNextPage: false}}) as $items
  | $items.nodes as $ip
  | if ($ip | length) == 0 then
      "Boot: VADE project — no items In Progress."
    else
      ($ip
        | group_by(.content.milestone.title // "~no-milestone")
        | sort_by(.[0].content.milestone.title // "~no-milestone")
      ) as $groups
      | (
          "Boot: VADE project — In Progress (\($ip | length) item\(if ($ip|length)==1 then "" else "s" end) across \($groups | length) milestone\(if ($groups|length)==1 then "" else "s" end))\(if $items.pageInfo.hasNextPage then " [+\($items.totalCount - ($ip|length)) more — raise first:N]" else "" end):"
        ),
        ($groups[] | (
          "  [\(.[0].content.milestone.title // "(no milestone)")]"
        ), (
          .[] | "    \(.content.repository.name)#\(.content.number) — \(.content.title)"
        )),
        "URL: github.com/orgs/coo-labs/projects/1 (filter status:\"In Progress\")"
    end
'
