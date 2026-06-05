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
