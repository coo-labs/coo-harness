#!/usr/bin/env bash
# Bash wrapper for transcript-fetch.py. Sources ~/.vade/coo-env so
# R2_TRANSCRIPTS_* and TRANSCRIPTS_AGE_IDENTITY are populated, then
# exec's the Python implementation.
#
# Usage:
#   bash scripts/lib/transcript-fetch.sh <session_id> [--meta <path>]
#   bash scripts/lib/transcript-fetch.sh --cleanup <jsonl_path>
#
# Exit codes propagate from the Python script; unlike the export-side
# wrapper, failures here surface to the caller (the Stage-1
# transcript-analyzer agent decides how to handle a fetch failure).
#
# coo-labs/coo-logs#64 Batch 3.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${HOME}/.vade/coo-env" ]; then
  # shellcheck disable=SC1090,SC1091
  . "${HOME}/.vade/coo-env" 2>/dev/null || true
fi

# Phase 2 (coo-memory#873) retired ~/.vade/coo-env. Resolve required
# secrets at call time via op read — routed through op-coo-wrap
# (coo-harness#443), so 1P SA-token rate-limit between primary and
# OP_SERVICE_ACCOUNT_TOKEN_BACKUP is absorbed transparently. Fetch
# needs R2 (download) + AGE (decrypt).
_resolve_transcript_secrets() {
  command -v op >/dev/null 2>&1 || return 0
  _maybe_set() {
    local var="$1" ref="$2" val
    eval "test -n \"\${$var:-}\"" && return 0
    val="$(op read "$ref" 2>/dev/null)" || return 0
    [ -n "$val" ] && export "$var=$val"
  }
  _maybe_set R2_TRANSCRIPTS_ACCESS_KEY_ID     op://COO/r2-transcripts/access-key-id
  _maybe_set R2_TRANSCRIPTS_SECRET_ACCESS_KEY op://COO/r2-transcripts/secret-access-key
  _maybe_set R2_TRANSCRIPTS_ENDPOINT          op://COO/r2-transcripts/endpoint
  _maybe_set R2_TRANSCRIPTS_BUCKET            op://COO/r2-transcripts/bucket
  _maybe_set TRANSCRIPTS_AGE_IDENTITY         op://COO/transcripts-age-key/credential
}
_resolve_transcript_secrets

exec "$SCRIPT_DIR/transcript-fetch.py" "$@"
