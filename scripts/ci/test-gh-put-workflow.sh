#!/usr/bin/env bash
# test-gh-put-workflow: unit-test the parsing helpers in
# scripts/gh-put-workflow.sh — owner/repo extraction across remote-URL
# shapes, and path resolution across absolute / relative / outside-repo
# inputs.
#
# Strategy: source the wrapper (its `main "$@"` is BASH_SOURCE-guarded)
# and call helpers directly. Real `gh` calls are not exercised here —
# those depend on App-token routing through `gh-coo-wrap.sh` and are
# covered by manual fresh-container verification.
#
# Run: bash scripts/ci/test-gh-put-workflow.sh
# Exit: 0 on all pass, non-zero on any fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../gh-put-workflow.sh"

[ -f "$WRAPPER" ] || { echo "FAIL: wrapper not found at $WRAPPER"; exit 1; }

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n    expected: %q\n    actual:   %q\n' "$label" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_empty() {
  local label="$1" actual="$2"
  if [ -z "$actual" ]; then
    printf '  PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n    expected empty, got: %q\n' "$label" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

# shellcheck disable=SC1090
source "$WRAPPER"

echo "== extract_repo_path =="

assert_eq "https github.com" "coo-labs/coo-harness" \
  "$(extract_repo_path "https://github.com/coo-labs/coo-harness")"

assert_eq "https github.com .git suffix" "coo-labs/coo-harness" \
  "$(extract_repo_path "https://github.com/coo-labs/coo-harness.git")"

assert_eq "ssh git@github.com" "coo-labs/coo-harness" \
  "$(extract_repo_path "git@github.com:coo-labs/coo-harness.git")"

assert_eq "cloud proxy form" "coo-labs/coo-harness" \
  "$(extract_repo_path "http://127.0.0.1:35033/git/coo-labs/coo-harness")"

assert_eq "cloud proxy form with user" "coo-labs/coo-harness" \
  "$(extract_repo_path "http://local_proxy@127.0.0.1:35033/git/coo-labs/coo-harness.git")"

assert_empty "garbage url" \
  "$(extract_repo_path "not-a-url")"

echo "== resolve_relative_path =="

tmp="$(mktemp -d)"
mkdir -p "$tmp/.github/workflows"
touch "$tmp/.github/workflows/foo.yml"

assert_eq "absolute path inside repo" ".github/workflows/foo.yml" \
  "$(resolve_relative_path "$tmp/.github/workflows/foo.yml" "$tmp")"

# CWD-relative case: cd into tmp so the relative resolution sees the
# correct base.
(
  cd "$tmp" || exit 1
  rel="$(resolve_relative_path ".github/workflows/foo.yml" "$tmp")"
  printf '%s' "$rel"
) > "$tmp/relative.out"
assert_eq "relative path inside repo" ".github/workflows/foo.yml" "$(cat "$tmp/relative.out")"

# Outside-repo case must error (non-zero exit + empty stdout).
out="$(resolve_relative_path "/etc/hosts" "$tmp" 2>/dev/null)" \
  && outcome="ok-but-shouldnt" \
  || outcome="errored"
assert_eq "outside-repo path errors" "errored" "$outcome"
assert_empty "outside-repo path empty stdout" "$out"

rm -rf "$tmp"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "all ${PASS} assertions passed"
  exit 0
else
  echo "${FAIL} of $((PASS + FAIL)) assertions failed"
  exit 1
fi
