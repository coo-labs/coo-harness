# scripts/ci/ — bootstrap regression suite

**Every bootstrap change needs a paired test.** Name: `test-<thing-being-tested>.sh`. Wire it into `run-bootstrap-regression.sh`'s list.

Local-run footgun — avoid clobbering `/home/user`:
```sh
VADE_CI_WORKSPACE_ROOT=/tmp/vade-ci-workspace \
  bash scripts/ci/run-bootstrap-regression.sh "$PWD"
```
`SOURCE_DIR` (arg 1) MUST NOT equal `$VADE_CI_WORKSPACE_ROOT/coo-harness` — the stage step does `rm -rf` on the destination first.

`mocks/` contract:
- `curl` intercepts ONLY `api.github.com/user`; other URLs forward to `$VADE_CI_REAL_CURL`.
- `op` returns canned vade-coo-shaped responses for PAT / SSH key / AgentMail / Mem0 lookups.
- When bootstrap adds a new 1Password read OR a new HTTP endpoint, update the matching mock in the same PR — or tests will silently forward live traffic or return empty data.

`VADE_CI_ALLOWLIST` — use to acknowledge known-failing invariants (E1–E4 always skip in CI by design, F1–F4 skip on stub coo-memory). Cite the reason in commit/PR. Empty the allowlist once the underlying issue is fixed.

`fixtures/` — point tests at fixtures by name; do not hard-code absolute paths.

---

*If you notice contradictions between the substrate and this file, update it after finishing your current task.*
