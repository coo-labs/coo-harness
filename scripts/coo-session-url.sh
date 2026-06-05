#!/usr/bin/env bash
# coo-session-url: print the Claude Code session URL for the current
# session, derived from CLAUDE_CODE_REMOTE_SESSION_ID (fallback
# CLAUDE_CODE_SESSION_ID). Silent no-op outside Claude Code: empty
# stdout, exit 0.
#
# Used by humans / scripts that need the URL ad-hoc — e.g. inside an
# editor body, a heredoc, or a manual MCP call.
#
# Canonical-call exception: gh-coo-wrap.sh inlines the same derivation
# (search "session URL once" in that file) to avoid a fork+exec on
# every attributable `gh` write. The two sites must stay in sync — any
# change to the sid resolution / cse_ stripping / URL shape here must
# also update gh-coo-wrap.sh, and vice versa. coo-labs/coo-harness#341
# recorded this convention.
#
# Source: issue coo-labs/coo-memory#150; MEMO 2026-04-26-02.

set -eu

sid="${CLAUDE_CODE_REMOTE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
[ -z "$sid" ] && exit 0

# CLAUDE_CODE_*_SESSION_ID is "cse_<id>"; the URL form is
# "session_<id>". Strip the cse_ prefix if present.
printf 'https://claude.ai/code/session_%s\n' "${sid#cse_}"
