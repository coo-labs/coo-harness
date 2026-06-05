#!/usr/bin/env bash
# subscribe-pr-watch: poll a GitHub PR's mergeable state, reviews, and
# inline review comments; emit one stdout line per new event.
#
# Closes two gaps in `mcp__github__subscribe_pr_activity`:
#
#   1. Author-filter regression (anthropics/claude-code#62096, our
#      coo-harness#286): pull_request_review and
#      pull_request_review_comment webhooks deliver only when the author
#      matches the session's connecting GitHub identity. Reviews from
#      other authors are dropped at the delivery layer; data remains
#      available via the REST API. This script polls the REST API and
#      re-emits the dropped events.
#
#   2. Mergeable-state transitions (coo-harness#254): GitHub does not
#      fire a webhook when mergeable_state flips from clean to dirty
#      after base-branch motion; only polling sees these. Same surface
#      as the prior subscribe-pr-mergeable.sh, now folded into one
#      Monitor per PR.
#
# Suitable for the `Monitor` tool: each printed line is one event
# notification, flushed. Exits 0 once the PR enters a terminal state
# (MERGED or CLOSED).
#
# Usage:
#   subscribe-pr-watch.sh <owner/repo> <pr-number> [poll_seconds]
#
# Default poll is 30s. Three API calls per poll (pr view + reviews +
# comments) × 1 PR × 60min/30s = 360 calls/hr/PR; well under the 5000/hr
# PAT limit even with several concurrent watches.
#
# State: per-PR last-known values under
# ${VADE_CLOUD_STATE_DIR:-$HOME/.vade-cloud-state}/pr-watch/<owner>__<repo>__<n>.state
#
#   line 1: last-seen mergeable concrete value (MERGEABLE|CONFLICTING)
#   line 2: last-seen review id (max numeric)
#   line 3: last-seen review-comment id (max numeric)
#
# First run records current state silently (no event emitted) so the
# historical backlog doesn't flood the session on subscribe; only future
# transitions and new items surface.
#
# UNKNOWN handling on mergeable: GitHub reports UNKNOWN transiently
# while it recomputes after a push. Transitions through UNKNOWN are not
# emitted; only transitions between concrete states fire events.
#
# Authentication: GITHUB_MCP_PAT or GH_TOKEN if set; otherwise falls back
# to `op read op://COO/github-pat-vade-coo/token` (the canonical PAT path
# used by gh-coo-wrap.sh). The fallback covers Monitor-tool subshells,
# which post-Phase-2 (coo-memory#873) don't inherit the PAT in their env.
#
# Exit codes:
#   0  graceful shutdown (SIGINT/SIGTERM) or terminal state (MERGED/CLOSED)
#   1  no GitHub token (env unset and op-read fallback failed)
#   2  argument error

set -eu

usage() {
  cat <<'EOF'
Usage: subscribe-pr-watch.sh <owner/repo> <pr-number> [poll_seconds]

Poll a GitHub PR for new reviews, inline review comments, and
mergeable-state transitions; emit one stdout line per new event,
suitable for `Monitor` tail-streaming.

Closes the subscribe_pr_activity author-filter regression on
pull_request_review[_comment] events (anthropics/claude-code#62096)
plus the mergeable-state webhook gap (coo-harness#254). Single
Monitor per PR.

Arguments:
  <owner/repo>     Target repository (e.g. coo-labs/coo-memory)
  <pr-number>      Pull request number
  [poll_seconds]   Polling interval, default 30

Environment:
  GITHUB_MCP_PAT        GitHub PAT (preferred)
  GH_TOKEN              Fallback if MCP PAT unset
  (neither set)         Falls back to op read op://COO/github-pat-vade-coo/token
  VADE_CLOUD_STATE_DIR  State directory root (defaults to ~/.vade-cloud-state)

Examples:
  subscribe-pr-watch.sh coo-labs/coo-memory 734
  subscribe-pr-watch.sh coo-labs/coo-harness 411 15
EOF
}

if [ $# -lt 2 ]; then
  usage >&2
  exit 2
fi

case "$1" in -h|--help) usage; exit 0 ;; esac

repo="$1"
number="$2"
poll="${3:-30}"

if ! [[ "$repo" == */* ]]; then
  echo "error: repo must be in <owner/name> form (got: $repo)" >&2
  exit 2
fi
if ! [[ "$number" =~ ^[0-9]+$ ]]; then
  echo "error: pr-number must be a positive integer (got: $number)" >&2
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
  # invocations see no PAT. Single-shot op-read fallback (no retry — the
  # poll loop's gh calls have their own per-call failure handling).
  token="$(op read op://COO/github-pat-vade-coo/token 2>/dev/null || true)"
fi
if [ -z "$token" ]; then
  echo "error: no GitHub token — GITHUB_MCP_PAT/GH_TOKEN unset and op read op://COO/github-pat-vade-coo/token failed" >&2
  exit 1
fi

state_root="${VADE_CLOUD_STATE_DIR:-$HOME/.vade-cloud-state}"
state_dir="$state_root/pr-watch"
mkdir -p "$state_dir"
state_file="$state_dir/${owner}__${name}__${number}.state"

trap 'echo "[pr-watch] shutdown ($repo#$number)" >&2; exit 0' INT TERM

last_mergeable=""
last_review_id=0
last_comment_id=0
first_run=1
if [ -f "$state_file" ]; then
  v1="$(sed -n '1p' "$state_file" 2>/dev/null || true)"
  v2="$(sed -n '2p' "$state_file" 2>/dev/null || true)"
  v3="$(sed -n '3p' "$state_file" 2>/dev/null || true)"
  case "$v1" in MERGEABLE|CONFLICTING) last_mergeable="$v1" ;; esac
  [[ "$v2" =~ ^[0-9]+$ ]] && last_review_id="$v2"
  [[ "$v3" =~ ^[0-9]+$ ]] && last_comment_id="$v3"
  first_run=0
fi

save_state() {
  printf '%s\n%s\n%s\n' "$last_mergeable" "$last_review_id" "$last_comment_id" > "$state_file"
}

# Coerce any jq output to a non-negative integer; falls back to 0 on
# non-array responses (e.g. GitHub error envelopes).
max_id_of() {
  printf '%s' "$1" | jq 'if type=="array" then ([.[].id] | (max // 0)) else 0 end' 2>/dev/null || echo 0
}

echo "[pr-watch] subscribed: $repo#$number (poll ${poll}s)" >&2

while true; do
  # 1. PR-level state (covers mergeable + terminal in one call).
  if pr_json=$(GH_TOKEN="$token" gh pr view "$number" \
      --repo "$repo" \
      --json state,mergeable,mergeStateStatus 2>/dev/null); then
    pr_ok=1
  else
    pr_ok=0
    pr_json='{}'
  fi

  state="$(printf '%s' "$pr_json"  | jq -r '.state // ""'            2>/dev/null || true)"
  merge="$(printf '%s' "$pr_json"  | jq -r '.mergeable // ""'        2>/dev/null || true)"
  status="$(printf '%s' "$pr_json" | jq -r '.mergeStateStatus // ""' 2>/dev/null || true)"

  # 2. Reviews + inline review comments.
  if reviews_json=$(GH_TOKEN="$token" gh api \
      -H "Accept: application/vnd.github+json" \
      "repos/$owner/$name/pulls/$number/reviews?per_page=100" 2>/dev/null); then
    reviews_ok=1
  else
    reviews_ok=0
    reviews_json="[]"
  fi
  if comments_json=$(GH_TOKEN="$token" gh api \
      -H "Accept: application/vnd.github+json" \
      "repos/$owner/$name/pulls/$number/comments?per_page=100" 2>/dev/null); then
    comments_ok=1
  else
    comments_ok=0
    comments_json="[]"
  fi

  max_review_id=$(max_id_of "$reviews_json")
  max_comment_id=$(max_id_of "$comments_json")

  if [ "$first_run" = "1" ]; then
    if [ "$pr_ok" = "1" ] && [ "$reviews_ok" = "1" ] && [ "$comments_ok" = "1" ]; then
      case "$merge" in
        MERGEABLE|CONFLICTING) last_mergeable="$merge" ;;
        *) last_mergeable="" ;;
      esac
      last_review_id="$max_review_id"
      last_comment_id="$max_comment_id"
      save_state
      first_run=0
      echo "[pr-watch] initial: mergeable=$last_mergeable review_id=$last_review_id comment_id=$last_comment_id" >&2
    else
      echo "[pr-watch] initial poll failed; retrying in ${poll}s" >&2
    fi
  else
    # Mergeable transitions (skip UNKNOWN / empty).
    case "$merge" in
      MERGEABLE|CONFLICTING)
        if [ -n "$last_mergeable" ] && [ "$merge" != "$last_mergeable" ]; then
          echo "PR $repo#$number mergeable: $last_mergeable → $merge (mergeStateStatus=$status)"
        fi
        last_mergeable="$merge"
        ;;
      UNKNOWN|"")
        : # transient — don't emit, don't update last_mergeable
        ;;
    esac

    # New reviews (skip PENDING drafts — only the author sees them).
    new_reviews=$(printf '%s' "$reviews_json" | jq -r --argjson lid "$last_review_id" '
      if type=="array" then
        [.[] | select(.id > $lid) | select(.state != "PENDING")]
        | sort_by(.id)
        | .[]
        | "review \(.id) \(.user.login) \(.state) \(.submitted_at // "") \(((.body // "") | gsub("[\n\r]+"; " ") | .[0:160]))"
      else empty end
    ' 2>/dev/null || true)
    if [ -n "$new_reviews" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] && echo "PR $repo#$number $line"
      done <<<"$new_reviews"
    fi

    # New inline review comments.
    new_comments=$(printf '%s' "$comments_json" | jq -r --argjson lid "$last_comment_id" '
      if type=="array" then
        [.[] | select(.id > $lid)]
        | sort_by(.id)
        | .[]
        | "review-comment \(.id) \(.user.login) \(.path):\(.line // .original_line // 0) \(.created_at // "") \(((.body // "") | gsub("[\n\r]+"; " ") | .[0:160]))"
      else empty end
    ' 2>/dev/null || true)
    if [ -n "$new_comments" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] && echo "PR $repo#$number $line"
      done <<<"$new_comments"
    fi

    if [[ "$max_review_id" =~ ^[0-9]+$ ]] && [ "$max_review_id" -gt "$last_review_id" ]; then
      last_review_id="$max_review_id"
    fi
    if [[ "$max_comment_id" =~ ^[0-9]+$ ]] && [ "$max_comment_id" -gt "$last_comment_id" ]; then
      last_comment_id="$max_comment_id"
    fi
    save_state
  fi

  # Terminal state, after emitting any backlog from this cycle.
  case "$state" in
    MERGED|CLOSED)
      echo "PR $repo#$number $state (final)"
      rm -f "$state_file"
      exit 0
      ;;
  esac

  sleep "$poll"
done
