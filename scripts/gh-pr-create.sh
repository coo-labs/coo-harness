#!/usr/bin/env bash
# gh-pr-create: thin wrapper around `gh pr create` that runs three pre-submission
# hygiene checks mirroring the at-PR-open CI workflows, aborting before submission
# if any fail. Each check has the same diagnostic text as its CI counterpart so the
# agent reads the same error at the earlier loop position.
#
#   1. Closing-keyword (Pattern B) — mirrors issue-pr-hygiene-reusable.yml.
#   2. Cross-repo + collision-prone refs (Patterns C + D) — mirrors the same
#      workflow's advisory step. Delegated to scripts/lib/pr-hygiene-patterns.py.
#   3. TOOLS.md row for new bin/ scripts — mirrors coo-memory's drift-gate.sh
#      Check 2. No-op in repos without TOOLS.md.
#
# Why: the PR template at .github/PULL_REQUEST_TEMPLATE.md only loads when
# `gh pr create` is invoked WITHOUT `--body`/`--body-file`. Agents that build
# PR bodies via heredoc (the standard pattern in the harness) bypass the template.
# Multiple consecutive sessions have hit the post-CI amend cycle that way. This
# wrapper closes the agent-path gap structurally per the CI strategy's move-it-left
# rule (G1 fast-feedback, retirement criterion (d) defense-in-depth-perpetual;
# coo-memory#1016, ci-strategy.md).
#
# Usage: identical to `gh pr create`. Adds two flags (plus one back-compat alias):
#   --closes <N|owner/repo#N|n/a>   Append a closing-keyword line to the body
#                                   (e.g. `--closes 1234` -> `Closes #1234`,
#                                   `--closes coo-labs/coo-memory#42` ->
#                                   `Closes coo-labs/coo-memory#42`,
#                                   `--closes n/a` -> `Closes: n/a`). Lets
#                                   callers declare what the PR resolves at
#                                   invocation time, so the closing-keyword
#                                   check passes without rewriting the body
#                                   after lint discovery. If the body already
#                                   carries a closing keyword the flag is
#                                   additive (both lines render); the lint
#                                   accepts either.
#   --skip-hygiene-check            Bypass all three checks. Use only when the
#   --skip-closing-keyword-check    workflow's exempt-class registry covers
#                                   your case (see operations/issue-pr-hygiene.md
#                                   §"Exempt-class registry").
#
# Exit codes:
#   0   gh pr create succeeded
#   2   one or more hygiene checks failed
#   *   propagated from gh

set -eu

title=""
body=""
body_file=""
closes_val=""
skip_check=0
pass_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-hygiene-check|--skip-closing-keyword-check)
      skip_check=1
      shift
      ;;
    --closes)
      if [ $# -lt 2 ]; then
        echo "gh-pr-create: --closes requires a value (N | owner/repo#N | n/a)" >&2
        exit 2
      fi
      closes_val="$2"
      shift 2
      ;;
    --closes=*)
      closes_val="${1#--closes=}"
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
      shift 2
      ;;
    --body=*)
      body="${1#--body=}"
      shift
      ;;
    --body-file)
      body_file="$2"
      shift 2
      ;;
    --body-file=*)
      body_file="${1#--body-file=}"
      shift
      ;;
    *)
      pass_args+=("$1")
      shift
      ;;
  esac
done

# Resolve body content from --body or --body-file. Done before the cloud-proxy
# block and the skip / session exec paths so a single re-injection of the
# possibly-augmented body into pass_args covers every downstream branch.
resolved_body=""
if [ -n "$body" ]; then
  resolved_body="$body"
elif [ -n "$body_file" ]; then
  if [ "$body_file" = "-" ]; then
    echo "gh-pr-create: --body-file - (stdin) not supported by the lint;" >&2
    echo "  use --body, a real file path, or --skip-hygiene-check." >&2
    exit 2
  fi
  if [ ! -f "$body_file" ]; then
    echo "gh-pr-create: --body-file '$body_file' not found" >&2
    exit 2
  fi
  resolved_body="$(cat "$body_file")"
fi

# Process --closes: validate the value, build the closing-keyword line, append
# to the body. Lets callers declare the closes target at invocation time so the
# closing-keyword check passes without retry. Body-side `Closes …` keeps working
# unchanged for callers that prefer to embed it themselves.
if [ -n "$closes_val" ]; then
  closes_line=""
  case "$closes_val" in
    n/a|N/A|n/A|N/a)
      closes_line="Closes: n/a"
      ;;
    *)
      if [[ "$closes_val" =~ ^#?[0-9]+$ ]]; then
        closes_line="Closes #${closes_val#\#}"
      elif [[ "$closes_val" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$ ]]; then
        closes_line="Closes ${closes_val}"
      else
        cat >&2 <<EOF
gh-pr-create: --closes value '${closes_val}' is malformed.

Expected one of:
    --closes <N>                        same-repo, e.g. --closes 1234
    --closes <owner>/<repo>#<N>         cross-repo, e.g. --closes coo-labs/coo-memory#1234
    --closes n/a                        no issue resolved
EOF
        exit 2
      fi
      ;;
  esac

  if [ -n "$resolved_body" ]; then
    resolved_body="${resolved_body}"$'\n\n'"${closes_line}"
  else
    resolved_body="${closes_line}"
  fi
fi

# Re-inject --body into pass_args. Skipped when no body input was supplied so
# the empty-body path still picks up .github/PULL_REQUEST_TEMPLATE.md (gh only
# loads the template when neither --body nor --body-file is present on argv).
if [ -n "$body" ] || [ -n "$body_file" ] || [ -n "$closes_val" ]; then
  pass_args+=("--body" "$resolved_body")
fi

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
# the agent from remembering --skip-hygiene-check.
if [[ "$title" == session:* ]]; then
  exec gh pr create "${pass_args[@]}"
fi

# Title + body together, mirroring the workflow's title-OR-body matching.
# resolved_body is set above (possibly with a `Closes …` line appended from
# --closes).
content="$title"$'\n'"$resolved_body"

# Check 1 — Closing-keyword regex (mirrors issue-pr-hygiene-reusable.yml
# Pattern B). Match: Closes/Fixes/Resolves followed by #N or
# coo-labs/<repo>#N, OR explicit `Closes: n/a`, OR the longer body-text
# form `n/a — no issue resolved` (em-dash or regular dash tolerated).
if printf '%s' "$content" | grep -qiE '\b(clos(e|es|ed|ing)|fix(es|ed|ing)?|resolv(e|es|ed|ing))[[:space:]]+(#[0-9]+|coo-labs/[a-z0-9-]+#[0-9]+)\b'; then
  : # ok
elif printf '%s' "$content" | grep -qiE '(^|[[:space:]])closes:[[:space:]]*n/a\b'; then
  : # ok — explicit no-issue close
elif printf '%s' "$content" | grep -qiE '\bn/a[[:space:]]*[—-][[:space:]]*no[[:space:]]+issue[[:space:]]+resolved\b'; then
  : # ok — longer body-text form
else
  cat >&2 <<'EOF'
gh-pr-create: closing-keyword check FAILED.

Declare the closes target at invocation with --closes:

    --closes <N>                        same-repo, appends `Closes #N`
    --closes <owner>/<repo>#<N>         cross-repo, appends `Closes <owner>/<repo>#<N>`
    --closes n/a                        no issue resolved, appends `Closes: n/a`

Or embed one of these lines in --body / --body-file directly:

    Closes #N                |    Closes coo-labs/<repo>#N    |    Closes: n/a

The CI workflow `closing-keywords` will block merge without it. This
lint runs locally because the PR template at
.github/PULL_REQUEST_TEMPLATE.md only pre-populates the slot when
gh pr create is invoked without --body/--body-file; heredoc-body
invocations bypass it. See
operations/issue-pr-hygiene.md §"Closing-keyword discipline".

To bypass (only if your PR is in the workflow's exempt-class registry —
session-logs, auto-meta-sidecars, dependabot, claude[bot]), pass
--skip-hygiene-check.
EOF
  exit 2
fi

# Check 2 — Patterns C + D (cross-repo + collision-prone refs). Delegated
# to a Python helper that mirrors issue-pr-hygiene-reusable.yml's advisory
# step. Blocking at the pre-push layer (the agent is still in-turn — fix is
# cheap); the workflow stays advisory at PR-time per its existing behavior.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$script_dir/lib/pr-hygiene-patterns.py"
if [ -x "$helper" ]; then
  # Derive bare host-repo name (e.g. "coo-memory") from origin/--repo so the
  # helper can classify naked-reponame hits as same-repo (suggest bare `#N`)
  # vs cross-repo (suggest `coo-labs/<repo>#N`). Falls back to empty if we
  # can't tell; the helper then treats every hit as cross-repo.
  host_repo_name=""
  if [ -n "$proxy_url" ]; then
    host_repo_name="${proxy_repo##*/}"
  else
    origin_for_host="${origin_url:-$(git remote get-url origin 2>/dev/null || true)}"
    if [[ "$origin_for_host" =~ github\.com[:/][^/]+/([^/.]+)(\.git)?/?$ ]]; then
      host_repo_name="${BASH_REMATCH[1]}"
    fi
  fi
  if ! printf '%s' "$(jq -n --arg t "$title" --arg b "$resolved_body" --arg h "$host_repo_name" '{title:$t,body:$b,host:$h}')" \
      | python3 "$helper"; then
    exit 2
  fi
fi

# Check 3 — TOOLS.md drift (mirrors coo-memory/.claude/_lib/drift-gate.sh
# Check 2). For every new bin/*.{sh,py} in the diff against origin/main,
# require a TOOLS.md row referencing the script's basename. No-op if
# TOOLS.md doesn't exist at repo root (most repos other than coo-memory).
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$repo_root" ] && [ -f "$repo_root/TOOLS.md" ]; then
  base_ref="origin/main"
  merge_base="$(git merge-base "$base_ref" HEAD 2>/dev/null || true)"
  if [ -n "$merge_base" ]; then
    new_scripts="$(git diff --name-only --diff-filter=A "$merge_base" -- 'bin/*.sh' 'bin/*.py' 2>/dev/null || true)"
    drift_fail=0
    if [ -n "$new_scripts" ]; then
      while IFS= read -r script_path; do
        [ -z "$script_path" ] && continue
        # Honor drift-gate's opt-out marker for one-off helpers.
        if grep -qE '^[[:space:]]*#[[:space:]]*drift-gate:[[:space:]]*skip' "$repo_root/$script_path" 2>/dev/null; then
          continue
        fi
        script_name="$(basename "$script_path")"
        if ! grep -qF "$script_name" "$repo_root/TOOLS.md" 2>/dev/null; then
          if [ "$drift_fail" -eq 0 ]; then
            echo "gh-pr-create: TOOLS.md drift check FAILED." >&2
            drift_fail=1
          fi
          echo "  $script_path has no TOOLS.md row" >&2
        fi
      done <<EOF
$new_scripts
EOF
    fi
    if [ "$drift_fail" -eq 1 ]; then
      cat >&2 <<'EOF'

The CI workflow `drift-gate` (coo-memory/.claude/_lib/drift-gate.sh, Check 2)
will block merge for any new bin/*.{sh,py} without a TOOLS.md row. Add a row
to TOOLS.md §6 (or the appropriate section) and a matching row to
operations/adoption_tracker.md §6 in this same PR.

To opt out for a genuine one-off helper, add a '# drift-gate: skip' marker
at the top of the script. To bypass this lint, pass --skip-hygiene-check.
EOF
      exit 2
    fi
  fi
fi

exec gh pr create "${pass_args[@]}"
