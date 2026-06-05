"""Local JSONL parsing + classification primitives.

Consolidates the JSONL reader, auto-notification stripping, and entry
classification that the renderer and the session-end export hook both
inline. Pure-Python — no boto3, no R2, no filesystem coupling beyond
reading the path passed in.

The Claude Code transcript format is documented in `coo-labs/tjsonl` —
this module covers the slice of the format the COO's renderer and
session-end hook need to make rendering decisions. Anything beyond
classification + auto-notification filtering belongs in `tjsonl` or
in `render.py`, not here.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

SYSTEM_REMINDER_RE: re.Pattern[str] = re.compile(
    r"<system-reminder>(.*?)</system-reminder>", re.DOTALL
)

AUTO_NOTIFICATION_RES: list[re.Pattern[str]] = [
    re.compile(r"<github-webhook-activity>.*?</github-webhook-activity>", re.DOTALL),
    re.compile(r"<task-notification>.*?</task-notification>", re.DOTALL),
]


def read_entries(jsonl_path: Path) -> list[dict[str, Any]]:
    """Parse a Claude Code transcript JSONL file into a list of entries.

    Lenient on the line-decode side: skips malformed lines with a stderr
    warning rather than aborting. This matches the renderer's behavior —
    partial reads are preferred to total failure, since the renderer can
    still emit a meaningful HTML page from an incomplete jsonl.
    """
    entries: list[dict[str, Any]] = []
    with open(jsonl_path) as f:
        for lineno, line in enumerate(f, 1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                entries.append(json.loads(stripped))
            except json.JSONDecodeError as e:
                sys.stderr.write(f"[transcripts.jsonl] skipping malformed line {lineno}: {e}\n")
    return entries


def strip_auto_notifications(text: str) -> str:
    """Strip system-reminders and known auto-notification envelopes.

    Returns the residue — what the user actually typed, if anything.
    Empty string means the message slot carried only auto-injected
    content (webhook activity, task completion, system reminders).
    """
    out = SYSTEM_REMINDER_RE.sub("", text)
    for r in AUTO_NOTIFICATION_RES:
        out = r.sub("", out)
    return out


def is_auto_notification_user_entry(entry: dict[str, Any]) -> bool:
    """True iff a user-typed message slot carries only auto-notifications.

    Discriminates between operator-typed turns and webhook /
    task-completion notifications injected into the user role. Returns
    False on entries whose content list contains no text blocks (tool_result
    messages — classified separately by callers).
    """
    msg = entry.get("message", {}) or {}
    content = msg.get("content")
    if isinstance(content, str):
        return not strip_auto_notifications(content).strip()
    if isinstance(content, list):
        any_text = False
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                any_text = True
                if strip_auto_notifications(block.get("text", "")).strip():
                    return False
        return any_text
    return False


def classify(entry: dict[str, Any]) -> str:
    """Bucket a raw jsonl entry into a rendering kind.

    Kinds: "user", "assistant", "thinking", "tool_use", "tool_result",
    "attachment", "meta", "other". The renderer dispatches on this;
    consumers that count turn types (cohort report, future indexer) also
    dispatch on it.

    Caller responsibility: filter via is_auto_notification_user_entry()
    before counting a "user" kind as a real operator turn — this function
    classifies by content shape only, not by author intent.
    """
    t = entry.get("type")
    if t == "attachment":
        return "attachment"
    if t in ("queue-operation", "last-prompt", "mode", "summary"):
        return "meta"
    if t == "user":
        return _classify_user(entry)
    if t == "assistant":
        return _classify_assistant(entry)
    return "other"


def _classify_user(entry: dict[str, Any]) -> str:
    msg = entry.get("message", {}) or {}
    content = msg.get("content")
    if isinstance(content, list) and any(
        isinstance(b, dict) and b.get("type") == "tool_result" for b in content
    ):
        return "tool_result"
    return "user"


def _classify_assistant(entry: dict[str, Any]) -> str:
    msg = entry.get("message", {}) or {}
    content = msg.get("content")
    if isinstance(content, list):
        kinds = [b.get("type") for b in content if isinstance(b, dict)]
        if kinds and all(k == "thinking" for k in kinds):
            return "thinking"
        if kinds and all(k == "tool_use" for k in kinds):
            return "tool_use"
    return "assistant"
