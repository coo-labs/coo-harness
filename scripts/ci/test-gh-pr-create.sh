#!/usr/bin/env bash
# test-gh-pr-create: smoke-test the PR-open wrapper, with focus on the
# --closes flag added 2026-06-06 to eliminate the embed-in-body-then-
# rediscover-in-lint loop.
#
# Strategy: shadow `gh` on PATH with a mock that dumps its argv, then
# run the wrapper with various arg shapes and assert the closing-keyword
# line lands where expected (or that validation/lint fails with exit 2
# when expected).
#
# Run: bash scripts/ci/test-gh-pr-create.sh
# Exit: 0 if all assertions pass, non-zero otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../gh-pr-create.sh"

[ -r "$WRAPPER" ] || { echo "FAIL: wrapper not found at $WRAPPER"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Minimal git repo so the wrapper's `git rev-parse` calls succeed.
(
  cd "$WORK"
  git init -q
  git config user.email t@t
  git config user.name t
  git remote add origin https://github.com/coo-labs/coo-harness.git
)

# Mock gh on PATH: dump argv one per line.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
i=0
for a in "$@"; do
  i=$((i+1))
  printf 'ARG[%d]=%s\n' "$i" "$a"
done
EOF
chmod 0755 "$WORK/bin/gh"

PASS=0
FAIL=0
declare -a FAILURES=()

run_wrapper() {
  (
    cd "$WORK"
    PATH="$WORK/bin:$PATH" bash "$WRAPPER" "$@" 2>&1
  )
  return $?
}

assert_pass_with_body_contains() {
  local name="$1"; shift
  local needle="$1"; shift
  local out rc
  out="$(run_wrapper "$@")" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    FAIL=$((FAIL+1)); FAILURES+=("$name")
    printf '  FAIL  %s (exit=%d)\n' "$name" "$rc"
    printf '%s\n' "$out" | sed 's/^/         /'
    return
  fi
  if printf '%s' "$out" | grep -qF "$needle"; then
    PASS=$((PASS+1))
    printf '  PASS  %s\n' "$name"
  else
    FAIL=$((FAIL+1)); FAILURES+=("$name")
    printf '  FAIL  %s\n' "$name"
    printf '         expected to contain: %s\n' "$needle"
    printf '         got:\n%s\n' "$out" | sed 's/^/           /'
  fi
}

assert_fail_with_exit_and_contains() {
  local name="$1"; shift
  local expected_rc="$1"; shift
  local needle="$1"; shift
  local out rc
  out="$(run_wrapper "$@")" && rc=0 || rc=$?
  if [ "$rc" -ne "$expected_rc" ]; then
    FAIL=$((FAIL+1)); FAILURES+=("$name")
    printf '  FAIL  %s (got exit=%d, expected=%d)\n' "$name" "$rc" "$expected_rc"
    printf '%s\n' "$out" | sed 's/^/         /'
    return
  fi
  if printf '%s' "$out" | grep -qF "$needle"; then
    PASS=$((PASS+1))
    printf '  PASS  %s\n' "$name"
  else
    FAIL=$((FAIL+1)); FAILURES+=("$name")
    printf '  FAIL  %s\n' "$name"
    printf '         expected to contain: %s\n' "$needle"
    printf '         got:\n%s\n' "$out" | sed 's/^/           /'
  fi
}

echo "test-gh-pr-create: --closes flag and closing-keyword lint"

assert_pass_with_body_contains \
  "--closes <N> appends 'Closes #N'" \
  "Closes #1234" \
  --title "test" --body "doing a thing" --closes 1234

assert_pass_with_body_contains \
  "--closes n/a appends 'Closes: n/a'" \
  "Closes: n/a" \
  --title "test" --closes n/a

assert_pass_with_body_contains \
  "--closes <owner>/<repo>#<N> appends cross-repo form" \
  "Closes coo-labs/coo-memory#42" \
  --title "test" --body "foo" --closes coo-labs/coo-memory#42

assert_pass_with_body_contains \
  "--closes #N (leading hash) is normalized to bare N" \
  "Closes #99" \
  --title "test" --body "foo" --closes "#99"

assert_pass_with_body_contains \
  "--closes= form (equals syntax) works" \
  "Closes #42" \
  --title "test" --body "x" --closes=42

echo "body from file" > "$WORK/bodyfile.md"
assert_pass_with_body_contains \
  "--body-file + --closes appends 'Closes #N'" \
  "Closes #7" \
  --title "test" --body-file "$WORK/bodyfile.md" --closes 7

assert_pass_with_body_contains \
  "--body-file content survives --closes append" \
  "body from file" \
  --title "test" --body-file "$WORK/bodyfile.md" --closes 7

assert_pass_with_body_contains \
  "embedded Closes + --closes both render (additive)" \
  "Closes #1" \
  --title "test" --body $'foo\nCloses #1' --closes 2

assert_fail_with_exit_and_contains \
  "--closes garbage fails validation with exit 2" \
  2 \
  "malformed" \
  --title "test" --body "foo" --closes "not-a-thing"

assert_fail_with_exit_and_contains \
  "no --closes, no Closes line: lint fails with exit 2" \
  2 \
  "closing-keyword check FAILED" \
  --title "test" --body "doing a thing"

assert_pass_with_body_contains \
  "embedded Closes #N alone (no --closes) passes lint" \
  "Closes #5" \
  --title "test" --body $'doing a thing\nCloses #5'

assert_pass_with_body_contains \
  "--skip-hygiene-check bypasses lint" \
  "ARG[1]=pr" \
  --title "test" --body "no closes anywhere" --skip-hygiene-check

assert_pass_with_body_contains \
  "session: title bypasses lint" \
  "ARG[1]=pr" \
  --title "session: log" --body "no closes"

echo
echo "test-gh-pr-create: Pattern-C naked-reponame lint (coo-memory#930)"

# Test origin is coo-labs/coo-harness, so "coo-harness#N" is same-repo,
# "coo-memory#N" is cross-repo.
assert_fail_with_exit_and_contains \
  "naked same-repo ref (coo-harness#42) trips Pattern-C lint" \
  2 \
  "naked reponame form" \
  --title "test" --body $'see coo-harness#42 for context\nCloses #1'

assert_fail_with_exit_and_contains \
  "naked cross-repo ref (coo-memory#42) trips Pattern-C lint" \
  2 \
  "naked reponame form" \
  --title "test" --body $'see coo-memory#42 for context\nCloses #1'

assert_pass_with_body_contains \
  "canonical cross-repo form coo-labs/coo-memory#42 passes" \
  "ARG[1]=pr" \
  --title "test" --body $'see coo-labs/coo-memory#42 for context\nCloses #1'

assert_pass_with_body_contains \
  "bare same-repo #42 passes (no slug prefix)" \
  "ARG[1]=pr" \
  --title "test" --body $'see #42 for context\nCloses #1'

assert_pass_with_body_contains \
  "discussion carve-out: coo-memory discussion #42 passes" \
  "ARG[1]=pr" \
  --title "test" --body $'see coo-memory discussion #42 for context\nCloses #1'

assert_fail_with_exit_and_contains \
  "naked-reponame advisory cites both same-repo and cross-repo" \
  2 \
  "→ \`#42\`" \
  --title "test" --body $'see coo-harness#42 + coo-memory#99\nCloses #1'

echo
if [ "$FAIL" -eq 0 ]; then
  printf 'test-gh-pr-create: %d passed\n' "$PASS"
  exit 0
fi
printf 'test-gh-pr-create: %d passed, %d failed:\n' "$PASS" "$FAIL"
for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
exit 1
