#!/usr/bin/env bash
# session-end-op-reads-roll — roll per-session tmpfs op-read jsonl
# events to a daily file under ~/.vade.
#
# Shipped by coo-harness#540 / briefing-40 §2.4. Fires from the
# SessionEnd hook chain (.claude/settings.json). The two sources:
#   /dev/shm/coo-op-reads-L2.<session_id>.jsonl   (op-coo-wrap.sh per-call)
#   /dev/shm/coo-pat-resolve-L1.<session_id>.jsonl (gh-coo-wrap.sh _resolve_pat)
# both append to one combined daily file:
#   ~/.vade/op-reads-YYYY-MM-DD.jsonl
#
# `layer` field on each line distinguishes L1 / L2 events. Append
# is file-locked via flock so concurrent SessionEnds can't interleave
# lines. Sources are deleted only after a successful append.
#
# Safe to run multiple times in one session (idempotent: source files
# are removed after roll, so a second run is a no-op).

set -u

LOG_DIR="${HOME}/.vade"
DATE="$(date -u +%Y-%m-%d)"
DAILY="$LOG_DIR/op-reads-${DATE}.jsonl"
LOCK="$LOG_DIR/.op-reads.lock"

mkdir -p "$LOG_DIR" 2>/dev/null || exit 0

# Locate sources. Wildcard expansion is filtered by `-f` check so an
# empty match doesn't roll the literal path.
shopt -s nullglob
declare -a sources=()
for src in /dev/shm/coo-op-reads-L2.*.jsonl /dev/shm/coo-pat-resolve-L1.*.jsonl; do
  [ -s "$src" ] && sources+=("$src")
done

if [ "${#sources[@]}" -eq 0 ]; then
  exit 0
fi

# flock the daily file; append each source then remove it.
{
  flock -x 9 2>/dev/null || exit 0
  for src in "${sources[@]}"; do
    cat "$src" >> "$DAILY" 2>/dev/null && rm -f "$src" 2>/dev/null || true
  done
} 9> "$LOCK"

# Best-effort: keep daily file bounded (10MB cap, keeps last lines).
# Per-session is capped at 10K events × ~300B = ~3MB; daily over many
# sessions can grow. 10MB is ~33K events, plenty of headroom for any
# rollup-script query without exhausting disk.
if [ -f "$DAILY" ] && [ "$(wc -c < "$DAILY" 2>/dev/null || echo 0)" -gt 10485760 ]; then
  {
    flock -x 9 2>/dev/null || exit 0
    tail -c 5242880 "$DAILY" > "${DAILY}.tmp" 2>/dev/null \
      && mv -f "${DAILY}.tmp" "$DAILY" 2>/dev/null \
      || rm -f "${DAILY}.tmp" 2>/dev/null
  } 9> "$LOCK"
fi

exit 0
