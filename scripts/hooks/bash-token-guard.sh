#!/usr/bin/env bash
# PreToolUse Bash hook: refuse bare-echo / bare-printf / cat-EOF of
# token-bearing env vars to stdout/stderr/files; also block raw
# `op item edit` and `gh secret set` outside the rotation skill.
#
# Why: Claude has at least twice leaked PAT bytes via
# `echo $GITHUB_MCP_PAT`-style commands and self-corrected after the
# fact. The discipline lives in CLAUDE.md but was followed
# inconsistently. This hook refuses the class of command outright,
# converting a soft norm into a hard guard.
#
# Contract: reads Claude Code's PreToolUse JSON on stdin,
# `{"tool_input": {"command": "..."}}`. Always exits 0. To block, emits
# `{"decision": "block", "reason": "..."}` on stdout (per Claude Code
# hook contract). To allow, emits nothing.
#
# Pattern:
#   - Variables guarded: schema-driven (credentials[].env_aliases from
#     $VADE_COO_MEMORY_DIR/operations/secrets/schema.yaml). Fallback to
#     hardcoded 5-var list if schema is unreadable (fail-open).
#   - Shape-regex: iterate secret_shapes[].pattern from schema (skip
#     patterns starting with "TBD:"). Match command line + heredoc
#     bodies against each shape pattern.
#   - BLOCK `op item edit` and `gh secret set` unless
#     VADE_SECRETS_SKILL_ACTIVE=1.
#   - BLOCK if a token-var reference appears as the operand of `echo`,
#     `printf`, or in a here-doc body, AND the redirection (or default
#     stdout) is NOT `/dev/null` AND the output is NOT piped into
#     another command.
#   - ALLOW: existence checks (`[ -n "$VAR" ]`, `[ -z "$VAR" ]`),
#     length checks (`${#VAR}`), redirect to /dev/null, pipe into
#     another command.
#
# Reference: coo-harness#165, MEMO-2026-04-22-04 (PAT discipline),
#            coo-memory#871 Track 2 (schema-driven extension).

set -uo pipefail

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
[ -z "$cmd" ] && exit 0

# ── Block op item edit / gh secret set outside the rotation skill ─────────────
# The rotation skill sets VADE_SECRETS_SKILL_ACTIVE=1 for its own writes.
# Direct use of these commands outside the skill bypasses the audit trail.
if [ "${VADE_SECRETS_SKILL_ACTIVE:-}" != "1" ]; then
  case "$cmd" in
    *"op item edit"*|*"op item update"*)
      jq -n '{
        decision: "block",
        reason: "[bash-token-guard] `op item edit` is blocked outside the rotation skill. Use `/rotate-credential` (sets VADE_SECRETS_SKILL_ACTIVE=1) to make sanctioned edits. Direct op-item edits bypass the audit trail. See coo-memory operations/secrets/README.md §3.2."
      }'
      exit 0
      ;;
    *"gh secret set"*)
      jq -n '{
        decision: "block",
        reason: "[bash-token-guard] `gh secret set` is blocked outside the rotation skill. Use `/rotate-credential` (sets VADE_SECRETS_SKILL_ACTIVE=1) to make sanctioned secret writes. See coo-memory operations/secrets/README.md §3.2."
      }'
      exit 0
      ;;
  esac
fi

# ── Build the guarded-var list from schema, with hardcoded fallback ───────────
# Load env_aliases from all credentials in schema.yaml.
# Fallback if schema unreadable: the original 5-var hardcoded list.
SCHEMA_PATH="${VADE_COO_MEMORY_DIR:-/home/user/coo-memory}/operations/secrets/schema.yaml"

# Extract via Python (handles YAML without a yaml module dependency by
# doing a targeted text scan — robust enough for the key=value structure
# of env_aliases lists, which are simple YAML sequences).
_load_schema_vars() {
  python3 - "$SCHEMA_PATH" <<'PY' 2>/dev/null || true
import sys, re

schema_path = sys.argv[1]
try:
    with open(schema_path) as f:
        content = f.read()
except Exception:
    sys.exit(1)

# Parse env_aliases lists from the YAML. The structure is:
#   env_aliases:
#     - VAR_NAME
#     - ...
# We scan for `env_aliases:` blocks and collect the list items.
vars_found = []
in_env_aliases = False
for line in content.split('\n'):
    stripped = line.lstrip()
    indent = len(line) - len(stripped)
    if re.match(r'env_aliases\s*:', stripped):
        in_env_aliases = True
        continue
    if in_env_aliases:
        m = re.match(r'-\s+([A-Za-z_][A-Za-z0-9_]*)', stripped)
        if m:
            vars_found.append(m.group(1))
        elif stripped and not stripped.startswith('#'):
            # Non-list line: end of env_aliases block
            in_env_aliases = False
print('\n'.join(vars_found))
PY
}

_load_schema_shapes() {
  python3 - "$SCHEMA_PATH" <<'PY' 2>/dev/null || true
import sys, re

schema_path = sys.argv[1]
try:
    with open(schema_path) as f:
        content = f.read()
except Exception:
    sys.exit(1)

# Parse secret_shapes list. Structure:
#   secret_shapes:
#     - name: foo
#       pattern: 'regex'
#       ...
# Extract (name, pattern) pairs; skip patterns starting with "TBD:".
shapes = []
in_shapes = False
current_name = None
for line in content.split('\n'):
    stripped = line.lstrip()
    if re.match(r'secret_shapes\s*:', stripped):
        in_shapes = True
        continue
    if in_shapes:
        # Top-level list item (non-secret-shapes section header ends the block)
        # Detect section boundary: a non-indented non-comment non-list line
        if stripped and not stripped.startswith('#') and not stripped.startswith('-') \
                and not stripped.startswith('name:') and not stripped.startswith('pattern:') \
                and not stripped.startswith('class:') and not stripped.startswith('false_positive') \
                and not stripped.startswith('notes:') and not stripped.startswith('|'):
            # Check if it looks like a new top-level key
            m_key = re.match(r'[a-z_][a-z_]*\s*:', stripped)
            if m_key and line[0] != ' ':
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
                shapes.append((current_name, pat))
            current_name = None

for name, pat in shapes:
    print(f'{name}\t{pat}')
PY
}

# Load schema vars; fall back to hardcoded list on failure
schema_vars="$(_load_schema_vars)"
if [ -z "$schema_vars" ]; then
  # Fallback: original hardcoded list (fail-open — schema unreadable)
  schema_vars="GITHUB_MCP_PAT
GITHUB_TOKEN
MEM0_API_KEY
OP_SERVICE_ACCOUNT_TOKEN
AGENTMAIL_API_KEY"
fi

# Build regex from var names
TOKEN_VAR_RE="($(printf '%s' "$schema_vars" | tr '\n' '|' | sed 's/|$//'))"

# Load shape patterns (name TAB pattern lines)
schema_shapes="$(_load_schema_shapes)"

# ── Quick pre-filter ───────────────────────────────────────────────────────────
# If the command doesn't reference any guarded var AND doesn't match any
# secret shape pattern, allow immediately.
var_hit=false
shape_hit=false

if printf '%s' "$cmd" | grep -qE "\\\$\{?${TOKEN_VAR_RE}\b" 2>/dev/null; then
  var_hit=true
fi

# Shape-regex pre-scan (fast path: any match triggers deeper check)
if [ -n "$schema_shapes" ] && [ "$shape_hit" = "false" ]; then
  while IFS=$'\t' read -r shape_name shape_pat; do
    [ -z "$shape_pat" ] && continue
    if printf '%s' "$cmd" | grep -qP "$shape_pat" 2>/dev/null; then
      shape_hit=true
      break
    fi
  done <<< "$schema_shapes"
fi

if [ "$var_hit" = "false" ] && [ "$shape_hit" = "false" ]; then
  exit 0
fi

# ── Step 1: detect here-doc bodies ────────────────────────────────────────────
#   cat <<EOF\n...$VAR...\nEOF
heredoc_check() {
  local c="$1"
  local var_re="$2"
  local shapes_tsv="$3"
  python3 - "$c" "$var_re" "$shapes_tsv" <<'PY' 2>/dev/null || true
import re, sys
cmd = sys.argv[1]
token_re_str = sys.argv[2]
shapes_tsv = sys.argv[3] if len(sys.argv) > 3 else ""

# Build token_re from var names
token_re = re.compile(r'\$\{?(' + token_re_str + r')\b')

# Build shape patterns list
shape_patterns = []
for line in shapes_tsv.strip().split('\n'):
    if '\t' in line:
        name, pat = line.split('\t', 1)
        pat = pat.strip()
        if pat and not pat.startswith('TBD:'):
            try:
                shape_patterns.append((name, re.compile(pat)))
            except re.error:
                pass

# Match here-doc openers; tag may be quoted.
pat = re.compile(r'<<-?\s*[\'"]?([A-Za-z_][A-Za-z0-9_]*)[\'"]?')
lines = cmd.split('\n')
i = 0
while i < len(lines):
    m = pat.search(lines[i])
    if m:
        tag = m.group(1)
        j = i + 1
        body = []
        while j < len(lines):
            stripped = lines[j].lstrip('\t')
            if stripped == tag:
                break
            body.append(lines[j])
            j += 1
        body_text = '\n'.join(body)
        tail = lines[i][m.end():]
        leak = False
        reason = ""
        if token_re.search(body_text):
            leak = True
            reason = "here-doc body emits a guarded token var to stdout/file"
        if not leak:
            for sname, spat in shape_patterns:
                if spat.search(body_text):
                    leak = True
                    reason = f"here-doc body contains a {sname}-shaped secret value"
                    break
        if leak:
            if '/dev/null' in tail or '|' in tail:
                pass  # safe
            else:
                print(reason)
                sys.exit(0)
        i = j + 1
    else:
        i += 1
PY
}

leak_reason=""
heredoc_reason="$(heredoc_check "$cmd" "$TOKEN_VAR_RE" "$schema_shapes")"
if [ -n "$heredoc_reason" ]; then
  leak_reason="$heredoc_reason"
fi

# ── Step 2: detect echo/printf of guarded vars / shape-matching literals ──────
echo_check() {
  local c="$1"
  local var_re="$2"
  local shapes_tsv="$3"
  python3 - "$c" "$var_re" "$shapes_tsv" <<'PY' 2>/dev/null || true
import re, sys
cmd = sys.argv[1]
token_re_str = sys.argv[2]
shapes_tsv = sys.argv[3] if len(sys.argv) > 3 else ""

token_re = re.compile(r'\$\{?(' + token_re_str + r')\b')

shape_patterns = []
for line in shapes_tsv.strip().split('\n'):
    if '\t' in line:
        parts = line.split('\t', 1)
        if len(parts) == 2:
            name, pat = parts
            pat = pat.strip()
            if pat and not pat.startswith('TBD:'):
                try:
                    shape_patterns.append((name, re.compile(pat)))
                except re.error:
                    pass

def strip_heredocs(c):
    pat = re.compile(r'<<-?\s*[\'"]?([A-Za-z_][A-Za-z0-9_]*)[\'"]?')
    lines = c.split('\n')
    out = []
    i = 0
    while i < len(lines):
        m = pat.search(lines[i])
        if m:
            tag = m.group(1)
            out.append(lines[i])
            j = i + 1
            while j < len(lines):
                stripped = lines[j].lstrip('\t')
                if stripped == tag:
                    out.append(lines[j])
                    break
                j += 1
            i = j + 1
        else:
            out.append(lines[i])
            i += 1
    return '\n'.join(out)

cmd = strip_heredocs(cmd)

def split_pipelines(s):
    out = []
    cur = []
    i = 0
    in_s = False
    in_d = False
    while i < len(s):
        ch = s[i]
        nxt = s[i+1] if i+1 < len(s) else ''
        if ch == '\\' and not in_s:
            cur.append(ch)
            if nxt:
                cur.append(nxt)
                i += 2
                continue
        if ch == "'" and not in_d:
            in_s = not in_s
            cur.append(ch); i += 1; continue
        if ch == '"' and not in_s:
            in_d = not in_d
            cur.append(ch); i += 1; continue
        if not in_s and not in_d and ch == '|' and nxt != '|' and (i == 0 or s[i-1] != '|'):
            out.append(''.join(cur))
            cur = []
            i += 1
            continue
        cur.append(ch); i += 1
    out.append(''.join(cur))
    return out

def split_logical(s):
    out = []
    cur = []
    i = 0
    in_s = False
    in_d = False
    while i < len(s):
        ch = s[i]
        nxt = s[i+1] if i+1 < len(s) else ''
        if ch == '\\' and not in_s:
            cur.append(ch)
            if nxt:
                cur.append(nxt)
                i += 2
                continue
        if ch == "'" and not in_d:
            in_s = not in_s
            cur.append(ch); i += 1; continue
        if ch == '"' and not in_s:
            in_d = not in_d
            cur.append(ch); i += 1; continue
        if not in_s and not in_d:
            if ch == '&' and nxt == '&':
                out.append(''.join(cur)); cur = []; i += 2; continue
            if ch == '|' and nxt == '|':
                out.append(''.join(cur)); cur = []; i += 2; continue
            if ch == ';':
                out.append(''.join(cur)); cur = []; i += 1; continue
            if ch == '\n':
                out.append(''.join(cur)); cur = []; i += 1; continue
        cur.append(ch); i += 1
    out.append(''.join(cur))
    return out

def scrub_safe(seg, var_re_str):
    # Build the var alternation for safe-context scrubbing
    seg = re.sub(r'\$\{#(' + var_re_str + r')\}', 'SAFE_LEN', seg)
    seg = re.sub(r'\[\[?\s*-[nz]\s+"?\$\{?(' + var_re_str + r')\}?"?\s*\]?\]?', 'SAFE_TEST', seg)
    seg = re.sub(r'\btest\s+-[nz]\s+"?\$\{?(' + var_re_str + r')\}?"?', 'SAFE_TEST', seg)
    return seg

def has_redirect_to_devnull(seg):
    return re.search(r'(?:^|\s|&)(?:[12]?>>?|&>>?)\s*/dev/null\b', seg) is not None

def echo_printf_leaks_var(seg, var_re, shape_patterns):
    s = seg.lstrip()
    m = re.match(r'(echo|printf)\b(.*)$', s, re.DOTALL)
    if not m:
        return None
    args = m.group(2)
    if var_re.search(args):
        return "bare echo/printf of a guarded token env var to stdout/file"
    for sname, spat in shape_patterns:
        if spat.search(args):
            return f"bare echo/printf of a {sname}-shaped secret value to stdout/file"
    return None

pipelines = split_pipelines(cmd)
n = len(pipelines)
for idx, stage in enumerate(pipelines):
    is_last_stage = (idx == n - 1)
    if not is_last_stage:
        continue
    for seg in split_logical(stage):
        scrubbed = scrub_safe(seg, token_re_str)
        if not token_re.search(scrubbed):
            # Check shape patterns on original (not scrubbed) for literal values
            seg_check = seg
            for sname, spat in shape_patterns:
                if spat.search(seg_check):
                    if not has_redirect_to_devnull(seg_check):
                        lreason = echo_printf_leaks_var(seg_check, token_re, [(sname, spat)])
                        if lreason:
                            print(lreason)
                            sys.exit(0)
            continue
        if has_redirect_to_devnull(scrubbed):
            continue
        lreason = echo_printf_leaks_var(scrubbed, token_re, shape_patterns)
        if lreason:
            print(lreason)
            sys.exit(0)
PY
}

if [ -z "$leak_reason" ]; then
  reason="$(echo_check "$cmd" "$TOKEN_VAR_RE" "$schema_shapes")"
  if [ -n "$reason" ]; then
    leak_reason="$reason"
  fi
fi

if [ -n "$leak_reason" ]; then
  jq -n --arg reason "$leak_reason" '{
    decision: "block",
    reason: ("[bash-token-guard] " + $reason + ". Refusing to print PAT/API-key bytes to a terminal or file. Use: existence check `[ -n \"$VAR\" ] && echo set`, length check `echo \"${#VAR}\"`, or pipe into a consumer like `gh auth login --with-token`. See coo-harness#165, MEMO-2026-04-22-04.")
  }'
  exit 0
fi

exit 0
