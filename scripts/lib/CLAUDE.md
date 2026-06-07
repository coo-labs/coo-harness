# scripts/lib/ — shared helpers (sourced, not entry points)

**Editing `common.sh` is a global change.** It is sourced by every boot script and most hooks. Bootstrap-regression CI must pass after any edit.

Logging functions are NOT interchangeable:
- `log "..."` → stderr only; human-readable chatter.
- `boot_log_record <script> <phase> [ok|fail|skip] [k=v...]` → JSONL appended to `$HOME/.vade/boot.log` (session-scope, reset on container restart). Use from SessionStart/End hooks.
- `build_log_record <status> <message>` → appended to `$VADE_CLOUD_STATE_DIR/build.log` (snapshot-persistent, survives resume). Use from `cloud-setup.sh` ONLY — NOT from SessionStart hooks.

`integrity-group-s.sh` is NOT standalone — sourced by `integrity-check.sh` only. It calls `_add` defined in the parent scope; standalone execution emits "command not found".

`lib/transcripts/` Python library — imported, not sourced. `sys.path` insert uses `parents[N]` where N depends on the calling script's depth: top-level `scripts/<x>.py` → `parents[1]`; nested `scripts/<sub>/<x>.py` → `parents[2]`. Never `pip install transcripts` — private.

---

*If you notice contradictions between the substrate and this file, update it after finishing your current task.*
