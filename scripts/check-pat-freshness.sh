#!/usr/bin/env bash
# check-pat-freshness: detect whether the gh-coo-wrap PAT cache (tmpfs)
# is current relative to the canonical value in 1Password
# (op://COO/vade-coo-self-2026-04/token per schema.yaml).
#
# Use this as the FIRST response when a `gh` write fails silently:
# exit 1, zero bytes stdout, zero bytes stderr. That signature is the
# canonical fingerprint of a stale-PAT mid-session — see
# MEMO-2026-05-21-r9rt and coo-labs/coo-memory#820.
#
# Phase 2 (coo-memory#873) retired GITHUB_MCP_PAT from process env;
# gh-coo-wrap.sh now caches the resolved PAT in tmpfs at
# $XDG_RUNTIME_DIR/coo-gh-pat-cache/MCP with a 5-minute TTL. This script
# inspects that cache rather than process env (which is structurally
# empty post-Phase-2; see integrity-group-s.sh S2 comment).
#
# Output (single line) one of:
#   OK <sha8>                            — cache matches 1Password
#   STALE cache=<sha8> op=<sha8>         — cache drifted; rm cache + retry gh call
#   CACHE-MISS                           — tmpfs cache absent (fresh session);
#                                          trigger any `gh` call to populate
#   OP-UNREACHABLE <reason>              — could not read 1Password
#
# Exit codes: 0 OK, 1 STALE, 2 OP-UNREACHABLE, 3 CACHE-MISS.
#
# Recovery on STALE: rm "$XDG_RUNTIME_DIR/coo-gh-pat-cache/MCP*" and
# re-run the failed `gh` call. The wrap shim's _resolve_pat MCP path
# will op-read fresh and re-populate.
#
# Recovery on CACHE-MISS: this is the expected first-call state of a
# fresh session. Trigger any `gh` invocation; the cache populates on
# the next _resolve_pat call.
#
# Sources: coo-labs/coo-memory#820, #873 (Phase 2), 2026-06-05 epic
# closeout.

set -eu

# The schema's canonical reference for vade-coo's PAT. Hardcoded here
# rather than re-read from schema.yaml because this script is the
# diagnostic path; a schema-fetch dependency would create a chicken-
# and-egg loop when the schema itself is what we're testing the cache
# against.
OP_REF="op://COO/vade-coo-self-2026-04/token"

# tmpfs cache location used by gh-coo-wrap.sh _resolve_pat MCP branch.
# XDG_RUNTIME_DIR is the cloud-container default; fall back to /tmp
# only if unset (matches the shim's own fallback at gh-coo-wrap.sh:112).
CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}/coo-gh-pat-cache"
CACHE_FILE="$CACHE_DIR/MCP"

if [ ! -f "$CACHE_FILE" ]; then
  printf 'CACHE-MISS\n'
  exit 3
fi

cache_pat=$(cat "$CACHE_FILE" 2>/dev/null || true)
if [ -z "$cache_pat" ]; then
  # Cache file exists but is empty — same operational meaning as miss.
  printf 'CACHE-MISS\n'
  exit 3
fi

cache_sha=$(printf '%s' "$cache_pat" | sha256sum | cut -c1-8)

if ! command -v op >/dev/null 2>&1; then
  printf 'OP-UNREACHABLE op-cli-missing\n'
  exit 2
fi
if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  printf 'OP-UNREACHABLE op-service-account-token-unset\n'
  exit 2
fi

if ! op_pat=$(op read "$OP_REF" 2>/dev/null); then
  printf 'OP-UNREACHABLE op-read-failed\n'
  exit 2
fi
if [ -z "$op_pat" ]; then
  printf 'OP-UNREACHABLE op-read-empty\n'
  exit 2
fi

op_sha=$(printf '%s' "$op_pat" | sha256sum | cut -c1-8)

if [ "$cache_sha" = "$op_sha" ]; then
  printf 'OK %s\n' "$cache_sha"
  exit 0
else
  printf 'STALE cache=%s op=%s\n' "$cache_sha" "$op_sha"
  exit 1
fi
