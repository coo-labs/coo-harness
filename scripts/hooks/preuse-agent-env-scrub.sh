#!/usr/bin/env bash
# PreToolUse Agent hook: compute which env vars a sub-agent should inherit
# and warn (or block, in enforce mode) when secrets would cross the boundary.
#
# Why: The audit (coo-memory#871) found 7 of 8 sub-agent definitions had full
# parent-env inheritance, forming a leak amplifier: secrets in the parent
# session propagate into sub-agent transcripts without opt-in. This hook
# implements the default-deny posture from SOP §3.6.
#
# Contract: reads Claude Code PreToolUse JSON on stdin:
#   { "tool_input": { "subagent_type": "...", ... } }
# Always exits 0. To block, emits { "decision": "block", "reason": "..." }.
# To allow, emits nothing. Fail-open on any error.
#
# Modes (controlled by VADE_AGENT_ENV_SCRUB env var):
#   warn     (default): log the scrub set to stderr; allow spawn with full
#                       parent env unchanged. Phase 1 — observe without impact.
#   enforce:            (future) compute the allowed set and enforce the
#                       boundary. Currently warns with enforcement intent.
#                       Full enforcement mechanism pending Claude Code SDK
#                       sub-agent env-override support.
#   disabled:           exit 0 immediately, no-op.
#
# Allowed env set = non_secret_env_allowlist ∪ non_secret_env_prefixes matches
#                  ∪ agent frontmatter env_allowlist (if declared).
#
# Reference: coo-memory#871 Track 2, operations/secrets/README.md §3.6,
#            .claude/agents/README.md (frontmatter convention).

set -uo pipefail

# Mode check: disabled → immediate no-op
mode="${VADE_AGENT_ENV_SCRUB:-warn}"
[ "$mode" = "disabled" ] && exit 0

# Fail-open wrapper
_fail_open() {
  local msg="$1"
  printf '[preuse-agent-env-scrub] fail-open: %s\n' "$msg" >&2
  exit 0
}

command -v python3 >/dev/null 2>&1 || _fail_open "python3 not found"
command -v jq >/dev/null 2>&1 || _fail_open "jq not found"

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

subagent_type="$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || true)"
[ -z "$subagent_type" ] && exit 0

SCHEMA_PATH="${VADE_COO_MEMORY_DIR:-/home/user/coo-memory}/operations/secrets/schema.yaml"

# Compute allowed set + scrub set via Python
scrub_result="$(python3 - "$SCHEMA_PATH" "$subagent_type" <<'PY' 2>/dev/null || true
import re, sys, os

schema_path = sys.argv[1]
subagent_type = sys.argv[2]

# ── Load schema ────────────────────────────────────────────────────────────────
allowlist = []
prefixes = []
secret_vars = []

try:
    with open(schema_path) as f:
        content = f.read()

    # Parse non_secret_env_allowlist
    in_allowlist = False
    for line in content.split('\n'):
        stripped = line.lstrip()
        if re.match(r'non_secret_env_allowlist\s*:', stripped):
            in_allowlist = True
            continue
        if in_allowlist:
            m = re.match(r'-\s+([A-Za-z_][A-Za-z0-9_]*)', stripped)
            if m:
                allowlist.append(m.group(1))
            elif stripped and not stripped.startswith('#'):
                in_allowlist = False

    # Parse non_secret_env_prefixes
    in_prefixes = False
    for line in content.split('\n'):
        stripped = line.lstrip()
        if re.match(r'non_secret_env_prefixes\s*:', stripped):
            in_prefixes = True
            continue
        if in_prefixes:
            m = re.match(r'-\s+([A-Za-z_][A-Za-z0-9_]*)', stripped)
            if m:
                prefixes.append(m.group(1))
            elif stripped and not stripped.startswith('#'):
                in_prefixes = False

    # Parse credentials[].env_aliases (secret vars — these must NOT cross)
    in_env_aliases = False
    for line in content.split('\n'):
        stripped = line.lstrip()
        if re.match(r'env_aliases\s*:', stripped):
            in_env_aliases = True
            continue
        if in_env_aliases:
            m = re.match(r'-\s+([A-Za-z_][A-Za-z0-9_]*)', stripped)
            if m:
                secret_vars.append(m.group(1))
            elif stripped and not stripped.startswith('#'):
                in_env_aliases = False

except Exception as e:
    # Fail-open: no schema data loaded; allow spawn unmodified
    print(f"FAIL_OPEN\tschema-load-error: {e}")
    sys.exit(0)

# ── Load agent frontmatter env_allowlist ──────────────────────────────────────
agent_allowlist = []
agent_paths = [
    os.path.join(os.path.dirname(schema_path), '..', '.claude', 'agents', f'{subagent_type}.md'),
    os.path.expanduser(f'~/.claude/agents/{subagent_type}.md'),
]

for ap in agent_paths:
    try:
        with open(os.path.normpath(ap)) as f:
            fm_content = f.read()
        # Parse YAML frontmatter between --- delimiters
        m = re.match(r'^---\s*\n(.*?)\n---', fm_content, re.DOTALL)
        if m:
            fm = m.group(1)
            in_ea = False
            for line in fm.split('\n'):
                stripped = line.lstrip()
                if re.match(r'env_allowlist\s*:', stripped):
                    # Inline list: env_allowlist: [VAR1, VAR2]
                    inline = re.search(r'\[([^\]]+)\]', stripped)
                    if inline:
                        for v in inline.group(1).split(','):
                            v = v.strip().strip('"\'')
                            if v:
                                agent_allowlist.append(v)
                    else:
                        in_ea = True
                    continue
                if in_ea:
                    mv = re.match(r'-\s+([A-Za-z_][A-Za-z0-9_]*)', stripped)
                    if mv:
                        agent_allowlist.append(mv.group(1))
                    elif stripped and not stripped.startswith('#'):
                        in_ea = False
        break
    except FileNotFoundError:
        continue
    except Exception:
        continue  # fail-open on parse errors

# ── Compute scrub set ─────────────────────────────────────────────────────────
# Current env vars
current_env = dict(os.environ)

allowed_explicit = set(allowlist) | set(agent_allowlist)
prefix_set = prefixes

def is_prefix_allowed(k):
    return any(k.startswith(p) for p in prefix_set)

# Classify each current env var
scrub_set = []
for k in sorted(current_env.keys()):
    if k in allowed_explicit:
        continue
    if is_prefix_allowed(k):
        continue
    # Mark as scrub candidate (whether secret or not — default-deny)
    is_secret = k in secret_vars
    scrub_set.append(f"{'SECRET' if is_secret else 'UNKNOWN'}\t{k}")

print(f"ALLOWED_COUNT\t{len(current_env) - len(scrub_set)}")
print(f"SCRUB_COUNT\t{len(scrub_set)}")
print(f"AGENT_ALLOWLIST\t{','.join(agent_allowlist) if agent_allowlist else '(none)'}")
# Emit every SECRET entry unconditionally — the bash side greps these to
# compute secret_count; truncating SECRETs for "log readability" silently
# masks the block-decision and breaks the hook's primary contract. Only
# UNKNOWN entries are capped for log volume.
secret_entries  = [e for e in scrub_set if e.startswith('SECRET\t')]
unknown_entries = [e for e in scrub_set if not e.startswith('SECRET\t')]
for entry in secret_entries:
    print(f"SCRUB\t{entry}")
for entry in unknown_entries[:50]:
    print(f"SCRUB\t{entry}")
if len(unknown_entries) > 50:
    print(f"SCRUB_OVERFLOW\t{len(unknown_entries) - 50} additional vars truncated from log")
PY
)"

# Fail-open if Python produced nothing (unexpected)
if [ -z "$scrub_result" ]; then
  _fail_open "scrub compute produced no output"
fi

# Check for fail-open signal from Python
if printf '%s' "$scrub_result" | grep -q '^FAIL_OPEN'; then
  fail_msg="$(printf '%s' "$scrub_result" | grep '^FAIL_OPEN' | cut -f2)"
  _fail_open "$fail_msg"
fi

# Extract counts for log
allowed_count="$(printf '%s' "$scrub_result" | grep '^ALLOWED_COUNT' | cut -f2 || echo '?')"
scrub_count="$(printf '%s' "$scrub_result" | grep '^SCRUB_COUNT' | cut -f2 || echo '?')"
agent_al="$(printf '%s' "$scrub_result" | grep '^AGENT_ALLOWLIST' | cut -f2 || echo '(none)')"

# Count secrets in scrub set
secret_count="$(printf '%s' "$scrub_result" | grep -c $'^SCRUB\tSECRET\t' || echo '0')"

# Log to stderr (always, for observability)
printf '[preuse-agent-env-scrub] mode=%s agent=%s allowed=%s scrub=%s (secrets=%s) agent_allowlist=%s\n' \
  "$mode" "$subagent_type" "$allowed_count" "$scrub_count" "$secret_count" "$agent_al" >&2

if [ "$secret_count" -gt 0 ] 2>/dev/null; then
  secret_names="$(printf '%s' "$scrub_result" | grep $'^SCRUB\tSECRET\t' | cut -f3 | tr '\n' ' ')"
  printf '[preuse-agent-env-scrub] SECRET vars in scrub set: %s\n' "$secret_names" >&2
fi

# In enforce mode: block if secret vars would cross the boundary
# Note: Claude Code PreToolUse for Agent cannot currently modify the
# sub-agent's env directly. The enforce-mode block prevents the spawn
# entirely if secrets would cross without explicit opt-in, forcing the
# caller to add the var to the agent's frontmatter env_allowlist.
if [ "$mode" = "enforce" ] && [ "${secret_count:-0}" -gt 0 ] 2>/dev/null; then
  secret_list="$(printf '%s' "$scrub_result" | grep $'^SCRUB\tSECRET\t' | cut -f3 | tr '\n' ' ')"
  jq -n --arg agent "$subagent_type" --arg vars "$secret_list" '{
    decision: "block",
    reason: ("[preuse-agent-env-scrub] enforce-mode: agent \"" + $agent + "\" would inherit secret env vars without opt-in: " + $vars + ". To allow specific vars, add `env_allowlist: [VAR_NAME]` to the agent frontmatter at .claude/agents/" + $agent + ".md. See coo-harness/.claude/agents/README.md for the convention.")
  }'
  exit 0
fi

# warn mode (default): log only, allow spawn
exit 0
