# scripts/lifecycle/ — session lifecycle + transcript export

**`session-end-transcript-export.sh` has a hard-won detach model. Do not break it.** Two production outages (coo-harness#181/182 and #198) landed the current pattern:

1. `setsid -f` forks the Python into a new process session so a harness PG-kill of the SessionEnd hook (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS mode) does not kill the export child.
2. The bash wrapper block-waits up to `VADE_TRANSCRIPT_EXPORT_BUDGET_SEC` (default 20s) for the child. Holds SessionEnd open so the container grace window covers the 5–10s export pipeline (boto3 import + redact + age-encrypt + R2 PutObject).

Never replace `setsid -f ... &` + `wait $child_pid` with a plain fork or `exec`. Always exit 0; write `<id>.export-error.txt` on failure — never propagate Python exceptions to the hook wrapper.

`post-bootstrap-chain.sh` children (in `../boot/`) must remain fast (<2s) — they block the chain. Digest scripts here (`coo-identity-digest.sh`, `discussions-digest.sh`, `project-board-digest.sh`) print captured context to stdout; log chatter goes to stderr.

`session-idle-watchdog.sh --start` is armed by the chain and triggers the idle-fire close path.
