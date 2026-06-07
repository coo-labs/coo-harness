#!/usr/bin/env python3
# Boot-brake PreToolUse guard. Reads Claude Code's PreToolUse JSON on
# stdin, returns a hookSpecificOutput JSON on stdout that either allows
# (silent) or denies (with sanitized reason). Always exits 0; behavior
# is controlled via emitted JSON.
#
# Implements coo-memory#1082 v2 design (Phase 0) per the #1109 commission.
# Canonical design: coo-memory/_drafts/2026-05-27_boot-brake-architecture-v2.md
#
# Architecture:
#   - First check the override sentinel ($HOME/.vade/boot-brake-override.<sid>.json):
#     HMAC valid + session_id matches + unexpired → allow (logged).
#   - Else read the cached sentinel ($VADE_CLOUD_STATE_DIR/boot-brake.<sid>.json):
#     OK → allow; FAIL → check whitelist; PENDING → allow or deny per mode.
#   - On cache miss / content-hash mismatch / manifest_version change /
#     1s backpressure-cap expiry: re-validate the deliverables manifest
#     ($VADE_COO_MEMORY_DIR/operations/boot-deliverables.yml).
#   - Atomic sentinel writes via tmp+rename.
#   - Append-only event log at $VADE_CLOUD_STATE_DIR/brake-events.jsonl.
#   - Read tool calls tracked at $HOME/.vade/session-reads.<sid>.log
#     (used by the identity_consumed check_kind).
#
# Enforcement mode (VADE_BRAKE_ENFORCE env):
#   - off:           guard disabled (always allow)
#   - warn (default): FAIL/PENDING log but allow (Phase 0 soak)
#   - block-on-FAIL: FAIL denies, PENDING allows (Phase 1)
#   - block-strict:  FAIL and PENDING both deny (Phase 2)
#
# Whitelist in FAIL/PENDING (block mode): Read + Grep only.
#
# Failure modes that this guard handles WITHOUT locking the agent out:
#   - Unparseable sentinel → treat as missing, re-validate, write diagnostic
#     to $VADE_CLOUD_STATE_DIR/boot-brake-faults/<ts>.log
#   - Validator self-fault (manifest unreadable, yaml broken, etc.) → state=FAIL
#     with cause=validator_self_fault, diagnostic to faults log
#   - Disk full / IO error → guard logs to stderr and allows (fail-OPEN on
#     guard infrastructure failure is intentional in Phase 0; the brake
#     should not be the source of session bricking — capability-fault
#     posture targets discipline failures, not its own infrastructure)
#
# This script is invoked via boot-brake-guard.sh which forwards stdin/env.

import hashlib
import hmac
import json
import os
import re
import string
import sys
import time
import traceback
from pathlib import Path


_SAFE_CHARSET = set(string.ascii_letters + string.digits + " ._/:-")

# Permitted syntax for has_jq_path check_arg values (coo-memory#1168 O15).
# The homegrown walker below intentionally implements a strict subset of
# jq syntax: a leading identifier, then zero or more `.identifier` or
# `[<digits>]` accessors. Validating at check time keeps malformed
# manifest entries from raising generic exceptions; the deny reason
# names the offending value so an operator can fix the manifest.
# Anything richer (filters, alternatives, recursive descent) requires
# spawning real jq, which is rejected here on hot-path-cost grounds —
# this guard fires on every PreToolUse.
_JQ_PATH_SAFE_RE = re.compile(
    r"^\.?[A-Za-z0-9_]+(\[\d+\])?(\.[A-Za-z0-9_]+(\[\d+\])?)*$"
)


def sanitize(s, max_len=240):
    """Strip any char outside the safe set; truncate. v2 §4 (R2#6).

    Untrusted interpolated values (deliverable ids, producer names,
    reason text from file paths, error class names) pass through this
    before reaching the agent's tool-feedback context. The safe set is
    [A-Za-z0-9 ._/:-] — no shell metachars, no sentence delimiters that
    could carry injection-style instructions.
    """
    if s is None:
        return ""
    out = "".join(ch for ch in str(s) if ch in _SAFE_CHARSET)
    if len(out) > max_len:
        out = out[:max_len] + "..."
    return out


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# SH2 (coo-memory#1167): per-session brake key written by
# boot-brake-clear.sh at $HOME/.vade/brake-key.<session_id> (mode 0600,
# 64 hex chars = 32 random bytes). Replaces the prior derivation that
# reused OP_SERVICE_ACCOUNT_TOKEN as the HMAC root — that widened the
# SA-token exposure surface (Read /proc/self/environ) and let any
# process holding it forge overrides. Per-session keying scopes forgery
# resistance to the file system, which Read can no longer touch
# (read-boot-inlined-guard.sh denies brake-key.* lookups).
def load_brake_key(home, session_id):
    """Return per-session HMAC key bytes, or None if unavailable.

    Failing closed (no key → no valid HMAC) is intentional: an override
    sentinel written without a matching key is structurally rejected.
    """
    key_path = Path(home) / ".vade" / f"brake-key.{session_id}"
    try:
        with open(key_path, "rb") as fh:
            data = fh.read().strip()
        if len(data) != 64:
            return None
        return bytes.fromhex(data.decode("ascii"))
    except (OSError, ValueError):
        return None


def compute_hmac(granted_at, expires_at, session_id, reason, key):
    """HMAC over length-prefixed canonical form.

    Length-prefixing closes the delimiter-injection attack: a `reason`
    containing `|` cannot produce a colliding MAC by reshuffling fields
    (security-review SC3). `expires_at` is included in the MAC scope so
    a captured override cannot have its TTL extended (security-review
    SC1). `key` is the per-session brake-key bytes (SH2 / #1167); the
    unbrake.sh writer must source the same file. Field order is fixed.
    """
    parts = (str(granted_at), str(expires_at), str(session_id), str(reason))
    msg = "|".join(f"{len(p)}:{p}" for p in parts).encode("utf-8")
    return hmac.new(key, msg, hashlib.sha256).hexdigest()


def parse_iso_epoch(iso_str):
    """Polish P3 (coo-memory#1167): parse ISO-8601 to epoch seconds.

    Returns None if unparseable. Tolerates both `Z` and `.fffZ` suffixes.
    The override-sentinel `expires_at` comparison uses this instead of
    lexicographic string compare so a mixed-precision timestamp pair
    (one with milliseconds, one without) doesn't misorder.
    """
    if not iso_str:
        return None
    try:
        clean = str(iso_str).split(".")[0].rstrip("Z")
        return time.mktime(time.strptime(clean, "%Y-%m-%dT%H:%M:%S")) - time.timezone
    except (ValueError, OverflowError, TypeError):
        return None


def atomic_write_json(path, payload):
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        Path(tmp).parent.mkdir(parents=True, exist_ok=True)
        with open(tmp, "w") as fh:
            json.dump(payload, fh, separators=(",", ":"))
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        return True
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


# brake-events.jsonl schema version. Bump on any breaking change to the
# event shape so a Phase 1 aggregator can detect format breaks across the
# accumulated soak data (coo-memory#1168 O1). Every event line carries
# this as "v"; it is injected centrally in append_event below.
EVENT_SCHEMA_VERSION = 1


def _sanitize_event_values(obj):
    """SH3 (coo-memory#1167): recursively sanitize string values for
    log-write safety. Centralises sanitisation at the write boundary so
    every append_event callsite is covered uniformly — attacker-controlled
    paths, deliverable ids, producer names, etc. land in brake-events.jsonl
    already stripped of shell metachars and sentence delimiters, closing
    the prompt-injection path that lets a later Read of the event log
    smuggle instructions back into agent context.
    """
    if isinstance(obj, dict):
        return {k: _sanitize_event_values(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_sanitize_event_values(v) for v in obj]
    if isinstance(obj, str):
        return sanitize(obj, max_len=500)
    return obj


def append_event(state_dir, event):
    path = Path(state_dir) / "brake-events.jsonl"
    try:
        if "v" not in event:
            event = {"v": EVENT_SCHEMA_VERSION, **event}
        event = _sanitize_event_values(event)
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a") as fh:
            fh.write(json.dumps(event, separators=(",", ":")) + "\n")
        # M3 (coo-memory#1167): event log contains session-identifying
        # material; match the override sentinel's 0600 mode rather than
        # inherit umask default (likely 0644).
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
    except Exception:
        pass


def append_session_read(home, session_id, file_path):
    log = Path(home) / ".vade" / f"session-reads.{session_id}.log"
    try:
        log.parent.mkdir(parents=True, exist_ok=True)
        with open(log, "a") as fh:
            fh.write(f"{now_iso()}\t{file_path}\n")
    except Exception:
        pass


def session_has_read(home, session_id, predicate):
    log = Path(home) / ".vade" / f"session-reads.{session_id}.log"
    if not log.exists():
        return False
    try:
        with open(log) as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t", 1)
                if len(parts) == 2 and predicate(parts[1]):
                    return True
    except Exception:
        return False
    return False


def write_fault(state_dir, message, exc=None):
    faults_dir = Path(state_dir) / "boot-brake-faults"
    try:
        faults_dir.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        path = faults_dir / f"{stamp}.{os.getpid()}.log"
        with open(path, "w") as fh:
            fh.write(f"{now_iso()} {message}\n")
            if exc is not None:
                fh.write(traceback.format_exc())
        return str(path)
    except Exception:
        return None


# SessionStart producers tracked by the race-gate (Sys-Eng C3). When
# the first PreToolUse fires while these are still running, the brake
# stays PENDING rather than emit phantom FAILs that pollute the 7-day
# soak signal. Only producers of the manifest's critical deliverables
# go here:
#   - session-start-sync produces user_settings_json AND drives
#     integrity-check.sh (integrity_check_json)
#   - coo-bootstrap produces bootstrap_marker
#   - coo-identity-digest produces the persisted-output file that
#     triggers the identity_consumed predicate when the digest overflows
# memo-index, discussions-digest, project-board-digest, and the
# idle-watchdog are intentionally NOT tracked — they don't produce
# manifest entries, so we don't wait on them.
PRODUCERS_TO_TRACK = (
    "session-start-sync",
    "coo-bootstrap",
    "coo-identity-digest",
)

# A producer is treated as "done" if either:
#   - phase=end has been logged for this session, OR
#   - phase=start has been logged AND elapsed > this threshold
# The start-based fallback tolerates early-exit skip paths (e.g.
# coo-bootstrap.sh's "marker present this container" branch which
# does `trap - EXIT; exit 0` and never writes phase=end).
PRODUCER_DONE_THRESHOLD_SECONDS = 15.0

# Wall-clock grace window when boot.log is unavailable (Sys-Eng C3
# fallback). The v2 design wanted producer end-markers as the primary
# mechanism; this is the documented degradation path.
# Overridable via VADE_BRAKE_RACE_GRACE_SECONDS (CI tests set it to 0
# to bypass the race window; production should leave it at the default).
def _race_grace_seconds():
    raw = os.environ.get("VADE_BRAKE_RACE_GRACE_SECONDS", "")
    if not raw:
        return 30.0
    try:
        return float(raw)
    except ValueError:
        return 30.0


def boot_producers_complete(home, session_id):
    """Returns (all_complete, missing_producers).

    Reads $HOME/.vade/boot.log (newline-delimited JSON) for entries
    scoped to this session_id. A producer is treated as complete if
    either:
      - phase=end has been logged (the canonical signal), OR
      - phase=start has been logged AND elapsed since that start
        exceeds PRODUCER_DONE_THRESHOLD_SECONDS (tolerates early-exit
        skip paths that don't write phase=end — e.g. coo-bootstrap.sh's
        "marker present this container" branch does `trap - EXIT; exit
        0` without firing the _on_exit trap that would have logged the
        end marker).

    Returns (None, []) when boot.log is missing or unreadable so the
    caller can fall back to the wall-clock grace heuristic.
    """
    log = Path(home) / ".vade" / "boot.log"
    if not log.exists():
        return None, []
    completed = set()
    started = {}  # producer name → earliest start epoch
    try:
        with open(log) as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("session") != session_id:
                    continue
                script = rec.get("script")
                phase = rec.get("phase")
                if not script or not phase:
                    continue
                if phase == "end":
                    completed.add(script)
                elif phase == "start":
                    ts = rec.get("ts", "")
                    try:
                        # ts is e.g. "2026-06-03T11:22:53.123Z" — slice
                        # the fractional seconds before strptime.
                        ts_clean = ts.split(".")[0].rstrip("Z")
                        start_epoch = time.mktime(time.strptime(
                            ts_clean, "%Y-%m-%dT%H:%M:%S"
                        )) - time.timezone
                    except (ValueError, OverflowError):
                        continue
                    if script not in started or start_epoch < started[script]:
                        started[script] = start_epoch
    except OSError:
        return None, []

    now = time.time()
    missing = []
    for p in PRODUCERS_TO_TRACK:
        if p in completed:
            continue
        if p in started and (now - started[p]) > PRODUCER_DONE_THRESHOLD_SECONDS:
            continue
        missing.append(p)
    return (len(missing) == 0), missing


def load_yaml_manifest(manifest_path):
    try:
        import yaml
    except ImportError:
        return None, "pyyaml not available"
    try:
        with open(manifest_path) as fh:
            data = yaml.safe_load(fh)
        return data, None
    except FileNotFoundError:
        return None, f"manifest not found at {manifest_path}"
    except Exception as e:
        return None, f"manifest unparseable: {type(e).__name__}: {e}"


def verify_manifest_pin(manifest_path, env):
    """SH1 (coo-memory#1167): verify manifest content-hash against
    VADE_BRAKE_MANIFEST_SHA256 pinned in the cloud env.

    A warn-mode session could Edit/Write the manifest and silently
    neuter a deliverable; when the brake later flips back to block-mode
    the tampered manifest would be enforced. Pinning the expected
    SHA256 in settings.json env (rewritten in lockstep with manifest
    changes) makes the tamper detectable: hash mismatch becomes a
    validator self-fault.

    Returns (ok, expected_sha, actual_sha). When the pin is unset the
    check is opt-in and returns ok=True with shas=None — the migration
    posture. Future PRs may flip to required.
    """
    expected = (env.get("VADE_BRAKE_MANIFEST_SHA256") or "").strip().lower()
    if not expected:
        return True, None, None
    try:
        with open(manifest_path, "rb") as fh:
            actual = hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return False, expected, None
    if actual != expected:
        return False, expected, actual
    return True, expected, actual


def resolve_path(entry, env):
    raw = entry.get("path", "")
    root = entry.get("root", "")
    expanded = raw
    for var in ("VADE_CLOUD_STATE_DIR", "VADE_COO_MEMORY_DIR", "VADE_RUNTIME_DIR", "HOME"):
        expanded = expanded.replace(f"${var}", env.get(var, ""))
    if root and not expanded.startswith("/"):
        root_v = env.get(root, "") if not root.startswith("/") else root
        for var in ("VADE_CLOUD_STATE_DIR", "VADE_COO_MEMORY_DIR", "VADE_RUNTIME_DIR", "HOME"):
            root_v = root_v.replace(f"${var}", env.get(var, ""))
        expanded = str(Path(root_v) / expanded)
    return expanded


def sha1_file(path):
    h = hashlib.sha1()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None


def check_deliverable(entry, env, home, session_id, cwd):
    """Returns (ok: bool, reason: str, content_hash: str|None, signals: list).

    `signals` is a list of diagnostic events that should land in
    brake-events.jsonl. Most check_kinds return []. The read_observed
    branch returns a signal when its predicate glob is configured but
    matches zero non-trivial files (SRE F5) — that's the symptom of a
    drifted path convention silently disabling the §11 invariant.
    """
    kind = entry.get("check_kind", "exists")
    path = resolve_path(entry, env)

    if kind == "exists":
        if Path(path).exists():
            return True, "", sha1_file(path), []
        return False, f"missing: {path}", None, []

    if kind == "parses_json":
        try:
            with open(path) as fh:
                content = fh.read()
            json.loads(content)
            return True, "", hashlib.sha1(content.encode()).hexdigest(), []
        except FileNotFoundError:
            return False, f"missing: {path}", None, []
        except Exception as e:
            return False, f"unparseable: {type(e).__name__}", None, []

    if kind == "symlink_to":
        target = entry.get("check_arg", "")
        for var in ("VADE_CLOUD_STATE_DIR", "VADE_COO_MEMORY_DIR", "VADE_RUNTIME_DIR", "HOME"):
            target = target.replace(f"${var}", env.get(var, ""))
        try:
            if not Path(path).is_symlink():
                return False, f"not a symlink: {path}", None, []
            resolved = os.path.realpath(path)
            expected = os.path.realpath(target) if target else None
            if expected and resolved != expected:
                return False, f"symlink target drift: {path}", None, []
            return True, "", hashlib.sha1(resolved.encode()).hexdigest(), []
        except Exception as e:
            return False, f"symlink check error: {type(e).__name__}", None, []

    if kind == "has_jq_path":
        jq_path = entry.get("check_arg", "")
        if not _JQ_PATH_SAFE_RE.match(jq_path or ""):
            # coo-memory#1168 O15: refuse anything outside the documented
            # subset. A typo or richer-than-supported expression should
            # land as a deliverable failure naming the offending value,
            # not silently degrade through the generic exception arm.
            return False, f"unsupported jq path syntax: {sanitize(jq_path)}", None, []
        try:
            with open(path) as fh:
                content = fh.read()
            data = json.loads(content)
            cur = data
            for segment in jq_path.strip(".").split("."):
                if segment.endswith("]"):
                    name, idx = segment[:-1].split("[", 1)
                    if name:
                        cur = cur[name]
                    cur = cur[int(idx)]
                elif segment:
                    if isinstance(cur, list):
                        cur = cur[int(segment)]
                    else:
                        cur = cur[segment]
            return True, "", hashlib.sha1(content.encode()).hexdigest(), []
        except FileNotFoundError:
            return False, f"missing: {path}", None, []
        except (KeyError, IndexError):
            return False, f"jq path missing: {jq_path}", None, []
        except Exception as e:
            return False, f"check error: {type(e).__name__}", None, []

    if kind == "read_observed":
        # The identity_consumed kind from v2 §11. The check_arg is a
        # regex pattern; the deliverable is satisfied when ANY Read tool
        # call observed in this session matches the pattern. Conditional:
        # if the predicate glob matches no non-trivial files, the digest
        # didn't overflow and the check is no-op.
        signals = []
        predicate_glob = entry.get("predicate_exists_glob", "")
        if predicate_glob:
            import glob
            expanded_glob = predicate_glob
            for var in ("VADE_CLOUD_STATE_DIR", "VADE_COO_MEMORY_DIR", "VADE_RUNTIME_DIR", "HOME"):
                expanded_glob = expanded_glob.replace(f"${var}", env.get(var, ""))
            # Resolve the parent directory before glob-escape so the
            # convention-drift heuristic below can iterdir() the literal
            # filesystem path (coo-memory#1175). The glob-escaped form
            # is for matching only.
            literal_parent = os.path.dirname(expanded_glob)
            literal_parent = literal_parent.replace(
                "$CWD_DASHIFIED", cwd.replace("/", "-")
            ).replace("$SESSION_ID", session_id)
            # Polish P2 (coo-memory#1167): escape glob metacharacters in
            # substituted values so a malicious cwd / session_id can't
            # reshape the glob (e.g. inject `*` or `[` into the literal
            # subdirectory the predicate is supposed to be checking).
            expanded_glob = expanded_glob.replace(
                "$CWD_DASHIFIED", glob.escape(cwd.replace("/", "-"))
            )
            expanded_glob = expanded_glob.replace(
                "$SESSION_ID", glob.escape(session_id)
            )
            try:
                matches = glob.glob(expanded_glob)
            except Exception:
                matches = []
            # Filter to non-trivial files (> 1KB indicates real overflow)
            substantive = []
            for m in matches:
                try:
                    if Path(m).stat().st_size > 1024:
                        substantive.append(m)
                except OSError:
                    continue
            if not substantive:
                # Two cases collapse here (coo-memory#1175):
                #   (a) parent dir absent OR contains no hook-prefixed
                #       files — digest fit inline, nothing persisted,
                #       gate is correctly no-op. Suppress diagnostic.
                #   (b) parent dir contains hook-prefixed files but none
                #       match the predicate suffix — Claude Code
                #       file-naming may have drifted; fire diagnostic.
                # Pre-#1175 the diagnostic fired in (a) too, polluting
                # the signal so case (b) became hard to spot.
                has_hook_files = False
                try:
                    for f in Path(literal_parent).iterdir():
                        if f.name.startswith("hook-"):
                            has_hook_files = True
                            break
                except OSError:
                    pass
                if has_hook_files:
                    signals.append({
                        "type": "predicate_unmatched",
                        "deliverable": entry.get("id", "unknown"),
                        "expanded_glob": sanitize(expanded_glob),
                        "matches_total": len(matches),
                    })
                return True, "predicate not present; check skipped", None, signals
        pattern = entry.get("check_arg", "")
        try:
            rx = re.compile(pattern)
        except re.error as e:
            return False, f"bad regex: {type(e).__name__}", None, []
        if session_has_read(home, session_id, lambda fp: rx.search(fp) is not None):
            return True, "", None, []
        return False, f"identity layer overflowed but agent has not yet Read it", None, []

    return False, f"unknown check_kind: {kind}", None, []


def validate_manifest(manifest, env, home, session_id, cwd):
    """Returns (state, failures, content_hashes, manifest_version, signals)."""
    if not manifest or "deliverables" not in manifest:
        return "FAIL", [{"deliverable": "manifest", "reason": "no deliverables key"}], {}, 0, []

    manifest_version = manifest.get("manifest_version", 1)
    failures = []
    hashes = {}
    signals = []

    for entry in manifest.get("deliverables", []):
        dlid = entry.get("id", "unknown")
        ok, reason, ch, entry_signals = check_deliverable(entry, env, home, session_id, cwd)
        if ch is not None:
            hashes[dlid] = ch
        if entry_signals:
            signals.extend(entry_signals)
        if not ok:
            if entry.get("severity", "critical") == "critical":
                failures.append({
                    "deliverable": dlid,
                    "reason": reason,
                    "producer": entry.get("producer", "unknown"),
                })

    state = "OK" if not failures else "FAIL"
    return state, failures, hashes, manifest_version, signals


def read_cached_sentinel(path):
    try:
        with open(path) as fh:
            return json.load(fh), None
    except FileNotFoundError:
        return None, "missing"
    except (json.JSONDecodeError, ValueError) as e:
        return None, f"unparseable: {type(e).__name__}"
    except Exception as e:
        return None, f"read error: {type(e).__name__}"


def check_override(home, session_id, parent_session_id=""):
    """Returns (allowed, info_dict|None).

    Rejects forged overrides per security review and SH-series patches:
      - SH4 (coo-memory#1167): if `parent_session_id` is set and differs
        from `session_id`, this is a sub-agent invocation. Refuse the
        override regardless of the file's session_id field — the
        parent's `/unbrake` must not propagate down dispatch.
      - SH2 (coo-memory#1167): HMAC is keyed by the per-session
        brake-key file at $HOME/.vade/brake-key.<session_id>. If the
        file is missing or malformed, no HMAC can validate.
      - Polish P3 (coo-memory#1167): expires_at comparison parses to
        epoch seconds and compares numerically — mixed-precision ISO
        strings would misorder under lexicographic compare.
      - Empty/missing expires_at → treated as already expired (SC2).
      - expires_at is in the HMAC scope (SC1) so a captured override
        cannot be tampered to extend its TTL.
      - session_id mismatch → reject (does not propagate to sub-agents).
    """
    if parent_session_id and parent_session_id != session_id:
        return False, {
            "failure": "parent_session_mismatch",
            "parent_session_id": parent_session_id,
        }

    path = Path(home) / ".vade" / f"boot-brake-override.{session_id}.json"
    if not path.exists():
        return False, None
    try:
        with open(path) as fh:
            ovr = json.load(fh)
    except Exception:
        return False, None

    expires_at = ovr.get("expires_at", "")
    if not expires_at:
        return False, {"failure": "missing_expires_at"}
    exp_epoch = parse_iso_epoch(expires_at)
    if exp_epoch is None:
        return False, {"failure": "unparseable_expires_at"}
    if exp_epoch < time.time():
        return False, {"failure": "expired", "expired_at": expires_at}
    if ovr.get("session_id") != session_id:
        return False, {"failure": "session_mismatch"}

    key = load_brake_key(home, session_id)
    if key is None:
        return False, {"failure": "no_brake_key"}

    expected_hmac = compute_hmac(
        ovr.get("granted_at", ""),
        expires_at,
        ovr.get("session_id", ""),
        ovr.get("reason", ""),
        key,
    )
    if not hmac.compare_digest(expected_hmac, ovr.get("hmac", "")):
        return False, {"failure": "hmac_mismatch"}

    return True, {"reason": ovr.get("reason", ""), "expires_at": expires_at}


def emit_allow(extra_event=None, state_dir=None):
    if extra_event and state_dir:
        append_event(state_dir, extra_event)
    sys.stdout.write("")
    sys.exit(0)


def emit_deny(reason, event=None, state_dir=None):
    """reason is assumed pre-sanitized by the caller — interpolated
    untrusted values must already have gone through sanitize(). The
    format string itself is trusted and uses only safe-set delimiters.
    """
    if event and state_dir:
        append_event(state_dir, event)
    if len(reason) > 1500:
        reason = reason[:1500] + "..."
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    sys.stdout.write(json.dumps(out))
    sys.exit(0)


def _strip_consumed_suffix(dlid):
    """`charter_consumed` -> `charter`; leaves non-suffixed ids intact."""
    suffix = "_consumed"
    s = str(dlid)
    return s[: -len(suffix)] if s.endswith(suffix) else s


def format_failures(failures):
    """Render the failing-deliverables summary for a deny reason.

    Identity-stack `read_observed` entries (id ending `_consumed`)
    collapse into a single directive when 2+ are failing — the typical
    first-boot pattern, where listing each at ~80 chars blows past
    readable density (coo-memory#1169 deny-reason ergonomics). Other
    failures render individually, capped at 3 with a "plus N more" tail.
    All interpolated values are sanitized; separators are safe-set only.
    """
    consumed = [f for f in failures if str(f.get("deliverable", "")).endswith("_consumed")]
    other = [f for f in failures if not str(f.get("deliverable", "")).endswith("_consumed")]

    segments = []
    if len(consumed) >= 2:
        names = " ".join(
            sanitize(_strip_consumed_suffix(f.get("deliverable", "unknown")))
            for f in consumed
        )
        segments.append(
            "identity stack not consumed: " + names
            + " -- Read the corresponding identity .md files and any "
            "persisted boot digest before proceeding"
        )
    else:
        for f in consumed:
            segments.append(
                f"{sanitize(f.get('deliverable', 'unknown'))}: {sanitize(f.get('reason', ''))}"
            )

    shown_other = other[:3]
    for f in shown_other:
        segments.append(
            f"{sanitize(f.get('deliverable', 'unknown'))}: {sanitize(f.get('reason', ''))}"
        )
    overflow = len(other) - len(shown_other)
    if overflow > 0:
        segments.append(f"plus {overflow} more")

    return " -- ".join(segments) if segments else "none"


# Tools that may run even when the brake is FAIL/PENDING under block-mode.
# Restricted to non-substrate-affecting reads and in-session-memory updates:
#   - Read, Grep, Glob  : filesystem inspection (no writes, no network)
#   - AskUserQuestion   : agent → user clarification (no substrate effect)
#   - TodoWrite         : in-session memory only (doesn't escape)
# Surfaced by the 2026-06-03 soak verification: AskUserQuestion was the
# most-impactful ergonomics gap — a brake-blocked instance trying to ask
# Ven "what should I do?" was being denied as if it were a write tool.
# Every other tool (Bash, Edit, Write, Skill, Task, MCP writes, WebFetch,
# WebSearch, Monitor, NotebookEdit) stays denied — the threat model is
# unchanged.
WHITELIST_TOOLS = {"Read", "Grep", "Glob", "AskUserQuestion", "TodoWrite"}


def main():
    # Read hook input from stdin (Claude Code PreToolUse JSON)
    raw = sys.stdin.read()
    if not raw.strip():
        sys.exit(0)
    try:
        event = json.loads(raw)
    except Exception:
        sys.exit(0)

    tool_name = event.get("tool_name", "")
    tool_input = event.get("tool_input", {}) or {}
    raw_session_id = event.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID", "unknown")
    parent_session_id = event.get("parent_session_id", "") or ""
    cwd = event.get("cwd") or os.environ.get("PWD", "/home/user")

    env = os.environ
    home = env.get("HOME", "/root")
    state_dir = env.get("VADE_CLOUD_STATE_DIR", f"{home}/.vade-cloud-state")

    mode = env.get("VADE_BRAKE_ENFORCE", "warn").lower()
    if mode == "off":
        sys.exit(0)

    # Polish P1 (coo-memory#1167): validate session_id to a safe charset
    # before threading it into file-path construction (override sentinel,
    # session-reads log, boot-brake.<sid>.json, glob substitutions).
    # An invalid session_id is replaced with "unknown" and logged — the
    # brake stays functional but attacker-shaped session_ids cannot form
    # arbitrary paths. Same treatment for parent_session_id.
    if re.fullmatch(r"[A-Za-z0-9_-]{1,64}", raw_session_id):
        session_id = raw_session_id
    else:
        session_id = "unknown"
        append_event(state_dir, {
            "ts": now_iso(),
            "session_id": "unknown",
            "cause": "invalid_session_id",
            "raw_length": len(raw_session_id),
        })
    if parent_session_id and not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", parent_session_id):
        # Discard a malformed parent_session_id silently — the SH4 check
        # below would otherwise treat any non-empty differing string as
        # a sub-agent signal. An invalid string is not a credible signal.
        parent_session_id = ""

    # Track Read tool calls into a per-session log for the
    # identity_consumed check_kind. Do this before any deny path so the
    # log is complete even when the same Read gets denied for an
    # unrelated reason.
    if tool_name == "Read":
        target = tool_input.get("file_path", "")
        if target:
            append_session_read(home, session_id, target)

    # Override sentinel takes precedence — if it's valid and unexpired,
    # allow unconditionally (logged once per session is enough; we log
    # every fire for audit completeness).
    ovr_ok, ovr_info = check_override(home, session_id, parent_session_id)
    if ovr_ok:
        # Non-transition event: an override grant is not a state-machine
        # transition, so it carries no from/to (coo-memory#1168 O2). The
        # `cause` field is the universal classifier across all events.
        append_event(state_dir, {
            "ts": now_iso(),
            "session_id": session_id,
            "tool": tool_name,
            "cause": "manual_override_granted",
            "reason": sanitize(ovr_info.get("reason", "")),
        })
        sys.exit(0)
    if ovr_info and ovr_info.get("failure"):
        fk = ovr_info.get("failure")
        if fk == "expired":
            append_event(state_dir, {
                "ts": now_iso(),
                "session_id": session_id,
                "cause": "manual_override_expired",
                "expired_at": ovr_info.get("expired_at"),
            })
        elif fk == "parent_session_mismatch":
            # SH4 (coo-memory#1167): sub-agent dispatch attempted to use
            # the parent's override. Distinct cause for auditability
            # (the operator's /unbrake granted in the parent shouldn't
            # leak down task-dispatch).
            append_event(state_dir, {
                "ts": now_iso(),
                "session_id": session_id,
                "cause": "parent_session_mismatch",
                "parent_session_id": ovr_info.get("parent_session_id", ""),
            })
        else:
            # O10: an override that fails HMAC / session / expires_at
            # validation is silently ignored by check_override. Surface it
            # so an operator whose /unbrake didn't take has a signal
            # (coo-memory#1168 O10).
            append_event(state_dir, {
                "ts": now_iso(),
                "session_id": session_id,
                "cause": "override_invalidated",
                "failure_kind": sanitize(fk),
            })

    sentinel_path = Path(state_dir) / f"boot-brake.{session_id}.json"
    sentinel, sentinel_err = read_cached_sentinel(sentinel_path)

    manifest_path = Path(env.get("VADE_COO_MEMORY_DIR", "/home/user/coo-memory")) / "operations" / "boot-deliverables.yml"

    # Initial revalidation triggers:
    #   - no sentinel at all (fresh session / first PreToolUse)
    #   - sentinel exists but is UNPARSEABLE
    #   - sentinel is PENDING (race-gate engaged previously; must keep
    #     re-evaluating to detect "producers now done → transition to
    #     OK/FAIL" without waiting for content-hash drift, which the
    #     race-gate path may not have recorded yet)
    # FAIL is handled in the backpressure branch below (not here) so it
    # re-checks at most once per second: a FAIL caused by an unsatisfied
    # read_observed entry must clear when the agent Reads the file, which
    # the content-hash drift check cannot see (coo-memory#1169).
    # Backpressure cap below bounds the cost.
    needs_revalidation = (
        sentinel is None
        or sentinel.get("state") == "UNPARSEABLE"
        or sentinel.get("state") == "PENDING"
    )

    # Backpressure cap: don't re-validate more than once per second —
    # EXCEPT when the current tool is a Read against a cached FAIL whose
    # failures include any read_observed entry. That's the "Read might
    # have just satisfied a gate" case (coo-memory#1168 soak-fix: parallel
    # boot Reads that close identity-stack gates would otherwise honor a
    # cached FAIL through the entire ~2s parallel batch and not transition
    # to OK until something else fires the guard).
    backpressure_floor = 1.0
    now_epoch = time.time()
    manifest_loaded = None  # cache across cached-check + revalidate branches
    m_err_cached = None
    read_observed_failure_cached = (
        tool_name == "Read"
        and sentinel is not None
        and sentinel.get("state") == "FAIL"
        and any(
            "consumed" in str(f.get("deliverable", ""))
            for f in sentinel.get("failures", [])
        )
    )
    if sentinel and not needs_revalidation:
        last = sentinel.get("checked_at_epoch", 0)
        if now_epoch - last < backpressure_floor and not read_observed_failure_cached:
            pass  # honor the cache
        else:
            # Content-hash drift check
            manifest_loaded, m_err_cached = load_yaml_manifest(manifest_path)
            if m_err_cached:
                # Treat manifest unreadable as a self-fault and force
                # revalidation (which will write FAIL + cause=validator_self_fault).
                # Sys-Eng C2: a previously-OK sentinel must not survive
                # pyyaml going missing or the manifest becoming unreadable.
                needs_revalidation = True
            elif manifest_loaded:
                # FAIL is not steady-state: re-validate past the
                # backpressure cap so it clears as soon as the underlying
                # condition is fixed. This is the only trigger that catches
                # a now-satisfied read_observed entry (charter/governance/
                # etc.), whose satisfaction changes via session Reads, not
                # file content, and is therefore invisible to the
                # content-hash drift check below (coo-memory#1169).
                if sentinel.get("state") == "FAIL":
                    needs_revalidation = True
                m_version = manifest_loaded.get("manifest_version", 1)
                if sentinel.get("manifest_version", 0) != m_version:
                    needs_revalidation = True
                else:
                    # Cheap mtime first-pass, then hash if changed
                    for entry in manifest_loaded.get("deliverables", []):
                        path = resolve_path(entry, env)
                        prev_hash = sentinel.get("content_hashes", {}).get(entry.get("id", ""))
                        # If we previously hashed this deliverable but
                        # it no longer exists / can't be stat'd, the
                        # cache is stale — re-validate. Sys-Eng C1: a
                        # cached OK must not survive deletion of a
                        # previously-OK deliverable.
                        if not Path(path).exists():
                            if prev_hash is not None:
                                needs_revalidation = True
                                break
                            continue
                        try:
                            Path(path).stat()
                        except OSError:
                            if prev_hash is not None:
                                needs_revalidation = True
                                break
                            continue
                        if prev_hash:
                            cur_hash = sha1_file(path)
                            if cur_hash != prev_hash:
                                needs_revalidation = True
                                break

    if sentinel_err and sentinel_err.startswith("unparseable"):
        write_fault(state_dir, f"sentinel unparseable: {sentinel_err}")
        needs_revalidation = True

    if needs_revalidation:
        # Reuse the cached manifest read if we already did one in the
        # cached-check branch (Sys-Eng M4: closes the TOCTOU window).
        if manifest_loaded is not None or m_err_cached is not None:
            manifest, m_err = manifest_loaded, m_err_cached
        else:
            manifest, m_err = load_yaml_manifest(manifest_path)
        # SH1 (coo-memory#1167): manifest tamper check. Verify the
        # content-hash matches VADE_BRAKE_MANIFEST_SHA256 (pinned in the
        # cloud env, rewritten in lockstep with manifest commits) before
        # trusting the deliverables list. A pinned manifest that drifts
        # from the expected hash is treated as a validator self-fault —
        # the brake refuses to enforce a deliverables list it can't
        # authenticate.
        pin_ok = True
        pin_err = ""
        if not m_err:
            pin_ok, pin_expected, pin_actual = verify_manifest_pin(manifest_path, env)
            if not pin_ok:
                pin_err = (
                    f"manifest SHA pin mismatch: expected="
                    f"{(pin_expected or '<unset>')[:16]} "
                    f"actual={(pin_actual or '<unreadable>')[:16]}"
                )

        if m_err or not pin_ok:
            # Validator self-fault — record but DO NOT brick the agent in
            # Phase 0. The brake's own infrastructure failing should not
            # convert into a session lockout.
            fault_msg = m_err or pin_err
            cause = "validator_self_fault" if m_err else "manifest_sha_mismatch"
            fault_path = write_fault(state_dir, f"{cause}: {fault_msg}")
            sentinel = {
                "state": "FAIL",
                "checked_at": now_iso(),
                "checked_at_epoch": now_epoch,
                "manifest_version": 0,
                "failures": [{
                    "deliverable": "brake-validator",
                    "reason": sanitize(fault_msg),
                    "producer": "boot-brake-guard.py",
                }],
                "boot_started_at": (sentinel or {}).get("boot_started_at", now_iso()),
                "content_hashes": {},
                "cause": cause,
                "fault_log": fault_path,
            }
            atomic_write_json(sentinel_path, sentinel)
            append_event(state_dir, {
                "ts": now_iso(),
                "session_id": session_id,
                "cause": cause,
                "reason": sanitize(fault_msg),
                "fault_log": fault_path,
            })
        else:
            # Race gate (Sys-Eng C3, v2 §6 producer-completion check):
            # if SessionStart producers haven't all logged phase=end,
            # the deliverables they produce may legitimately not exist
            # yet. Stay PENDING rather than record a phantom FAIL that
            # corrupts the 7-day soak signal gating the warn→block flip.
            boot_started_at_str = (sentinel or {}).get("boot_started_at", now_iso())
            try:
                boot_started_epoch = time.mktime(time.strptime(
                    boot_started_at_str, "%Y-%m-%dT%H:%M:%SZ"
                )) - time.timezone
            except (ValueError, OverflowError):
                boot_started_epoch = now_epoch
            elapsed = now_epoch - boot_started_epoch

            grace_seconds = _race_grace_seconds()
            all_done, missing_producers = boot_producers_complete(home, session_id)
            if grace_seconds <= 0:
                in_race_window = False
                race_reason = "race-gate disabled"
            elif all_done is None:
                # boot.log unreadable — fall back to wall-clock grace
                in_race_window = elapsed < grace_seconds
                race_reason = "wall-clock grace"
            else:
                in_race_window = (not all_done)
                race_reason = "producer end-markers pending"

            prev_state = (sentinel or {}).get("state", "PENDING")
            if in_race_window:
                # Stay PENDING; do not record FAIL during the race window.
                sentinel = {
                    "state": "PENDING",
                    "checked_at": now_iso(),
                    "checked_at_epoch": now_epoch,
                    "manifest_version": manifest.get("manifest_version", 1),
                    "failures": [],
                    "cause": "race_gate_engaged",
                    "boot_started_at": boot_started_at_str,
                    "content_hashes": (sentinel or {}).get("content_hashes", {}),
                    "race_gate": {
                        "reason": race_reason,
                        "missing_producers": missing_producers,
                        "elapsed_seconds": round(elapsed, 2),
                    },
                }
                atomic_write_json(sentinel_path, sentinel)
                if prev_state != "PENDING":
                    append_event(state_dir, {
                        "ts": now_iso(),
                        "session_id": session_id,
                        "tool": tool_name,
                        "from": prev_state,
                        "to": "PENDING",
                        "cause": "race_gate_engaged",
                        "race_reason": race_reason,
                        "missing_producers": missing_producers,
                    })
            else:
                state, failures, hashes, m_version, signals = validate_manifest(
                    manifest, env, home, session_id, cwd
                )
                for sig in signals:
                    if sig.get("type") == "predicate_unmatched":
                        append_event(state_dir, {
                            "ts": now_iso(),
                            "session_id": session_id,
                            "tool": tool_name,
                            "cause": "identity_predicate_unmatched",
                            "deliverable": sig.get("deliverable"),
                            "expanded_glob": sig.get("expanded_glob"),
                            "matches_total": sig.get("matches_total"),
                        })
                sentinel = {
                    "state": state,
                    "checked_at": now_iso(),
                    "checked_at_epoch": now_epoch,
                    "manifest_version": m_version,
                    "failures": failures,
                    # O4: every sentinel write records a cause so the
                    # runbook's `jq .cause` triage works uniformly.
                    "cause": "deliverable_missing" if failures else "all_satisfied",
                    "boot_started_at": boot_started_at_str,
                    "content_hashes": hashes,
                }
                atomic_write_json(sentinel_path, sentinel)
                if prev_state != state and failures:
                    append_event(state_dir, {
                        "ts": now_iso(),
                        "session_id": session_id,
                        "tool": tool_name,
                        "from": prev_state,
                        "to": state,
                        "cause": "deliverable_missing",
                        "deliverables": [f["deliverable"] for f in failures],
                    })
                elif prev_state != state:
                    append_event(state_dir, {
                        "ts": now_iso(),
                        "session_id": session_id,
                        "tool": tool_name,
                        "from": prev_state,
                        "to": state,
                        "cause": "all_satisfied",
                    })

    state = (sentinel or {}).get("state", "PENDING")

    # OK → allow silently
    if state == "OK":
        sys.exit(0)

    # FAIL / PENDING in warn mode → allow but log. Tag each event with
    # the same outcome that block mode would emit, so warn-mode is a
    # faithful preview of block-mode (and the soak signal isn't polluted
    # by tools that block mode would have whitelisted):
    #   - state=PENDING                            → race_gate_observed
    #     (block-on-FAIL allows; only block-strict denies)
    #   - state=FAIL + tool in WHITELIST_TOOLS     → whitelisted_in_fail
    #     (block-on-FAIL would log this same cause; coo-memory#1168 follow-up)
    #   - state=FAIL + tool not whitelisted        → would_have_denied
    #     (the real soak signal: actions block-on-FAIL would refuse)
    if mode == "warn":
        if state == "PENDING":
            cause = "race_gate_observed"
        elif tool_name in WHITELIST_TOOLS:
            cause = "whitelisted_in_fail"
        else:
            cause = "would_have_denied"
        append_event(state_dir, {
            "ts": now_iso(),
            "session_id": session_id,
            "tool": tool_name,
            "state": state,
            "mode": "warn",
            "cause": cause,
            "failures": (sentinel or {}).get("failures", []),
        })
        sys.exit(0)

    # block-on-FAIL / block-strict → check whitelist + deny if outside.
    # `mode` is lowercased on read (line 405), so the comparison
    # constants must be lowercase too. block-strict denies PENDING.
    if state == "PENDING" and mode == "block-on-fail":
        sys.exit(0)

    if tool_name in WHITELIST_TOOLS:
        append_event(state_dir, {
            "ts": now_iso(),
            "session_id": session_id,
            "tool": tool_name,
            "state": state,
            "cause": "whitelisted_in_fail",
        })
        sys.exit(0)

    failures = (sentinel or {}).get("failures", [])
    # format_failures collapses the identity-stack *_consumed entries into
    # one directive when 2+ are failing (coo-memory#1169 ergonomics);
    # separators are safe-set only and interpolated values are sanitized.
    fail_summary = format_failures(failures)
    state_safe = sanitize(state)
    reason = (
        f"Boot brake active. State: {state_safe}. "
        f"Failing deliverables: {fail_summary}. "
        f"Read and Grep are allowed for investigation. "
        f"For override and recovery procedures see operations/boot-brake.md."
    )
    emit_deny(reason, event={
        "ts": now_iso(),
        "session_id": session_id,
        "tool": tool_name,
        "state": state,
        "cause": "denied",
        "failures": failures,
    }, state_dir=state_dir)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        try:
            home = os.environ.get("HOME", "/root")
            state_dir = os.environ.get("VADE_CLOUD_STATE_DIR", f"{home}/.vade-cloud-state")
            write_fault(state_dir, f"guard crashed: {type(e).__name__}: {e}", exc=e)
        except Exception:
            pass
        # Fail-OPEN on guard infrastructure crash — the brake should not
        # be the source of session bricking. Per Phase 0 commitment.
        sys.exit(0)
