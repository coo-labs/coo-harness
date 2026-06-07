# `scripts/`

Boot orchestration, session-lifecycle, hooks, and shared utilities for
the COO kernel. Organized by role into sub-folders post-PR9a (see
[coo-labs/coo-memory#1066](https://github.com/coo-labs/coo-memory/issues/1066)
+ [coo-labs/coo-harness#344](https://github.com/coo-labs/coo-harness/pull/344));
top-level retains scripts that don't fit a single sub-folder cleanly —
mostly cross-cutting wrappers, probes, subscribe utilities, and one-off
backfills.

`.claude/settings.json` hook commands point at `boot/`, `hooks/`,
`lifecycle/` directly via `$VADE_RUNTIME_DIR/scripts/<subfolder>/<script>`
— no dispatcher in between (the `dispatch.sh` + `hooks-dispatch.sh`
indirection was removed in PR9a).

## Sub-folders

- **`boot/`** — bootstrap entry points + integrity probes. Hooks call
  `boot-brake-clear.sh`, `session-start-sync.sh`, `coo-bootstrap.sh`
  at session start. `cloud-setup.sh` / `local-setup.sh` are the
  surface-specific bootstrap orchestrators; `integrity-check.sh` runs
  the Group A–F invariant probes; `healthcheck.sh` is the fast smoke.
- **`hooks/`** — PreToolUse / PostToolUse / SessionStart / SessionEnd
  hook implementations. Pure hook scripts only — test runners moved
  to `ci/`. Includes the token-guards (`bash-token-guard.sh`,
  `bash-github-api-guard.sh`), the boot-brake guard, the agent
  model-guard, auto-subscribe-PR, the workflow-file auth guard, and
  the skill-yaml / skill-best-practices nudges.
- **`lifecycle/`** — session-lifecycle scripts (`session-lifecycle.sh`,
  `session-idle-watchdog.sh`), transcript export + render
  (`session-end-transcript-{export,render}.{sh,py}`), and the boot-time
  digest helpers (`coo-identity-digest.sh`, `discussions-digest.sh`,
  `project-board-digest.sh`).
- **`lib/`** — sourced helpers, not entry points. `common.sh` carries
  the shared functions (settings.json merging, claude-config
  aggregation, manifest loading); `integrity-group-s.sh` carries
  Group-S invariant logic; transcript-fetch / redaction helpers live
  here too.
- **`mcp/`** — MCP-server projection helpers (`mem0-mcp-projection.py`).
- **`ci/`** — bootstrap-regression CI driver
  (`run-bootstrap-regression.sh`), per-hook test scripts, mocks, and
  fixtures.
- **`billing/`** — Cloudflare + GitHub scope probes and usage snapshot
  collectors. Polled by the billing-watch surface.
- **`debug/`** — diagnostic instrumentation. `bootstrap-trace-init.sh`
  + `bootstrap-trace-snapshot.sh` are the BASH_ENV-wired capture
  harness (container UI configures `BASH_ENV` to point here);
  `coo-boot-incident-collect.sh` collects boot-crash artifacts.
  The renderer for trace timelines lives bundled into the
  `trace-timeline` skill, not here.

## Top-level scripts (cross-cutting)

Wrappers, probes, subscribe utilities, and ad-hoc backfills that don't
fit a sub-folder cleanly:

- `gh-coo-wrap.sh`, `gh-pr-create.sh`, `gh-app-token.sh`,
  `gh-put-workflow.sh` — `gh` CLI wrappers + write paths.
- `git-shim.sh`, `git-push-with-fallback.sh` — git proxy + push
  fallback (HTTPS-proxy 403 retry).
- `op-coo-wrap.sh` — `op` CLI wrapper that caches SA-token fetches.
- `check-pat-freshness.sh` — first-response probe for silent `gh`
  failures (see coo-memory CLAUDE.md §"GitHub writes").
- `coo-session-url.sh` — prints the Claude Code session URL.
- `claude-thinking-display-wrap.sh` — PATH-shim for `claude` injecting
  `--thinking-display summarized` (MEMO-2026-06-07-4bat).
- `issue-comments.sh` — bounded issue-comment fetcher (substitute for
  unbounded `mcp__github__issue_read get_comments`).
- `registry-check.sh` — F17 registry-completeness probe.
- `subscribe-*.sh` (4) — discussion-watch, PR-watch, agentmail-watch,
  vade-coo-notification-watch subscribers.
- `sync-repos.sh`, `sync-templates-to-consumers.sh` — bulk-repo + bulk-
  template sweep helpers.
- `bridge-form-fields-to-natives.py` — project-board form-field migrator.
- `transcript-*-backfill.py` (3) — one-shot transcript-corpus
  backfills (URL, render, rerender-v3).

## Config

- `../config/aggregator.yml` — top-level config; the manifest of repos
  whose `.claude/` aggregates into the workspace surface. Loaded by
  `lib/common.sh::load_aggregator_repos`. Moved to top-level `config/`
  in PR9b ([coo-labs/coo-memory#1066](https://github.com/coo-labs/coo-memory/issues/1066)).
