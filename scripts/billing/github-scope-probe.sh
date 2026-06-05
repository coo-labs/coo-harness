#!/usr/bin/env bash
# github-scope-probe.sh — verify the Organization administration:Read
# permission added to vade-coo-app per coo-labs/coo-memory MEMO-2026-06-05-nubs
# actually reaches the GitHub billing endpoints. Runs the App-install-token
# path (via gh-coo-wrap.sh's GH_USE_APP_TOKEN=1 mode), not the PAT path
# (vade-coo is non-org-admin per MEMO-2026-05-21-w6qz; PAT is structurally
# blocked regardless of declared scope).
#
# Read-only; emits a markdown probe report to stdout. No side effects.
# Sister script (full usage / cost digest) is the deferred follow-on
# tracked against coo-labs/coo-memory#1025.

set -euo pipefail

ORG="${ORG:-coo-labs}"

probe() {
  local label="$1" method="$2" path="$3"
  local resp http body
  resp=$(GH_USE_APP_TOKEN=1 gh api -i -X "$method" "$path" 2>&1) || true
  http=$(printf '%s' "$resp" | awk '/^HTTP\// {print $2; exit}')
  body=$(printf '%s' "$resp" | awk '/^$/{found=1; next} found' | head -c 400)
  case "$http" in
    200|204)
      printf -- "- **%s** — \`%s %s\` — OK (%s)\n" "$label" "$method" "$path" "$http"
      ;;
    410)
      msg=$(printf '%s' "$body" | jq -r '.message // empty' 2>/dev/null | head -c 100)
      printf -- "- **%s** — \`%s %s\` — DEPRECATED (410, %s)\n" "$label" "$method" "$path" "$msg"
      ;;
    422)
      msg=$(printf '%s' "$body" | jq -r '.message // empty' 2>/dev/null | head -c 100)
      printf -- "- **%s** — \`%s %s\` — OK-shape (422 needs param: %s)\n" "$label" "$method" "$path" "$msg"
      ;;
    *)
      msg=$(printf '%s' "$body" | jq -r '.message // empty' 2>/dev/null | head -c 100)
      printf -- "- **%s** — \`%s %s\` — FAIL (http=%s%s)\n" "$label" "$method" "$path" "$http" "${msg:+, $msg}"
      ;;
  esac
}

printf "# GitHub scope probe (org=%s, App install token route)\n\n" "$ORG"
printf "Generated: %s\n\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf "## Org plan visibility (Organization administration:Read)\n\n"
probe "Org metadata"           GET "orgs/$ORG"
printf "\n## Enhanced billing (canonical surface — MEMO-2026-06-05-nubs)\n\n"
probe "Usage report"           GET "organizations/$ORG/settings/billing/usage"
probe "Budgets"                GET "organizations/$ORG/settings/billing/budgets"
printf "\n## Legacy billing (deprecated; expect 410 redirects to enhanced)\n\n"
probe "Actions billing"        GET "orgs/$ORG/settings/billing/actions"
probe "Packages billing"       GET "orgs/$ORG/settings/billing/packages"
probe "Shared-storage billing" GET "orgs/$ORG/settings/billing/shared-storage"
probe "Adv-Security billing"   GET "orgs/$ORG/settings/billing/advanced-security"
