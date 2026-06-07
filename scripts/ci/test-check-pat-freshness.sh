#!/usr/bin/env bash
# test-check-pat-freshness: pin the contract of the canonical PAT-cache
# freshness diagnostic, the COO's first-response when a `gh` write fails
# silently (exit 1, zero bytes stdout, zero bytes stderr). See
# MEMO-2026-05-21-r9rt (superseded by MEMO-2026-05-22-3678), Phase-2
# rewrite per coo-memory#873, and the contract documented in
# coo-memory/CLAUDE.md §"GitHub writes".
#
# The script's contract is:
#
#   OK <sha8>                     exit 0  cache matches 1Password
#   STALE cache=<sha8> op=<sha8>  exit 1  cache drifted; rm + retry
#   OP-UNREACHABLE <reason>       exit 2  could not read 1Password
#   CACHE-MISS                    exit 3  tmpfs cache absent / empty
#
# A subtle drift in any of these surfaces breaks the COO's first-response
# playbook. This suite pins each exit code + exact stdout shape.
#
# Strategy mirrors test-op-coo-wrap.sh: install a mock `op` binary via
# PATH-shadowing, control its behavior with env switches, run the
# script under a fresh XDG_RUNTIME_DIR per case so cache state doesn't
# bleed.
#
# Run: bash scripts/ci/test-check-pat-freshness.sh
# Exit: 0 if all assertions pass, non-zero otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../check-pat-freshness.sh"

[ -x "$SCRIPT" ] || { echo "FAIL: script not executable at $SCRIPT"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Mock op binary controlled by env switches:
#   MOCK_OP_STDOUT   bytes emitted on stdout (default empty)
#   MOCK_OP_EXITCODE exit code (default 0)
mkdir -p "$WORK/bin"
cat > "$WORK/bin/op" <<'EOF'
#!/usr/bin/env bash
if [ -n "${MOCK_OP_STDOUT:-}" ]; then
  printf '%s' "$MOCK_OP_STDOUT"
fi
exit "${MOCK_OP_EXITCODE:-0}"
EOF
chmod 0755 "$WORK/bin/op"

# PATH for the script subprocess. Two variants: one carries the mock op,
# the other strips it for the op-cli-missing case. /usr/bin + /bin gives
# the script everything else it needs (sha256sum, cat, printf).
PATH_WITH_OP="$WORK/bin:/usr/bin:/bin"
PATH_NO_OP="/usr/bin:/bin"

PASS=0
FAIL=0
declare -a FAILURES=()

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1)); printf '  PASS  %s\n' "$name"
  else
    FAIL=$((FAIL+1)); FAILURES+=("$name")
    printf '  FAIL  %s\n' "$name"
    printf '         want: %s\n' "$want"
    printf '         got:  %s\n' "$got"
  fi
}

# sha8 of a string the way the script does it.
sha8() { printf '%s' "$1" | sha256sum | cut -c1-8; }

# Fresh XDG dir per test so cache state doesn't bleed.
fresh_env() {
  XDG_RUNTIME_DIR="$(mktemp -d)"
  export XDG_RUNTIME_DIR
}

# Pre-populate the tmpfs cache slot that gh-coo-wrap._resolve_pat writes.
write_cache() {
  mkdir -p "$XDG_RUNTIME_DIR/coo-gh-pat-cache"
  printf '%s' "$1" > "$XDG_RUNTIME_DIR/coo-gh-pat-cache/MCP"
}

# Unset any host MOCK_* leaking in from the operator's env.
unset MOCK_OP_STDOUT MOCK_OP_EXITCODE

# ---- TEST 1: OK — cache matches 1Password ----
fresh_env
write_cache "pat_value_AAAAAA"
rc=0
out="$(PATH="$PATH_WITH_OP" \
       OP_SERVICE_ACCOUNT_TOKEN="sa-token" \
       MOCK_OP_STDOUT="pat_value_AAAAAA" \
       MOCK_OP_EXITCODE=0 \
       "$SCRIPT" 2>&1)" || rc=$?
expect_sha="$(sha8 "pat_value_AAAAAA")"
assert_eq "OK: stdout" "$out" "OK $expect_sha"
assert_eq "OK: exit 0" "$rc" "0"

# ---- TEST 2: gh-shaped silent failure → STALE diagnosis ----
# Canonical first-response scenario from MEMO-2026-05-21-r9rt: PAT
# rotated externally, in-session cache holds the old value, the next
# `gh` write fails silently. Running this script must correctly
# fingerprint the stale cache so the documented recovery (rm
# $XDG_RUNTIME_DIR/coo-gh-pat-cache/MCP*) follows.
fresh_env
write_cache "stale_value_XXXXXX"
rc=0
out="$(PATH="$PATH_WITH_OP" \
       OP_SERVICE_ACCOUNT_TOKEN="sa-token" \
       MOCK_OP_STDOUT="fresh_value_YYYYYY" \
       MOCK_OP_EXITCODE=0 \
       "$SCRIPT" 2>&1)" || rc=$?
stale_sha="$(sha8 "stale_value_XXXXXX")"
fresh_sha="$(sha8 "fresh_value_YYYYYY")"
assert_eq "STALE: stdout" "$out" "STALE cache=$stale_sha op=$fresh_sha"
assert_eq "STALE: exit 1" "$rc" "1"

# ---- TEST 3: CACHE-MISS — cache file absent (fresh session) ----
fresh_env
rc=0
out="$(PATH="$PATH_WITH_OP" \
       OP_SERVICE_ACCOUNT_TOKEN="sa-token" \
       MOCK_OP_STDOUT="any_value" \
       MOCK_OP_EXITCODE=0 \
       "$SCRIPT" 2>&1)" || rc=$?
assert_eq "CACHE-MISS absent: stdout" "$out" "CACHE-MISS"
assert_eq "CACHE-MISS absent: exit 3" "$rc" "3"

# ---- TEST 4: CACHE-MISS — cache file present but empty ----
# Same operational meaning as absent per the script's docstring.
fresh_env
mkdir -p "$XDG_RUNTIME_DIR/coo-gh-pat-cache"
: > "$XDG_RUNTIME_DIR/coo-gh-pat-cache/MCP"
rc=0
out="$(PATH="$PATH_WITH_OP" \
       OP_SERVICE_ACCOUNT_TOKEN="sa-token" \
       MOCK_OP_STDOUT="any_value" \
       MOCK_OP_EXITCODE=0 \
       "$SCRIPT" 2>&1)" || rc=$?
assert_eq "CACHE-MISS empty: stdout" "$out" "CACHE-MISS"
assert_eq "CACHE-MISS empty: exit 3" "$rc" "3"

# ---- TEST 5: OP-UNREACHABLE — op CLI missing from PATH ----
fresh_env
write_cache "any_value"
rc=0
out="$(PATH="$PATH_NO_OP" \
       OP_SERVICE_ACCOUNT_TOKEN="sa-token" \
       "$SCRIPT" 2>&1)" || rc=$?
assert_eq "OP-UNREACHABLE cli-missing: stdout" "$out" "OP-UNREACHABLE op-cli-missing"
assert_eq "OP-UNREACHABLE cli-missing: exit 2" "$rc" "2"

# ---- TEST 6: OP-UNREACHABLE — OP_SERVICE_ACCOUNT_TOKEN unset ----
fresh_env
write_cache "any_value"
rc=0
out="$(PATH="$PATH_WITH_OP" \
       OP_SERVICE_ACCOUNT_TOKEN="" \
       "$SCRIPT" 2>&1)" || rc=$?
assert_eq "OP-UNREACHABLE sa-token-unset: stdout" "$out" "OP-UNREACHABLE op-service-account-token-unset"
assert_eq "OP-UNREACHABLE sa-token-unset: exit 2" "$rc" "2"

# ---- TEST 7: OP-UNREACHABLE — op read fails (non-zero exit) ----
fresh_env
write_cache "any_value"
rc=0
out="$(PATH="$PATH_WITH_OP" \
       OP_SERVICE_ACCOUNT_TOKEN="sa-token" \
       MOCK_OP_EXITCODE=1 \
       "$SCRIPT" 2>&1)" || rc=$?
assert_eq "OP-UNREACHABLE read-failed: stdout" "$out" "OP-UNREACHABLE op-read-failed"
assert_eq "OP-UNREACHABLE read-failed: exit 2" "$rc" "2"

# ---- TEST 8: OP-UNREACHABLE — op read succeeds but returns empty ----
fresh_env
write_cache "any_value"
rc=0
out="$(PATH="$PATH_WITH_OP" \
       OP_SERVICE_ACCOUNT_TOKEN="sa-token" \
       MOCK_OP_STDOUT="" \
       MOCK_OP_EXITCODE=0 \
       "$SCRIPT" 2>&1)" || rc=$?
assert_eq "OP-UNREACHABLE read-empty: stdout" "$out" "OP-UNREACHABLE op-read-empty"
assert_eq "OP-UNREACHABLE read-empty: exit 2" "$rc" "2"

# ---- Summary ----
echo
echo "----------------------------------------"
echo "check-pat-freshness test summary: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failing tests:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
