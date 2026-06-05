#!/usr/bin/env bash
# gh-coo-wrap: append the Claude Code session URL to --body on
# COO-attributed `gh` writes, then run the real gh.
#
# Substrate enforcement of the rule in
# coo-memory MEMO 2026-04-26-02 (issue #150). Carved out so the
# COO does not have to add the trail manually each turn — every
# attributable write that flows through `gh` carries the link back
# to the originating session.
#
# Marker (DO NOT REMOVE): COO-GH-COO-WRAP-MARKER-v1
#
# Behavior:
#   * Covered subcommands: `gh pr {create,edit,comment,review}` and
#     `gh issue {create,edit,comment}` — only when --body / -b /
#     --body-file is present (editor-flow and approve-only invocations
#     pass through unchanged).
#   * Source of URL: $CLAUDE_CODE_REMOTE_SESSION_ID (fallback
#     $CLAUDE_CODE_SESSION_ID), with `cse_` prefix stripped.
#   * Idempotent: bodies that already contain `claude.ai/code/session_`
#     are not re-augmented.
#   * Silent pass-through if no session URL is available (running
#     outside Claude Code) or the body is empty.
#   * Real gh located at $COO_GH_REAL (default
#     /home/user/.local/bin/gh-real). If absent, falls back to the
#     first `gh` on PATH whose directory differs from this wrapper's
#     and which does not itself carry the wrapper marker.

set -eu

WRAPPER_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
WRAPPER_DIR="$(dirname "$WRAPPER_PATH")"

# Resolve the real gh binary.
REAL_GH="${COO_GH_REAL:-/home/user/.local/bin/gh-real}"
if [ ! -x "$REAL_GH" ]; then
  REAL_GH=""
  oldifs="$IFS"; IFS=:
  for d in $PATH; do
    IFS="$oldifs"
    [ "$d" = "$WRAPPER_DIR" ] && { IFS=:; continue; }
    if [ -x "$d/gh" ] && ! grep -q 'COO-GH-COO-WRAP-MARKER-v1' "$d/gh" 2>/dev/null; then
      REAL_GH="$d/gh"
      break
    fi
    IFS=:
  done
  IFS="$oldifs"
fi

if [ -z "$REAL_GH" ] || [ ! -x "$REAL_GH" ]; then
  printf 'gh-coo-wrap: real gh binary not found (COO_GH_REAL=%s); refusing to run.\n' "${COO_GH_REAL:-unset}" >&2
  exit 127
fi

# Compute session URL once. Empty if outside Claude Code.
sid="${CLAUDE_CODE_REMOTE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
SESSION_URL=""
[ -n "$sid" ] && SESSION_URL="https://claude.ai/code/session_${sid#cse_}"

# PAT routing for cross-org public-repo writes (MEMO-2026-05-11-6xv2,
# expanded by MEMO-2026-05-12-22m9 — coverage extension to positional
# repo args and `gh api` URL paths).
#
# `$GITHUB_MCP_PAT` is fine-grained, scoped to coo-labs/* — the default
# bounded write surface. `$GITHUB_PUBLIC_PAT` is a classic PAT with
# `public_repo` scope, provisioned for writes to public repos outside
# coo-labs/* (anthropics/claude-code, upstream skill repos, etc).
#
# Phase 2 (coo-memory#873) retired settings.json::env secrets, so neither
# GITHUB_MCP_PAT nor GITHUB_PUBLIC_PAT is present in Bash-tool subprocesses
# by default. _resolve_pat materializes the PAT at call-time via op-read
# (extending Phase 2's MCP-via-op-run model to the Bash-tool surface) and
# caches the result in tmpfs to avoid saturating the 1P SA-token rate
# limit on multi-call sessions.
#
# Cache: $XDG_RUNTIME_DIR/coo-gh-pat-cache/<NAME> (0600), with a sibling
# <NAME>.expiry file holding the unix-time expiry stamp. Tmpfs is in-
# memory, container-ephemeral, dies on container reboot — within the
# spirit of Phase 2's "no plaintext at rest" (no disk persistence, no
# backup surface). TTL is generous (5 min) since PAT rotation runs
# daily; cache is for amortizing op-read latency + rate-limit pressure,
# not for freshness control. On op rate-limit or unavailability, stale
# cache is used as graceful degradation.
#
# Cost model:
#  - env var set (legacy session)        → 0 op-read, env passthrough
#  - cache hit (within TTL)              → 0 op-read, tmpfs read (~µs)
#  - cache miss (TTL expired or absent)  → 1 op-read (~50-200ms), write cache
#  - op rate-limited + stale cache       → 0 op-read, stale tmpfs read
#  - op rate-limited + no stale cache    → empty PAT, gh fails through
_resolve_pat() {
  local name="$1" op_path=""
  case "$name" in
    MCP)
      if [ -n "${GITHUB_MCP_PAT:-}" ]; then
        printf '%s' "$GITHUB_MCP_PAT"
        return 0
      fi
      op_path="op://COO/vade-coo-self-2026-04/token"
      ;;
    PUBLIC)
      if [ -n "${GITHUB_PUBLIC_PAT:-}" ]; then
        printf '%s' "$GITHUB_PUBLIC_PAT"
        return 0
      fi
      # Field is `credential` (confirmed 2026-06-05 via `op item get
      # GITHUB_PUBLIC_PAT`). The audit-era `/token` path silently returned
      # empty since the schema renamed the field; cross-org gh writes
      # surfaced the bug for the first time mid-session. The new S9
      # invariant in integrity-group-s.sh cross-checks hardcoded op-paths
      # like this against schema.yaml::credentials[] to prevent re-regression.
      op_path="op://COO/GITHUB_PUBLIC_PAT/credential"
      ;;
    *) return 0 ;;
  esac

  local cache_dir="${XDG_RUNTIME_DIR:-/tmp}/coo-gh-pat-cache"
  local cache_file="$cache_dir/$name"
  local expiry_file="$cache_dir/$name.expiry"
  local ttl=300
  local now; now="$(date +%s 2>/dev/null || echo 0)"

  # Cache hit if both files present and not expired.
  if [ -f "$cache_file" ] && [ -f "$expiry_file" ]; then
    local expiry="0"
    expiry="$(cat "$expiry_file" 2>/dev/null || echo 0)"
    if [ "${expiry:-0}" -gt "$now" ] 2>/dev/null; then
      cat "$cache_file"
      return 0
    fi
  fi

  # Cache miss / expired: resolve via op.
  if command -v op >/dev/null 2>&1 && [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    local val=""
    val="$(op read "$op_path" 2>/dev/null || true)"
    if [ -n "$val" ]; then
      mkdir -p "$cache_dir" 2>/dev/null || true
      chmod 0700 "$cache_dir" 2>/dev/null || true
      local umask_save; umask_save="$(umask)"
      umask 0177
      printf '%s' "$val" > "$cache_file" 2>/dev/null || true
      printf '%s' "$((now + ttl))" > "$expiry_file" 2>/dev/null || true
      umask "$umask_save"
      printf '%s' "$val"
      return 0
    fi
  fi

  # Op unavailable or rate-limited: fall back to stale cache if any.
  if [ -f "$cache_file" ]; then
    cat "$cache_file"
  fi
  return 0
}

# Routing: if any covered surface in argv names an owner != coo-labs
# AND $GITHUB_PUBLIC_PAT is set, swap GH_TOKEN to the public PAT for
# this invocation. coo-labs/* and unrecognized-shape invocations pass
# through unchanged.
#
# Covered surfaces:
#   1. `--repo <owner>/<name>` / `-R <owner>/<name>` flag form
#      → extract_owner (the original layer).
#   2. Positional `<owner>/<name>` after the action of
#      `gh repo {fork,create,clone,view,sync,rename,archive,delete,
#                edit,set-default,deploy-key,unarchive}`
#      → extract_owner_positional.
#   3. URL path after `gh api`:
#        repos/<owner>/<repo>[/...]   → <owner>
#        orgs/<owner>[/...]           → <owner>
#        users/<owner>[/...]          → <owner>
#      → extract_owner_positional.
#
# False-positive bound (template repo case): on
# `gh repo create --template owner-a/foo owner-b/new`, naive scanning
# picks owner-a, but `--template` is treated as value-taking below so
# the positional resolves to owner-b. The flag-value allowlist
# (__gh_valued_flag) is conservative; unknown flags are treated as
# boolean (their next arg is treated as positional).
extract_owner() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo|-R)
        shift
        if [ $# -gt 0 ]; then
          printf '%s' "${1%%/*}"
          return 0
        fi
        ;;
      --repo=*)
        repo="${1#--repo=}"
        printf '%s' "${repo%%/*}"
        return 0
        ;;
      -R=*)
        repo="${1#-R=}"
        printf '%s' "${repo%%/*}"
        return 0
        ;;
    esac
    shift
  done
  return 0
}

# __gh_valued_flag: returns 0 iff $1 is a known gh flag that consumes
# the next arg as its value. Conservative — false-negative (treating a
# valued flag as boolean) can mis-route in rare template/source cases;
# false-positive (treating a boolean as valued) skips an arg silently.
__gh_valued_flag() {
  case "$1" in
    -X|--method|-H|--header|-F|--field|-f|--raw-field|-q|--jq|\
    -t|--template|--input|--hostname|--cache|--description|\
    --gitignore|--license|--homepage|--remote|--source|--team|\
    --org|--clone-into|--fork-name|--remote-name|--target-name|\
    --upstream-remote-name|--default-branch|--add-topic|\
    --remove-topic|--include|--exclude|--limit|--label|--assignee|\
    --milestone|--project|--draft|--head|--base|--reviewer|--body|\
    --body-file|--title|--editor|--message|--from|--to)
      return 0 ;;
  esac
  return 1
}

# extract_owner_positional: positional + URL-path forms not covered by
# extract_owner. Returns owner on match, empty on no-match (caller is
# expected to fall through).
extract_owner_positional() {
  # Skip leading global flags before the subcommand. gh accepts a small
  # set here (--hostname, --help, --version); --repo / -R is also valid
  # pre-subcommand but already handled by extract_owner.
  while [ $# -gt 0 ]; do
    case "$1" in
      --hostname)
        shift; [ $# -gt 0 ] && shift ;;
      --hostname=*) shift ;;
      --help|-h|--version) shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  [ $# -gt 0 ] || return 0
  local sub="$1"; shift

  if [ "$sub" = "api" ]; then
    while [ $# -gt 0 ]; do
      case "$1" in
        --*=*) shift ;;
        --*|-*)
          if __gh_valued_flag "$1"; then
            shift; [ $# -gt 0 ] && shift
          else
            shift
          fi
          ;;
        *)
          local path="${1#/}"
          case "$path" in
            repos/*/*)
              path="${path#repos/}"
              printf '%s' "${path%%/*}"
              return 0
              ;;
            orgs/*)
              path="${path#orgs/}"
              printf '%s' "${path%%/*}"
              return 0
              ;;
            users/*)
              path="${path#users/}"
              printf '%s' "${path%%/*}"
              return 0
              ;;
          esac
          return 0
          ;;
      esac
    done
    return 0
  fi

  if [ "$sub" = "repo" ]; then
    [ $# -gt 0 ] || return 0
    local act="$1"; shift
    case "$act" in
      fork|create|clone|view|sync|rename|archive|delete|edit|set-default|deploy-key|unarchive)
        while [ $# -gt 0 ]; do
          case "$1" in
            --*=*) shift ;;
            --*|-*)
              if __gh_valued_flag "$1"; then
                shift; [ $# -gt 0 ] && shift
              else
                shift
              fi
              ;;
            *)
              case "$1" in
                https://github.com/*/*)
                  local v="${1#https://github.com/}"
                  printf '%s' "${v%%/*}"
                  return 0
                  ;;
                http://github.com/*/*)
                  local v="${1#http://github.com/}"
                  printf '%s' "${v%%/*}"
                  return 0
                  ;;
                git@github.com:*/*)
                  local v="${1#git@github.com:}"
                  printf '%s' "${v%%/*}"
                  return 0
                  ;;
                http://*|https://*|git@*|ssh://*)
                  shift; continue ;;
                */*)
                  printf '%s' "${1%%/*}"
                  return 0
                  ;;
              esac
              shift
              ;;
          esac
        done
        ;;
    esac
  fi

  return 0
}

# is_org_admin_api: returns 0 iff the argv parses as `gh api <path>` where
# <path> matches a known org-admin REST surface (issue-types, custom
# properties, properties, custom-repository-roles under any org). These
# endpoints 403 for fine-grained PATs whose underlying user is not an org
# admin (identity-vs-token rule, MEMO-2026-05-21-w6qz) — App installation
# tokens authenticate as the installation, bypassing the user-elevation
# gate. Scope intentionally narrow: only auto-route surfaces known to
# require org-admin + currently in use. Other surfaces opt in explicitly
# via GH_USE_APP_TOKEN=1.
#
# GraphQL bodies (gh api graphql -f query=…) are not parsed here — set
# GH_USE_APP_TOKEN=1 at the callsite for org-admin GraphQL mutations
# (e.g. addProjectV2ItemById on org-owned ProjectV2 items).
is_org_admin_api() {
  local sub=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift ;;
      --*=*) shift ;;
      -R|--repo|--hostname) shift; [ $# -gt 0 ] && shift ;;
      -*) shift ;;
      *)
        sub="$1"; shift; break ;;
    esac
  done
  [ "$sub" = "api" ] || return 1
  while [ $# -gt 0 ]; do
    case "$1" in
      --*=*) shift ;;
      --*|-*)
        if __gh_valued_flag "$1"; then
          shift; [ $# -gt 0 ] && shift
        else
          shift
        fi
        ;;
      *)
        local path="${1#/}"
        case "$path" in
          orgs/*/issue-types|orgs/*/issue-types/*) return 0 ;;
          orgs/*/properties/*) return 0 ;;
          orgs/*/custom-repository-roles|orgs/*/custom-repository-roles/*) return 0 ;;
        esac
        return 1
        ;;
    esac
  done
  return 1
}

# is_app_only_read: returns 0 iff argv parses as `gh api <path>` where
# <path> targets a Check-API, commit-status, or Actions surface AND the
# request is GET-shaped (no -X POST/PATCH/PUT/DELETE, no -f/--field,
# no --input). The fine-grained PAT cannot grant `Checks: Read` at all
# (a permanent GitHub limitation — see coo-labs/coo-memory#1157 and
# community#129512), and the substrate prefers to keep CI/check-state
# reads on a single token route. Writes against these surfaces stay on
# the user PAT to preserve the identity invariant — only reads auto-
# route to the App.
#
# Matched patterns (read-only):
#   repos/<o>/<r>/commits/<ref>/check-runs[/...]
#   repos/<o>/<r>/commits/<ref>/check-suites[/...]
#   repos/<o>/<r>/check-runs/<id>[/...]
#   repos/<o>/<r>/check-suites/<id>[/...]
#   repos/<o>/<r>/commits/<ref>/status
#   repos/<o>/<r>/commits/<ref>/statuses
#   repos/<o>/<r>/actions/runs[/...]
#   repos/<o>/<r>/actions/jobs/<id>[/...]
#   repos/<o>/<r>/actions/workflows/<id>/runs[/...]
is_app_only_read() {
  local sub=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift ;;
      --*=*) shift ;;
      -R|--repo|--hostname) shift; [ $# -gt 0 ] && shift ;;
      -*) shift ;;
      *)
        sub="$1"; shift; break ;;
    esac
  done
  [ "$sub" = "api" ] || return 1

  local method="GET" path=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -X|--method)
        shift; [ $# -gt 0 ] && { method="$1"; shift; }
        ;;
      -X=*|--method=*)
        method="${1#*=}"; shift
        ;;
      --input|-f|--field|-F|--raw-field)
        # Non-GET shape: writes a body. Refuse auto-route.
        return 1
        ;;
      --input=*|-f=*|--field=*|-F=*|--raw-field=*)
        return 1
        ;;
      --*=*) shift ;;
      --*|-*)
        if __gh_valued_flag "$1"; then
          shift; [ $# -gt 0 ] && shift
        else
          shift
        fi
        ;;
      *)
        path="${1#/}"
        shift
        ;;
    esac
  done

  [ "$method" = "GET" ] || return 1
  [ -n "$path" ] || return 1

  case "$path" in
    repos/*/*/commits/*/check-runs|repos/*/*/commits/*/check-runs/*) return 0 ;;
    repos/*/*/commits/*/check-suites|repos/*/*/commits/*/check-suites/*) return 0 ;;
    repos/*/*/check-runs/*) return 0 ;;
    repos/*/*/check-suites/*) return 0 ;;
    repos/*/*/commits/*/status|repos/*/*/commits/*/statuses) return 0 ;;
    repos/*/*/actions/runs|repos/*/*/actions/runs/*) return 0 ;;
    repos/*/*/actions/jobs/*) return 0 ;;
    repos/*/*/actions/workflows/*/runs|repos/*/*/actions/workflows/*/runs/*) return 0 ;;
  esac
  return 1
}

# is_pr_checks: returns 0 iff argv parses as `gh pr checks ...`. The
# subcommand calls the GraphQL `statusCheckRollup` field, which aggregates
# both check-runs (App-only) and commit-statuses. Routing to the App
# unblocks the rollup end-to-end; the App holds both `Checks: Read` and
# `Commit statuses: Read`.
is_pr_checks() {
  local sub="" act=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift ;;
      --*=*) shift ;;
      -R|--repo|--hostname) shift; [ $# -gt 0 ] && shift ;;
      -*) shift ;;
      *)
        if [ -z "$sub" ]; then
          sub="$1"; shift
        else
          act="$1"; break
        fi
        ;;
    esac
  done
  [ "$sub" = "pr" ] && [ "$act" = "checks" ]
}

# Routing precedence:
#   1. GH_USE_APP_TOKEN=1 → mint App token (explicit opt-in; for GraphQL).
#   2. `gh api <org-admin-path>` → mint App token (auto, write).
#   3. `gh api <check/status/actions read path>` → mint App token (auto,
#      read-only; GET-shape only, see is_app_only_read). Closes the
#      PAT-lacks-Checks-permission gap (coo-memory#1157).
#   4. `gh pr checks ...` → mint App token (the GraphQL statusCheckRollup
#      field aggregates both check-runs (App-only) and statuses).
#   5. owner != coo-labs + GITHUB_PUBLIC_PAT → public PAT (cross-org).
#   6. default → $GITHUB_MCP_PAT via gh's auth context (no override here).
#
# App-token routing is attempted only when GITHUB_APP_ID is set in env
# (the boot-time signal that Phase 1 of coo-memory#837 has been
# completed). When unset (App not yet provisioned), routing falls through
# to the cross-org branch and the org-admin call lands on the PAT — which
# 403s with the same error class the App fixes. Failure mode is symmetric
# with the pre-App state, not silently wrong.
if [ -n "${GITHUB_APP_ID:-}" ] && { [ "${GH_USE_APP_TOKEN:-0}" = "1" ] || is_org_admin_api "$@" || is_app_only_read "$@" || is_pr_checks "$@"; }; then
  # The minter lives in coo-harness/scripts/, not next to this wrapper.
  # ensure_gh_coo_wrap (lib/common.sh) installs *only* gh-coo-wrap.sh to
  # ~/.local/bin/gh — the minter stays canonical at its repo path. Locate
  # via $VADE_RUNTIME_DIR (set in settings.json env at boot per D4
  # integrity-check); fall back to a hard-coded path for the in-cloud
  # default layout if the env var is missing.
  minter="${VADE_RUNTIME_DIR:-/home/user/coo-harness}/scripts/gh-app-token.sh"
  if [ -x "$minter" ]; then
    app_token="$("$minter" 2>/dev/null || true)"
    if [ -n "$app_token" ]; then
      export GH_TOKEN="$app_token"
    else
      echo "gh-coo-wrap: WARN: App-token mint failed for org-admin path; falling back to default auth (likely 403)." >&2
    fi
  else
    echo "gh-coo-wrap: WARN: minter not found at $minter; org-admin path will use default auth." >&2
  fi
else
  # No App-token route fired. Routing precedence:
  #  - Cross-org: always swap to PUBLIC PAT (preserves pre-Phase-2 behavior
  #    that auto-corrects a caller-set GH_TOKEN for the public surface).
  #  - coo-labs/*: only materialize MCP PAT if GH_TOKEN is unset (preserves
  #    caller-set GH_TOKEN; in legacy sessions this is the env-inherited PAT,
  #    in post-Phase-2 sessions GH_TOKEN is unset so the op-read fallback fires).
  target_owner="$(extract_owner "$@")"
  if [ -z "$target_owner" ]; then
    target_owner="$(extract_owner_positional "$@")"
  fi
  if [ -n "$target_owner" ] && [ "$target_owner" != "coo-labs" ]; then
    _pat="$(_resolve_pat PUBLIC)"
    if [ -n "$_pat" ]; then export GH_TOKEN="$_pat"; fi
  elif [ -z "${GH_TOKEN:-}" ]; then
    _pat="$(_resolve_pat MCP)"
    if [ -n "$_pat" ]; then export GH_TOKEN="$_pat"; fi
  fi
  unset _pat || true
fi

# Resolve issue/PR shape-check script. Advisory only; missing-tolerant.
# Source: coo-memory/bin/issue-pr-shape-check.py (lands via
# coo-memory#226). The wrapper uses the script when present;
# absence is silent and never affects the gh invocation.
SHAPE_CHECK="${VADE_COO_MEMORY_DIR:-/home/user/coo-memory}/bin/issue-pr-shape-check.py"
[ -x "$SHAPE_CHECK" ] || SHAPE_CHECK=""

# shape_check_body <body>: surface advisory body-shape warnings to
# stderr per MEMO-2026-04-28-4umz. Side-effect only — script's
# stderr passes through; exit code is intentionally ignored
# (the check is non-blocking by #201's "no hard gates" constraint).
shape_check_body() {
  local body="$1"
  [ -z "$SHAPE_CHECK" ] && return 0
  [ -z "$body" ] && return 0
  printf '%s' "$body" | python3 "$SHAPE_CHECK" || true
  return 0
}

# is_covered <argv...>: returns 0 iff the (subcommand, action) pair
# parsed from argv falls in the augment-eligible set. Skips leading
# global flags so that e.g. `gh -R repo issue comment` is recognized
# the same as `gh issue comment -R repo`. Value-taking global flags
# in their separate-token form (`-R repo`, `--repo repo`,
# `--hostname host`) consume the following arg; `--flag=value` and
# boolean flags consume only themselves.
is_covered() {
  local sub="" act=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift ;;
      --*=*) shift ;;
      -R|--repo|--hostname)
        shift
        [ $# -gt 0 ] && shift
        ;;
      -*) shift ;;
      *)
        if [ -z "$sub" ]; then
          sub="$1"; shift
        else
          act="$1"; break
        fi
        ;;
    esac
  done
  case "$sub" in
    pr)
      case "$act" in create|edit|comment|review) return 0 ;; esac
      ;;
    issue)
      case "$act" in create|edit|comment) return 0 ;; esac
      ;;
  esac
  return 1
}

# augment <body>: prints body with session URL appended on a
# blank-line-separated trailing line. Returns body unchanged if:
#   * no session URL available
#   * body is empty
#   * body already contains a claude.ai/code/session_ link
#
# Side-effect: invokes shape_check_body before the URL append so
# the original (un-augmented) body is what's measured.
augment() {
  local body="$1"
  shape_check_body "$body"
  if [ -z "$SESSION_URL" ] || [ -z "$body" ]; then
    printf '%s' "$body"
    return
  fi
  case "$body" in
    *"claude.ai/code/session_"*) printf '%s' "$body"; return ;;
  esac
  printf '%s\n\n%s' "$body" "$SESSION_URL"
}

# Pass-through: no session URL OR not a covered subcommand.
if [ -z "$SESSION_URL" ] || ! is_covered "$@"; then
  exec "$REAL_GH" "$@"
fi

# Walk args, augmenting --body / --body-file values.
declare -a new_args=()
declare -a tmp_files=()
cleanup() {
  if [ "${#tmp_files[@]}" -gt 0 ]; then
    rm -f "${tmp_files[@]}"
  fi
  return 0
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  a="$1"
  case "$a" in
    --body|-b)
      shift
      body="${1:-}"
      new_args+=("$a" "$(augment "$body")")
      ;;
    --body=*)
      body="${a#--body=}"
      new_args+=("--body=$(augment "$body")")
      ;;
    -b=*)
      body="${a#-b=}"
      new_args+=("-b=$(augment "$body")")
      ;;
    --body-file)
      shift
      bf="${1:-}"
      if [ "$bf" = "-" ]; then
        body="$(cat)"
        new_args+=("--body" "$(augment "$body")")
      elif [ -f "$bf" ]; then
        body="$(cat "$bf")"
        tmp="$(mktemp)"
        tmp_files+=("$tmp")
        printf '%s' "$(augment "$body")" > "$tmp"
        new_args+=("--body-file" "$tmp")
      else
        new_args+=("--body-file" "$bf")
      fi
      ;;
    --body-file=*)
      bf="${a#--body-file=}"
      if [ "$bf" = "-" ]; then
        body="$(cat)"
        new_args+=("--body" "$(augment "$body")")
      elif [ -f "$bf" ]; then
        body="$(cat "$bf")"
        tmp="$(mktemp)"
        tmp_files+=("$tmp")
        printf '%s' "$(augment "$body")" > "$tmp"
        new_args+=("--body-file=$tmp")
      else
        new_args+=("$a")
      fi
      ;;
    *)
      new_args+=("$a")
      ;;
  esac
  shift
done

# Run real gh. Don't exec — we need the EXIT trap to clean up
# tmp files. gh reads --body-file synchronously, so the file is
# safe to remove after it returns.
"$REAL_GH" "${new_args[@]}"
exit $?
