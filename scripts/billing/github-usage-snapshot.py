#!/usr/bin/env python3
"""github-usage-snapshot.py — GitHub usage / cost digest.

Consumes the org-level read endpoints whose `Organization administration: Read`
scope was provisioned on `vade-coo-app` per coo-labs/coo-memory MEMO-2026-06-05-nubs
and live-verified by the sister probe script (coo-labs/coo-harness#490). Emits
a markdown billing/usage summary to stdout, suitable for the Night's Watch
monthly snapshot rollup or for on-demand COO inspection.

Endpoints touched (all read-only, all via App install token):
  GET orgs/{org}                                    (org metadata + plan)
  GET organizations/{org}/settings/billing/usage    (per-SKU usage items)
  GET organizations/{org}/settings/billing/budgets  (configured budgets)

Routing: relies on `gh-coo-wrap.sh` to mint the App install token for the
`coo-labs` installation. The PAT path is structurally blocked because
`vade-coo` is non-org-admin per MEMO-2026-05-21-w6qz; the script sets
`GH_USE_APP_TOKEN=1` for every gh invocation.

Invocation:

    python3 scripts/billing/github-usage-snapshot.py
    python3 scripts/billing/github-usage-snapshot.py --org coo-labs --month 2026-05

No env vars required for the default invocation — `gh-coo-wrap.sh` resolves
credentials from `op://` on demand. `ORG` env overrides the default org.

Tracked by coo-labs/coo-memory#1230 (parent epic #1025). Sister to
scripts/billing/cloudflare-usage-snapshot.py (coo-labs/coo-memory#1226).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone

# Published baseline included quotas for the GitHub Team plan, per
# https://docs.github.com/en/billing/concepts/product-billing/github-actions
# (Actions minutes only; storage is GiB-hours-billed which doesn't map
# cleanly to the published instantaneous-GB inclusion and is left out of
# the headroom table). GitHub may apply additional discounts beyond this
# baseline (OSS sponsorship, plan promotions); the authoritative
# absorbed-cost figure is the `discountAmount` field returned by the API,
# shown in the per-SKU detail table.
TEAM_PLAN_MINUTES_INCLUDED = {
    "Actions Linux":   3000,
    "Actions Windows": 1500,
    "Actions macOS":   300,
}


def gh_app_api(path: str) -> tuple[object, dict | None]:
    """Run `GH_USE_APP_TOKEN=1 gh api <path>`; return (parsed_json, error_or_None).

    gh prints the response body to stdout on success or 4xx/5xx and a
    `gh: <message> (HTTP <code>)` tail to stderr on failure. We capture
    both, prefer the JSON body for parsing, and surface the HTTP code in
    the error envelope when the call failed.
    """
    env = os.environ.copy()
    env["GH_USE_APP_TOKEN"] = "1"
    try:
        proc = subprocess.run(
            ["gh", "api", path],
            env=env, capture_output=True, timeout=30, check=False,
        )
    except (subprocess.SubprocessError, OSError) as e:
        return {}, {"http": None, "message": str(e)}
    stdout = proc.stdout.decode("utf-8", "replace")
    stderr = proc.stderr.decode("utf-8", "replace")
    if proc.returncode != 0:
        http = None
        for line in stderr.splitlines():
            tok = line.strip().rsplit("(HTTP ", 1)
            if len(tok) == 2 and tok[1].endswith(")"):
                http = tok[1][:-1].strip()
                break
        try:
            body = json.loads(stdout) if stdout.strip() else {}
            msg = body.get("message") if isinstance(body, dict) else None
        except json.JSONDecodeError:
            msg = None
        return {}, {
            "http": http,
            "message": (msg or stderr.strip() or stdout.strip() or "(empty error)")[:400],
        }
    try:
        return json.loads(stdout), None
    except json.JSONDecodeError as e:
        return {}, {"http": None, "message": f"JSON decode: {e}"}


def fmt_money(v) -> str:
    if v is None:
        return "?"
    try:
        f = float(v)
    except (TypeError, ValueError):
        return str(v)
    if f == 0:
        return "$0.00"
    if abs(f) < 0.01:
        return f"${f:.6f}".rstrip("0").rstrip(".")
    return f"${f:.2f}"


def fmt_quantity(v, unit: str) -> str:
    if v is None:
        return "?"
    try:
        f = float(v)
    except (TypeError, ValueError):
        return str(v)
    if unit == "Minutes":
        return f"{f:,.0f}"
    if unit == "GigabyteHours":
        return f"{f:.3f}"
    return f"{f:,}"


def md_escape(s) -> str:
    if s is None:
        return ""
    return str(s).replace("|", "\\|").replace("\n", " ")


def section_org(org: str) -> dict:
    print("## Organization\n")
    data, err = gh_app_api(f"orgs/{org}")
    if err:
        print(f"- _FAIL_ (http={err['http']}): {md_escape(err['message'])}\n")
        return {}
    if not isinstance(data, dict):
        print(f"- _FAIL_: unexpected response shape (type {type(data).__name__})\n")
        return {}
    print(f"- **Login:** `{data.get('login', '?')}`")
    print(f"- **Billing email:** `{data.get('billing_email', '?')}`")
    plan = data.get("plan") or {}
    if plan:
        seats = f"{plan.get('filled_seats', '?')}/{plan.get('seats', '?')}"
        print(
            f"- **Plan:** `{plan.get('name', '?')}` "
            f"(seats: {seats}, private repos cap: {plan.get('private_repos', '?')})"
        )
    if data.get("created_at"):
        print(f"- **Created:** `{data['created_at']}`")
    print()
    return data


def section_budgets(org: str) -> None:
    print("## Budgets\n")
    data, err = gh_app_api(f"organizations/{org}/settings/billing/budgets")
    if err:
        print(f"- _FAIL_ (http={err['http']}): {md_escape(err['message'])}\n")
        return
    items = (data or {}).get("budgets") if isinstance(data, dict) else None
    items = items or []
    total = (data or {}).get("total_count") if isinstance(data, dict) else None
    print(f"- **Configured:** {total if total is not None else len(items)}\n")
    if not items:
        return
    print("| Product SKU | Scope | Amount | Stop on cap? | Alerts to |")
    print("|---|---|---|---|---|")
    for b in items:
        alerts = b.get("budget_alerting") or {}
        recipients = ", ".join(alerts.get("alert_recipients") or [])
        stop = "yes" if b.get("prevent_further_usage") else "no"
        amt = b.get("budget_amount")
        amt_s = fmt_money(amt) if amt else "$0.00"
        print(
            f"| `{b.get('budget_product_sku', '?')}` "
            f"| `{b.get('budget_scope', '?')}` "
            f"| `{amt_s}` "
            f"| {stop} "
            f"| {md_escape(recipients)} |"
        )
    print()


def section_usage(org: str, month: str, plan_name: str) -> None:
    data, err = gh_app_api(f"organizations/{org}/settings/billing/usage")
    if err:
        print(f"## Usage — {month}\n\n- _FAIL_ (http={err['http']}): {md_escape(err['message'])}\n")
        return
    items = (data or {}).get("usageItems") if isinstance(data, dict) else None
    items = items if isinstance(items, list) else []

    by_month: dict[str, list] = defaultdict(list)
    for it in items:
        date = (it.get("date") or "")[:7]
        by_month[date].append(it)

    months_avail = sorted(by_month.keys())
    print(f"## Usage — {month}\n")
    if month not in by_month:
        avail = ", ".join(months_avail) if months_avail else "none"
        print(f"- _(no usage items for {month}; months in API: {avail})_\n")
        return

    rows = by_month[month]
    agg: dict[tuple, dict] = defaultdict(lambda: {
        "quantity": 0.0, "unitType": "?",
        "gross": 0.0, "discount": 0.0, "net": 0.0,
        "repos": set(),
    })
    for it in rows:
        k = (it.get("product"), it.get("sku"))
        a = agg[k]
        for src, dst in (("quantity", "quantity"), ("grossAmount", "gross"),
                         ("discountAmount", "discount"), ("netAmount", "net")):
            try:
                a[dst] += float(it.get(src) or 0)
            except (TypeError, ValueError):
                pass
        a["unitType"] = it.get("unitType") or a["unitType"]
        if it.get("repositoryName"):
            a["repos"].add(it["repositoryName"])

    total_gross = sum(a["gross"] for a in agg.values())
    total_discount = sum(a["discount"] for a in agg.values())
    total_net = sum(a["net"] for a in agg.values())

    print(f"- **Gross:** {fmt_money(total_gross)}  ")
    print(f"- **Absorbed in included usage:** {fmt_money(total_discount)}  ")
    print(f"- **Net billable:** {fmt_money(total_net)}\n")

    if plan_name == "team":
        print("### Consumption vs. included Actions minutes (Team plan baseline)\n")
        print("| SKU | Used | Included | Headroom |")
        print("|---|---|---|---|")
        for sku, limit in TEAM_PLAN_MINUTES_INCLUDED.items():
            a = agg.get(("actions", sku))
            used = float(a["quantity"]) if a else 0.0
            headroom = max(limit - used, 0)
            pct = (used / limit * 100) if limit else 0
            warn = " :warning:" if pct >= 80 else ""
            print(
                f"| `{sku}` "
                f"| {fmt_quantity(used, 'Minutes')} ({pct:.0f}%){warn} "
                f"| {fmt_quantity(limit, 'Minutes')} "
                f"| {fmt_quantity(headroom, 'Minutes')} |"
            )
        print()
        print(
            "_Baseline is the published Team-plan inclusion (3000 Linux / 1500 Windows / "
            "300 macOS per month). GitHub may apply additional discounts beyond the baseline "
            "(OSS sponsorship, plan promotions, mid-cycle credits); the authoritative "
            "absorbed-cost figure is the **Discount** column in the per-SKU table below. "
            "Storage SKUs are billed in GiB-hours and aren't reduced to the published "
            "instantaneous-GB inclusion here._\n"
        )
    else:
        print("### Consumption vs. included\n")
        print(
            f"_Skipped — included-quota table is wired only for `team` plan; "
            f"current plan is `{plan_name or '?'}`. Per-SKU detail below._\n"
        )

    print("### Per-SKU detail\n")
    print("| Product | SKU | Quantity | Unit | Gross | Discount | Net | Repos |")
    print("|---|---|---|---|---|---|---|---|")
    for (prod, sku), a in sorted(agg.items(), key=lambda x: (x[0][0] or "", x[0][1] or "")):
        repos = ", ".join(sorted(a["repos"])) or "?"
        print(
            f"| `{prod}` | `{sku}` "
            f"| {fmt_quantity(a['quantity'], a['unitType'])} | `{a['unitType']}` "
            f"| {fmt_money(a['gross'])} "
            f"| {fmt_money(a['discount'])} "
            f"| {fmt_money(a['net'])} "
            f"| {md_escape(repos)} |"
        )
    print()

    print(f"### Months available in API\n\n- {', '.join(months_avail)}\n")


def main() -> int:
    p = argparse.ArgumentParser(
        description="GitHub usage / cost snapshot for a coo-labs-style org",
    )
    p.add_argument(
        "--org",
        default=os.environ.get("ORG", "coo-labs"),
        help="GitHub org login; default coo-labs (or $ORG)",
    )
    p.add_argument(
        "--month",
        default=datetime.now(timezone.utc).strftime("%Y-%m"),
        help="YYYY-MM to filter usage on; default current UTC month",
    )
    args = p.parse_args()

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"# GitHub usage snapshot (org={args.org})\n")
    print(f"Generated: {now}\n")
    print(
        "Source: enhanced billing endpoints unlocked by "
        "[MEMO-2026-06-05-nubs](https://github.com/coo-labs/coo-memory/blob/main/memos/2026-06-05-nubs.md) "
        "(`Organization administration: Read` on `vade-coo-app`); verified by "
        "[coo-labs/coo-harness#490](https://github.com/coo-labs/coo-harness/pull/490). "
        "Snapshot script: [coo-labs/coo-memory#1230](https://github.com/coo-labs/coo-memory/issues/1230).\n"
    )

    org_data = section_org(args.org)
    plan_name = ""
    if isinstance(org_data, dict):
        plan = org_data.get("plan") or {}
        plan_name = (plan.get("name") or "").lower()
    section_budgets(args.org)
    section_usage(args.org, args.month, plan_name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
