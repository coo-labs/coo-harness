#!/usr/bin/env bash
# VADE cloud-session integrity check.
#
# Runs a fixed set of invariants (Groups A-E) against the current
# session and writes a structured JSON report to
# $VADE_CLOUD_STATE_DIR/integrity-check.json. Also prints a one-line
# human-readable summary to stderr so an agent invoking this directly
# sees the result without parsing JSON.
#
# Non-fatal on every path: always exits 0 even when invariants fail.
# This is a probe, not a repair tool.
#
# Invocation modes:
#   1. Automatic at boot — session-start-sync.sh calls it at end.
#   2. On-demand — `bash $VADE_RUNTIME_DIR/scripts/boot/integrity-check.sh`
#   3. CI — tests run it after faking a SessionStart chain; Groups
#      A/B/C gate PR merges, D/E are secret-dependent and skip in CI.
#
# See the VADE integrity protocol memo (paired with this file's PR)
# for the full invariant list and rationale.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

# Belt-and-suspenders: common.sh seeds VADE_CLOUD_STATE_DIR with a cloud-host default;
# session-start-sync.sh now merges it into settings.json so hooks inherit the correct path,
# but if that merge hasn't run yet (e.g., manual invocation before bootstrap), redirect
# when the cloud path is absent and the local path exists. coo-harness#171.
if [ ! -d "$VADE_CLOUD_STATE_DIR" ] && [ -d "$HOME/.vade/local-state" ]; then
  VADE_CLOUD_STATE_DIR="$HOME/.vade/local-state"
fi

OUT_FILE="${VADE_CLOUD_STATE_DIR}/integrity-check.json"

# Phase gate. `fast` skips Group E (live network probes, 30–115 s) so
# the boot-path call from coo-bootstrap's exit trap completes in <1 s.
# `live` (default) runs every group. The post-bootstrap chain re-runs
# in `live` mode in the background to refresh E group results without
# blocking the boot banner. See post-bootstrap-chain.sh.
VADE_INTEGRITY_PHASE="${VADE_INTEGRITY_PHASE:-live}"

# Atomic-write target — write to .tmp, rename into place. Previous
# revisions `rm -f`-then-rewrote the destination directly; any consumer
# reading during the write window (boot-brake-guard.py parses_json,
# digest summary read) saw a partial file. Atomic rename eliminates
# the window without changing semantics for steady-state readers.
mkdir -p "$(dirname "$OUT_FILE")" 2>/dev/null || true

RUNTIME_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Workspace root: parent of vade-runtime. /home/user on cloud,
# $WORKSPACE_ROOT (e.g. ~/GitHub/coo-labs) on local. The cloud-style
# convenience symlinks (CLAUDE.md and .mcp.json) live here on both
# surfaces; deriving from SCRIPT_DIR keeps the invariants portable.
WORKSPACE_ROOT="$(cd "$RUNTIME_DIR/.." && pwd)"

# Array of "key|ok|detail" triples. Flat for shell; node groups by
# key prefix (A1 → A, B1 → B, etc) at write time.
RESULTS=()
_add() {
  local key="$1" ok="$2" detail="${3:-}"
  RESULTS+=("$key|$ok|$detail")
}

# ── Group A: Build-time setup ──────────────────────────────────
A1_receipt="$VADE_SETUP_RECEIPT"
if [ -f "$A1_receipt" ] && node -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' "$A1_receipt" 2>/dev/null; then
  _add A1 true "receipt at $A1_receipt parses"
else
  _add A1 false "receipt missing or unparseable at $A1_receipt"
fi

if [ -f "$VADE_BUILD_LOG" ] && grep -q 'OK cloud-setup: complete\|OK local-setup: complete' "$VADE_BUILD_LOG" 2>/dev/null; then
  _add A2 true "build.log has terminal OK line"
else
  _add A2 false "build.log missing or no terminal OK line at $VADE_BUILD_LOG"
fi

# A3: receipt asserts workspace_mcp_symlinked=true/identity_link_ok=true
# but the link is currently absent OR points at the wrong target → drift.
# A symlink pointing at the wrong place is just as bad as no symlink for
# the receipt's purposes (the receipt's invariant is "the workspace-scope
# overrides land where downstream consumers expect"), so we resolve and
# compare end targets rather than just checking existence. C1/C2 also
# validate the live targets in their own group; A3 specifically gates
# receipt-vs-reality drift between snapshot build and current resume.
A3_detail=""
A3_ok=true
if [ -f "$A1_receipt" ] && check_cmd node; then
  claim_mcp="$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1])); process.stdout.write(String(!!r.workspace_mcp_symlinked))' "$A1_receipt" 2>/dev/null || echo unknown)"
  claim_id="$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1])); process.stdout.write(String(!!r.identity_link_ok))' "$A1_receipt" 2>/dev/null || echo unknown)"
  expected_mcp_target="$(readlink -f "$VADE_RUNTIME_DIR/.mcp.json" 2>/dev/null || true)"
  expected_id_target="$(readlink -f "$VADE_COO_MEMORY_DIR/CLAUDE.md" 2>/dev/null || true)"
  observed_mcp=false; observed_id=false
  if [ -L "$WORKSPACE_ROOT/.mcp.json" ] && [ -n "$expected_mcp_target" ] \
     && [ "$(readlink -f "$WORKSPACE_ROOT/.mcp.json" 2>/dev/null)" = "$expected_mcp_target" ]; then
    observed_mcp=true
  fi
  if [ -L "$WORKSPACE_ROOT/CLAUDE.md" ] && [ -n "$expected_id_target" ] \
     && [ "$(readlink -f "$WORKSPACE_ROOT/CLAUDE.md" 2>/dev/null)" = "$expected_id_target" ]; then
    observed_id=true
  fi
  [ "$claim_mcp" = "$observed_mcp" ] || { A3_ok=false; A3_detail="mcp_link drift: receipt=$claim_mcp observed-correct-target=$observed_mcp; "; }
  [ "$claim_id" = "$observed_id" ] || { A3_ok=false; A3_detail="${A3_detail}identity_link drift: receipt=$claim_id observed-correct-target=$observed_id"; }
  [ "$A3_ok" = true ] && A3_detail="receipt matches observed (resolved) symlink targets"
else
  A3_ok=skip
  A3_detail="receipt or node unavailable"
fi
_add A3 "$A3_ok" "$A3_detail"

# ── Group B: SessionStart hooks executable ────────────────────
# B1: hook self-test — every settings.json hook command path resolves
# to an executable file. Recipe: audits/2026-05-25_file-sprawl-audit/migration-protocol.md §5.2.
B1_settings="$HOME/.claude/settings.json"
B1_ok=skip
B1_detail="settings.json unreadable or jq missing"
if [ -r "$B1_settings" ] && check_cmd jq; then
  B1_missing=""
  B1_checked=0
  while IFS= read -r cmd; do
    path="$(printf '%s' "$cmd" | grep -oE '"[^"]*\$VADE[^"]*"' | head -1 | tr -d '"' \
      | sed -e "s|\$VADE_RUNTIME_DIR|$VADE_RUNTIME_DIR|g" \
            -e "s|\$VADE_COO_MEMORY_DIR|$VADE_COO_MEMORY_DIR|g")"
    [ -z "$path" ] && continue
    B1_checked=$((B1_checked + 1))
    if [ ! -x "$path" ]; then
      B1_missing="${B1_missing}${path}; "
    fi
  done < <(jq -r '.. | objects | .command? // empty' "$B1_settings" 2>/dev/null)
  if [ "$B1_checked" -eq 0 ]; then
    B1_ok=skip
    B1_detail="no \$VADE-prefixed hook command paths in settings.json (pre-PR9 style or non-COO settings)"
  elif [ -z "$B1_missing" ]; then
    B1_ok=true
    B1_detail="$B1_checked hook command path(s) resolve and are executable"
  else
    B1_ok=false
    B1_detail="missing/non-executable: ${B1_missing% }"
  fi
fi
_add B1 "$B1_ok" "$B1_detail"

# B2: legacy .claude/vade-hooks/ indirection absent. settings.json
# references scripts directly; a snapshot that still carries the old
# shim is degraded.
if [ ! -d "$HOME/.claude/vade-hooks" ]; then
  _add B2 true "no legacy vade-hooks/ indirection"
else
  _add B2 false "legacy vade-hooks/ present at $HOME/.claude/vade-hooks"
fi

# B3: hook chain outcomes for the current session in boot.log.
# The prior implementation grepped /tmp/claude-code.log cumulatively,
# which (a) includes pre-fix historical failures forever and (b) over-
# matched 'No such file or directory' from unrelated subsystems (e.g.
# ripgrep probing a missing plugin cache). boot.log is per-hook-run
# structured JSON; scoping to the most recent cse_* session gives a
# current-state signal. Issue coo-harness#41.
B3_ok=skip
B3_detail="boot.log not readable"
if [ -r "$HOME/.vade/boot.log" ]; then
  latest_session="$(grep -oE '"session":"cse_[^"]+' "$HOME/.vade/boot.log" 2>/dev/null | tail -1 | sed 's/^"session":"//')"
  if [ -n "$latest_session" ]; then
    failures="$(grep -F "\"session\":\"${latest_session}\"" "$HOME/.vade/boot.log" 2>/dev/null | grep -c '"ok":false' || true)"
    failures="${failures:-0}"
    if [ "$failures" -gt 0 ]; then
      B3_ok=false
      B3_detail="$failures failing hook entries in current session ($latest_session)"
    else
      B3_ok=true
      B3_detail="no hook failures in current session ($latest_session)"
    fi
  else
    B3_ok=true
    B3_detail="no tagged session in boot.log yet (pre-first-session)"
  fi
fi
_add B3 "$B3_ok" "$B3_detail"

# B4: hooks section hash matches repo
B4_ok=skip
B4_detail="node missing"
if check_cmd node; then
  B4_ok=$(node -e '
    const fs = require("fs"); const [src, dst] = process.argv.slice(1);
    try {
      const s = JSON.parse(fs.readFileSync(src, "utf8"));
      const d = JSON.parse(fs.readFileSync(dst, "utf8"));
      const sh = JSON.stringify(s.hooks || {});
      const dh = JSON.stringify(d.hooks || {});
      process.stdout.write(sh === dh ? "true" : "false");
    } catch { process.stdout.write("skip"); }
  ' "$RUNTIME_DIR/.claude/settings.json" "$HOME/.claude/settings.json" 2>/dev/null || echo skip)
  case "$B4_ok" in
    true)  B4_detail="settings.json hooks section matches repo" ;;
    false) B4_detail="settings.json hooks drift from repo; re-run session-start-sync" ;;
    *)     B4_detail="comparison failed" ;;
  esac
fi
_add B4 "$B4_ok" "$B4_detail"

# B5: diagnostic, not pass/fail
_add B5 info "CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-<unset>} cwd=$(pwd) HOME=$HOME"

# ── Group C: Symlinks & MCP config ────────────────────────────
# Workspace-root convenience symlinks (CLAUDE.md, .mcp.json) live at
# $WORKSPACE_ROOT/CLAUDE.md is the workspace-scope symlink; the target
# is the coo-memory checkout.
if [ -L "$WORKSPACE_ROOT/CLAUDE.md" ] && [ "$(readlink -f "$WORKSPACE_ROOT/CLAUDE.md")" = "$(readlink -f "$VADE_COO_MEMORY_DIR/CLAUDE.md" 2>/dev/null)" ]; then
  _add C1 true "$WORKSPACE_ROOT/CLAUDE.md → coo-memory/CLAUDE.md"
else
  _add C1 false "$WORKSPACE_ROOT/CLAUDE.md symlink missing or wrong target"
fi

if [ -L "$WORKSPACE_ROOT/.mcp.json" ] && [ "$(readlink -f "$WORKSPACE_ROOT/.mcp.json")" = "$(readlink -f "$VADE_RUNTIME_DIR/.mcp.json" 2>/dev/null)" ]; then
  _add C2 true "$WORKSPACE_ROOT/.mcp.json → coo-harness/.mcp.json"
else
  _add C2 false "$WORKSPACE_ROOT/.mcp.json symlink missing or wrong target"
fi

if [ -f "$WORKSPACE_ROOT/.mcp.json" ] && node -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' "$WORKSPACE_ROOT/.mcp.json" 2>/dev/null; then
  _add C3 true "mcp.json parses"
else
  _add C3 false "mcp.json missing or unparseable"
fi

# ── Group D: COO identity & secrets ──────────────────────────
if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  _add D1 true "OP_SERVICE_ACCOUNT_TOKEN set (len=${#OP_SERVICE_ACCOUNT_TOKEN})"
else
  _add D1 false "OP_SERVICE_ACCOUNT_TOKEN unset in session process"
fi

if [ -f "$HOME/.vade/.coo-bootstrap-done" ]; then
  _add D2 true "marker present"
else
  _add D2 false "marker $HOME/.vade/.coo-bootstrap-done missing"
fi

if [ -f "$HOME/.vade/coo-bootstrap.log" ]; then
  tail_line="$(tail -n 1 "$HOME/.vade/coo-bootstrap.log" 2>/dev/null || true)"
  # 'SKIP marker present' is the idempotent-skip terminal written by
  # coo-bootstrap.sh when the marker file exists; it is a healthy
  # resumed-container outcome. Issue coo-harness#41.
  if printf '%s' "$tail_line" | grep -qE 'OK step=complete|OK step=skip-|SKIP marker present'; then
    _add D3 true "coo-bootstrap.log tail: $tail_line"
  else
    _add D3 false "coo-bootstrap.log tail non-terminal: $tail_line"
  fi
else
  _add D3 false "coo-bootstrap.log missing"
fi

# D4: Phase 2 (coo-memory#873): MCP tokens no longer live in settings.json env.
# MCP children receive secrets via `op run --env-file` at spawn time.
# The check now verifies:
#   1. MCP env-template files are present (op run --env-file SOURCE).
#   2. Materialized MCP env files are present at the .mcp.json-pinned path
#      (op run --env-file TARGET). Phase 2 follow-up: pre-materialization at
#      bootstrap eliminates per-spawn op-reads against the 1P account-level
#      rate-limit.
#   3. settings.json env does NOT contain secret keys (Phase 2 scrub).
#   4. VADE_*_DIR vars are in process env (container UI .env-block source).
if check_cmd node && [ -f "$HOME/.claude/settings.json" ]; then
  _MCP_TEMPLATE_DIR="${VADE_RUNTIME_DIR:-/home/user/coo-harness}/scripts/lib/mcp-env-templates"
  _MCP_MATERIALIZED_DIR="/dev/shm/coo-mcp-env"
  D4_missing_templates=""
  for t in mem0.env agentmail.env; do
    [ -f "$_MCP_TEMPLATE_DIR/$t" ] || D4_missing_templates="${D4_missing_templates}${t},"
  done
  D4_missing_templates="${D4_missing_templates%,}"
  D4_missing_materialized=""
  for t in mem0.env agentmail.env; do
    [ -f "$_MCP_MATERIALIZED_DIR/$t" ] || D4_missing_materialized="${D4_missing_materialized}${t},"
  done
  D4_missing_materialized="${D4_missing_materialized%,}"
  D4_stale_secrets="$(node -e '
    const fs = require("fs");
    let c = {};
    try { c = JSON.parse(fs.readFileSync(process.argv[1], "utf8")) || {}; } catch { process.exit(0); }
    const env = c.env || {};
    const secrets = ["GITHUB_MCP_PAT","GITHUB_TOKEN","GITHUB_PUBLIC_PAT",
                     "AGENTMAIL_API_KEY","MEM0_API_KEY",
                     "R2_TRANSCRIPTS_ACCESS_KEY_ID","R2_TRANSCRIPTS_SECRET_ACCESS_KEY",
                     "TRANSCRIPTS_AGE_IDENTITY","CLOUDFLARE_API_TOKEN",
                     "VADE_AUTH_TOKEN","VADE_BEARER_TOKEN","GITHUB_APP_PRIVATE_KEY"];
    process.stdout.write(secrets.filter(k => env[k]).join(","));
  ' "$HOME/.claude/settings.json" 2>/dev/null)"
  D4_missing_dirs=""
  for v in VADE_CLOUD_STATE_DIR VADE_RUNTIME_DIR VADE_COO_MEMORY_DIR; do
    eval "val=\${$v:-}"
    [ -z "$val" ] && D4_missing_dirs="${D4_missing_dirs}${v},"
  done
  D4_missing_dirs="${D4_missing_dirs%,}"
  if [ -z "$D4_missing_templates" ] && [ -z "$D4_missing_materialized" ] && [ -z "$D4_stale_secrets" ] && [ -z "$D4_missing_dirs" ]; then
    _add D4 true "MCP templates + materialized present; settings.json env secret-free; VADE_*_DIR in process env"
  else
    detail=""
    [ -n "$D4_missing_templates" ] && detail="MCP templates missing: $D4_missing_templates"
    [ -n "$D4_missing_materialized" ] && detail="${detail:+$detail; }MCP materialized files missing at $_MCP_MATERIALIZED_DIR: $D4_missing_materialized"
    [ -n "$D4_stale_secrets" ] && detail="${detail:+$detail; }secrets still in settings.json: $D4_stale_secrets"
    [ -n "$D4_missing_dirs" ] && detail="${detail:+$detail; }process env missing: $D4_missing_dirs"
    _add D4 false "$detail"
  fi
else
  _add D4 skip "node or settings.json unavailable"
fi

GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
if [ "$GIT_EMAIL" = "coo@vade-app.dev" ]; then
  _add D5 true "gitconfig user.email=coo@vade-app.dev"
else
  _add D5 false "gitconfig user.email=$GIT_EMAIL (expected coo@vade-app.dev)"
fi

# D5b — local-scope .git/config divergence surface
# D5 covers the global ~/.gitconfig (coo-memory#287, fixed by
# coo-harness#184). Per-repo .git/config can override it silently:
# a clone performed during a poisoned-bootstrap session may stamp
# local user.email at clone time, surviving subsequent global-scope
# corrections (coo-memory#338). This probe scans repos under
# WORKSPACE_ROOT and surfaces local-scope user.email values that
# diverge from coo@vade-app.dev.
#
# Surface-only — does NOT rewrite. Some repos may carry intentional
# per-repo identities (forks, vendored externals); auto-rewrite would
# clobber them. When D5b fires, the operator-side fix is:
#   git -C <path> config --local --unset user.email
#   git -C <path> config --local --unset user.name
D5b_bad=()
for _repo_dir in "$WORKSPACE_ROOT"/*/; do
  _repo_dir="${_repo_dir%/}"
  [ -d "$_repo_dir/.git" ] || continue
  _local_email="$(git -C "$_repo_dir" config --local user.email 2>/dev/null || true)"
  if [ -n "$_local_email" ] && [ "$_local_email" != "coo@vade-app.dev" ]; then
    D5b_bad+=("$(basename "$_repo_dir"):$_local_email")
  fi
done
if [ "${#D5b_bad[@]}" -eq 0 ]; then
  _add D5b true "no local-scope user.email overrides diverge from coo@vade-app.dev"
else
  _add D5b false "local-scope user.email override(s): ${D5b_bad[*]}"
fi

if [ -f "$HOME/.ssh/vade-coo-auth" ] && [ -f "$HOME/.ssh/vade-coo-sign" ]; then
  # Keys present; now check the signing posture is internally consistent.
  # Per MEMO 2026-04-23-04, cloud sessions (harness sets gpg.ssh.program
  # to a code-sign wrapper at /tmp/code-sign that substitutes the signing
  # key) must have commit.gpgsign=false and tag.gpgsign=false; Mac
  # sessions (no wrapper) must have both =true so the registered
  # vade-coo-sign key is actually used.
  D6_commit="$(git config --global commit.gpgsign 2>/dev/null || echo '<unset>')"
  D6_tag="$(git config --global tag.gpgsign 2>/dev/null || echo '<unset>')"
  if [ -x /tmp/code-sign ] || [ -n "${CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE:-}" ]; then
    if [ "$D6_commit" = "false" ] && [ "$D6_tag" = "false" ]; then
      _add D6 true "keys+signing-off (cloud, per MEMO 2026-04-23-04)"
    else
      _add D6 false "cloud harness detected but commit.gpgsign=$D6_commit tag.gpgsign=$D6_tag (expect false/false; MEMO 2026-04-23-04)"
    fi
  else
    if [ "$D6_commit" = "true" ] && [ "$D6_tag" = "true" ]; then
      _add D6 true "keys+signing-on (local, vade-coo-sign)"
    else
      _add D6 false "no harness but commit.gpgsign=$D6_commit tag.gpgsign=$D6_tag (expect true/true)"
    fi
  fi
else
  _add D6 false "vade-coo-{auth,sign} keys missing in $HOME/.ssh"
fi

# D7 — op-read failure surface (coo-harness#451)
# Counts events in ~/.vade/op-read-failures.jsonl over a rolling window.
# Each event is one _op_to_file call that either failed outright or took
# >1s wall time (i.e., burned at least one retry). The metric for #451's
# success criterion ("zero retries over 7-day window") rolls up from
# this file across the cloud-session fleet.
#
# Probe is `true` when:
#   - no events in window (clean), or
#   - events present but rc=0 across the board (slow but recoverable);
#     surfaced as a non-blocking detail so operators can see the cost, or
#   - events with rc!=0 present BUT the last recorded bootstrap line
#     in ~/.vade/coo-bootstrap.log is `OK step=complete` — the retry
#     path absorbed the failure and bootstrap completed cleanly. That
#     is recoverable noise, not a degraded boot. Surfaced as detail so
#     operators can still see the cost.
# Probe is `false` when rc!=0 events are present AND the last bootstrap
# line is not `OK step=complete` — that's an install_coo_ssh_keys-class
# FAIL that wasn't (yet) recovered, and the boot is actually degraded.
D7_log="${HOME}/.vade/op-read-failures.jsonl"
D7_boot_log="${HOME}/.vade/coo-bootstrap.log"
D7_window_h="${VADE_D7_WINDOW_H:-24}"
if [ -f "$D7_log" ] && check_cmd python3; then
  D7_summary="$(python3 -c "
import json, datetime
window_h = ${D7_window_h}
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=window_h)
total = 0; fails = 0; total_ms = 0
try:
    with open('$D7_log') as f:
        for line in f:
            try: ev = json.loads(line)
            except Exception: continue
            try: t = datetime.datetime.strptime(ev.get('ts',''),'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
            except Exception: continue
            if t < cutoff: continue
            total += 1
            if ev.get('rc') != 0: fails += 1
            try: total_ms += int(ev.get('elapsed_ms',0) or 0)
            except Exception: pass
except Exception: pass
recovered = 0
try:
    last = ''
    with open('$D7_boot_log') as f:
        for line in f:
            if line.strip():
                last = line.strip()
    if 'OK step=complete' in last:
        recovered = 1
except Exception: pass
print(f'{total}|{fails}|{total_ms}|{recovered}')
" 2>/dev/null || echo "0|0|0|0")"
  D7_total="${D7_summary%%|*}"
  _D7_rest="${D7_summary#*|}"
  D7_fails="${_D7_rest%%|*}"
  _D7_rest="${_D7_rest#*|}"
  D7_ms="${_D7_rest%%|*}"
  D7_recovered="${_D7_rest#*|}"
  if [ "$D7_total" = "0" ]; then
    _add D7 true "no op-read events in last ${D7_window_h}h"
  elif [ "$D7_fails" = "0" ]; then
    _add D7 true "${D7_total} slow op-read event(s) in last ${D7_window_h}h, 0 failed (${D7_ms}ms cumulative); see $D7_log"
  elif [ "$D7_recovered" = "1" ]; then
    _add D7 true "${D7_fails}/${D7_total} op-read event(s) failed in last ${D7_window_h}h but bootstrap recovered (${D7_ms}ms cumulative wall-time cost); see $D7_log"
  else
    _add D7 false "${D7_fails}/${D7_total} op-read event(s) failed in last ${D7_window_h}h, bootstrap did not recover (${D7_ms}ms cumulative wall-time cost); see $D7_log"
  fi
else
  _add D7 true "no op-read-failures.jsonl (clean steady state)"
fi

# ── Group E: MCP surface ─────────────────────────────────────
# Phase gate. `fast` (the boot-path call from coo-bootstrap's exit
# trap) marks E1–E9 as `pending` and skips the live probes entirely,
# so bootstrap finishes in <1 s. The post-bootstrap chain re-runs in
# the default `live` phase to refresh E group results in the
# background after the boot banner has rendered.
if [ "$VADE_INTEGRITY_PHASE" = "fast" ]; then
  for _e in E1 E2 E3 E4 E5 E6 E7 E8 E9; do
    _add "$_e" skip "phase=fast: live MCP probes deferred; refreshed by post-bootstrap-chain live pass"
  done
fi

if [ "$VADE_INTEGRITY_PHASE" != "fast" ]; then
# Requires MCP tool calls (get_me on github and github-coo namespaces).
# An agent invoking this directly should fill E1/E2/E3/E4 into the
# JSON afterwards. CI skips E1-E4 entirely. E5 is a script-level probe
# that doesn't require an agent — it spawns the stdio Mem0 MCP and
# confirms the JSON-RPC handshake.
_add E1 skip "requires-agent: call mcp__github__get_me (note: harness github MCP writes deny-listed in #112; reads only)"
_add E2 skip "github-coo MCP retired by Epic #112 Stream 1; vade-coo identity check is now \`gh auth status\` via Bash"
_add E3 skip "requires-agent: inspect mcp-needs-auth-cache.json"
_add E4 skip "requires-agent: observe tool namespaces"

# E5: stdio Mem0 MCP server is installed, answers initialize, AND
# completes a real tool round-trip against api.mem0.ai. The hosted
# https://mcp.mem0.ai endpoint hits a Node `undici` DNS-cache overflow
# inside Claude Code's MCP HTTP transport on cloud-harness boots
# (coo-harness#36/#109), leaving the agent with no Mem0 surface for
# the rest of the session. We bypass that by running the official
# stdio MCP server (`mem0-mcp-server`, pinned via common.sh) as a
# subprocess.
#
# This probe layers two checks (per coo-harness#114):
#   1. Transport — the binary spawns and answers initialize +
#      tools/list with the read/write tool surface we depend on.
#      Fast failure mode: missing binary, no MEM0_API_KEY, JSON-RPC
#      timeout, missing tool names.
#   2. API reachability — a real tools/call get_memories round-trip
#      that exercises api.mem0.ai. Without this, an
#      api.mem0.ai 503 ("DNS cache overflow") leaves initialize
#      passing while every actual tool call errors with
#      "Expecting value: line 1 column 1 (char 0)" — a misleading
#      green that defeats the point of `summary.ok`.
#
# Verdict ordering: handshake failure > round-trip failure > ok. The
# coo-identity-digest banner highlights any E* failure in the
# degraded block, so a degraded Mem0 surface is loud at SessionStart.
#
# Skip on CI (bootstrap-regression runs in fake-env mode against a
# mock workspace; live MCP probes can't validate there) and when the
# binary truly cannot be tested (no MEM0_API_KEY in env — the server
# won't accept initialize without auth). Live-only invariant; not part
# of the bootstrap-regression Layer-1 gate.
E5_ok=skip
E5_detail="requires mem0-mcp-server binary + MEM0_API_KEY"
_mem0_bin=""
for _candidate in "/home/user/.local/bin/mem0-mcp-server" "$HOME/.local/bin/mem0-mcp-server" "${VADE_BINDIR_OVERRIDE:-}/mem0-mcp-server"; do
  if [ -n "$_candidate" ] && [ -x "$_candidate" ]; then
    _mem0_bin="$_candidate"
    break
  fi
done

if [ -n "${VADE_CI_WORKSPACE_ROOT:-}" ] || [ -n "${VADE_BINDIR_OVERRIDE:-}" ]; then
  # CI mode: bootstrap-regression stages a fake-env workspace and the
  # live MCP install path is intentionally not exercised (would mean
  # a 50-package uv install on every PR run for a probe that can't
  # validate against the real api.mem0.ai anyway). Same shape as
  # E1-E4 above; skip cleanly.
  E5_ok=skip
  E5_detail="skipped in CI fake-env (VADE_CI_WORKSPACE_ROOT or VADE_BINDIR_OVERRIDE set); live-only probe"
elif [ -z "$_mem0_bin" ]; then
  E5_ok=false
  E5_detail="mem0-mcp-server binary missing; run ensure_mem0_mcp_server (cloud-setup.sh installs at build; session-start-sync.sh retries on resume)"
elif [ -z "${MEM0_API_KEY:-}" ]; then
  # Binary present but no key in process env. Phase 2 (coo-memory#873):
  # MEM0_API_KEY is no longer in settings.json env. It is exported
  # in-process by bootstrap (available to hook subprocesses) and resolved
  # at MCP spawn time via `op run --env-file mcp-env-templates/mem0.env`.
  # If it's absent here, bootstrap hasn't run yet or failed. Treat as
  # skip rather than fail to avoid false negatives in hook sub-processes.
  E5_ok=skip
  E5_detail="mem0-mcp-server present at $_mem0_bin; MEM0_API_KEY not in hook env (bootstrap may not have completed; op run --env-file resolves at MCP spawn)"
elif ! check_cmd timeout || ! check_cmd node; then
  E5_ok=skip
  E5_detail="timeout or node missing; cannot probe"
else
  # Send initialize + initialized notification + tools/list +
  # tools/call get_memories, then read responses with a budgeted
  # timeout. The server emits one JSON-RPC line per response on
  # stdout. Success criteria:
  #   id=1 → result.serverInfo.name == "mem0"
  #   id=2 → result.tools contains get_memories + search_memories + add_memory
  #   id=3 → result returned without isError; round-trip to api.mem0.ai ok
  # Cheap filter: user_id="coo" with page_size=1 — tiny namespace,
  # one record, one network round-trip.
  E5_probe_out="$(
    {
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"integrity-check","version":"1.0"}}}'
      sleep 0.2
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
      sleep 0.1
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
      sleep 0.5
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_memories","arguments":{"filters":{"AND":[{"user_id":"coo"}]},"page":1,"page_size":1}}}'
      sleep 3
    } | MEM0_API_KEY="$MEM0_API_KEY" timeout 10 "$_mem0_bin" 2>/dev/null \
      | head -4
  )"
  E5_verdict="$(printf '%s' "$E5_probe_out" | node -e '
    let data = "";
    process.stdin.on("data", c => data += c);
    process.stdin.on("end", () => {
      const lines = data.split("\n").filter(Boolean);
      let serverName = null;
      let toolNames = [];
      let roundTripOk = false;
      let roundTripError = null;
      for (const l of lines) {
        try {
          const m = JSON.parse(l);
          if (m.id === 1 && m.result?.serverInfo?.name) serverName = m.result.serverInfo.name;
          if (m.id === 2 && Array.isArray(m.result?.tools)) toolNames = m.result.tools.map(t => t.name);
          if (m.id === 3) {
            if (m.error) {
              roundTripError = (m.error.message || JSON.stringify(m.error)).slice(0, 160);
            } else if (m.result?.isError) {
              const txt = m.result.content?.[0]?.text || JSON.stringify(m.result.content || m.result);
              roundTripError = ("isError: " + txt).slice(0, 160);
            } else if (m.result) {
              roundTripOk = true;
            }
          }
        } catch {}
      }
      const required = ["get_memories", "search_memories", "add_memory"];
      const missing = required.filter(n => !toolNames.includes(n));
      const handshakeOk = serverName === "mem0" && missing.length === 0;
      const out = {
        serverName,
        toolCount: toolNames.length,
        missing,
        handshakeOk,
        roundTripOk,
        roundTripError,
        ok: handshakeOk && roundTripOk,
      };
      process.stdout.write(JSON.stringify(out));
    });
  ' 2>/dev/null)"

  if [ -n "$E5_verdict" ] && printf '%s' "$E5_verdict" | grep -q '"ok":true'; then
    E5_ok=true
    E5_tools="$(printf '%s' "$E5_verdict" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const o=JSON.parse(d);process.stdout.write(o.toolCount+"")}catch{process.stdout.write("?")}})' 2>/dev/null || echo "?")"
    E5_detail="stdio Mem0 MCP healthy: $_mem0_bin (handshake ok, $E5_tools tools, get_memories round-trip ok)"
  else
    E5_ok=false
    if [ -z "$E5_probe_out" ]; then
      E5_detail="$_mem0_bin spawned but produced no JSON-RPC output in 10s; check MEM0_API_KEY validity, network egress to api.mem0.ai (curl https://api.mem0.ai/v1/ping/), and stderr"
    elif [ -z "$E5_verdict" ]; then
      E5_detail="$_mem0_bin probe parser produced no verdict; raw: $(printf '%s' "$E5_probe_out" | head -c 240)"
    elif printf '%s' "$E5_verdict" | grep -q '"handshakeOk":false'; then
      E5_detail="$_mem0_bin handshake failed: $(printf '%s' "$E5_verdict" | head -c 240)"
    else
      # Handshake passed but round-trip failed: api.mem0.ai is degraded
      # while the local MCP transport is up. This is the misleading-green
      # case from coo-harness#114; surface it explicitly.
      _e5_rt_err="$(printf '%s' "$E5_verdict" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const o=JSON.parse(d);process.stdout.write(o.roundTripError||"(no error string)")}catch{process.stdout.write("(verdict parse failed)")}})' 2>/dev/null || echo "(node parse failed)")"
      E5_detail="api.mem0.ai unreachable: handshake ok but get_memories round-trip failed — $_e5_rt_err. Probe: curl https://api.mem0.ai/v1/ping/ ; if 503/DNS-cache-overflow, defer Mem0 writes (memo-sync, identity loads) until upstream recovers."
    fi
  fi

  # E5 retry: one attempt after a 2s delay on transient failures.
  # Addresses boot-time false alarms when api.mem0.ai or the MCP server
  # hasn't finished initialising by the time the probe first fires.
  if [ "$E5_ok" = false ]; then
    sleep 2
    E5_probe_out="$(
      {
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"integrity-check","version":"1.0"}}}'
        sleep 0.2
        printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
        sleep 0.1
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
        sleep 0.5
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_memories","arguments":{"filters":{"AND":[{"user_id":"coo"}]},"page":1,"page_size":1}}}'
        sleep 3
      } | MEM0_API_KEY="$MEM0_API_KEY" timeout 10 "$_mem0_bin" 2>/dev/null \
        | head -4
    )"
    E5_verdict="$(printf '%s' "$E5_probe_out" | node -e '
      let data = "";
      process.stdin.on("data", c => data += c);
      process.stdin.on("end", () => {
        const lines = data.split("\n").filter(Boolean);
        let serverName = null;
        let toolNames = [];
        let roundTripOk = false;
        let roundTripError = null;
        for (const l of lines) {
          try {
            const m = JSON.parse(l);
            if (m.id === 1 && m.result?.serverInfo?.name) serverName = m.result.serverInfo.name;
            if (m.id === 2 && Array.isArray(m.result?.tools)) toolNames = m.result.tools.map(t => t.name);
            if (m.id === 3) {
              if (m.error) {
                roundTripError = (m.error.message || JSON.stringify(m.error)).slice(0, 160);
              } else if (m.result?.isError) {
                const txt = m.result.content?.[0]?.text || JSON.stringify(m.result.content || m.result);
                roundTripError = ("isError: " + txt).slice(0, 160);
              } else if (m.result) {
                roundTripOk = true;
              }
            }
          } catch {}
        }
        const required = ["get_memories", "search_memories", "add_memory"];
        const missing = required.filter(n => !toolNames.includes(n));
        const handshakeOk = serverName === "mem0" && missing.length === 0;
        const out = {
          serverName,
          toolCount: toolNames.length,
          missing,
          handshakeOk,
          roundTripOk,
          roundTripError,
          ok: handshakeOk && roundTripOk,
        };
        process.stdout.write(JSON.stringify(out));
      });
    ' 2>/dev/null)"
    if [ -n "$E5_verdict" ] && printf '%s' "$E5_verdict" | grep -q '"ok":true'; then
      E5_ok=true
      E5_tools="$(printf '%s' "$E5_verdict" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const o=JSON.parse(d);process.stdout.write(o.toolCount+"")}catch{process.stdout.write("?")}})' 2>/dev/null || echo "?")"
      E5_detail="stdio Mem0 MCP healthy: $_mem0_bin (handshake ok, $E5_tools tools, get_memories round-trip ok)"
    fi
    # If still failing after retry, keep the detail from the first attempt
    # (it has the specific error message) and let it fall through to _add.
  fi
fi
_add E5 "$E5_ok" "$E5_detail"

# E6: R2 transcript-absence alarm (coo-harness#201, MEMO-2026-05-04-mzeq).
# Counts *.jsonl under ~/.claude/projects in the last VADE_E6_WINDOW_H
# hours (default 24); if > 0 and R2 has zero objects in the matching
# date prefixes, alarms. Catches total-loss-of-export — the failure
# mode of coo-harness#181 (agent-teams SIGKILL, 48h outage 04-29→04-30)
# and #198 (recurrence). Sibling to E7 (#209, SHA mismatch) and E8
# (#217, orphan meta); jointly cover loss / corruption / partial.
#
# Per MEMO-2026-05-04-mzeq principle 2, "closed" requires both a fix
# AND a continuous detector. E6 covers the absence axis.
#
# Cost: rglob over ~/.claude/projects (cheap; bounded by session
# count) + 2 R2 LISTs per boot. Skips when R2 creds missing, uv
# missing, timeout missing, or CI fake-env active. Live-only invariant.
#
# Tunable via env: VADE_E6_WINDOW_H (default 24),
# VADE_E6_PROJECTS_DIR (default ~/.claude/projects).
E6_ok=skip
E6_detail="prerequisites missing"
E6_WINDOW_H="${VADE_E6_WINDOW_H:-24}"
E6_PROJECTS_DIR="${VADE_E6_PROJECTS_DIR:-$HOME/.claude/projects}"
if [ -n "${VADE_CI_WORKSPACE_ROOT:-}" ] || [ -n "${VADE_BINDIR_OVERRIDE:-}" ]; then
  E6_ok=skip
  E6_detail="skipped in CI fake-env (VADE_CI_WORKSPACE_ROOT or VADE_BINDIR_OVERRIDE set); live-only probe"
elif [ -z "${R2_TRANSCRIPTS_ACCESS_KEY_ID:-}" ] || [ -z "${R2_TRANSCRIPTS_SECRET_ACCESS_KEY:-}" ]; then
  E6_ok=skip
  E6_detail="R2_TRANSCRIPTS_{ACCESS,SECRET}_KEY missing in env (live probe needs creds)"
elif ! check_cmd uv; then
  E6_ok=skip
  E6_detail="uv missing (required for boto3 probe)"
elif ! check_cmd timeout; then
  E6_ok=skip
  E6_detail="timeout missing (cannot bound probe)"
else
  E6_probe_script="$SCRIPT_DIR/integrity-check-e6-r2-absence.py"
  if [ ! -x "$E6_probe_script" ]; then
    E6_ok=skip
    E6_detail="probe script not executable: $E6_probe_script"
  else
    E6_out="$(timeout 30 "$E6_probe_script" \
      --window-h "$E6_WINDOW_H" \
      --projects-dir "$E6_PROJECTS_DIR" \
      2>/dev/null || echo '')"
    if [ -z "$E6_out" ]; then
      E6_ok=false
      E6_detail="probe produced no output (timeout, missing uv, or process error)"
    elif check_cmd node; then
      E6_parsed="$(printf '%s' "$E6_out" | node -e '
        let d = "";
        process.stdin.on("data", c => d += c);
        process.stdin.on("end", () => {
          try {
            const o = JSON.parse(d);
            const ok = o.ok === true ? "true" : "false";
            const detail = (o.detail || "").replace(/[|\n\r]/g, " ");
            process.stdout.write(ok + "|" + detail);
          } catch {
            process.stdout.write("false|probe output not JSON-parseable: " + d.slice(0, 160));
          }
        });
      ' 2>/dev/null)"
      IFS='|' read -r E6_ok E6_detail <<<"$E6_parsed"
      [ -z "$E6_ok" ] && { E6_ok=false; E6_detail="probe parser produced empty verdict"; }
    else
      E6_ok=skip
      E6_detail="node missing; cannot parse probe output"
    fi
  fi
fi
_add E6 "$E6_ok" "$E6_detail"

# E7: R2 ciphertext SHA-mismatch sample (coo-harness#209, MEMO 2026-05-03-bgk3).
# Samples the K most-recent post-fix coo-logs meta.json files,
# GETs each R2 object, compares SHA256 to meta.ciphertext_sha256.
# Fires (degraded) when any mismatch is found in the sample.
#
# Additive observability over the now-fixed pipeline: coo-harness#212
# landed atomic IfNoneMatch first-write-wins in
# session-end-transcript-export.py at 2026-05-03T09:01:47Z (closing #204
# + MEMO 2026-05-03-bgk3). Mismatches in post-fix sessions would
# indicate a regression; pre-fix sessions are filtered out via the
# probe's --post-cutoff parameter.
#
# Cost: K=3 GETs of ~400KB ciphertext each ≈ 1-2MB / 2-3s per boot.
# Skips when R2 creds missing, coo-logs absent, uv missing, or
# CI fake-env active. Live-only invariant (CI staging has no R2).
#
# Tunable via env: VADE_E7_SAMPLE_K (default 3),
# VADE_E7_POST_CUTOFF (default 2026-05-03T09:01:47+00:00).
E7_ok=skip
E7_detail="prerequisites missing"
E7_K="${VADE_E7_SAMPLE_K:-3}"
E7_CUTOFF="${VADE_E7_POST_CUTOFF:-2026-05-03T09:01:47+00:00}"
E7_LOGS_DIR="${VADE_E7_LOGS_DIR:-$(dirname "$VADE_COO_MEMORY_DIR")/coo-logs/transcripts}"
if [ -n "${VADE_CI_WORKSPACE_ROOT:-}" ] || [ -n "${VADE_BINDIR_OVERRIDE:-}" ]; then
  E7_ok=skip
  E7_detail="skipped in CI fake-env (VADE_CI_WORKSPACE_ROOT or VADE_BINDIR_OVERRIDE set); live-only probe"
elif [ -z "${R2_TRANSCRIPTS_ACCESS_KEY_ID:-}" ] || [ -z "${R2_TRANSCRIPTS_SECRET_ACCESS_KEY:-}" ]; then
  E7_ok=skip
  E7_detail="R2_TRANSCRIPTS_{ACCESS,SECRET}_KEY missing in env (live probe needs creds)"
elif [ ! -d "$E7_LOGS_DIR" ]; then
  E7_ok=skip
  E7_detail="$E7_LOGS_DIR absent (no meta.json corpus to sample)"
elif ! check_cmd uv; then
  E7_ok=skip
  E7_detail="uv missing (required for boto3 probe)"
elif ! check_cmd timeout; then
  E7_ok=skip
  E7_detail="timeout missing (cannot bound probe)"
else
  E7_probe_script="$SCRIPT_DIR/integrity-check-e7-r2-sha.py"
  if [ ! -x "$E7_probe_script" ]; then
    E7_ok=skip
    E7_detail="probe script not executable: $E7_probe_script"
  else
    E7_out="$(timeout 20 "$E7_probe_script" \
      --sample-k "$E7_K" \
      --post-cutoff "$E7_CUTOFF" \
      --logs-dir "$E7_LOGS_DIR" \
      2>/dev/null || echo 'ERROR|probe-timeout-or-failure')"
    IFS='|' read -r E7_status E7_a E7_b E7_c <<<"$E7_out"
    case "$E7_status" in
      OK)
        if [ "${E7_b:-0}" = "0" ] && [ "${E7_c:-0}" = "0" ]; then
          E7_ok=true
          E7_detail="$E7_a/$E7_a post-fix R2 ciphertext SHAs match meta sidecars (K=$E7_K, cutoff $E7_CUTOFF)"
        else
          E7_ok=false
          E7_detail="$E7_b/$E7_a post-fix R2 ciphertext SHA mismatches + $E7_c errors — regression in #212 atomic IfNoneMatch fix or upload contract; see coo-harness#209, MEMO 2026-05-03-bgk3"
        fi
        ;;
      SKIP)
        E7_ok=skip
        E7_detail="probe skip: ${E7_a:-no reason} ${E7_b:-} ${E7_c:-}"
        ;;
      ERROR)
        E7_ok=false
        E7_detail="probe error: ${E7_a:-no message} ${E7_b:-} ${E7_c:-}"
        ;;
      *)
        E7_ok=false
        E7_detail="probe produced unexpected output: $(printf '%s' "$E7_out" | head -c 200)"
        ;;
    esac
  fi
fi
_add E7 "$E7_ok" "$E7_detail"

# E8: R2 ciphertext orphan detector (coo-harness#217, MEMO 2026-05-04-mzeq).
# Lists transcripts/<today>/ + transcripts/<yesterday>/ for ciphertexts
# whose LastModified is within the last VADE_E8_WINDOW_H hours (default 24),
# HEADs each one, and asserts the `vade-meta-json` user-metadata key is
# present and JSON-parseable.
#
# Sibling to E6 (#201, absence detector) and E7 (#209, SHA-mismatch).
# E8 catches the partial-export hazard: a ciphertext that lands without
# its vade-meta-json sidecar metadata, leaving fetch + analyzer
# pipelines unable to decrypt without the meta. coo-harness#216
# collapsed body+meta into one atomic PUT (object metadata via
# `x-amz-meta-vade-meta-json`), making post-#216 orphans
# structurally impossible — but per MEMO 2026-05-04-mzeq principle 2,
# "closed" requires both a fix AND a continuous detector.
#
# The 3 pre-#216 orphans (session_ids 8b2913a0, 2a6cb65a, b43eda2e
# from 2026-05-03) are excluded by the (cutoff + allowlist) combination
# inside the probe — keys whose LastModified < VADE_E8_PRE_FIX_CUTOFF
# AND whose key contains one of the allowlisted session_ids never
# count as orphans.
#
# Cost: 2 LISTs + N HEADs per boot, N = ciphertexts in window
# (~1–10 in normal use). Skips when R2 creds missing, uv missing,
# timeout missing, or CI fake-env active. Live-only invariant.
#
# Tunable via env: VADE_E8_WINDOW_H (default 24),
# VADE_E8_PRE_FIX_CUTOFF (default 2026-05-04T07:30:00Z).
E8_ok=skip
E8_detail="prerequisites missing"
E8_WINDOW_H="${VADE_E8_WINDOW_H:-24}"
E8_PRE_FIX_CUTOFF="${VADE_E8_PRE_FIX_CUTOFF:-2026-05-04T07:30:00+00:00}"
if [ -n "${VADE_CI_WORKSPACE_ROOT:-}" ] || [ -n "${VADE_BINDIR_OVERRIDE:-}" ]; then
  E8_ok=skip
  E8_detail="skipped in CI fake-env (VADE_CI_WORKSPACE_ROOT or VADE_BINDIR_OVERRIDE set); live-only probe"
elif [ -z "${R2_TRANSCRIPTS_ACCESS_KEY_ID:-}" ] || [ -z "${R2_TRANSCRIPTS_SECRET_ACCESS_KEY:-}" ]; then
  E8_ok=skip
  E8_detail="R2_TRANSCRIPTS_{ACCESS,SECRET}_KEY missing in env (live probe needs creds)"
elif ! check_cmd uv; then
  E8_ok=skip
  E8_detail="uv missing (required for boto3 probe)"
elif ! check_cmd timeout; then
  E8_ok=skip
  E8_detail="timeout missing (cannot bound probe)"
else
  E8_probe_script="$SCRIPT_DIR/integrity-check-e8-r2-orphan.py"
  if [ ! -x "$E8_probe_script" ]; then
    E8_ok=skip
    E8_detail="probe script not executable: $E8_probe_script"
  else
    E8_out="$(timeout 30 "$E8_probe_script" \
      --window-h "$E8_WINDOW_H" \
      --pre-fix-cutoff "$E8_PRE_FIX_CUTOFF" \
      2>/dev/null || echo '')"
    if [ -z "$E8_out" ]; then
      E8_ok=false
      E8_detail="probe produced no output (timeout, missing uv, or process error)"
    elif check_cmd node; then
      # Parse the probe's JSON output. node is part of the integrity
      # check's standing dependency surface (see Group A), so this
      # path is the canonical one.
      E8_parsed="$(printf '%s' "$E8_out" | node -e '
        let d = "";
        process.stdin.on("data", c => d += c);
        process.stdin.on("end", () => {
          try {
            const o = JSON.parse(d);
            const ok = o.ok === true ? "true" : "false";
            const detail = (o.detail || "").replace(/[|\n\r]/g, " ");
            process.stdout.write(ok + "|" + detail);
          } catch {
            process.stdout.write("false|probe output not JSON-parseable: " + d.slice(0, 160));
          }
        });
      ' 2>/dev/null)"
      IFS='|' read -r E8_ok E8_detail <<<"$E8_parsed"
      [ -z "$E8_ok" ] && { E8_ok=false; E8_detail="probe parser produced empty verdict"; }
    else
      E8_ok=skip
      E8_detail="node missing; cannot parse probe output"
    fi
  fi
fi
_add E8 "$E8_ok" "$E8_detail"

# E9: Cloudflare API token reachable + scoped per MEMO-2026-05-09-vwk2.
# Probe contract:
#   - GET https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/tokens/verify
#     with Authorization: Bearer $CLOUDFLARE_API_TOKEN.
#   - Pass: HTTP 200 + result.status == "active".
# Surfaces revocation, expiry, or scope-change between snapshots and
# reports expires_on so the next rotation deadline is loud.
# Account-scoped endpoint because the COO token is an Account-owned
# API token (cfat_ prefix); the user-scoped /user/tokens/verify
# endpoint rejects account tokens with code 1000 "Invalid API Token".
# Best-effort: token is feature-gated (not all sessions need Cloudflare
# access), so missing $CLOUDFLARE_API_TOKEN or $CLOUDFLARE_ACCOUNT_ID
# is `skip`, not `false`. CI fake-env mode also skips.
E9_ok=skip
E9_detail="requires CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID in env"
if [ -n "${VADE_CI_WORKSPACE_ROOT:-}" ] || [ -n "${VADE_BINDIR_OVERRIDE:-}" ]; then
  E9_ok=skip
  E9_detail="skipped in CI fake-env (VADE_CI_WORKSPACE_ROOT or VADE_BINDIR_OVERRIDE set); live-only probe"
elif [ -z "${CLOUDFLARE_API_TOKEN:-}" ] || [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
  E9_ok=skip
  E9_detail="CLOUDFLARE_API_TOKEN or CLOUDFLARE_ACCOUNT_ID not in hook env (Phase 2: secrets live in process env only; this probe runs in a hook subprocess that may not have inherited from bootstrap yet)"
elif ! check_cmd curl || ! check_cmd node; then
  E9_ok=skip
  E9_detail="curl or node missing; cannot probe"
else
  # No -f so we keep the response body on 4xx (parsing it gives us the
  # real Cloudflare error message instead of a generic "non-2xx").
  E9_resp="$(curl -sS -m 8 \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/tokens/verify" 2>/dev/null || true)"
  if [ -z "$E9_resp" ]; then
    E9_ok=false
    E9_detail="api.cloudflare.com unreachable from this hook (no body returned within 8s); check egress to api.cloudflare.com or DNS"
  else
    E9_verdict="$(printf '%s' "$E9_resp" | node -e '
      let d = ""; process.stdin.on("data", c => d += c);
      process.stdin.on("end", () => {
        try {
          const o = JSON.parse(d);
          if (o.success && o.result && o.result.status === "active") {
            const id = String(o.result.id || "").slice(0, 8);
            const exp = o.result.expires_on || "no-expiry";
            process.stdout.write("ok|" + id + "|" + exp);
          } else {
            const errCode = (o.errors && o.errors[0] && o.errors[0].code) || "?";
            const errMsg = ((o.errors && o.errors[0] && o.errors[0].message) || "unknown error").slice(0, 120);
            const status = (o.result && o.result.status) || "missing";
            process.stdout.write("bad|" + status + "|code=" + errCode + " " + errMsg);
          }
        } catch (e) {
          process.stdout.write("bad|parse-failed|body: " + d.slice(0, 200));
        }
      });
    ' 2>/dev/null || echo "bad|node-failed|node parse subprocess failed")"
    IFS='|' read -r E9_verdict_kind E9_verdict_a E9_verdict_b <<<"$E9_verdict"
    if [ "$E9_verdict_kind" = "ok" ]; then
      E9_ok=true
      E9_detail="Cloudflare API token active (id-prefix=$E9_verdict_a; expires=$E9_verdict_b; verified against /accounts/$CLOUDFLARE_ACCOUNT_ID/tokens/verify per MEMO-2026-05-09-vwk2)"
    else
      E9_ok=false
      E9_detail="Cloudflare token verify failed: status=$E9_verdict_a $E9_verdict_b"
    fi
  fi
fi
_add E9 "$E9_ok" "$E9_detail"
fi  # close VADE_INTEGRITY_PHASE != "fast" gate around Group E

# ── Group F: Culture-system substrate discipline ─────────────
# Implements E1–E4 from foundations/2026-04-22_we-can-claim-a-record.md
# §5d (label delta: the essay calls these E1–E4; Group E is occupied by
# live MCP-surface probes, so the script reserves F). Adopted by
# SOP-CULTURE-001 and MEMO 2026-04-24-12. Non-fatal on every path.
#
# F_CUTOFF is the adoption moment from which the invariants bind.
# Artifacts dated earlier are pre-adoption and pass by construction.
# Bumping the cutoff requires a memo retiring or superseding MEMO
# 2026-04-24-12's §F_CUTOFF clause.
#
# Time-precise rather than date-precise because 2026-04-24 contained
# one Ven-authored commit (418f0a4, PR #94) an hour before the first
# decision-bearing commit of the day; an "adoption moment" captures
# the adoption boundary cleanly without retroactively flagging a
# legitimate pre-adoption attribution.
#
# F_CUTOFF_GIT bumped 2026-04-26 per MEMO 2026-04-26-01 to retire
# 7 chronic-yellow F4 hits (3 nightly-routine, 2 historical Ven-
# human-action quick-fixes, 1 post-convention quick-fix where the
# auto-marker workflow did not yet exist, 1 coo-scope refactor where
# the bootstrap was degraded at PR-open time). The auto-marker workflow
# in coo-memory/.github/workflows/f4-marker.yml takes effect on
# PRs opened from this point forward; F4 reflects the post-workflow
# reality rather than the historical accumulation. F_CUTOFF (date form)
# stays at 2026-04-24 — F2/F3 are green and the broader memo/essay
# invariants should keep the wider window.
F_CUTOFF="2026-04-24"                     # date form — used for F2 memo-index, F3 essay-filename comparisons
F_CUTOFF_GIT="2026-04-26 00:30:00 +0000"  # timestamp form — used for F1/F4 git log --since

# Resolve the coo-memory repo path. Canonical order: env
# override, sibling under WORKSPACE_ROOT (works on both cloud and
# local since WORKSPACE_ROOT was derived from SCRIPT_DIR above),
# macOS legacy fallback, cloud legacy fallback.
F_REPO="${COO_MEMORY_DIR:-$VADE_COO_MEMORY_DIR}"

# ── F1 — memo-or-issue citation invariant ───────────────────
# Every commit since F_CUTOFF touching identity/, operations/,
# memos/, briefings/, plans/, projects/, instruments/, quorums/,
# foundations/, lineage/, site/, personas/, funding/, or CLAUDE.md
# (excluding _drafts/, _archive/, audits/, retrospectives/, and the
# foundations/*_transcript.md pattern) must cite MEMO YYYY-MM-DD-NN
# or #NNN in its message body. Diff mentions do not count.
# F1_ALLOWLIST_SHA — explicit per-commit carve-outs for F1-scope commits
# whose bodies lack the regex citation form but describe substantively
# correct linkage (e.g. "Ven UI queue item N", "§7 work-stream"). The body
# context makes the lineage clear to a human reviewer but doesn't match
# the F1 regex (MEMO-YYYY-MM-DD-suffix or #NNN). Allowlisted with full
# causal record below; no policy gap.
F1_ALLOWLIST_SHA=(
  # 16cb6fb81d — "secrets(schema+log): record Ven decisions 2026-06-04 (Step B)"
  # by Coo on 2026-06-04. Body explicitly references "§7 Ven UI queue" work-
  # stream from coo-memory#871 Track 1 + audit reports/storage.md §7, plus
  # five specific schema-entry decisions per Ven. The citation form is
  # "§7 Ven UI queue item N" rather than "#N" — clear linkage, F1 regex
  # miss only.
  "16cb6fb81d"
  # 21fa1f661b — "secrets(schema): backfill vade-coo-self-2026-04 expires_at + scopes"
  # by Coo on 2026-06-04. Body references "Ven UI queue item 4 (Track 1 §4
  # dispatch prerequisite)" — same §-citation pattern as 16cb6fb81d. Documents
  # the live-read backfill of expires_at + permission_scopes on the canonical
  # PAT. Clear linkage to #871 Track 1 §4; F1 regex miss only.
  "21fa1f661b"
  # aa645c5315 — "schema.schema.json: extend enums for cf-worker surface + retired status"
  # by Coo on 2026-06-05. Body opens with "CI caught 5 enum violations
  # introduced by the close-out commit" — the lineage is to the prior
  # main commit (the secrets-epic close-out, MEMO-2026-06-05-v5qk /
  # coo-memory#871). The "the close-out commit" referent is unambiguous
  # in body context but the F1 regex matches neither MEMO-... nor #N
  # forms. Clear linkage to #871 Track close-out; F1 regex miss only.
  "aa645c5315"
  # 6542a1be51 — "funding/billing: file 1Password credit invoice in_1Tfpth
  # (Jun 7 2026)" by Coo on 2026-06-08, merged via coo-memory#1329. First
  # agent-authored receipt filing under funding/billing/ (precedent: BDFL
  # uploads receipts directly per funding/billing/README.md "Who writes
  # here"). Vendor receipts are pure archive — vendor-issued PDFs with the
  # vendor's own identifier in the filename — and carry no decision content
  # that would warrant a memo or issue citation. The vendor invoice ID
  # `in_1TfpthHBax7L5HDfdwcnBTMX` is present in the body but doesn't match
  # the F1 regex (MEMO-YYYY-MM-DD-suffix or #NNN). Already pushed to
  # origin/main — rewriting public history is the wrong tradeoff.
  # Systemic gap: any agent-filed vendor receipt under funding/billing/
  # will hit this same shape; consider excluding `^funding/billing/` from
  # the F1 scope regex (structurally similar to the existing _archive/
  # carve-out — receipts are archive, not decision content). Surfaced in
  # the PR that adds this entry.
  "6542a1be51"
)
if [ -d "$F_REPO/.git" ] && check_cmd git; then
  f1_total=0
  f1_bad=()
  # List commit SHAs touching F1 scope since F_CUTOFF; body inspection
  # happens per-commit. --name-only with --format gives sha-then-paths.
  #
  # --min-parents=1 skips parent-less commits. In cloud-container shallow
  # clones (every Claude Code on the web boot), the most-recent merged
  # commit lands as the shallow boundary and reports as a root commit;
  # `git show --name-only` on it reports the entire tree as "touched",
  # producing a structural F1 false-positive every boot. Real F1 scope
  # is the per-commit diff, so a no-parent commit can't legitimately be
  # decision-bearing under this invariant; skipping the boundary recovers
  # canonical-history semantics on shallow checkouts without weakening
  # the rule on the full-history reviewer's repo.
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    # Paths this commit touched that are in scope.
    touched=$(git -C "$F_REPO" show --name-only --format= "$sha" 2>/dev/null \
      | grep -E '^(identity/|operations/|memos/|briefings/|plans/|projects/|instruments/|quorums/|foundations/|lineage/|site/|personas/|funding/|CLAUDE\.md$)' \
      | grep -vE '^_drafts/|^_archive/|^audits/|^retrospectives/|^foundations/.*_transcript\.md$' \
      || true)
    [ -n "$touched" ] || continue
    f1_total=$((f1_total + 1))
    body=$(git -C "$F_REPO" log -1 --format='%B' "$sha" 2>/dev/null || echo '')
    if ! printf '%s' "$body" | grep -qE 'MEMO[- ][0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-z]+|#[0-9]+'; then
      # Check allowlist before flagging.
      allowed=0
      for allow_sha in "${F1_ALLOWLIST_SHA[@]}"; do
        case "$sha" in "$allow_sha"*) allowed=1; break ;; esac
      done
      [ "$allowed" -eq 1 ] && continue
      f1_bad+=("${sha:0:10}")
    fi
  done < <(git -C "$F_REPO" log --since="$F_CUTOFF_GIT" --min-parents=1 --format='%H' 2>/dev/null)

  if [ "$f1_total" -eq 0 ]; then
    _add F1 true "no decision-bearing commits since $F_CUTOFF_GIT (nothing to check)"
  elif [ "${#f1_bad[@]}" -eq 0 ]; then
    _add F1 true "$f1_total/$f1_total decision-bearing commits since $F_CUTOFF_GIT cite memo or issue"
  else
    _add F1 false "${#f1_bad[@]}/$f1_total commits missing memo-or-issue citation (MEMO-YYYY-MM-DD-suffix or #NNN): $(IFS=,; echo "${f1_bad[*]}")"
  fi
else
  _add F1 skip "requires coo-memory repo at $F_REPO with .git"
fi

# ── F2 — Memo retirement invariant ───────────────────────────
# Every memo dated >= F_CUTOFF in memos/memo_index.json must carry a
# 'Retirement condition' clause or `retention: "permanent"` in the body of
# its per-memo file at $entry.file_path (post-#210 layout, MEMO-2026-04-27-5kaq;
# canonical spec: operations/culture_system_sop.md F2 row).
# Absence = case-law violation per memo_protocol.md.
if [ -f "$F_REPO/memos/memo_index.json" ] && check_cmd jq; then
  f2_total=0
  f2_bad=()
  while IFS='|' read -r id fp; do
    [ -n "$id" ] || continue
    f2_total=$((f2_total + 1))
    body_path="$F_REPO/$fp"
    if [ ! -f "$body_path" ]; then
      f2_bad+=("$id(missing-file)")
      continue
    fi
    if ! grep -qE 'Retirement condition|retention: "permanent"' "$body_path"; then
      f2_bad+=("$id")
    fi
  done < <(jq -r --arg c "$F_CUTOFF" '.[] | select(.date >= $c) | "\(.id)|\(.file_path)"' "$F_REPO/memos/memo_index.json" 2>/dev/null)

  if [ "$f2_total" -eq 0 ]; then
    _add F2 true "no post-cutoff memos to check"
  elif [ "${#f2_bad[@]}" -eq 0 ]; then
    _add F2 true "$f2_total/$f2_total post-cutoff memos carry retirement clause"
  else
    _add F2 false "missing retirement clause: $(IFS=,; echo "${f2_bad[*]}")"
  fi
else
  _add F2 skip "requires memos/memo_index.json and jq"
fi

# ── F3 — Essay companion invariant ───────────────────────────
# Every foundations/YYYY-MM-DD_*.md dated since F_CUTOFF (excluding
# _transcript, _companion, and _agent-reports files) must have a matching
# companion: either YYYY-MM-DD_transcript.md (single-session form) or any
# YYYY-MM-DD_*_companion.md / YYYY-MM-DD_*-companion.md (multi-instance /
# protocol-substrate form, e.g. foundations/2026-04-28_letter-to-
# anthropic-companion.md). Either satisfies the obligation; the companion
# variant carries the same record-of-reasoning role for artifacts that
# weren't authored in a single session.
if [ -d "$F_REPO/foundations" ]; then
  f3_total=0
  f3_bad=()
  while IFS= read -r essay; do
    [ -n "$essay" ] || continue
    essay_date="${essay:0:10}"
    # String comparison on ISO dates is safe; bash [[ ]] supports it.
    [ "$essay_date" \< "$F_CUTOFF" ] && continue
    case "$essay" in
      *_transcript.md|*_companion.md|*-companion.md|*_agent-reports*) continue ;;
    esac
    f3_total=$((f3_total + 1))
    has_companion=0
    if [ -f "$F_REPO/foundations/${essay_date}_transcript.md" ]; then
      has_companion=1
    else
      # Accept any same-date *_companion.md or *-companion.md as transcript-equivalent.
      for c in "$F_REPO/foundations/${essay_date}"_*_companion.md \
               "$F_REPO/foundations/${essay_date}"_*-companion.md; do
        [ -f "$c" ] && { has_companion=1; break; }
      done
    fi
    if [ "$has_companion" -eq 0 ]; then
      f3_bad+=("$essay")
    fi
  done < <(ls -1 "$F_REPO/foundations/" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_')

  if [ "$f3_total" -eq 0 ]; then
    _add F3 true "no post-cutoff essays to check"
  elif [ "${#f3_bad[@]}" -eq 0 ]; then
    _add F3 true "$f3_total/$f3_total post-cutoff essays have transcript companion"
  else
    _add F3 false "missing transcript for: $(IFS=,; echo "${f3_bad[*]}")"
  fi
else
  _add F3 skip "no foundations directory at $F_REPO"
fi

# ── F4 — Attribution coverage ────────────────────────────────
# Every commit since F_CUTOFF in $F_REPO must resolve to vade-coo
# (author email coo@vade-app.dev) or carry 'ven-human-action:' in body.
# Silent venpopov-authored commits on coo-scope paths are F4-relevant.
#
# F4_ALLOWLIST_SHA — explicit per-commit carve-outs for direct-to-main
# commits with no PR (the PR-body fallback below can't help when there
# is no PR). PR-merge commits where the f4-marker workflow raced past
# the merge are handled by the fallback at audit time, not this list.
# Tracked structurally at coo-memory#271.
F4_ALLOWLIST_SHA=(
  # 7cb8a86da4 — coo-memory direct commit "update gitignore" by
  # Ven on 2026-05-01 outside the PR flow (no PR body, so the f4-marker
  # workflow at coo-memory/.github/workflows/f4-marker.yml had no
  # surface to inject ven-human-action: into). Direct-to-main quick-fix
  # by the BDFL is allowlisted by the same precedent that retired the
  # 2 historical Ven-human-action quick-fixes pre-2026-04-26 (cf. the
  # F_CUTOFF_GIT comment block above). Cleared in run-2026-05-02T120959
  # full-bootup pass.
  "7cb8a86da4"
  # d3479467e8 — coo-memory commit "end-session: streamline (pre-fill
  # title, inline Mem0 shape, scripted PR-open)" on 2026-06-04. Author
  # leaked as Claude <noreply@anthropic.com>; committer correctly set
  # to Coo <coo@vade-app.dev>. Root cause: Anthropic shipped a new
  # silent override on git credentials earlier that day that defeated
  # the existing COO author-override; the override-on-override was
  # patched same session, and the prior session re-attributed most of
  # the affected commits, but this one landed on main before the
  # remediation and was missed in the sweep. Already pushed to
  # origin/main — rewriting public history is the wrong tradeoff.
  # Allowlisted with full causal record above; no policy gap.
  "d3479467e8"
  # 8354ca0d6f — coo-memory commit "coo-on-assign: flip thin trigger
  # from assigned to field_added (PR3/4)" on 2026-06-07, merged via
  # coo-memory#1327. Author leaked as vade-coo-app[bot] <286614649+
  # vade-coo-app[bot]@users.noreply.github.com>; committer correctly
  # set to Coo <coo@vade-app.dev>. Root cause: the diff touches
  # `.github/workflows/coo-on-assign.yml`, which requires the
  # `vade-coo-app` GitHub App install-token write authority (the
  # OAuth that authenticates `git push` lacks the `workflow` scope —
  # see coo-memory/CLAUDE.md "To commit a file the session's OAuth
  # lacks scope for ..."). The pr-ven-human-action-marker workflow
  # correctly skipped marker injection because the PR author was
  # `vade-coo` (the COO opens own PRs); on rebase-merge the original
  # commit SHA was preserved, carrying the App author email forward.
  # F4's PR-body fallback can't reach PR #1327 either because the
  # subject ends in "(PR3/4)" rather than "(#1327)". Already pushed
  # to origin/main — rewriting public history is the wrong tradeoff.
  # Systemic gap: any workflow-file commit made via App install-token
  # in a `vade-coo`-authored PR will hit this same shape; consider a
  # follow-on that accepts the App-bot author email as COO attribution
  # outright, rather than per-commit allowlisting. Surfaced in the PR
  # that adds this entry.
  "8354ca0d6f"
)
if [ -d "$F_REPO/.git" ] && check_cmd git; then
  f4_total=0
  f4_bad=()
  while IFS='|' read -r sha email body; do
    # Skip blank records: awk's RS="\0" parser emits one on the trailing
    # null terminator, and trimmed SHA-less lines can slip through mid-stream.
    [ -n "$sha" ] || continue
    case "$sha" in *[!0-9a-f]*) continue ;; esac
    f4_total=$((f4_total + 1))
    if [ "$email" = "coo@vade-app.dev" ]; then
      continue
    fi
    if printf '%s' "$body" | grep -q 'ven-human-action:'; then
      continue
    fi
    allowed=0
    for allow_sha in "${F4_ALLOWLIST_SHA[@]}"; do
      case "$sha" in "$allow_sha"*) allowed=1; break ;; esac
    done
    [ "$allowed" -eq 1 ] && continue
    # PR-body fallback for f4-marker race (coo-memory#271): the
    # f4-marker workflow may inject the marker into the PR body after
    # the merge, leaving the commit body without it. When the commit
    # subject ends in "(#NNN)", look up the PR body via gh api and
    # accept if the marker is present there. Falls open (commit lands
    # in f4_bad) when gh missing or auth fails — same observability
    # as today.
    pr_num=""
    subject=$(git -C "$F_REPO" log -1 --format='%s' "$sha" 2>/dev/null || echo '')
    if [[ "$subject" =~ \(#([0-9]+)\)[[:space:]]*$ ]]; then
      pr_num="${BASH_REMATCH[1]}"
    fi
    if [ -n "$pr_num" ] && check_cmd gh; then
      pr_body=$(GH_TOKEN="${GITHUB_MCP_PAT:-${GH_TOKEN:-}}" \
        gh api "repos/coo-labs/coo-memory/pulls/$pr_num" \
        --jq '.body' 2>/dev/null || true)
      if printf '%s' "$pr_body" | grep -q 'ven-human-action:'; then
        continue
      fi
    fi
    f4_bad+=("${sha:0:10}($email)")
  done < <(git -C "$F_REPO" log --since="$F_CUTOFF_GIT" --format='%H|%ae|%B%x00' 2>/dev/null | awk 'BEGIN{RS="\0"} { sub(/^\n/, ""); if (NF) { gsub(/\n/,"\\n"); print } }')

  if [ "$f4_total" -eq 0 ]; then
    _add F4 true "no commits since $F_CUTOFF_GIT (nothing to check)"
  elif [ "${#f4_bad[@]}" -eq 0 ]; then
    _add F4 true "$f4_total/$f4_total commits resolve to vade-coo or carry ven-human-action"
  else
    _add F4 false "${#f4_bad[@]}/$f4_total attribution mismatches: $(IFS=,; echo "${f4_bad[*]}")"
  fi
else
  _add F4 skip "requires coo-memory repo at $F_REPO with .git"
fi

# ── F5 — Voice-density on post-cutoff foundations essays ─────
# Stage 1 of disposition-proposal §5 F4 (substrate-capture pole), per
# MEMO-2026-04-29-74vf (voice-drain register failure mode + voice-density
# verification dimension). Runs bin/voice-density.py on each non-companion
# foundations essay and fires when any falls below the calibrated floor
# (default 6.0 carriers/1000 from the auto-detectable subset; baseline
# observed min 6.92 per instruments/voice-density.md §4).
#
# Numbering note: integrity-check.sh F1-F4 are memo-or-issue-citation,
# memo-retirement, essay-companion, attribution-coverage. F5 extends the script's F-series
# numerically; the disposition-proposal F1-F7 audit poles are a SEPARATE
# numbering axis. F5 here implements pole F4's sub-condition 1. Stages 2-4
# of coo-memory#429 will add further slots covering the remaining
# sub-conditions (section-positioning, fresh-boot reading-test, F5 dark-
# accumulation metrics).
#
# Signal-shape, not gate-shape: a fired F5 means "investigate drift,"
# not "block." Disposition-proposal §6 names gate-shape watchdogs as
# themselves a substrate-capture vector; F5 honors that explicitly.
#
# Floor revisable by env: VADE_VOICE_DENSITY_FLOOR.
F5_SCRIPT="$F_REPO/bin/voice-density.py"
F5_FLOOR="${VADE_VOICE_DENSITY_FLOOR:-6.0}"
if [ -f "$F5_SCRIPT" ] && [ -d "$F_REPO/foundations" ] && check_cmd python3; then
  f5_tmp_err=$(mktemp 2>/dev/null || echo "/tmp/vade-f5-$$.err")
  f5_count=$(python3 "$F5_SCRIPT" --all "$F_REPO/foundations" \
    --exclude '*_transcript.md' \
    --exclude '*_companion.md' \
    --exclude '*-companion.md' \
    --exclude '*_agent-reports*' \
    --exclude 'README.md' \
    --floor "$F5_FLOOR" 2>"$f5_tmp_err" \
    | grep -c '^path:' || true)
  f5_rc=${PIPESTATUS[0]}
  if [ "$f5_rc" -eq 0 ]; then
    _add F5 true "$f5_count post-cutoff essays meet voice-density floor $F5_FLOOR/1000 (auto subset)"
  elif [ "$f5_rc" -eq 1 ]; then
    f5_below=$(grep -E '^[[:space:]]+/' "$f5_tmp_err" 2>/dev/null \
      | sed 's|^[[:space:]]*||;s|^.*/||;s|: .*||' \
      | tr '\n' ',' | sed 's/,$//')
    _add F5 false "voice-density below floor $F5_FLOOR/1000 (auto subset): ${f5_below:-unknown}"
  else
    _add F5 skip "voice-density.py exited rc=$f5_rc"
  fi
  rm -f "$f5_tmp_err"
else
  _add F5 skip "requires $F_REPO/bin/voice-density.py + foundations + python3"
fi

# ── F6 — External-touch (dark-accumulation pole, Stage 2) ─────
# Stage 2 of disposition-proposal §5 F5 sub-condition 1
# (time-since-last-external-touch per artifact category). Runs
# bin/external-touch.py in --check mode against a cached vade-canvas
# discussions index; fires when any mirrored artifact's most recent
# external touch is past the category floor (foundations 60d,
# retrospectives 90d, lineage 7d, memos tracked-not-floored).
#
# Cache-decoupled architecture: the gh api call is deliberately
# separated into --refresh-cache mode and is NOT invoked here. F6
# reads the cache offline. Refresh on demand via:
#   python3 $F_REPO/bin/external-touch.py \
#     --refresh-cache $VADE_CLOUD_STATE_DIR/external-touch-cache.json
#
# F6 fires on:
#   - recurring categories (foundations, retrospectives): above-floor
#     violations only — no-mirror exempt due to matcher false-negatives.
#   - one-shot categories (lineage, per coo-memory#508):
#     no-mirror-past-window violations (age from first commit > floor).
#     Mirrored-once = satisfied permanently.
# See instruments/external-touch.md §2.
#
# Numbering note: same axis as F5 — extends integrity-check.sh's
# F-series numerically; this implements disposition-proposal F5
# sub-condition 1.
F6_SCRIPT="$F_REPO/bin/external-touch.py"
F6_CACHE="${VADE_EXTERNAL_TOUCH_CACHE:-$VADE_CLOUD_STATE_DIR/external-touch-cache.json}"
if [ -f "$F6_SCRIPT" ] && [ -d "$F_REPO/memos" ] && check_cmd python3; then
  if [ ! -f "$F6_CACHE" ]; then
    _add F6 skip "cache absent at $F6_CACHE — refresh via bin/external-touch.py --refresh-cache"
  else
    f6_tmp_err=$(mktemp 2>/dev/null || echo "/tmp/vade-f6-$$.err")
    python3 "$F6_SCRIPT" --check --cache "$F6_CACHE" --coo-root "$F_REPO" 2>"$f6_tmp_err"
    f6_rc=$?
    if [ "$f6_rc" -eq 0 ]; then
      f6_age=$(python3 -c "
import json, sys
from datetime import datetime, timezone
try:
  with open('$F6_CACHE') as fh:
    fetched = datetime.fromisoformat(json.load(fh)['fetched_at'])
  age = (datetime.now(timezone.utc) - fetched).total_seconds() / 86400.0
  print(f'{age:.1f}')
except Exception:
  print('?')
" 2>/dev/null)
      _add F6 true "no external-touch floor violations (cache age: ${f6_age}d)"
    elif [ "$f6_rc" -eq 1 ]; then
      f6_violations=$(grep -E '^\[' "$f6_tmp_err" 2>/dev/null | head -3 | tr '\n' ';' | sed 's/;$//')
      _add F6 false "external-touch violation: ${f6_violations:-unknown}"
    else
      _add F6 skip "external-touch.py exited rc=$f6_rc"
    fi
    rm -f "$f6_tmp_err"
  fi
else
  _add F6 skip "requires $F_REPO/bin/external-touch.py + coo + python3"
fi

# ── F8 — Framed-as-caution auditor (dark-accumulation pole, sub-cond 3) ─
# F5 sub-condition 3 of disposition-proposal §5 (lines 285-289): auditor-
# agent corpus pass over retrospectives and memos detecting "framed as
# caution" patterns — perpetual non-externalization presented as
# principled restraint without the principle stated, or with a principle
# that would dissolve under scrutiny. Per plans/2026-05-10_f4-f5-
# completion.md §6 Phase 2 + instruments/framed-as-caution.md §6.
#
# Runs bin/framed-as-caution.py against retrospectives/ + memos/
# (foundations excluded — covered by F4 / integrity-check F5) and fires
# when the count of artifacts with strong (non-borderline) framed-as-
# caution findings rises above the calibrated threshold.
#
# Numbering note: integrity-check.sh F1-F4 are memo-or-issue-citation,
# memo-retirement, essay-companion, attribution-coverage. F5-F8 extend the
# script's F-series numerically; the disposition-proposal F1-F7 audit
# poles are a SEPARATE numbering axis. F8 here implements disposition-
# proposal F5 sub-condition 3 (where F5 here implemented disposition-
# proposal F4 sub-condition 1 and F6 implemented F5 sub-condition 1).
# F7 is reserved for fresh-boot reading-test cadence per
# instruments/fresh-boot-reading-test.md §6 if/when it lands as an
# invariant; F9 is reserved for the future section-positioning v2
# (disposition-proposal F4 sub-condition 2) per the F4/F5 plan §6 Phase 3.
#
# Signal-shape, not gate-shape: a fired F8 means "investigate; the
# corpus has accumulated framed-as-caution language above baseline,"
# not "block." The disposition-proposal §6 names gate-shape watchdogs
# as themselves a substrate-capture vector; F8 honors that explicitly.
#
# Threshold revisable by env: VADE_FRAMED_AS_CAUTION_THRESHOLD.
# Initial threshold TBD by first 3 quarterly runs per
# instruments/framed-as-caution.md §4 — calibration on first run
# is a separate dispatch from the tooling-ship PR.
F8_SCRIPT="$F_REPO/bin/framed-as-caution.py"
F8_THRESHOLD="${VADE_FRAMED_AS_CAUTION_THRESHOLD:-0}"
if [ -f "$F8_SCRIPT" ] \
   && [ -d "$F_REPO/retrospectives" ] \
   && [ -d "$F_REPO/memos" ] \
   && check_cmd python3; then
  f8_tmp_err=$(mktemp 2>/dev/null || echo "/tmp/vade-f8-$$.err")
  f8_tmp_out=$(mktemp 2>/dev/null || echo "/tmp/vade-f8-$$.out")
  python3 "$F8_SCRIPT" --corpus "$F_REPO" --json --threshold "$F8_THRESHOLD" \
    >"$f8_tmp_out" 2>"$f8_tmp_err"
  f8_rc=$?
  if [ "$f8_rc" -eq 0 ]; then
    f8_count=$(python3 -c "
import json, sys
try:
  recs = json.load(open('$f8_tmp_out'))
  strong = sum(1 for r in recs if any(ev.get('borderline_reason') is None for ev in r.get('evidence', [])))
  border = sum(1 for r in recs if r['framed_as_caution'] and not any(ev.get('borderline_reason') is None for ev in r.get('evidence', [])))
  print(f'{strong}|{border}|{len(recs)}')
except Exception as e:
  print(f'?|?|?')
" 2>/dev/null)
    f8_strong=$(echo "$f8_count" | cut -d'|' -f1)
    f8_border=$(echo "$f8_count" | cut -d'|' -f2)
    f8_total=$(echo "$f8_count" | cut -d'|' -f3)
    _add F8 true "${f8_strong:-0} flagged framed-as-caution (strong), ${f8_border:-0} borderline-only, across ${f8_total:-?} artifacts (threshold $F8_THRESHOLD)"
  elif [ "$f8_rc" -eq 1 ]; then
    f8_offenders=$(python3 -c "
import json
try:
  recs = json.load(open('$f8_tmp_out'))
  flagged = [r['path'] for r in recs if any(ev.get('borderline_reason') is None for ev in r.get('evidence', []))]
  print(','.join(p.rsplit('/', 1)[-1] for p in flagged[:3]))
except Exception:
  print('')
" 2>/dev/null)
    _add F8 false "framed-as-caution count above threshold $F8_THRESHOLD: ${f8_offenders:-unknown}"
  else
    _add F8 skip "framed-as-caution.py exited rc=$f8_rc"
  fi
  rm -f "$f8_tmp_err" "$f8_tmp_out"
else
  _add F8 skip "requires $F_REPO/bin/framed-as-caution.py + retrospectives + memos + python3"
fi

# ── Group S: Secrets-schema invariants ───────────────────────
# Implements S1, S2, S3, S4, S5, S7, S8 from
# coo-memory/operations/secrets/README.md §3.4. S6 demoted to warning
# per SOP rationalization R-3 and intentionally NOT emitted here.
#
# Track 1b of the secrets-management implementation epic
# (coo-memory#871). Probe-not-repair: every failure surfaces in the
# JSON output, but the script keeps exit 0. Boot-blocking integration
# is a follow-up PR after this soaks clean.
#
# Skip semantics (per S-invariant):
#   - S1: skip if validator or PyYAML/jsonschema missing.
#   - S2: skip if yq missing.
#   - S3: works in CI for filesystem mirrors; sha8 check + org/repo
#         secret checks skip when op CLI or gh CLI is unavailable.
#   - S4: skip if op CLI not live (CI fake-env or missing
#         OP_SERVICE_ACCOUNT_TOKEN).
#   - S5: works in CI for filesystem path inspection; degraded reports
#         do not impede other invariants.
#   - S7: skip if op CLI not live.
#   - S8: works everywhere — classifies current process env against
#         schema + writes today's keynames snapshot.
S_LIB="$SCRIPT_DIR/../lib/integrity-group-s.sh"
if [ -r "$S_LIB" ]; then
  # shellcheck source=../lib/integrity-group-s.sh
  source "$S_LIB"
  s_check_all
else
  _add S1 skip "integrity-group-s.sh helper missing at $S_LIB"
fi

# ── Serialize ────────────────────────────────────────────────
mkdir -p "$VADE_CLOUD_STATE_DIR" 2>/dev/null || true

if check_cmd node; then
  printf '%s\n' "${RESULTS[@]}" | node -e '
    const fs = require("fs");
    const [outFile, sessionId] = process.argv.slice(1);
    const groups = {};
    const degraded = [];
    let total = 0, okCount = 0;
    const input = fs.readFileSync(0, "utf8");
    for (const line of input.split("\n")) {
      if (!line) continue;
      const [key, ok, ...detailParts] = line.split("|");
      const detail = detailParts.join("|");
      const g = key[0];
      groups[g] = groups[g] || {};
      const isOk = ok === "true";
      const isInfo = ok === "info";
      const isSkip = ok === "skip";
      groups[g][key] = { ok: isOk, detail };
      if (isInfo) groups[g][key] = { info: true, detail };
      if (isSkip) groups[g][key] = { ok: null, skipped: true, detail };
      if (!isInfo && !isSkip) {
        total += 1;
        if (isOk) okCount += 1;
        else degraded.push(key);
      }
    }
    const out = {
      checked_at: new Date().toISOString(),
      session_id: sessionId || "unknown",
      schema_version: "1.0",
      summary: { ok: degraded.length === 0, passed: okCount, total, degraded },
      groups,
    };
    const tmpFile = outFile + ".tmp." + process.pid;
    fs.writeFileSync(tmpFile, JSON.stringify(out, null, 2) + "\n");
    fs.renameSync(tmpFile, outFile);
    const tag = out.summary.ok ? "OK" : "DEGRADED";
    process.stderr.write(`VADE integrity: ${okCount}/${total} ${tag}`
      + (degraded.length ? ` — degraded (${degraded.join(",")})` : "")
      + ` — ${outFile}\n`);
  ' "$OUT_FILE" "${CLAUDE_CODE_SESSION_ID:-unknown}" || {
    echo "[vade-setup] integrity-check: node writer failed; leaving stale file" >&2
  }
else
  # Fallback: newline-separated triples, no JSON. Atomic write via
  # tmpfile + mv so consumers don't observe a partial file.
  _tmp_fallback="${OUT_FILE}.tmp.$$"
  {
    printf 'checked_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'session_id=%s\n' "${CLAUDE_CODE_SESSION_ID:-unknown}"
    printf '%s\n' "${RESULTS[@]}"
  } > "$_tmp_fallback" 2>/dev/null && mv -f "$_tmp_fallback" "$OUT_FILE" 2>/dev/null || true
  rm -f "$_tmp_fallback" 2>/dev/null || true
  echo "[vade-setup] integrity-check: node missing; wrote key=value file to $OUT_FILE" >&2
fi

exit 0
