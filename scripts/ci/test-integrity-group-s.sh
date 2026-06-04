#!/usr/bin/env bash
# Test suite for the Group S secrets-schema invariants in
# scripts/lib/integrity-group-s.sh.
#
# Each test materializes a synthetic schema.yaml (and optional
# settings.json / coo-env file) under $TEST_ROOT, sources the helper
# with a stubbed $VADE_COO_MEMORY_DIR + override variables that route
# the invariant to the synthetic fixtures, and asserts the invariant's
# (key, ok, detail) triple.
#
# Coverage:
#   - S1: clean → ok; injected malformed schema → fail.
#   - S2: every alias set → ok; one alias unset (non-dormant) → fail.
#         Dormant credential's unset alias does NOT fail.
#   - S3: declared container_env mirror present in synthetic
#         settings.json → ok; mirror file absent → fail.
#   - S4: skip in CI fake-env (documents the skip path).
#   - S5: synthetic sanctioned path with secret-shape match → ok;
#         empty/no-match sanctioned path → fail.
#   - S7: skip in CI fake-env (documents the skip path).
#   - S8: env classification — known alias goes to declared_secret;
#         unknown allowlisted prefix → prefix_allowlist; injected
#         token-shape value on an unknown name → unknown_secret_shape.
#
# Skips:
#   - S4 + S7 live `op` integration is exercised in the cloud session
#     (Track 1b soak), not here — CI fake-env can't validate op-read.
#     The test asserts the skip detail wording is sensible.
#
# Exit 0 if all assertions pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/lib/integrity-group-s.sh"
FIXTURE="$REPO_ROOT/scripts/ci/fixtures/secrets-schema-clean.yaml"

[ -r "$HELPER" ]   || { echo "FAIL: helper not readable at $HELPER"; exit 1; }
[ -r "$FIXTURE" ]  || { echo "FAIL: fixture not readable at $FIXTURE"; exit 1; }
command -v yq      >/dev/null 2>&1 || { echo "FAIL: yq required"; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "FAIL: jq required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "FAIL: PyYAML required"; exit 1; }

TEST_ROOT="${TEST_ROOT:-/tmp/integrity-group-s-test-$$}"
mkdir -p "$TEST_ROOT"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0
declare -a FAILURES=()

_pass() {
  PASS=$((PASS + 1))
  printf '  ok: %s\n' "$1"
}

_fail() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$1")
  printf '  FAIL: %s\n' "$1"
}

# Render a fresh fixture into $1 with __FIXTURE_DIR__ replaced by $2.
_render_fixture() {
  local dst="$1" fixdir="$2"
  sed "s#__FIXTURE_DIR__#$fixdir#g" "$FIXTURE" > "$dst"
}

# Stage a synthetic VADE_COO_MEMORY_DIR-shaped tree under a per-test
# directory. Returns the path on stdout.
_stage_memory() {
  local dir="$1"
  mkdir -p "$dir/operations/secrets/env-snapshots" "$dir/bin"
  # Stage a copy of secrets-schema-check.py + schema.schema.json from
  # the live coo-memory checkout if available. If not, S1 will skip
  # cleanly (caller decides whether to assert).
  local src_validator="${VADE_COO_MEMORY_DIR:-/home/user/coo-memory}/bin/secrets-schema-check.py"
  local src_schema="${VADE_COO_MEMORY_DIR:-/home/user/coo-memory}/operations/secrets/schema.schema.json"
  if [ -f "$src_validator" ]; then
    cp "$src_validator" "$dir/bin/secrets-schema-check.py"
    chmod +x "$dir/bin/secrets-schema-check.py"
  fi
  if [ -f "$src_schema" ]; then
    cp "$src_schema" "$dir/operations/secrets/schema.schema.json"
  fi
  _render_fixture "$dir/operations/secrets/schema.yaml" "$dir"
  printf '%s' "$dir"
}

# Source the helper + run a single S<N> check inside a subshell with
# RESULTS captured. Sets `_LAST_KEY`, `_LAST_OK`, `_LAST_DETAIL` from
# the FIRST matching `<key>|<ok>|<detail>` line emitted.
_run_invariant() {
  local key="$1" mem_dir="$2"
  shift 2
  local out
  out="$(
    VADE_COO_MEMORY_DIR="$mem_dir" \
    VADE_SECRETS_SNAPSHOT_DIR="$mem_dir/operations/secrets/env-snapshots" \
    VADE_SECRETS_SNAPSHOT_SKIP="${VADE_SECRETS_SNAPSHOT_SKIP:-1}" \
    "$@" bash -c '
      set -uo pipefail
      RESULTS=()
      _add() { RESULTS+=("$1|$2|$3"); }
      source "'"$HELPER"'"
      s_check_'"$key"'
      printf "%s\n" "${RESULTS[@]}"
    ' 2>&1)"
  # First line with the key
  local line
  line="$(printf '%s\n' "$out" | grep -E "^${key}\|" | head -1)"
  _LAST_KEY="${line%%|*}"
  local rest="${line#*|}"
  _LAST_OK="${rest%%|*}"
  _LAST_DETAIL="${rest#*|}"
}

# Per-key assertion helpers.
_assert_ok() {
  local key="$1" label="$2"
  if [ "$_LAST_KEY" = "$key" ] && [ "$_LAST_OK" = "true" ]; then
    _pass "$key OK: $label"
  else
    _fail "$key expected ok=true, got ok=$_LAST_OK detail=$_LAST_DETAIL ($label)"
  fi
}
_assert_fail() {
  local key="$1" label="$2"
  if [ "$_LAST_KEY" = "$key" ] && [ "$_LAST_OK" = "false" ]; then
    _pass "$key FAIL (as expected): $label"
  else
    _fail "$key expected ok=false, got ok=$_LAST_OK detail=$_LAST_DETAIL ($label)"
  fi
}
_assert_skip() {
  local key="$1" label="$2"
  if [ "$_LAST_KEY" = "$key" ] && [ "$_LAST_OK" = "skip" ]; then
    _pass "$key SKIP (as expected): $label"
  else
    _fail "$key expected ok=skip, got ok=$_LAST_OK detail=$_LAST_DETAIL ($label)"
  fi
}
_assert_detail_contains() {
  local needle="$1" label="$2"
  if printf '%s' "$_LAST_DETAIL" | grep -qF -- "$needle"; then
    _pass "detail contains '$needle' ($label)"
  else
    _fail "detail missing '$needle': $_LAST_DETAIL ($label)"
  fi
}

printf '\n== S1: schema parse + shape-validity ==\n'

S1_DIR="$TEST_ROOT/s1-clean"
_stage_memory "$S1_DIR" >/dev/null
# CI fake-env marker prevents S4/S7 from attempting live op
# (defensive — they should already short-circuit on op_live=0 without
# VADE_BINDIR_OVERRIDE, but setting it removes any host-op dependency).
_run_invariant S1 "$S1_DIR" env VADE_BINDIR_OVERRIDE=/tmp
_assert_ok S1 "clean schema validates"

S1_BAD="$TEST_ROOT/s1-bad"
_stage_memory "$S1_BAD" >/dev/null
# Inject a malformed YAML structure — non-array `credentials`.
sed -i 's/^credentials:/credentials: not-an-array/' "$S1_BAD/operations/secrets/schema.yaml"
_run_invariant S1 "$S1_BAD" env VADE_BINDIR_OVERRIDE=/tmp
_assert_fail S1 "malformed schema fails validation"

printf '\n== S2: every declared env-alias set (non-dormant) ==\n'

S2_DIR="$TEST_ROOT/s2-all-set"
_stage_memory "$S2_DIR" >/dev/null
_run_invariant S2 "$S2_DIR" env \
  VADE_BINDIR_OVERRIDE=/tmp \
  VADE_TEST_GHPAT="ghp_fixturefixturefixturefixturefixturefi" \
  VADE_TEST_MULTI="multi-fixture-value"
_assert_ok S2 "all non-dormant aliases set"
_assert_detail_contains "2/2" "S2 count includes dormant exclusion (test-dormant not counted)"

S2_DIR="$TEST_ROOT/s2-one-unset"
_stage_memory "$S2_DIR" >/dev/null
_run_invariant S2 "$S2_DIR" env \
  VADE_BINDIR_OVERRIDE=/tmp \
  VADE_TEST_GHPAT="ghp_fixturefixturefixturefixturefixturefi"
  # VADE_TEST_MULTI deliberately unset.
_assert_fail S2 "one non-dormant alias missing fails"
_assert_detail_contains "VADE_TEST_MULTI" "S2 names the missing var"

printf '\n== S3: declared mirror exists ==\n'

S3_DIR="$TEST_ROOT/s3-present"
_stage_memory "$S3_DIR" >/dev/null
# Create a settings.json carrying both declared env keys.
cat > "$S3_DIR/settings.json" <<EOF
{
  "env": {
    "VADE_TEST_GHPAT": "ghp_fixturefixturefixturefixturefixturefi",
    "VADE_TEST_MULTI": "multi-fixture-value"
  }
}
EOF
_run_invariant S3 "$S3_DIR" env VADE_BINDIR_OVERRIDE=/tmp
_assert_ok S3 "both mirrors present in settings.json"

S3_DIR="$TEST_ROOT/s3-missing"
_stage_memory "$S3_DIR" >/dev/null
# Settings.json absent — both mirrors should be reported missing.
_run_invariant S3 "$S3_DIR" env VADE_BINDIR_OVERRIDE=/tmp
_assert_fail S3 "missing settings.json fails S3"
_assert_detail_contains "file-absent" "S3 surfaces file-absent"

S3_DIR="$TEST_ROOT/s3-empty-key"
_stage_memory "$S3_DIR" >/dev/null
# Settings.json exists but the key has empty value.
cat > "$S3_DIR/settings.json" <<EOF
{
  "env": {
    "VADE_TEST_GHPAT": "",
    "VADE_TEST_MULTI": "multi-fixture-value"
  }
}
EOF
_run_invariant S3 "$S3_DIR" env VADE_BINDIR_OVERRIDE=/tmp
_assert_fail S3 "empty mirror value fails"
_assert_detail_contains "env-key-absent" "S3 surfaces env-key-absent"

printf '\n== S4: stale empty credential (CI fake-env skip path) ==\n'

S4_DIR="$TEST_ROOT/s4-skip"
_stage_memory "$S4_DIR" >/dev/null
_run_invariant S4 "$S4_DIR" env VADE_BINDIR_OVERRIDE=/tmp
_assert_skip S4 "skips in CI fake-env (no live op)"
_assert_detail_contains "op CLI" "S4 skip detail mentions op CLI"

printf '\n== S5: sanctioned paths carry expected secret shapes ==\n'

# S5 reads literal /root/* paths — in CI these don't exist. Pre-stage
# alternate paths and override via $VADE_RUNTIME_DIR /
# $VADE_COO_MEMORY_DIR so the coo-harness/coo-memory paths resolve to
# our fixtures. The literal /root/* paths fall into the "absent (not
# required on this host)" bucket, which is fine.

S5_DIR="$TEST_ROOT/s5-clean"
_stage_memory "$S5_DIR" >/dev/null
# Stage a coo-harness-shape and a coo-memory-shape directory; only
# the common.sh path needs to carry a secret-shape match per the
# sanctioned-paths list.
mkdir -p "$S5_DIR/coo-harness/scripts/lib"
cat > "$S5_DIR/coo-harness/scripts/lib/common.sh" <<EOF
# Synthetic common.sh that carries one matching secret shape.
# Token below matches the github-classic-pat regex from fixture.
SOME_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
EOF
mkdir -p "$S5_DIR/coo-memory/.claude"
# Token below matches ghp_ + 36 alphanumeric chars (the github-classic-pat regex).
cat > "$S5_DIR/coo-memory/.claude/settings.json" <<EOF
{"env": {"FOO": "ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}
EOF
_run_invariant S5 "$S5_DIR" env \
  VADE_BINDIR_OVERRIDE=/tmp \
  VADE_RUNTIME_DIR="$S5_DIR/coo-harness" \
  VADE_COO_MEMORY_DIR="$S5_DIR/coo-memory"
# We expect "ok" — at least one sanctioned-path file has a regex hit.
# The fixture references $VADE_COO_MEMORY_DIR/operations/secrets/schema.yaml,
# but _run_invariant overrides $VADE_COO_MEMORY_DIR to $S5_DIR/coo-memory
# AFTER staging; re-run S5 with the schema located under the same dir.
# Stage the fixture inside coo-memory subtree as well so the helper finds it.
mkdir -p "$S5_DIR/coo-memory/operations/secrets"
_render_fixture "$S5_DIR/coo-memory/operations/secrets/schema.yaml" "$S5_DIR/coo-memory"
cp "$S5_DIR/operations/secrets/schema.schema.json" "$S5_DIR/coo-memory/operations/secrets/" 2>/dev/null || true
_run_invariant S5 "$S5_DIR" env \
  VADE_BINDIR_OVERRIDE=/tmp \
  VADE_RUNTIME_DIR="$S5_DIR/coo-harness" \
  VADE_COO_MEMORY_DIR="$S5_DIR/coo-memory"
_assert_ok S5 "sanctioned path carries secret shape"

S5_DIR="$TEST_ROOT/s5-empty"
_stage_memory "$S5_DIR" >/dev/null
mkdir -p "$S5_DIR/coo-harness/scripts/lib" "$S5_DIR/coo-memory/operations/secrets"
# common.sh exists but contains NO secret-shape matches.
cat > "$S5_DIR/coo-harness/scripts/lib/common.sh" <<EOF
# Synthetic common.sh that carries no secret-shape matches.
echo "just regular shell code"
EOF
_render_fixture "$S5_DIR/coo-memory/operations/secrets/schema.yaml" "$S5_DIR/coo-memory"
cp "$S5_DIR/operations/secrets/schema.schema.json" "$S5_DIR/coo-memory/operations/secrets/" 2>/dev/null || true
_run_invariant S5 "$S5_DIR" env \
  VADE_BINDIR_OVERRIDE=/tmp \
  VADE_RUNTIME_DIR="$S5_DIR/coo-harness" \
  VADE_COO_MEMORY_DIR="$S5_DIR/coo-memory"
_assert_fail S5 "sanctioned path with no secret-shape match fails"
_assert_detail_contains "common.sh" "S5 surfaces the empty path"

printf '\n== S7: orphan-pattern detection (CI fake-env skip path) ==\n'

S7_DIR="$TEST_ROOT/s7-skip"
_stage_memory "$S7_DIR" >/dev/null
_run_invariant S7 "$S7_DIR" env VADE_BINDIR_OVERRIDE=/tmp
_assert_skip S7 "skips in CI fake-env (no live op)"
_assert_detail_contains "op CLI" "S7 skip detail mentions op CLI"

printf '\n== S8: env-drift classification ==\n'

# Clean env case: only the fixture's declared alias is set; rest map to
# known buckets. The test process inherits PATH/HOME/etc. from the
# parent shell, but the fixture allowlists PATH/HOME/LANG/LC_ALL, so
# they land in declared_allowlist. Unknown vars (e.g. CI-only vars in
# this shell) land in unknown_other unless they prefix-match.
S8_DIR="$TEST_ROOT/s8-clean"
_stage_memory "$S8_DIR" >/dev/null
# Run in a scrubbed env — only known-allowlisted vars + the fixture's
# declared alias. env -i wipes the inherited env to remove the noise
# CI hosts inject (CLAUDE_CODE_*, etc.).
out_s8="$(
  env -i PATH="$PATH" HOME="$HOME" LANG=C LC_ALL=C \
    VADE_TEST_KNOWN=set \
    VADE_TEST_PFX_FOO=bar \
    VADE_TEST_GHPAT="ghp_fixturefixturefixturefixturefixturefi" \
    VADE_TEST_MULTI="multi-fixture-value" \
    VADE_COO_MEMORY_DIR="$S8_DIR" \
    VADE_SECRETS_SNAPSHOT_DIR="$S8_DIR/operations/secrets/env-snapshots" \
    VADE_SECRETS_SNAPSHOT_SKIP=1 \
    VADE_BINDIR_OVERRIDE=/tmp \
    bash -c '
      set -uo pipefail
      RESULTS=()
      _add() { RESULTS+=("$1|$2|$3"); }
      source "'"$HELPER"'"
      s_check_S8
      printf "%s\n" "${RESULTS[@]}"
    '
)"
line="$(printf '%s\n' "$out_s8" | grep -E '^S8\|' | head -1)"
_LAST_KEY="${line%%|*}"; rest="${line#*|}"; _LAST_OK="${rest%%|*}"; _LAST_DETAIL="${rest#*|}"
# Scrubbed env should not produce unknown_secret_shape — only known
# bucket counts.
_assert_ok S8 "scrubbed env classifies cleanly"
_assert_detail_contains "declared_secret=2" "S8 counts the two declared aliases"
_assert_detail_contains "prefix_allowlist=1" "S8 counts the VADE_TEST_PFX_FOO via prefix"
_assert_detail_contains "declared_allowlist=" "S8 counts declared allowlist hits"

# Failure case: inject an unknown env var whose VALUE matches a secret
# shape (the github-classic-pat regex from the fixture).
S8_DIR="$TEST_ROOT/s8-leak"
_stage_memory "$S8_DIR" >/dev/null
out_s8b="$(
  env -i PATH="$PATH" HOME="$HOME" LANG=C LC_ALL=C \
    SOME_UNKNOWN_VAR="ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    VADE_COO_MEMORY_DIR="$S8_DIR" \
    VADE_SECRETS_SNAPSHOT_DIR="$S8_DIR/operations/secrets/env-snapshots" \
    VADE_SECRETS_SNAPSHOT_SKIP=1 \
    VADE_BINDIR_OVERRIDE=/tmp \
    bash -c '
      set -uo pipefail
      RESULTS=()
      _add() { RESULTS+=("$1|$2|$3"); }
      source "'"$HELPER"'"
      s_check_S8
      printf "%s\n" "${RESULTS[@]}"
    '
)"
line="$(printf '%s\n' "$out_s8b" | grep -E '^S8\|' | head -1)"
_LAST_KEY="${line%%|*}"; rest="${line#*|}"; _LAST_OK="${rest%%|*}"; _LAST_DETAIL="${rest#*|}"
_assert_fail S8 "unknown_secret_shape on injected token-shaped value"
_assert_detail_contains "SOME_UNKNOWN_VAR" "S8 names the offending key"

printf '\n== Summary ==\n'
printf 'Total: %d pass, %d fail\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed cases:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
