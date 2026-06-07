#!/usr/bin/env python3
"""Pre-push port of issue-pr-hygiene-reusable.yml Patterns C + D.

Reads JSON {"title": "...", "body": "..."} on stdin. Emits human-readable
findings on stderr. Exit 2 on any finding (blocking at the pre-push layer
where the agent is still in-turn); 0 on clean. Diagnostic format mirrors the
workflow's advisory text so the agent reads the same message either layer.

Active coo-labs/* slug list hardcoded — the workflow loads it from the
org registry at run time. A pre-push primitive needs a deterministic source;
maintenance window is whenever a new top-level coo-labs/* repo lands (rare
enough to be a deliberate touch, per the strategy's "structural friction"
framing). Cross-references coo-memory#1016 G1 fast-feedback.

Drift between this list and the org registry is itself a G2 drift-watch
subject — surfaced by the next epic per the CI strategy's W3 probe.
"""

import json
import re
import sys

ACTIVE_SLUGS = (
    "coo-memory",
    "coo-harness",
    "coo-logs",
    "coo-console",
    "tjsonl",
    "skills",
    "coo4one",
    "vade-canvas",
    "site",
    ".github",
)


def strip_links_and_code(s: str) -> str:
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", s)
    s = re.sub(r"`[^`]*`", "", s)
    return s


def check_pattern_c(title: str, body: str, host_repo: str | None = None) -> list[str]:
    findings: list[str] = []

    slug_alt = "|".join(re.escape(s) for s in ACTIVE_SLUGS)
    cross_repo_cues = re.compile(rf"((?:{slug_alt})(?!#))[^\n]{{0,80}}#\d+")

    clean_body = strip_links_and_code(body)
    clean_title = strip_links_and_code(title)

    c_matches = [
        m.group(0)
        for m in list(cross_repo_cues.finditer(clean_body))
        + list(cross_repo_cues.finditer(clean_title))
        if not re.search(r"discussion", m.group(0), re.IGNORECASE)
    ]

    if c_matches:
        examples = "\n".join(f"  - `{m}`" for m in c_matches[:5])
        findings.append(
            "Pattern C — cross-repo references\n"
            f"Detected {len(c_matches)} reference(s) where an active coo-labs/* repo "
            "is named near a bare `#N`. Bare `#N` resolves to the host repo; use "
            "`coo-labs/<repo>#N` for cross-repo.\n"
            "Examples:\n"
            f"{examples}"
        )

    # Naked-reponame sub-check — `<slug>#N` (no `coo-labs/` prefix, no space).
    # Pattern B's broken-form regex catches this only in closing-keyword position
    # (Closes/Fixes/Resolves <slug>#N); this fires anywhere in title or body.
    # Lookbehind `(?<![\w/])` excludes the valid `coo-labs/<slug>#N` form and
    # wordy false positives like `xcoo-memory#1`. Discussion carve-out applied
    # for parity with the cross-repo subcheck.
    naked_slug_re = re.compile(rf"(?<![\w/])({slug_alt})#(\d+)")
    naked_matches = [
        m for m in list(naked_slug_re.finditer(clean_body)) + list(naked_slug_re.finditer(clean_title))
        if not re.search(r"discussion", m.group(0), re.IGNORECASE)
    ]
    if naked_matches:
        same_repo = [m for m in naked_matches if host_repo and m.group(1) == host_repo]
        cross_repo = [m for m in naked_matches if not host_repo or m.group(1) != host_repo]
        msg = (
            "Pattern C — naked reponame form\n"
            f"Detected {len(naked_matches)} reference(s) using `<reponame>#N` form "
            "(no `coo-labs/` prefix). Autolinks but doesn't satisfy closing-keyword "
            "semantics; reads as a broken form to skim readers expecting either bare "
            "`#N` (same-repo) or `coo-labs/<repo>#N` (cross-repo)."
        )
        if same_repo:
            ex = "\n".join(
                f"  - `{m.group(0)}` → `#{m.group(2)}`" for m in same_repo[:5]
            )
            msg += f"\n\nSame-repo ({len(same_repo)}) — use bare `#N`:\n{ex}"
        if cross_repo:
            ex = "\n".join(
                f"  - `{m.group(0)}` → `coo-labs/{m.group(1)}#{m.group(2)}`"
                for m in cross_repo[:5]
            )
            msg += f"\n\nCross-repo ({len(cross_repo)}) — use `coo-labs/<repo>#N`:\n{ex}"
        findings.append(msg)

    list_inheritance = re.compile(r"coo-labs/[a-z0-9-]+#\d+\s*,\s*#\d+")
    list_matches = [
        m.group(0)
        for m in list(list_inheritance.finditer(body)) + list(list_inheritance.finditer(title))
    ]
    if list_matches:
        examples = "\n".join(f"  - `{m}`" for m in list_matches[:3])
        findings.append(
            "Pattern C — list-inheritance\n"
            "Detected `coo-labs/<repo>#N, #M` patterns. The prefix scopes only the "
            "first `#N`; subsequent `#M` autolink to the host repo. Repeat the prefix "
            "per item: `coo-labs/<repo>#N, coo-labs/<repo>#M`.\n"
            f"Examples:\n{examples}"
        )

    return findings


def check_pattern_d(title: str, body: str) -> list[str]:
    findings: list[str] = []

    collision_terms = re.compile(
        r"\b(quorum|instance|briefing|memo|stage|phase|finding|oq|audit|committee|persona|agent|chunk|round|track|step|tier|band|mechanism|hypothesis)s?\s+#\d+(?:\s*[-–]\s*#?\d+)?\b",
        re.IGNORECASE,
    )
    enumerated_ids = re.compile(r"\b(F\d+|Q\d+|A\d+|G\d+)\s+#\d+(?:\s*[-–]\s*#?\d+)?\b")

    stripped_body = re.sub(r"^[-*]\s*\[[ xX]\]\s+.*$", "", body, flags=re.MULTILINE)

    d_matches = [
        m.group(0)
        for m in list(collision_terms.finditer(stripped_body))
        + list(enumerated_ids.finditer(stripped_body))
        + list(collision_terms.finditer(title))
        + list(enumerated_ids.finditer(title))
    ]

    if d_matches:
        examples = "\n".join(f"  - `{m}`" for m in d_matches[:5])
        findings.append(
            "Pattern D — `#num` for non-issue IDs\n"
            f"Detected {len(d_matches)} reference(s) using `<term> #N` notation where "
            "`#N` autolinks to an unrelated GitHub issue/PR. Use dash form: `quorum-1`, "
            "`instance-N`, `briefing-014`, etc.\n"
            f"Examples:\n{examples}"
        )

    return findings


def main() -> int:
    payload = json.load(sys.stdin)
    title = payload.get("title", "") or ""
    body = payload.get("body", "") or ""
    host_repo = payload.get("host", "") or None

    findings = check_pattern_c(title, body, host_repo) + check_pattern_d(title, body)

    if not findings:
        return 0

    sys.stderr.write("gh-pr-create: PR hygiene check FAILED (Patterns C + D)\n\n")
    for f in findings:
        sys.stderr.write(f + "\n\n")
    sys.stderr.write(
        "Reference: issue-pr-hygiene-reusable.yml is the non-bypassable backstop; "
        "this pre-push layer is the cheap-fix earlier surface (CI strategy G1 "
        "fast-feedback, defense-in-depth-perpetual).\n"
        "Bypass: --skip-hygiene-check (only when your case is genuinely exempt).\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
