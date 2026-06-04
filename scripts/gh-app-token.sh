#!/usr/bin/env bash
# gh-app-token.sh — mint a GitHub App installation token for vade-coo-app.
#
# Authenticates as the App's *installation*, not as a user — bypasses the
# user-elevation rule (MEMO-2026-05-21-w6qz) that blocks `vade-coo` PAT
# from org-admin endpoints (createIssueType, createIssueField, project
# writes, custom-property admin).
#
# Reads creds from env (preferred) or 1Password fallback. Caches the
# installation token in $VADE_CLOUD_STATE_DIR/gh-app-token-cache.json
# (TTL ~55 min — GitHub mints tokens valid for 1 h).
#
# Usage:
#   gh-app-token.sh                       # print token to stdout
#   gh-app-token.sh --refresh             # ignore cache, mint fresh
#   gh-app-token.sh --jwt                 # print the App JWT (debug)
#
# Env consumed:
#   GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY
#   (populated by fetch_coo_secrets at boot; falls back to op:// reads).
#
# Exit codes: 0 ok | 2 missing creds | 3 mint failure | 4 malformed response

set -euo pipefail

CACHE_FILE="${VADE_CLOUD_STATE_DIR:-$HOME/.vade-cloud-state}/gh-app-token-cache.json"
MIN_TTL_SEC=300

refresh=0
mode=token
for arg in "$@"; do
  case "$arg" in
    --refresh) refresh=1 ;;
    --jwt) mode=jwt ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *)
      echo "gh-app-token: unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

# Cache hit path
if [ "$mode" = token ] && [ "$refresh" -eq 0 ] && [ -f "$CACHE_FILE" ]; then
  now=$(date +%s)
  cached_exp=$(jq -r '.expires_at_unix // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
  if [ "$cached_exp" -gt $((now + MIN_TTL_SEC)) ]; then
    jq -r '.token' "$CACHE_FILE"
    exit 0
  fi
fi

# Fetch creds (env preferred, op:// fallback)
app_id="${GITHUB_APP_ID:-}"
install_id="${GITHUB_APP_INSTALLATION_ID:-}"
private_key="${GITHUB_APP_PRIVATE_KEY:-}"

if [ -z "$app_id" ]; then
  app_id="$(op read 'op://COO/vade-coo-app/app_id' 2>/dev/null || true)"
fi
if [ -z "$install_id" ]; then
  install_id="$(op read 'op://COO/vade-coo-app/installation_id' 2>/dev/null || true)"
fi
# Phase 2 follow-up: check tmpfs cache populated by bootstrap's
# materialize_app_key_cache before falling back to op-read. The cache is
# in-memory tmpfs, written once at boot, container-ephemeral. Avoids 1
# op-read per gh-app-token cache miss (which was previously the only
# op-read in the App-token mint hot path after the installation-token
# cache landed).
if [ -z "$private_key" ]; then
  for cache_path in /dev/shm/coo-app-key-cache/private_key /tmp/coo-app-key-cache/private_key; do
    if [ -r "$cache_path" ]; then
      private_key="$(cat "$cache_path" 2>/dev/null || true)"
      [ -n "$private_key" ] && break
    fi
  done
fi
if [ -z "$private_key" ]; then
  private_key="$(op read 'op://COO/vade-coo-app/private_key' 2>/dev/null || true)"
fi

if [ -z "$app_id" ] || [ -z "$install_id" ] || [ -z "$private_key" ]; then
  echo "gh-app-token: missing creds (app_id=${app_id:+set} install_id=${install_id:+set} private_key=${private_key:+set})" >&2
  exit 2
fi

# Normalize PEM. 1Password text-field paste flattens newlines in PEM-shaped
# multi-line content into spaces; openssl rejects the result. Recover by
# re-wrapping the base64 body at 64 chars between the BEGIN/END markers.
PEM_FILE="$(mktemp)"
trap 'rm -f "$PEM_FILE"' EXIT
python3 - "$private_key" > "$PEM_FILE" <<'PY'
import sys, re
raw = sys.argv[1].rstrip('\n')
m = re.match(r'^(-----BEGIN [^-]+-----)\s*(.+?)\s*(-----END [^-]+-----)\s*$', raw, re.DOTALL)
if not m:
    sys.stderr.write("gh-app-token: PEM pattern mismatch\n")
    sys.exit(2)
header, body, footer = m.groups()
body = re.sub(r'\s+', '', body)
wrapped = '\n'.join(body[i:i+64] for i in range(0, len(body), 64))
sys.stdout.write(f"{header}\n{wrapped}\n{footer}\n")
PY
chmod 600 "$PEM_FILE"

# Build JWT (RS256). iat backdated by 60s for clock-skew tolerance per
# GitHub's own recommendation.
now=$(date +%s)
iat=$((now - 60))
exp=$((now + 540))
header_b64=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
payload_b64=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
unsigned="$header_b64.$payload_b64"
sig_b64=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$PEM_FILE" -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
jwt="$unsigned.$sig_b64"

if [ "$mode" = jwt ]; then
  echo "$jwt"
  exit 0
fi

# Exchange for installation token
response="$(curl -sS -w '\n%{http_code}' -X POST \
  -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/$install_id/access_tokens" 2>&1)"

http_code="$(echo "$response" | tail -1)"
body="$(echo "$response" | sed '$d')"

if [ "$http_code" != "201" ]; then
  echo "gh-app-token: mint failed (HTTP $http_code): $body" >&2
  exit 3
fi

token="$(echo "$body" | jq -r '.token // empty')"
expires_at="$(echo "$body" | jq -r '.expires_at // empty')"

if [ -z "$token" ] || [ -z "$expires_at" ]; then
  echo "gh-app-token: malformed response: $body" >&2
  exit 4
fi

# Cache
mkdir -p "$(dirname "$CACHE_FILE")"
expires_unix="$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('$expires_at'.replace('Z', '+00:00')).timestamp()))")"
jq -n --arg t "$token" --arg ea "$expires_at" --argjson eu "$expires_unix" \
  '{token: $t, expires_at: $ea, expires_at_unix: $eu, minted_at: (now | floor)}' > "$CACHE_FILE"
chmod 600 "$CACHE_FILE"

echo "$token"
