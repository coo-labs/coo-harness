#!/usr/bin/env bash
# cloudflare-scope-probe.sh — verify the six account-level read scopes
# added to CLOUDFLARE_API_TOKEN per MEMO-2026-06-05-vegp actually work
# against the live Cloudflare API.
#
# Read-only; emits a markdown probe report to stdout. No side effects.
# Sister script (full usage digest) is the deferred follow-on tracked
# against coo-labs/coo-memory#1025.

set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN not set}"
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID not set}"

CF_BASE="https://api.cloudflare.com/client/v4"
H_AUTH=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")
H_CT=(-H "Content-Type: application/json")

probe() {
  local label="$1" method="$2" path="$3"
  local resp http body success
  resp=$(curl -s -w '\n%{http_code}' -X "$method" "${H_AUTH[@]}" "${H_CT[@]}" "$CF_BASE$path")
  http="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  success=$(printf '%s' "$body" | jq -r '.success // empty' 2>/dev/null || echo "")
  if [[ "$http" == "200" && "$success" == "true" ]]; then
    printf -- "- **%s** — \`%s %s\` — OK\n" "$label" "$method" "$path"
  else
    local err
    err=$(printf '%s' "$body" | jq -r '.errors[0].message // empty' 2>/dev/null || echo "")
    printf -- "- **%s** — \`%s %s\` — FAIL (http=%s%s)\n" "$label" "$method" "$path" "$http" "${err:+, $err}"
  fi
}

printf "# Cloudflare scope probe (account_id=%s)\n\n" "$CLOUDFLARE_ACCOUNT_ID"
printf "Generated: %s\n\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf "## New account-level read scopes (MEMO-2026-06-05-vegp)\n\n"
probe "Account Settings"  GET "/accounts/$CLOUDFLARE_ACCOUNT_ID"
probe "Billing profile"   GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/billing/profile"
probe "Billing history"   GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/billing/history"
probe "Workers scripts"   GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts"
probe "R2 buckets"        GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/r2/buckets"
probe "Pages projects"    GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects"
printf "\n## Pre-existing scopes (sanity)\n\n"
probe "Zone list"         GET "/zones"
