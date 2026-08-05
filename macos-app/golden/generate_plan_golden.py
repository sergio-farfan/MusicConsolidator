#!/usr/bin/env python3
"""Export plan golden fixtures from the Python reference implementation (resolver.build_plan /
resolver.build_merge_plan) for the Swift M2 parity gate.

Run from the project root so `apple_music_consolidator` is importable:

    python3 macos-app/golden/generate_plan_golden.py

Writes macos-app/golden/plan_golden.json. Byte-reproducible: every input is a
static literal (or the checked-in tests/fixtures/music_snapshot.json) and the
outputs are pure functions of them.

Schema:
    {
      "build_plan_cases": [
        {"name", "source": <PlaylistSnapshot.to_dict()>,
         "expected": {"source_playlist_name", "source_playlist_persistent_id",
                      "source_track_count", "winner_source_indexes",
                      "decisions": [<DuplicateDecision.to_dict()>],
                      "non_eligible_source_indexes",
                      "output_tracks": [<TrackSnapshot.to_dict()>] | null}}
      ],
      "build_merge_plan_cases": [
        {"name", "merged_name", "copies": [<PlaylistSnapshot.to_dict()>],
         "expected": {"merged_playlist_source_name", "winner_source_indexes",
                      "decisions", "non_eligible_source_indexes",
                      "combined_track_count", "copy_boundaries",
                      "combined_tracks": [<TrackSnapshot.to_dict()>],
                      "output_tracks": [<TrackSnapshot.to_dict()>]}}
      ]
    }

Fingerprints are deliberately NOT exported: the Swift side owns its own
canonical encoding + SHA-256 (locked plan decision); parity compares RESULTS.

"output_tracks" is the full ordered output (the winning track for each entry
of winner_source_indexes). It is null when the synthetic source reuses a
source_index (the index alone cannot identify the track); those cases pin the
winner via the decisions' embedded winner snapshot instead.
"""

import json
import sys
import unicodedata
from dataclasses import replace
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = OUT_DIR.parents[1]  # macos-app/golden -> macos-app -> project root
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from apple_music_consolidator.models import (  # noqa: E402
    PlaylistSnapshot,
    combine_source_tracks,
)
from apple_music_consolidator.music_bridge import parse_exact_playlist_snapshot  # noqa: E402
from apple_music_consolidator.normalize import normalize_text  # noqa: E402
from apple_music_consolidator.resolver import build_merge_plan, build_plan  # noqa: E402
from tests.helpers import track  # noqa: E402


# ---------------------------------------------------------------------------
# build_plan sources
# ---------------------------------------------------------------------------

def fixture_playlist() -> PlaylistSnapshot:
    raw = (PROJECT_ROOT / "tests" / "fixtures" / "music_snapshot.json").read_text(
        encoding="utf-8"
    )
    return parse_exact_playlist_snapshot(raw, "#Musica xTotal")


# Canonically-equivalent-but-scalar-different pair (binding M1 finding):
# normalize_text("ΐ") == "ΐ" while
# normalize_text("Ϊ́") == "ΐ" — same NFC, different
# code points; the reference keeps them as two distinct tracks.
SCALAR_PAIR_TITLE_A = "ΐ"
SCALAR_PAIR_TITLE_B = "Ϊ́"
_norm_a = normalize_text(SCALAR_PAIR_TITLE_A)
_norm_b = normalize_text(SCALAR_PAIR_TITLE_B)
assert _norm_a != _norm_b, "scalar pair must stay code-point distinct"
assert unicodedata.normalize("NFC", _norm_a) == unicodedata.normalize("NFC", _norm_b), (
    "scalar pair must be canonically equivalent"
)

BUILD_PLAN_SOURCES: list[tuple[str, PlaylistSnapshot]] = [
    ("fixture_musica_xtotal", fixture_playlist()),
    (
        # tests/test_resolver.py::test_resolver_prefers_available_then_higher_sample_rate
        "prefers_available_then_higher_sample_rate",
        PlaylistSnapshot(
            "Source",
            "PLAYLIST",
            (
                track(source_index=0, persistent_id="FIRST", sample_rate_hz=44100),
                track(
                    source_index=1,
                    persistent_id="OLD",
                    kind="AIFF audio file",
                    sample_rate_hz=96000,
                    cloud_status="No Longer Available",
                    is_file_track=True,
                ),
                track(source_index=2, persistent_id="BEST", sample_rate_hz=48000),
            ),
        ),
    ),
    (
        "never_collapses_artist_spelling_or_duration",
        PlaylistSnapshot(
            "Source",
            "PLAYLIST",
            (
                track(source_index=0, artist="Jordan Léser", duration_ms=192000),
                track(source_index=1, artist="Jordan Laser", duration_ms=192000),
                track(source_index=2, artist="Jordan Léser", duration_ms=192001),
            ),
        ),
    ),
    (
        "non_eligible_retained_in_place",
        PlaylistSnapshot(
            "Source",
            "PLAYLIST",
            (
                track(source_index=0, title=""),
                track(source_index=1, persistent_id="LOW", bit_rate_kbps=128),
                track(source_index=2, persistent_id="HIGH", bit_rate_kbps=320),
                track(source_index=3, artist="", persistent_id="NO_ARTIST"),
            ),
        ),
    ),
    (
        # Ties broken at successive stages: availability, then sample rate.
        "first_decisive_quality_difference",
        PlaylistSnapshot(
            "Source",
            "PLAYLIST",
            (
                track(source_index=0, persistent_id="UNAVAILABLE", cloud_status="no longer available"),
                track(source_index=1, persistent_id="LOW_RATE", sample_rate_hz=44100),
                track(source_index=2, persistent_id="WIN", sample_rate_hz=48000),
            ),
        ),
    ),
    (
        "lossless_before_sample_rate",
        PlaylistSnapshot(
            "Source",
            "PLAYLIST",
            (
                track(source_index=0, persistent_id="LOSSY", sample_rate_hz=96000),
                track(source_index=1, persistent_id="LOSSLESS", kind="AIFF audio file", sample_rate_hz=44100),
            ),
        ),
    ),
    (
        "bit_rate_after_prior_ties",
        PlaylistSnapshot(
            "Source",
            "PLAYLIST",
            (
                track(source_index=0, persistent_id="LOW", bit_rate_kbps=128),
                track(source_index=1, persistent_id="HIGH", bit_rate_kbps=320),
            ),
        ),
    ),
    (
        # Winner has the LATER position; indexes are unique but non-positional.
        "source_order_after_quality_ties",
        PlaylistSnapshot(
            "Source",
            "PLAYLIST",
            (
                track(source_index=8, persistent_id="LATER"),
                track(source_index=3, persistent_id="EARLIER"),
            ),
        ),
    ),
    (
        # Both tracks share source_index 0 -> output_tracks is null; the
        # decisions' embedded winner snapshot pins the outcome.
        "persistent_id_after_source_order_ties",
        PlaylistSnapshot(
            "Source",
            "PLAYLIST",
            (
                track(source_index=0, persistent_id="ZZZ"),
                track(source_index=0, persistent_id="AAA"),
            ),
        ),
    ),
    (
        # Every group member is unavailable; later criteria still decide.
        "unavailable_only_group",
        PlaylistSnapshot(
            "Source",
            "PLAYLIST",
            (
                track(
                    source_index=0,
                    persistent_id="GONE_LOW",
                    cloud_status="No Longer Available",
                    sample_rate_hz=44100,
                ),
                track(
                    source_index=1,
                    persistent_id="GONE_HIGH",
                    cloud_status="no longer available",
                    sample_rate_hz=48000,
                ),
            ),
        ),
    ),
    (
        "all_non_eligible",
        PlaylistSnapshot(
            "Source",
            "PLAYLIST",
            (
                track(source_index=0, title="", persistent_id="NO_TITLE"),
                track(source_index=1, artist="   ", persistent_id="BLANK_ARTIST"),
                track(source_index=2, duration_ms=None, persistent_id="NO_DURATION"),
            ),
        ),
    ),
    (
        # Winner sits at index 2 but its group is anchored at position 0, so
        # winner_source_indexes must lead with 2 (non-monotonic output order).
        "winner_at_earliest_index_ordering",
        PlaylistSnapshot(
            "Source",
            "PLAYLIST",
            (
                track(source_index=0, persistent_id="DUP_LOW", sample_rate_hz=44100),
                track(source_index=1, persistent_id="UNIQUE", title="Unique"),
                track(source_index=2, persistent_id="DUP_HIGH", sample_rate_hz=96000),
            ),
        ),
    ),
    ("empty_playlist", PlaylistSnapshot("Empty", "PLAYLIST-EMPTY", ())),
    (
        "scalar_different_canonically_equivalent_pair",
        PlaylistSnapshot(
            "Source",
            "PLAYLIST",
            (
                track(source_index=0, title=SCALAR_PAIR_TITLE_A, persistent_id="P0"),
                track(source_index=1, title=SCALAR_PAIR_TITLE_B, persistent_id="P1"),
            ),
        ),
    ),
    (
        # tests/test_audit.py::ProvenanceTests — one omitted duplicate, one
        # retained winner, one unique, one non-eligible.
        "provenance_mixed_actions",
        PlaylistSnapshot(
            "#Musica xTotal",
            "PLAYLIST",
            (
                track(
                    source_index=0,
                    database_id=100,
                    persistent_id="OMITTED",
                    title="Same",
                    artist="Artist",
                    album="Old",
                    duration_ms=180001,
                    kind="Apple Music AAC audio file",
                    bit_rate_kbps=128,
                    sample_rate_hz=44100,
                    cloud_status="No Longer Available",
                    is_file_track=False,
                ),
                track(
                    source_index=1,
                    database_id=101,
                    persistent_id="WINNER",
                    title="Same",
                    artist="Artist",
                    album="Master",
                    duration_ms=180001,
                    kind="AIFF audio file",
                    bit_rate_kbps=1411,
                    sample_rate_hz=96000,
                    cloud_status="matched",
                    is_file_track=True,
                ),
                track(
                    source_index=2,
                    database_id=102,
                    persistent_id="UNIQUE",
                    title="Unique",
                    artist="Solo",
                    album="Only",
                    duration_ms=200002,
                    bit_rate_kbps=256,
                    sample_rate_hz=48000,
                    cloud_status="uploaded",
                ),
                track(
                    source_index=3,
                    database_id=103,
                    persistent_id="NONELIGIBLE",
                    title="Missing Artist",
                    artist="",
                    album="Unknown",
                    duration_ms=210003,
                    kind="MPEG audio file",
                    bit_rate_kbps=None,
                    sample_rate_hz=None,
                    cloud_status="",
                    is_file_track=True,
                ),
            ),
        ),
    ),
]


# ---------------------------------------------------------------------------
# build_merge_plan sources
# ---------------------------------------------------------------------------

def merge_test_copies() -> tuple[PlaylistSnapshot, ...]:
    """tests/test_resolver.py::MergeResolverTests._copies."""
    copy_a = PlaylistSnapshot(
        "90s Techno",
        "PID-A",
        (
            track(source_index=0, database_id=1, persistent_id="LOSSY",
                  title="Firestarter", artist="The Prodigy",
                  duration_ms=280000, sample_rate_hz=44100),
            track(source_index=1, database_id=2, persistent_id="ONLY-A",
                  title="Around the World", artist="Daft Punk",
                  duration_ms=430000),
        ),
    )
    copy_b = PlaylistSnapshot(
        "90s Techno",
        "PID-B",
        (
            track(source_index=0, database_id=3, persistent_id="LOSSLESS",
                  title="Firestarter", artist="The Prodigy",
                  duration_ms=280000, kind="AIFF audio file",
                  sample_rate_hz=96000),
            track(source_index=1, database_id=4, persistent_id="ONLY-B",
                  title="Enjoy the Silence", artist="Depeche Mode",
                  duration_ms=370000),
        ),
    )
    return (copy_a, copy_b)


_fixture = fixture_playlist()

BUILD_MERGE_PLAN_SOURCES: list[tuple[str, str, tuple[PlaylistSnapshot, ...]]] = [
    ("fixture_single_copy", _fixture.name, (_fixture,)),
    (
        # Same fixture tracks in both copies -> every eligible track is a
        # cross-copy duplicate.
        "fixture_two_copies",
        _fixture.name,
        (_fixture, replace(_fixture, persistent_id="PLAYLIST-456")),
    ),
    ("cross_copy_duplicate_prefers_quality", "90s Techno", merge_test_copies()),
    (
        "three_copies",
        "90s Techno",
        merge_test_copies()
        + (
            PlaylistSnapshot(
                "90s Techno",
                "PID-C",
                (track(source_index=0, database_id=5, persistent_id="ONLY-C",
                       title="Sandstorm", artist="Darude", duration_ms=350000),),
            ),
        ),
    ),
    (
        "merge_with_empty_middle_copy",
        "90s Techno",
        (
            merge_test_copies()[0],
            PlaylistSnapshot("90s Techno", "PID-EMPTY", ()),
            merge_test_copies()[1],
        ),
    ),
    (
        "single_empty_copy",
        "Empty",
        (PlaylistSnapshot("Empty", "PID-EMPTY", ()),),
    ),
]


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

def output_tracks_or_none(tracks, winner_source_indexes):
    """Winning track per output position, or None when indexes are ambiguous."""
    indexes = [item.source_index for item in tracks]
    if len(set(indexes)) != len(indexes):
        return None
    by_index = {item.source_index: item for item in tracks}
    return [by_index[i].to_dict() for i in winner_source_indexes]


build_plan_cases = []
for name, source in BUILD_PLAN_SOURCES:
    plan = build_plan(source)
    build_plan_cases.append(
        {
            "name": name,
            "source": source.to_dict(),
            "expected": {
                "source_playlist_name": plan.source_playlist_name,
                "source_playlist_persistent_id": plan.source_playlist_persistent_id,
                "source_track_count": plan.source_track_count,
                "winner_source_indexes": list(plan.winner_source_indexes),
                "decisions": [decision.to_dict() for decision in plan.decisions],
                "non_eligible_source_indexes": list(plan.non_eligible_source_indexes),
                "output_tracks": output_tracks_or_none(
                    source.tracks, plan.winner_source_indexes
                ),
            },
        }
    )

build_merge_plan_cases = []
for name, merged_name, copies in BUILD_MERGE_PLAN_SOURCES:
    plan = build_merge_plan(merged_name, copies)
    combined = combine_source_tracks(copies)
    expected_output = output_tracks_or_none(combined, plan.winner_source_indexes)
    assert expected_output is not None, "combined indexes are always unique"
    build_merge_plan_cases.append(
        {
            "name": name,
            "merged_name": merged_name,
            "copies": [copy.to_dict() for copy in copies],
            "expected": {
                "merged_playlist_source_name": plan.merged_playlist_source_name,
                "winner_source_indexes": list(plan.winner_source_indexes),
                "decisions": [decision.to_dict() for decision in plan.decisions],
                "non_eligible_source_indexes": list(plan.non_eligible_source_indexes),
                "combined_track_count": plan.combined_track_count(),
                "copy_boundaries": list(plan.copy_boundaries()),
                "combined_tracks": [item.to_dict() for item in combined],
                "output_tracks": expected_output,
            },
        }
    )

payload = {
    "build_plan_cases": build_plan_cases,
    "build_merge_plan_cases": build_merge_plan_cases,
}
out_path = OUT_DIR / "plan_golden.json"
out_path.write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
print(
    f"wrote {len(build_plan_cases)} build_plan cases and "
    f"{len(build_merge_plan_cases)} build_merge_plan cases -> {out_path}"
)
