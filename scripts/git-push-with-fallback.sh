#!/usr/bin/env bash
# git push wrapper with direct-URL fallback for the cloud git-proxy 403 issue.
#
# The Claude Code cloud sandbox routes git through a local proxy at
# 127.0.0.1:<port>/git/<owner>/<repo>. The proxy intermittently returns
# HTTP 403 on push (often only the second push onward of a session) and,
# separately, substitutes a token without `workflow` scope on workflow-file
# pushes. Pushing directly to github.com with the COO PAT is reliable.
# See coo-labs/coo-harness#67 for the diagnostic write-up.
#
# Usage:
#   scripts/git-push-with-fallback.sh [<git push args>...]
#
# Behaviour:
#   1. Run `git push <args>`.
#   2. On non-zero exit, scan output for proxy-class failure markers.
#      Match → reconstruct the same push against
#      https://vade-coo:${GITHUB_MCP_PAT}@github.com/<owner>/<repo>.git
#      and retry exactly once.
#      No match (genuine permission denial, bad refspec, etc.) → exit
#      with the original status, no retry.
#
# Requires GITHUB_MCP_PAT in the environment for the fallback path. If
# unset, the wrapper passes the original failure through with a
# pointer at coo-bootstrap.sh.
#
# Credential-leak hardening (coo-labs/coo-harness#124):
#   The fallback push targets a credential-bearing URL. To prevent the
#   PAT from leaking into stdout or .git/config when `-u` /
#   `--set-upstream` is present, the wrapper:
#     · strips upstream flags from the fallback args and re-establishes
#       tracking via `git config branch.<X>.remote=<symbolic remote>`
#       after the push lands;
#     · pipes fallback push output through a sed redactor that masks
#       any `<user>:<password>@` URL.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# Patterns that indicate the harness git proxy refused or dropped the push.
# Anything matching is eligible for the direct-URL fallback. Keep this
# list narrow — we don't want to retry genuine permission errors.
readonly PROXY_FAILURE_PATTERNS='HTTP 403|send-pack: unexpected disconnect|the remote end hung up unexpectedly|refusing to allow an OAuth App|workflow.*scope'

# Sed expression that masks any `<user>:<password>@` segment of a URL.
# Defensive against the wrapper's own credential URL leaking from any
# git-emitted line we don't otherwise control.
readonly PAT_REDACT_SED='s|(https?://[^:/[:space:]]+:)[^@[:space:]]+@|\1***@|g'

resolve_remote_from_args() {
  local a
  for a in "$@"; do
    case "$a" in
      -*) continue ;;
      *) printf '%s' "$a"; return 0 ;;
    esac
  done
  printf 'origin'
}

extract_repo_path() {
  local url="$1"
  local path
  # Proxy form: http(s)://[user@]host[:port]/git/owner/repo[.git]
  path="$(printf '%s' "$url" | sed -nE 's#^https?://[^/]+/git/(.+)$#\1#p')"
  printf '%s' "${path%.git}"
}

# Parse the push refspec out of a git push arg list. Prints two lines —
# <local-branch> and <remote-ref-name> — used to restore upstream
# tracking after a fallback push that had `-u` stripped. Empty output
# when a refspec can't be determined.
parse_push_refspec() {
  local remote="$1"; shift
  local seen_remote=0 a
  for a in "$@"; do
    case "$a" in
      -u|--set-upstream) continue ;;
      -*) continue ;;
    esac
    if [ "$seen_remote" -eq 0 ] && [ "$a" = "$remote" ]; then
      seen_remote=1
      continue
    fi
    local raw="${a#+}"  # strip force-push prefix
    local src dst
    if [[ "$raw" == *:* ]]; then
      src="${raw%%:*}"
      dst="${raw#*:}"
    else
      src="$raw"
      dst="$raw"
    fi
    printf '%s\n%s\n' "$src" "$dst"
    return 0
  done
  local cur
  cur="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
  if [ -n "$cur" ]; then
    printf '%s\n%s\n' "$cur" "$cur"
  fi
}

PUSH_OUT_TMP=""
cleanup() { [ -n "${PUSH_OUT_TMP:-}" ] && rm -f "$PUSH_OUT_TMP"; }
trap cleanup EXIT

main() {
  if ! PUSH_OUT_TMP="$(mktemp 2>/dev/null)"; then
    log_err "mktemp failed; running git push directly with no fallback"
    exec git push "$@"
  fi
  local tmp="$PUSH_OUT_TMP"

  local rc=0
  git push "$@" 2>&1 | tee "$tmp"
  rc="${PIPESTATUS[0]}"
  if [ "$rc" -eq 0 ]; then
    return 0
  fi

  if ! grep -qE "$PROXY_FAILURE_PATTERNS" "$tmp"; then
    log_err "git push failed (rc=$rc) with no proxy-failure marker; passing through"
    return "$rc"
  fi

  local remote current_url repo_path repo_owner
  remote="$(resolve_remote_from_args "$@")"
  if ! current_url="$(git remote get-url "$remote" 2>/dev/null)" || [ -z "$current_url" ]; then
    log_err "could not resolve remote '$remote'; not falling back"
    return "$rc"
  fi
  case "$current_url" in
    *github.com*)
      log_err "remote '$remote' already targets github.com; failure is not proxy-related"
      return "$rc"
      ;;
  esac
  repo_path="$(extract_repo_path "$current_url")"
  if [ -z "$repo_path" ]; then
    log_err "could not extract owner/repo from '$current_url'; not falling back"
    return "$rc"
  fi
  repo_owner="${repo_path%%/*}"

  # PAT selection by remote owner (MEMO-2026-05-12-22m9). coo-labs/*
  # remotes use the fine-grained MCP PAT (default write surface);
  # other remotes use the classic public-repo PAT when available.
  # Mirrors the gh-coo-wrap routing layer for symmetric coverage —
  # `git push` to a fork at venpopov/foo would otherwise fall back
  # with the wrong PAT and re-403.
  local fallback_pat fallback_pat_name fallback_user
  if [ "$repo_owner" != "coo-labs" ] && [ -n "${GITHUB_PUBLIC_PAT:-}" ]; then
    fallback_pat="$GITHUB_PUBLIC_PAT"
    fallback_pat_name="GITHUB_PUBLIC_PAT"
    fallback_user="vade-coo"
  elif [ -n "${GITHUB_MCP_PAT:-}" ]; then
    fallback_pat="$GITHUB_MCP_PAT"
    fallback_pat_name="GITHUB_MCP_PAT"
    fallback_user="vade-coo"
  else
    log_err "git proxy push failed but no GitHub PAT is set (GITHUB_MCP_PAT, GITHUB_PUBLIC_PAT); cannot fall back"
    log_err "  run scripts/boot/coo-bootstrap.sh to populate them (Phase 2: no coo-env file)"
    return "$rc"
  fi

  local direct_url="https://${fallback_user}:${fallback_pat}@github.com/${repo_path}.git"
  local masked_url="https://${fallback_user}:***@github.com/${repo_path}.git"
  log_err "git proxy push failed; retrying via $masked_url (using $fallback_pat_name)"

  # Build fallback args: substitute direct_url for the remote token, and
  # drop -u / --set-upstream (the upstream-tracking config gets written
  # explicitly post-push, see #124).
  local -a new_args=()
  local seen_remote=0 has_upstream=0 a
  for a in "$@"; do
    case "$a" in
      -u|--set-upstream) has_upstream=1; continue ;;
    esac
    if [ "$seen_remote" -eq 0 ] && [ "$a" = "$remote" ]; then
      new_args+=("$direct_url")
      seen_remote=1
    else
      new_args+=("$a")
    fi
  done
  if [ "$seen_remote" -eq 0 ]; then
    local current_branch
    current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
    if [ -z "$current_branch" ]; then
      log_err "no remote in args and detached HEAD; cannot construct fallback push"
      return "$rc"
    fi
    new_args+=("$direct_url" "HEAD:refs/heads/$current_branch")
  fi

  # Pipe push output through a redactor as belt-and-suspenders against
  # any URL leak from git itself. PIPESTATUS preserves git's exit code.
  local fallback_rc
  git push "${new_args[@]}" 2>&1 | sed -E "$PAT_REDACT_SED"
  fallback_rc="${PIPESTATUS[0]}"
  if [ "$fallback_rc" -ne 0 ]; then
    return "$fallback_rc"
  fi

  # Restore upstream tracking via the symbolic remote so .git/config
  # stays free of the credential URL. Skip silently if the user didn't
  # ask for upstream-setting.
  if [ "$has_upstream" -eq 1 ]; then
    local refs local_branch remote_ref merge_ref
    refs="$(parse_push_refspec "$remote" "$@")"
    local_branch="$(printf '%s' "$refs" | sed -n '1p')"
    remote_ref="$(printf '%s' "$refs" | sed -n '2p')"
    if [ -n "$local_branch" ] && [ -n "$remote_ref" ]; then
      case "$remote_ref" in
        refs/*) merge_ref="$remote_ref" ;;
        *) merge_ref="refs/heads/$remote_ref" ;;
      esac
      git config "branch.${local_branch}.remote" "$remote"
      git config "branch.${local_branch}.merge" "$merge_ref"
    else
      log_err "fallback push succeeded but could not parse refspec; upstream not restored — run 'git push -u $remote <branch>' manually if needed"
    fi
  fi
}

# Run main only when invoked as a script (not when sourced for testing).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
