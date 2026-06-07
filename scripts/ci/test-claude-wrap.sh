#!/usr/bin/env bash
# test-claude-wrap: smoke-test scripts/claude-wrap.sh against a mock `claude`
# binary that echoes its received args. For each fixture, assert whether the
# expected injection (--thinking-display summarized, Workflow tool) is or is
# not present in the exec'd args.
#
# Run: bash scripts/ci/test-claude-wrap.sh
# Exit: 0 if all assertions pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAP="$SCRIPT_DIR/../claude-wrap.sh"

[ -x "$WRAP" ] || { echo "FAIL: wrapper not executable at $WRAP"; exit 1; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/fake-claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
chmod +x "$TMPDIR/fake-claude"

export CLAUDE_WRAP_REAL_BINARY="$TMPDIR/fake-claude"

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

# Workflow tool injection: assert that --tools / --allowed-tools / --allowedTools
# values gain a Workflow token when applicable.
#
# `count_workflow_in_tools_values` counts `Workflow` tokens across the values of
# every --tools / --allowed-tools / --allowedTools flag in a stream of newline-
# separated args (the fake binary's stdout). The fake binary repeats arg names
# verbatim as values, so we must only count Workflow inside extracted *values*,
# not in the flag name `--tools`.
count_workflow_in_tools_values() {
  awk '
    {
      if (expect) { val = $0; expect = 0 }
      else if ($0 == "--tools" || $0 == "--allowed-tools" || $0 == "--allowedTools") { expect = 1; next }
      else if (match($0, /^--tools=/))          { val = substr($0, RLENGTH+1) }
      else if (match($0, /^--allowed-tools=/))  { val = substr($0, RLENGTH+1) }
      else if (match($0, /^--allowedTools=/))   { val = substr($0, RLENGTH+1) }
      else { next }
      n = split(val, parts, ",")
      for (i=1; i<=n; i++) if (parts[i] == "Workflow") c++
    }
    END { print c+0 }
  '
}

# Count Workflow tokens in the input args.
count_workflow_in_input() {
  local prev=""
  local total=0
  for a in "$@"; do
    case "$prev" in
      --tools|--allowed-tools|--allowedTools)
        IFS=',' read -ra parts <<< "$a"
        for p in "${parts[@]}"; do [[ "$p" == "Workflow" ]] && total=$((total+1)); done
        ;;
    esac
    case "$a" in
      --tools=*|--allowed-tools=*|--allowedTools=*)
        IFS=',' read -ra parts <<< "${a#*=}"
        for p in "${parts[@]}"; do [[ "$p" == "Workflow" ]] && total=$((total+1)); done
        ;;
    esac
    prev="$a"
  done
  echo "$total"
}

expect_tools_workflow() {
  local name="$1"; shift
  local out in_count out_count
  out="$(run "$@")"
  in_count="$(count_workflow_in_input "$@")"
  out_count="$(printf '%s\n' "$out" | count_workflow_in_tools_values)"
  if [ "$out_count" -gt "$in_count" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$name: expected injection (in=$in_count, out=$out_count); output: $(printf '%s' "$out" | tr '\n' ' ')")
  fi
}

expect_no_tools_workflow() {
  local name="$1"; shift
  local out in_count out_count
  out="$(run "$@" || true)"
  in_count="$(count_workflow_in_input "$@")"
  out_count="$(printf '%s\n' "$out" | count_workflow_in_tools_values)"
  if [ "$out_count" -eq "$in_count" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$name: expected no injection (in=$in_count, out=$out_count); output: $(printf '%s' "$out" | tr '\n' ' ')")
  fi
}

expect_tools_workflow "cloud launcher shape: --tools preset:default,X --allowedTools preset:default,Y" \
  --sdk-url https://example/cse_X \
  --tools preset:default,Task,Bash,Read \
  --allowedTools preset:default,Task,Bash,Read,mcp__github__*

expect_tools_workflow "= form: --tools=preset:default,X" \
  --sdk-url https://example/cse_X \
  --tools=preset:default,Task,Bash

expect_no_tools_workflow "already present: --tools includes Workflow" \
  --sdk-url https://example/cse_X \
  --tools preset:default,Workflow,Task

expect_no_tools_workflow "= form already present" \
  --sdk-url https://example/cse_X \
  --tools=preset:default,Workflow,Task

expect_no_tools_workflow "--tools default skips injection" \
  --sdk-url https://example/cse_X \
  --tools default

expect_no_tools_workflow "empty --tools value skips injection" \
  --sdk-url https://example/cse_X \
  --tools ""

CC_INJECT_WORKFLOW=0 expect_no_tools_workflow "CC_INJECT_WORKFLOW=0 disables injection" \
  --sdk-url https://example/cse_X \
  --tools preset:default,Task,Bash

# --disallowedTools must NOT receive Workflow (we don't want to deny it).
expect_no_tools_workflow "--disallowedTools is left alone" \
  --sdk-url https://example/cse_X \
  --disallowedTools SomeOther,YetAnother

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
