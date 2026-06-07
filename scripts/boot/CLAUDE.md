# scripts/boot/ — boot entry points + integrity probes

**SessionStart hook order is fixed.** Do not add bootstrap-dependent hooks as SessionStart siblings — they race against `coo-bootstrap.sh`'s writes. From `../../.claude/settings.json` startup chain:

1. `boot-brake-clear.sh` — mint per-session sentinel, sweep stale state.
2. `session-start-sync.sh` — re-sync `.claude/` config, `.mcp.json`, workspace CLAUDE.md symlink. **Idempotent; no 1Password access.**
3. `coo-bootstrap.sh` — pull COO credentials from 1Password, write SSH keys + PATs + env. EXIT trap then calls `post-bootstrap-chain.sh` (digest → discussions-digest → project-board-digest → idle-watchdog → integrity-check backgrounded) IN ORDER.
4. `memo-index.sh` (coo-memory) — index memos.

`cloud-setup.sh` vs `session-start-sync.sh`:
- `cloud-setup.sh` — runs ONCE at snapshot build. Installs binaries, writes receipts, calls `coo-bootstrap.sh` with live 1Password access.
- `session-start-sync.sh` — runs on EVERY SessionStart. Sync + symlinks only.

`integrity-check.sh` phase gate:
- `VADE_INTEGRITY_PHASE=fast` (default from EXIT trap) — skips Group E live network probes.
- `VADE_INTEGRITY_PHASE=live` — runs all groups. Backgrounded by `post-bootstrap-chain.sh` after the banner renders.
- Non-fatal on every path: exits 0 even on invariant failures. It is a PROBE, not a repair tool.

CI fake-env signal: `VADE_CI_WORKSPACE_ROOT` or `VADE_BINDIR_OVERRIDE` set. Groups E1–E4 + F1–F4 skip in CI by design.

---

*If you notice contradictions between the substrate and this file, update it after finishing your current task.*
