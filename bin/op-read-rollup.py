#!/usr/bin/env python3
"""
op-read-rollup — aggregate per-day op-read consumption from the
two-layer jsonl sinks shipped by coo-harness#540 / briefing-40.

Reads ~/.vade/op-reads-YYYY-MM-DD.jsonl (one combined file per day,
distinguished by `layer` field — L1 lines from gh-coo-wrap.sh's
_resolve_pat decisions, L2 lines from op-coo-wrap.sh's per-call
events). Emits per-script / per-path / per-phase histograms with
p50/p95/p99 latency.

Output: markdown table to stdout + structured JSON to
coo-logs/telemetry/op-reads-rollup-<date>.json when --json-out is set.

Usage:
  op-read-rollup.py --date 2026-06-07 --by script
  op-read-rollup.py --date 2026-06-07 --by path
  op-read-rollup.py --date 2026-06-07 --by phase
  op-read-rollup.py --range 2026-06-01:2026-06-07 --by script
  op-read-rollup.py --date 2026-06-07 --json-out coo-logs/telemetry/op-reads-rollup-2026-06-07.json

Exit codes:
  0 — rollup produced
  1 — input file missing or no events
  2 — invocation error (bad args)
"""

import argparse
import json
import os
import statistics
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path


def parse_args():
    p = argparse.ArgumentParser(description="Aggregate op-read jsonl consumption.")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--date", help="YYYY-MM-DD single-day rollup")
    g.add_argument("--range", help="YYYY-MM-DD:YYYY-MM-DD inclusive range")
    p.add_argument(
        "--by",
        choices=("script", "path", "phase", "layer", "decision"),
        default="script",
        help="Aggregation dimension",
    )
    p.add_argument(
        "--input-dir",
        default=os.path.expanduser("~/.vade"),
        help="Directory containing op-reads-YYYY-MM-DD.jsonl files",
    )
    p.add_argument(
        "--json-out",
        help="Optional path to write structured JSON output",
    )
    p.add_argument(
        "--layer",
        choices=("L1", "L2", "both"),
        default="both",
        help="Restrict to one layer (default: both)",
    )
    return p.parse_args()


def date_range(args):
    if args.date:
        d = datetime.strptime(args.date, "%Y-%m-%d").date()
        return [d]
    start_s, end_s = args.range.split(":", 1)
    start = datetime.strptime(start_s, "%Y-%m-%d").date()
    end = datetime.strptime(end_s, "%Y-%m-%d").date()
    if end < start:
        raise SystemExit("range end < start")
    days = []
    d = start
    while d <= end:
        days.append(d)
        d += timedelta(days=1)
    return days


def load_events(input_dir, days, layer_filter):
    rows = []
    for d in days:
        path = Path(input_dir) / f"op-reads-{d.isoformat()}.jsonl"
        if not path.exists():
            continue
        with path.open("r", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if layer_filter != "both" and ev.get("layer") != layer_filter:
                    continue
                rows.append(ev)
    return rows


def percentile(values, p):
    if not values:
        return 0
    s = sorted(values)
    idx = max(0, min(len(s) - 1, int(round((p / 100.0) * (len(s) - 1)))))
    return s[idx]


def aggregate(rows, by):
    """Group rows by dimension; compute count + latency p50/p95/p99 per group."""
    # Field used as the group key per dimension.
    def key_of(ev):
        if by == "script":
            cmd = ev.get("caller_cmd") or ev.get("caller_script") or "<unknown>"
            # Reduce caller_cmd to a coarse script identifier: the last path-
            # like token under coo-harness/ or coo-memory/ if present, else
            # the basename of the first .sh/.py argv element.
            for tok in cmd.split():
                if "coo-harness/" in tok or "coo-memory/" in tok:
                    return tok.split("/")[-1].split()[0]
                if tok.endswith(".sh") or tok.endswith(".py"):
                    return tok.rsplit("/", 1)[-1]
            return cmd[:60]
        if by == "path":
            return ev.get("op_path") or "<no-path>"
        if by == "phase":
            return ev.get("phase") or "<unknown>"
        if by == "layer":
            return ev.get("layer") or "<unknown>"
        if by == "decision":
            return ev.get("decision") or "<n/a>"
        return "<unknown>"

    groups = defaultdict(list)
    for ev in rows:
        groups[key_of(ev)].append(ev)

    out = []
    for k, evs in groups.items():
        latencies = [int(e.get("latency_ms") or 0) for e in evs]
        rcs = [e.get("rc") for e in evs if e.get("rc") is not None]
        rl_count = sum(1 for e in evs if e.get("rate_limited"))
        out.append({
            "key": k,
            "count": len(evs),
            "fail_count": sum(1 for r in rcs if r != 0),
            "rate_limited_count": rl_count,
            "p50_latency_ms": percentile(latencies, 50),
            "p95_latency_ms": percentile(latencies, 95),
            "p99_latency_ms": percentile(latencies, 99),
            "total_latency_ms": sum(latencies),
        })
    out.sort(key=lambda r: (-r["count"], r["key"]))
    return out


def render_markdown(groups, by, days, total_rows):
    days_label = days[0].isoformat() if len(days) == 1 else f"{days[0].isoformat()}..{days[-1].isoformat()}"
    lines = [
        f"# op-read rollup — {days_label} — by {by}",
        "",
        f"Total events: **{total_rows}**",
        "",
    ]
    if not groups:
        lines.append("_(no events in range)_")
        return "\n".join(lines) + "\n"
    lines += [
        f"| {by} | count | fail | rate-limited | p50 ms | p95 ms | p99 ms | total ms |",
        f"|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for g in groups:
        lines.append(
            f"| {g['key']} | {g['count']} | {g['fail_count']} | {g['rate_limited_count']} | "
            f"{g['p50_latency_ms']} | {g['p95_latency_ms']} | {g['p99_latency_ms']} | "
            f"{g['total_latency_ms']} |"
        )
    return "\n".join(lines) + "\n"


def main():
    args = parse_args()
    try:
        days = date_range(args)
    except SystemExit:
        raise
    except Exception as e:
        print(f"op-read-rollup: bad date/range: {e}", file=sys.stderr)
        sys.exit(2)

    rows = load_events(args.input_dir, days, args.layer)
    if not rows:
        print(f"op-read-rollup: no events for {days[0]}..{days[-1]} under {args.input_dir}", file=sys.stderr)
        sys.exit(1)

    groups = aggregate(rows, args.by)
    out_md = render_markdown(groups, args.by, days, len(rows))
    sys.stdout.write(out_md)

    if args.json_out:
        payload = {
            "days": [d.isoformat() for d in days],
            "by": args.by,
            "layer_filter": args.layer,
            "total_events": len(rows),
            "groups": groups,
        }
        out_path = Path(args.json_out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(payload, indent=2) + "\n")
        print(f"op-read-rollup: wrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
