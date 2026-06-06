#!/usr/bin/env bash
# test-track2-env-scrub: tests for preuse-agent-env-scrub.sh (Track 2 Deliverable 3).
#
# Tests:
#   1. warn-mode: logs scrub set to stderr; does NOT block spawn.
#   2. enforce-mode: blocks spawn when secret vars are in scrub set.
#   3. enforce-mode: allows spawn when secret vars listed in frontmatter env_allowlist.
#   4. Agent with no frontmatter: does not fail-closed (fail-open).
#   5. disabled-mode: hook is a no-op (no output, no block).
#   6. Missing schema: fail-open (allow spawn, log to stderr).
#
# Run: bash scripts/ci/test-track2-env-scrub.sh
# Exit: 0 if all assertions pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/preuse-agent-env-scrub.sh"

[ -x "$HOOK" ] || { echo "FAIL: hook not executable at $HOOK"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 required"; exit 1; }

# Stage a minimal coo-memory fixture so the hook's schema reader resolves
# to a real file. Without this, the hook can't classify GITHUB_MCP_PAT as
# a secret var and §2 (enforce-mode-blocks) silently allows. The dev
# container's /home/user/coo-memory hides this in local runs; the CI
# runner exposes it. §6 (missing-schema fail-open) explicitly overrides
# VADE_COO_MEMORY_DIR to a nonexistent path.
FIXTURE_DIR="$(mktemp -d -t env-scrub-fixture.XXXXXX)"
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
SCHEMA_EOF
export VADE_COO_MEMORY_DIR="$FIXTURE_DIR"

PASS=0
FAIL=0
declare -a FAILURES=()

# Use coo-memory schema if available, else skip schema-dependent tests
SCHEMA_PATH="${VADE_COO_MEMORY_DIR:-/home/user/coo-memory}/operations/secrets/schema.yaml"

# Tmp dir for synthetic agent frontmatter files
TMP_AGENTS="$(mktemp -d)"
trap 'rm -rf "$TMP_AGENTS" "$FIXTURE_DIR"' EXIT

# Write a synthetic agent frontmatter with env_allowlist
write_agent_md() {
  local name="$1"
  shift
  local vars=("$@")
  local path="$TMP_AGENTS/$name.md"
  printf -- '---\nname: %s\nenv_allowlist:\n' "$name" > "$path"
  for v in "${vars[@]}"; do
    printf '  - %s\n' "$v" >> "$path"
  done
  printf -- '---\n\n# Agent body\n' >> "$path"
  echo "$path"
}

make_input() {
  local subagent_type="$1"
  jq -n --arg t "$subagent_type" '{tool_input: {subagent_type: $t}}'
}

run_hook_mode() {
  local mode="$1" input="$2" extra_schema_dir="${3:-}"
  local schema_dir="${extra_schema_dir:-${VADE_COO_MEMORY_DIR:-/home/user/coo-memory}}"
  # Run with synthetic agent dir as project-level .claude/agents
  printf '%s' "$input" | \
    VADE_AGENT_ENV_SCRUB="$mode" \
    VADE_COO_MEMORY_DIR="$schema_dir" \
    CLAUDE_PROJECT_DIR="$TMP_AGENTS/.." \
    "$HOOK" 2>&1 || true
}

run_hook_mode_stdout() {
  local mode="$1" input="$2" extra_schema_dir="${3:-}"
  local schema_dir="${extra_schema_dir:-${VADE_COO_MEMORY_DIR:-/home/user/coo-memory}}"
  printf '%s' "$input" | \
    VADE_AGENT_ENV_SCRUB="$mode" \
    VADE_COO_MEMORY_DIR="$schema_dir" \
    CLAUDE_PROJECT_DIR="$TMP_AGENTS/.." \
    "$HOOK" 2>/dev/null || true
}

# ── §1 warn-mode: logs but does NOT block ─────────────────────────────────────
printf '\n§1 warn-mode: logs scrub set, does not block:\n'
input="$(make_input "some-agent")"
# warn-mode stdout should be empty (no block)
stdout="$(run_hook_mode_stdout "warn" "$input")"
if [ -z "$stdout" ] || ! printf '%s' "$stdout" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  PASS=$((PASS+1))
  printf '  PASS  warn-mode: no block on stdout\n'
else
  FAIL=$((FAIL+1))
  FAILURES+=("warn-mode: should not block but did")
  printf '  FAIL  warn-mode: should not block but did\n'
  printf '         stdout: %s\n' "$stdout"
fi
# Stderr should have the log line
stderr_log="$(run_hook_mode "warn" "$input" 2>&1 | grep 'preuse-agent-env-scrub' || true)"
if [ -n "$stderr_log" ]; then
  PASS=$((PASS+1))
  printf '  PASS  warn-mode: log line on stderr\n'
else
  FAIL=$((FAIL+1))
  FAILURES+=("warn-mode: expected log line on stderr")
  printf '  FAIL  warn-mode: expected log line on stderr\n'
fi

# ── §2 enforce-mode: blocks when secret var in scrub set ─────────────────────
printf '\n§2 enforce-mode: blocks when GITHUB_MCP_PAT in env (no frontmatter):\n'
# Export a synthetic secret var to ensure it's in env
input="$(make_input "no-frontmatter-agent")"
stdout="$(GITHUB_MCP_PAT="ghp_synthetic_test_value_not_real" run_hook_mode_stdout "enforce" "$input")"
if printf '%s' "$stdout" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  PASS=$((PASS+1))
  printf '  PASS  enforce-mode: blocks spawn with secret in env\n'
else
  FAIL=$((FAIL+1))
  FAILURES+=("enforce-mode: should block but did not")
  printf '  FAIL  enforce-mode: should block when secret in scrub set\n'
  printf '         stdout: %s\n' "$stdout"
fi

# ── §3 enforce-mode: allows when var listed in frontmatter env_allowlist ──────
printf '\n§3 enforce-mode: allows spawn when secret in frontmatter env_allowlist:\n'
write_agent_md "allowed-agent" "GITHUB_MCP_PAT" >/dev/null
# Create a .claude/agents directory at the synthetic location
mkdir -p "$TMP_AGENTS/.."
# Copy to a path the hook can find
TMP_PROJECT="$(mktemp -d)"
mkdir -p "$TMP_PROJECT/.claude/agents"
write_agent_md_file="$(write_agent_md "allowed-agent" "GITHUB_MCP_PAT")"
cp "$write_agent_md_file" "$TMP_PROJECT/.claude/agents/allowed-agent.md"

input="$(make_input "allowed-agent")"
stdout="$(GITHUB_MCP_PAT="ghp_synthetic_test_value_not_real" \
  VADE_AGENT_ENV_SCRUB="enforce" \
  VADE_COO_MEMORY_DIR="${VADE_COO_MEMORY_DIR:-/home/user/coo-memory}" \
  CLAUDE_PROJECT_DIR="$TMP_PROJECT" \
  printf '%s' "$input" | "$HOOK" 2>/dev/null || true)"
if [ -z "$stdout" ] || ! printf '%s' "$stdout" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  PASS=$((PASS+1))
  printf '  PASS  enforce-mode: allows when var in frontmatter env_allowlist\n'
else
  FAIL=$((FAIL+1))
  FAILURES+=("enforce-mode: should allow when var explicitly listed but blocked")
  printf '  FAIL  enforce-mode: should allow when var in frontmatter env_allowlist\n'
fi
rm -rf "$TMP_PROJECT"

# ── §4 Agent with no frontmatter: fail-open ───────────────────────────────────
printf '\n§4 Agent with no frontmatter file: fail-open (does not fail-closed):\n'
input="$(make_input "nonexistent-agent-xyz")"
# In warn-mode, hook should log and not block
stdout="$(run_hook_mode_stdout "warn" "$input")"
if [ -z "$stdout" ] || ! printf '%s' "$stdout" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  PASS=$((PASS+1))
  printf '  PASS  no-frontmatter: fail-open in warn-mode\n'
else
  FAIL=$((FAIL+1))
  FAILURES+=("no-frontmatter: should not block (fail-open) but did")
  printf '  FAIL  no-frontmatter: should not block in warn-mode\n'
fi

# ── §5 disabled-mode: complete no-op ─────────────────────────────────────────
printf '\n§5 disabled-mode: complete no-op:\n'
input="$(make_input "some-agent")"
stdout="$(run_hook_mode_stdout "disabled" "$input")"
stderr_out="$(run_hook_mode "disabled" "$input" 2>&1 || true)"
if [ -z "$stdout" ] && [ -z "$stderr_out" ]; then
  PASS=$((PASS+1))
  printf '  PASS  disabled-mode: no stdout, no stderr\n'
else
  FAIL=$((FAIL+1))
  FAILURES+=("disabled-mode: expected complete silence")
  printf '  FAIL  disabled-mode: expected no output\n'
  printf '         stdout: %s\n' "$stdout"
  printf '         stderr: %s\n' "$stderr_out"
fi

# ── §6 Missing schema: fail-open ─────────────────────────────────────────────
printf '\n§6 Missing schema: fail-open (allow spawn):\n'
input="$(make_input "some-agent")"
stdout="$(run_hook_mode_stdout "warn" "$input" "/tmp/nonexistent-schema-xyz")"
if [ -z "$stdout" ] || ! printf '%s' "$stdout" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  PASS=$((PASS+1))
  printf '  PASS  missing-schema: fail-open (no block)\n'
else
  FAIL=$((FAIL+1))
  FAILURES+=("missing-schema: should not block (fail-open)")
  printf '  FAIL  missing-schema: should not block but did\n'
fi

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
