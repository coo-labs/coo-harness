# coo-harness

**The COO's kernel.** Boot orchestration for Claude Code sessions:
SessionStart hooks, integrity checks, MCP projection, PAT routing,
session lifecycle, transcript export. Divorced from canvas; no
Docker / devcontainer.

## What's in the kernel

| Component | Purpose |
|-----------|---------|
| `scripts/cloud-setup.sh` | Cloud-env one-shot snapshot bake: pre-fetches binaries (`op`, `gh`, `uv`, `mem0-mcp-server`, `@takescake/1password-mcp`) |
| `scripts/coo-bootstrap.sh` | COO identity setup (opt-in via `OP_SERVICE_ACCOUNT_TOKEN`): SSH keys, PAT, AgentMail, Mem0, R2, Cloudflare, GitHub App creds |
| `scripts/session-start-sync.sh` | Per-session boot: mirror `.claude/` from repo into workspace; aggregate skills/agents/commands/hooks from data-owning repos |
| `scripts/integrity-check.sh` | 29 invariants across 5 groups (A=env, B=workspace, C=identity, D=session, E=MCP); JSON report at `~/.vade-cloud-state/integrity-check.json` |
| `scripts/gh-coo-wrap.sh` | PAT routing shim: `vade-coo-app` installation token or repo-owner-class PAT |
| `scripts/git-push-with-fallback.sh` | Push retry through direct github.com URL on cloud-proxy 403 |
| `.claude/settings.json` | SessionStart hook chain + permissions + env mappings |
| `.mcp.json` | mem0 + agentmail + 1password MCP servers (canvas-MCP divorced per F11) |
| `versions.lock` | Pinned binary versions with rationale |

## Layout

```
coo-harness/
├── .claude/                  ← shared Claude Code config
│   └── settings.json         ← hooks declared here; mirrored to ~/.claude/ at boot
├── .mcp.json                 ← MCP server config (mem0, agentmail, 1password)
├── scripts/
│   ├── cloud-setup.sh        ← Claude Code web "Setup script" entry point
│   ├── coo-bootstrap.sh      ← COO identity setup (opt-in)
│   ├── session-start-sync.sh ← per-session boot
│   ├── integrity-check.sh    ← invariants + JSON report
│   ├── gh-coo-wrap.sh        ← PAT routing shim
│   └── lib/common.sh         ← shared helpers
└── versions.lock             ← pinned binaries
```

## How to use

### Claude Code on the web

The harness clones `coo-harness` and `coo-memory` into `/home/user/`
per session. Set the cloud environment's **Setup script** field to:

```bash
#!/bin/bash
set -e
bash /home/user/coo-harness/scripts/boot/cloud-setup.sh
```

> **Note:** the local clone path is currently `coo-harness/` until
> the next container build picks up the rename to `coo-harness/`. See
> the F11 PR's handoff prompt for the migration sequencing.

`cloud-setup.sh` mirrors `coo-harness/.claude/` into `~/.claude/`:
subdirectories (`skills/`, `agents/`, `commands/`, `hooks/`) are
symlinked so edits in the repo are live next session start;
`settings.json` is copied so COO bootstrap can mutate the env block
without dirtying the working tree.

## COO identity mode

Claude Code web sessions can boot with the `vade-coo` GitHub
identity pre-wired: SSH keys for push and signing, git identity,
GitHub PAT, AgentMail key, Mem0 key, R2 transcript credentials,
Cloudflare API token, GitHub App credentials. Opt-in via a single
env var set in the cloud environment config:

```
OP_SERVICE_ACCOUNT_TOKEN=ops_...
```

On next session boot, `cloud-setup.sh` detects the token and
invokes `scripts/coo-bootstrap.sh`, which:

1. Installs the 1Password `op` CLI to `~/.local/bin/` if missing
2. Authenticates with the service-account token
3. Reads SSH keys + PAT + AgentMail + Mem0 + R2 + Cloudflare + GH App
   creds from the 1Password `COO` vault
4. Writes `~/.ssh/vade-coo-{auth,sign}`, `~/.ssh/allowed_signers`,
   `~/.gitconfig` with COO identity + signed-commit config
5. Exports the credentials into the bootstrap process env (Phase 2;
   coo-memory#873). Secrets are NOT persisted to `~/.vade/coo-env`
   (retired) or `~/.claude/settings.json::env` (scrubbed). MCP children
   receive secrets via `op run --env-file=/dev/shm/coo-mcp-env/*.env`;
   gh-coo-wrap caches PAT values in tmpfs (`$XDG_RUNTIME_DIR/coo-gh-pat-cache/`)
   with a 5-minute TTL. Wrapper scripts that need a secret at call
   time use an inline `op read` resolver (pattern in
   `scripts/lifecycle/session-end-transcript-export.sh`)
6. Validates the PAT is actually for `vade-coo` — aborts loudly on
   mismatch

If `OP_SERVICE_ACCOUNT_TOKEN` is unset, the bootstrap is a silent
no-op and the cloud env comes up in plain VADE mode.

### 1Password vault contract

The service account must have **read** access to a vault named `COO`
containing the following items. Items marked *best-effort* may be
absent — their absence warns and disables the corresponding feature
without blocking boot.

| Item reference | Type | What it holds |
|---|---|---|
| `op://COO/vade-coo-self-2026-04` | API Credential | GitHub fine-grained PAT (`credential` field) |
| `op://COO/agentmail-vade-coo` | API Credential | AgentMail API key (`credential` field) |
| `op://COO/mem0-vade-coo` | API Credential | Mem0 Platform API key (`credential` field; prefix `m0-`) — powers the `mem0-rest.sh` fallback when the Mem0 MCP OAuth transport is degraded |
| `op://COO/vade-coo-auth` | SSH Key | GitHub auth key (`ed25519`) |
| `op://COO/vade-coo-sign` | SSH Key | GitHub signing key (`ed25519`) |
| `op://COO/cloudflare-api-token-vade-coo` | API Credential | *Best-effort.* Cloudflare API token (vade-app.dev zone scope) — Worker deploys, DNS edits |
| `op://COO/transcripts-r2-vade-coo` | API Credential | *Best-effort.* R2 access keys for transcript export |
| `op://COO/transcripts-age-key` | API Credential | *Best-effort.* age identity for transcript decryption (Stage-1 analyzer) |
| `op://COO/vade-coo-app-2026-05` | API Credential | *Best-effort.* GitHub App ID + installation ID for org-admin operations |

Fingerprints validated at boot:

- auth: `SHA256:9vxJc6c69L8eaR6CvwdZoYDco24W6yN6GkKwnsm8Uys`
- sign: `SHA256:pZeA8xycAtIsVGwhMzR3mg4KG05n9ksFuy4F1ZVXn3A`

Mismatch = boot fails. Rotate keys → update fingerprints in
`scripts/lib/common.sh` (`COO_AUTH_FP_EXPECTED`, `COO_SIGN_FP_EXPECTED`).

### Push fallback for the cloud git proxy

The Claude Code cloud sandbox routes git through a local proxy
(`http://local_proxy@127.0.0.1:<port>/git/<owner>/<repo>`) that
intermittently 403s on push and, separately, substitutes a token
without `workflow` scope on workflow-file pushes
([coo-harness#67](https://github.com/coo-labs/coo-harness/issues/67)).

`scripts/git-push-with-fallback.sh` wraps `git push` and, on a
proxy-class failure, retries once via
`https://vade-coo:${GITHUB_MCP_PAT}@github.com/<owner>/<repo>.git`,
preserving `vade-coo` attribution. Genuine failures (permission
denied, bad refspec, network down) pass through untouched with the
original exit status.

```bash
scripts/git-push-with-fallback.sh -u origin claude/my-branch
```

Requires `GITHUB_MCP_PAT` in env — populated by `coo-bootstrap.sh`
at session start.

### Extending to other sub-agents

The pattern is copyable. For a new agent (e.g., Night's Watch, PM
agent), create a parallel vault (`NIGHTS_WATCH`, `PM`), a parallel
service account, and either (a) clone `coo-bootstrap.sh` with the
new vault name, or (b) parameterize via a `VADE_AGENT_VAULT` env var
when this list grows past two. Keep the fingerprint-validation step
— cheap insurance against a wrong vault binding.

## Governance

Kernel design changes affect every COO session's boot; significant
changes require BDFL review. Governance reference:
[`coo-memory/identity/public-authority.md`](https://github.com/coo-labs/coo-memory/blob/main/identity/public-authority.md).

## License

Apache-2.0 (see [LICENSE](LICENSE)).
