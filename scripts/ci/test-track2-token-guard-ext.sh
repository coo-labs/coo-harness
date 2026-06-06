#!/usr/bin/env bash
# test-track2-token-guard-ext: regression + extension tests for the
# schema-driven bash-token-guard.sh (Track 2 Deliverable 1).
#
# Tests:
#   1. Regression: existing 5-var hardcoded fast path still blocks correctly
#      (even when schema is present).
#   2. Shape-regex: new ghp_-shaped synthetic secret gets blocked.
#   3. New shape: github_pat_ fine-grained PAT shape gets blocked.
#   4. op item edit blocked outside VADE_SECRETS_SKILL_ACTIVE.
#   5. op item edit allowed when VADE_SECRETS_SKILL_ACTIVE=1.
#   6. gh secret set blocked outside skill.
#   7. Safe contexts still pass (pipe, /dev/null, length check, existence test).
#   8. Schema fallback: hook still blocks with a missing schema (uses hardcoded list).
#
# Run: bash scripts/ci/test-track2-token-guard-ext.sh
# Exit: 0 if all assertions pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/bash-token-guard.sh"

[ -x "$HOOK" ] || { echo "FAIL: hook not executable at $HOOK"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 required"; exit 1; }

# Stage a minimal coo-memory fixture so the hook's schema reader resolves to
# a real file with the `credentials:` + `secret_shapes:` blocks §1/§3/§4 need.
# Without this, the test silently used /home/user/coo-memory if it happened to
# exist (true on the dev container, false on the CI runner) — passing locally
# and failing in CI. The §2 fallback path explicitly overrides
# VADE_COO_MEMORY_DIR to a nonexistent dir to exercise schema-unreadable.
FIXTURE_DIR="$(mktemp -d -t bash-token-guard-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
mkdir -p "$FIXTURE_DIR/operations/secrets"
cat > "$FIXTURE_DIR/operations/secrets/schema.yaml" <<'SCHEMA_EOF'
schema_version: 1
vault: COO
credentials:
  - id: github-pat-vade-coo
    op_item: vade-coo-self-2026-04
    op_field: token
    status: active
    rotation_class: III
    env_aliases:
      - GITHUB_MCP_PAT
      - GITHUB_TOKEN
  - id: mem0-api
    op_item: mem0-vade-coo
    op_field: credential
    status: active
    rotation_class: III
    env_aliases:
      - MEM0_API_KEY
  - id: op-sa-token
    op_item: service-account
    op_field: token
    status: active
    rotation_class: IV
    env_aliases:
      - OP_SERVICE_ACCOUNT_TOKEN
  - id: agentmail-api
    op_item: agentmail-vade-coo
    op_field: credential
    status: active
    rotation_class: III
    env_aliases:
      - AGENTMAIL_API_KEY
secret_shapes:
  - name: github-classic-pat
    pattern: 'ghp_[A-Za-z0-9]{36}'
  - name: github-fine-grained-pat
    pattern: 'github_pat_[A-Za-z0-9_]{82}'
SCHEMA_EOF
export VADE_COO_MEMORY_DIR="$FIXTURE_DIR"

PASS=0
FAIL=0
declare -a FAILURES=()

run_hook() {
  local cmd="$1"
  local extra_env="${2:-}"
  if [ -n "$extra_env" ]; then
    env "$extra_env" bash -c "jq -n --arg c \"\$1\" '{tool_input: {command: \$c}}' | \"$HOOK\" 2>/dev/null" -- "$cmd" || true
  else
    jq -n --arg c "$cmd" '{tool_input: {command: $c}}' | "$HOOK" 2>/dev/null || true
  fi
}

run_hook_with_env() {
  local cmd="$1"
  shift
  # Pass additional env vars
  jq -n --arg c "$cmd" '{tool_input: {command: $c}}' | env "$@" "$HOOK" 2>/dev/null || true
}

expect_block() {
  local name="$1" cmd="$2"
  local out
  out="$(run_hook "$cmd")"
  if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf '  PASS  BLOCK: %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("BLOCK: $name")
    printf '  FAIL  BLOCK: %s\n' "$name"
    printf '         command: %s\n' "$cmd"
    printf '         hook output: %s\n' "$out"
  fi
}

expect_allow() {
  local name="$1" cmd="$2"
  local out
  out="$(run_hook "$cmd")"
  if [ -z "$out" ] || ! printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf '  PASS  ALLOW: %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("ALLOW: $name")
    printf '  FAIL  ALLOW: %s\n' "$name"
    printf '         command: %s\n' "$cmd"
    printf '         hook output: %s\n' "$out"
  fi
}

expect_block_with_skill_active() {
  local name="$1" cmd="$2" expected_block="${3:-false}"
  local out
  out="$(jq -n --arg c "$cmd" '{tool_input: {command: $c}}' | \
    VADE_SECRETS_SKILL_ACTIVE=1 "$HOOK" 2>/dev/null || true)"
  if [ "$expected_block" = "true" ]; then
    if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
      PASS=$((PASS+1))
      printf '  PASS  BLOCK(skill_active): %s\n' "$name"
    else
      FAIL=$((FAIL+1))
      FAILURES+=("BLOCK_SKILL_ACTIVE: $name")
      printf '  FAIL  BLOCK(skill_active): %s\n' "$name"
    fi
  else
    if [ -z "$out" ] || ! printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
      PASS=$((PASS+1))
      printf '  PASS  ALLOW(skill_active): %s\n' "$name"
    else
      FAIL=$((FAIL+1))
      FAILURES+=("ALLOW_SKILL_ACTIVE: $name")
      printf '  FAIL  ALLOW(skill_active): %s\n' "$name"
    fi
  fi
}

# ── §1 Regression: original 5-var list still blocks ───────────────────────────
printf '\n§1 Regression: original 5-var fast path (schema present):\n'
expect_block "echo \$GITHUB_MCP_PAT" \
  'echo $GITHUB_MCP_PAT'
expect_block "echo \"\$GITHUB_TOKEN\"" \
  'echo "$GITHUB_TOKEN"'
expect_block "printf '%s\\n' \$MEM0_API_KEY" \
  "printf '%s\\n' \$MEM0_API_KEY"
expect_block "cat <<EOF / \$OP_SERVICE_ACCOUNT_TOKEN / EOF" \
  $'cat <<EOF\n$OP_SERVICE_ACCOUNT_TOKEN\nEOF'
expect_block "echo \$AGENTMAIL_API_KEY > /tmp/leak.txt" \
  'echo $AGENTMAIL_API_KEY > /tmp/leak.txt'

# ── §2 Schema fallback: hook still blocks with missing schema ─────────────────
printf '\n§2 Schema fallback (nonexistent schema path):\n'
# Override schema path to a nonexistent file — should fall back to hardcoded list
out="$(jq -n --arg c 'echo $GITHUB_MCP_PAT' '{tool_input: {command: $c}}' | \
  VADE_COO_MEMORY_DIR=/tmp/nonexistent-schema-path-xyz "$HOOK" 2>/dev/null || true)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  PASS=$((PASS+1))
  printf '  PASS  BLOCK(fallback): echo $GITHUB_MCP_PAT with missing schema\n'
else
  FAIL=$((FAIL+1))
  FAILURES+=("BLOCK(fallback): echo \$GITHUB_MCP_PAT with missing schema")
  printf '  FAIL  BLOCK(fallback): echo $GITHUB_MCP_PAT with missing schema\n'
  printf '         hook output: %s\n' "$out"
fi

# ── §3 Shape-regex: ghp_-shaped synthetic PAT ────────────────────────────────
printf '\n§3 Shape-regex: github-classic-pat (ghp_ shape):\n'
# This is a synthetic token matching the ghp_[A-Za-z0-9]{36} pattern
SYNTH_GHP="ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"  # 36 chars after ghp_
expect_block "echo ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
  "echo ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

# ── §4 Shape-regex: github_pat_ fine-grained PAT ─────────────────────────────
printf '\n§4 Shape-regex: github-fine-grained-pat (github_pat_ shape):\n'
# 82 chars of [A-Za-z0-9_] after github_pat_
SYNTH_FGP="github_pat_$(python3 -c "print('A' * 82)")"
expect_block "echo $SYNTH_FGP" \
  "echo $SYNTH_FGP"

# ── §5 op item edit / gh secret set blocking ─────────────────────────────────
printf '\n§5 op item edit / gh secret set blocked outside skill:\n'
expect_block "op item edit my-item field=value" \
  "op item edit my-item field=value"
expect_block "gh secret set MY_SECRET --body \$VALUE" \
  'gh secret set MY_SECRET --body $VALUE'
expect_block "op item update vade-coo-self-2026-04 token=newval" \
  'op item update vade-coo-self-2026-04 token=newval'

# ── §6 op item edit allowed when VADE_SECRETS_SKILL_ACTIVE=1 ─────────────────
printf '\n§6 op item edit / gh secret set allowed with VADE_SECRETS_SKILL_ACTIVE=1:\n'
expect_block_with_skill_active "op item edit allowed when skill active" \
  "op item edit my-item field=value" "false"
expect_block_with_skill_active "gh secret set allowed when skill active" \
  'gh secret set MY_SECRET --body value' "false"

# ── §7 Safe contexts still pass ───────────────────────────────────────────────
printf '\n§7 Safe contexts (must still pass):\n'
expect_allow "[ -n \"\$GITHUB_MCP_PAT\" ] && echo set" \
  '[ -n "$GITHUB_MCP_PAT" ] && echo set'
expect_allow "echo \"\${#GITHUB_TOKEN}\"" \
  'echo "${#GITHUB_TOKEN}"'
expect_allow "echo \$GITHUB_MCP_PAT > /dev/null" \
  'echo $GITHUB_MCP_PAT > /dev/null'
expect_allow "echo \"\$GITHUB_MCP_PAT\" | gh auth login --with-token" \
  'echo "$GITHUB_MCP_PAT" | gh auth login --with-token'
expect_allow "git status" \
  "git status"
expect_allow "op read 'op://COO/...'" \
  "op read 'op://COO/...'"

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\nTotal: %d pass, %d fail\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed cases:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
