# Sub-agent env_allowlist convention

This directory holds `.claude/agents/<name>.md` definitions for sub-agents that
run under this harness. When a sub-agent is spawned via the `Agent` tool, the
`preuse-agent-env-scrub.sh` PreToolUse hook computes the env vars it would
inherit and logs (or blocks) any secrets crossing the boundary without opt-in.

## Default-deny posture

By default, only these vars flow into a sub-agent's context:

- Every var in `non_secret_env_allowlist` from
  `operations/secrets/schema.yaml` (e.g. `HOME`, `PATH`, `VADE_COO_MEMORY_DIR`,
  `CLOUDFLARE_ACCOUNT_ID`, etc.).
- Every var whose name matches a prefix in `non_secret_env_prefixes` from the
  same schema (e.g. `CLAUDE_CODE_*`, `ANT_*`, `NODE_*`).
- Any var explicitly listed in the agent's own `env_allowlist:` frontmatter
  (see below).

Any var not in the above set is in the **scrub set** — the hook logs it (in
`warn` mode) or blocks the spawn (in `enforce` mode).

## Declaring env_allowlist in agent frontmatter

If a sub-agent needs a specific secret or non-allowlisted var, declare it in
the agent's frontmatter YAML block:

```markdown
---
name: my-agent
description: Does something that requires Cloudflare access.
model: sonnet
env_allowlist:
  - CLOUDFLARE_API_TOKEN
---
```

Or inline (both forms are parsed):

```markdown
---
env_allowlist: [CLOUDFLARE_API_TOKEN, VADE_AUTH_TOKEN]
---
```

Only vars you explicitly list here will cross. No implicit inheritance of
secret-class vars.

## Concrete example

An agent that queries the Cloudflare zone for DNS records needs
`CLOUDFLARE_API_TOKEN`. Without `env_allowlist`, the hook logs:

```
[preuse-agent-env-scrub] SECRET vars in scrub set: CLOUDFLARE_API_TOKEN
```

With the declaration above, `CLOUDFLARE_API_TOKEN` is in the allowed set and
does not appear in the scrub-set log.

## The three modes of VADE_AGENT_ENV_SCRUB

| Mode | Behavior | When to use |
|---|---|---|
| `warn` (default) | Log scrub set to stderr; allow spawn with full parent env. | Current phase — observe without impact. |
| `enforce` | Block spawn if any `declared_secret` vars are in the scrub set. | After soak signal confirms behavior is stable. |
| `disabled` | No-op, immediate exit 0. | Debug / CI contexts where the hook would false-positive. |

**Current phase: `warn`.** The default was set to `warn` at Track 2 ship
(coo-memory#871). Flip to `enforce` is a separate session's call after soak
observation (target: ~2026-06-11 post-soak). Track that flip under the
coo-memory#871 epic.

## Why this matters

The audit (coo-memory#871) found 7 of 8 sub-agent definitions had full
parent-env inheritance. Without this guard, sub-agents form a leak amplifier:
secrets in the parent session propagate into sub-agent transcripts that are
separately persisted, even with the PostToolUse redactor in place on the
parent. The `env_allowlist` convention makes the boundary explicit and
auditable per-agent.

See `operations/secrets/README.md` §3.6 for the full sub-agent env-inheritance
SOP.
