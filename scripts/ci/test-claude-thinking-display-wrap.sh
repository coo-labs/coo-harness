#!/usr/bin/env bash
# test-claude-thinking-display-wrap: smoke-test
# scripts/claude-thinking-display-wrap.sh against a mock `claude` binary that
# echoes its received args. For each fixture, assert whether
# `--thinking-display summarized` is or is not present in the exec'd args.
#
# Run: bash scripts/ci/test-claude-thinking-display-wrap.sh
# Exit: 0 if all assertions pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAP="$SCRIPT_DIR/../claude-thinking-display-wrap.sh"

[ -x "$WRAP" ] || { echo "FAIL: wrapper not executable at $WRAP"; exit 1; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/fake-claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
chmod +x "$TMPDIR/fake-claude"

export CLAUDE_THINKING_WRAP_REAL_BINARY="$TMPDIR/fake-claude"

PASS=0
FAIL=0
declare -a FAILURES=()

run() {
  "$WRAP" "$@"
}

# Assert `--thinking-display summarized` appears as the first two args.
expect_inject() {
  local name="$1"; shift
  local out
  out="$(run "$@")"
  if printf '%s' "$out" | head -2 | tr '\n' ' ' \
        | grep -q '^--thinking-display summarized '; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$name: expected injection, got: $(printf '%s' "$out" | tr '\n' ' ')")
  fi
}

# Assert the wrapper did not add a `--thinking-display` arg: the output's count
# of that token matches the input's count.
expect_skip() {
  local name="$1"; shift
  local in_count=0 out_count
  for a in "$@"; do
    case "$a" in --thinking-display|--thinking-display=*) in_count=$((in_count+1));; esac
  done
  local out
  out="$(run "$@" || true)"
  out_count="$(printf '%s\n' "$out" | grep -c -- '^--thinking-display' || true)"
  if [ "$out_count" -eq "$in_count" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$name: expected $in_count --thinking-display in output, got $out_count: $(printf '%s' "$out" | tr '\n' ' ')")
  fi
}

expect_skip   "bare invocation (TUI)"
expect_skip   "--version probe" --version
expect_skip   "mcp subcommand" mcp list
expect_skip   "config subcommand" config get model
expect_skip   "doctor subcommand" doctor

expect_inject "cloud session shape" \
  --output-format=stream-json --verbose --input-format=stream-json \
  --maintenance --model claude-opus-4-7 \
  --sdk-url https://example/cse_X --resume=https://example/cse_X --debug

expect_inject "headless -p" -p "what is 2+2"
expect_inject "headless --print" --print "what is 2+2"
expect_inject "vscode --thinking adaptive + -p" \
  --thinking adaptive --model claude-opus-4-7 -p "test"
expect_inject "vscode --thinking enabled + -p" \
  --thinking enabled -p "test"
expect_inject "--output-format= alone is enough" \
  --output-format=stream-json

expect_skip   "--thinking disabled" --thinking disabled -p "test"
expect_skip   "already has --thinking-display" \
  --thinking-display summarized -p "test"
expect_skip   "already has --thinking-display=omitted" \
  --thinking-display=omitted -p "test"

CC_THINKING_DISPLAY=omitted expect_skip   "CC_THINKING_DISPLAY=omitted env" -p "test"
CC_THINKING_DISPLAY=summarized expect_inject "CC_THINKING_DISPLAY=summarized env" -p "test"

echo
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
