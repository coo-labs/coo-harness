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


def derive_hmac_key():
    src = os.environ.get("OP_SERVICE_ACCOUNT_TOKEN", "")
    if not src:
        src = os.environ.get("MEM0_API_KEY", "") or os.environ.get("GITHUB_MCP_PAT", "")
    if not src:
        src = "vade-boot-brake-default-no-secrets"
    return hashlib.sha256(src.encode("utf-8")).digest()


def compute_hmac(granted_at, session_id, reason):
    msg = f"{granted_at}|{session_id}|{reason}".encode("utf-8")
    return hmac.new(derive_hmac_key(), msg, hashlib.sha256).hexdigest()


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


def append_event(state_dir, event):
    path = Path(state_dir) / "brake-events.jsonl"
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a") as fh:
            fh.write(json.dumps(event, separators=(",", ":")) + "\n")
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
    """Returns (ok: bool, reason: str, content_hash: str|None)."""
    kind = entry.get("check_kind", "exists")
    path = resolve_path(entry, env)

    if kind == "exists":
        if Path(path).exists():
            return True, "", sha1_file(path)
        return False, f"missing: {path}", None

    if kind == "parses_json":
        try:
            with open(path) as fh:
                content = fh.read()
            json.loads(content)
            return True, "", hashlib.sha1(content.encode()).hexdigest()
        except FileNotFoundError:
            return False, f"missing: {path}", None
        except Exception as e:
            return False, f"unparseable: {type(e).__name__}", None

    if kind == "symlink_to":
        target = entry.get("check_arg", "")
        for var in ("VADE_CLOUD_STATE_DIR", "VADE_COO_MEMORY_DIR", "VADE_RUNTIME_DIR", "HOME"):
            target = target.replace(f"${var}", env.get(var, ""))
        try:
            if not Path(path).is_symlink():
                return False, f"not a symlink: {path}", None
            resolved = os.path.realpath(path)
            expected = os.path.realpath(target) if target else None
            if expected and resolved != expected:
                return False, f"symlink target drift: {path}", None
            return True, "", hashlib.sha1(resolved.encode()).hexdigest()
        except Exception as e:
            return False, f"symlink check error: {type(e).__name__}", None

    if kind == "has_jq_path":
        jq_path = entry.get("check_arg", "")
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
            return True, "", hashlib.sha1(content.encode()).hexdigest()
        except FileNotFoundError:
            return False, f"missing: {path}", None
        except (KeyError, IndexError):
            return False, f"jq path missing: {jq_path}", None
        except Exception as e:
            return False, f"check error: {type(e).__name__}", None

    if kind == "read_observed":
        # The identity_consumed kind from v2 §11. The check_arg is a
        # regex pattern; the deliverable is satisfied when ANY Read tool
        # call observed in this session matches the pattern. Conditional:
        # if the predicate file doesn't exist, skip (not required).
        predicate_glob = entry.get("predicate_exists_glob", "")
        if predicate_glob:
            import glob
            expanded_glob = predicate_glob
            for var in ("VADE_CLOUD_STATE_DIR", "VADE_COO_MEMORY_DIR", "VADE_RUNTIME_DIR", "HOME"):
                expanded_glob = expanded_glob.replace(f"${var}", env.get(var, ""))
            # The cwd is part of the per-session project dir naming
            expanded_glob = expanded_glob.replace("$CWD_DASHIFIED", cwd.replace("/", "-"))
            expanded_glob = expanded_glob.replace("$SESSION_ID", session_id)
            matches = glob.glob(expanded_glob)
            # Filter to non-trivial files (> 1KB indicates real overflow)
            substantive = [m for m in matches if Path(m).stat().st_size > 1024]
            if not substantive:
                return True, "predicate not present; check skipped", None
        pattern = entry.get("check_arg", "")
        try:
            rx = re.compile(pattern)
        except re.error as e:
            return False, f"bad regex: {type(e).__name__}", None
        if session_has_read(home, session_id, lambda fp: rx.search(fp) is not None):
            return True, "", None
        return False, f"identity layer overflowed but agent has not yet Read it", None

    return False, f"unknown check_kind: {kind}", None


def validate_manifest(manifest, env, home, session_id, cwd):
    """Returns (state, failures, content_hashes, manifest_version)."""
    if not manifest or "deliverables" not in manifest:
        return "FAIL", [{"deliverable": "manifest", "reason": "no deliverables key"}], {}, 0

    manifest_version = manifest.get("manifest_version", 1)
    failures = []
    hashes = {}

    for entry in manifest.get("deliverables", []):
        dlid = entry.get("id", "unknown")
        ok, reason, ch = check_deliverable(entry, env, home, session_id, cwd)
        if ch is not None:
            hashes[dlid] = ch
        if not ok:
            if entry.get("severity", "critical") == "critical":
                failures.append({
                    "deliverable": dlid,
                    "reason": reason,
                    "producer": entry.get("producer", "unknown"),
                })

    state = "OK" if not failures else "FAIL"
    return state, failures, hashes, manifest_version


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


def check_override(home, session_id):
    """Returns (allowed, info_dict|None)."""
    path = Path(home) / ".vade" / f"boot-brake-override.{session_id}.json"
    if not path.exists():
        return False, None
    try:
        with open(path) as fh:
            ovr = json.load(fh)
    except Exception:
        return False, None

    expected_hmac = compute_hmac(
        ovr.get("granted_at", ""),
        ovr.get("session_id", ""),
        ovr.get("reason", ""),
    )
    if not hmac.compare_digest(expected_hmac, ovr.get("hmac", "")):
        return False, {"failure": "hmac_mismatch"}
    if ovr.get("session_id") != session_id:
        return False, {"failure": "session_mismatch"}
    expires_at = ovr.get("expires_at", "")
    if expires_at and expires_at < now_iso():
        return False, {"failure": "expired", "expired_at": expires_at}

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


WHITELIST_TOOLS = {"Read", "Grep"}


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
    session_id = event.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID", "unknown")
    cwd = event.get("cwd") or os.environ.get("PWD", "/home/user")

    env = os.environ
    home = env.get("HOME", "/root")
    state_dir = env.get("VADE_CLOUD_STATE_DIR", f"{home}/.vade-cloud-state")

    mode = env.get("VADE_BRAKE_ENFORCE", "warn").lower()
    if mode == "off":
        sys.exit(0)

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
    ovr_ok, ovr_info = check_override(home, session_id)
    if ovr_ok:
        append_event(state_dir, {
            "ts": now_iso(),
            "session_id": session_id,
            "tool": tool_name,
            "from": "any",
            "to": "OK",
            "cause": "manual_override_granted",
            "reason": sanitize(ovr_info.get("reason", "")),
        })
        sys.exit(0)
    if ovr_info and ovr_info.get("failure") == "expired":
        append_event(state_dir, {
            "ts": now_iso(),
            "session_id": session_id,
            "cause": "manual_override_expired",
            "expired_at": ovr_info.get("expired_at"),
        })

    sentinel_path = Path(state_dir) / f"boot-brake.{session_id}.json"
    sentinel, sentinel_err = read_cached_sentinel(sentinel_path)

    manifest_path = Path(env.get("VADE_COO_MEMORY_DIR", "/home/user/coo-memory")) / "operations" / "boot-deliverables.yml"

    needs_revalidation = (
        sentinel is None
        or sentinel.get("state") == "UNPARSEABLE"
    )

    # Backpressure cap: don't re-validate more than once per second.
    backpressure_floor = 1.0
    now_epoch = time.time()
    if sentinel and not needs_revalidation:
        last = sentinel.get("checked_at_epoch", 0)
        if now_epoch - last < backpressure_floor:
            pass  # honor the cache
        else:
            # Content-hash drift check
            manifest, m_err = load_yaml_manifest(manifest_path)
            if manifest and not m_err:
                m_version = manifest.get("manifest_version", 1)
                if sentinel.get("manifest_version", 0) != m_version:
                    needs_revalidation = True
                else:
                    # Cheap mtime first-pass, then hash if changed
                    for entry in manifest.get("deliverables", []):
                        path = resolve_path(entry, env)
                        if not Path(path).exists():
                            continue
                        try:
                            mtime = Path(path).stat().st_mtime
                        except OSError:
                            continue
                        prev_hash = sentinel.get("content_hashes", {}).get(entry.get("id", ""))
                        if prev_hash:
                            cur_hash = sha1_file(path)
                            if cur_hash != prev_hash:
                                needs_revalidation = True
                                break

    if sentinel_err and sentinel_err.startswith("unparseable"):
        write_fault(state_dir, f"sentinel unparseable: {sentinel_err}")
        needs_revalidation = True

    if needs_revalidation:
        manifest, m_err = load_yaml_manifest(manifest_path)
        if m_err:
            # Validator self-fault — record but DO NOT brick the agent in
            # Phase 0. The brake's own infrastructure failing should not
            # convert into a session lockout.
            fault_path = write_fault(state_dir, f"validator self-fault: {m_err}")
            sentinel = {
                "state": "FAIL",
                "checked_at": now_iso(),
                "checked_at_epoch": now_epoch,
                "manifest_version": 0,
                "failures": [{
                    "deliverable": "brake-validator",
                    "reason": sanitize(m_err),
                    "producer": "boot-brake-guard.py",
                }],
                "boot_started_at": (sentinel or {}).get("boot_started_at", now_iso()),
                "content_hashes": {},
                "cause": "validator_self_fault",
                "fault_log": fault_path,
            }
            atomic_write_json(sentinel_path, sentinel)
            append_event(state_dir, {
                "ts": now_iso(),
                "session_id": session_id,
                "cause": "validator_self_fault",
                "reason": sanitize(m_err),
                "fault_log": fault_path,
            })
        else:
            state, failures, hashes, m_version = validate_manifest(
                manifest, env, home, session_id, cwd
            )
            prev_state = (sentinel or {}).get("state", "PENDING")
            sentinel = {
                "state": state,
                "checked_at": now_iso(),
                "checked_at_epoch": now_epoch,
                "manifest_version": m_version,
                "failures": failures,
                "boot_started_at": (sentinel or {}).get("boot_started_at", now_iso()),
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
                })

    state = (sentinel or {}).get("state", "PENDING")

    # OK → allow silently
    if state == "OK":
        sys.exit(0)

    # FAIL / PENDING in warn mode → allow but log
    if mode == "warn":
        append_event(state_dir, {
            "ts": now_iso(),
            "session_id": session_id,
            "tool": tool_name,
            "state": state,
            "mode": "warn",
            "cause": "would_have_denied",
            "failures": (sentinel or {}).get("failures", []),
        })
        sys.exit(0)

    # block-on-FAIL / block-strict → check whitelist + deny if outside
    if state == "PENDING" and mode == "block-on-FAIL":
        sys.exit(0)

    if tool_name in WHITELIST_TOOLS:
        append_event(state_dir, {
            "ts": now_iso(),
            "session_id": session_id,
            "tool": tool_name,
            "state": state,
            "outcome": "whitelisted",
        })
        sys.exit(0)

    failures = (sentinel or {}).get("failures", [])
    # Format: "<dlid>: <reason> -- <dlid>: <reason>" — delimiters drawn
    # from the safe set only. Interpolated values are sanitized.
    fail_parts = [
        f"{sanitize(f.get('deliverable', 'unknown'))}: {sanitize(f.get('reason', ''))}"
        for f in failures[:3]
    ]
    fail_summary = " -- ".join(fail_parts)
    if len(failures) > 3:
        fail_summary += f" -- plus {len(failures) - 3} more"
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
        "outcome": "denied",
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
