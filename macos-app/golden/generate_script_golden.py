#!/usr/bin/env python3
"""Export script-TEXT golden fixtures from the Python reference implementation
(music_bridge.build_read_jxa / build_apply_script / build_merge_apply_script)
for the Swift M4 byte-parity gate.

Run from the project root so `apple_music_consolidator` is importable:

    python3 macos-app/golden/generate_script_golden.py

Writes macos-app/golden/script_golden.json. Byte-reproducible: every input is
a static literal (or the checked-in tests/fixtures/music_snapshot.json) and
the generated scripts are pure functions of them (no clocks, no randomness).

Schema:
    {
      "read_jxa_cases": [
        {"name", "playlist_name", "script": build_read_jxa(playlist_name)}
      ],
      "apply_cases": [
        {"name", "source": <PlaylistSnapshot.to_dict()>, "target_name",
         "script": build_apply_script(build_plan(source), source, target_name)}
      ],
      "merge_apply_cases": [
        {"name", "merged_name", "copies": [<PlaylistSnapshot.to_dict()>],
         "target_name",
         "script": build_merge_apply_script(
             build_merge_plan(merged_name, copies), copies, target_name)}
      ]
    }

The Swift golden test rebuilds each plan with the Swift resolver from the
same source snapshot and compares the generated script text UTF-8
byte-for-byte against "script". Winner-index parity between the resolvers is
already pinned by plan_golden.json (M2); any residual divergence surfaces
here as a byte diff with a diagnosable offset.

Invisible/hostile characters below are constructed with chr() so the source
stays reviewable, printable ASCII plus visible unicode only.

Housekeeping: running any generator in this directory may create a disposable
__pycache__/ next to it (Python bytecode cache). It carries no fixture data,
is never read by the Swift tests, and can be deleted at any time.

Hostile-string constraints (reference-faithful): _apple_script_string is
json.dumps, and AppleScript string literals only understand the escapes
backslash-n/r/t/quote/backslash - so apply/merge inputs restrict control
characters to newline/tab/CR (anything else would fail the reference's own
osacompile gate too). The read JXA is JavaScript, where every json.dumps
escape is legal, so the read cases also cover backspace, form feed, U+0001,
U+2028/U+2029, and DEL.
"""

import json
import sys
from dataclasses import replace
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = OUT_DIR.parents[1]  # macos-app/golden -> macos-app -> project root
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from apple_music_consolidator.models import PlaylistSnapshot  # noqa: E402
from apple_music_consolidator.music_bridge import (  # noqa: E402
    build_apply_script,
    build_merge_apply_script,
    build_read_jxa,
    parse_exact_playlist_snapshot,
)
from apple_music_consolidator.resolver import build_merge_plan, build_plan  # noqa: E402
from tests.helpers import track  # noqa: E402

# Invisible characters, kept out of the source text on purpose.
NEWLINE = chr(0x0A)
TAB = chr(0x09)
CR = chr(0x0D)
BACKSPACE = chr(0x08)
FORM_FEED = chr(0x0C)
CTRL_ONE = chr(0x01)
DEL = chr(0x7F)
ZWSP = chr(0x200B)
NBSP = chr(0x00A0)
LINE_SEP = chr(0x2028)
PARA_SEP = chr(0x2029)
PUA_E000 = chr(0xE000)
PUA_E001 = chr(0xE001)
PUA_E002 = chr(0xE002)
PUA_E003 = chr(0xE003)
PUA_F8FF = chr(0xF8FF)  # Apple logo private-use character


def fixture_playlist() -> PlaylistSnapshot:
    raw = (PROJECT_ROOT / "tests" / "fixtures" / "music_snapshot.json").read_text(
        encoding="utf-8"
    )
    return parse_exact_playlist_snapshot(raw, "#Musica xTotal")


# ---------------------------------------------------------------------------
# read JXA names
# ---------------------------------------------------------------------------

READ_JXA_NAMES: list[tuple[str, str]] = [
    ("fixture_name", "#Musica xTotal"),
    # tests/test_music_bridge.py::test_read_jxa_json_encodes_untrusted_playlist_name
    (
        "hostile_injection",
        'Source";' + "\\" + NEWLINE + 'throw new Error("injected")',
    ),
    # em dash, Cherokee, dotted capital I, ZWSP, NBSP, precomposed e-acute
    ("unicode_name", "Trance — 2022 ᏣᎳᎩ İstanbul" + ZWSP + NBSP + "é"),
    # JS-legal escapes beyond AppleScript's set, plus raw JS line separators.
    (
        "pua_and_controls",
        PUA_E000 + " List " + PUA_F8FF + " "
        + BACKSPACE + FORM_FEED + CTRL_ONE + LINE_SEP + PARA_SEP + DEL,
    ),
    ("empty_name", ""),
]


# ---------------------------------------------------------------------------
# apply sources
# ---------------------------------------------------------------------------

def guard_source() -> PlaylistSnapshot:
    """tests/test_music_bridge.py::WriterBoundaryTests._guard_source."""
    return PlaylistSnapshot(
        'Source "Exact"',
        "PLAYLIST",
        (
            track(
                source_index=0,
                database_id=101,
                persistent_id="OMITTED-A",
                title='Same "Song"',
                artist="Artist A",
                album="Old Album",
                duration_ms=181001,
                kind="Apple Music AAC audio file",
                bit_rate_kbps=128,
                sample_rate_hz=44100,
                cloud_status="no longer available",
                is_file_track=False,
            ),
            track(
                source_index=1,
                database_id=202,
                persistent_id="WINNER-B",
                title='Same "Song"',
                artist="Artist A",
                album="Master Album",
                duration_ms=181001,
                kind="AIFF audio file",
                bit_rate_kbps=1411,
                sample_rate_hz=96000,
                cloud_status="matched",
                is_file_track=True,
            ),
            track(
                source_index=2,
                database_id=303,
                persistent_id="UNIQUE-C",
                title="Unique Song",
                artist="Artist C",
                album="Album C",
                duration_ms=None,
                kind="MPEG audio file",
                bit_rate_kbps=None,
                sample_rate_hz=None,
                cloud_status="uploaded",
                is_file_track=True,
            ),
        ),
    )


def hostile_playlist() -> PlaylistSnapshot:
    """AppleScript-meaningful sequences kept inert as data (quote, backslash,
    ampersand, not-sign, guillemets), newline/tab/CR, unicode
    (Cherokee/dotted-I/ZWSP/NBSP/emoji), empty strings."""
    return PlaylistSnapshot(
        'Hostile "Play' + "\\" + 'list" — ¬ «name»' + TAB + "with" + NEWLINE + "newline",
        'PID "H" ' + "\\" + " ¬",
        (
            track(
                source_index=0,
                database_id=1,
                persistent_id='P-"QUOTE"',
                title='Same "Song" ' + "\\" + " with ¬ and «guillemets» & concat",
                artist="Artist 'single' \"double\"",
                album="Album" + "\\" + "Back" + "\\" + "slash",
                duration_ms=181001,
                kind='Kind "quoted" file',
                bit_rate_kbps=128,
                sample_rate_hz=44100,
                cloud_status="matched",
                is_file_track=False,
            ),
            track(
                source_index=1,
                database_id=2,
                persistent_id="P-DUP",
                title='Same "Song" ' + "\\" + " with ¬ and «guillemets» & concat",
                artist="Artist 'single' \"double\"",
                album="Album «master» 🎵",
                duration_ms=181001,
                kind="AIFF audio file",
                bit_rate_kbps=1411,
                sample_rate_hz=96000,
                cloud_status="uploaded",
                is_file_track=True,
            ),
            track(
                source_index=2,
                database_id=3,
                persistent_id="P-CTRL",
                title="Line" + NEWLINE + "Break" + TAB + "Tab" + CR + "CR",
                artist="İstanbul ᏣᎳᎩ",
                album="ZWSP" + ZWSP + "NBSP" + NBSP + "end",
                duration_ms=200002,
                cloud_status="no longer available",
            ),
            track(
                source_index=3,
                database_id=4,
                persistent_id="P-EMPTY",
                title="",
                artist="",
                album="",
                duration_ms=None,
                kind="",
                bit_rate_kbps=None,
                sample_rate_hz=None,
                cloud_status="",
            ),
        ),
    )


def pua_playlist() -> PlaylistSnapshot:
    """The PUA delimiter characters themselves appear in track data, forcing
    the payload encoder to scan past them (expects U+E002/U+E004)."""
    return PlaylistSnapshot(
        "PUA " + PUA_E000 + PUA_E001 + PUA_E002 + " Source",
        "PID-PUA",
        (
            track(
                source_index=0,
                database_id=1,
                persistent_id="PUA-A",
                title="Title " + PUA_E000 + " uses first candidate",
                artist="Artist " + PUA_E001 + " uses second",
                album="Album " + PUA_E003 + PUA_F8FF,
            ),
            track(
                source_index=1,
                database_id=2,
                persistent_id="PUA-B",
                title="Plain Title",
            ),
        ),
    )


def large_playlist() -> PlaylistSnapshot:
    """tests/test_music_bridge.py::test_generated_apply_script_compiles_for_large_playlist."""
    return PlaylistSnapshot(
        "Source",
        "P",
        tuple(
            track(
                source_index=index,
                database_id=index + 1,
                persistent_id=f"P{index:08d}",
                title=f"Song {index:04d}",
                duration_ms=180000 + index,
            )
            for index in range(1600)
        ),
    )


APPLY_SOURCES: list[tuple[str, PlaylistSnapshot, str]] = [
    ("fixture_musica_xtotal", fixture_playlist(), "#Musica xTotal — Consolidated"),
    ("guarded_three_track", guard_source(), 'Target "Safe"'),
    # tests/test_music_bridge.py::test_apply_script_rejects_target_name_script_injection
    (
        "hostile_strings",
        hostile_playlist(),
        'Target"' + NEWLINE + 'error "injected — ¬ «»',
    ),
    ("pua_delimiters_in_data", pua_playlist(), "PUA Target"),
    ("empty_playlist", PlaylistSnapshot("Empty", "PLAYLIST-EMPTY", ()), "Empty — Consolidated"),
    ("large_1600", large_playlist(), "Target"),
]


# ---------------------------------------------------------------------------
# merge sources
# ---------------------------------------------------------------------------

def merge_test_copies() -> tuple[PlaylistSnapshot, ...]:
    """tests/test_resolver.py::MergeResolverTests._copies (as in plan goldens)."""
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


def hostile_merge_copies() -> tuple[PlaylistSnapshot, ...]:
    name = 'Merge "Hostile" — ¬ «copies»'
    hostile_title = 'Cross "Copy" ' + "\\" + " Dup ¬ «x» & y"
    copy_a = PlaylistSnapshot(
        name,
        'PID-A "1" ' + "\\",
        (
            track(source_index=0, database_id=1, persistent_id="H-LOSSY",
                  title=hostile_title,
                  artist="Artist" + TAB + "Tabbed", duration_ms=280000,
                  sample_rate_hz=44100),
            track(source_index=1, database_id=2, persistent_id="H-ONLY-A",
                  title="Only In" + NEWLINE + "Copy A", artist="ᏣᎳᎩ İ",
                  duration_ms=430000),
        ),
    )
    copy_b = PlaylistSnapshot(
        name,
        "PID-B " + PUA_E000 + PUA_E001,
        (
            track(source_index=0, database_id=3, persistent_id="H-LOSSLESS",
                  title=hostile_title,
                  artist="Artist" + TAB + "Tabbed", duration_ms=280000,
                  kind="AIFF audio file", sample_rate_hz=96000,
                  album="PUA " + PUA_E000 + " data"),
        ),
    )
    return (copy_a, copy_b)


def large_merge_copies() -> tuple[PlaylistSnapshot, ...]:
    """tests/test_music_bridge.py::test_merge_writer_compiles_for_large_multi_copy_input."""
    copy_a = PlaylistSnapshot(
        "Big", "PID-A",
        tuple(track(source_index=i, database_id=i + 1, persistent_id=f"A{i:08d}",
                    title=f"Song {i:04d}", duration_ms=180000 + i)
              for i in range(900)),
    )
    copy_b = PlaylistSnapshot(
        "Big", "PID-B",
        tuple(track(source_index=i, database_id=10000 + i, persistent_id=f"B{i:08d}",
                    title=f"Other {i:04d}", duration_ms=240000 + i)
              for i in range(900)),
    )
    return (copy_a, copy_b)


_fixture = fixture_playlist()

MERGE_SOURCES: list[tuple[str, str, tuple[PlaylistSnapshot, ...], str]] = [
    (
        "fixture_two_copies",
        _fixture.name,
        (_fixture, replace(_fixture, persistent_id="PLAYLIST-456")),
        "#Musica xTotal — Merged",
    ),
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
        "90s Techno — Merged",
    ),
    (
        "hostile_merge",
        'Merge "Hostile" — ¬ «copies»',
        hostile_merge_copies(),
        'Merged"' + NEWLINE + 'error "injected',
    ),
    ("large_two_copies_900", "Big", large_merge_copies(), "Big — Merged"),
]


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

read_jxa_cases = [
    {"name": name, "playlist_name": playlist_name, "script": build_read_jxa(playlist_name)}
    for name, playlist_name in READ_JXA_NAMES
]

apply_cases = []
for name, source, target_name in APPLY_SOURCES:
    plan = build_plan(source)
    apply_cases.append(
        {
            "name": name,
            "source": source.to_dict(),
            "target_name": target_name,
            "script": build_apply_script(plan, source, target_name),
        }
    )

merge_apply_cases = []
for name, merged_name, copies, target_name in MERGE_SOURCES:
    plan = build_merge_plan(merged_name, copies)
    merge_apply_cases.append(
        {
            "name": name,
            "merged_name": merged_name,
            "copies": [copy.to_dict() for copy in copies],
            "target_name": target_name,
            "script": build_merge_apply_script(plan, copies, target_name),
        }
    )

payload = {
    "read_jxa_cases": read_jxa_cases,
    "apply_cases": apply_cases,
    "merge_apply_cases": merge_apply_cases,
}
out_path = OUT_DIR / "script_golden.json"
out_path.write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
print(
    f"wrote {len(read_jxa_cases)} read_jxa cases, {len(apply_cases)} apply cases, "
    f"{len(merge_apply_cases)} merge_apply cases -> {out_path}"
)
