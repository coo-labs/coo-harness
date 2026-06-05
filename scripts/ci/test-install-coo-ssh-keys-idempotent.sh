#!/usr/bin/env bash
# test-install-coo-ssh-keys-idempotent: lock in the skip-when-clean
# behavior of install_coo_ssh_keys (coo-harness#473).
#
# When the four COO SSH key files already exist on disk and their
# fingerprints match the expected values, install_coo_ssh_keys should
# not call `op read` at all — the disk content would be identical, and
# every avoided op-read saves wall time + 1P quota.
#
# Strategy: source common.sh, override `op` as a bash function that
# tracks whether it was called. Pre-stage $HOME/.ssh with fixture
# ed25519 keys; set COO_AUTH_FP_EXPECTED / COO_SIGN_FP_EXPECTED to the
# matching values. Run install_coo_ssh_keys and assert op was never
# invoked. Then mutate one expected fingerprint and assert the function
# falls through to the op path.
#
# Run: bash scripts/ci/test-install-coo-ssh-keys-idempotent.sh
# Exit: 0 if all assertions pass, non-zero otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMON="$REPO_ROOT/scripts/lib/common.sh"

[ -f "$COMMON" ] || { echo "FAIL: common.sh not found at $COMMON" >&2; exit 1; }

command -v ssh-keygen >/dev/null 2>&1 || {
  echo "SKIP: ssh-keygen not on PATH; idempotent skip relies on it" >&2
  exit 0
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
mkdir -p "$HOME/.ssh" "$HOME/.vade"
chmod 700 "$HOME/.ssh"

export VADE_RUNTIME_DIR="$REPO_ROOT"
export VADE_COO_MEMORY_DIR="${VADE_COO_MEMORY_DIR:-$REPO_ROOT/../coo-memory}"
export VADE_CLOUD_STATE_DIR="$WORK/cloud-state"
mkdir -p "$VADE_CLOUD_STATE_DIR"

# Generate fixture ed25519 keys; capture their fingerprints as the
# "expected" values for the skip path. Same pattern the bootstrap-
# regression runner uses (scripts/ci/run-bootstrap-regression.sh).
ssh-keygen -t ed25519 -N "" -C "test-auth" -f "$HOME/.ssh/vade-coo-auth"  >/dev/null
ssh-keygen -t ed25519 -N "" -C "test-sign" -f "$HOME/.ssh/vade-coo-sign"  >/dev/null
chmod 0600 "$HOME/.ssh/vade-coo-auth" "$HOME/.ssh/vade-coo-sign"
chmod 0644 "$HOME/.ssh/vade-coo-auth.pub" "$HOME/.ssh/vade-coo-sign.pub"

COO_AUTH_FP_EXPECTED="$(ssh-keygen -lf "$HOME/.ssh/vade-coo-auth.pub" | awk '{print $2}')"
COO_SIGN_FP_EXPECTED="$(ssh-keygen -lf "$HOME/.ssh/vade-coo-sign.pub" | awk '{print $2}')"
export COO_AUTH_FP_EXPECTED COO_SIGN_FP_EXPECTED

# shellcheck disable=SC1090
source "$COMMON"

PASS=0
FAIL=0
declare -a FAILURES=()

_pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
_fail() { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  FAIL  %s\n' "$1"; }

OP_CALL_LOG="$WORK/op-calls.log"
: > "$OP_CALL_LOG"

# Snapshot the on-disk key material at setup so the mock can return
# stable content even after test 3 deletes one of the files. Without
# this, the mock's `cat` would return empty content on the deleted
# file, _op_to_file's empty-content guard would trip, and the test
# would fail for the wrong reason (mock plumbing, not the skip-branch
# fall-through we're checking).
SNAP_AUTH_PRIV="$(cat "$HOME/.ssh/vade-coo-auth")"
SNAP_AUTH_PUB="$(cat "$HOME/.ssh/vade-coo-auth.pub")"
SNAP_SIGN_PRIV="$(cat "$HOME/.ssh/vade-coo-sign")"
SNAP_SIGN_PUB="$(cat "$HOME/.ssh/vade-coo-sign.pub")"
export SNAP_AUTH_PRIV SNAP_AUTH_PUB SNAP_SIGN_PRIV SNAP_SIGN_PUB

# Tracking op stub — records each invocation. The success branch echoes
# the snapshotted content so _op_to_file's empty-content guard doesn't
# trip and the rewritten disk content matches the original fingerprints.
op() {
  printf '%s\n' "$*" >> "$OP_CALL_LOG"
  if [ "${1:-}" = "read" ]; then
    case "${2:-}" in
      "op://COO/vade-coo-ssh-auth/private key") printf '%s' "$SNAP_AUTH_PRIV" ;;
      "op://COO/vade-coo-ssh-auth/public key")  printf '%s' "$SNAP_AUTH_PUB" ;;
      "op://COO/vade-coo-ssh-sign/private key") printf '%s' "$SNAP_SIGN_PRIV" ;;
      "op://COO/vade-coo-ssh-sign/public key")  printf '%s' "$SNAP_SIGN_PUB" ;;
      *) echo "test-mock-op-$2" ;;
    esac
  fi
  return 0
}
export -f op

# ── Test 1: skip path when disk matches expected ─────────────────
printf '\nTest 1: install_coo_ssh_keys skips op-read when fingerprints match\n'
: > "$OP_CALL_LOG"
RC1=0
install_coo_ssh_keys >"$WORK/log1" 2>&1 || RC1=$?

if [ "$RC1" -eq 0 ]; then
  _pass "skip path: rc=0"
else
  _fail "skip path: rc=$RC1 (expected 0). Log: $(cat "$WORK/log1")"
fi

OP_CALLS="$(wc -l < "$OP_CALL_LOG" | tr -d ' ')"
if [ "$OP_CALLS" = "0" ]; then
  _pass "skip path: op never called (0 invocations)"
else
  _fail "skip path: op called $OP_CALLS time(s). Calls: $(cat "$OP_CALL_LOG")"
fi

if grep -qF "skipping op-read" "$WORK/log1"; then
  _pass "skip path: skip-line logged"
else
  _fail "skip path: 'skipping op-read' missing from log"
fi

if [ -f "$HOME/.ssh/allowed_signers" ] \
   && grep -q '^coo@vade-app.dev ' "$HOME/.ssh/allowed_signers"; then
  _pass "skip path: allowed_signers refreshed (derived state still runs)"
else
  _fail "skip path: allowed_signers missing or malformed"
fi

# ── Test 2: refetch when one fingerprint mismatches ──────────────
printf '\nTest 2: install_coo_ssh_keys falls through to op-read on fingerprint mismatch\n'
: > "$OP_CALL_LOG"
# Mutate expected auth fingerprint so disk no longer matches; signing
# stays matching to confirm the AND-of-both-match gate is correct.
COO_AUTH_FP_EXPECTED="SHA256:thisDoesNotMatchAnyOnDiskKeyAtAll0000000000"
export COO_AUTH_FP_EXPECTED

RC2=0
install_coo_ssh_keys >"$WORK/log2" 2>&1 || RC2=$?

# The fetch path overwrites disk with mock content matching the
# original disk fingerprints, so the post-fetch fingerprint check
# rejects them against the (now-different) expected — rc=1 is correct.
# The point of this test is: op WAS called (skip path correctly didn't
# fire), not that the overall function succeeded.
if [ "$RC2" -ne 0 ]; then
  _pass "mismatch path: rc=$RC2 (non-zero — fetch path's fingerprint check rejects mismatched expected)"
else
  _fail "mismatch path: rc=0 (expected non-zero; fingerprint check should reject)"
fi

if grep -qF "refetching" "$WORK/log2"; then
  _pass "mismatch path: 'refetching' line logged"
else
  _fail "mismatch path: 'refetching' line missing"
fi

OP_CALLS2="$(wc -l < "$OP_CALL_LOG" | tr -d ' ')"
if [ "$OP_CALLS2" -ge 4 ]; then
  _pass "mismatch path: op called ≥4 times (one per key file: $OP_CALLS2)"
else
  _fail "mismatch path: op called only $OP_CALLS2 times (expected ≥4)"
fi

# ── Test 3: missing files fall through to op-read ────────────────
printf '\nTest 3: install_coo_ssh_keys falls through when a key file is missing\n'
rm -f "$HOME/.ssh/vade-coo-sign"
: > "$OP_CALL_LOG"
# Restore matching expected fingerprints so the post-fetch check passes
# (mock writes the original-fingerprint content).
COO_AUTH_FP_EXPECTED="$(ssh-keygen -lf "$HOME/.ssh/vade-coo-auth.pub" | awk '{print $2}')"
COO_SIGN_FP_EXPECTED="$(ssh-keygen -lf "$HOME/.ssh/vade-coo-sign.pub" | awk '{print $2}')"
export COO_AUTH_FP_EXPECTED COO_SIGN_FP_EXPECTED

RC3=0
install_coo_ssh_keys >"$WORK/log3" 2>&1 || RC3=$?

if [ "$RC3" -eq 0 ]; then
  _pass "missing-file path: rc=0 (fetch path succeeds, fingerprints match)"
else
  _fail "missing-file path: rc=$RC3 (expected 0). Log: $(cat "$WORK/log3")"
fi

if ! grep -qF "skipping op-read" "$WORK/log3"; then
  _pass "missing-file path: did not take skip branch"
else
  _fail "missing-file path: incorrectly took skip branch despite missing file"
fi

OP_CALLS3="$(wc -l < "$OP_CALL_LOG" | tr -d ' ')"
if [ "$OP_CALLS3" -ge 4 ]; then
  _pass "missing-file path: op called ≥4 times ($OP_CALLS3)"
else
  _fail "missing-file path: op called only $OP_CALLS3 times (expected ≥4)"
fi

# ── Summary ──────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
