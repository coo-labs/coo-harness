#!/usr/bin/env python3
"""Render an interactive HTML timeline from a bootstrap-trace run.

Usage: render-trace-timeline.py [<trace-dir>] [<output-html>] [--json]
Default trace-dir: ~/.vade/traces/$(cat ~/.vade/traces/CURRENT_RUN_ID)
Default output:    /tmp/trace-timeline.html (or /tmp/trace-data.json with --json)

The ``--json`` flag emits the parsed data blob (the same object the HTML
renderer embeds inline) and skips HTML emission. Used by
``upload-trace-bundle.py`` to ship traces to the Console R2 prefix.
"""
import datetime
import json
import os
import re
import sys
from html import escape


def find_default_trace_dir():
    cur = os.path.expanduser("~/.vade/traces/CURRENT_RUN_ID")
    if os.path.exists(cur):
        run_id = open(cur).read().strip()
        return os.path.expanduser(f"~/.vade/traces/{run_id}")
    raise SystemExit("no trace dir given and CURRENT_RUN_ID not found")


_ARGS = [a for a in sys.argv[1:] if a != "--json"]
JSON_MODE = "--json" in sys.argv
TRACE_DIR = _ARGS[0] if len(_ARGS) > 0 else find_default_trace_dir()
OUTPUT = _ARGS[1] if len(_ARGS) > 1 else (
    "/tmp/trace-data.json" if JSON_MODE else "/tmp/trace-timeline.html"
)

meta_path = os.path.join(TRACE_DIR, "meta.json")
meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}

xtrace_path = os.path.join(TRACE_DIR, "xtrace.log")
xtrace_re = re.compile(
    r"^\++ \[(?P<ts>[0-9.]+)\] \[pid=(?P<pid>\d+) bp=(?P<bp>\d+)\] "
    r"\[(?P<script>[^:\]]+?)(?::(?P<line>\d+))? fn=(?P<fn>[^\]]+)\] "
    r"(?P<cmd>.*)$"
)

PID_FIRST = {}
PID_LAST = {}
PID_SCRIPT = {}
PID_CMD_COUNT = {}
PID_COMMANDS = {}  # pid -> list of dicts {ts_ms (set later), script, line, fn, cmd_preview}
COMMANDS_PER_PID_CAP = 80  # bounds output size for chatty PIDs

# PIDs whose script matches one of these get no command log — they're trace
# plumbing and brief subprocesses, not the user-script work. Saves ~10x in
# output size when many are present.
NOISE_SCRIPTS_FOR_CMDLOG = {
    "dispatch.sh", "bootstrap-trace-init.sh", "common.sh",
    "bash-token-guard.sh", "bash-github-api-guard.sh",
    "git", "gh", "jq",
}
EVENTS = []
boot_start = None

print(f"Parsing {xtrace_path} ...", file=sys.stderr)

with open(xtrace_path) as f:
    for line in f:
        m = xtrace_re.match(line)
        if not m:
            continue
        ts = float(m["ts"])
        pid = int(m["pid"])
        script = m["script"]
        srcline = m.group("line") or ""
        fn = m["fn"]
        cmd = m["cmd"].strip()

        if boot_start is None or ts < boot_start:
            boot_start = ts

        if pid not in PID_FIRST:
            PID_FIRST[pid] = ts
            PID_SCRIPT[pid] = script
            PID_CMD_COUNT[pid] = 0
            PID_COMMANDS[pid] = []
        PID_LAST[pid] = ts
        PID_CMD_COUNT[pid] += 1

        # Capture command for the per-PID command log (capped). Skip the
        # noisiest internal trace plumbing so the log shows user-relevant
        # bash commands, not the trace harness's own state-shuffling.
        if (
            len(PID_COMMANDS[pid]) < COMMANDS_PER_PID_CAP
            and fn not in ("_je", "_log", "_json_escape")
            and not cmd.startswith("_VTRACE_")
            and not cmd.startswith("local ")
        ):
            PID_COMMANDS[pid].append({
                "ts": ts,
                "script": script,
                "line": srcline,
                "fn": fn,
                "cmd": cmd[:200],
            })

        # Only honor the FIRST _VTRACE_INVOCATION_TAG per PID. A long-lived
        # script (e.g. coo-identity-digest.sh that sticks around as a monitor)
        # may re-source bootstrap-trace-init later with a different tag for a
        # subshell action — we keep the first-seen script identity.
        if cmd.startswith("_VTRACE_INVOCATION_TAG=") and not PID_SCRIPT.get(f"_tag_seen_{pid}"):
            tag = cmd.split("=", 1)[1].split()[0]
            PID_SCRIPT[pid] = tag
            PID_SCRIPT[f"_tag_seen_{pid}"] = True

        # Promote script: stop reporting bootstrap-trace-init/dispatch when
        # we've already locked a real user script via TAG
        if not PID_SCRIPT.get(f"_tag_seen_{pid}"):
            if PID_SCRIPT[pid] in ("bootstrap-trace-init.sh", "common.sh", "dispatch.sh") and script not in (
                "bootstrap-trace-init.sh",
                "common.sh",
                "dispatch.sh",
            ):
                PID_SCRIPT[pid] = script

        # Capture events
        ev = None
        if fn.startswith("_write_claude_settings_"):
            ev = {"type": "write", "label": fn.replace("_write_claude_settings_", "write:")}
        elif fn.startswith("merge_coo_settings_"):
            ev = {"type": "merge", "label": fn.replace("merge_coo_settings_", "merge:")}
        elif cmd.startswith("_add "):
            parts = cmd.split(" ", 3)
            if len(parts) >= 3:
                key, ok = parts[1], parts[2]
                detail = parts[3] if len(parts) > 3 else ""
                ev = {
                    "type": "invariant-fail" if ok == "false" else ("invariant-skip" if ok == "skip" else "invariant-pass"),
                    "label": f"{key}={ok}",
                    "detail": detail,
                }
        elif fn == "ensure_gh_coo_wrap" and "0755" in cmd and "install" in cmd:
            ev = {"type": "note", "label": "gh-coo-wrap installed"}
        elif fn == "ensure_hooks_dispatch_shim" and cmd.startswith("mkdir -p"):
            ev = {"type": "note", "label": "dispatch shim setup"}
        elif fn == "MAIN" and (cmd.startswith("set -euo") or cmd.startswith("set -uo")):
            # script-entry marker
            ev = {"type": "enter", "label": f"enter {script}"}
        elif fn == "_log" and cmd.startswith("echo '[") and "BOOT DEGRADED" in cmd:
            ev = {"type": "alert", "label": "BOOT DEGRADED banner"}
        elif fn == "log" and cmd.startswith("echo '[vade-setup]"):
            # surface key vade-setup log lines
            if any(k in cmd for k in ("merged ", "marker present", "SKIP", "fresh bootstrap", "coo-bootstrap: already")):
                ev = {"type": "note", "label": cmd[5:].strip("'\"")[:80]}

        if ev is not None:
            # dedup repeated writes/merges (same pid+label keep first only)
            if ev["type"] in ("write", "merge"):
                key = (pid, ev["label"])
                if any(e.get("_key") == key for e in EVENTS):
                    continue
                ev["_key"] = key
            ev["ts"] = ts
            ev["pid"] = pid
            ev["script"] = script
            ev["line"] = srcline
            ev["fn"] = fn
            ev["cmd"] = cmd[:240]
            EVENTS.append(ev)

# Parse snapshots
SNAPSHOTS = []
snapshots_dir = os.path.join(TRACE_DIR, "snapshots")
if os.path.isdir(snapshots_dir):
    snap_re = re.compile(
        r"^(?P<ymd>\d{8})T(?P<hms>\d{6})(?P<micros>\d+)-(?P<script>.+?)-enter-(?P<pid>\d+)$"
    )
    for d in sorted(os.listdir(snapshots_dir)):
        m = snap_re.match(d)
        if not m:
            continue
        try:
            dt = datetime.datetime.strptime(
                f"{m['ymd']}{m['hms']}", "%Y%m%d%H%M%S"
            ).replace(tzinfo=datetime.timezone.utc)
            ts = dt.timestamp() + int(m["micros"]) * 1e-6
        except Exception:
            continue

        env_state = None
        try:
            s = json.load(open(os.path.join(snapshots_dir, d, "content/settings.json")))
            env = s.get("env", {}) or {}
            env_state = {
                "has_VADE_RUNTIME_DIR": "VADE_RUNTIME_DIR" in env,
                "has_VADE_COO_MEMORY_DIR": "VADE_COO_MEMORY_DIR" in env,
                "has_VADE_CLOUD_STATE_DIR": "VADE_CLOUD_STATE_DIR" in env,
                "env_keys_count": len(env),
            }
        except Exception:
            pass

        SNAPSHOTS.append(
            {"ts": ts, "script": m["script"], "pid": int(m["pid"]), "env": env_state, "dir": d}
        )

# strip sentinel keys we used internally
for k in [k for k in PID_SCRIPT if isinstance(k, str) and k.startswith("_tag_seen_")]:
    del PID_SCRIPT[k]

# ── Parent-child derivation from snapshots/*/metadata/processes.txt ───
# Each snapshot has a `ps`-style dump with columns: PID PPID PGID STAT CMD.
# Build a single map: tracked PID → (PPID, command_snippet) using the
# first-seen row per PID (parent doesn't change during a PID's lifespan in
# practice for bash-spawned children — re-parenting on session leader death
# is rare enough to ignore for the boot window we care about).
print(f"Scanning processes.txt across {len(SNAPSHOTS) if 'SNAPSHOTS' in dir() else '?'} snapshots ...", file=sys.stderr)
PID_PPID = {}      # tracked pid -> ppid (int)
PID_ALL_PPID = {}  # any pid -> ppid (used by ancestor_chain to walk past untracked intermediates)
PID_PSCMD = {}     # any pid (tracked or not) -> short ps CMD snippet
ps_row_re = re.compile(r"^\s*(?P<pid>\d+)\s+(?P<ppid>\d+)\s+\d+\s+\S+\s+(?P<cmd>.*)$")
tracked = set(PID_FIRST.keys())
snapshots_dir = os.path.join(TRACE_DIR, "snapshots")
if os.path.isdir(snapshots_dir):
    # sorted so first-seen reflects chronology
    for d in sorted(os.listdir(snapshots_dir)):
        proc_path = os.path.join(snapshots_dir, d, "metadata", "processes.txt")
        if not os.path.exists(proc_path):
            continue
        try:
            with open(proc_path) as pf:
                for ln in pf:
                    m = ps_row_re.match(ln)
                    if not m:
                        continue
                    pid_n = int(m["pid"])
                    ppid_n = int(m["ppid"])
                    cmd_str = m["cmd"].strip()
                    if pid_n not in PID_PSCMD:
                        PID_PSCMD[pid_n] = cmd_str[:160]
                    if pid_n not in PID_ALL_PPID:
                        PID_ALL_PPID[pid_n] = ppid_n
                    if pid_n in tracked and pid_n not in PID_PPID:
                        PID_PPID[pid_n] = ppid_n
        except Exception:
            continue

# Derive child lists: tracked_pid -> [tracked children]
PID_CHILDREN = {p: [] for p in tracked}
for child, parent in PID_PPID.items():
    if parent in PID_CHILDREN:
        PID_CHILDREN[parent].append(child)

def parent_label(pid):
    """Return a {pid, script, tracked} dict for the parent, or None if root."""
    ppid = PID_PPID.get(pid)
    if not ppid:
        return None
    if ppid in PID_SCRIPT:
        return {"pid": ppid, "script": PID_SCRIPT[ppid], "tracked": True}
    # Parent isn't in our xtrace (e.g. the top-level claude process, /bin/sh)
    return {"pid": ppid, "script": PID_PSCMD.get(ppid, "(unknown)")[:80], "tracked": False}

def ancestor_chain(pid, cap=8):
    """Walk PPID upward to root. Each link gets {pid, script, tracked}.
    Prefers PID_PSCMD (the ps-side ground truth from snapshots) over
    PID_SCRIPT (the xtrace view, which may be misleading under PID reuse
    — e.g. PID 2213 starts as `claude` per ps but our xtrace re-uses 2213
    for a bash subprocess much later). `tracked` is True when the PID
    also exists in our xtrace, so the click-to-jump still works."""
    chain = []
    cur = PID_ALL_PPID.get(pid)
    seen = set()
    while cur and cur not in seen and len(chain) < cap:
        seen.add(cur)
        tracked = cur in PID_SCRIPT
        if cur in PID_PSCMD:
            script_label = PID_PSCMD[cur][:80]
        elif tracked:
            script_label = PID_SCRIPT[cur]
        else:
            script_label = "(unknown)"
        chain.append({"pid": cur, "script": script_label, "tracked": tracked})
        cur = PID_ALL_PPID.get(cur)
    return chain

PIDS = sorted(PID_FIRST.keys(), key=lambda p: PID_FIRST[p])


def to_ms(ts):
    return (ts - boot_start) * 1000


data = {
    "meta": meta,
    "boot_start_epoch": boot_start,
    "duration_ms": (max(PID_LAST.values()) - boot_start) * 1000 if PID_LAST else 0,
    "pids": [
        {
            "pid": p,
            "script": PID_SCRIPT[p],
            "first_ms": to_ms(PID_FIRST[p]),
            "last_ms": to_ms(PID_LAST[p]),
            "count": PID_CMD_COUNT[p],
            "parent": parent_label(p),
            "ancestors": ancestor_chain(p),
            "children": sorted(PID_CHILDREN.get(p, [])),
            "ps_cmd": PID_PSCMD.get(p, ""),
            "commands": (
                [] if PID_SCRIPT[p] in NOISE_SCRIPTS_FOR_CMDLOG else
                [
                    {
                        "ts_ms": to_ms(c["ts"]),
                        "script": c["script"],
                        "line": c["line"],
                        "fn": c["fn"],
                        "cmd": c["cmd"],
                    }
                    for c in PID_COMMANDS.get(p, [])
                ]
            ),
            "commands_truncated": (
                PID_SCRIPT[p] not in NOISE_SCRIPTS_FOR_CMDLOG
                and PID_CMD_COUNT[p] > COMMANDS_PER_PID_CAP
            ),
        }
        for p in PIDS
    ],
    "events": [
        {
            "pid": e["pid"],
            "ts_ms": to_ms(e["ts"]),
            "type": e["type"],
            "label": e["label"],
            "script": e["script"],
            "line": e["line"],
            "fn": e["fn"],
            "cmd": e["cmd"],
            "detail": e.get("detail", ""),
        }
        for e in EVENTS
    ],
    "snapshots": [
        {
            "ts_ms": to_ms(s["ts"]),
            "script": s["script"],
            "pid": s["pid"],
            "env": s["env"],
            "dir": s["dir"],
        }
        for s in SNAPSHOTS
    ],
}

print(
    f"PIDs={len(PIDS)}  events={len(EVENTS)}  snapshots={len(SNAPSHOTS)}  "
    f"duration={data['duration_ms']:.0f}ms",
    file=sys.stderr,
)

if JSON_MODE:
    if OUTPUT == "-":
        json.dump(data, sys.stdout)
    else:
        with open(OUTPUT, "w") as f:
            json.dump(data, f)
        print(f"Wrote {OUTPUT}", file=sys.stderr)
    sys.exit(0)

run_id = escape(meta.get("run_id", "?"))
started_at = escape(meta.get("started_at", "?"))

HTML = (
    """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="theme-color" content="#1a1a1a">
<title>Bootstrap trace timeline — """ + run_id + """</title>
<style>
  :root {
    --bg: #1a1a1a;
    --panel: #232323;
    --row-alt: #1e1e1e;
    --text: #d8d8d8;
    --muted: #888;
    --border: #3a3a3a;
    --span: rgba(120,150,200,0.25);
    --span-border: rgba(180,200,240,0.5);
    --hl: #ffd35a;
  }
  * { box-sizing: border-box; }
  /* --app-vh is set by JS to window.innerHeight so we measure the
     actually-visible viewport, not the layout viewport which some iPad
     in-app WebViews (Files, Documents-by-Readdle, etc.) report as the
     full screen height even when their toolbar overlays the page. */
  html, body { margin: 0; padding: 0; height: 100%; height: var(--app-vh, 100dvh); }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, sans-serif;
    background: var(--bg);
    color: var(--text);
    font-size: 12px;
    overflow-x: hidden;
    overflow-y: auto;
    -webkit-text-size-adjust: 100%;
    -webkit-tap-highlight-color: transparent;
    padding-top: calc(env(safe-area-inset-top, 0px) + var(--manual-offset, 0px));
    padding-left: env(safe-area-inset-left, 0px);
    padding-right: env(safe-area-inset-right, 0px);
    padding-bottom: env(safe-area-inset-bottom, 0px);
    overscroll-behavior: contain;
  }
  #header {
    padding: 8px 12px;
    border-bottom: 1px solid var(--border);
    display: flex;
    gap: 16px;
    align-items: baseline;
    background: var(--panel);
    flex-shrink: 0;
    position: relative;
  }
  #header strong { color: #fff; font-weight: 600; }
  #header .meta { color: var(--muted); font-size: 11px; }
  #header .meta b { color: var(--text); font-weight: 600; }
  /* Collapse header + legend when body has [data-chrome=hidden]. Gives back
     ~70px of vertical for iPad in-app WebViews that overlay their toolbar
     across the top of the page. Toggle via the chrome button (top-right). */
  body[data-chrome="hidden"] #header,
  body[data-chrome="hidden"] #legend { display: none; }
  body[data-chrome="hidden"] #main { height: calc(var(--app-vh, 100dvh) - var(--manual-offset, 0px)); }
  #chrome-toggle, .top-fab {
    position: fixed;
    top: calc(env(safe-area-inset-top, 0px) + 6px);
    width: 32px;
    height: 32px;
    border-radius: 16px;
    border: 1px solid var(--border);
    background: rgba(40, 40, 40, 0.85);
    color: var(--text);
    font-size: 12px;
    line-height: 1;
    cursor: pointer;
    z-index: 200;
    -webkit-backdrop-filter: blur(8px);
    backdrop-filter: blur(8px);
    padding: 0;
  }
  #chrome-toggle { right: calc(env(safe-area-inset-right, 0px) + 6px); }
  #pad-down { right: calc(env(safe-area-inset-right, 0px) + 44px); }
  #pad-up   { right: calc(env(safe-area-inset-right, 0px) + 82px); }
  #chrome-toggle:active, .top-fab:active { background: rgba(60, 60, 60, 0.9); }

  #legend {
    padding: 6px 12px;
    font-size: 11px;
    color: var(--muted);
    background: var(--panel);
    border-bottom: 1px solid var(--border);
    display: flex;
    gap: 14px;
    flex-wrap: wrap;
    flex-shrink: 0;
  }
  .leg { display: inline-flex; align-items: center; gap: 4px; }
  .swatch { display: inline-block; width: 10px; height: 10px; border-radius: 2px; }

  #main {
    display: flex;
    height: calc(var(--app-vh, 100dvh) - 70px - var(--manual-offset, 0px));
    overflow: hidden;
    position: relative;
  }
  #chart-area {
    flex-grow: 1;
    overflow: hidden;
    position: relative;
    background: var(--bg);
    min-width: 0;
  }
  #detail-area {
    width: var(--detail-width, 340px);
    flex-shrink: 0;
    border-left: 1px solid var(--border);
    overflow-y: auto;
    padding: 12px;
    background: var(--panel);
    transition: transform 200ms ease-out;
    position: relative;
  }
  #detail-resize {
    position: absolute;
    left: -4px;
    top: 0;
    bottom: 0;
    width: 8px;
    cursor: ew-resize;
    z-index: 71;
    background: transparent;
    /* invisible by default; show a hairline on hover */
  }
  #detail-resize:hover, #detail-resize.dragging { background: rgba(255, 211, 90, 0.4); }
  /* Hide resize handle on narrow viewports — sidebar is overlay, not flex column */
  @media (max-width: 900px) { #detail-resize { display: none; } }
  #detail-close {
    display: none;
    position: absolute;
    top: 6px;
    right: 6px;
    width: 36px;
    height: 36px;
    border: 1px solid var(--border);
    background: #1a1a1a;
    color: var(--text);
    border-radius: 18px;
    font-size: 18px;
    line-height: 1;
    cursor: pointer;
    z-index: 60;
  }
  #detail-close:active { background: #333; }
  /* Narrow-window: detail panel becomes slide-in overlay from right */
  @media (max-width: 900px) {
    #detail-area {
      position: absolute;
      top: 0;
      right: 0;
      bottom: 0;
      width: min(420px, 88vw);
      transform: translateX(105%);
      box-shadow: -8px 0 24px rgba(0,0,0,0.45);
      z-index: 70;
    }
    #detail-area.open {
      transform: translateX(0);
    }
    #detail-close { display: block; }
    #legend .leg { font-size: 12px; }
    #legend .leg.hint { display: none; }
  }
  @media (max-width: 600px) {
    #header { gap: 6px; padding: 6px 8px; font-size: 12px; }
    #header .meta { font-size: 10px; }
    #legend { padding: 6px 8px; gap: 8px; }
  }
  #detail-area h3 { margin: 0 0 8px 0; font-size: 12px; color: var(--hl); }
  #detail-area dl { margin: 0; }
  #detail-area dt { color: var(--muted); font-size: 10px; margin-top: 6px; }
  #detail-area dd { margin: 2px 0 0 0; font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 11px; overflow-wrap: anywhere; word-break: normal; }
  #detail-area .anc-list { display: flex; flex-direction: column; gap: 3px; margin-top: 4px; }
  #detail-area .anc-row { background: rgba(255,255,255,0.04); border-left: 2px solid rgba(255,255,255,0.2); padding: 4px 8px; border-radius: 3px; font-size: 11px; line-height: 1.35; }
  #detail-area .anc-row .anc-pid { color: var(--muted); font-size: 10px; font-family: ui-monospace, "SF Mono", Menlo, monospace; margin-right: 6px; }
  #detail-area .anc-row .anc-script { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 10px; overflow-wrap: anywhere; }
  #detail-area .anc-row.tracked .anc-script { cursor: pointer; text-decoration: underline dotted; text-underline-offset: 2px; }
  #detail-area .anc-row.untracked { border-left-color: rgba(255,255,255,0.08); opacity: 0.85; }
  #detail-area .anc-arrow { color: var(--muted); margin-right: 4px; }
  #detail-area .children-list { display: flex; flex-direction: column; gap: 3px; }
  #detail-area .children-list .pid-link { padding: 3px 6px; background: rgba(255,255,255,0.03); border-radius: 3px; display: inline-block; }
  #detail-area .hint { color: var(--muted); font-size: 11px; }
  /* Per-PID command log block */
  #detail-area details.cmd-log { margin-top: 12px; border-top: 1px solid var(--border); padding-top: 8px; }
  #detail-area details.cmd-log summary { cursor: pointer; color: var(--hl); font-size: 11px; margin-bottom: 6px; user-select: none; }
  #detail-area .cmd-list { display: flex; flex-direction: column; gap: 6px; max-height: 50vh; overflow-y: auto; }
  #detail-area .cmd-row { background: rgba(255,255,255,0.03); padding: 4px 6px; border-radius: 3px; border-left: 2px solid rgba(255,255,255,0.1); }
  #detail-area .cmd-row .cmd-ts { color: var(--muted); font-size: 10px; margin-right: 8px; }
  #detail-area .cmd-row .cmd-loc { color: var(--muted); font-size: 10px; }
  #detail-area .cmd-row .cmd-text { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 10px; margin-top: 2px; white-space: pre-wrap; word-break: break-word; color: var(--text); }
  #detail-area .cmd-trunc { color: var(--muted); font-size: 10px; font-style: italic; padding: 4px 0; }
  #detail-area .pid-link:active { opacity: 0.7; }

  #chart-scroll {
    position: absolute;
    inset: 0;
    overflow-x: auto;
    overflow-y: auto;
    -webkit-overflow-scrolling: touch;
    touch-action: pan-x pan-y;
    overscroll-behavior: contain;
  }
  #chart-inner {
    position: relative;
    height: 100%;
    min-height: 100%;
  }

  #axis {
    position: sticky;
    top: 0;
    height: 26px;
    background: var(--panel);
    border-bottom: 1px solid var(--border);
    z-index: 10;
  }
  .axis-tick {
    position: absolute;
    top: 0;
    bottom: 0;
    padding-left: 4px;
    font-size: 10px;
    color: var(--muted);
    border-left: 1px solid var(--border);
  }

  .labels {
    position: sticky;
    left: 0;
    z-index: 9;
    width: var(--label-width, 260px);
    background: var(--panel);
    border-right: 1px solid var(--border);
  }

  .row {
    position: relative;
    height: 22px;
    border-bottom: 1px solid rgba(255,255,255,0.04);
    white-space: nowrap;
  }
  .row.alt { background: var(--row-alt); }
  .row .label {
    position: absolute;
    left: 0;
    top: 0;
    bottom: 0;
    width: var(--label-width, 260px);
    padding: 3px 8px;
    background: var(--panel);
    border-right: 1px solid var(--border);
    overflow: hidden;
    text-overflow: ellipsis;
    z-index: 5;
    font-size: 11px;
  }
  .row .label .pid { color: var(--muted); margin-right: 6px; }
  .row .lane {
    position: absolute;
    left: var(--label-width, 260px);
    top: 0;
    bottom: 0;
  }
  @media (max-width: 900px) {
    :root { --label-width: 160px; }
  }
  @media (max-width: 600px) {
    :root { --label-width: 130px; }
    .row .label { font-size: 10px; padding: 3px 4px; }
    .row .label .pid { margin-right: 3px; }
  }
  .span {
    position: absolute;
    top: 4px;
    bottom: 4px;
    background: var(--span);
    border: 1px solid var(--span-border);
    border-radius: 2px;
    pointer-events: auto;
  }
  .span:hover { background: rgba(120,150,200,0.4); }
  .event {
    position: absolute;
    top: 3px;
    width: 5px;
    height: 16px;
    border-radius: 1px;
    cursor: pointer;
    transform: translateX(-2px);
    /* enlarge invisible hit area for touch without enlarging visual */
    box-shadow: 0 0 0 0 transparent;
  }
  .event::after {
    content: "";
    position: absolute;
    top: -8px;
    bottom: -8px;
    left: -6px;
    right: -6px;
    /* invisible touch target */
  }
  .event:hover { outline: 2px solid var(--hl); z-index: 6; }
  .event.selected { outline: 2px solid var(--hl); outline-offset: 1px; z-index: 7; }
  .event.write { background: #ff9c2a; width: 6px; }
  .event.merge { background: #4aa8ff; }
  .event.invariant-pass { background: #4ad06a; }
  .event.invariant-fail { background: #ff4a4a; width: 7px; box-shadow: 0 0 6px rgba(255,74,74,0.6); }
  .event.invariant-skip { background: #888; }
  .event.note { background: #c0c0c0; opacity: 0.65; width: 3px; }
  .event.enter { background: #c084fc; width: 2px; }
  .event.alert { background: #ff4a4a; width: 8px; }

  .snap-line {
    position: absolute;
    top: 0;
    bottom: 0;
    width: 0;
    border-left: 1px dashed rgba(200,200,200,0.25);
    pointer-events: none;
    z-index: 2;
  }
  .snap-line.has-rt { border-color: rgba(74,208,106,0.55); }
  .snap-line.no-rt { border-color: rgba(255,74,74,0.5); }
  .snap-line .marker {
    position: absolute;
    top: -4px;
    left: -6px;
    width: 12px;
    height: 12px;
    background: inherit;
    pointer-events: auto;
    cursor: pointer;
  }
  .snap-line.has-rt .marker { background: #4ad06a; border-radius: 50%; }
  .snap-line.no-rt .marker { background: #ff4a4a; border-radius: 50%; box-shadow: 0 0 4px rgba(255,74,74,0.5); }
  .snap-line .marker::after {
    content: "";
    position: absolute;
    inset: -10px;
  }

  #tooltip {
    position: fixed;
    background: #0b0b0b;
    border: 1px solid #555;
    padding: 6px 9px;
    font-size: 11px;
    pointer-events: none;
    max-width: 380px;
    z-index: 100;
    border-radius: 4px;
    display: none;
    box-shadow: 0 6px 24px rgba(0,0,0,0.6);
    line-height: 1.4;
  }

  #controls {
    position: absolute;
    right: 10px;
    bottom: 10px;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 8px 10px;
    display: flex;
    gap: 10px;
    z-index: 50;
    align-items: center;
    font-size: 12px;
    flex-wrap: wrap;
    max-width: calc(100vw - 24px);
  }
  #controls button {
    background: #333;
    color: var(--text);
    border: 1px solid #555;
    padding: 8px 14px;
    cursor: pointer;
    border-radius: 5px;
    font-size: 13px;
    min-height: 36px;
    min-width: 44px;
  }
  #controls button:hover { background: #444; }
  #controls button:active { background: #555; }
  #controls button.active { background: #2a5e8e; border-color: #4a8edb; }
  #controls input[type=range] { width: 160px; height: 32px; }
  #controls input[type=range]::-webkit-slider-thumb { width: 22px; height: 22px; }
  #controls input[type=text] {
    background: #1a1a1a; color: var(--text); border: 1px solid #555;
    padding: 8px 10px; font-size: 13px; border-radius: 5px; width: 140px;
    min-height: 36px;
  }
  #controls label {
    display: inline-flex; align-items: center; gap: 6px; cursor: pointer;
    min-height: 36px;
    padding: 0 4px;
  }
  #controls input[type=checkbox] { width: 18px; height: 18px; }
  #controls .group { display: inline-flex; align-items: center; gap: 6px; }
  #controls-toggle {
    display: none;
    position: absolute;
    right: 10px;
    bottom: 10px;
    width: 48px;
    height: 48px;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 24px;
    color: var(--text);
    font-size: 22px;
    z-index: 51;
    cursor: pointer;
    box-shadow: 0 4px 14px rgba(0,0,0,0.5);
  }
  @media (max-width: 900px) {
    #controls {
      left: 10px;
      right: 10px;
      bottom: 64px;
      flex-direction: column;
      align-items: stretch;
      gap: 8px;
      max-height: 60vh;
      overflow-y: auto;
      display: none;
    }
    #controls.open { display: flex; }
    #controls .group { justify-content: space-between; flex-wrap: wrap; }
    #controls input[type=range] { width: 100%; flex-grow: 1; }
    #controls input[type=text] { width: 100%; flex-grow: 1; }
    #controls-toggle { display: flex; align-items: center; justify-content: center; }
  }

  #stage-bg {
    position: absolute;
    left: var(--label-width, 260px);
    top: 26px;
    bottom: 0;
    z-index: 1;
    pointer-events: none;
  }
  /* Tree-view connector overlay (parent → child lines) */
  #tree-connectors {
    position: absolute;
    pointer-events: none;
    z-index: 3;
    top: 0;
    left: 0;
    overflow: visible;
  }
  #tree-connectors path { fill: none; stroke-width: 1.5; }
  /* Tree-view label indent (depth) */
  .row.tree-depth-1 .label { padding-left: 16px; }
  .row.tree-depth-2 .label { padding-left: 24px; }
  .row.tree-depth-3 .label { padding-left: 32px; }
  .row.tree-depth-4 .label { padding-left: 40px; }
  .row.tree-depth-5 .label { padding-left: 48px; }
  .row.tree-depth-6 .label { padding-left: 56px; }
  .row.tree-depth-7 .label { padding-left: 64px; }
  .row.tree-depth-8 .label { padding-left: 72px; }
  /* Tiny tree marker before the label name */
  .row[class*="tree-depth-"] .label::before {
    content: "↳ ";
    color: var(--muted);
    margin-left: -8px;
  }
  .row.tree-depth-0 .label::before { content: none; }
</style>
</head>
<body>
<button id="pad-up" class="top-fab" aria-label="Shrink top padding" title="Decrease top offset (▲)">▲</button>
<button id="pad-down" class="top-fab" aria-label="Grow top padding" title="Increase top offset (▼) — push content down past an overlapping app toolbar">▼</button>
<button id="chrome-toggle" aria-label="Toggle header" title="Hide/show header — claim ~70px of vertical space if your viewer is cutting off the top">⇕</button>
<div id="header">
  <strong>Bootstrap trace timeline</strong>
  <span class="meta">
    <b>""" + run_id + """</b> &middot;
    started <b>""" + started_at + """</b> &middot;
    duration <b id="meta-duration">…</b> &middot;
    <b id="meta-procs">…</b> processes &middot;
    <b id="meta-events">…</b> events &middot;
    <b id="meta-snaps">…</b> snapshots
  </span>
</div>
<div id="legend">
  <span class="leg"><span class="swatch" style="background:#ff9c2a"></span> file write</span>
  <span class="leg"><span class="swatch" style="background:#4aa8ff"></span> merge wrapper</span>
  <span class="leg"><span class="swatch" style="background:#4ad06a"></span> invariant pass</span>
  <span class="leg"><span class="swatch" style="background:#ff4a4a"></span> invariant fail</span>
  <span class="leg"><span class="swatch" style="background:#888"></span> invariant skip</span>
  <span class="leg"><span class="swatch" style="background:#c084fc"></span> script entry</span>
  <span class="leg"><span class="swatch" style="background:#c0c0c0"></span> log/note</span>
  <span class="leg"><span class="swatch" style="background:#4ad06a;border-radius:50%"></span> snapshot (VADE_RUNTIME_DIR present)</span>
  <span class="leg"><span class="swatch" style="background:#ff4a4a;border-radius:50%"></span> snapshot (missing)</span>
  <span class="leg hint" id="hint-text" style="margin-left:auto">scroll = pan · ⌘/Ctrl+scroll = zoom · click event/snapshot for detail</span>
</div>
<div id="main">
  <div id="chart-area">
    <div id="chart-scroll">
      <div id="chart-inner">
        <div id="axis"></div>
        <div id="rows"></div>
      </div>
    </div>
    <button id="controls-toggle" aria-label="Toggle controls">⚙</button>
    <div id="controls">
      <div class="group"><span>view</span>
        <button id="view-rows" class="active">rows</button>
        <button id="view-tree">tree</button>
      </div>
      <div class="group"><span>zoom</span>
        <input type="range" id="zoom" min="0.05" max="30" step="0.05" value="1">
      </div>
      <div class="group">
        <button id="fit">fit window</button>
        <button id="boot-zoom">boot (0–5s)</button>
      </div>
      <div class="group"><span>filter</span>
        <input type="text" id="filter" placeholder="script name…">
      </div>
      <div class="group">
        <label><input type="checkbox" id="hide-noise" checked> hide wrappers</label>
        <label><input type="checkbox" id="boot-only" checked> boot window only</label>
      </div>
    </div>
  </div>
  <div id="detail-area">
    <div id="detail-resize" aria-label="Resize panel"></div>
    <button id="detail-close" aria-label="Close detail">×</button>
    <h3 id="detail-title">Detail</h3>
    <div id="detail-body" class="hint">
      <span class="touch-hint" style="display:none">Tap an event or snapshot to inspect it. Pinch to zoom, drag to pan.</span>
      <span class="mouse-hint">Click an event or snapshot to inspect it. Scroll the chart with the trackpad/wheel. Hold ⌘ or Ctrl + scroll to zoom.</span>
    </div>
  </div>
</div>
<div id="tooltip"></div>
<script>
const DATA = """ + json.dumps(data) + """;
"""
    + r"""
const TARGETS = {
  ROW_HEIGHT: 22,
  AXIS_HEIGHT: 26,
  LABEL_WIDTH: 260,
  MIN_PX_PER_MS: 0.05,
  MAX_PX_PER_MS: 30,
};
// Resolve the actual label width from the CSS --label-width variable, which
// changes via @media queries. Recompute on resize.
function getLabelWidth() {
  const v = getComputedStyle(document.documentElement).getPropertyValue("--label-width").trim();
  if (v.endsWith("px")) return parseInt(v, 10);
  return TARGETS.LABEL_WIDTH;
}

const IS_TOUCH = (("ontouchstart" in window) || (navigator.maxTouchPoints > 0));

// Set --app-vh to the actually-visible viewport height. Fixes iPad in-app
// WebViews (Files app, Documents-by-Readdle, etc.) where 100dvh reports the
// full screen behind the app's toolbar overlay, hiding our header.
// Prefer visualViewport.height when present — it excludes overlaid chrome in
// most modern iOS/iPadOS WebViews. Fall back to innerHeight.
function syncAppVh() {
  const h = (window.visualViewport && window.visualViewport.height) || window.innerHeight;
  document.documentElement.style.setProperty("--app-vh", h + "px");
}
syncAppVh();
window.addEventListener("resize", syncAppVh);
window.addEventListener("orientationchange", syncAppVh);
if (window.visualViewport) {
  window.visualViewport.addEventListener("resize", syncAppVh);
  window.visualViewport.addEventListener("scroll", syncAppVh);
}

let pxPerMs = 0.5;
const chartInner = document.getElementById("chart-inner");
const rowsHost = document.getElementById("rows");
const axisHost = document.getElementById("axis");
const scroll = document.getElementById("chart-scroll");
const tooltip = document.getElementById("tooltip");
const detailArea = document.getElementById("detail-area");
const detailClose = document.getElementById("detail-close");
const controlsEl = document.getElementById("controls");
const controlsToggle = document.getElementById("controls-toggle");

// resolve a script color by name
function scriptColor(script) {
  const key = (script || "").toLowerCase();
  if (key.includes("session-start-sync")) return "#4aa8ff";
  if (key.includes("integrity-check")) return "#ff4a4a";
  if (key.includes("coo-bootstrap")) return "#4ad06a";
  if (key.includes("coo-identity-digest")) return "#ff9c2a";
  if (key.includes("memo-index")) return "#c084fc";
  if (key.includes("session-lifecycle")) return "#ffd35a";
  if (key.includes("session-idle")) return "#aaa";
  if (key.includes("discussions-digest")) return "#22d3ee";
  if (key.includes("bash-")) return "#7f8c8d";
  if (key.includes("dispatch")) return "#677";
  return "#999";
}

function setMeta() {
  document.getElementById("meta-duration").textContent = `${DATA.duration_ms.toFixed(0)} ms`;
  document.getElementById("meta-procs").textContent = DATA.pids.length;
  document.getElementById("meta-events").textContent = DATA.events.length;
  document.getElementById("meta-snaps").textContent = DATA.snapshots.length;
}

const BOOT_WINDOW_MS = 22000;
const NOISE_SCRIPTS = new Set(["dispatch.sh", "bootstrap-trace-init.sh"]);
function isNoisePid(p) {
  if (NOISE_SCRIPTS.has(p.script)) return true;
  // brief git subprocesses are integrity-check children; skip when many
  if (p.script === "git" && p.count < 100) return true;
  if (p.script === "bash-github-api-guard.sh") return true;
  if (p.script === "bash-token-guard.sh") return true;
  return false;
}

function baseVisiblePids() {
  const filterTxt = (document.getElementById("filter").value || "").toLowerCase();
  const hideNoise = document.getElementById("hide-noise").checked;
  const bootOnly = document.getElementById("boot-only").checked;
  return DATA.pids.filter(p => {
    if (bootOnly && p.first_ms >= BOOT_WINDOW_MS) return false;
    if (hideNoise && isNoisePid(p)) return false;
    if (filterTxt && !(`${p.pid} ${p.script}`.toLowerCase().includes(filterTxt))) return false;
    return true;
  });
}

// Tree-view layout: preorder traversal of the visible subset. Each visible
// PID gets a depth (parent's depth + 1 within the visible set), and the
// order is DFS from earliest root through descendants. Returns
// {pids: [...visiblePidsInTreeOrder], depthByPid: Map<pid, depth>,
//  parentInView: Map<pid, parentPid>}.
function treeOrderedPids() {
  const base = baseVisiblePids();
  const baseSet = new Set(base.map(p => p.pid));
  // For each visible PID, find its nearest visible ancestor by walking ancestor chain
  const parentInView = new Map();
  for (const p of base) {
    if (!p.ancestors) continue;
    for (const a of p.ancestors) {
      if (baseSet.has(a.pid)) {
        parentInView.set(p.pid, a.pid);
        break;
      }
    }
  }
  // Build children adjacency from parentInView
  const childMap = new Map();
  for (const [child, parent] of parentInView.entries()) {
    if (!childMap.has(parent)) childMap.set(parent, []);
    childMap.get(parent).push(child);
  }
  // Sort children of each parent by first_ms (earliest spawn first)
  const pidById = new Map(base.map(p => [p.pid, p]));
  for (const kids of childMap.values()) {
    kids.sort((a, b) => pidById.get(a).first_ms - pidById.get(b).first_ms);
  }
  // Roots: visible PIDs without a parent in the visible set
  const roots = base
    .filter(p => !parentInView.has(p.pid))
    .sort((a, b) => a.first_ms - b.first_ms);
  // DFS preorder
  const pids = [];
  const depthByPid = new Map();
  const seen = new Set();
  function visit(pid, depth) {
    if (seen.has(pid)) return;
    seen.add(pid);
    const p = pidById.get(pid);
    if (!p) return;
    pids.push(p);
    depthByPid.set(pid, depth);
    for (const c of (childMap.get(pid) || [])) {
      visit(c, depth + 1);
    }
  }
  for (const r of roots) visit(r.pid, 0);
  // Safety: any visible PID we missed (cycles, weird data) — append at depth 0
  for (const p of base) {
    if (!seen.has(p.pid)) {
      pids.push(p);
      depthByPid.set(p.pid, 0);
    }
  }
  return { pids, depthByPid, parentInView };
}

let viewMode = "rows"; // "rows" | "tree"

function visiblePids() {
  if (viewMode === "tree") {
    return treeOrderedPids().pids;
  }
  return baseVisiblePids();
}

function effectiveDurationMs() {
  if (document.getElementById("boot-only").checked) return BOOT_WINDOW_MS;
  return DATA.duration_ms;
}

function render() {
  rowsHost.innerHTML = "";
  axisHost.innerHTML = "";
  // also clear any old snap-lines + connectors
  chartInner.querySelectorAll(".snap-line, #tree-connectors").forEach(n => n.remove());

  const labelWidth = getLabelWidth();
  // Compute pids + (if tree mode) depth + parent-in-view map
  let pids, depthByPid = null, parentInView = null;
  if (viewMode === "tree") {
    const t = treeOrderedPids();
    pids = t.pids;
    depthByPid = t.depthByPid;
    parentInView = t.parentInView;
  } else {
    pids = baseVisiblePids();
  }
  const totalMs = effectiveDurationMs();
  const chartWidth = labelWidth + totalMs * pxPerMs + 60;
  chartInner.style.width = `${chartWidth}px`;
  chartInner.style.height = `${TARGETS.AXIS_HEIGHT + pids.length * TARGETS.ROW_HEIGHT + 40}px`;

  // axis
  const tickStep = pickTickStep(pxPerMs);
  axisHost.style.width = `${chartWidth}px`;
  for (let t = 0; t <= totalMs; t += tickStep) {
    const tick = document.createElement("div");
    tick.className = "axis-tick";
    tick.style.left = `${labelWidth + t * pxPerMs}px`;
    tick.textContent = formatMs(t);
    axisHost.appendChild(tick);
  }

  // rows
  const eventsByPid = new Map();
  for (const ev of DATA.events) {
    if (!eventsByPid.has(ev.pid)) eventsByPid.set(ev.pid, []);
    eventsByPid.get(ev.pid).push(ev);
  }

  const rowIndexByPid = new Map();
  pids.forEach((p, idx) => {
    rowIndexByPid.set(p.pid, idx);
    const row = document.createElement("div");
    let cls = "row" + (idx % 2 ? " alt" : "");
    if (depthByPid) {
      const d = Math.min(8, depthByPid.get(p.pid) || 0);
      cls += ` tree-depth-${d}`;
    }
    row.className = cls;
    row.style.top = `${idx * TARGETS.ROW_HEIGHT}px`;
    row.style.position = "absolute";
    row.style.left = "0";
    row.style.width = `${chartWidth}px`;

    const label = document.createElement("div");
    label.className = "label";
    label.title = `${p.script} (PID ${p.pid}) — ${p.count} commands`;
    label.innerHTML = `<span class="pid">${p.pid}</span><span style="color:${scriptColor(p.script)}">${escapeHtml(p.script)}</span>`;
    row.appendChild(label);

    const lane = document.createElement("div");
    lane.className = "lane";
    lane.style.left = `${labelWidth}px`;
    lane.style.width = `${DATA.duration_ms * pxPerMs + 60}px`;

    const span = document.createElement("div");
    span.className = "span";
    const startX = p.first_ms * pxPerMs;
    const widthX = Math.max(2, (p.last_ms - p.first_ms) * pxPerMs);
    span.style.left = `${startX}px`;
    span.style.width = `${widthX}px`;
    span.style.borderColor = scriptColor(p.script);
    span.title = `${p.script} (PID ${p.pid}) — ${formatMs(p.first_ms)} → ${formatMs(p.last_ms)} (${(p.last_ms - p.first_ms).toFixed(1)} ms, ${p.count} commands)`;
    span.addEventListener("click", () => showProcDetail(p));
    span.addEventListener("mouseenter", e => showTooltip(e, `PID ${p.pid} · ${p.script}<br>${formatMs(p.first_ms)} → ${formatMs(p.last_ms)} (${(p.last_ms - p.first_ms).toFixed(1)} ms)<br>${p.count} commands`));
    span.addEventListener("mousemove", moveTooltip);
    span.addEventListener("mouseleave", hideTooltip);
    lane.appendChild(span);

    const evs = eventsByPid.get(p.pid) || [];
    for (const ev of evs) {
      const dot = document.createElement("div");
      dot.className = `event ${ev.type}`;
      dot.style.left = `${ev.ts_ms * pxPerMs}px`;
      dot.title = `${ev.label} @ ${formatMs(ev.ts_ms)}`;
      dot.addEventListener("click", e => { e.stopPropagation(); showEventDetail(ev, p); });
      dot.addEventListener("mouseenter", e =>
        showTooltip(e, `<b>${escapeHtml(ev.label)}</b><br>${formatMs(ev.ts_ms)} · PID ${ev.pid}<br>${escapeHtml(ev.script)}:${ev.line || "?"} fn=${escapeHtml(ev.fn)}` + (ev.detail ? `<br><i>${escapeHtml(ev.detail.slice(0,160))}</i>` : ""))
      );
      dot.addEventListener("mousemove", moveTooltip);
      dot.addEventListener("mouseleave", hideTooltip);
      lane.appendChild(dot);
    }

    row.appendChild(lane);
    rowsHost.appendChild(row);
  });

  // tree-mode connectors: SVG paths from parent → child at the spawn x
  if (viewMode === "tree" && parentInView && parentInView.size > 0) {
    const SVG_NS = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(SVG_NS, "svg");
    svg.id = "tree-connectors";
    svg.setAttribute("width", String(chartWidth));
    svg.setAttribute("height", String(pids.length * TARGETS.ROW_HEIGHT));
    svg.style.top = `${TARGETS.AXIS_HEIGHT}px`;
    svg.style.left = "0";
    for (const [childPid, parentPid] of parentInView.entries()) {
      const childIdx = rowIndexByPid.get(childPid);
      const parentIdx = rowIndexByPid.get(parentPid);
      const child = pids[childIdx];
      const parent = pids[parentIdx];
      if (!child || !parent) continue;
      const x = labelWidth + child.first_ms * pxPerMs;
      const py = parentIdx * TARGETS.ROW_HEIGHT + TARGETS.ROW_HEIGHT / 2;
      const cy = childIdx * TARGETS.ROW_HEIGHT + TARGETS.ROW_HEIGHT / 2;
      // L-shape: down from parent's bar (slight curve at the corner)
      // Path: M (x-6, py) → curve to (x, py+8) → vertical down to (x, cy-2) → curve right
      const path = document.createElementNS(SVG_NS, "path");
      const r = 6; // corner radius
      const dy = cy - py;
      const dir = dy >= 0 ? 1 : -1;
      const d = [
        `M ${x - 12} ${py}`,
        `L ${x - r} ${py}`,
        `Q ${x} ${py} ${x} ${py + r * dir}`,
        `L ${x} ${cy - r * dir}`,
        `Q ${x} ${cy} ${x + r} ${cy}`,
        `L ${x + 4} ${cy}`,
      ].join(" ");
      path.setAttribute("d", d);
      path.setAttribute("stroke", scriptColor(parent.script));
      path.setAttribute("opacity", "0.45");
      svg.appendChild(path);
      // Small arrowhead at child end (a tiny triangle pointing right)
      const arrow = document.createElementNS(SVG_NS, "polygon");
      arrow.setAttribute("points", `${x + 4},${cy - 3} ${x + 9},${cy} ${x + 4},${cy + 3}`);
      arrow.setAttribute("fill", scriptColor(parent.script));
      arrow.setAttribute("opacity", "0.55");
      svg.appendChild(arrow);
    }
    chartInner.appendChild(svg);
  }

  // overlay snapshots as vertical lines
  rowsHost.style.position = "absolute";
  rowsHost.style.top = `${TARGETS.AXIS_HEIGHT}px`;
  rowsHost.style.left = "0";
  rowsHost.style.right = "0";
  rowsHost.style.height = `${pids.length * TARGETS.ROW_HEIGHT}px`;

  const bootOnly = document.getElementById("boot-only").checked;
  for (const snap of DATA.snapshots) {
    if (bootOnly && snap.ts_ms >= BOOT_WINDOW_MS) continue;
    const line = document.createElement("div");
    const present = snap.env && snap.env.has_VADE_RUNTIME_DIR;
    line.className = "snap-line " + (snap.env ? (present ? "has-rt" : "no-rt") : "");
    line.style.left = `${labelWidth + snap.ts_ms * pxPerMs}px`;
    line.style.top = `${TARGETS.AXIS_HEIGHT}px`;
    line.style.height = `${pids.length * TARGETS.ROW_HEIGHT}px`;
    const marker = document.createElement("div");
    marker.className = "marker";
    marker.addEventListener("click", e => { e.stopPropagation(); showSnapDetail(snap); });
    marker.addEventListener("mouseenter", e => showTooltip(e, snapTooltip(snap)));
    marker.addEventListener("mousemove", moveTooltip);
    marker.addEventListener("mouseleave", hideTooltip);
    line.appendChild(marker);
    chartInner.appendChild(line);
  }
}

function snapTooltip(s) {
  const e = s.env || {};
  return `<b>snapshot</b> @ ${formatMs(s.ts_ms)}<br>${escapeHtml(s.script)}-enter (BASHPID ${s.pid})<br>settings.json env keys: ${e.env_keys_count ?? "?"}<br>VADE_RUNTIME_DIR: <b style="color:${e.has_VADE_RUNTIME_DIR ? '#4ad06a' : '#ff4a4a'}">${e.has_VADE_RUNTIME_DIR ? "present" : "missing"}</b><br>VADE_COO_MEMORY_DIR: ${e.has_VADE_COO_MEMORY_DIR ? "present" : "missing"}<br>VADE_CLOUD_STATE_DIR: ${e.has_VADE_CLOUD_STATE_DIR ? "present" : "missing"}`;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
}

function formatMs(ms) {
  if (ms < 1000) return ms.toFixed(0) + " ms";
  return (ms / 1000).toFixed(2) + " s";
}

function pickTickStep(pxPerMs) {
  // pick tick spacing so labels are ~80px apart
  const targetPx = 80;
  const stepMs = targetPx / pxPerMs;
  const candidates = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 30000, 60000];
  for (const c of candidates) if (c >= stepMs) return c;
  return candidates[candidates.length - 1];
}

function showTooltip(e, html) {
  tooltip.innerHTML = html;
  tooltip.style.display = "block";
  moveTooltip(e);
}
function moveTooltip(e) {
  const padding = 12;
  let x = e.clientX + padding;
  let y = e.clientY + padding;
  const tw = tooltip.offsetWidth;
  const th = tooltip.offsetHeight;
  if (x + tw > window.innerWidth) x = e.clientX - padding - tw;
  if (y + th > window.innerHeight) y = e.clientY - padding - th;
  tooltip.style.left = `${x}px`;
  tooltip.style.top = `${y}px`;
}
function hideTooltip() { tooltip.style.display = "none"; }

// Lookup helper: find a PID's full record by pid number
function findPid(pidNum) {
  return DATA.pids.find(p => p.pid === pidNum);
}

// Jump to a PID: scroll its row into view, highlight, populate detail
function jumpToPid(pidNum) {
  const target = findPid(pidNum);
  if (target) {
    showProcDetail(target);
    // Scroll the chart vertically so the target row is in view
    const visible = visiblePids();
    const idx = visible.findIndex(p => p.pid === pidNum);
    if (idx >= 0) {
      scroll.scrollTop = Math.max(0, idx * TARGETS.ROW_HEIGHT - 80);
    } else {
      // Not in current view (filtered out) — surface a note
      const body = document.getElementById("detail-body");
      const note = document.createElement("div");
      note.style.color = "var(--muted)";
      note.style.marginTop = "8px";
      note.style.fontSize = "10px";
      note.textContent = "(this PID is filtered out of the current view — toggle hide-wrappers or boot-only to see its row)";
      body.appendChild(note);
    }
  }
}

function pidLinkHtml(linkObj) {
  // linkObj: {pid, script, tracked} from parent_label OR {pid} from a bare child
  if (!linkObj) return "<i>none (process root)</i>";
  const tracked = linkObj.tracked !== false && findPid(linkObj.pid);
  const colorStyle = tracked ? `color:${scriptColor(linkObj.script)}` : `color:var(--muted)`;
  const cls = tracked ? "pid-link" : "pid-link-untracked";
  const label = linkObj.script ? `${linkObj.pid} · ${escapeHtml(linkObj.script)}` : `${linkObj.pid}`;
  if (tracked) {
    return `<a href="#" class="${cls}" data-pid="${linkObj.pid}" style="${colorStyle}; text-decoration: underline dotted; cursor: pointer">${label}</a>`;
  }
  return `<span style="${colorStyle}">${label}</span>`;
}

function showProcDetail(p) {
  const title = document.getElementById("detail-title");
  const body = document.getElementById("detail-body");
  title.textContent = `Process · PID ${p.pid}`;
  body.classList.remove("hint");

  // Build ancestor chain as readable cards (root → immediate parent)
  let ancestorsHtml;
  if (!p.ancestors || p.ancestors.length === 0) {
    ancestorsHtml = "<i>none (process root)</i>";
  } else {
    // Reverse so the most distant ancestor is at the top
    const reversed = [...p.ancestors].reverse();
    ancestorsHtml = '<div class="anc-list">' + reversed.map((a, i) => {
      const tracked = a.tracked && findPid(a.pid);
      const cls = tracked ? "tracked" : "untracked";
      const arrow = i > 0 ? '<span class="anc-arrow">↳</span>' : '';
      const color = tracked ? `color:${scriptColor(a.script)}` : `color:var(--muted)`;
      const clickAttr = tracked ? ` data-pid="${a.pid}"` : "";
      return `<div class="anc-row ${cls}"${clickAttr}>
        ${arrow}<span class="anc-pid">PID ${a.pid}</span><span class="anc-script" style="${color}">${escapeHtml(a.script)}</span>
      </div>`;
    }).join("") + '</div>';
  }

  // Build children block (tracked only) — use vertical card stack
  let childrenHtml;
  if (!p.children || p.children.length === 0) {
    childrenHtml = "<i>none</i>";
  } else {
    childrenHtml = '<div class="children-list">' + p.children.map(cpid => {
      const c = findPid(cpid);
      return pidLinkHtml(c ? {pid: c.pid, script: c.script, tracked: true} : {pid: cpid, script: "(not traced)", tracked: false});
    }).join("") + '</div>';
  }

  // Build command log
  let cmdLogHtml = "";
  if (p.commands && p.commands.length > 0) {
    const rows = p.commands.map(c => `
      <div class="cmd-row">
        <span class="cmd-ts">${formatMs(c.ts_ms)}</span>
        <span class="cmd-loc">${escapeHtml(c.script)}${c.line ? ":" + c.line : ""}${c.fn !== "MAIN" ? " · " + escapeHtml(c.fn) : ""}</span>
        <div class="cmd-text">${escapeHtml(c.cmd)}</div>
      </div>
    `).join("");
    const truncNote = p.commands_truncated
      ? `<div class="cmd-trunc">… showing first ${p.commands.length} of ${p.count} commands (rest elided to keep file size bounded)</div>`
      : "";
    cmdLogHtml = `
      <details class="cmd-log" open>
        <summary>command log (${p.commands.length}${p.commands_truncated ? "/" + p.count : ""})</summary>
        <div class="cmd-list">${rows}${truncNote}</div>
      </details>
    `;
  } else {
    cmdLogHtml = `<details class="cmd-log"><summary>command log</summary><div class="hint" style="padding:6px 0">No commands captured (PID was a brief subprocess with only noise commands).</div></details>`;
  }

  body.innerHTML = `<dl>
    <dt>script</dt><dd style="color:${scriptColor(p.script)}">${escapeHtml(p.script)}</dd>
    <dt>first seen</dt><dd>${formatMs(p.first_ms)}</dd>
    <dt>last seen</dt><dd>${formatMs(p.last_ms)}</dd>
    <dt>lifespan</dt><dd>${(p.last_ms - p.first_ms).toFixed(1)} ms</dd>
    <dt>commands in xtrace</dt><dd>${p.count}</dd>
    <dt>ancestor chain</dt><dd>${ancestorsHtml}</dd>
    <dt>children (traced)</dt><dd>${childrenHtml}</dd>
    ${p.ps_cmd ? `<dt>ps cmd</dt><dd style="color:var(--muted); font-size:10px">${escapeHtml(p.ps_cmd)}</dd>` : ""}
  </dl>${cmdLogHtml}`;

  // Wire up pid-link and ancestor-card clicks
  body.querySelectorAll(".pid-link").forEach(el => {
    el.addEventListener("click", (e) => {
      e.preventDefault();
      jumpToPid(parseInt(el.dataset.pid, 10));
    });
  });
  body.querySelectorAll(".anc-row.tracked").forEach(el => {
    el.addEventListener("click", () => {
      jumpToPid(parseInt(el.dataset.pid, 10));
    });
  });

  openDetail();
}

function showEventDetail(ev, p) {
  const title = document.getElementById("detail-title");
  const body = document.getElementById("detail-body");
  title.innerHTML = `<span style="color:${typeColor(ev.type)}">${escapeHtml(ev.label)}</span>`;
  body.classList.remove("hint");
  body.innerHTML = `<dl>
    <dt>type</dt><dd>${ev.type}</dd>
    <dt>timestamp</dt><dd>${formatMs(ev.ts_ms)} (epoch+${ev.ts_ms.toFixed(3)} ms)</dd>
    <dt>process</dt><dd>PID ${ev.pid} — <span style="color:${scriptColor(p.script)}">${escapeHtml(p.script)}</span></dd>
    <dt>source line</dt><dd>${escapeHtml(ev.script)}:${ev.line || "?"}</dd>
    <dt>function</dt><dd>${escapeHtml(ev.fn)}</dd>
    ${ev.detail ? `<dt>detail</dt><dd>${escapeHtml(ev.detail)}</dd>` : ""}
    <dt>raw command</dt><dd style="white-space:pre-wrap">${escapeHtml(ev.cmd)}</dd>
  </dl>`;
  openDetail();
}

function showSnapDetail(snap) {
  const e = snap.env || {};
  const title = document.getElementById("detail-title");
  const body = document.getElementById("detail-body");
  title.textContent = `Snapshot · ${snap.script}`;
  body.classList.remove("hint");
  body.innerHTML = `<dl>
    <dt>timestamp</dt><dd>${formatMs(snap.ts_ms)}</dd>
    <dt>trigger</dt><dd>${escapeHtml(snap.script)}-enter (BASHPID ${snap.pid})</dd>
    <dt>settings.json env keys</dt><dd>${e.env_keys_count ?? "?"}</dd>
    <dt>VADE_RUNTIME_DIR</dt><dd style="color:${e.has_VADE_RUNTIME_DIR ? '#4ad06a' : '#ff4a4a'}">${e.has_VADE_RUNTIME_DIR ? "present" : "missing"}</dd>
    <dt>VADE_COO_MEMORY_DIR</dt><dd style="color:${e.has_VADE_COO_MEMORY_DIR ? '#4ad06a' : '#ff4a4a'}">${e.has_VADE_COO_MEMORY_DIR ? "present" : "missing"}</dd>
    <dt>VADE_CLOUD_STATE_DIR</dt><dd style="color:${e.has_VADE_CLOUD_STATE_DIR ? '#4ad06a' : '#ff4a4a'}">${e.has_VADE_CLOUD_STATE_DIR ? "present" : "missing"}</dd>
    <dt>snapshot dir</dt><dd>${escapeHtml(snap.dir)}</dd>
  </dl>`;
  openDetail();
}

function typeColor(t) {
  return {
    "write": "#ff9c2a", "merge": "#4aa8ff",
    "invariant-pass": "#4ad06a", "invariant-fail": "#ff4a4a", "invariant-skip": "#888",
    "note": "#c0c0c0", "enter": "#c084fc", "alert": "#ff4a4a",
  }[t] || "#fff";
}

// Zoom controls
const zoomInput = document.getElementById("zoom");
zoomInput.addEventListener("input", () => { pxPerMs = parseFloat(zoomInput.value); render(); });
function fitToWindow(targetMs) {
  const usable = scroll.clientWidth - getLabelWidth() - 60;
  pxPerMs = Math.max(TARGETS.MIN_PX_PER_MS, Math.min(TARGETS.MAX_PX_PER_MS, usable / targetMs));
  zoomInput.value = pxPerMs;
  render();
  scroll.scrollLeft = 0;
}
document.getElementById("fit").addEventListener("click", () => fitToWindow(effectiveDurationMs()));
document.getElementById("boot-zoom").addEventListener("click", () => fitToWindow(5000));
document.getElementById("filter").addEventListener("input", render);
document.getElementById("hide-noise").addEventListener("change", render);
document.getElementById("boot-only").addEventListener("change", render);

// View-mode toggle
const VIEW_KEY = "vade-trace-view";
function setViewMode(mode) {
  viewMode = mode;
  localStorage.setItem(VIEW_KEY, mode);
  document.getElementById("view-rows").classList.toggle("active", mode === "rows");
  document.getElementById("view-tree").classList.toggle("active", mode === "tree");
  render();
}
document.getElementById("view-rows").addEventListener("click", () => setViewMode("rows"));
document.getElementById("view-tree").addEventListener("click", () => setViewMode("tree"));
// Restore preference
viewMode = localStorage.getItem(VIEW_KEY) || "rows";
document.getElementById("view-rows").classList.toggle("active", viewMode === "rows");
document.getElementById("view-tree").classList.toggle("active", viewMode === "tree");

// --- Zoom around a focal point (used by wheel + pinch) ---
function zoomAround(clientX, factor) {
  const labelWidth = getLabelWidth();
  const rect = scroll.getBoundingClientRect();
  const xInChart = scroll.scrollLeft + (clientX - rect.left) - labelWidth;
  const msAtPointer = xInChart / pxPerMs;
  const next = Math.max(TARGETS.MIN_PX_PER_MS, Math.min(TARGETS.MAX_PX_PER_MS, pxPerMs * factor));
  if (next === pxPerMs) return false;
  pxPerMs = next;
  zoomInput.value = pxPerMs;
  render();
  scroll.scrollLeft = msAtPointer * pxPerMs - (clientX - rect.left - labelWidth);
  return true;
}

// wheel zoom (ctrl/cmd)
scroll.addEventListener("wheel", (e) => {
  if (!(e.ctrlKey || e.metaKey)) return;
  e.preventDefault();
  const factor = e.deltaY < 0 ? 1.2 : 1 / 1.2;
  zoomAround(e.clientX, factor);
}, { passive: false });

// --- iOS Safari pinch zoom on the chart area ---
// `gesturestart`/`gesturechange`/`gestureend` give us a `scale` ratio.
// We project that onto pxPerMs and keep the pinch midpoint anchored.
let gestureBasePx = pxPerMs;
let gestureCenterX = 0;
const chartArea = document.getElementById("chart-area");
chartArea.addEventListener("gesturestart", (e) => {
  e.preventDefault();
  gestureBasePx = pxPerMs;
  // approximate midpoint from clientX/clientY (Safari sets these on gesture)
  gestureCenterX = (e.clientX != null) ? e.clientX : (chartArea.getBoundingClientRect().left + chartArea.clientWidth / 2);
}, { passive: false });
chartArea.addEventListener("gesturechange", (e) => {
  e.preventDefault();
  const target = Math.max(TARGETS.MIN_PX_PER_MS, Math.min(TARGETS.MAX_PX_PER_MS, gestureBasePx * e.scale));
  if (Math.abs(target - pxPerMs) < 1e-4) return;
  const factor = target / pxPerMs;
  zoomAround(gestureCenterX, factor);
}, { passive: false });
chartArea.addEventListener("gestureend", (e) => { e.preventDefault(); }, { passive: false });

// --- Fallback pinch zoom for browsers without iOS gesture events ---
// Use Pointer Events to track two simultaneous touches.
const activePointers = new Map();
let pinchInitialDist = 0;
let pinchBasePx = pxPerMs;
let pinchCenterX = 0;
scroll.addEventListener("pointerdown", (e) => {
  if (e.pointerType !== "touch") return;
  activePointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
  if (activePointers.size === 2) {
    const [a, b] = [...activePointers.values()];
    pinchInitialDist = Math.hypot(a.x - b.x, a.y - b.y);
    pinchBasePx = pxPerMs;
    pinchCenterX = (a.x + b.x) / 2;
  }
});
scroll.addEventListener("pointermove", (e) => {
  if (e.pointerType !== "touch" || !activePointers.has(e.pointerId)) return;
  activePointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
  if (activePointers.size === 2 && pinchInitialDist > 0) {
    const [a, b] = [...activePointers.values()];
    const dist = Math.hypot(a.x - b.x, a.y - b.y);
    const scaleRatio = dist / pinchInitialDist;
    const target = Math.max(TARGETS.MIN_PX_PER_MS, Math.min(TARGETS.MAX_PX_PER_MS, pinchBasePx * scaleRatio));
    if (Math.abs(target - pxPerMs) > 1e-4) {
      const factor = target / pxPerMs;
      zoomAround(pinchCenterX, factor);
    }
    e.preventDefault();
  }
}, { passive: false });
function endPointer(e) {
  if (activePointers.has(e.pointerId)) activePointers.delete(e.pointerId);
  if (activePointers.size < 2) pinchInitialDist = 0;
}
scroll.addEventListener("pointerup", endPointer);
scroll.addEventListener("pointercancel", endPointer);
scroll.addEventListener("pointerleave", endPointer);

// --- Detail-area open/close on narrow screens ---
function isNarrow() { return window.matchMedia("(max-width: 900px)").matches; }
function openDetail() {
  if (isNarrow()) detailArea.classList.add("open");
}
function closeDetail() {
  detailArea.classList.remove("open");
}
detailClose.addEventListener("click", closeDetail);

// --- Controls toggle on narrow screens ---
controlsToggle.addEventListener("click", () => {
  controlsEl.classList.toggle("open");
});
// Close controls panel when tapping outside (on narrow screens)
document.addEventListener("click", (e) => {
  if (!isNarrow()) return;
  if (controlsEl.contains(e.target) || controlsToggle.contains(e.target)) return;
  controlsEl.classList.remove("open");
});

// --- Header/legend chrome toggle (claims vertical space in cut-off viewers) ---
const chromeToggle = document.getElementById("chrome-toggle");
const CHROME_KEY = "vade-trace-chrome";
function applyChrome() {
  const state = localStorage.getItem(CHROME_KEY) || "visible";
  document.body.dataset.chrome = state;
  chromeToggle.textContent = state === "hidden" ? "▾" : "▴";
  chromeToggle.title = state === "hidden"
    ? "Show header (currently hidden)"
    : "Hide header — claim ~70px of vertical space if your viewer is cutting off the top";
  // After toggling chrome, re-fit because #main height just changed
  setTimeout(() => render(), 0);
}
chromeToggle.addEventListener("click", () => {
  const next = (localStorage.getItem(CHROME_KEY) || "visible") === "visible" ? "hidden" : "visible";
  localStorage.setItem(CHROME_KEY, next);
  applyChrome();
});
applyChrome();

// --- Manual top-offset nudge (▲/▼). Pushes the layout down so an
// overlapping app toolbar (iPad Files viewer, etc.) stops cutting the top.
// Persists per-device via localStorage so the user only tunes it once.
const OFFSET_KEY = "vade-trace-offset";
const OFFSET_STEP = 20;
const OFFSET_MAX = 500;
function getOffset() { return parseInt(localStorage.getItem(OFFSET_KEY) || "0", 10) || 0; }
function setOffset(v) {
  v = Math.max(0, Math.min(OFFSET_MAX, v));
  localStorage.setItem(OFFSET_KEY, String(v));
  document.documentElement.style.setProperty("--manual-offset", v + "px");
  setTimeout(() => render(), 0);
}
document.getElementById("pad-down").addEventListener("click", () => setOffset(getOffset() + OFFSET_STEP));
document.getElementById("pad-up").addEventListener("click", () => setOffset(getOffset() - OFFSET_STEP));
setOffset(getOffset());

// --- Resizable detail sidebar (desktop / wide-viewport only) ---
const detailResize = document.getElementById("detail-resize");
const DETAIL_WIDTH_KEY = "vade-trace-detail-width";
const initialDetailWidth = parseInt(localStorage.getItem(DETAIL_WIDTH_KEY) || "340", 10);
document.documentElement.style.setProperty("--detail-width", initialDetailWidth + "px");
(function wireDetailResize() {
  let dragging = false;
  let startX = 0;
  let startW = 0;
  function pxFromEvent(e) {
    return (e.touches && e.touches[0]) ? e.touches[0].clientX : e.clientX;
  }
  function onMove(e) {
    if (!dragging) return;
    const dx = startX - pxFromEvent(e); // drag left = larger
    const next = Math.max(280, Math.min(window.innerWidth * 0.7, startW + dx));
    document.documentElement.style.setProperty("--detail-width", next + "px");
    if (e.cancelable) e.preventDefault();
  }
  function onEnd() {
    if (!dragging) return;
    dragging = false;
    detailResize.classList.remove("dragging");
    const w = parseInt(getComputedStyle(detailArea).width, 10);
    localStorage.setItem(DETAIL_WIDTH_KEY, String(w));
    // re-fit chart after width change
    render();
  }
  detailResize.addEventListener("pointerdown", (e) => {
    dragging = true;
    startX = pxFromEvent(e);
    startW = parseInt(getComputedStyle(detailArea).width, 10);
    detailResize.classList.add("dragging");
    detailResize.setPointerCapture(e.pointerId);
  });
  detailResize.addEventListener("pointermove", onMove);
  detailResize.addEventListener("pointerup", onEnd);
  detailResize.addEventListener("pointercancel", onEnd);
})();

// --- Touch hint swap ---
if (IS_TOUCH) {
  document.querySelectorAll(".touch-hint").forEach(n => n.style.display = "");
  document.querySelectorAll(".mouse-hint").forEach(n => n.style.display = "none");
  const ht = document.getElementById("hint-text");
  if (ht) ht.textContent = "drag = pan · pinch = zoom · tap event/snapshot for detail";
}

setMeta();
// initial fit
function initialFit() {
  const usable = scroll.clientWidth - getLabelWidth() - 60;
  pxPerMs = Math.max(TARGETS.MIN_PX_PER_MS, Math.min(TARGETS.MAX_PX_PER_MS, usable / Math.min(5000, BOOT_WINDOW_MS)));
  zoomInput.value = pxPerMs;
  render();
}
window.addEventListener("load", initialFit);

// --- Re-render on resize / orientation change so label-width media query takes effect ---
let resizeTimer = 0;
window.addEventListener("resize", () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => render(), 100);
});
window.addEventListener("orientationchange", () => setTimeout(initialFit, 200));
</script>
</body>
</html>
"""
)

with open(OUTPUT, "w") as f:
    f.write(HTML)
print(f"Wrote {OUTPUT}", file=sys.stderr)
