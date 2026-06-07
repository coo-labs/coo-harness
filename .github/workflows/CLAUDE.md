# .github/workflows/ — CI workflows

**Writing/editing files here triggers the OAuth-scope wall.** The session's OAuth token does not carry `workflow` scope; `git push` of a workflow change is rejected with "refusing to allow an OAuth App ... without `workflow` scope". The `workflow-file-auth-guard.sh` PreToolUse hook fires on Write/Edit and injects the recipe.

Canonical push path — use the `vade-coo` App install token via the contents-API:
```sh
GH_USE_APP_TOKEN=1 gh api -X PUT \
  repos/coo-labs/coo-harness/contents/.github/workflows/<file>.yml \
  -f branch=<branch> -f sha=<current-sha> -f content=<base64>
```
Helper: `../../scripts/gh-put-workflow.sh`.

`bootstrap-regression.yml` is the kernel's CI backstop. Do NOT weaken it by expanding `VADE_CI_ALLOWLIST` without a cited rationale in the PR commit.

PR-open changes here run the full bootstrap-regression suite end-to-end in fake-env mode against a staged `/home/user`.

---

*If you notice contradictions between the substrate and this file, update it after finishing your current task.*
