# coo-harness — Repo Instructions for Claude Code

This repository is the **COO's kernel**: boot orchestration for
Claude Code sessions. SessionStart hooks, integrity checks, MCP
projection, PAT routing, session lifecycle, transcript export.

## Session-start reading

1. This file.
2. `README.md`.
3. The public authority and decision-rights document at
   [coo-memory/identity/public-authority.md](https://github.com/coo-labs/coo-memory/blob/main/identity/public-authority.md)
   — for what may and may not be done autonomously.

## Scope

Boot orchestration: every primitive a Claude Code session needs at
boot, in order. SessionStart hooks (`.claude/settings.json`), MCP
server projection (`.mcp.json`), integrity invariants
(`scripts/boot/integrity-check.sh`), PAT routing
(`scripts/gh-coo-wrap.sh`), session-lifecycle scripts (transcript
export, end-session helpers), the boot-time skill aggregator.

## What may be done autonomously

- Update boot scripts under `scripts/`.
- Revise `.mcp.json` / `.claude/settings.json` for new MCP servers
  or hook chains (boot-impact PR convention: handoff prompt
  required, see `operations/handoff-prompts.md` in coo-memory).
- Update pinned tool versions in `versions.lock` with rationale.
- Open PRs for review.

## What requires explicit approval

- Merging to `main`.
- Removing or adding env vars that flow through
  `_write_claude_settings_env` (positional-arg surface; coordinated
  change).
- Changes to the COO-identity-bootstrap flow (`coo-bootstrap.sh`,
  `install_coo_credentials`).

## Pinning discipline

Every binary version fetched from a CDN at boot time must be
pinned in `versions.lock` with rationale. Unpinned dependencies
cause silent drift across container snapshots — the exact class of
bug the kernel's reproducibility discipline exists to prevent.

## Current state

Production boot kernel. `scripts/boot/cloud-setup.sh` pre-bakes `op`,
`gh`, `uv`, `mem0-mcp-server`, and the 1Password MCP into a snapshot;
subsequent sessions resume warm with these tools in place. Identity
bootstrap (`scripts/boot/coo-bootstrap.sh`) wires the `vade-coo` GitHub
identity when `OP_SERVICE_ACCOUNT_TOKEN` is set in the cloud-env
config.

## Querying the transcript corpus — `bin/coo-search`

`bin/coo-search` is the canonical "have I done this before?" surface.
Queries the `coo_corpus` Cloudflare D1 database (built nightly from R2
sidecars by the `corpus-index` Action in `coo-labs/coo-logs`; see
coo-labs/coo-memory#1149 for Phase 3 scope, MEMO-2026-06-06-keks for
the D1 + token-scope ack).

```sh
# Recent sessions touching coo-memory
coo-search sessions --repo coo-memory --from 2026-06 --limit 10

# Sessions that called a particular tool
coo-search tool-calls --tool 'mcp__github__pull_request_read' --limit 10

# Across-corpus tool usage
coo-search tool-calls --limit 20

# Find an artifact by ref or title (substring)
coo-search artifacts --ref 'briefing 039'
coo-search artifacts --kind pr --ref 'MEMO-2026-06'

# Approximate "files touched" via artifact-title scan (until Phase 4)
coo-search files --path 'coo-bootstrap.sh' --last

# Sessions with errors
coo-search errors --from 2026-06 --limit 10

# Add --json for machine-readable output
coo-search --json sessions --limit 5
```

Backends:

- **D1 (default).** Reads `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`,
  `D1_DATABASE_ID` from env. Token is the `vade-coo-2026-05` Cloudflare
  API key (Account D1:Edit/Read scope, added 2026-06-06).
- **Local snapshot.** Pass `--snapshot path/to/corpus.db.gz` to query the
  gzipped SQLite mirror instead — works offline, useful for DR, and
  doesn't need any env. Snapshot lives at `coo-logs/index/corpus.db.gz`,
  refreshed nightly by the same Action.

Deferred to a Phase 4 enrichment pass: `excerpt` (needs rendered HTML
or jsonl access), exact `files` (needs jsonl decryption in the Action),
token-count and cost columns. The current schema and data sources are
documented in `coo-labs/coo-logs/index/README.md`.

## Op-read consumption telemetry — `bin/op-read-rollup.py`

`bin/op-read-rollup.py` aggregates per-day 1Password op-read consumption
across two sources:

- **Session side** — per-call jsonl events emitted by `op-coo-wrap.sh`
  (Layer 2) and `gh-coo-wrap.sh` `_resolve_pat` (Layer 1), rolled to
  per-session sidecars at `coo-logs/sessions/YYYY/MM/DD/coo-*.op-reads.jsonl`
  by the `/end-session` skill (shipped in coo-labs/coo-harness#540).
- **Actions side** — daily rollup of `1password/load-secrets-action@v2`
  consumption across `coo-labs/*` workflows, written nightly to
  `coo-logs/telemetry/op-reads-actions-YYYY-MM-DD.json` by the
  `op-reads-actions` Action in `coo-labs/coo-logs` (shipped in
  coo-labs/coo-harness#541).

```sh
# Session-side rollups (per-script / per-path / per-phase histograms)
op-read-rollup.py --date 2026-06-07 --by script
op-read-rollup.py --range 2026-06-01:2026-06-07 --by path

# Combined daily total: sessions + actions
op-read-rollup.py --combine-with-actions 2026-06-07
```

The combined view is the canonical answer to "what's our total daily
op-read consumption?" — the session-side and Actions-side draw on the
same `OP_SERVICE_ACCOUNT_TOKEN` quota, so neither alone is sufficient.

Origin: briefing-040 (`coo-memory/briefings/040-op-request-volume.md`)
and its followup plan §4 (`briefings/_followups/040-op-request-volume-plan-2026-06-07-mrcc.md`).

## Transcript primitives — `lib/transcripts/`

`lib/transcripts/` is the internal Python library for the VADE transcript
pipeline — R2 access, schema types (Pydantic v2 `Sidecar`), JSONL parsing,
provenance invariants, sidecar I/O. Imported by `scripts/lib/transcript-*.py`
and `scripts/lifecycle/session-end-transcript-*.py`; consolidated out of the
earlier copy-pasted version of those primitives.

**When you touch transcripts** — JSONL walks, R2 sidecar reads/writes,
redaction, schema validation, session-end exports, or any new sidecar
shape (`*.cost.json`, future cost dashboard etc.) — **start with
[`lib/transcripts/README.md`](lib/transcripts/README.md)** and import from
`transcripts.*` rather than re-implementing in `scripts/`. The package is
the consolidation layer; the older `scripts/lib/transcript-*.py` files are
pre-consolidation orchestrators kept for backward-compat.

Import pattern (per the README's `parents[N]` table for the script's depth):

```python
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))  # scripts/lifecycle/
from transcripts import Sidecar, read_entries, r2_client
```

CI for the package runs ruff + mypy + pytest on every PR that touches
`lib/transcripts/` (`.github/workflows/lib-transcripts.yml`).

## Bootstrap CI

PRs that touch `scripts/`, `.claude/`, `.mcp.json`, or
`versions.lock` trigger
`.github/workflows/bootstrap-regression.yml`, which stages a
cloud-style workspace under `/home/user`, runs `scripts/boot/cloud-setup.sh`
+ `scripts/boot/session-start-sync.sh` end-to-end in **fake-env mode**
(PATH-shadowed `op` and `curl`-to-`api.github.com/user` mocks under
`scripts/ci/mocks/`), then asserts the integrity-check report has no
degraded invariants modulo the `VADE_CI_ALLOWLIST` env. Catches
script-level regressions at PR-open time without burning a Claude
Code session per check.

This Layer-1 suite does not exercise Claude Code reading
`settings.json`, MCP startup, skill loading, or live 1Password /
GitHub PAT round-trips — those stay in the manual fresh-container
ritual.

What runs:
1. `scripts/ci/run-bootstrap-regression.sh` stages
   `$VADE_CI_WORKSPACE_ROOT/{coo-harness,coo-memory}` from the
   PR checkout (sibling repos are stubbed).
2. Generates fixture ed25519 keys per run; their fingerprints are
   exported as `COO_AUTH_FP_EXPECTED` / `COO_SIGN_FP_EXPECTED` so
   `install_coo_ssh_keys` validates against the substituted material.
3. Mocks `op` (returns canned vade-coo-shaped responses) and `curl`
   (intercepts only `api.github.com/user`; other URLs forward).
4. Provisions an isolated `$HOME` so the runner's `~/.gitconfig` /
   `~/.claude` stay untouched.
5. Runs `cloud-setup.sh` → `session-start-sync.sh` →
   `integrity-check.sh`; reads `integrity-check.json`, applies
   `VADE_CI_ALLOWLIST`, fails if anything degraded remains.
6. Renders a per-group markdown table and posts/updates a sticky PR
   comment (header marker `<!-- bootstrap-regression-comment -->`).

Allowlist defaults to empty. E1–E4 (live MCP probes) skip in CI by
design; F1–F4 (culture-substrate invariants) skip cleanly because
the staged `coo-memory` is a stub without `.git`. Bump the
allowlist via the workflow's `VADE_CI_ALLOWLIST` env or the
`workflow_dispatch` input — cite the reason in the commit so the
next operator can audit.

Local run (from a coo-harness checkout, against a scratch workspace
to avoid clobbering production `/home/user`):

```sh
VADE_CI_WORKSPACE_ROOT=/tmp/vade-ci-workspace \
  bash scripts/ci/run-bootstrap-regression.sh "$PWD"
```

Smoke-test the suite itself by editing `cloud-setup.sh` /
`session-start-sync.sh` to comment out a call like
`ensure_workspace_identity_link` or `merge_coo_settings_env` — the
runner should report the corresponding C1/D4 invariant as degraded
and exit 1.
