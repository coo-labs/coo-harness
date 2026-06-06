#!/usr/bin/env bash
# test-bash-github-api-guard: smoke-test scripts/hooks/bash-github-api-guard.sh.
#
# Mirrors the test-bash-token-guard.sh shape: pipe PreToolUse JSON
# envelopes into the hook, assert block / allow per case.
#
# Run: bash scripts/hooks/test-bash-github-api-guard.sh
# Exit: 0 on all pass, 1 otherwise.
#
# Reference: MEMO-2026-05-12-22m9, coo-harness#TBD.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/bash-github-api-guard.sh"

[ -x "$HOOK" ] || { echo "FAIL: hook not executable at $HOOK"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 required"; exit 1; }

PASS=0
FAIL=0
declare -a FAILURES=()

run_hook() {
  local cmd="$1"
  jq -n --arg c "$cmd" '{tool_input: {command: $c}}' | "$HOOK" 2>/dev/null
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

printf 'BLOCK fixtures (must be refused):\n'
expect_block "curl https://api.github.com/repos/foo/bar/forks" \
  'curl https://api.github.com/repos/foo/bar/forks'
expect_block "curl -X POST https://api.github.com/repos/foo/bar/forks" \
  'curl -X POST https://api.github.com/repos/foo/bar/forks'
expect_block "curl with Authorization header" \
  'curl -H "Authorization: token $GITHUB_PUBLIC_PAT" https://api.github.com/user'
expect_block "wget https://api.github.com/..." \
  'wget https://api.github.com/repos/foo/bar'
expect_block "/usr/bin/curl absolute path" \
  '/usr/bin/curl https://api.github.com/repos/foo/bar'
expect_block "python3 -c with requests to api.github.com" \
  'python3 -c "import requests; requests.post(\"https://api.github.com/repos/foo/bar/forks\")"'
expect_block "node -e with fetch to api.github.com" \
  'node -e "fetch(\"https://api.github.com/foo\")"'
expect_block "ruby -e with api.github.com" \
  'ruby -e "require \"net/http\"; Net::HTTP.get(URI(\"https://api.github.com/foo\"))"'
expect_block "pipeline: cat | curl https://api.github.com" \
  'cat body.json | curl -X POST -d @- https://api.github.com/repos/foo/bar/issues'
expect_block "logical: && curl api.github.com" \
  'echo starting && curl https://api.github.com/user'
expect_block "logical: ; curl api.github.com" \
  'true; curl https://api.github.com/user'

printf '\nALLOW fixtures (must pass through):\n'
expect_allow "gh api repos/foo/bar" \
  'gh api repos/foo/bar'
expect_allow "gh api -X POST repos/foo/bar/forks" \
  'gh api -X POST repos/foo/bar/forks'
expect_allow "gh repo fork foo/bar" \
  'gh repo fork foo/bar'
expect_allow "gh pr create --repo foo/bar" \
  'gh pr create --repo foo/bar --title t --body x'
expect_allow "grep -r api.github.com . (text search)" \
  'grep -r api.github.com .'
expect_allow "sed editing a file mentioning api.github.com" \
  'sed -i "s/api.github.com/example/" file'
expect_allow "cat file.txt (no api.github.com in cmd)" \
  'cat file.txt'
expect_allow "curl https://example.com (not api.github.com)" \
  'curl https://example.com/something'
expect_allow "curl raw.githubusercontent.com (not the API)" \
  'curl https://raw.githubusercontent.com/foo/bar/main/x'
expect_allow "curl github.com (not api subdomain)" \
  'curl https://github.com/foo/bar'
expect_allow "python3 my_script.py (no api.github.com in argv)" \
  'python3 my_script.py'
expect_allow "git push origin main" \
  'git push origin main'
expect_allow "VADE_GITHUB_API_GUARD_BYPASS=1 curl api.github.com" \
  'VADE_GITHUB_API_GUARD_BYPASS=1 curl https://api.github.com/user'
expect_allow "echo with api.github.com string (not a fetch)" \
  'echo "api.github.com is the endpoint"'
expect_allow "comment containing api.github.com" \
  '# fix curl to api.github.com later
echo done'

printf '\nTotal: %d pass, %d fail\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed cases:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
