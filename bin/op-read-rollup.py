#!/usr/bin/env python3
"""
op-read-rollup — aggregate per-day op-read consumption from the
two-layer jsonl sinks shipped by coo-harness#540 / briefing-40.

Reads per-session op-reads sidecars at
coo-logs/sessions/YYYY/MM/DD/coo-<slug>.op-reads.jsonl (one file per
session, written by /end-session's op-reads export step). Each line
carries a `layer` field distinguishing L1 (gh-coo-wrap.sh _resolve_pat
decisions) from L2 (op-coo-wrap.sh per-call events). Emits per-script /
per-path / per-phase histograms with p50/p95/p99 latency.

Output: markdown table to stdout; --json-out writes structured JSON.

The --combine-with-actions <date> mode merges the session-side jsonl with
the Actions-side rollup at coo-logs/telemetry/op-reads-actions-<date>.json
(produced by coo-labs/coo-logs/bin/op-reads-actions.py per
coo-labs/coo-harness#541) to report total daily op-read consumption.

Usage:
  op-read-rollup.py --date 2026-06-07 --by script
  op-read-rollup.py --date 2026-06-07 --by path
  op-read-rollup.py --date 2026-06-07 --by phase
  op-read-rollup.py --range 2026-06-01:2026-06-07 --by script
  op-read-rollup.py --date 2026-06-07 --input-dir /path/to/coo-logs/sessions
  op-read-rollup.py --combine-with-actions 2026-06-07    # sessions + actions

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
    g.add_argument(
        "--combine-with-actions",
        metavar="YYYY-MM-DD",
        help="Combine session-side jsonl with the Actions-side rollup at "
             "coo-logs/telemetry/op-reads-actions-<date>.json for total daily total",
    )
    p.add_argument(
        "--by",
        choices=("script", "path", "phase", "layer", "decision", "cache_decision"),
        default="script",
        help="Aggregation dimension",
    )
    p.add_argument(
        "--input-dir",
        default=_default_input_dir(),
        help="coo-logs root or sessions directory containing per-session "
             "op-reads sidecars (default: auto-detect coo-logs)",
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


def _default_input_dir():
    for cand in (
        os.path.expanduser("~/GitHub/coo-labs/coo-logs"),
        "/home/user/coo-logs",
        os.environ.get("COO_LOGS_DIR", ""),
    ):
        if cand and Path(cand).is_dir():
            return cand
    return "/home/user/coo-logs"


def load_events(input_dir, days, layer_filter):
    """Walk coo-logs/sessions/YYYY/MM/DD/coo-*.op-reads.jsonl for each day.

    Accepts either a coo-logs root (then walks into ./sessions/) or a
    pre-resolved sessions root. Sidecar filenames carry the
    .op-reads.jsonl suffix; the matching session-log .md sits beside.
    """
    root = Path(input_dir)
    sessions_root = root / "sessions" if (root / "sessions").is_dir() else root
    rows = []
    for d in days:
        day_dir = sessions_root / d.strftime("%Y") / d.strftime("%m") / d.strftime("%d")
        if not day_dir.is_dir():
            continue
        for path in sorted(day_dir.glob("*.op-reads.jsonl")):
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
        if by == "cache_decision":
            return ev.get("cache_decision") or "<bypass>"
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


def _coo_logs_root(input_dir):
    """Resolve the coo-logs repo root from --input-dir.

    --input-dir may point at the coo-logs root or its sessions/ subdir; the
    Actions-side rollup file lives under coo-logs/telemetry/ either way.
    """
    p = Path(input_dir)
    if (p / "sessions").is_dir() and (p / "telemetry").is_dir():
        return p
    if p.name == "sessions" and (p.parent / "telemetry").is_dir():
        return p.parent
    if (p / "telemetry").is_dir():
        return p
    return p.parent if p.parent != p else p


def combine_with_actions(args):
    """Combined daily-total view: session-side + Actions-side."""
    try:
        target = datetime.strptime(args.combine_with_actions, "%Y-%m-%d").date()
    except ValueError as e:
        print(f"op-read-rollup: bad --combine-with-actions date: {e}", file=sys.stderr)
        sys.exit(2)

    # Session side — read the same jsonl sidecars (both layers).
    rows = load_events(args.input_dir, [target], "both")
    session_total = len(rows)
    session_by_layer = defaultdict(int)
    for ev in rows:
        session_by_layer[ev.get("layer") or "unknown"] += 1

    # Actions side — read coo-logs/telemetry/op-reads-actions-<date>.json.
    logs_root = _coo_logs_root(args.input_dir)
    actions_path = logs_root / "telemetry" / f"op-reads-actions-{target.isoformat()}.json"
    actions_payload = None
    if actions_path.is_file():
        try:
            actions_payload = json.loads(actions_path.read_text())
        except json.JSONDecodeError as e:
            print(
                f"op-read-rollup: bad Actions-side JSON at {actions_path}: {e}",
                file=sys.stderr,
            )
    actions_summary = (actions_payload or {}).get("summary") or {}
    actions_total = int(actions_summary.get("total_op_reads") or 0)
    actions_runs = int(actions_summary.get("total_runs_counted") or 0)

    grand_total = session_total + actions_total

    lines = [
        f"# op-read combined rollup — {target.isoformat()}",
        "",
        f"Grand total: **{grand_total}** op-read events",
        "",
        "| source | events | notes |",
        "|---|---:|---|",
        f"| sessions (L1 + L2) | {session_total} | L1={session_by_layer.get('L1', 0)}, L2={session_by_layer.get('L2', 0)} (input: {args.input_dir}) |",
    ]
    if actions_payload is None:
        lines.append(f"| actions | _missing_ | expected at {actions_path} |")
    else:
        wf_count = len(actions_payload.get("workflows") or [])
        lines.append(
            f"| actions (load-secrets-action@v2) | {actions_total} | {actions_runs} counted runs across {wf_count} loader workflows ({actions_path}) |"
        )
    lines.append("")

    if actions_payload and (actions_payload.get("workflows") or []):
        lines += [
            "## Actions-side per-workflow",
            "",
            "| repo | workflow | ref-list-size | runs | op-reads |",
            "|---|---|---:|---:|---:|",
        ]
        for w in actions_payload["workflows"]:
            lines.append(
                f"| {w.get('repo')} | {w.get('path')} | {w.get('ref_list_size')} | "
                f"{w.get('runs_counted')} | {w.get('op_reads')} |"
            )
        lines.append("")

    out_md = "\n".join(lines) + "\n"
    sys.stdout.write(out_md)

    if args.json_out:
        payload = {
            "date": target.isoformat(),
            "session_side": {
                "total_events": session_total,
                "by_layer": dict(session_by_layer),
                "input_dir": str(args.input_dir),
            },
            "actions_side": {
                "total_op_reads": actions_total,
                "total_runs_counted": actions_runs,
                "source_path": str(actions_path),
                "present": actions_payload is not None,
                "by_repo": actions_summary.get("by_repo") or {},
            },
            "grand_total": grand_total,
        }
        out_path = Path(args.json_out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(payload, indent=2) + "\n")
        print(f"op-read-rollup: wrote {out_path}", file=sys.stderr)


def main():
    args = parse_args()
    if args.combine_with_actions:
        combine_with_actions(args)
        return
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
