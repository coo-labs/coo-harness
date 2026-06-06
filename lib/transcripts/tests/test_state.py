"""Tests for transcripts.state — R2 cohort snapshot primitives.

Pure-function exercise on the snapshot/cohort math; one I/O-wrapper test
goes through a boto3-shaped fake to confirm take_snapshot() wires through
list_keys + read_sidecar correctly.
"""

from __future__ import annotations

import io
import json
from datetime import datetime, timedelta, timezone
from typing import Any, cast
from unittest.mock import patch

import pytest

from transcripts.state import (
    Artifact,
    R2Snapshot,
    compute_snapshot,
    is_count_drift,
    recent_rendered_without_ciphertext,
    sid_from_ciphertext_key,
    sid_from_rendered_key,
    take_snapshot,
)

FIXED_NOW = datetime(2026, 6, 6, 12, 0, 0, tzinfo=timezone.utc)


def _s3(client: object) -> Any:
    """Cast a duck-typed fake into the S3Client position for mypy."""
    return cast(Any, client)


class TestSidParsers:
    """Strict key-shape regexes — out-of-shape keys return None, not a guess.

    These are the boundary against `cron` consumers that walk paginated R2
    output unfiltered. Any False positive here would silently inflate cohort
    counts; any False negative drops real sessions from the snapshot.
    """

    @pytest.mark.parametrize(
        ("key", "expected"),
        [
            ("transcripts/2026/06/06/abc.jsonl.gz.age", "abc"),
            ("transcripts/2026/01/01/cse_uuid-with-dashes.jsonl.gz.age", "cse_uuid-with-dashes"),
        ],
    )
    def test_ciphertext_happy_path(self, key: str, expected: str) -> None:
        assert sid_from_ciphertext_key(key) == expected

    @pytest.mark.parametrize(
        "key",
        [
            "transcripts/abc.jsonl.gz.age",
            "transcripts/2026/06/abc.jsonl.gz.age",
            "transcripts/2026/06/06/sub/abc.jsonl.gz.age",
            "transcripts/2026/06/06/abc.jsonl",
            "transcripts/2026/06/06/abc.json",
            "rendered/abc.jsonl.gz.age",
            "transcripts/2026/6/6/abc.jsonl.gz.age",
            "",
        ],
    )
    def test_ciphertext_rejects_malformed(self, key: str) -> None:
        assert sid_from_ciphertext_key(key) is None

    @pytest.mark.parametrize(
        ("key", "suffix", "expected"),
        [
            ("rendered/abc.html", ".html", "abc"),
            ("rendered/abc.meta.json", ".meta.json", "abc"),
            ("rendered/cse_with-dash.html", ".html", "cse_with-dash"),
        ],
    )
    def test_rendered_happy_path(self, key: str, suffix: str, expected: str) -> None:
        assert sid_from_rendered_key(key, suffix) == expected

    @pytest.mark.parametrize(
        ("key", "suffix"),
        [
            ("rendered/.html", ".html"),
            ("rendered/sub/abc.html", ".html"),
            ("transcripts/abc.html", ".html"),
            ("rendered/abc.html", ".meta.json"),
        ],
    )
    def test_rendered_rejects_malformed(self, key: str, suffix: str) -> None:
        assert sid_from_rendered_key(key, suffix) is None


class TestComputeSnapshot:
    """Cohort classification + aggregate counts."""

    def test_complete_cohort(self) -> None:
        snap, assignment = compute_snapshot(
            ciphertext_sids=["a"],
            html_sids=["a"],
            sidecar_sids=["a"],
            now=FIXED_NOW,
        )
        assert snap.session_count == 1
        assert snap.cohort_counts["complete"] == 1
        assert assignment.by_sid == {"a": "complete"}

    def test_each_singleton_cohort(self) -> None:
        snap, assignment = compute_snapshot(
            ciphertext_sids=["only-cipher"],
            html_sids=["only-html"],
            sidecar_sids=["only-side"],
            now=FIXED_NOW,
        )
        assert snap.session_count == 3
        assert snap.cohort_counts["ciphertext_only"] == 1
        assert snap.cohort_counts["html_only"] == 1
        assert snap.cohort_counts["sidecar_only"] == 1
        assert snap.cohort_counts["complete"] == 0
        assert assignment.by_sid["only-cipher"] == "ciphertext_only"
        assert assignment.by_sid["only-html"] == "html_only"
        assert assignment.by_sid["only-side"] == "sidecar_only"

    def test_pair_cohorts(self) -> None:
        snap, assignment = compute_snapshot(
            ciphertext_sids=["ch", "cs"],
            html_sids=["ch", "hs"],
            sidecar_sids=["cs", "hs"],
            now=FIXED_NOW,
        )
        assert snap.cohort_counts["ciphertext_html_no_sidecar"] == 1
        assert snap.cohort_counts["ciphertext_sidecar_no_html"] == 1
        assert snap.cohort_counts["rendered_no_ciphertext"] == 1
        assert assignment.by_sid["ch"] == "ciphertext_html_no_sidecar"
        assert assignment.by_sid["cs"] == "ciphertext_sidecar_no_html"
        assert assignment.by_sid["hs"] == "rendered_no_ciphertext"

    def test_cohort_counts_sum_to_session_count(self) -> None:
        snap, _ = compute_snapshot(
            ciphertext_sids=["a", "b", "c"],
            html_sids=["b", "c", "d"],
            sidecar_sids=["c", "d", "e"],
            now=FIXED_NOW,
        )
        assert snap.session_count == sum(snap.cohort_counts.values())

    def test_counts_by_artifact_are_independent_sums(self) -> None:
        snap, _ = compute_snapshot(
            ciphertext_sids=["a", "b"],
            html_sids=["a"],
            sidecar_sids=[],
            now=FIXED_NOW,
        )
        assert snap.counts_by_artifact[Artifact.CIPHERTEXT.value] == 2
        assert snap.counts_by_artifact[Artifact.HTML.value] == 1
        assert snap.counts_by_artifact[Artifact.SIDECAR.value] == 0

    def test_url_source_counts_from_sidecars(self) -> None:
        sidecars: dict[str, dict[str, Any]] = {
            "a": {"url_source": "title-fast-path"},
            "b": {"url_source": "html-extract"},
            "c": {"url_source": "title-fast-path"},
            "d": {},
            "e": {"url_source": None},
            "f": {"url_source": ""},
        }
        snap, _ = compute_snapshot(
            ciphertext_sids=[],
            html_sids=[],
            sidecar_sids=list(sidecars),
            sidecars=sidecars,
            now=FIXED_NOW,
        )
        assert snap.url_source_counts == {
            "title-fast-path": 2,
            "html-extract": 1,
            "__untagged__": 3,
        }

    def test_url_source_counts_skip_sids_not_in_set(self) -> None:
        sidecars = {
            "a": {"url_source": "title-fast-path"},
            "b": {"url_source": "html-extract"},
        }
        snap, _ = compute_snapshot(
            ciphertext_sids=[],
            html_sids=[],
            sidecar_sids=["a"],
            sidecars=sidecars,
            now=FIXED_NOW,
        )
        assert snap.url_source_counts == {"title-fast-path": 1}

    def test_url_source_counts_empty_when_sidecars_none(self) -> None:
        snap, _ = compute_snapshot(
            ciphertext_sids=[],
            html_sids=[],
            sidecar_sids=["a"],
            sidecars=None,
            now=FIXED_NOW,
        )
        assert snap.url_source_counts == {}

    def test_captured_at_is_iso_utc_z(self) -> None:
        snap, _ = compute_snapshot(
            ciphertext_sids=[],
            html_sids=[],
            sidecar_sids=[],
            now=FIXED_NOW,
        )
        assert snap.captured_at == "2026-06-06T12:00:00Z"

    def test_captured_at_normalizes_offset(self) -> None:
        non_utc = datetime(2026, 6, 6, 14, 0, 0, tzinfo=timezone(timedelta(hours=2)))
        snap, _ = compute_snapshot(
            ciphertext_sids=[],
            html_sids=[],
            sidecar_sids=[],
            now=non_utc,
        )
        assert snap.captured_at == "2026-06-06T12:00:00Z"

    def test_default_now_is_utc(self) -> None:
        snap, _ = compute_snapshot(
            ciphertext_sids=[],
            html_sids=[],
            sidecar_sids=[],
        )
        assert snap.captured_at.endswith("Z")

    def test_empty_input_produces_zero_snapshot(self) -> None:
        snap, assignment = compute_snapshot(
            ciphertext_sids=[],
            html_sids=[],
            sidecar_sids=[],
            now=FIXED_NOW,
        )
        assert snap.session_count == 0
        assert assignment.by_sid == {}
        assert all(v == 0 for v in snap.cohort_counts.values())

    def test_assignment_in_cohort_filters(self) -> None:
        _, assignment = compute_snapshot(
            ciphertext_sids=["a", "b"],
            html_sids=["a"],
            sidecar_sids=["a"],
            now=FIXED_NOW,
        )
        assert assignment.in_cohort("complete") == ["a"]
        assert assignment.in_cohort("ciphertext_only") == ["b"]
        assert assignment.in_cohort("html_only") == []


class TestR2SnapshotSerialization:
    def test_as_dict_keys_sorted(self) -> None:
        snap = R2Snapshot(
            captured_at="2026-06-06T12:00:00Z",
            counts_by_artifact={"sidecar": 1, "ciphertext": 2, "html": 3},
            cohort_counts={"complete": 1, "ciphertext_only": 1},
            url_source_counts={"html-extract": 1, "title-fast-path": 2},
            session_count=2,
        )
        d = snap.as_dict()
        assert list(d["counts_by_artifact"]) == ["ciphertext", "html", "sidecar"]
        assert list(d["url_source_counts"]) == ["html-extract", "title-fast-path"]

    def test_as_jsonl_line_is_minified_and_newline_terminated(self) -> None:
        snap = R2Snapshot(
            captured_at="2026-06-06T12:00:00Z",
            counts_by_artifact={"ciphertext": 1, "html": 1, "sidecar": 1},
            cohort_counts={"complete": 1},
            url_source_counts={},
            session_count=1,
        )
        line = snap.as_jsonl_line()
        assert line.endswith("\n")
        assert " " not in line  # minified
        round_trip = json.loads(line)
        assert round_trip["session_count"] == 1
        assert round_trip["captured_at"] == "2026-06-06T12:00:00Z"


class TestRecentRenderedWithoutCiphertext:
    def _obj(self, key: str, last_modified: str) -> dict[str, Any]:
        return {"key": key, "size": 100, "last_modified": last_modified}

    def test_flags_old_sidecar_with_no_ciphertext(self) -> None:
        objs = [self._obj("rendered/old.meta.json", "2026-06-04T00:00:00+00:00")]
        out = recent_rendered_without_ciphertext(
            objs,
            ciphertext_sids=[],
            grace=timedelta(hours=24),
            now=FIXED_NOW,
        )
        assert out == ["old"]

    def test_respects_grace_window(self) -> None:
        recent = (FIXED_NOW - timedelta(hours=1)).isoformat()
        objs = [self._obj("rendered/recent.meta.json", recent)]
        out = recent_rendered_without_ciphertext(
            objs,
            ciphertext_sids=[],
            grace=timedelta(hours=24),
            now=FIXED_NOW,
        )
        assert out == []

    def test_skips_when_ciphertext_present(self) -> None:
        objs = [self._obj("rendered/paired.meta.json", "2026-06-04T00:00:00+00:00")]
        out = recent_rendered_without_ciphertext(
            objs,
            ciphertext_sids=["paired"],
            grace=timedelta(hours=24),
            now=FIXED_NOW,
        )
        assert out == []

    def test_html_objects_ignored(self) -> None:
        objs = [self._obj("rendered/orphan.html", "2026-06-04T00:00:00+00:00")]
        out = recent_rendered_without_ciphertext(
            objs,
            ciphertext_sids=[],
            grace=timedelta(hours=24),
            now=FIXED_NOW,
        )
        assert out == []

    def test_z_suffix_accepted(self) -> None:
        objs = [self._obj("rendered/old.meta.json", "2026-06-04T00:00:00Z")]
        out = recent_rendered_without_ciphertext(
            objs,
            ciphertext_sids=[],
            grace=timedelta(hours=24),
            now=FIXED_NOW,
        )
        assert out == ["old"]

    def test_naive_timestamp_treated_as_utc(self) -> None:
        objs = [self._obj("rendered/old.meta.json", "2026-06-04T00:00:00")]
        out = recent_rendered_without_ciphertext(
            objs,
            ciphertext_sids=[],
            grace=timedelta(hours=24),
            now=FIXED_NOW,
        )
        assert out == ["old"]

    def test_malformed_timestamp_skipped(self) -> None:
        objs = [self._obj("rendered/old.meta.json", "not-a-date")]
        out = recent_rendered_without_ciphertext(
            objs,
            ciphertext_sids=[],
            grace=timedelta(hours=24),
            now=FIXED_NOW,
        )
        assert out == []

    def test_missing_last_modified_skipped(self) -> None:
        objs = [{"key": "rendered/x.meta.json", "size": 0}]
        out = recent_rendered_without_ciphertext(
            objs,
            ciphertext_sids=[],
            grace=timedelta(hours=24),
            now=FIXED_NOW,
        )
        assert out == []

    def test_non_string_last_modified_skipped(self) -> None:
        objs = [{"key": "rendered/x.meta.json", "size": 0, "last_modified": 42}]
        out = recent_rendered_without_ciphertext(
            objs,
            ciphertext_sids=[],
            grace=timedelta(hours=24),
            now=FIXED_NOW,
        )
        assert out == []

    def test_output_sorted(self) -> None:
        objs = [
            self._obj("rendered/zzz.meta.json", "2026-06-04T00:00:00Z"),
            self._obj("rendered/aaa.meta.json", "2026-06-04T00:00:00Z"),
            self._obj("rendered/mmm.meta.json", "2026-06-04T00:00:00Z"),
        ]
        out = recent_rendered_without_ciphertext(
            objs,
            ciphertext_sids=[],
            grace=timedelta(hours=24),
            now=FIXED_NOW,
        )
        assert out == ["aaa", "mmm", "zzz"]


class TestIsCountDrift:
    @pytest.mark.parametrize(
        ("today", "yesterday", "expected"),
        [
            (10, 100, True),
            (49, 100, True),
            (50, 100, False),
            (51, 100, False),
            (100, 100, False),
            (200, 100, False),
            (0, 100, True),
            (0, 1, True),
        ],
    )
    def test_default_threshold(self, today: int, yesterday: int, expected: bool) -> None:
        assert is_count_drift(today, yesterday) is expected

    def test_no_baseline_returns_false(self) -> None:
        assert is_count_drift(0, 0) is False
        assert is_count_drift(100, 0) is False

    def test_custom_threshold(self) -> None:
        assert is_count_drift(80, 100, threshold=0.9) is True
        assert is_count_drift(90, 100, threshold=0.9) is False

    def test_negative_counts_raise(self) -> None:
        with pytest.raises(ValueError, match="non-negative"):
            is_count_drift(-1, 100)
        with pytest.raises(ValueError, match="non-negative"):
            is_count_drift(50, -1)


class _FakeDateTime:
    def isoformat(self) -> str:
        return "2026-06-06T12:00:00+00:00"


class FakeS3Client:
    """boto3-shaped fake for take_snapshot — list + get only."""

    def __init__(self, objects: dict[str, bytes]) -> None:
        self.objects = objects
        self.gets: list[str] = []

    def get_object(self, *, Bucket: str, Key: str) -> dict[str, Any]:
        self.gets.append(Key)
        if Key not in self.objects:
            err = type("NoSuchKey", (Exception,), {"response": {"Error": {"Code": "NoSuchKey"}}})
            raise err()
        return {"Body": io.BytesIO(self.objects[Key])}

    def get_paginator(self, op: str) -> FakePaginator:
        return FakePaginator(self)


class FakePaginator:
    def __init__(self, client: FakeS3Client) -> None:
        self.client = client

    def paginate(self, *, Bucket: str, Prefix: str) -> list[dict[str, Any]]:
        contents = [
            {"Key": k, "Size": len(v), "LastModified": _FakeDateTime()}
            for k, v in self.client.objects.items()
            if k.startswith(Prefix)
        ]
        return [{"Contents": contents}] if contents else [{}]


class TestTakeSnapshot:
    def test_round_trip_against_fake_r2(self) -> None:
        objs: dict[str, bytes] = {
            "transcripts/2026/06/06/a.jsonl.gz.age": b"x",
            "transcripts/2026/06/06/b.jsonl.gz.age": b"x",
            "rendered/a.html": b"x",
            "rendered/a.meta.json": json.dumps({"url_source": "title-fast-path"}).encode(),
            "rendered/c.html": b"x",
            "rendered/c.meta.json": json.dumps({"url_source": "html-extract"}).encode(),
        }
        client = FakeS3Client(objs)
        with patch("transcripts.r2._bucket_from_env_or_op", return_value="bkt"):
            snap, assignment = take_snapshot(s3=_s3(client), now=FIXED_NOW)
        assert snap.session_count == 3
        assert snap.counts_by_artifact == {"ciphertext": 2, "html": 2, "sidecar": 2}
        assert snap.cohort_counts["complete"] == 1
        assert snap.cohort_counts["ciphertext_only"] == 1
        assert snap.cohort_counts["rendered_no_ciphertext"] == 1
        assert snap.url_source_counts == {"title-fast-path": 1, "html-extract": 1}
        assert assignment.by_sid == {
            "a": "complete",
            "b": "ciphertext_only",
            "c": "rendered_no_ciphertext",
        }

    def test_read_sidecars_false_skips_get(self) -> None:
        objs: dict[str, bytes] = {
            "rendered/a.meta.json": json.dumps({"url_source": "title-fast-path"}).encode(),
        }
        client = FakeS3Client(objs)
        with patch("transcripts.r2._bucket_from_env_or_op", return_value="bkt"):
            snap, _ = take_snapshot(s3=_s3(client), now=FIXED_NOW, read_sidecars=False)
        assert snap.url_source_counts == {}
        assert client.gets == []

    def test_malformed_keys_ignored(self) -> None:
        objs: dict[str, bytes] = {
            "transcripts/bad-no-date.jsonl.gz.age": b"x",
            "rendered/sub/oops.html": b"x",
            "transcripts/2026/06/06/good.jsonl.gz.age": b"x",
        }
        client = FakeS3Client(objs)
        with patch("transcripts.r2._bucket_from_env_or_op", return_value="bkt"):
            snap, _ = take_snapshot(s3=_s3(client), now=FIXED_NOW, read_sidecars=False)
        assert snap.session_count == 1
        assert snap.counts_by_artifact == {"ciphertext": 1, "html": 0, "sidecar": 0}

    def test_empty_r2_produces_zero_snapshot(self) -> None:
        objs: dict[str, bytes] = {}
        client = FakeS3Client(objs)
        with patch("transcripts.r2._bucket_from_env_or_op", return_value="bkt"):
            snap, assignment = take_snapshot(s3=_s3(client), now=FIXED_NOW)
        assert snap.session_count == 0
        assert assignment.by_sid == {}
