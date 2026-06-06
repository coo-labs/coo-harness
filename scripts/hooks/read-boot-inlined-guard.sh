#!/usr/bin/env bash
# PreToolUse Read hook: refuse Read on files already inlined by the
# SessionStart `coo-identity-digest`. Reading them duplicates context
# the boot banner already surfaced.
#
# Why: When CLAUDE.md documented "don't Read this" / "only Read if
# truncated" in prose, models reasoned about whether-to-read on each
# call and sometimes got it wrong — wasted-cycles tax that compounds
# across the session. Per the coo-memory#1133 trim review:
#
#   > "this is now in the digest and models have to reason to skip it,
#     ending up skipping other files. remove" (identity_layer.md)
#   > "don't tell what not to read. block reading via hook such that
#     models don't even try" (memo_index.json)
#
# The hook route is structural: Read just refuses, the message names
# the escape hatch, the agent's next move is the right one.
#
# Contract: reads Claude Code's PreToolUse JSON on stdin,
#   { "tool_name": "Read", "tool_input": { "file_path": "..." } }
# Always exits 0. To block, emits
#   { "decision": "block", "reason": "..." }
# on stdout. To allow, emits nothing.
#
# Path matching: tail-suffix match on `file_path` against known
# boot-surfaced files. We don't canonicalize — the canonical paths
# live under `*/coo-memory/{memos,identity}/...` and a suffix match
# catches direct paths from any sibling-checkout location without
# stat-ing the filesystem.
#
# Blocked paths:
#   - */memos/memo_index.json
#     Flat JSON, ≳25K tokens, regenerated each container epoch from
#     memos/*.md by the `memo-index` SessionStart hook. 10-most-recent
#     in digest; deeper slices via `jq` per .claude/skills/memo-search/references/retrieval-policy.md.
#   - */identity/identity_layer.md
#     Fully inlined in the digest's "Identity layer (CB-*/OG-*)" block.
#     If genuinely truncated, force-read via `cat` from Bash.
#
# Scope: Read only. Edit / Write / Bash all pass through — committee
# revisions, /memo-sync regenerations, and `jq`/`cat` queries against
# the same files remain unblocked.
#
# Bypass: VADE_BOOT_INLINED_READ_GUARD_BYPASS=1 → unconditionally allow.
#
# Reference: coo-harness#399; coo-memory#1133.

set -uo pipefail

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

if [ "${VADE_BOOT_INLINED_READ_GUARD_BYPASS:-}" = "1" ]; then
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || true)"
[ "$tool_name" = "Read" ] || exit 0

file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)"
[ -z "$file_path" ] && exit 0

reason=""
case "$file_path" in
  */memos/memo_index.json)
    reason="[read-boot-inlined-guard] memos/memo_index.json is regenerated each container epoch from memos/*.md and the 10-most-recent slice is already in the boot digest's \"Latest memos\" block. The full file is ≳25K tokens — Read would dump it into context unnecessarily.

Use one of:
  - \`jq '...' memos/memo_index.json\` from a Bash call for deeper slices (schema: .claude/skills/memo-search/references/retrieval-policy.md).
  - \`/memo-query <term>\` for literal keyword lookup.
  - \`/memo-query --semantic \"<query>\"\` for concept search.

Edit/Write are unblocked — /memo-sync regenerations and manual fixes still work.

Bypass for a deliberate diagnostic: prefix \`VADE_BOOT_INLINED_READ_GUARD_BYPASS=1\`. See coo-harness#399."
    ;;
  */identity/identity_layer.md)
    reason="[read-boot-inlined-guard] identity/identity_layer.md is fully inlined in the SessionStart digest's \"Identity layer (CB-*/OG-*)\" block — every CB-* belief and OG-* goal is already in your context. Read would duplicate it.

If the digest was genuinely truncated this session, force-read via:
  cat /home/user/coo-memory/identity/identity_layer.md

Edit/Write are unblocked — committee revisions and citation updates still work normally.

Bypass for a deliberate diagnostic: prefix \`VADE_BOOT_INLINED_READ_GUARD_BYPASS=1\`. See coo-harness#399."
    ;;
esac

[ -z "$reason" ] && exit 0

jq -n --arg reason "$reason" '{
  decision: "block",
  reason: $reason
}'
exit 0
