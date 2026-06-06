#!/usr/bin/env bash
# gh-put-workflow: App-token PUT-contents wrapper for `.github/workflows/*`.
#
# Closes the OAuth-without-`workflow`-scope wall: a session `git push`-ing a
# workflow file is rejected by the proxy (the cloud-OAuth identity does not
# carry `workflow`). The App installation token does — but the PUT-contents
# path leaves the local working tree out of sync, and the stop hook then
# fires "commit and push these changes" even though the change is pushed.
# This wrapper does the PUT and the local sync so `git status` lands clean.
#
# Usage:
#   scripts/gh-put-workflow.sh <file> <branch> <message> [base]
#
# Args:
#   <file>     Path to the workflow file (absolute or relative to CWD).
#   <branch>   Target remote branch (created from <base> if absent).
#   <message>  Commit message for the App PUT.
#   [base]     Optional base branch when creating <branch>; default `main`.
#
# Behavior:
#   1. Validate file + extract owner/repo from `origin` remote URL.
#   2. Create <branch> from <base> if it doesn't exist remotely.
#   3. Look up the file's current blob sha on <branch> (needed for PUT
#      update; absent for PUT create).
#   4. PUT contents with branch / message / content (base64) / [sha].
#   5. If currently on <branch>: fetch, stash-the-file-or-rm-untracked,
#      `merge --ff-only origin/<branch>`. Result: HEAD advances to the new
#      remote commit and `git status` is clean.
#   6. If not on <branch>: just fetch; the operator manages their checkout.
#
# Composes with `gh-coo-wrap.sh` by setting `GH_USE_APP_TOKEN=1` on each
# `gh` call. The wrap shim sees that flag and routes through the App
# installation token instead of the PAT cache. The wrapper does not
# bypass routing.
#
# Closes: coo-labs/coo-harness#508.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat >&2 <<EOF
usage: $0 <file> <branch> <message> [base]

  <file>     workflow file path (absolute or relative to CWD)
  <branch>   target remote branch (created from <base> if absent)
  <message>  commit message for the App PUT
  [base]     base branch when creating <branch>; default main
EOF
  exit 2
}

# Extract `owner/repo` from a git remote URL. Handles:
#   git@github.com:owner/repo[.git]
#   https://github.com/owner/repo[.git]
#   http(s)://[user@]host[:port]/git/owner/repo[.git]   ← cloud git-proxy
# Echoes `owner/repo` on success, empty on failure.
extract_repo_path() {
  local url="$1" path
  case "$url" in
    git@github.com:*)
      path="${url#git@github.com:}"
      ;;
    *github.com/*)
      path="$(printf '%s' "$url" | sed -nE 's#^https?://[^/]+/(.+)$#\1#p')"
      ;;
    *)
      # Proxy: http(s)://[user@]host[:port]/git/owner/repo[.git]
      path="$(printf '%s' "$url" | sed -nE 's#^https?://[^/]+/git/(.+)$#\1#p')"
      ;;
  esac
  path="${path%.git}"
  case "$path" in
    */*) printf '%s' "$path" ;;
    *) printf '' ;;
  esac
}

# Resolve <file> to a path relative to the repo root. <file> may be
# absolute or relative to CWD. Echoes `<path-from-repo-root>` on success,
# empty + nonzero exit on file-outside-repo. Repo root passed as $2 so
# the function is testable in isolation.
resolve_relative_path() {
  local file="$1" repo_root="$2" abs_file
  if [ -z "$file" ] || [ -z "$repo_root" ]; then
    return 1
  fi
  case "$file" in
    /*) abs_file="$file" ;;
    *)  abs_file="$(cd "$(dirname -- "$file")" 2>/dev/null && pwd)/$(basename -- "$file")" ;;
  esac
  case "$abs_file" in
    "$repo_root"/*) printf '%s' "${abs_file#$repo_root/}" ;;
    *) return 1 ;;
  esac
}

main() {
  [ "$#" -lt 3 ] && usage

  local file="$1" branch="$2" message="$3" base="${4:-main}"

  [ -f "$file" ] || { log_err "file not found: $file"; exit 1; }

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log_err "not in a git repository"
    exit 1
  fi

  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"

  local relative_path
  if ! relative_path="$(resolve_relative_path "$file" "$repo_root")" || [ -z "$relative_path" ]; then
    log_err "file is outside repo root ($repo_root): $file"
    exit 1
  fi

  local remote_url
  if ! remote_url="$(git remote get-url origin 2>/dev/null)" || [ -z "$remote_url" ]; then
    log_err "no 'origin' remote configured"
    exit 1
  fi

  local repo_path owner repo
  repo_path="$(extract_repo_path "$remote_url")"
  if [ -z "$repo_path" ]; then
    log_err "could not extract owner/repo from '$remote_url'"
    exit 1
  fi
  owner="${repo_path%%/*}"
  repo="${repo_path##*/}"

  log "target: $owner/$repo:$branch path=$relative_path base=$base"

  # Note whether the file was tracked locally pre-PUT — drives whether
  # we stash (tracked-modified) or rm (untracked) before the ff-merge.
  local was_tracked=0
  if git ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1; then
    was_tracked=1
  fi

  # 1. Ensure target branch exists on remote.
  if ! GH_USE_APP_TOKEN=1 gh api "repos/$owner/$repo/branches/$branch" >/dev/null 2>&1; then
    log "branch '$branch' missing on remote; creating from '$base'"
    local base_sha
    if ! base_sha="$(GH_USE_APP_TOKEN=1 gh api "repos/$owner/$repo/branches/$base" --jq .commit.sha 2>/dev/null)" \
       || [ -z "$base_sha" ]; then
      log_err "failed to resolve base sha for '$base'"
      exit 1
    fi
    if ! GH_USE_APP_TOKEN=1 gh api -X POST "repos/$owner/$repo/git/refs" \
         -f "ref=refs/heads/$branch" -f "sha=$base_sha" >/dev/null; then
      log_err "failed to create branch '$branch' from sha=$base_sha"
      exit 1
    fi
  fi

  # 2. Get current file sha on target branch (for PUT update). Empty when
  #    the file doesn't yet exist on that branch (PUT create path).
  local sha_flag=() file_sha
  if file_sha="$(GH_USE_APP_TOKEN=1 gh api "repos/$owner/$repo/contents/$relative_path?ref=$branch" --jq .sha 2>/dev/null)" \
     && [ -n "$file_sha" ] && [ "$file_sha" != "null" ]; then
    sha_flag=(-f "sha=$file_sha")
  fi

  # 3. PUT contents (base64-encoded). base64 -w0 is GNU; on BSD use `base64`
  #    without -w. Both are fine since we materialize the encoded string
  #    once into a variable.
  local content_b64
  if ! content_b64="$(base64 -w0 < "$file" 2>/dev/null)" || [ -z "$content_b64" ]; then
    # Fallback for BSD base64 (no -w flag).
    content_b64="$(base64 < "$file" | tr -d '\n' 2>/dev/null)"
  fi
  [ -z "$content_b64" ] && { log_err "base64 encode failed"; exit 1; }

  log "PUT $owner/$repo/contents/$relative_path on $branch"
  if ! GH_USE_APP_TOKEN=1 gh api -X PUT "repos/$owner/$repo/contents/$relative_path" \
       -f "branch=$branch" -f "message=$message" -f "content=$content_b64" \
       "${sha_flag[@]}" >/dev/null; then
    log_err "PUT contents failed"
    exit 1
  fi
  log "PUT ok"

  # 4. Local sync — only when HEAD is on the target branch. The wrapper
  #    deliberately does not switch branches; the operator owns checkout.
  local current_branch
  current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
  if [ "$current_branch" != "$branch" ]; then
    log "HEAD on '${current_branch:-detached}' (not '$branch'); fetching only"
    git fetch origin "$branch" >/dev/null 2>&1 || log_err "fetch warning"
    return 0
  fi

  log "syncing local working tree to origin/$branch"
  if ! git fetch origin "$branch" >/dev/null 2>&1; then
    log_err "git fetch failed"
    exit 1
  fi

  # Stash this file's diff (tracked-modified) or rm (untracked-new) so
  # the ff-merge doesn't conflict on the path we just PUT. Unrelated
  # changes elsewhere in the working tree are left untouched.
  local stashed=0
  if [ "$was_tracked" -eq 1 ]; then
    if ! git diff --quiet -- "$relative_path" 2>/dev/null; then
      if ! git stash push --quiet -- "$relative_path" 2>/dev/null; then
        log_err "stash failed; refusing to ff-merge into a dirty tree"
        exit 1
      fi
      stashed=1
    fi
  else
    rm -f -- "$repo_root/$relative_path"
  fi

  if git merge --ff-only "origin/$branch" >/dev/null 2>&1; then
    if [ "$stashed" -eq 1 ]; then
      # Stashed diff was the same content as the PUT commit; drop it.
      git stash drop --quiet >/dev/null 2>&1 || true
    fi
    log "synced: HEAD → $(git rev-parse --short HEAD)"
    return 0
  fi

  log_err "ff-merge failed; local diverged from origin/$branch."
  log_err "  The PUT landed; resolve the local tree manually."
  if [ "$stashed" -eq 1 ]; then
    git stash pop --quiet >/dev/null 2>&1 \
      || log_err "  stash pop also failed; the stashed diff remains in the stash list"
  fi
  exit 1
}

# Run main only when invoked as a script (not when sourced for testing).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
