#!/usr/bin/env bash
# gh-issue-create: hygiene wrapper around `gh issue create` that pre-checks
# native type, milestone, label hygiene, and body template structure before
# submission. Mirrors gh-pr-create.sh.
#
# Today, agent-authored issues bypass the issue-form template (which is what
# the bridge workflow at .github/workflows/bridge-form-fields-to-natives.yml
# expects), so native type is unset, field values stay null, and deprecated
# label conventions slip through. Sessions hit the post-create patch loop —
# updateIssue { issueTypeId }, setIssueFieldValue REST, addSubIssue — once per
# epic. This wrapper collapses that to a single invocation.
#
# Beyond `gh issue create`'s native flags, adds:
#   --type <Task|Bug|Feature|Epic|Chore|Docs|Refactor|Test|Research|Skill>
#                                  (required) native issue type
#   --priority <P0|P1|P2|P3>
#   --readiness <Ready|"Needs design"|"Needs research"|"Needs breakdown">
#   --effort <XS|S|M|L|XL>
#   --start <YYYY-MM-DD>           (Epic / Research)
#   --target <YYYY-MM-DD>          (Epic / Research)
#   --research-question <text>     (Research)
#   --output-kind <memo|foundation-essay|operations-doc|briefing|code-spike>
#                                  (Research)
#   --skill-kind <implement|review|revise|evaluate|idea>   (Skill)
#   --skill-name <text>            (Skill)
#   --parent-issue <[owner/repo#]N>
#   --children <[owner/repo#]N,[owner/repo#]N,...>
#   --skip-hygiene-check           bypass all pre-submit lints
#
# Exit codes:
#   0   issue created and post-create mutations completed
#   2   lint failed (no submission)
#   *   propagated from `gh issue create` or post-create mutation

set -eu

# issueType GraphQL node IDs (org-wide stable across coo-labs/* repos;
# resolved 2026-06-05 via `gh api graphql ... issueTypes { nodes { id name }}`).
# Static — refresh if a new type is added at the org level.
declare -A TYPE_IDS=(
  [Task]=IT_kwDOEGdN_84B8w6P [Bug]=IT_kwDOEGdN_84B8w6Q [Feature]=IT_kwDOEGdN_84B8w6R
  [Epic]=IT_kwDOEGdN_84CAfXB [Chore]=IT_kwDOEGdN_84CAfXC [Docs]=IT_kwDOEGdN_84CAfXD
  [Refactor]=IT_kwDOEGdN_84CAfXK [Test]=IT_kwDOEGdN_84CAfXL [Research]=IT_kwDOEGdN_84CAfXM
  [Skill]=IT_kwDOEGdN_84CAfXN
)

# Field IDs per coo-memory/operations/issue-fields-and-types.md §"API surface"
# Date IDs (Start=41357631, Target=41357632) confirmed live 2026-06-05.
PRIORITY_FIELD=41357630
START_FIELD=41357631
TARGET_FIELD=41357632
EFFORT_FIELD=41357633
READINESS_FIELD=42387399
OUTPUT_FIELD=42390217
RESEARCH_Q_FIELD=42390218
SKILL_KIND_FIELD=42390219
SKILL_NAME_FIELD=42390220

# Body template sections required per type, mirroring the bridge widgets
# table in operations/issue-fields-and-types.md §"Issue templates".
# Multi-word section names use whitespace; the regex below is anchored at
# `^### `.
declare -A REQ_SECTIONS=(
  [Task]="Priority|Readiness"
  [Bug]="Priority|Readiness"
  [Feature]="Priority|Readiness"
  [Epic]="Priority|Readiness|Effort"
  [Chore]="Priority|Readiness"
  [Docs]="Priority"
  [Refactor]="Priority|Effort"
  [Test]="Priority|Readiness"
  [Research]="Priority|Readiness|Effort|Output kind|Research question"
  [Skill]="Priority|Readiness|Effort|Skill kind|Skill name"
)

title=""
body=""
body_file=""
type=""
milestone=""
repo=""
priority=""
readiness=""
effort=""
start_date=""
target_date=""
research_q=""
output_kind=""
skill_kind=""
skill_name=""
parent_issue=""
children=""
skip_check=0
labels=()
pass_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-hygiene-check)    skip_check=1; shift ;;
    --type)                  type="$2"; shift 2 ;;
    --type=*)                type="${1#--type=}"; shift ;;
    --priority)              priority="$2"; shift 2 ;;
    --priority=*)            priority="${1#--priority=}"; shift ;;
    --readiness)             readiness="$2"; shift 2 ;;
    --readiness=*)           readiness="${1#--readiness=}"; shift ;;
    --effort)                effort="$2"; shift 2 ;;
    --effort=*)              effort="${1#--effort=}"; shift ;;
    --start)                 start_date="$2"; shift 2 ;;
    --start=*)               start_date="${1#--start=}"; shift ;;
    --target)                target_date="$2"; shift 2 ;;
    --target=*)              target_date="${1#--target=}"; shift ;;
    --research-question)     research_q="$2"; shift 2 ;;
    --research-question=*)   research_q="${1#--research-question=}"; shift ;;
    --output-kind)           output_kind="$2"; shift 2 ;;
    --output-kind=*)         output_kind="${1#--output-kind=}"; shift ;;
    --skill-kind)            skill_kind="$2"; shift 2 ;;
    --skill-kind=*)          skill_kind="${1#--skill-kind=}"; shift ;;
    --skill-name)            skill_name="$2"; shift 2 ;;
    --skill-name=*)          skill_name="${1#--skill-name=}"; shift ;;
    --parent-issue)          parent_issue="$2"; shift 2 ;;
    --parent-issue=*)        parent_issue="${1#--parent-issue=}"; shift ;;
    --children)              children="$2"; shift 2 ;;
    --children=*)            children="${1#--children=}"; shift ;;
    --title)                 title="$2"; pass_args+=("$1" "$2"); shift 2 ;;
    --title=*)               title="${1#--title=}"; pass_args+=("$1"); shift ;;
    --body)                  body="$2"; pass_args+=("$1" "$2"); shift 2 ;;
    --body=*)                body="${1#--body=}"; pass_args+=("$1"); shift ;;
    --body-file)             body_file="$2"; pass_args+=("$1" "$2"); shift 2 ;;
    --body-file=*)           body_file="${1#--body-file=}"; pass_args+=("$1"); shift ;;
    --milestone|-m)          milestone="$2"; pass_args+=("$1" "$2"); shift 2 ;;
    --milestone=*)           milestone="${1#--milestone=}"; pass_args+=("$1"); shift ;;
    --repo|-R)               repo="$2"; pass_args+=("$1" "$2"); shift 2 ;;
    --repo=*)                repo="${1#--repo=}"; pass_args+=("$1"); shift ;;
    -l|--label)              labels+=("$2"); pass_args+=("$1" "$2"); shift 2 ;;
    --label=*)               labels+=("${1#--label=}"); pass_args+=("$1"); shift ;;
    *)                       pass_args+=("$1"); shift ;;
  esac
done

# Cloud-session compatibility (coo-memory#703, coo-memory#898). In cloud
# sandboxes the git remote is a local-proxy URL of the form
#   http://local_proxy@127.0.0.1:<port>/git/<owner>/<repo>
# which `gh` cannot resolve to a known GitHub host. `gh issue create` errors
# unless --repo is passed; we auto-derive from the proxy URL when the caller
# didn't supply it. On a normal GitHub remote the regex won't match.
origin_url="$(git remote get-url origin 2>/dev/null || true)"
if [ -z "$repo" ] && [[ "$origin_url" =~ ^https?://[^@/]+@127\.0\.0\.1:[0-9]+/git/([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+?)(\.git)?/?$ ]]; then
  repo="${BASH_REMATCH[1]}"
  pass_args=(--repo "$repo" "${pass_args[@]}")
fi

# Lints
fail_msgs=()

if [ "$skip_check" -eq 0 ]; then
  # 1. Type required and known
  if [ -z "$type" ]; then
    fail_msgs+=("--type is required (one of: ${!TYPE_IDS[*]})")
  elif [ -z "${TYPE_IDS[$type]:-}" ]; then
    fail_msgs+=("--type '$type' unknown; must be one of: ${!TYPE_IDS[*]}")
  fi

  # 2. Milestone required
  if [ -z "$milestone" ]; then
    fail_msgs+=("--milestone is required (canonical themes in MEMO-2026-05-20-mlst)")
  fi

  # 3. Deprecated labels refused
  for label in ${labels[@]+"${labels[@]}"}; do
    case "$label" in
      type:*|prio:*|priority:*|readiness:*)
        fail_msgs+=("deprecated label '$label' — use native fields via --type / --priority / --readiness instead")
        ;;
    esac
  done

  # 4. Body has required template sections for the type
  if [ -n "$type" ] && [ -n "${REQ_SECTIONS[$type]:-}" ]; then
    content=""
    if [ -n "$body" ]; then
      content="$body"
    elif [ -n "$body_file" ]; then
      if [ "$body_file" = "-" ]; then
        fail_msgs+=("--body-file - (stdin) not supported by the lint; use --body, a file path, or --skip-hygiene-check")
      elif [ ! -f "$body_file" ]; then
        fail_msgs+=("--body-file '$body_file' not found")
      else
        content="$(cat "$body_file")"
      fi
    else
      fail_msgs+=("--body or --body-file required (template-section lint needs body content)")
    fi

    if [ -n "$content" ]; then
      IFS='|' read -ra sections <<< "${REQ_SECTIONS[$type]}"
      for section in "${sections[@]}"; do
        if ! printf '%s' "$content" | grep -qE "^### ${section}([[:space:]]|$)"; then
          fail_msgs+=("body missing '### $section' section required for type '$type'")
        fi
      done
    fi
  fi

  if [ ${#fail_msgs[@]} -gt 0 ]; then
    {
      echo "gh-issue-create: hygiene check FAILED:"
      for msg in "${fail_msgs[@]}"; do echo "  - $msg"; done
      echo ""
      echo "Fix the issues above or pass --skip-hygiene-check to bypass."
      echo "Reference: coo-memory/operations/issue-fields-and-types.md"
    } >&2
    exit 2
  fi
fi

# Submit
create_out=$(gh issue create "${pass_args[@]}")
echo "$create_out"

issue_url=$(printf '%s\n' "$create_out" | grep -oE 'https://github\.com/[^[:space:]]+/issues/[0-9]+' | tail -1)
if [ -z "$issue_url" ]; then
  echo "gh-issue-create: submission succeeded but issue URL not found in output; skipping post-create mutations." >&2
  exit 0
fi
issue_num="${issue_url##*/}"
url_repo="${issue_url#https://github.com/}"
url_repo="${url_repo%/issues/*}"
[ -z "$repo" ] && repo="$url_repo"

owner="${repo%/*}"
name="${repo#*/}"

# Native type + sub-issue links require the issue's GraphQL node id.
issue_node_id=""
if [ -n "${type:-}" ] || [ -n "$parent_issue" ] || [ -n "$children" ]; then
  issue_node_id=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$n:Int!){repository(owner:$owner,name:$repo){issue(number:$n){id}}}' \
    -F owner="$owner" -F repo="$name" -F n="$issue_num" \
    --jq '.data.repository.issue.id')
fi

# Set native type (gh issue create has no --type flag as of gh v2.91 — the
# updateIssue mutation is the canonical post-create path; verified working
# 2026-05-24 per issue-fields-and-types.md). Soft-fail: the issue exists
# regardless; surface the error but let post-create cleanup continue.
if [ -n "$type" ] && [ -n "$issue_node_id" ]; then
  type_id="${TYPE_IDS[$type]}"
  if gh api graphql \
       -f query='mutation($id:ID!,$tid:ID!){updateIssue(input:{id:$id,issueTypeId:$tid}){issue{number}}}' \
       -F id="$issue_node_id" -F tid="$type_id" \
       --jq '.data.updateIssue.issue.number' >/dev/null 2>&1; then
    echo "  + type set: $type"
  else
    echo "  ! type-set mutation failed (issue #$issue_num created without type — patch manually)" >&2
  fi
fi

# Set field values via REST. Single-select values are option name strings;
# date values are YYYY-MM-DD strings; text values are the string itself.
# Method is POST, body is a top-level array, key is `field_id` (per ops doc).
field_pairs=()
[ -n "$priority" ]    && field_pairs+=("$PRIORITY_FIELD:$priority")
[ -n "$readiness" ]   && field_pairs+=("$READINESS_FIELD:$readiness")
[ -n "$effort" ]      && field_pairs+=("$EFFORT_FIELD:$effort")
[ -n "$start_date" ]  && field_pairs+=("$START_FIELD:$start_date")
[ -n "$target_date" ] && field_pairs+=("$TARGET_FIELD:$target_date")
[ -n "$output_kind" ] && field_pairs+=("$OUTPUT_FIELD:$output_kind")
[ -n "$research_q" ]  && field_pairs+=("$RESEARCH_Q_FIELD:$research_q")
[ -n "$skill_kind" ]  && field_pairs+=("$SKILL_KIND_FIELD:$skill_kind")
[ -n "$skill_name" ]  && field_pairs+=("$SKILL_NAME_FIELD:$skill_name")

if [ ${#field_pairs[@]} -gt 0 ]; then
  payload=$(printf '%s\n' "${field_pairs[@]}" | jq -Rsc '
    split("\n") | map(select(length > 0))
    | map(split(":") | {field_id: (.[0] | tonumber), value: (.[1:] | join(":"))})
  ')
  if printf '%s' "$payload" | gh api -X POST "repos/$repo/issues/$issue_num/issue-field-values" --input - >/dev/null 2>&1; then
    echo "  + fields set: ${#field_pairs[@]}"
  else
    echo "  ! field-values POST failed (the bridge workflow may set them from body sections)" >&2
  fi
fi

# addSubIssue links (mirror coo-memory/bin/add-sub-issues.sh; inlined to
# keep this script self-contained within coo-harness).
resolve_node() {
  local _owner="$1" _repo="$2" _num="$3"
  gh api graphql \
    -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){id}}}' \
    -F o="$_owner" -F r="$_repo" -F n="$_num" --jq '.data.repository.issue.id // empty'
}

parse_ref() {
  local ref="$1"
  if [[ "$ref" == */*#* ]]; then
    REF_OWNER="${ref%%/*}"
    local rest="${ref#*/}"
    REF_REPO="${rest%%#*}"
    REF_NUM="${rest#*#}"
  elif [[ "$ref" == \#* ]]; then
    REF_OWNER="$owner"; REF_REPO="$name"; REF_NUM="${ref#\#}"
  else
    REF_OWNER="$owner"; REF_REPO="$name"; REF_NUM="$ref"
  fi
}

link_sub_issue() {
  local parent_id="$1" child_id="$2" label="$3"
  local out
  out=$(gh api graphql \
    -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){issue{number}}}' \
    -F p="$parent_id" -F c="$child_id" 2>&1) || true
  if grep -qiE 'duplicate sub-issues|may only have one parent|already.*sub.?issue|already linked' <<<"$out"; then
    echo "  ~ sub-issue $label already linked"
  elif grep -qiE 'circular dependency' <<<"$out"; then
    echo "  ! sub-issue $label would create circular dependency — skipped" >&2
  elif grep -qE '"errors"' <<<"$out"; then
    echo "  ! sub-issue $label failed: $out" >&2
    return 1
  else
    echo "  + sub-issue linked: $label"
  fi
}

if [ -n "$parent_issue" ]; then
  parse_ref "$parent_issue"
  parent_id=$(resolve_node "$REF_OWNER" "$REF_REPO" "$REF_NUM")
  if [ -z "$parent_id" ]; then
    echo "  ! --parent-issue $parent_issue not found" >&2
  else
    link_sub_issue "$parent_id" "$issue_node_id" "parent=$REF_OWNER/$REF_REPO#$REF_NUM child=$repo#$issue_num"
  fi
fi

if [ -n "$children" ]; then
  IFS=',' read -ra child_refs <<< "$children"
  for child_ref in "${child_refs[@]}"; do
    child_ref="${child_ref#"${child_ref%%[![:space:]]*}"}"
    child_ref="${child_ref%"${child_ref##*[![:space:]]}"}"
    [ -z "$child_ref" ] && continue
    parse_ref "$child_ref"
    child_id=$(resolve_node "$REF_OWNER" "$REF_REPO" "$REF_NUM")
    if [ -z "$child_id" ]; then
      echo "  ! --children entry $child_ref not found — skipped" >&2
      continue
    fi
    link_sub_issue "$issue_node_id" "$child_id" "parent=$repo#$issue_num child=$REF_OWNER/$REF_REPO#$REF_NUM"
  done
fi
