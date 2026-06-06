"""HTML rendering primitives for Claude Code transcripts.

Pure-Python rendering core extracted from
scripts/lifecycle/session-end-transcript-render.py per
coo-labs/coo-memory#1147. Takes a list of jsonl entries → returns either
the per-entry HTML strings or a full self-contained HTML document.

No boto3, no R2, no filesystem coupling beyond the inputs. The orchestration
(R2 PUT of html + sidecar, session-URL resolution from env/R2) stays in the
Stop-hook script. compute_metadata and render_html accept session_url +
url_source as inputs rather than resolving them internally — that's the
primitive/orchestration split per the lib README.

RENDERER_VERSION is the canonical version constant for the rendered sidecar
shape (renderer_version field). Bump it when the rendered HTML or the
compute_metadata output diverges in a way reconcile needs to detect.
"""

from __future__ import annotations

import datetime
import html
import json
from typing import Any

from transcripts.jsonl import (
    AUTO_NOTIFICATION_RES,
    SYSTEM_REMINDER_RE,
    classify,
    is_auto_notification_user_entry,
    strip_auto_notifications,
)

RENDERER_VERSION: int = 3

# Re-export the regex constants so consumers don't have to reach into jsonl.
__all__ = [
    "AUTO_NOTIFICATION_RES",
    "CSS",
    "JS",
    "RENDERER_VERSION",
    "SYSTEM_REMINDER_RE",
    "build_toc",
    "compute_metadata",
    "esc",
    "first_line",
    "format_elapsed",
    "format_session_url",
    "format_ts",
    "json_pretty",
    "render_assistant",
    "render_attachment",
    "render_html",
    "render_meta",
    "render_other",
    "render_raw",
    "render_text_with_reminders",
    "render_thinking_entry",
    "render_tool_result",
    "render_user",
    "tool_args_summary",
    "tool_result_text",
    "truncate",
    "ts_to_dt",
]


# ---------------------------------------------------------------------------
# Time + string formatting
# ---------------------------------------------------------------------------


def format_ts(ts: str | None) -> str:
    if not ts:
        return ""
    try:
        dt = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return dt.strftime("%Y-%m-%d %H:%M:%S UTC")
    except (ValueError, TypeError):
        return ts or ""


def ts_to_dt(ts: str | None) -> datetime.datetime | None:
    if not ts:
        return None
    try:
        return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


def format_elapsed(prev: datetime.datetime | None, now: datetime.datetime | None) -> str:
    _S_PER_MIN = 60
    _S_PER_HOUR = 3600
    if prev is None or now is None:
        return ""
    delta = (now - prev).total_seconds()
    if delta < 0:
        return ""
    if delta < 1:
        return "<1s"
    if delta < _S_PER_MIN:
        return f"{int(delta)}s"
    if delta < _S_PER_HOUR:
        return f"{int(delta // _S_PER_MIN)}m{int(delta % _S_PER_MIN):02d}s"
    return f"{int(delta // _S_PER_HOUR)}h{int((delta % _S_PER_HOUR) // _S_PER_MIN):02d}m"


def truncate(s: str, n: int) -> tuple[str, bool]:
    """Return (head, was_truncated). Head has no trailing whitespace."""
    if len(s) <= n:
        return s, False
    return s[:n].rstrip(), True


def first_line(s: Any, max_len: int = 80) -> str:
    if not isinstance(s, str):
        s = "" if s is None else json_pretty(s)
    first = s.lstrip().splitlines()[0] if s.strip() else ""
    head, _ = truncate(first, max_len)
    return head


def esc(s: Any) -> str:
    if s is None:
        return ""
    if not isinstance(s, str):
        s = str(s)
    return str(html.escape(s, quote=True))


def json_pretty(obj: Any) -> str:
    try:
        return json.dumps(obj, indent=2, ensure_ascii=False)
    except (TypeError, ValueError):
        return repr(obj)


def format_session_url(remote_sid: str) -> str:
    remote_sid = remote_sid.strip()
    if not remote_sid:
        return ""
    if remote_sid.startswith("cse_"):
        remote_sid = remote_sid[4:]
    return f"https://claude.ai/code/session_{remote_sid}"


# ---------------------------------------------------------------------------
# Tool args / result helpers
# ---------------------------------------------------------------------------


def tool_args_summary(input_obj: dict[str, Any] | None) -> str:
    if not isinstance(input_obj, dict) or not input_obj:
        return ""
    parts = []
    for k, v in input_obj.items():
        if isinstance(v, str):
            head, trunc = truncate(v.replace("\n", " "), 60)
            parts.append(f"{k}={head}" + ("…" if trunc else ""))
        elif isinstance(v, (int, float, bool)) or v is None:
            parts.append(f"{k}={v}")
        else:
            parts.append(f"{k}=…")
    out, _ = truncate(" ".join(parts), 160)
    return out


def tool_result_text(content: Any) -> str:
    """Tool result content can be a string, list of content blocks, or dict."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        chunks = []
        for block in content:
            if isinstance(block, dict):
                if block.get("type") == "text":
                    chunks.append(block.get("text", ""))
                elif block.get("type") == "image":
                    chunks.append("[image]")
                else:
                    chunks.append(json_pretty(block))
            else:
                chunks.append(str(block))
        return "\n".join(chunks)
    return json_pretty(content)


# ---------------------------------------------------------------------------
# Per-entry rendering
# ---------------------------------------------------------------------------


def render_raw(entry: dict[str, Any]) -> str:
    raw = esc(json_pretty(entry))
    return (
        '<details class="raw"><summary>Show raw JSON</summary>'
        f'<pre class="raw-json">{raw}</pre></details>'
    )


def render_text_with_reminders(text: str) -> str:
    """Split text into normal segments and folded system-reminder blocks."""
    parts: list[str] = []
    cursor = 0
    for m in SYSTEM_REMINDER_RE.finditer(text):
        prefix = text[cursor : m.start()]
        if prefix.strip():
            parts.append(f'<div class="text">{esc(prefix)}</div>')
        body = m.group(1).strip()
        head = first_line(body, 80)
        parts.append(
            '<details class="sysrem">'
            f'<summary><span class="badge">system-reminder</span> '
            f'<span class="preview">{esc(head)}</span></summary>'
            f'<pre class="content">{esc(body)}</pre>'
            "</details>"
        )
        cursor = m.end()
    tail = text[cursor:]
    if tail.strip():
        parts.append(f'<div class="text">{esc(tail)}</div>')
    if not parts:
        return ""
    return "\n".join(parts)


def render_user(idx: int, entry: dict[str, Any], elapsed: str) -> str:
    msg = entry.get("message", {}) or {}
    content = msg.get("content")
    if isinstance(content, list):
        body_parts = []
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text":
                body_parts.append(render_text_with_reminders(block.get("text", "")))
            else:
                body_parts.append(f'<pre class="content">{esc(json_pretty(block))}</pre>')
        body = "\n".join(p for p in body_parts if p)
    elif isinstance(content, str):
        body = render_text_with_reminders(content)
    else:
        body = f'<pre class="content">{esc(json_pretty(content))}</pre>'

    ts = format_ts(entry.get("timestamp"))
    return (
        f'<article class="entry user" id="entry-{idx}" data-role="user">'
        f'<header><a class="anchor" href="#entry-{idx}">#{idx}</a>'
        f'<span class="role-badge">user</span>'
        f'<span class="ts">{esc(ts)}</span>'
        f'<span class="elapsed">{esc(elapsed)}</span></header>'
        f'<div class="body">{body}</div>'
        f"{render_raw(entry)}"
        "</article>"
    )


def render_assistant(idx: int, entry: dict[str, Any], elapsed: str) -> str:
    msg = entry.get("message", {}) or {}
    content = msg.get("content")
    usage = msg.get("usage") or {}
    parts: list[str] = []
    has_error = False

    if isinstance(content, list):
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "text":
                parts.append(f'<div class="text">{esc(block.get("text", ""))}</div>')
            elif btype == "thinking":
                thinking = block.get("thinking", "") or ""
                head = first_line(thinking, 80)
                parts.append(
                    '<details class="thinking">'
                    f'<summary><span class="badge">thinking</span> '
                    f'<span class="preview">{esc(head)}</span></summary>'
                    f'<pre class="content">{esc(thinking)}</pre>'
                    "</details>"
                )
            elif btype == "tool_use":
                name = block.get("name", "?")
                input_obj = block.get("input", {})
                summary = tool_args_summary(input_obj)
                args_pretty = json_pretty(input_obj)
                parts.append(
                    '<div class="tool-use">'
                    f'<span class="badge tool">⚒ {esc(name)}</span>'
                    f'<span class="tool-summary">{esc(summary)}</span>'
                    '<details class="tool-args">'
                    "<summary>args</summary>"
                    f'<pre class="content">{esc(args_pretty)}</pre>'
                    "</details>"
                    "</div>"
                )
            else:
                parts.append(f'<pre class="content">{esc(json_pretty(block))}</pre>')
    elif isinstance(content, str):
        parts.append(f'<div class="text">{esc(content)}</div>')

    in_tok = usage.get("input_tokens")
    out_tok = usage.get("output_tokens")
    cache_read = usage.get("cache_read_input_tokens")
    token_bits = []
    if in_tok is not None:
        token_bits.append(f"in {in_tok}")
    if out_tok is not None:
        token_bits.append(f"out {out_tok}")
    if cache_read:
        token_bits.append(f"cache {cache_read}")
    token_badge = " · ".join(token_bits)

    ts = format_ts(entry.get("timestamp"))
    role_cls = "assistant"
    return (
        f'<article class="entry {role_cls}{" error" if has_error else ""}" '
        f'id="entry-{idx}" data-role="assistant">'
        f'<header><a class="anchor" href="#entry-{idx}">#{idx}</a>'
        f'<span class="role-badge">assistant</span>'
        f'<span class="ts">{esc(ts)}</span>'
        f'<span class="elapsed">{esc(elapsed)}</span>'
        f'<span class="tokens">{esc(token_badge)}</span></header>'
        f'<div class="body">{"".join(parts)}</div>'
        f"{render_raw(entry)}"
        "</article>"
    )


def render_tool_result(idx: int, entry: dict[str, Any], elapsed: str) -> str:
    msg = entry.get("message", {}) or {}
    content = msg.get("content")
    if not isinstance(content, list):
        content = []

    body_parts = []
    has_error = False
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") != "tool_result":
            continue
        is_err = bool(block.get("is_error"))
        has_error = has_error or is_err
        text = tool_result_text(block.get("content"))
        line_count = text.count("\n") + 1 if text else 0
        first = first_line(text, 80)
        tool_use_id = block.get("tool_use_id", "")
        body_parts.append(
            '<div class="tool-result-block">'
            f'<span class="badge result{" err" if is_err else ""}">'
            f"{'ERROR' if is_err else 'result'}</span>"
            f'<span class="preview">{esc(first)}</span>'
            f'<span class="lines">{line_count} line{"s" if line_count != 1 else ""}</span>'
            f'<span class="tuid">{esc(tool_use_id[:8])}</span>'
            '<details class="tool-result-full">'
            "<summary>full</summary>"
            f'<pre class="content">{esc(text)}</pre>'
            "</details>"
            "</div>"
        )

    ts = format_ts(entry.get("timestamp"))
    return (
        f'<article class="entry tool-result{" error" if has_error else ""}" '
        f'id="entry-{idx}" data-role="tool_result">'
        f'<header><a class="anchor" href="#entry-{idx}">#{idx}</a>'
        f'<span class="role-badge">tool result</span>'
        f'<span class="ts">{esc(ts)}</span>'
        f'<span class="elapsed">{esc(elapsed)}</span></header>'
        f'<div class="body">{"".join(body_parts)}</div>'
        f"{render_raw(entry)}"
        "</article>"
    )


def render_attachment(idx: int, entry: dict[str, Any], elapsed: str) -> str:
    att = entry.get("attachment", {}) or {}
    hook_name = att.get("hookName") or att.get("hookEvent") or att.get("type") or "attachment"
    raw_stdout = att.get("stdout")
    stdout: str = raw_stdout if isinstance(raw_stdout, str) else ""
    raw_stderr = att.get("stderr")
    stderr: str = raw_stderr if isinstance(raw_stderr, str) else ""
    content = att.get("content")
    content_str = content if isinstance(content, str) else (json_pretty(content) if content else "")
    exit_code = att.get("exitCode")
    has_error = isinstance(exit_code, int) and exit_code != 0

    preview = first_line(stdout or content_str or stderr, 80)
    body = stdout + (("\nSTDERR:\n" + stderr) if stderr else "")
    if content_str and content_str != stdout:
        body = body + (("\n---\n" + content_str) if body else content_str)

    ts = format_ts(entry.get("timestamp"))
    return (
        '<details class="entry attachment'
        f'{" error" if has_error else ""}" id="entry-{idx}" data-role="attachment">'
        '<summary><a class="anchor" href="#entry-{idx}">'.format(idx=idx)
        + f"#{idx}</a>"
        f'<span class="role-badge">attachment</span>'
        f'<span class="hook-name">{esc(hook_name)}</span>'
        f'<span class="preview">{esc(preview)}</span>'
        f'<span class="ts">{esc(ts)}</span>'
        f'<span class="elapsed">{esc(elapsed)}</span></summary>'
        f'<pre class="content">{esc(body)}</pre>'
        f"{render_raw(entry)}"
        "</details>"
    )


def render_thinking_entry(idx: int, entry: dict[str, Any], elapsed: str) -> str:
    """Assistant entry whose only content is thinking — render compact."""
    return render_assistant(idx, entry, elapsed)


def render_meta(idx: int, entry: dict[str, Any], elapsed: str) -> str:
    t = entry.get("type") or "meta"
    body = json_pretty(entry)
    ts = format_ts(entry.get("timestamp"))
    return (
        f'<details class="entry meta" id="entry-{idx}" data-role="meta">'
        f'<summary><a class="anchor" href="#entry-{idx}">#{idx}</a>'
        f'<span class="role-badge">{esc(t)}</span>'
        f'<span class="ts">{esc(ts)}</span>'
        f'<span class="elapsed">{esc(elapsed)}</span></summary>'
        f'<pre class="content">{esc(body)}</pre>'
        "</details>"
    )


def render_other(idx: int, entry: dict[str, Any], elapsed: str) -> str:
    return render_meta(idx, entry, elapsed)


def build_toc(rendered_entries: list[tuple[int, str, str]]) -> str:
    """Build the table-of-contents nav.

    Each tuple is (idx, kind, preview). Only user turns get numbered list
    entries; assistant turns appear underneath their preceding user turn
    as sub-entries (visual hierarchy is the user-turn anchor).
    """
    items = []
    user_n = 0
    for idx, kind, preview in rendered_entries:
        if kind == "user":
            user_n += 1
            label = f"{user_n}. {preview or '(empty)'}"
            label_short, _ = truncate(label, 60)
            items.append(f'<li><a href="#entry-{idx}">{esc(label_short)}</a></li>')
    if not items:
        items.append('<li><em class="muted">no user turns</em></li>')
    return f'<nav class="toc"><h2>User turns</h2><ol>{"".join(items)}</ol></nav>'


# ---------------------------------------------------------------------------
# Metadata (sidecar) computation
# ---------------------------------------------------------------------------


def compute_metadata(
    session_id: str,
    entries: list[dict[str, Any]],
    *,
    session_url: str = "",
    url_source: str = "",
) -> dict[str, Any]:
    """Walk entries once; return the metadata blob for the list-page sidecar.

    Schema (renderer_version=RENDERER_VERSION):
      session_id, started_at, ended_at, duration_seconds,
      entry_count, user_turn_count, assistant_turn_count,
      tool_call_count, error_count, first_user_preview,
      first_user_uuid, session_url, renderer_version,
      models (list of distinct model strings from assistant messages),
      cwds (list of distinct cwd strings),
      cc_version (last seen Claude Code client version),
      url_source (omitted when empty — matches the renderer's prior
      omit-when-falsy pattern).

    `session_url` + `url_source` are inputs — resolution from env / R2
    is orchestration and stays in the calling script.
    """
    first_ts: datetime.datetime | None = None
    last_ts: datetime.datetime | None = None
    user_count = 0
    assistant_count = 0
    tool_call_count = 0
    error_count = 0
    first_user_preview = ""
    first_user_uuid = ""
    models: list[str] = []
    cwds: list[str] = []
    cc_version = ""

    def _add_unique(lst: list[str], val: str) -> None:
        if val and val not in lst:
            lst.append(val)

    for entry in entries:
        kind = classify(entry)
        ts = ts_to_dt(entry.get("timestamp"))
        if ts is not None:
            if first_ts is None:
                first_ts = ts
            last_ts = ts
        v = entry.get("version")
        if isinstance(v, str) and v:
            cc_version = v
        cwd = entry.get("cwd")
        if isinstance(cwd, str):
            _add_unique(cwds, cwd)

        if kind == "user":
            if is_auto_notification_user_entry(entry):
                # Webhook events / task notifications injected into the user
                # slot aren't operator turns; don't count them.
                pass
            else:
                user_count += 1
                if not first_user_uuid:
                    uuid = entry.get("uuid")
                    if isinstance(uuid, str) and uuid:
                        first_user_uuid = uuid
                if not first_user_preview:
                    msg = entry.get("message", {}) or {}
                    content = msg.get("content")
                    text = ""
                    if isinstance(content, str):
                        text = content
                    elif isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict) and block.get("type") == "text":
                                text = block.get("text", "")
                                break
                    text = strip_auto_notifications(text).strip()
                    if text:
                        first_user_preview = first_line(text, 140)
        elif kind in ("assistant", "tool_use", "thinking"):
            assistant_count += 1
            msg = entry.get("message", {}) or {}
            model = msg.get("model")
            if isinstance(model, str):
                _add_unique(models, model)
            content = msg.get("content")
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        tool_call_count += 1
        elif kind == "tool_result":
            msg = entry.get("message", {}) or {}
            content = msg.get("content")
            if isinstance(content, list):
                for block in content:
                    if (
                        isinstance(block, dict)
                        and block.get("type") == "tool_result"
                        and block.get("is_error")
                    ):
                        error_count += 1
        elif kind == "attachment":
            att = entry.get("attachment", {}) or {}
            exit_code = att.get("exitCode")
            if isinstance(exit_code, int) and exit_code != 0:
                error_count += 1

    duration_seconds = 0
    if first_ts is not None and last_ts is not None:
        duration_seconds = max(0, int((last_ts - first_ts).total_seconds()))

    metadata: dict[str, Any] = {
        "session_id": session_id,
        "started_at": first_ts.isoformat() if first_ts else None,
        "ended_at": last_ts.isoformat() if last_ts else None,
        "duration_seconds": duration_seconds,
        "entry_count": len(entries),
        "user_turn_count": user_count,
        "assistant_turn_count": assistant_count,
        "tool_call_count": tool_call_count,
        "error_count": error_count,
        "first_user_preview": first_user_preview,
        "first_user_uuid": first_user_uuid,
        "models": models,
        "cwds": cwds,
        "cc_version": cc_version,
        "session_url": session_url,
        "renderer_version": RENDERER_VERSION,
    }
    if url_source:
        metadata["url_source"] = url_source
    return metadata


# ---------------------------------------------------------------------------
# Document assembly
# ---------------------------------------------------------------------------


CSS = """
:root {
  --bg: #0d1117; --panel: #161b22; --border: #30363d; --fg: #e6edf3;
  --muted: #8b949e; --accent: #58a6ff; --user: #79c0ff; --assistant: #d2a8ff;
  --tool: #7ee787; --system: #8b949e; --error: #ff7b72;
  --warning: #d29922;
}
@media (prefers-color-scheme: light) {
  :root {
    --bg: #ffffff; --panel: #f6f8fa; --border: #d0d7de; --fg: #1f2328;
    --muted: #656d76; --accent: #0969da; --user: #0969da; --assistant: #8250df;
    --tool: #1a7f37; --system: #656d76; --error: #cf222e;
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: var(--bg); color: var(--fg);
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui,
    sans-serif; font-size: 14px; line-height: 1.5; }
body { display: grid; grid-template-columns: minmax(220px, 280px) 1fr;
  min-height: 100vh; }
nav.toc { position: sticky; top: 0; align-self: start; max-height: 100vh;
  overflow-y: auto; padding: 16px; border-right: 1px solid var(--border);
  background: var(--panel); font-size: 12px; }
nav.toc h2 { font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em;
  margin: 0 0 12px 0; color: var(--muted); }
nav.toc ol { list-style: none; margin: 0; padding: 0; }
nav.toc li { margin: 0 0 6px 0; }
nav.toc a { color: var(--fg); text-decoration: none; display: block;
  padding: 4px 6px; border-radius: 4px; }
nav.toc a:hover { background: var(--bg); }
main { padding: 16px 24px; min-width: 0; max-width: 100%; }
p.back { margin: 0 0 8px 0; font-size: 12px; }
p.back a { color: var(--muted); text-decoration: none; }
p.back a:hover { color: var(--accent); }
header.session { padding-bottom: 16px; border-bottom: 1px solid var(--border);
  margin-bottom: 16px; }
header.session h1 { margin: 0 0 4px 0; font-size: 18px; font-family: ui-monospace,
  SFMono-Regular, Menlo, monospace; }
header.session .meta { color: var(--muted); font-size: 12px; }
.controls { display: flex; flex-wrap: wrap; gap: 8px; margin: 12px 0 24px;
  align-items: center; }
.controls input[type=search] { flex: 1 1 200px; background: var(--panel);
  border: 1px solid var(--border); color: var(--fg); padding: 6px 10px;
  border-radius: 6px; font: inherit; }
.controls button { background: var(--panel); border: 1px solid var(--border);
  color: var(--fg); padding: 6px 10px; border-radius: 6px; font: inherit;
  cursor: pointer; }
.controls button.active { background: var(--accent); color: var(--bg);
  border-color: var(--accent); }
.entry { margin: 0 0 14px 0; padding: 10px 12px; border: 1px solid var(--border);
  border-left: 3px solid var(--system); border-radius: 6px; background: var(--panel); }
.entry.user { border-left-color: var(--user); }
.entry.assistant { border-left-color: var(--assistant); }
.entry.tool-result { border-left-color: var(--tool); }
.entry.attachment { border-left-color: var(--system); }
.entry.meta { border-left-color: var(--system); opacity: 0.85; }
.entry.error { border-left-color: var(--error); }
.entry > header, .entry > summary { display: flex; flex-wrap: wrap; gap: 10px;
  align-items: center; font-size: 12px; color: var(--muted); cursor: default; }
.entry > summary { cursor: pointer; list-style: none; }
.entry > summary::-webkit-details-marker { display: none; }
.entry > summary::before { content: "▸"; color: var(--muted); width: 8px;
  display: inline-block; transition: transform 0.1s; }
.entry[open] > summary::before { transform: rotate(90deg); }
.anchor { color: var(--muted); text-decoration: none; font-family: ui-monospace,
  monospace; min-width: 32px; }
.anchor:hover { color: var(--accent); }
.role-badge { background: var(--bg); padding: 2px 6px; border-radius: 3px;
  font-weight: 600; font-size: 11px; text-transform: uppercase;
  letter-spacing: 0.03em; }
.ts, .elapsed, .tokens, .hook-name, .tuid, .lines { font-family: ui-monospace,
  monospace; font-size: 11px; color: var(--muted); }
.elapsed::before { content: "+"; }
.body { margin-top: 8px; }
.text { white-space: pre-wrap; word-wrap: break-word; margin: 6px 0; }
.entry pre.content, pre.raw-json { background: var(--bg); border: 1px solid var(--border);
  border-radius: 4px; padding: 8px 10px; overflow-x: auto; font-family: ui-monospace,
  monospace; font-size: 12px; white-space: pre-wrap; word-wrap: break-word;
  max-width: 100%; margin: 6px 0; }
details.sysrem, details.thinking, details.tool-args, details.tool-result-full,
details.raw { margin: 6px 0; }
details.sysrem > summary, details.thinking > summary, details.tool-args > summary,
details.tool-result-full > summary, details.raw > summary {
  cursor: pointer; color: var(--muted); font-size: 12px; list-style: none;
  display: flex; gap: 8px; align-items: center; }
details > summary::-webkit-details-marker { display: none; }
details > summary::before { content: "▸"; width: 8px; display: inline-block;
  color: var(--muted); transition: transform 0.1s; }
details[open] > summary::before { transform: rotate(90deg); }
.badge { background: var(--bg); padding: 2px 6px; border-radius: 3px;
  font-size: 11px; font-weight: 600; }
.badge.tool { color: var(--tool); }
.badge.result { color: var(--tool); }
.badge.result.err { color: var(--error); }
.preview { color: var(--muted); font-family: ui-monospace, monospace;
  font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  max-width: 60ch; }
.tool-use { display: flex; flex-wrap: wrap; gap: 8px; align-items: baseline;
  margin: 4px 0; }
.tool-summary { color: var(--fg); font-family: ui-monospace, monospace;
  font-size: 12px; overflow-wrap: anywhere; }
.tool-result-block { margin: 6px 0; padding: 6px 8px; background: var(--bg);
  border-radius: 4px; }
.tool-result-block > * { display: inline-block; vertical-align: middle;
  margin-right: 8px; }
.hide-attachment .entry.attachment { display: none; }
.hide-tool-result .entry.tool-result { display: none; }
.hide-meta .entry.meta { display: none; }
.only-conversation .entry:not(.user):not(.assistant) { display: none; }
mark.search-hit { background: var(--warning); color: var(--bg); }
@media (max-width: 768px) {
  body { grid-template-columns: 1fr; }
  nav.toc { position: static; max-height: 280px; border-right: none;
    border-bottom: 1px solid var(--border); }
}
"""

JS = """
(function(){
  const main = document.querySelector('main');
  const search = document.getElementById('search-box');
  const buttons = document.querySelectorAll('.controls button[data-toggle]');
  buttons.forEach(b => b.addEventListener('click', () => {
    b.classList.toggle('active');
    document.body.classList.toggle(b.dataset.toggle, b.classList.contains('active'));
  }));
  let timer;
  search.addEventListener('input', () => {
    clearTimeout(timer);
    timer = setTimeout(() => runSearch(search.value.trim()), 150);
  });
  function runSearch(q) {
    // Clear previous highlights.
    document.querySelectorAll('mark.search-hit').forEach(m => {
      const t = document.createTextNode(m.textContent);
      m.parentNode.replaceChild(t, m);
    });
    document.querySelectorAll('.entry').forEach(e => e.style.display = '');
    if (!q) return;
    const ql = q.toLowerCase();
    const entries = document.querySelectorAll('.entry');
    entries.forEach(e => {
      const text = e.textContent.toLowerCase();
      if (text.indexOf(ql) === -1) {
        e.style.display = 'none';
      } else {
        // expand any closed <details> inside so the match is visible
        e.querySelectorAll('details').forEach(d => d.open = true);
        if (e.tagName === 'DETAILS') e.open = true;
        highlight(e, q);
      }
    });
  }
  function highlight(root, q) {
    const ql = q.toLowerCase();
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: n => n.parentElement.closest('script,style,mark') ? NodeFilter.FILTER_REJECT
        : n.nodeValue.toLowerCase().indexOf(ql) !== -1 ? NodeFilter.FILTER_ACCEPT
        : NodeFilter.FILTER_SKIP
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach(n => {
      const v = n.nodeValue, lv = v.toLowerCase();
      const frag = document.createDocumentFragment();
      let i = 0;
      while (i < v.length) {
        const j = lv.indexOf(ql, i);
        if (j === -1) { frag.appendChild(document.createTextNode(v.slice(i))); break; }
        if (j > i) frag.appendChild(document.createTextNode(v.slice(i, j)));
        const mark = document.createElement('mark');
        mark.className = 'search-hit';
        mark.textContent = v.slice(j, j + q.length);
        frag.appendChild(mark);
        i = j + q.length;
      }
      n.parentNode.replaceChild(frag, n);
    });
  }
  const jumpErr = document.getElementById('jump-error');
  if (jumpErr) jumpErr.addEventListener('click', () => {
    const e = document.querySelector('.entry.error');
    if (e) { e.scrollIntoView({block:'start'}); if (e.tagName==='DETAILS') e.open = true; }
  });
})();
"""


def render_html(
    session_id: str,
    entries: list[dict[str, Any]],
    *,
    session_url: str = "",
) -> str:
    """Render entries into a self-contained HTML document.

    `session_url` is an input; resolution from env / R2 is orchestration and
    stays in the calling script.
    """
    rendered: list[str] = []
    toc_entries: list[tuple[int, str, str]] = []
    prev_ts: datetime.datetime | None = None
    first_ts: datetime.datetime | None = None
    last_ts: datetime.datetime | None = None
    error_count = 0

    for i, entry in enumerate(entries):
        kind = classify(entry)
        now_ts = ts_to_dt(entry.get("timestamp"))
        if now_ts is not None:
            if first_ts is None:
                first_ts = now_ts
            last_ts = now_ts
        elapsed = format_elapsed(prev_ts, now_ts)
        if now_ts is not None:
            prev_ts = now_ts

        preview = ""
        is_auto_user = kind == "user" and is_auto_notification_user_entry(entry)
        if kind == "user" and not is_auto_user:
            msg = entry.get("message", {}) or {}
            content = msg.get("content")
            if isinstance(content, str):
                preview = first_line(strip_auto_notifications(content), 60)
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        preview = first_line(strip_auto_notifications(block.get("text", "")), 60)
                        break

        if kind == "user":
            html_chunk = render_user(i, entry, elapsed)
        elif kind == "assistant":
            html_chunk = render_assistant(i, entry, elapsed)
        elif kind == "thinking":
            html_chunk = render_thinking_entry(i, entry, elapsed)
        elif kind == "tool_use":
            html_chunk = render_assistant(i, entry, elapsed)
        elif kind == "tool_result":
            html_chunk = render_tool_result(i, entry, elapsed)
        elif kind == "attachment":
            html_chunk = render_attachment(i, entry, elapsed)
        elif kind == "meta":
            html_chunk = render_meta(i, entry, elapsed)
        else:
            html_chunk = render_other(i, entry, elapsed)

        if 'class="entry' in html_chunk and " error" in html_chunk.split(">", 1)[0]:
            error_count += 1

        rendered.append(html_chunk)
        # Auto-notification user entries don't get a TOC slot — but they
        # still render as entries (raw form remains scrollable / Find-able).
        toc_entries.append((i, "auto_user" if is_auto_user else kind, preview))

    toc = build_toc(toc_entries)
    duration = format_elapsed(first_ts, last_ts) or "—"
    started = format_ts(first_ts.isoformat() if first_ts else None) or "—"
    entry_count = len(entries)
    user_count = sum(1 for _, k, _ in toc_entries if k == "user")
    assistant_count = sum(1 for _, k, _ in toc_entries if k == "assistant")

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Transcript {esc(session_id)}</title>
<style>{CSS}</style>
</head>
<body>
{toc}
<main>
  <p class="back"><a href="/transcripts/">← All transcripts</a>{(' &nbsp;·&nbsp; <a href="' + esc(session_url) + '" target="_blank" rel="noopener">Open in Claude Code ↗</a> &nbsp;·&nbsp; <a href="/sessions/' + esc(session_url.rsplit("/session_", 1)[-1]) + '">GitHub artifacts ↗</a>') if session_url else ""}</p>
  <header class="session">
    <h1>{esc(session_id)}</h1>
    <div class="meta">
      started {esc(started)} · duration {esc(duration)} ·
      {entry_count} entries ({user_count} user, {assistant_count} assistant) ·
      {error_count} error{"" if error_count == 1 else "s"}
    </div>
  </header>
  <div class="controls">
    <input type="search" id="search-box" placeholder="Search transcript..." autocomplete="off">
    <button data-toggle="hide-attachment">Hide attachments</button>
    <button data-toggle="hide-tool-result">Hide tool results</button>
    <button data-toggle="hide-meta">Hide meta</button>
    <button data-toggle="only-conversation">Only user + assistant</button>
    <button id="jump-error">Jump to first error</button>
  </div>
  <div class="entries">
    {"".join(rendered)}
  </div>
</main>
<script>{JS}</script>
</body>
</html>
"""
