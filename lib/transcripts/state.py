"""R2 cohort snapshot — point-in-time inventory of the transcript pipeline's
artifact state across the `transcripts/` and `rendered/` prefixes.

What a snapshot captures, per session_id:

  - whether the ciphertext blob (`transcripts/<YYYY>/<MM>/<DD>/<sid>.jsonl.gz.age`)
    is present
  - whether the rendered HTML (`rendered/<sid>.html`) is present
  - whether the rendered sidecar (`rendered/<sid>.meta.json`) is present

Each session falls into a cohort defined by which subset of the three is
present. The interesting cohorts are the partial ones — the cron in
coo-console consumes these to detect substrate drift (cipher-no-render,
render-no-cipher, sidecar-without-html, etc.).

This module is the pure-Python primitives layer:

  - `compute_snapshot()` — takes already-enumerated sets and produces a
    serializable `R2Snapshot`. Has no I/O.
  - `take_snapshot()` — wraps the pure function with the R2 walk so callers
    that just want "give me the current snapshot" don't have to wire the
    list_keys / read_sidecar primitives themselves.
  - `recent_rendered_without_ciphertext()` — the cron's reconciliation
    invariant: a `rendered/<sid>.meta.json` older than a grace window must
    have a ciphertext peer.
  - `is_count_drift()` — the cron's drift detector: today's count below
    `threshold * yesterday's count` signals a producer regression.

`R2Snapshot.as_jsonl_line()` serializes one-line JSON suitable for
append-only writes to `coo-labs/coo-logs/state/r2-inventory.jsonl`.

Cohort math reference: coo-labs/coo-memory#1145's parent cohort numbers
(329 ciphertext / 279 html / 240 sidecars across 563 server-side sessions
as of 2026-06-01).
"""

from __future__ import annotations

import json
import re
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from enum import Enum
from typing import TYPE_CHECKING, Any

from transcripts.r2 import _bucket_from_env_or_op, list_keys, r2_client, read_sidecar

if TYPE_CHECKING:
    from mypy_boto3_s3.client import S3Client
else:
    S3Client = Any


CIPHERTEXT_PREFIX: str = "transcripts/"
RENDERED_PREFIX: str = "rendered/"
CIPHERTEXT_SUFFIX: str = ".jsonl.gz.age"
HTML_SUFFIX: str = ".html"
SIDECAR_SUFFIX: str = ".meta.json"


class Artifact(str, Enum):
    """Which artifact a session has in R2.

    A cohort is a frozenset of these — `{CIPHERTEXT, HTML, SIDECAR}` is the
    complete-record cohort; `{CIPHERTEXT}` is the unrendered cohort; etc.
    """

    CIPHERTEXT = "ciphertext"
    HTML = "html"
    SIDECAR = "sidecar"


COHORT_LABELS: dict[frozenset[Artifact], str] = {
    frozenset({Artifact.CIPHERTEXT, Artifact.HTML, Artifact.SIDECAR}): "complete",
    frozenset({Artifact.CIPHERTEXT, Artifact.HTML}): "ciphertext_html_no_sidecar",
    frozenset({Artifact.CIPHERTEXT, Artifact.SIDECAR}): "ciphertext_sidecar_no_html",
    frozenset({Artifact.HTML, Artifact.SIDECAR}): "rendered_no_ciphertext",
    frozenset({Artifact.CIPHERTEXT}): "ciphertext_only",
    frozenset({Artifact.HTML}): "html_only",
    frozenset({Artifact.SIDECAR}): "sidecar_only",
}
"""Stable human-readable name for each non-empty cohort. The empty cohort is
never reported — a session with no artifacts in R2 is by definition not in
the snapshot's universe.
"""

_UNTAGGED_URL_SOURCE: str = "__untagged__"
"""Sentinel for sidecars whose `url_source` field is missing, null, or empty
— pre-taxonomy sidecars. Stored explicitly so the count is visible alongside
the named tags rather than silently dropped.
"""


_CIPHERTEXT_KEY_RE: re.Pattern[str] = re.compile(
    r"^transcripts/\d{4}/\d{2}/\d{2}/([^/]+)\.jsonl\.gz\.age$"
)


def sid_from_ciphertext_key(key: str) -> str | None:
    """Extract session_id from `transcripts/<YYYY>/<MM>/<DD>/<sid>.jsonl.gz.age`.

    Returns None on any key shape mismatch — including a top-level `transcripts/`
    key (no date layout) or a key with a trailing slash. The strict regex
    keeps malformed objects out of the cohort counts.
    """
    m = _CIPHERTEXT_KEY_RE.match(key)
    return m.group(1) if m else None


def sid_from_rendered_key(key: str, suffix: str) -> str | None:
    """Extract session_id from `rendered/<sid><suffix>`.

    `suffix` is one of `.html` or `.meta.json`. Returns None on anything that
    doesn't match the strict `rendered/<sid><suffix>` shape — no subdirectories,
    no missing prefix.
    """
    if not key.startswith(RENDERED_PREFIX) or not key.endswith(suffix):
        return None
    sid = key[len(RENDERED_PREFIX) : -len(suffix)]
    if not sid or "/" in sid:
        return None
    return sid


@dataclass(frozen=True)
class R2Snapshot:
    """Point-in-time inventory snapshot of the transcripts pipeline in R2.

    Fields:

    - `captured_at` — ISO-8601 UTC string. The wall-clock time at which the
      snapshot was taken; used by the daily cron as the JSONL line's
      ordering key and by drift comparisons.
    - `counts_by_artifact` — total objects per artifact category. Independent
      sums; a complete session contributes one to each of the three.
    - `cohort_counts` — count per cohort label. Sums of cohort_counts equal
      the size of the session_id universe (distinct sids across all three
      prefixes).
    - `url_source_counts` — for sidecars that were read, count per
      `url_source` tag. `__untagged__` aggregates the pre-taxonomy / unset
      cases. Total may be less than `counts_by_artifact["sidecar"]` if the
      snapshot was taken with `read_sidecars=False`.
    - `session_count` — distinct session_id count across the prefixes. Equals
      the sum of `cohort_counts` values.
    """

    captured_at: str
    counts_by_artifact: dict[str, int]
    cohort_counts: dict[str, int]
    url_source_counts: dict[str, int]
    session_count: int

    def as_dict(self) -> dict[str, Any]:
        """Plain-dict view, sorted for stable JSON output."""
        return {
            "captured_at": self.captured_at,
            "counts_by_artifact": dict(sorted(self.counts_by_artifact.items())),
            "cohort_counts": dict(sorted(self.cohort_counts.items())),
            "url_source_counts": dict(sorted(self.url_source_counts.items())),
            "session_count": self.session_count,
        }

    def as_jsonl_line(self) -> str:
        """One-line JSON for append-only logs (terminated with a newline).

        Suitable for `coo-labs/coo-logs/state/r2-inventory.jsonl` — minified,
        deterministic key order, newline-terminated so consecutive append
        writes don't run together.
        """
        return json.dumps(self.as_dict(), separators=(",", ":")) + "\n"


@dataclass(frozen=True)
class CohortAssignment:
    """Per-session cohort membership — `(sid, cohort_label)` pairs.

    Returned alongside the aggregate snapshot when a caller needs to walk the
    individual sids in a cohort (the cron's reconciliation pass, for example).
    """

    by_sid: dict[str, str] = field(default_factory=dict)

    def in_cohort(self, label: str) -> list[str]:
        """All session_ids whose cohort label matches. Order is insertion-order
        from the underlying dict — callers that need sorted output sort it.
        """
        return [sid for sid, lbl in self.by_sid.items() if lbl == label]


def _classify_session(
    sid: str,
    *,
    ciphertext: set[str],
    html: set[str],
    sidecar: set[str],
) -> str:
    cohort: frozenset[Artifact] = frozenset(
        a
        for a, members in (
            (Artifact.CIPHERTEXT, ciphertext),
            (Artifact.HTML, html),
            (Artifact.SIDECAR, sidecar),
        )
        if sid in members
    )
    label = COHORT_LABELS.get(cohort)
    if label is None:
        raise ValueError(f"unreachable: empty cohort for sid {sid}")
    return label


def _count_url_sources(sidecars: Mapping[str, dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for meta in sidecars.values():
        src = meta.get("url_source")
        key = src if isinstance(src, str) and src else _UNTAGGED_URL_SOURCE
        counts[key] = counts.get(key, 0) + 1
    return counts


def compute_snapshot(
    *,
    ciphertext_sids: Iterable[str],
    html_sids: Iterable[str],
    sidecar_sids: Iterable[str],
    sidecars: Mapping[str, dict[str, Any]] | None = None,
    now: datetime | None = None,
) -> tuple[R2Snapshot, CohortAssignment]:
    """Build a snapshot from already-enumerated session_id sets.

    Pure function — no I/O. Tests exercise this directly with fixture data;
    `take_snapshot()` is the thin I/O wrapper around it.

    `sidecars` is the per-sid sidecar dict (`{sid: meta_json}`); when None,
    `url_source_counts` is computed empty. Sids in `sidecars` that aren't in
    `sidecar_sids` are ignored — `sidecar_sids` is the authoritative set.

    `now` defaults to `datetime.now(timezone.utc)` and is used only to stamp
    `captured_at`. Tests pass a fixed instant for determinism.

    Returns `(snapshot, assignment)`. The aggregate snapshot is the JSONL
    payload; the assignment carries per-sid cohort labels for callers that
    need to walk individual sids (the cron's reconciliation pass, the
    drift-issue body).
    """
    if now is None:
        now = datetime.now(timezone.utc)

    cipher_set = set(ciphertext_sids)
    html_set = set(html_sids)
    sidecar_set = set(sidecar_sids)

    all_sids = cipher_set | html_set | sidecar_set
    counts_by_artifact = {
        Artifact.CIPHERTEXT.value: len(cipher_set),
        Artifact.HTML.value: len(html_set),
        Artifact.SIDECAR.value: len(sidecar_set),
    }
    by_sid: dict[str, str] = {}
    cohort_counts: dict[str, int] = {label: 0 for label in COHORT_LABELS.values()}
    for sid in sorted(all_sids):
        label = _classify_session(
            sid,
            ciphertext=cipher_set,
            html=html_set,
            sidecar=sidecar_set,
        )
        by_sid[sid] = label
        cohort_counts[label] += 1

    url_source_counts: dict[str, int] = {}
    if sidecars is not None:
        scoped = {sid: meta for sid, meta in sidecars.items() if sid in sidecar_set}
        url_source_counts = _count_url_sources(scoped)

    snapshot = R2Snapshot(
        captured_at=now.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        counts_by_artifact=counts_by_artifact,
        cohort_counts=cohort_counts,
        url_source_counts=url_source_counts,
        session_count=len(all_sids),
    )
    return snapshot, CohortAssignment(by_sid=by_sid)


def take_snapshot(
    s3: S3Client | None = None,
    *,
    bucket: str | None = None,
    now: datetime | None = None,
    read_sidecars: bool = True,
) -> tuple[R2Snapshot, CohortAssignment]:
    """Walk R2 and produce a current snapshot.

    Lists every object under `transcripts/` and `rendered/`; if
    `read_sidecars=True`, GETs each `rendered/<sid>.meta.json` to capture
    the url_source distribution.

    Production paging cost: at the parent issue's 2026-06-01 measurements
    (~329 ciphertexts + ~519 rendered objects), this is ~5 list pages and
    ~240 sidecar reads — well within Worker / scheduled-task budgets, but
    the sidecar reads dominate. `read_sidecars=False` skips them when the
    caller only needs cohort counts.
    """
    if s3 is None:
        s3 = r2_client()
    if bucket is None:
        bucket = _bucket_from_env_or_op()

    ciphertext_objs = list_keys(CIPHERTEXT_PREFIX, s3=s3)
    rendered_objs = list_keys(RENDERED_PREFIX, s3=s3)

    cipher_sids: set[str] = set()
    for obj in ciphertext_objs:
        sid = sid_from_ciphertext_key(obj["key"])
        if sid is not None:
            cipher_sids.add(sid)

    html_sids: set[str] = set()
    sidecar_sids: set[str] = set()
    for obj in rendered_objs:
        key = obj["key"]
        html_sid = sid_from_rendered_key(key, HTML_SUFFIX)
        if html_sid is not None:
            html_sids.add(html_sid)
            continue
        meta_sid = sid_from_rendered_key(key, SIDECAR_SUFFIX)
        if meta_sid is not None:
            sidecar_sids.add(meta_sid)

    sidecars: dict[str, dict[str, Any]] | None
    if read_sidecars:
        sidecars = {}
        for sid in sidecar_sids:
            meta = read_sidecar(sid, s3=s3)
            if meta is not None:
                sidecars[sid] = meta
    else:
        sidecars = None

    return compute_snapshot(
        ciphertext_sids=cipher_sids,
        html_sids=html_sids,
        sidecar_sids=sidecar_sids,
        sidecars=sidecars,
        now=now,
    )


def recent_rendered_without_ciphertext(
    rendered_objs: Iterable[dict[str, Any]],
    *,
    ciphertext_sids: Iterable[str],
    grace: timedelta,
    now: datetime,
) -> list[str]:
    """The cron's reconciliation invariant.

    Returns session_ids whose `rendered/<sid>.meta.json` sidecar exists in R2,
    is older than `grace`, and has no ciphertext peer under `transcripts/`.

    A sidecar within the grace window is treated as in-flight: the export
    hook writes the sidecar after the ciphertext, but R2 is eventually-
    consistent on enumeration. The grace window is the operator's policy
    knob — the cron's default is 24 hours per the issue's reconciliation
    spec.

    Inputs are paths through list_keys' output: `{key, size, last_modified}`
    where `last_modified` is an ISO-8601 string. Only sidecar keys are
    inspected; html-only entries are skipped (orphan HTML is a separate
    drift category, not a reconciliation miss).
    """
    cipher_set = set(ciphertext_sids)
    cutoff = now - grace
    out: list[str] = []
    for obj in rendered_objs:
        key = obj["key"]
        sid = sid_from_rendered_key(key, SIDECAR_SUFFIX)
        if sid is None:
            continue
        if sid in cipher_set:
            continue
        lm_str = obj.get("last_modified", "")
        if not isinstance(lm_str, str):
            continue
        try:
            lm = _parse_iso8601(lm_str)
        except ValueError:
            continue
        if lm <= cutoff:
            out.append(sid)
    out.sort()
    return out


def _parse_iso8601(s: str) -> datetime:
    """Parse the ISO-8601 last_modified strings list_keys emits.

    Accepts both `+00:00` and a trailing `Z` for UTC. The list_keys output is
    `datetime.isoformat()`, which uses `+00:00`; we accept `Z` so the same
    primitive works against any consumer that normalizes the timestamp.
    """
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def is_count_drift(
    today: int,
    yesterday: int,
    *,
    threshold: float = 0.5,
) -> bool:
    """True when today's count has fallen below `threshold * yesterday`.

    The cron's alarm condition — fires an issue when ciphertext or rendered
    counts collapse to under half the previous day's tally, the simplest
    signal that an upstream producer stopped writing. A growing or steady
    count is fine; the alarm is for the regression case only.

    Trivial-edge handling: `yesterday == 0` returns False — without a prior
    baseline there's no drift to measure. `today < 0` or `yesterday < 0` is
    caller error and raises ValueError.
    """
    if today < 0 or yesterday < 0:
        raise ValueError("counts must be non-negative")
    if yesterday == 0:
        return False
    return today < threshold * yesterday
