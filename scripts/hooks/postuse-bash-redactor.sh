#!/usr/bin/env bash
# PostToolUse Bash hook: detect secret-shaped values in tool output and
# warn Claude to treat them as redacted.
#
# Why: After a bash command runs, its stdout/stderr may contain token-shaped
# strings (from grep over settings.json, `op read` output accidentally echoed,
# leak through a sub-process, etc.). PostToolUse hooks cannot modify tool
# output shown to the model, but can inject `additionalContext` that
# instructs Claude to treat any matched values as redacted and not repeat,
# log, or act on them.
#
# Contract: reads Claude Code PostToolUse JSON on stdin:
#   { "tool_input": {"command": "..."},
#     "tool_response": {"stdout": "...", "stderr": "..."} }
# On detection, emits:
#   { "hookSpecificOutput": { "hookEventName": "PostToolUse",
#                             "additionalContext": "..." } }
# Always exits 0. Fail-open on any error (schema unreadable, regex compile
# failure, jq/python missing) — emits nothing and logs to stderr only.
#
# Latency target: p99 < 100ms on 100KB output (Python single-pass scan).
#
# Reference: coo-memory#872, coo-memory#871 Track 2,
#            operations/secrets/README.md §7a (fail-open policy).

set -uo pipefail

# Fail-open wrapper: any error → exit 0 silently (log to stderr only)
_fail_open() {
  local msg="$1"
  printf '[postuse-bash-redactor] fail-open: %s\n' "$msg" >&2
  exit 0
}

# Require jq (used for JSON input parsing)
command -v jq >/dev/null 2>&1 || _fail_open "jq not found"
command -v python3 >/dev/null 2>&1 || _fail_open "python3 not found"

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

# Extract command for quick pre-filter (optional; not all PostToolUse inputs
# include it cleanly in all Claude Code versions)
# Extract stdout + stderr
output_text="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    resp = d.get("tool_response", {})
    if isinstance(resp, dict):
        out = (resp.get("stdout") or "") + "\n" + (resp.get("stderr") or "")
    else:
        out = str(resp)
    print(out)
except Exception as e:
    # Fail-open: print nothing, let outer script handle
    print("", end="")
' 2>/dev/null || true)"

[ -z "$output_text" ] && exit 0

# Load secret_shapes from schema
SCHEMA_PATH="${VADE_COO_MEMORY_DIR:-/home/user/coo-memory}/operations/secrets/schema.yaml"

# Run the redaction scan via Python
# Returns lines of "shape_name\tmatched_value" for each hit
redaction_hits="$(python3 - "$SCHEMA_PATH" "$output_text" <<'PY' 2>/dev/null || true
import re, sys

schema_path = sys.argv[1]
text = sys.argv[2]

# Load secret_shapes from schema YAML
shapes = []
try:
    with open(schema_path) as f:
        content = f.read()
    in_shapes = False
    current_name = None
    for line in content.split('\n'):
        stripped = line.lstrip()
        if re.match(r'secret_shapes\s*:', stripped):
            in_shapes = True
            continue
        if in_shapes:
            if stripped and not stripped.startswith('#') and not stripped.startswith('-') \
                    and not stripped.startswith('name:') and not stripped.startswith('pattern:') \
                    and not stripped.startswith('class:') and not stripped.startswith('false_positive') \
                    and not stripped.startswith('notes:') and not stripped.startswith('|') \
                    and not stripped.startswith('  '):
                m_key = re.match(r'[a-z_][a-z_]*\s*:', stripped)
                if m_key and not line.startswith(' '):
                    in_shapes = False
                    continue
            m_name = re.match(r'-\s+name\s*:\s*(.+)', stripped)
            if m_name:
                current_name = m_name.group(1).strip().strip('"\'')
                continue
            m_pat = re.match(r'pattern\s*:\s*(.+)', stripped)
            if m_pat and current_name:
                pat = m_pat.group(1).strip().strip('"\'')
                if not pat.startswith('TBD:'):
                    try:
                        shapes.append((current_name, re.compile(pat)))
                    except re.error:
                        pass
                current_name = None
except Exception:
    # Fail-open: no shapes loaded, emit nothing
    sys.exit(0)

if not shapes:
    sys.exit(0)

# Scan text for each shape; collect unique (name, value) hits
hits = []
seen = set()
for name, pat in shapes:
    for m in pat.finditer(text):
        val = m.group(0)
        key = (name, val[:16])  # deduplicate by name + first 16 chars
        if key not in seen:
            seen.add(key)
            # Mask the value: show first 4 chars + *** + last 2 chars if long enough
            if len(val) > 8:
                masked = val[:4] + "***" + val[-2:]
            else:
                masked = val[:2] + "***"
            hits.append(f"{name}\t{masked}")

for h in hits:
    print(h)
PY
)"

[ -z "$redaction_hits" ] && exit 0

# Build the additionalContext message listing each detected shape
context_msg="$(python3 - "$redaction_hits" <<'PY' 2>/dev/null || true
import sys
lines = sys.argv[1].strip().split('\n')
if not lines or not lines[0]:
    sys.exit(0)

items = []
for line in lines:
    if '\t' in line:
        name, masked = line.split('\t', 1)
        items.append(f"  - {name}: {masked}...")

if not items:
    sys.exit(0)

msg = "[postuse-bash-redactor] Secret-shaped value(s) detected in command output. " \
      "Treat these as REDACTED — do not repeat, log, include in memos, or act on the raw bytes:\n"
msg += "\n".join(items)
msg += "\n\nIf you need to use one of these values, read it fresh from op:// " \
       "via `op read op://COO/<item>/<field>` and pipe directly into the consumer. " \
       "See operations/secrets/README.md §7a."
print(msg)
PY
)"

[ -z "$context_msg" ] && exit 0

jq -n --arg msg "$context_msg" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $msg
  }
}'
exit 0
