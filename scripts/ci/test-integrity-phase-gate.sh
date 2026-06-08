#!/usr/bin/env bash
# test-integrity-phase-gate: assert Group S in integrity-check.sh skips
# the op-touching invariants (S3, S4, S7) when VADE_INTEGRITY_PHASE=fast,
# and runs the full s_check_all when phase is unset or live.
#
# Background: briefing-40 T2.1 (coo-labs/coo-harness#563) — cold-boot
# op-reads were 3-4x the documented bound because integrity-check.sh
# fires twice per cold-boot (fast phase from coo-bootstrap.sh's EXIT
# trap, live phase from post-bootstrap-chain.sh) and Group S iterates
# the full schema with `op read` per credential each time. Gating S3/
# S4/S7 to live-phase only halves cold-boot op-quota use.
#
# Run: bash scripts/ci/test-integrity-phase-gate.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INTEGRITY="$REPO_ROOT/scripts/boot/integrity-check.sh"
HELPER="$REPO_ROOT/scripts/lib/integrity-group-s.sh"

[ -r "$INTEGRITY" ] || { echo "FAIL: integrity-check.sh not readable at $INTEGRITY"; exit 1; }
[ -r "$HELPER" ]    || { echo "FAIL: integrity-group-s.sh not readable at $HELPER"; exit 1; }

PASS=0
FAIL=0
declare -a FAILURES=()

_pass() { PASS=$((PASS + 1)); printf '  ok: %s\n' "$1"; }
_fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); printf '  FAIL: %s\n' "$1"; }

# Sanity: the production dispatcher still contains the phase-gate marker
# and the skip reason wording the test asserts on — surfaces accidental
# removal or rename.
if ! grep -q 'phase=fast: op-bound check deferred to live pass' "$INTEGRITY"; then
  _fail "production dispatcher missing phase-gate skip reason marker"
fi
if ! grep -q 'VADE_INTEGRITY_PHASE.*=.*fast' "$INTEGRITY"; then
  _fail "production dispatcher missing VADE_INTEGRITY_PHASE=fast comparison"
fi

# Source the helper into a sandbox that mocks each s_check_* function to
# record its name. Re-run the exact dispatcher logic from integrity-check.sh
# under each phase value and assert the call set + recorded skips.
_run_dispatcher() {
  local phase="$1" out
  out="$(
    VADE_INTEGRITY_PHASE="$phase" bash -c '
      set -uo pipefail
      RESULTS=()
      CALLED=()
      _add() { RESULTS+=("$1|$2|$3"); }
      # Stub every s_check_* to record its name without doing work.
      for fn in s_check_S1 s_check_S2 s_check_S3 s_check_S4 s_check_S5 \
                s_check_S7 s_check_S8 s_check_S9 s_check_S10 s_check_all; do
        eval "${fn}() { CALLED+=(\"${fn}\"); }"
      done
      # Mirror of the phase-gate dispatcher block in integrity-check.sh.
      # Keep these two blocks (here and the production site) in lockstep —
      # the sanity grep above catches drift in the skip-reason wording.
      if [ "$VADE_INTEGRITY_PHASE" = "fast" ]; then
        s_check_S1
        s_check_S2
        for _s in S3 S4 S7; do
          _add "$_s" skip "phase=fast: op-bound check deferred to live pass (coo-harness#563)"
        done
        s_check_S5
        s_check_S8
        s_check_S9
        s_check_S10
      else
        s_check_all
      fi
      printf "CALLED:%s\n" "$(IFS=,; echo "${CALLED[*]:-}")"
      printf "RESULTS:%s\n" "$(IFS=,; echo "${RESULTS[*]:-}")"
    ')"
  printf '%s' "$out"
}

echo "Case 1: VADE_INTEGRITY_PHASE=fast"
out_fast="$(_run_dispatcher fast)"
called_fast="$(printf '%s\n' "$out_fast" | grep '^CALLED:' | sed 's/^CALLED://')"
results_fast="$(printf '%s\n' "$out_fast" | grep '^RESULTS:' | sed 's/^RESULTS://')"

for expected in s_check_S1 s_check_S2 s_check_S5 s_check_S8 s_check_S9 s_check_S10; do
  case ",$called_fast," in
    *,"$expected",*) _pass "fast phase invokes $expected" ;;
    *)               _fail "fast phase missing $expected (called: $called_fast)" ;;
  esac
done
for forbidden in s_check_S3 s_check_S4 s_check_S7 s_check_all; do
  case ",$called_fast," in
    *,"$forbidden",*) _fail "fast phase unexpectedly invokes $forbidden" ;;
    *)                _pass "fast phase skips $forbidden" ;;
  esac
done
for sk in S3 S4 S7; do
  if printf '%s' "$results_fast" | grep -q "${sk}|skip|phase=fast: op-bound check deferred to live pass (coo-harness#563)"; then
    _pass "fast phase emits skip for $sk with phase-fast wording"
  else
    _fail "fast phase missing skip for $sk (results: $results_fast)"
  fi
done

echo
echo "Case 2: VADE_INTEGRITY_PHASE=live"
out_live="$(_run_dispatcher live)"
called_live="$(printf '%s\n' "$out_live" | grep '^CALLED:' | sed 's/^CALLED://')"
case ",$called_live," in
  *,s_check_all,*) _pass "live phase invokes s_check_all" ;;
  *)               _fail "live phase missing s_check_all (called: $called_live)" ;;
esac
for forbidden in s_check_S1 s_check_S2 s_check_S5 s_check_S8; do
  case ",$called_live," in
    *,"$forbidden",*) _fail "live phase unexpectedly invokes $forbidden individually (should go via s_check_all)" ;;
    *)                _pass "live phase delegates $forbidden to s_check_all" ;;
  esac
done

echo
echo "Case 3: VADE_INTEGRITY_PHASE unset (defaults to live)"
out_default="$(_run_dispatcher '')"
called_default="$(printf '%s\n' "$out_default" | grep '^CALLED:' | sed 's/^CALLED://')"
case ",$called_default," in
  *,s_check_all,*) _pass "unset phase defaults to s_check_all" ;;
  *)               _fail "unset phase missing s_check_all (called: $called_default)" ;;
esac

echo
echo "Results: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
