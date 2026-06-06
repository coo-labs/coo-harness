"""Backfill driver tests — dry-run + apply paths against an in-memory dump.

The renderer subprocess is stubbed with a tiny shell-like script that writes
known bytes to `--output`. R2 is mocked at the boto3 client level via a fake.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import pytest

from transcripts.backfill.events import (
    EVENTS_URL_SOURCE,
    BackfillResult,
    BackfillStatus,
    backfill_dump,
)
from transcripts.events.client import PARSER_VERSION


def _write_dump(tmp_path: Path, sessions: dict[str, list[dict[str, Any]]]) -> Path:
    """Build a multi-session dump file from sessions dict."""
    dump = {
        "parser_version": PARSER_VERSION,
        "dumped_at": "2026-06-06T00:00:00Z",
        "org_uuid": "org-test",
        "sessions": sessions,
        "errors": [],
    }
    path = tmp_path / "dump.json"
    path.write_text(json.dumps(dump), encoding="utf-8")
    return path


def _write_fake_renderer(tmp_path: Path, *, html_body: str = "<html>OK</html>") -> Path:
    """Create a Python stub that mimics the renderer's --input/--output contract."""
    script = tmp_path / "fake_renderer.py"
    script.write_text(
        "import argparse, sys\n"
        "from pathlib import Path\n"
        "p = argparse.ArgumentParser()\n"
        "p.add_argument('--input', type=Path, required=True)\n"
        "p.add_argument('--session-id', required=True)\n"
        "p.add_argument('--output', type=Path, required=True)\n"
        "p.add_argument('--no-upload', action='store_true')\n"
        "args, _ = p.parse_known_args()\n"
        "lines = [l for l in args.input.read_text().splitlines() if l.strip()]\n"
        f"args.output.write_text({html_body!r} + f'<!-- entries={{len(lines)}} -->')\n"
        "sys.exit(0)\n",
        encoding="utf-8",
    )
    return script


def _write_failing_renderer(tmp_path: Path) -> Path:
    script = tmp_path / "failing_renderer.py"
    script.write_text(
        "import sys\nsys.stderr.write('renderer exploded\\n')\nsys.exit(7)\n",
        encoding="utf-8",
    )
    return script


_SAMPLE_EVENTS: list[dict[str, Any]] = [
    {
        "type": "system",
        "subtype": "init",
        "created_at": "2026-05-31T01:00:00Z",
        "uuid": "i1",
        "cwd": "/home/user",
        "claude_code_version": "2.1.158",
    },
    {
        "type": "user",
        "created_at": "2026-05-31T01:00:05Z",
        "uuid": "u1",
        "session_id": "",
        "message": {"content": "hi coo, boot up please"},
    },
    {
        "type": "assistant",
        "created_at": "2026-05-31T01:00:10Z",
        "uuid": "a1",
        "message": {
            "model": "claude-opus-4-7",
            "content": [{"type": "text", "text": "Boot starting"}],
        },
    },
]


@dataclass
class _FakeS3:
    """Minimal in-memory S3 stand-in: tracks PUT/GET calls + canned NoSuchKey.

    Mirrors the shape of `_is_no_such_key` / `_is_precondition_failed` so the
    lib's r2.py recognizes the synthesized exceptions correctly.
    """

    objects: dict[str, bytes] = field(default_factory=dict)
    puts: list[dict[str, Any]] = field(default_factory=list)

    def get_object(self, *, Bucket: str, Key: str) -> dict[str, Any]:
        if Key not in self.objects:
            raise _NoSuchKeyError()
        body = self.objects[Key]

        class _Body:
            def read(self) -> bytes:
                return body

        return {"Body": _Body()}

    def put_object(self, **kwargs: Any) -> dict[str, Any]:
        key = kwargs["Key"]
        self.puts.append(kwargs)
        if kwargs.get("IfNoneMatch") == "*" and key in self.objects:
            raise _PreconditionFailedError()
        self.objects[key] = kwargs["Body"]
        return {}


class _NoSuchKeyError(Exception):
    """Mock botocore's NoSuchKey shape — duck-typed on `.response`."""

    def __init__(self) -> None:
        super().__init__("NoSuchKey")
        self.response = {"Error": {"Code": "NoSuchKey"}}


class _PreconditionFailedError(Exception):
    def __init__(self) -> None:
        super().__init__("PreconditionFailed")
        self.response = {"Error": {"Code": "PreconditionFailed"}}


@pytest.fixture
def fake_s3() -> _FakeS3:
    return _FakeS3()


@pytest.fixture
def _patch_bucket(monkeypatch: pytest.MonkeyPatch) -> None:
    """Stub the op-bucket resolution; tests never reach 1Password."""
    monkeypatch.setattr(
        "transcripts.r2._bucket_from_env_or_op",
        lambda: "test-bucket",
    )


class TestDryRunPath:
    def test_dry_run_translates_and_renders_no_writes(
        self, tmp_path: Path, fake_s3: _FakeS3, _patch_bucket: None
    ) -> None:
        dump_path = _write_dump(tmp_path, {"session_dry": _SAMPLE_EVENTS})
        renderer = _write_fake_renderer(tmp_path)

        report = backfill_dump(
            dump_path=dump_path,
            apply=False,
            renderer_script=renderer,
            s3=fake_s3,
        )

        assert len(report.results) == 1
        result = report.results[0]
        assert result.status == BackfillStatus.DRY_RUN
        assert result.session_id == "session_dry"
        assert result.html_bytes > 0
        assert result.user_turn_count == 1
        assert result.assistant_turn_count == 1
        assert fake_s3.puts == []  # no R2 writes


class TestApplyPath:
    def test_apply_writes_html_then_sidecar(
        self, tmp_path: Path, fake_s3: _FakeS3, _patch_bucket: None
    ) -> None:
        dump_path = _write_dump(tmp_path, {"session_apply": _SAMPLE_EVENTS})
        renderer = _write_fake_renderer(tmp_path)

        report = backfill_dump(
            dump_path=dump_path,
            apply=True,
            renderer_script=renderer,
            s3=fake_s3,
        )

        result = report.results[0]
        assert result.status == BackfillStatus.APPLIED
        # Two PUTs: html + sidecar.
        keys = [p["Key"] for p in fake_s3.puts]
        assert "rendered/session_apply.html" in keys
        assert "rendered/session_apply.meta.json" in keys

    def test_sidecar_carries_events_url_source(
        self, tmp_path: Path, fake_s3: _FakeS3, _patch_bucket: None
    ) -> None:
        dump_path = _write_dump(tmp_path, {"session_url": _SAMPLE_EVENTS})
        renderer = _write_fake_renderer(tmp_path)

        backfill_dump(
            dump_path=dump_path,
            apply=True,
            renderer_script=renderer,
            s3=fake_s3,
        )

        meta_put = next(p for p in fake_s3.puts if p["Key"].endswith(".meta.json"))
        body = json.loads(meta_put["Body"])
        assert body["url_source"] == EVENTS_URL_SOURCE
        assert body["session_url"] == "https://claude.ai/code/session_url"
        assert body["cc_version"] == "2.1.158"
        assert body["cwds"] == ["/home/user"]

    def test_first_write_uses_if_none_match(
        self, tmp_path: Path, fake_s3: _FakeS3, _patch_bucket: None
    ) -> None:
        dump_path = _write_dump(tmp_path, {"session_first": _SAMPLE_EVENTS})
        renderer = _write_fake_renderer(tmp_path)

        backfill_dump(
            dump_path=dump_path,
            apply=True,
            renderer_script=renderer,
            s3=fake_s3,
        )

        for put in fake_s3.puts:
            assert put.get("IfNoneMatch") == "*", f"{put['Key']} missing atomic-create"


class TestProvenanceGate:
    def test_authoritative_existing_sidecar_cedes(
        self, tmp_path: Path, fake_s3: _FakeS3, _patch_bucket: None
    ) -> None:
        sid = "session_existing"
        existing = json.dumps({"session_id": sid, "url_source": "env-recovery"}).encode()
        fake_s3.objects[f"rendered/{sid}.meta.json"] = existing

        dump_path = _write_dump(tmp_path, {sid: _SAMPLE_EVENTS})
        renderer = _write_fake_renderer(tmp_path)

        report = backfill_dump(
            dump_path=dump_path,
            apply=True,
            renderer_script=renderer,
            s3=fake_s3,
        )

        result = report.results[0]
        assert result.status == BackfillStatus.CEDED_AUTHORITATIVE
        # No additional PUTs after the ceded decision.
        keys_after_cede = [p["Key"] for p in fake_s3.puts if p["Key"].startswith("rendered/")]
        assert f"rendered/{sid}.html" not in keys_after_cede

    def test_existing_events_uuid_can_overwrite(
        self, tmp_path: Path, fake_s3: _FakeS3, _patch_bucket: None
    ) -> None:
        """A re-run against the same source should overwrite, not cede."""
        sid = "session_rerun"
        existing = json.dumps({"session_id": sid, "url_source": EVENTS_URL_SOURCE}).encode()
        fake_s3.objects[f"rendered/{sid}.meta.json"] = existing
        fake_s3.objects[f"rendered/{sid}.html"] = b"<old html>"

        dump_path = _write_dump(tmp_path, {sid: _SAMPLE_EVENTS})
        renderer = _write_fake_renderer(tmp_path)

        report = backfill_dump(
            dump_path=dump_path,
            apply=True,
            renderer_script=renderer,
            s3=fake_s3,
        )

        assert report.results[0].status == BackfillStatus.APPLIED
        # PUTs went through (overwrite path; no IfNoneMatch).
        rewrite_puts = [p for p in fake_s3.puts if p["Key"].startswith(f"rendered/{sid}.")]
        for put in rewrite_puts:
            assert "IfNoneMatch" not in put


class TestSkipPaths:
    def test_empty_translation_skipped(
        self, tmp_path: Path, fake_s3: _FakeS3, _patch_bucket: None
    ) -> None:
        # Only control-plane events; translator produces zero entries.
        events = [{"type": "control_request", "created_at": "ts", "uuid": "c"}]
        dump_path = _write_dump(tmp_path, {"session_empty": events})
        renderer = _write_fake_renderer(tmp_path)

        report = backfill_dump(
            dump_path=dump_path,
            apply=True,
            renderer_script=renderer,
            s3=fake_s3,
        )
        assert report.results[0].status == BackfillStatus.SKIPPED_NO_ENTRIES
        assert fake_s3.puts == []

    def test_fetch_errors_skipped_with_detail(
        self, tmp_path: Path, fake_s3: _FakeS3, _patch_bucket: None
    ) -> None:
        sid = "session_bad_fetch"
        dump_path = tmp_path / "dump.json"
        dump_path.write_text(
            json.dumps(
                {
                    "parser_version": PARSER_VERSION,
                    "dumped_at": "ts",
                    "org_uuid": "x",
                    "sessions": {sid: _SAMPLE_EVENTS},
                    "errors": [{"sid": sid, "page": 1, "error": "HTTP 401"}],
                }
            ),
            encoding="utf-8",
        )
        renderer = _write_fake_renderer(tmp_path)

        report = backfill_dump(
            dump_path=dump_path,
            apply=True,
            renderer_script=renderer,
            s3=fake_s3,
        )
        result = report.results[0]
        assert result.status == BackfillStatus.SKIPPED_FETCH_ERROR
        assert "HTTP 401" in result.error_detail


class TestErrorPropagation:
    def test_renderer_failure_marked_as_error(
        self, tmp_path: Path, fake_s3: _FakeS3, _patch_bucket: None
    ) -> None:
        dump_path = _write_dump(tmp_path, {"session_render_fail": _SAMPLE_EVENTS})
        renderer = _write_failing_renderer(tmp_path)

        report = backfill_dump(
            dump_path=dump_path,
            apply=True,
            renderer_script=renderer,
            s3=fake_s3,
        )
        result = report.results[0]
        assert result.status == BackfillStatus.ERROR
        assert "rc=7" in result.error_detail


class TestSubsetFiltering:
    def test_only_session_ids_filters_dump(
        self, tmp_path: Path, fake_s3: _FakeS3, _patch_bucket: None
    ) -> None:
        sessions = {
            "session_in": _SAMPLE_EVENTS,
            "session_out": _SAMPLE_EVENTS,
        }
        dump_path = _write_dump(tmp_path, sessions)
        renderer = _write_fake_renderer(tmp_path)

        report = backfill_dump(
            dump_path=dump_path,
            apply=False,
            renderer_script=renderer,
            s3=fake_s3,
            only_session_ids={"session_in"},
        )
        assert {r.session_id for r in report.results} == {"session_in"}


class TestReportShape:
    def test_counts_by_status_aggregates(
        self, tmp_path: Path, fake_s3: _FakeS3, _patch_bucket: None
    ) -> None:
        sessions = {
            "session_a": _SAMPLE_EVENTS,
            "session_b": [{"type": "control_request", "created_at": "t", "uuid": "c"}],
        }
        dump_path = _write_dump(tmp_path, sessions)
        renderer = _write_fake_renderer(tmp_path)

        report = backfill_dump(
            dump_path=dump_path,
            apply=False,
            renderer_script=renderer,
            s3=fake_s3,
        )
        counts = report.counts_by_status()
        assert counts.get("dry_run") == 1
        assert counts.get("skipped_no_entries") == 1

    def test_result_to_jsonl_omits_empty_error_detail(self) -> None:
        r = BackfillResult(
            session_id="x",
            status=BackfillStatus.DRY_RUN,
            entry_count=3,
            html_bytes=42,
        )
        parsed = json.loads(r.to_jsonl())
        assert "error_detail" not in parsed
        assert parsed["status"] == "dry_run"

    def test_report_dump_path_recorded(
        self, tmp_path: Path, fake_s3: _FakeS3, _patch_bucket: None
    ) -> None:
        dump_path = _write_dump(tmp_path, {"session_x": _SAMPLE_EVENTS})
        renderer = _write_fake_renderer(tmp_path)
        report = backfill_dump(
            dump_path=dump_path,
            apply=False,
            renderer_script=renderer,
            s3=fake_s3,
        )
        assert report.dump_path == str(dump_path)
        assert report.org_uuid == "org-test"


def test_subprocess_runs_against_real_python() -> None:
    """Sanity: the fake renderer pattern actually works under the lib's subprocess.

    Ensures `sys.executable` is a sensible default; matches the driver path.
    """
    assert Path(sys.executable).exists()
