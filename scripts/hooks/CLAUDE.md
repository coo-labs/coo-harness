# scripts/hooks/ — hook implementations

**Fail open. Always exit 0. Use the JSON `decision` block to refuse, NOT non-zero exit codes — non-zero crashes the hook chain for that session event.**

stdin/stdout contract by event type:

- **PreToolUse** — stdin: `{tool_name, tool_input, ...}`.
  Block: stdout `{"decision":"block","reason":"..."}`.
  Inject context: stdout `{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"..."}}`.
  Allow: print nothing.

- **PostToolUse** — stdin adds `tool_response`. Cannot block.
  Inject: stdout `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"..."}}`.

- **SessionStart / SessionEnd** — stdout is captured into the agent's persisted-output digest.
  Banners/context → stdout. Log chatter → stderr (`log()` in `../lib/common.sh`).

Wiring + tests:
1. Add the script here.
2. Wire it in `../../.claude/settings.json` under the right event + matcher.
3. Add `../ci/test-<script-name>.sh`.
4. Run `bash ../ci/run-bootstrap-regression.sh "$PWD"` against a scratch workspace.

Bypass env vars (grep `VADE_*_BYPASS=` for the live set): `VADE_GITHUB_API_GUARD_BYPASS`, `VADE_WORKFLOW_AUTH_GUARD_BYPASS`, `VADE_SKILL_YAML_GUARD_BYPASS`, `VADE_BRAKE_ENFORCE=warn|off`, `VADE_AGENT_ENV_SCRUB=warn|enforce|disabled`.

---

*If you notice contradictions between the substrate and this file, update it after finishing your current task.*
