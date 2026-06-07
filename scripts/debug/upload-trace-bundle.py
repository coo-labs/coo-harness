#!/usr/bin/env python3
"""Upload a parsed bootstrap-trace bundle to the Console R2 prefix.

Usage:
    upload-trace-bundle.py [<trace-dir>] [--run-id <id>] [--console-url <url>]
    upload-trace-bundle.py --data-json <path.json> [--run-id <id>]

The script:
1. Either invokes ``render-trace-timeline.py --json`` to parse the trace
   bundle into the data blob the React ``/trace/`` route consumes, or
   reads a pre-parsed ``data.json`` via ``--data-json``.
2. Sources the Console bearer token from ``CONSOLE_TOKEN`` env or from
   ``op://COO/console-bearer-ven/credential``.
3. POSTs the JSON to ``{console-url}/trace/data?run-id={id}``.
4. Prints the Console viewer URL on success.

R2 layout: ``vade-agent-transcripts/console-traces/<run-id>/data.json``
(bucket reused; prefix is per ``coo-labs/coo-memory#832`` spec).
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

DEFAULT_CONSOLE = "https://console.vade-app.dev"
RUN_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")


def find_default_trace_dir() -> str:
    cur = os.path.expanduser("~/.vade/traces/CURRENT_RUN_ID")
    if os.path.exists(cur):
        run_id = open(cur).read().strip()
        return os.path.expanduser(f"~/.vade/traces/{run_id}")
    raise SystemExit("no trace dir given and CURRENT_RUN_ID not found")


def read_console_token() -> str:
    env = os.environ.get("CONSOLE_TOKEN")
    if env:
        return env
    try:
        out = subprocess.check_output(
            ["op", "read", "op://COO/console-bearer-ven/credential"],
            stderr=subprocess.PIPE,
        ).decode().strip()
    except FileNotFoundError:
        raise SystemExit(
            "CONSOLE_TOKEN env unset and op CLI not on PATH"
        )
    except subprocess.CalledProcessError as e:
        raise SystemExit(
            f"op read for CONSOLE_TOKEN failed: {e.stderr.decode().strip()}"
        )
    if not out:
        raise SystemExit("op read returned empty CONSOLE_TOKEN")
    return out


def parse_via_renderer(trace_dir: str) -> dict:
    """Shell out to render-trace-timeline.py --json - to get the data dict."""
    # Renderer lives in the trace-timeline skill bundle (PR9b moved it out
    # of scripts/debug/ to keep the skill self-contained per convention 4).
    # This script lives at coo-harness/scripts/debug/upload-trace-bundle.py;
    # walk up two levels then into the skill bundle.
    renderer = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..", "..", ".claude", "skills", "trace-timeline", "scripts",
        "render-trace-timeline.py",
    )
    if not os.path.exists(renderer):
        raise SystemExit(f"renderer not found at {renderer}")
    out = subprocess.check_output(
        [sys.executable, renderer, trace_dir, "-", "--json"]
    )
    return json.loads(out)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "trace_dir",
        nargs="?",
        default=None,
        help="bootstrap-trace run directory (default: CURRENT_RUN_ID)",
    )
    ap.add_argument(
        "--run-id",
        default=None,
        help="override run-id (default: reads from meta.json or --data-json)",
    )
    ap.add_argument(
        "--console-url",
        default=DEFAULT_CONSOLE,
        help=f"Console base URL (default {DEFAULT_CONSOLE})",
    )
    ap.add_argument(
        "--data-json",
        default=None,
        help="upload a pre-rendered data.json (skips renderer invocation)",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="parse + validate but do not POST",
    )
    args = ap.parse_args()

    if args.data_json:
        with open(args.data_json) as f:
            data = json.load(f)
    else:
        trace_dir = args.trace_dir or find_default_trace_dir()
        if not os.path.isdir(trace_dir):
            print(f"Trace dir not found: {trace_dir}", file=sys.stderr)
            return 1
        data = parse_via_renderer(trace_dir)

    meta = data.get("meta") or {}
    run_id = args.run_id or meta.get("run_id")
    if not run_id:
        print(
            "No run-id; pass --run-id or ensure meta.json has run_id",
            file=sys.stderr,
        )
        return 1
    if not RUN_ID_RE.match(run_id):
        print(
            f"run-id {run_id!r} fails sanitization "
            "(allowed: A-Z a-z 0-9 . _ -, length 1-128)",
            file=sys.stderr,
        )
        return 1

    body = json.dumps(data).encode("utf-8")
    target = f"{args.console_url}/trace/data?run-id={run_id}"
    print(
        f"PIDs={len(data.get('pids', []))}  "
        f"events={len(data.get('events', []))}  "
        f"snapshots={len(data.get('snapshots', []))}  "
        f"bytes={len(body)}",
        file=sys.stderr,
    )
    print(f"target: {target}", file=sys.stderr)

    if args.dry_run:
        print("dry-run; skipping upload", file=sys.stderr)
        return 0

    token = read_console_token()
    req = urllib.request.Request(
        target,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": "upload-trace-bundle.py (coo-harness)",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            response = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace") if e.fp else ""
        print(f"HTTP {e.code}: {detail.strip()}", file=sys.stderr)
        return 1
    except urllib.error.URLError as e:
        print(f"Network error: {e.reason}", file=sys.stderr)
        return 1

    print(json.dumps(response, indent=2), file=sys.stderr)
    print(f"{args.console_url}/trace/?run-id={run_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
