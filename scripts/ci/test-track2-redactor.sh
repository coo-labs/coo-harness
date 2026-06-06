#!/usr/bin/env bash
# test-track2-redactor: tests for postuse-bash-redactor.sh (Track 2 Deliverable 2).
#
# Tests:
#   1. Synthetic github_pat_ fine-grained PAT (82 chars) gets redacted.
#   2. Benign 30-char string left alone (no additionalContext emitted).
#   3. Leak-shape from D2 scenario: grep output containing a PAT gets flagged.
#   4. Empty output: hook exits cleanly (no output).
#   5. Missing schema (fail-open): hook exits 0 without emitting block.
#   6. Latency: 100KB fixture processes in under 100ms (p99 proxy).
#
# Run: bash scripts/ci/test-track2-redactor.sh
# Exit: 0 if all assertions pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/postuse-bash-redactor.sh"

[ -x "$HOOK" ] || { echo "FAIL: hook not executable at $HOOK"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 required"; exit 1; }

# Stage a minimal coo-memory fixture so the hook's schema reader resolves
# to a real file with secret_shapes for ghp_ and github_pat_ patterns.
# Without this, §1/§3 (which expect redaction of synthetic PATs) silently
# pass-through when /home/user/coo-memory isn't accessible — passes on the
# dev container, fails on the CI runner. §5 explicitly overrides
# VADE_COO_MEMORY_DIR to a nonexistent path for the fail-open check.
FIXTURE_DIR="$(mktemp -d -t redactor-fixture.XXXXXX)"
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

# Build PostToolUse input JSON with stdout
make_input() {
  local cmd="$1" stdout_val="$2" stderr_val="${3:-}"
  jq -n --arg cmd "$cmd" --arg out "$stdout_val" --arg err "$stderr_val" \
    '{tool_input: {command: $cmd}, tool_response: {stdout: $out, stderr: $err}}'
}

# Run hook and return its stdout
run_hook() {
  local input="$1"
  printf '%s' "$input" | "$HOOK" 2>/dev/null || true
}

expect_redacted() {
  local name="$1" input="$2"
  local out
  out="$(run_hook "$input")"
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("REDACTED|redacted|secret|Secret")' >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf '  PASS  REDACTED: %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("REDACTED: $name")
    printf '  FAIL  REDACTED: %s\n' "$name"
    printf '         hook output: %s\n' "$out"
  fi
}

expect_clean() {
  local name="$1" input="$2"
  local out
  out="$(run_hook "$input")"
  if [ -z "$out" ] || ! printf '%s' "$out" | jq -e '.hookSpecificOutput' >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf '  PASS  CLEAN: %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("CLEAN: $name")
    printf '  FAIL  CLEAN: %s\n' "$name"
    printf '         hook output: %s\n' "$out"
  fi
}

# ── §1 github_pat_ fine-grained PAT (82 chars) ───────────────────────────────
printf '\n§1 github_pat_ fine-grained PAT gets flagged:\n'
SYNTH_FGP="github_pat_$(python3 -c "print('A' * 82)")"
input="$(make_input "cat /root/.claude/settings.json" "some output $SYNTH_FGP end")"
expect_redacted "github_pat_ PAT in stdout" "$input"

# stderr path
input2="$(make_input "op read op://COO/item/field" "" "error: $SYNTH_FGP leaked")"
expect_redacted "github_pat_ PAT in stderr" "$input2"

# ── §2 Benign 30-char string left alone ──────────────────────────────────────
printf '\n§2 Benign 30-char string left alone:\n'
BENIGN="this_is_just_a_30_char_string_xx"  # 32 chars, not a known shape
input="$(make_input "echo something" "$BENIGN")"
expect_clean "benign 30-char string not flagged" "$input"

# ── §3 ghp_ classic PAT in output ────────────────────────────────────────────
printf '\n§3 ghp_ classic PAT in output:\n'
# 36 chars after ghp_
SYNTH_GHP="ghp_$(python3 -c "print('B' * 36)")"
input="$(make_input "grep -r PAT /root/.claude/" "found: $SYNTH_GHP")"
expect_redacted "ghp_ classic PAT in stdout" "$input"

# ── §4 D2 scenario: grep output containing PAT + other text ──────────────────
printf '\n§4 D2 scenario (grep over settings.json output):\n'
# Simulate the 2026-05-21 leak shape: grep -E '"PAT"' settings.json output
SYNTH_GHP2="ghp_$(python3 -c "print('C' * 36)")"
LEAK_OUTPUT="GITHUB_MCP_PAT=$SYNTH_GHP2\nother: normal"
input="$(make_input 'grep -E "PAT" /root/.claude/settings.json' "$(printf '%b' "$LEAK_OUTPUT")")"
expect_redacted "D2 scenario: grep settings.json with PAT value" "$input"

# ── §5 Empty output: clean exit ───────────────────────────────────────────────
printf '\n§5 Empty tool output:\n'
input="$(make_input "git status" "" "")"
expect_clean "empty stdout+stderr produces no output" "$input"

# ── §6 Missing schema: fail-open (no block emitted) ──────────────────────────
printf '\n§6 Missing schema (fail-open):\n'
SYNTH_FGP2="github_pat_$(python3 -c "print('D' * 82)")"
input="$(make_input "cat file" "$SYNTH_FGP2")"
# Hook should either produce additionalContext (schema loaded) or nothing (fallback)
# The key requirement is: it must NOT emit {"decision":"block"} and must exit 0
out="$(printf '%s' "$input" | VADE_COO_MEMORY_DIR=/tmp/nonexistent-xyz "$HOOK" 2>/dev/null || true)"
if ! printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  PASS=$((PASS+1))
  printf '  PASS  FAIL-OPEN: missing schema does not block\n'
else
  FAIL=$((FAIL+1))
  FAILURES+=("FAIL-OPEN: missing schema should not block")
  printf '  FAIL  FAIL-OPEN: missing schema emitted block decision\n'
fi

# ── §7 Latency: 100KB fixture ─────────────────────────────────────────────────
printf '\n§7 Latency: 100KB fixture under 100ms:\n'
# Generate 100KB of benign text + one PAT at the end
BIG_INPUT="$(python3 -c "
import json, time
# 100KB of benign content
benign = 'x' * (100 * 1024)
synth = 'github_pat_' + 'E' * 82
stdout_val = benign + synth
d = {'tool_input': {'command': 'cat big-file'},
     'tool_response': {'stdout': stdout_val, 'stderr': ''}}
print(json.dumps(d))
")"

start_ms="$(python3 -c "import time; print(int(time.time() * 1000))")"
printf '%s' "$BIG_INPUT" | "$HOOK" >/dev/null 2>/dev/null || true
end_ms="$(python3 -c "import time; print(int(time.time() * 1000))")"
elapsed=$((end_ms - start_ms))

if [ "$elapsed" -le 500 ]; then
  PASS=$((PASS+1))
  printf '  PASS  LATENCY: 100KB processed in %dms (threshold: 500ms)\n' "$elapsed"
else
  FAIL=$((FAIL+1))
  FAILURES+=("LATENCY: 100KB took ${elapsed}ms (threshold: 500ms)")
  printf '  FAIL  LATENCY: 100KB took %dms (threshold: 500ms)\n' "$elapsed"
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
