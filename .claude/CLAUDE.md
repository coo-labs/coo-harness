# .claude/ — harness Claude Code config

`settings.json` changes that add or remove a hook command must also add or update the matching `scripts/ci/test-<script>.sh` and the entry in `run-bootstrap-regression.sh`'s list. CI catches mismatches at PR-open.

`_write_claude_settings_env` (in `../scripts/boot/coo-bootstrap.sh`) writes the `env` block via a positional-arg surface — coordinated change. Adding/removing env vars there is the gated path (see `coo-harness/CLAUDE.md` §"What requires explicit approval").

`outputStyle: coo` references `output-styles/coo.md`; do not rename that file without updating the setting.

`enableWorkflows: true` enables dynamic-workflow authoring (MEMO-2026-06-07-fkef). Leave on.

Hook implementations: [`../scripts/hooks/CLAUDE.md`](../scripts/hooks/CLAUDE.md).
Agent definitions: [`agents/README.md`](agents/README.md) — every agent's frontmatter requires `env_allowlist:`.

---

*If you notice contradictions between the substrate and this file, update it after finishing your current task.*
