#!/usr/bin/env bash
# PreToolUse boot-brake guard. Reads Claude Code's PreToolUse JSON on
# stdin, dispatches to boot-brake-guard.py for the validator + decision
# logic.
#
# Why a python sibling: the validator carries content-hashing, HMAC
# verification, YAML manifest parsing, and a five-way state machine.
# That doesn't fit cleanly in bash + jq. The python script is the brain;
# this wrapper is the hook surface.
#
# Always exits 0. On allow, emits nothing. On deny, emits the modern
# hookSpecificOutput shape per https://code.claude.com/docs/en/hooks.md
# with permissionDecision=deny + sanitized permissionDecisionReason.
#
# VADE_BRAKE_ENFORCE controls mode (off|warn|block-on-FAIL|block-strict).
# Default is `warn` for Phase 0 — sessions don't experience refusal
# during the soak period.
#
# Reference: coo-memory#1082 (design), coo-memory#1109 (this commission).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pipe stdin through to the python guard. Capture its stdout (the
# hookSpecificOutput JSON on deny; empty on allow) and forward.
input="$(cat 2>/dev/null || true)"
if [ -z "$input" ]; then
  exit 0
fi

# Python guard handles its own exceptions and fails OPEN if it crashes.
printf '%s' "$input" | python3 "$SCRIPT_DIR/boot-brake-guard.py"
exit 0
