#!/usr/bin/env bash
# test-op-coo-wrap-cache: exercise the T3.1 session-scope op-read cache
# in scripts/op-coo-wrap.sh (briefing-40 plan §3, coo-harness#562).
#
# Strategy: stand up a mock op-real binary that echoes a deterministic
# value per (path, scenario) and tracks invocation count via a counter
# file, then drive op-coo-wrap.sh against it through scenarios that
# exercise each cache_decision branch:
#
#   1. cache-miss-new — first read of a path; rc=0, value flows to
#      stdout, cache file is written, invocation count = 1.
#   2. cache-hit — second read of the same path; rc=0, value matches
#      the cached value, mock's counter does NOT advance (op-real never
#      invoked), event carries cache_decision=cache-hit.
#   3. TTL expiry — backdate the cache mtime past COO_OP_CACHE_TTL, read
#      again; op-real is re-invoked, cache file is refreshed, event is
#      cache-miss-new.
#   4. cache-miss-stale-fallback — every token rate-limited AND a stale
#      cache file exists; the cached value is served, event is
#      cache-miss-stale-fallback, exit code is 0 (not the rate-limit rc).
#   5. cache bypass (non-`read` subcommand) — `op whoami` passes through
#      to the real binary; no cache file is created; event carries
#      empty cache_decision.
#   6. COO_OP_CACHE=0 opt-out — read with the env var set; no cache file
#      is created; event carries empty cache_decision.
#
# Run: bash scripts/ci/test-op-coo-wrap-cache.sh
# Exit: 0 if all assertions pass, non-zero otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAP="$REPO_ROOT/scripts/op-coo-wrap.sh"

[ -f "$WRAP" ] || { echo "FAIL: op-coo-wrap.sh not found at $WRAP" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Isolated runtime dir so the cache and L2 jsonl don't touch /dev/shm or
# the operator's $XDG_RUNTIME_DIR.
export XDG_RUNTIME_DIR="$WORK/xdg"
mkdir -p "$XDG_RUNTIME_DIR"

# Mock op-real. Behavior:
#   - SCENARIO=success    → echo "value-for-<path>", rc=0
#   - SCENARIO=rate-limit → echo nothing on stdout, "Too many requests" on stderr, rc=1
#   - SCENARIO=signin     → echo "you are 'tester'", rc=0 (whoami passthrough)
MOCK_OP="$WORK/op-real-mock"
COUNTER="$WORK/mock-counter"
echo 0 > "$COUNTER"
cat > "$MOCK_OP" <<'MOCK_EOF'
#!/usr/bin/env bash
# Track every invocation in the counter so the test can assert the
# wrap shim called us exactly N times (cache hits should NOT advance).
COUNTER="${MOCK_COUNTER:-/tmp/mock-counter}"
cur="$(cat "$COUNTER" 2>/dev/null || echo 0)"
echo $((cur + 1)) > "$COUNTER"

case "${SCENARIO:-success}" in
  rate-limit)
    printf '[ERROR] could not read secret: Too many requests. Your client has been rate-limited.\n' >&2
    exit 1
    ;;
  signin)
    # Treat `whoami` as a special success
    echo "you are 'tester'"
    exit 0
    ;;
  success|*)
    # Echo a value derived from argv (skip "read" itself, use the path).
    for arg in "$@"; do
      case "$arg" in
        op://*) echo "value-for-${arg}"; exit 0 ;;
      esac
    done
    echo "value-for-default"
    exit 0
    ;;
esac
MOCK_EOF
chmod +x "$MOCK_OP"

export COO_OP_REAL="$MOCK_OP"
export MOCK_COUNTER="$COUNTER"

# Set both SA token slots so the cascade has tokens to iterate. They
# don't need to be real values; op-real is mocked.
export OP_SERVICE_ACCOUNT_TOKEN="fake-token-A"
export OP_SERVICE_ACCOUNT_TOKEN_BACKUP="fake-token-B"
export OP_SERVICE_ACCOUNT_TOKEN_BACKUP2="fake-token-C"

# Bootstrap-done marker so phase classification doesn't keep flipping
# to bootstrap and writing extra events.
mkdir -p "$HOME/.vade" 2>/dev/null || true
touch "$HOME/.vade/.coo-bootstrap-done"

# L2 log path is /dev/shm/coo-op-reads-L2.<session>.jsonl — redirect via
# CLAUDE_CODE_SESSION_ID to a session-id under our isolated runtime dir,
# then symlink /dev/shm to it.
SESSION_ID="cache-test-$$"
export CLAUDE_CODE_SESSION_ID="$SESSION_ID"

# We can't easily reroute /dev/shm; instead, sample by reading the path
# the wrap shim writes to. The default path is /dev/shm/coo-op-reads-L2.<sid>.jsonl.
LOG_PATH="/dev/shm/coo-op-reads-L2.${SESSION_ID}.jsonl"
rm -f "$LOG_PATH" 2>/dev/null || true

PASS=0
FAIL=0
declare -a FAILURES=()
_pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
_fail() { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  FAIL  %s\n' "$1"; }

run_op() {
  # Wrap-shim subprocess; bash explicitly to honor shebang on systems
  # where the test bit isn't preserved.
  SCENARIO="${SCENARIO:-success}" bash "$WRAP" "$@"
}

last_event() {
  tail -n 1 "$LOG_PATH" 2>/dev/null
}

# ── Test 1: cache-miss-new ───────────────────────────────────────
printf '\nTest 1: cache-miss-new (first read writes cache)\n'
echo 0 > "$COUNTER"
RC1=0
OUT1="$(SCENARIO=success run_op read op://COO/foo/bar 2>/dev/null)" || RC1=$?

if [ "$RC1" -eq 0 ]; then _pass "rc=0"; else _fail "rc=$RC1 (expected 0)"; fi
if [ "$OUT1" = "value-for-op://COO/foo/bar" ]; then _pass "stdout matches mock value"; else _fail "stdout='$OUT1' (expected 'value-for-op://COO/foo/bar')"; fi
COUNT1="$(cat "$COUNTER")"
if [ "$COUNT1" = "1" ]; then _pass "mock invoked exactly 1 time"; else _fail "mock counter=$COUNT1 (expected 1)"; fi
CACHE_DIR="$XDG_RUNTIME_DIR/coo-op-cache"
N_CACHE_FILES="$(find "$CACHE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)"
if [ "$N_CACHE_FILES" = "1" ]; then _pass "1 cache file written"; else _fail "$N_CACHE_FILES cache files (expected 1)"; fi
EV1="$(last_event)"
if echo "$EV1" | grep -q '"cache_decision":"cache-miss-new"'; then _pass "event: cache_decision=cache-miss-new"; else _fail "event cache_decision wrong: $EV1"; fi

# ── Test 2: cache-hit ────────────────────────────────────────────
printf '\nTest 2: cache-hit (second read of same path skips op-real)\n'
RC2=0
OUT2="$(SCENARIO=success run_op read op://COO/foo/bar 2>/dev/null)" || RC2=$?

if [ "$RC2" -eq 0 ]; then _pass "rc=0"; else _fail "rc=$RC2 (expected 0)"; fi
if [ "$OUT2" = "value-for-op://COO/foo/bar" ]; then _pass "stdout matches cached value"; else _fail "stdout='$OUT2'"; fi
COUNT2="$(cat "$COUNTER")"
if [ "$COUNT2" = "1" ]; then _pass "mock counter still 1 (op-real not invoked)"; else _fail "mock counter=$COUNT2 (expected 1)"; fi
EV2="$(last_event)"
if echo "$EV2" | grep -q '"cache_decision":"cache-hit"'; then _pass "event: cache_decision=cache-hit"; else _fail "event cache_decision wrong: $EV2"; fi

# ── Test 3: TTL expiry → fresh cache-miss-new ────────────────────
printf '\nTest 3: TTL expiry forces re-fetch\n'
# Find the cache file (only one entry) and backdate its mtime past 1hr.
CACHE_FILE="$(find "$CACHE_DIR" -maxdepth 1 -type f | head -1)"
if [ -n "$CACHE_FILE" ] && [ -f "$CACHE_FILE" ]; then
  # Use a deliberately tiny TTL so we don't need to actually wait. Combine
  # with `touch -d` to set mtime two seconds in the past.
  touch -d "2 seconds ago" "$CACHE_FILE"
  _pass "cache mtime backdated"
else
  _fail "no cache file found to backdate"
fi

RC3=0
OUT3="$(COO_OP_CACHE_TTL=1 SCENARIO=success run_op read op://COO/foo/bar 2>/dev/null)" || RC3=$?
if [ "$RC3" -eq 0 ]; then _pass "rc=0"; else _fail "rc=$RC3"; fi
COUNT3="$(cat "$COUNTER")"
if [ "$COUNT3" = "2" ]; then _pass "mock counter advanced to 2 (cache expired → re-fetched)"; else _fail "mock counter=$COUNT3 (expected 2)"; fi
EV3="$(last_event)"
if echo "$EV3" | grep -q '"cache_decision":"cache-miss-new"'; then _pass "event: cache_decision=cache-miss-new on expiry"; else _fail "event cache_decision wrong: $EV3"; fi

# ── Test 4: cache-miss-stale-fallback on all-tokens-rate-limited ─
printf '\nTest 4: stale-fallback when every token rate-limited\n'
# Cache file from Test 3 is still present. Backdate it again so it's
# definitely past the TTL we'll use for this read.
CACHE_FILE="$(find "$CACHE_DIR" -maxdepth 1 -type f | head -1)"
touch -d "2 seconds ago" "$CACHE_FILE"
COUNT_BEFORE="$(cat "$COUNTER")"
RC4=0
OUT4="$(COO_OP_CACHE_TTL=1 SCENARIO=rate-limit run_op read op://COO/foo/bar 2>/dev/null)" || RC4=$?

if [ "$RC4" -eq 0 ]; then _pass "rc=0 (stale cache served, rate-limit absorbed)"; else _fail "rc=$RC4 (expected 0; fall-back to cache should succeed)"; fi
if [ "$OUT4" = "value-for-op://COO/foo/bar" ]; then _pass "stdout = cached stale value"; else _fail "stdout='$OUT4'"; fi
COUNT_AFTER="$(cat "$COUNTER")"
EXPECTED_DELTA=3  # All three tokens cascaded
ACTUAL_DELTA=$((COUNT_AFTER - COUNT_BEFORE))
if [ "$ACTUAL_DELTA" -eq "$EXPECTED_DELTA" ]; then _pass "all 3 tokens probed before fallback (delta=$ACTUAL_DELTA)"; else _fail "token cascade delta=$ACTUAL_DELTA (expected $EXPECTED_DELTA)"; fi
EV4="$(last_event)"
if echo "$EV4" | grep -q '"cache_decision":"cache-miss-stale-fallback"'; then _pass "event: cache_decision=cache-miss-stale-fallback"; else _fail "event cache_decision wrong: $EV4"; fi

# ── Test 5: cache bypass for non-read subcommand ─────────────────
printf '\nTest 5: op whoami passes through, no cache file written\n'
# Clear the cache dir so we can verify nothing new is written.
rm -rf "$CACHE_DIR"
N_BEFORE="$(find "$XDG_RUNTIME_DIR" -name 'coo-op-cache' -maxdepth 1 2>/dev/null | wc -l)"

RC5=0
OUT5="$(SCENARIO=signin run_op whoami 2>/dev/null)" || RC5=$?
if [ "$RC5" -eq 0 ]; then _pass "rc=0"; else _fail "rc=$RC5"; fi
if [ "$OUT5" = "you are 'tester'" ]; then _pass "stdout matches mock whoami output"; else _fail "stdout='$OUT5'"; fi
N_AFTER_FILES="$(find "$XDG_RUNTIME_DIR/coo-op-cache" -maxdepth 1 -type f 2>/dev/null | wc -l)"
if [ "$N_AFTER_FILES" = "0" ]; then _pass "no cache file written for whoami"; else _fail "$N_AFTER_FILES cache files (expected 0)"; fi
EV5="$(last_event)"
if echo "$EV5" | grep -q '"op_subcommand":"whoami"' && echo "$EV5" | grep -q '"cache_decision":""'; then
  _pass "event: op_subcommand=whoami, cache_decision empty (bypass)"
else
  _fail "event shape wrong for whoami: $EV5"
fi

# ── Test 6: COO_OP_CACHE=0 opt-out ───────────────────────────────
printf '\nTest 6: COO_OP_CACHE=0 disables caching even for read\n'
echo 0 > "$COUNTER"
rm -rf "$CACHE_DIR"
RC6=0
OUT6="$(COO_OP_CACHE=0 SCENARIO=success run_op read op://COO/foo/baz 2>/dev/null)" || RC6=$?
if [ "$RC6" -eq 0 ]; then _pass "rc=0"; else _fail "rc=$RC6"; fi
if [ "$OUT6" = "value-for-op://COO/foo/baz" ]; then _pass "stdout matches"; else _fail "stdout='$OUT6'"; fi
N_OPTOUT_FILES="$(find "$XDG_RUNTIME_DIR/coo-op-cache" -maxdepth 1 -type f 2>/dev/null | wc -l)"
if [ "$N_OPTOUT_FILES" = "0" ]; then _pass "no cache file written when COO_OP_CACHE=0"; else _fail "$N_OPTOUT_FILES cache files (expected 0)"; fi
EV6="$(last_event)"
if echo "$EV6" | grep -q '"cache_decision":""'; then _pass "event cache_decision empty under opt-out"; else _fail "event wrong: $EV6"; fi

# ── Summary ──────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
rm -f "$LOG_PATH" 2>/dev/null || true
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
