#!/usr/bin/env bash
# gh-pr-create: thin wrapper around `gh pr create` that pre-checks the
# body for a closing keyword (Pattern B from
# operations/issue-pr-hygiene.md §"Closing-keyword discipline"),
# aborting before submission if missing.
#
# Why: the PR template at .github/PULL_REQUEST_TEMPLATE.md only loads
# when `gh pr create` is invoked WITHOUT `--body`/`--body-file`. Agents
# that build PR bodies via heredoc (the standard pattern in the harness)
# bypass the template and the closing-keyword reminder along with it.
# Multiple consecutive sessions have hit the post-CI amend cycle that
# way. This wrapper closes the agent-path gap structurally rather than
# via another norms doc.
#
# Usage: identical to `gh pr create`. Adds one flag:
#   --skip-closing-keyword-check    Bypass the lint. Use only when the
#                                   workflow's exempt-class registry
#                                   covers your case (see
#                                   operations/issue-pr-hygiene.md
#                                   §"Exempt-class registry").
#
# Exit codes:
#   0   gh pr create succeeded
#   2   missing closing keyword (lint failure)
#   *   propagated from gh

set -eu

title=""
body=""
body_file=""
skip_check=0
pass_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-closing-keyword-check)
      skip_check=1
      shift
      ;;
    --title)
      title="$2"
      pass_args+=("$1" "$2")
      shift 2
      ;;
    --title=*)
      title="${1#--title=}"
      pass_args+=("$1")
      shift
      ;;
    --body)
      body="$2"
      pass_args+=("$1" "$2")
      shift 2
      ;;
    --body=*)
      body="${1#--body=}"
      pass_args+=("$1")
      shift
      ;;
    --body-file)
      body_file="$2"
      pass_args+=("$1" "$2")
      shift 2
      ;;
    --body-file=*)
      body_file="${1#--body-file=}"
      pass_args+=("$1")
      shift
      ;;
    *)
      pass_args+=("$1")
      shift
      ;;
  esac
done

# Cloud-session compatibility (coo-labs/coo-memory#703, coo-memory#898). In cloud
# sandboxes the git remote is a local-proxy URL of the form
#   http://local_proxy@127.0.0.1:<port>/git/<owner>/<repo>
# which `gh` cannot resolve to a known GitHub host, so `gh pr create` errors
# with "none of the git remotes ... point to a known GitHub host" unless the
# caller passes BOTH --repo AND --head. --repo alone isn't enough because gh
# also needs to fork-detect the head ref; --head explicit short-circuits that
# path. We auto-derive both from the proxy URL + current branch when the
# caller didn't supply them; on a normal GitHub remote the regex won't match
# and we leave args untouched.
proxy_url=""
origin_url="$(git remote get-url origin 2>/dev/null || true)"
if [[ "$origin_url" =~ ^https?://[^@/]+@127\.0\.0\.1:[0-9]+/git/([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+?)(\.git)?/?$ ]]; then
  proxy_url="$origin_url"
  proxy_repo="${BASH_REMATCH[1]}"
fi

if [ -n "$proxy_url" ]; then
  has_repo_flag=0
  has_head_flag=0
  for arg in "${pass_args[@]}"; do
    case "$arg" in
      --repo|--repo=*) has_repo_flag=1 ;;
      --head|--head=*) has_head_flag=1 ;;
    esac
  done

  if [ "$has_repo_flag" -eq 0 ]; then
    pass_args=(--repo "$proxy_repo" "${pass_args[@]}")
  fi

  if [ "$has_head_flag" -eq 0 ]; then
    head_ref="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -z "$head_ref" ] || [ "$head_ref" = "HEAD" ]; then
      echo "gh-pr-create: cloud-proxy mode requires a named branch (got: '${head_ref:-<empty>}'); pass --head <branch> explicitly or switch off detached HEAD." >&2
      exit 2
    fi
    pass_args=(--head "$head_ref" "${pass_args[@]}")
  fi
fi

if [ "$skip_check" -eq 1 ]; then
  exec gh pr create "${pass_args[@]}"
fi

# Mirror the workflow's exempt-class registry for session-log PRs: title
# prefix `session:` is the contract used by the /end-session skill and the
# auto-subscribe-pr hook. The coo-logs auto-merge workflow doesn't gate on
# closing keywords for these, so the local lint shouldn't either — saves
# the agent from remembering --skip-closing-keyword-check.
if [[ "$title" == session:* ]]; then
  exec gh pr create "${pass_args[@]}"
fi

# Resolve body content for the lint. Title + body together, mirroring
# the workflow's title-OR-body check.
content="$title"
if [ -n "$body" ]; then
  content="$content"$'\n'"$body"
elif [ -n "$body_file" ]; then
  if [ "$body_file" = "-" ]; then
    echo "gh-pr-create: --body-file - (stdin) not supported by the lint;" >&2
    echo "  use --body, a real file path, or --skip-closing-keyword-check." >&2
    exit 2
  fi
  if [ ! -f "$body_file" ]; then
    echo "gh-pr-create: --body-file '$body_file' not found" >&2
    exit 2
  fi
  content="$content"$'\n'"$(cat "$body_file")"
fi

# Closing-keyword regex (mirrors .github/workflows/issue-pr-hygiene.yml).
# Match: Closes/Fixes/Resolves followed by #N or coo-labs/<repo>#N,
# OR explicit `Closes: n/a`, OR the longer body-text form
# `n/a — no issue resolved` (em-dash or regular dash tolerated).
if printf '%s' "$content" | grep -qiE '\b(clos(e|es|ed|ing)|fix(es|ed|ing)?|resolv(e|es|ed|ing))[[:space:]]+(#[0-9]+|coo-labs/[a-z0-9-]+#[0-9]+)\b'; then
  : # ok
elif printf '%s' "$content" | grep -qiE '(^|[[:space:]])closes:[[:space:]]*n/a\b'; then
  : # ok — explicit no-issue close
elif printf '%s' "$content" | grep -qiE '\bn/a[[:space:]]*[—-][[:space:]]*no[[:space:]]+issue[[:space:]]+resolved\b'; then
  : # ok — longer body-text form
else
  cat >&2 <<'EOF'
gh-pr-create: closing-keyword check FAILED.

The PR body must include one of:

    Closes #N                           (same-repo issue)
    Closes coo-labs/<repo>#N            (cross-repo issue)
    Closes: n/a                         (no issue resolved)

The CI workflow `closing-keywords` will block merge without it. This
lint runs locally because the PR template at
.github/PULL_REQUEST_TEMPLATE.md only pre-populates the slot when
gh pr create is invoked without --body/--body-file; heredoc-body
invocations bypass it. See
operations/issue-pr-hygiene.md §"Closing-keyword discipline".

To bypass (only if your PR is in the workflow's exempt-class registry —
session-logs, auto-meta-sidecars, dependabot, claude[bot]), pass
--skip-closing-keyword-check.
EOF
  exit 2
fi

exec gh pr create "${pass_args[@]}"
