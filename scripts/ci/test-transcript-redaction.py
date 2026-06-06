#!/usr/bin/env python3
"""
CI test for the transcript-redaction engine.

Asserts:
  1. Positive corpus — every synthesized token of every pattern shape
     is redacted with its expected REDACTED:<id> label.
  2. Negative corpus — strings that resemble secrets but don't match
     any pattern pass through unchanged (no over-redaction; no entropy
     false-positives on common short / low-entropy strings).
  3. Thinking blocks — JSON events with {type:"thinking",text:"..."}
     have their text wholesale-replaced (preserving structure +
     signature); embedded secrets-inside-thinking are gone via defense
     in depth; hits summary reports thinking-block count.

Why Python instead of TSV fixtures + bash:
  GitHub secret-scanning push protection blocks any commit whose disk
  content matches partner patterns (real PAT shapes, Stripe keys,
  Slack tokens, etc.). Storing literal-shape synthetic tokens on disk
  trips the scanner. Building tokens via string concatenation at test
  runtime keeps the disk content scanner-clean while still exercising
  the redactor against canonical shapes. The corpus *contents* never
  exist as literal strings in the repo — only as concatenation
  expressions.

Exits 0 on full pass, 1 on any failure.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Iterable

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
REDACT = os.path.join(REPO_ROOT, "scripts", "lib", "transcript-redact.sh")


# Synthetic-token builders. Each returns a string whose shape matches
# the named pattern but whose content is never-real (high-entropy
# patterns use 'A' fillers; structured patterns use trivial fixed
# content). Build at runtime — never write these literal strings to
# any committed file.
def _A(n: int) -> str:
    return "A" * n


def _gh_classic_pat() -> str:
    return "ghp" + "_" + _A(36)


def _gh_fine_pat() -> str:
    # Spec: 11-char prefix + 82 chars (verified at length 93).
    return "github" + "_pat_" + _A(82)


def _gh_oauth(prefix: str) -> str:
    return prefix + "_" + _A(36)


def _anthropic_key() -> str:
    return "sk" + "-ant-" + "api01" + "-" + _A(95)


def _openai_key() -> str:
    return "sk" + "-proj-" + _A(60)


def _mem0_key() -> str:
    return "m0" + "-" + _A(43)


def _agentmail_key() -> str:
    # Real AgentMail shape: `am_` prefix + body (~73 chars in practice).
    # The previous `"agentmail" + "-" + ...` shape was wrong — the
    # corresponding regex never matched live keys; three secrets leaked
    # into capture archives 2026-05-30 (coo-labs/coo-harness#361).
    return "am" + "_" + _A(73)


def _r2_access_key_id_env() -> str:
    # env-assignment form: NAME=val
    return "R2_TRANSCRIPTS_ACCESS_KEY_ID" + "=" + ("a" * 32)


def _r2_access_key_id_json() -> str:
    # JSON form: "NAME": "val" — the form that bypassed redaction in #361.
    return '"R2_TRANSCRIPTS_ACCESS_KEY_ID"' + ": " + '"' + ("a" * 32) + '"'


def _r2_secret_access_key_env() -> str:
    return "R2_TRANSCRIPTS_SECRET_ACCESS_KEY" + "=" + ("a" * 64)


def _r2_secret_access_key_json() -> str:
    return '"R2_TRANSCRIPTS_SECRET_ACCESS_KEY"' + ": " + '"' + ("a" * 64) + '"'


def _cloudflare_tunnel_token() -> str:
    return "cfut" + "_" + _A(48)


def _op_token() -> str:
    # Realistic shape: ops_ prefix + base64-shaped JWT body. We use a
    # short structurally-valid base64 fragment so the regex matches but
    # secret-scanning doesn't fingerprint it as a real op token.
    return "ops" + "_" + "eyJ" + ("a" * 30) + "." + ("a" * 30)


def _generic_jwt() -> str:
    return "eyJ" + ("a" * 20) + "." + ("a" * 20) + "." + ("a" * 20)


def _aws_akid() -> str:
    return "AKIA" + ("A" * 16)


def _aws_secret() -> str:
    return "aws_secret_access_key=" + ("A" * 40)


def _auth_header() -> str:
    return "Authorization: " + "Bearer " + ("a" * 30)


def _gcp_refresh() -> str:
    return "1" + "//0" + ("A" * 60)


def _gcp_pem() -> str:
    return (
        "-----BEGIN PRIVATE KEY-----\n"
        + "MIIEvQ" + ("A" * 30) + "\n"
        + "-----END PRIVATE KEY-----"
    )


def _ssh_private() -> str:
    return (
        "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        + "b3Blbn" + ("A" * 30) + "\n"
        + "-----END OPENSSH PRIVATE KEY-----"
    )


def _slack_token() -> str:
    return "xox" + "b" + "-1234567890-1234567890-1234567890-" + ("a" * 32)


def _slack_webhook() -> str:
    return "https://hooks.slack" + ".com/services/T" + ("0" * 9) + "/B" + ("0" * 9) + "/" + ("a" * 24)


def _discord_webhook() -> str:
    return "https://discord" + ".com/api/webhooks/" + ("0" * 18) + "/" + ("a" * 24)


def _stripe_key() -> str:
    return "sk_" + "live_" + ("A" * 24)


def _hf_token() -> str:
    return "hf" + "_" + ("a" * 36)


def _npm_token() -> str:
    return "npm" + "_" + _A(36)


def _pypi_token() -> str:
    # Macaroon-shape: pypi-AgEIcHlwaS5vcmc + base64ish run.
    return "pypi-Ag" + "EIcHlwaS5vcmc" + ("A" * 60)


# (pattern_id, token-builder, surrounding-context)
POSITIVE_CASES: list[tuple[str, callable, str]] = [
    ("gh-classic-pat", _gh_classic_pat, "stdout: gh auth status"),
    ("gh-fine-pat", _gh_fine_pat, "embedded in env="),
    ("gh-oauth-u2s", lambda: _gh_oauth("ghu"), "from a hypothetical OAuth flow"),
    ("gh-oauth-s2s", lambda: _gh_oauth("ghs"), "server-to-server"),
    ("gh-oauth-refresh", lambda: _gh_oauth("ghr"), "refresh"),
    ("anthropic-key", _anthropic_key, "leaked into a stray printenv"),
    ("openai-key", _openai_key, "leaked into Bash output"),
    ("mem0-key", _mem0_key, "in env-snapshot"),
    ("agentmail-key", _agentmail_key, "agentmail key dump"),
    ("r2-access-key-id", _r2_access_key_id_env, "R2 access key id env-assignment form"),
    ("r2-access-key-id", _r2_access_key_id_json, "R2 access key id JSON form (settings.json case)"),
    ("r2-secret-access-key", _r2_secret_access_key_env, "R2 secret access key env-assignment form"),
    ("r2-secret-access-key", _r2_secret_access_key_json, "R2 secret access key JSON form"),
    ("cloudflare-tunnel-token", _cloudflare_tunnel_token, "Cloudflare Tunnel token"),
    ("op-token", _op_token, "1Password service token"),
    ("jwt", _generic_jwt, "a JWT in a tool result"),
    ("aws-akid", _aws_akid, "AWS access key in stdout"),
    ("aws-secret", _aws_secret, "in a credentials file paste"),
    ("auth-header", _auth_header, "curl -v output line"),
    ("gcp-refresh", _gcp_refresh, "Google OAuth refresh token"),
    ("gcp-pem", _gcp_pem, "GCP service-account JSON"),
    ("ssh-private", _ssh_private, "An SSH key block"),
    ("slack-token", _slack_token, "Slack bot token"),
    ("slack-webhook", _slack_webhook, "Slack webhook URL"),
    ("discord-webhook", _discord_webhook, "Discord webhook URL"),
    ("stripe-key", _stripe_key, "Stripe live secret"),
    ("hf-token", _hf_token, "HuggingFace user token"),
    ("npm-token", _npm_token, "npm publish token"),
    ("pypi-token", _pypi_token, "PyPI Macaroon token"),
]


# Strings that should NOT trigger any redaction.
NEGATIVE_CASES: list[tuple[str, str]] = [
    ("short-id", "abc123"),
    ("common-word", "hello"),
    ("common-phrase", "The quick brown fox"),
    ("short-numeric", "12345"),
    ("date-iso", "2026-04-27T22:33:08.589Z"),
    ("sha-prefix", "08849f6"),
    ("git-shim-path", "/home/user/.local/bin/git"),
    ("ghp-not-pat", "ghp" + "_short"),
    ("github-pat-too-short", "github" + "_pat_" + _A(6)),
    ("m0-too-short", "m0" + "-" + _A(4)),
    ("ops-without-eyJ", "ops" + "_" + _A(28)),
    ("low-entropy-long", "a" * 37),
    ("session-id-uuid", "a3ff2b79-14b0-43e2-b167-63782e72a4f1"),
]


def _run_redact(payload: str) -> str:
    """Pipe `payload` through the redact wrapper, return redacted output."""
    proc = subprocess.run(
        ["bash", REDACT],
        input=payload,
        capture_output=True,
        text=True,
        check=True,
    )
    return proc.stdout


def _run_redact_with_hits(input_path: str) -> tuple[str, dict]:
    """Run redact on a file path; return (redacted_text, hits_summary)."""
    import tempfile
    out = tempfile.NamedTemporaryFile(mode="w+", delete=False, suffix=".jsonl")
    hits = tempfile.NamedTemporaryFile(mode="w+", delete=False, suffix=".json")
    out.close()
    hits.close()
    subprocess.run(
        ["bash", REDACT, "--input", input_path, "--output", out.name, "--hits", hits.name],
        check=True,
    )
    with open(out.name) as f:
        redacted = f.read()
    with open(hits.name) as f:
        summary = json.load(f)
    os.unlink(out.name)
    os.unlink(hits.name)
    return redacted, summary


def main() -> int:
    failures: list[str] = []

    print("[1/3] Positive corpus: every shape must redact with its expected label")
    for pid, builder, ctx in POSITIVE_CASES:
        token = builder()
        payload = json.dumps({"type": "user", "content": f"{ctx} {token} extra-suffix"}) + "\n"
        out = _run_redact(payload)
        if token in out:
            failures.append(f"pattern={pid} token survived (first 50 chars): {token[:50]!r}")
        if f"REDACTED:{pid}" not in out:
            failures.append(f"pattern={pid} expected label REDACTED:{pid} not in output: {out[:200]!r}")

    print("[2/3] Negative corpus: strings must pass through unchanged")
    for label, s in NEGATIVE_CASES:
        payload = json.dumps({"type": "user", "content": s}) + "\n"
        out = _run_redact(payload)
        if s not in out:
            failures.append(f"negative={label} string was modified: {s!r}")
        if "REDACTED:" in out:
            failures.append(f"negative={label} triggered redaction: {s!r}")

    print("[3/3] Thinking blocks: text replaced + signature preserved + embedded secrets gone")
    # Build a thinking-block fixture at runtime.
    embedded_secret_1 = _gh_classic_pat()
    embedded_secret_2 = _gh_fine_pat()
    fixture_lines = [
        json.dumps({
            "type": "assistant",
            "message": {
                "content": [{
                    "type": "thinking",
                    "text": f"This reasoning re-states a secret like {embedded_secret_1} that the model decided not to print to user-visible output.",
                    "signature": "sig123",
                }]
            },
        }),
        json.dumps({
            "type": "assistant",
            "message": {
                "content": [
                    {"type": "text", "text": "Public output line."},
                    {
                        "type": "thinking",
                        "text": f"More thinking, mentioning {embedded_secret_2} which is also embedded.",
                        "signature": "sig456",
                    },
                ],
            },
        }),
    ]
    import tempfile
    fixture_path = tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".jsonl")
    fixture_path.write("\n".join(fixture_lines) + "\n")
    fixture_path.close()
    try:
        redacted, summary = _run_redact_with_hits(fixture_path.name)
    finally:
        os.unlink(fixture_path.name)

    if "This reasoning re-states a secret" in redacted:
        failures.append("thinking text 'This reasoning re-states a secret' survived")
    if '"signature": "sig123"' not in redacted and '"signature":"sig123"' not in redacted:
        failures.append("signature 'sig123' not preserved in event 1")
    if "REDACTED:thinking-block:" not in redacted:
        failures.append("thinking-block redaction marker not present")
    if embedded_secret_1 in redacted:
        failures.append(f"embedded secret 1 survived thinking redaction (defense-in-depth fail): {embedded_secret_1[:30]!r}")
    if embedded_secret_2 in redacted:
        failures.append(f"embedded secret 2 survived thinking redaction (defense-in-depth fail): {embedded_secret_2[:30]!r}")
    thinking_count = summary.get("redaction_hits", {}).get("thinking-block", 0)
    if thinking_count < 2:
        failures.append(f"hits summary reported thinking-block={thinking_count}, expected >=2; full hits: {summary.get('redaction_hits')}")

    if failures:
        print("")
        print(f"FAIL ({len(failures)} failure(s)):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("")
    print("all transcript-redaction tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
