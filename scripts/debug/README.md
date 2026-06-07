# bootstrap-trace — boot-architecture diagnostic harness

Single-purpose instrumentation for the COO boot pipeline review (paused
commission [coo-labs/coo-memory#762](https://github.com/coo-labs/coo-memory/issues/762)). Plan file:
`/root/.claude/plans/let-s-start-with-the-dapper-torvalds.md` (per-session;
not committed).

**What this is.** A hands-off observer that captures one ground-truth
artifact per container build: every command bash runs, every file write
under `~/.claude` / `~/.vade` / `~/.vade-cloud-state`, plus a filesystem
snapshot at every bash invocation entry. Output is for human reading
during the architecture review.

**What this is not.** A fix. A monitoring tool. A production primitive.
When the review concludes the harness is removed (one PR).

## How it engages

`BASH_ENV` is a bash mechanism: every non-interactive bash invocation
sources the file pointed at by `BASH_ENV` before its first command. Set
`BASH_ENV=/home/user/coo-harness/scripts/debug/bootstrap-trace-init.sh`
in the container settings UI permanently; the init script is a hard
no-op unless `VADE_BOOTSTRAP_TRACE_MODE=1` is also set. Flipping that
flag for one container build is the toggle.

The init then attaches `set -x`, an inotifywait watcher, and a
per-invocation snapshot — automatically, to every bash invocation that
runs in the container, including `cloud-setup.sh` at build time and the
SessionStart hook chain at session start. No existing script is
modified.

## Container UI configuration

In the Anthropic container settings UI, add these env vars alongside
the existing `OP_SERVICE_ACCOUNT_TOKEN`:

| Env var | Value | When |
|---------|-------|------|
| `BASH_ENV` | `/home/user/coo-harness/scripts/debug/bootstrap-trace-init.sh` | Permanent (init no-ops without the flag below). |
| `VADE_BOOTSTRAP_TRACE_MODE` | `1` | Only when capturing a trace. Unset (or remove) to disable. |
| `VADE_BOOTSTRAP_TRACE_DIR` | `/home/user/.vade/traces` | Optional. Default is the same value. |

Trigger a container rebuild (changing UI env vars typically does this).
The next session boots with the trace active.

## Output layout

```
~/.vade/traces/CURRENT_RUN_ID                # marker → current run dir name
~/.vade/traces/<run-id>/
  meta.json                                  # run_id, started_at, first init pid
  xtrace.log                                 # set -x output, all bash, all scripts
  file-events.log                            # inotifywait pipe-separated lines
  inotify.pid                                # PID of the inotifywait owner
  snapshots/
    <ts>-<tag>-<pid>/                        # one per bash invocation entry
      content/                               # diffable byte-for-byte
        settings.json
        settings.local.json
        dot-vade/coo-bootstrap.log
        dot-vade-cloud-state/integrity-check.json
        ...
      metadata/
        dot-claude.tsv                       # path size mtime mode
        home-user.tsv
        processes.txt
        env.txt                              # env minus secrets
```

Snapshot directories are sortable lexicographically by their timestamp
prefix. `ls snapshots/` gives chronological order.

## How to read the output

### What ran, in what order, where

```bash
TRACE=~/.vade/traces/$(cat ~/.vade/traces/CURRENT_RUN_ID)
less "$TRACE/xtrace.log"
```

Each line is a single bash command with prefix:
```
+ [<epoch.ns>] [pid=N bp=N] [<source>:<line> fn=<name>] <command>
```

### What got written when

```bash
cat "$TRACE/file-events.log"
# format: <timestamp>|<full path>|<event-list>
# example: 2026-05-15T22:30:01|/home/user/.claude/settings.json|MODIFY,CLOSE_WRITE
```

### Settings.json evolution across phases

```bash
# List snapshots in order:
ls "$TRACE/snapshots/"

# Diff settings.json between two phases:
diff "$TRACE/snapshots/<earlier>/content/settings.json" \
     "$TRACE/snapshots/<later>/content/settings.json"

# All settings.json snapshots, in time order:
for d in "$TRACE/snapshots/"*/content/settings.json; do
    echo "=== $d ==="
    cat "$d"
done | less
```

### What was running at a snapshot

```bash
cat "$TRACE/snapshots/<ts>-<tag>-<pid>/metadata/processes.txt"
```

### Env state at a snapshot

```bash
cat "$TRACE/snapshots/<ts>-<tag>-<pid>/metadata/env.txt"
```

(Token-shaped vars are stripped on the way out.)

### Interactive timeline (Chrome DevTools shape)

```bash
python3 /home/user/coo-harness/scripts/debug/render-trace-timeline.py
# → writes /tmp/trace-timeline.html (open in any browser)
```

One row per PID, lifespan bars, event markers for writes / invariant
decisions / merges / script entries, snapshot vertical lines colored
by `VADE_RUNTIME_DIR` presence in `settings.json`. Pan with scroll,
zoom with Ctrl/⌘+scroll, click any event for raw xtrace context.

Default view filters to the first 22 s of boot and hides dispatch /
guard / brief-git wrappers. Pass a different trace directory as the
first positional argument; second positional is the HTML output path.

Also surfaced as the `trace-timeline` skill — the agent will pick this
up when you ask it to "visualize" or "show" a trace.

### Upload to the Console viewer (preferred)

```bash
python3 /home/user/coo-harness/scripts/debug/upload-trace-bundle.py
# → POSTs the parsed data blob to console.vade-app.dev/trace/data
#   and prints the viewer URL: https://console.vade-app.dev/trace/?run-id=<id>
```

The uploader invokes `render-trace-timeline.py --json` to parse the
trace, then POSTs the data blob to the Console Worker, which writes it
to R2 at `vade-agent-transcripts/console-traces/<run-id>/data.json`
([coo-labs/coo-memory#832](https://github.com/coo-labs/coo-memory/issues/832)).
The Console's `/trace/` React route fetches the same data blob and
renders the timeline live, replacing the static-HTML flow above.

Auth: bearer token from `op://COO/console-token-2026-05/credential`
(or set `CONSOLE_TOKEN` in env). The R2 prefix is auth-gated on both
read and write. Pass `--dry-run` to parse + validate without uploading.
`--data-json <path>` skips parsing and uploads a pre-rendered blob —
useful for re-uploading a saved bundle.

## How to stop the trace

Three options, descending order of operational simplicity:

1. **Next container rebuild without the flag.** Remove `VADE_BOOTSTRAP_TRACE_MODE`
   (or set it to `0`) in the container UI; trigger a rebuild.
   `bootstrap-trace-init.sh` no-ops on every invocation; the inotifywait
   process dies with the container.
2. **Manually kill inotifywait and remove the CURRENT marker.**
   `kill $(cat ~/.vade/traces/<run-id>/inotify.pid); rm ~/.vade/traces/CURRENT_RUN_ID`.
   Subsequent `set -x` continues for any bash already running, but new
   bash invocations restart in a fresh run-id. Useful for dividing the
   trace into segments.
3. **Container destroy.** Natural endpoint.

## Fidelity notes

- **`set -x` is suppressed by `set +x`.** If a traced script explicitly
  disables xtrace (none currently do, but worth knowing), the trace
  pauses. PS4 prefix carries source/line, so reactivation is visible.
- **`BASH_ENV` only fires for non-interactive bash.** Interactive shells
  (a human typing in a terminal) do not source it. The boot pipeline
  is entirely non-interactive.
- **Anthropic's pre-clone phase is invisible.** Whatever runs before
  `/home/user/coo-harness/` exists cannot resolve `BASH_ENV`. The
  trace begins at the first bash invocation that occurs after the repo
  is on disk.
- **Inotifywait can miss events under burst load.** Rare for boot-pipeline
  scale. If observed, the next snapshot's metadata captures the
  resulting state.
- **Snapshot count grows.** Every bash invocation produces one. Hooks +
  helpers + sub-scripts: expect tens to a couple hundred per boot.
  Total trace size typically a few MB.
- **Existing EXIT traps.** This v1 does not chain onto pre-existing EXIT
  traps in target scripts. It does not set its own EXIT trap to avoid
  clobbering. Per-invocation snapshots fire on entry only; the next
  invocation's entry snapshot captures the prior's exit state.

## Sub-agent discipline

If follow-on Explore or Plan agents are dispatched against this work,
they MUST be pinned to Sonnet or Opus explicitly via the `model` field
— never Haiku.
