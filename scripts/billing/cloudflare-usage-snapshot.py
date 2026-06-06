#!/usr/bin/env python3
"""cloudflare-usage-snapshot.py — Cloudflare usage / cost digest.

Consumes the six account-level read endpoints whose scope was provisioned
by coo-labs/coo-memory MEMO-2026-06-05-vegp and live-verified via the
sister probe script (coo-labs/coo-harness#476). Emits a markdown
billing/usage summary to stdout.

Endpoints touched (all read-only):
  GET /accounts/{id}                          (Account Settings:Read)
  GET /accounts/{id}/billing/profile          (Billing:Read)
  GET /accounts/{id}/billing/history          (Billing:Read)
  GET /accounts/{id}/workers/scripts          (Workers Scripts:Read)
  GET /accounts/{id}/r2/buckets               (Workers R2 Storage:Read)
  GET /accounts/{id}/r2/buckets/{name}/usage  (Workers R2 Storage:Read)
  GET /accounts/{id}/pages/projects           (Pages:Read)

No writes. No PII beyond what already lives in funding/billing/ receipts
(account balance, credit-card status enum, country code). Per-resource
analytics (Workers Analytics Engine SQL, R2 ops volume, Pages traffic)
are out of scope here — separate child if the basic enumeration earns
its keep.

Invocation:

    CLOUDFLARE_API_TOKEN=$(op read 'op://COO/cloudflare-api-vade-coo/credential') \\
    CLOUDFLARE_ACCOUNT_ID=$(op read 'op://COO/cloudflare-api-vade-coo/account_id') \\
    python3 scripts/billing/cloudflare-usage-snapshot.py

Both env vars are already in the COO container's process env, so the
live invocation is just `python3 scripts/billing/cloudflare-usage-snapshot.py`.

Tracked by coo-labs/coo-memory#1226 (parent epic #1025).
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

CF_BASE = "https://api.cloudflare.com/client/v4"
TIMEOUT_S = 30


def cf_get(token: str, path: str, query: dict | None = None) -> dict:
    """GET a Cloudflare API endpoint; return parsed JSON or a synthetic error envelope."""
    url = f"{CF_BASE}{path}"
    if query:
        url += "?" + urlencode(query)
    req = Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    })
    try:
        with urlopen(req, timeout=TIMEOUT_S) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        try:
            parsed = json.loads(body)
            return {
                "success": False,
                "_http_status": e.code,
                "errors": parsed.get("errors") or [{"message": "(no errors block)"}],
            }
        except json.JSONDecodeError:
            return {
                "success": False,
                "_http_status": e.code,
                "errors": [{"message": body[:200] or "(empty body)"}],
            }
    except URLError as e:
        return {
            "success": False,
            "_http_status": None,
            "errors": [{"message": str(e.reason)}],
        }


def fail_line(data: dict) -> str:
    http = data.get("_http_status")
    errors = data.get("errors") or [{"message": "(no errors)"}]
    msg = errors[0].get("message", "(no message)")
    return f"_FAIL_ (http={http}): {msg}"


def fmt_bytes(n: int | str | None) -> str:
    """Human-friendly bytes; Cloudflare's R2 usage returns strings."""
    if n is None:
        return "?"
    try:
        v = float(n)
    except (TypeError, ValueError):
        return str(n)
    units = ("B", "KiB", "MiB", "GiB", "TiB", "PiB")
    i = 0
    while v >= 1024 and i < len(units) - 1:
        v /= 1024
        i += 1
    if i == 0:
        return f"{int(v)} {units[i]}"
    return f"{v:.2f} {units[i]}"


def md_escape(s: str) -> str:
    return s.replace("|", "\\|").replace("\n", " ")


def section_account(token: str, account_id: str) -> None:
    print("## Account\n")
    data = cf_get(token, f"/accounts/{account_id}")
    if not data.get("success"):
        print(f"- {fail_line(data)}\n")
        return
    acc = data.get("result") or {}
    settings = acc.get("settings") or {}
    print(f"- **Name:** `{acc.get('name', '?')}`")
    print(f"- **ID:** `{acc.get('id', account_id)}`")
    if acc.get("type"):
        print(f"- **Type:** `{acc['type']}`")
    if acc.get("created_on"):
        print(f"- **Created:** `{acc['created_on']}`")
    if "enforce_twofactor" in settings:
        print(f"- **2FA enforced:** `{settings['enforce_twofactor']}`")
    print()


def section_billing_profile(token: str, account_id: str) -> None:
    print("## Billing profile\n")
    data = cf_get(token, f"/accounts/{account_id}/billing/profile")
    if not data.get("success"):
        print(f"- {fail_line(data)}\n")
        return
    prof = data.get("result") or {}
    balance = prof.get("account_balance")
    currency = prof.get("currency") or ""
    if balance is not None:
        print(f"- **Account balance:** `{balance} {currency}`".rstrip())
    cc = prof.get("credit_card_status")
    if cc:
        print(f"- **Credit-card status:** `{cc}`")
    country = prof.get("country")
    if country:
        print(f"- **Country:** `{country}`")
    if prof.get("created_on"):
        print(f"- **Profile created:** `{prof['created_on']}`")
    if prof.get("edited_on"):
        print(f"- **Profile last edited:** `{prof['edited_on']}`")
    print()


def section_billing_history(token: str, account_id: str, limit: int = 3) -> None:
    print(f"## Billing history (last {limit} events)\n")
    data = cf_get(
        token,
        f"/accounts/{account_id}/billing/history",
        query={"per_page": limit, "page": 1},
    )
    if not data.get("success"):
        print(f"- {fail_line(data)}\n")
        return
    items = data.get("result") or []
    if not items:
        print("- _(no billing events recorded)_\n")
        return
    print("| Occurred | Type | Action | Description | Amount |")
    print("|---|---|---|---|---|")
    for it in items[:limit]:
        occ = it.get("occurred_at", "?")
        t = it.get("type", "?")
        act = it.get("action", "?")
        desc = md_escape(it.get("description") or "")
        amt = it.get("amount")
        cur = it.get("currency") or ""
        amt_s = f"{amt} {cur}".rstrip() if amt is not None else "?"
        print(f"| `{occ}` | `{t}` | `{act}` | {desc} | `{amt_s}` |")
    print()


def section_workers(token: str, account_id: str) -> None:
    print("## Workers\n")
    data = cf_get(token, f"/accounts/{account_id}/workers/scripts")
    if not data.get("success"):
        print(f"- {fail_line(data)}\n")
        return
    scripts = data.get("result") or []
    print(f"- **Count:** {len(scripts)}")
    if not scripts:
        print()
        return
    print()
    print("| Name | Modified | Usage model |")
    print("|---|---|---|")
    for s in sorted(scripts, key=lambda x: (x.get("id") or "")):
        name = s.get("id", "?")
        mod = s.get("modified_on", "?")
        um = s.get("usage_model") or "?"
        print(f"| `{name}` | `{mod}` | `{um}` |")
    print()


def section_r2(token: str, account_id: str) -> None:
    print("## R2 buckets\n")
    data = cf_get(token, f"/accounts/{account_id}/r2/buckets")
    if not data.get("success"):
        print(f"- {fail_line(data)}\n")
        return
    result = data.get("result") or {}
    buckets = result.get("buckets") if isinstance(result, dict) else result
    buckets = buckets or []
    print(f"- **Count:** {len(buckets)}")
    if not buckets:
        print()
        return
    print()
    print("| Name | Location | Created | Storage (payload + meta) | Objects |")
    print("|---|---|---|---|---|")
    for b in sorted(buckets, key=lambda x: (x.get("name") or "")):
        name = b.get("name", "?")
        loc = b.get("location") or "default"
        created = b.get("creation_date", "?")
        usage = cf_get(token, f"/accounts/{account_id}/r2/buckets/{name}/usage")
        if usage.get("success"):
            u = usage.get("result") or {}
            payload = u.get("payloadSize") or 0
            metadata = u.get("metadataSize") or 0
            try:
                total = int(payload) + int(metadata)
                storage = fmt_bytes(total)
            except (TypeError, ValueError):
                storage = "?"
            objects = u.get("objectCount", "?")
        else:
            storage = "?"
            objects = "?"
        print(f"| `{name}` | `{loc}` | `{created}` | {storage} | {objects} |")
    print()


def section_pages(token: str, account_id: str) -> None:
    print("## Pages projects\n")
    data = cf_get(token, f"/accounts/{account_id}/pages/projects")
    if not data.get("success"):
        print(f"- {fail_line(data)}\n")
        return
    projects = data.get("result") or []
    print(f"- **Count:** {len(projects)}")
    if not projects:
        print()
        return
    print()
    print("| Name | Production branch | Latest deploy | Latest deploy created | Status |")
    print("|---|---|---|---|---|")
    for p in sorted(projects, key=lambda x: (x.get("name") or "")):
        name = p.get("name", "?")
        branch = p.get("production_branch") or "?"
        ld = p.get("latest_deployment") or {}
        ld_id = (ld.get("id") or "")[:8] or "?"
        ld_created = ld.get("created_on", "?")
        status = "?"
        for st in ld.get("stages") or []:
            if st.get("name") == "deploy":
                status = st.get("status") or "?"
                break
        print(f"| `{name}` | `{branch}` | `{ld_id}` | `{ld_created}` | `{status}` |")
    print()


def main() -> int:
    token = os.environ.get("CLOUDFLARE_API_TOKEN")
    account_id = os.environ.get("CLOUDFLARE_ACCOUNT_ID")
    if not token:
        sys.stderr.write("error: CLOUDFLARE_API_TOKEN not set\n")
        return 2
    if not account_id:
        sys.stderr.write("error: CLOUDFLARE_ACCOUNT_ID not set\n")
        return 2

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"# Cloudflare usage snapshot (account_id={account_id})\n")
    print(f"Generated: {now}\n")
    print(
        "Source: account-level read scopes per MEMO-2026-06-05-vegp; "
        "verified via [coo-labs/coo-harness#476](https://github.com/coo-labs/coo-harness/pull/476). "
        "Snapshot script: [coo-labs/coo-memory#1226](https://github.com/coo-labs/coo-memory/issues/1226).\n"
    )

    section_account(token, account_id)
    section_billing_profile(token, account_id)
    section_billing_history(token, account_id, limit=3)
    section_workers(token, account_id)
    section_r2(token, account_id)
    section_pages(token, account_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
