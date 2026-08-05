# MusicConsolidator

A macOS tool that cleans up an Apple Music library that has accumulated
duplicate playlists and duplicate tracks — safely. It merges same-name
playlist copies, consolidates duplicate tracks inside a single playlist, and
retires leftovers through guarded, individually verified operations. Every
write is planned first, reviewed as an on-disk artifact, executed through a
guarded writer, and proven correct by reading the library back.

Two implementations share one behavioral contract:

- **`apple_music_consolidator/`** — the Python reference implementation and
  CLI (stdlib only). It defines the exact matching, planning, and
  verification semantics.
- **`macos-app/`** — the native SwiftUI app (Swift 6, macOS 14+). A faithful
  port of the reference implementation, pinned to it by golden fixtures and
  differential tests, talking to Music.app in-process via OSAKit.

## Why

Syncing services and years of library churn leave real damage: the same
playlist imported three times, hundreds of tracks duplicated inside one
playlist, near-identical names differing by a trailing space. Cleaning that
up by hand is error-prone, and cleaning it up with a script is dangerous —
one wrong delete is someone's playlist gone. This tool treats every write to
the library as a small, reviewable, verifiable transaction.

## Features

- **Merge** — combines same-name playlist copies into one new
  `<Name> — Merged` playlist, deduplicating across copies with a strict
  duplicate key (normalized title + normalized artist + exact rounded
  duration) and a deterministic winner preference. Source playlists are
  never modified.
- **Consolidate** — deduplicates tracks inside a single playlist into a new
  `<Name> — Consolidated` playlist, same strict key, with every omission
  individually accounted for in the plan.
- **Batch runs** — select any number of playlists or merge groups and
  process them unattended; every item still gets its own fresh library
  read, plan, guarded write, and readback verification, and the run always
  ends in a persisted report listing every judgment call made.
- **Guarded delete and rename** — playlist deletion and renaming as
  first-class, individually gated operations: persistent-ID-pinned,
  session-bound single-use plan artifacts, SHA-256 rechecked before
  dispatch, typed-confirmation gates, and a full-library bijective readback
  proving exactly the approved change happened and nothing else.
- **Post-merge cleanup** — discovers completed merges from their plan
  evidence and retires the now-redundant source copies, one guarded
  execution per copy with verification between copies.
- **Failure taxonomy** — a failed operation reports its exact library
  state: refused before write, writer failed, unverifiable, source drifted
  after a verified write, or target mismatch — plus a guarded shortcut to
  remove any leftover it created.
- **Everything leaves a record** — plans (`.plan.json`, `.detail.csv`,
  `.summary.md`), run reports, and mutation results are written to
  `reports/` and never overwritten; the artifacts are the durable history
  of every change ever made.

## The safety model

The engine is fail-closed by construction:

1. **Fresh read first.** Every operation starts by re-reading the live
   library; stale state is refused, never patched.
2. **Plan before write.** The exact intended change is serialized to a
   reviewable artifact with an integrity hash before anything executes.
3. **Guarded write.** The writer revalidates names, counts, and ordered
   persistent IDs inside the same compiled execution, immediately before
   its single mutation verb. An existing target is refused, never reused.
4. **Readback proof.** After the write, the library is read back and
   compared against the plan. Anything unexpected fails the operation with
   verbatim mismatches.
5. **Never repair, never retry.** A failed operation reports and stops.
   Recovery is always a fresh, human-initiated pass.

Text comparison throughout is Unicode-scalar exact — canonically equivalent
lookalikes (NFC/NFD), trailing spaces, and invisible characters are treated
as the distinct values they are.

## The native app

SwiftUI, four destinations: **Library** (browse, select, and start merge /
consolidate / cleanup work), **Activity** (live runs, review and approval
for attended flows, run reports), **Reports** (the artifact history), and
**Settings**. Running the guarded AppleScript in-process makes the app
itself the Apple-events sender, which is what allows unattended batch runs
that a terminal-driven script cannot do.

The test suite (700+ tests) runs fully offline against scripted fakes —
tests never touch a live library. UI structure is enforced by offscreen
rendering tests with geometric containment assertions at multiple window
sizes.

## Requirements

- macOS 14 or later (developed against macOS 26 Tahoe)
- Xcode command line tools with Swift 6
- Music.app with an Apple Music library
- Python 3 for the reference CLI (standard library only)

## Building

```bash
# Full Swift test suite
cd macos-app/ConsolidatorKit && swift test

# Python reference implementation tests
python3 -m unittest discover -v

# Build, assemble, and sign the app bundle
bash macos-app/scripts/build-app.sh
```

The build script signs the bundle with a stable self-signed certificate so
the macOS Automation permission survives rebuilds. First launch requires
granting the app permission to control Music.

## CLI usage (reference implementation)

```bash
# Read-only audit of one playlist; writes the reviewable plan artifacts
python3 scripts/apple_music_consolidate.py audit \
  --playlist "Playlist Name" --output-dir reports

# Apply a reviewed plan (creates the new target; sources untouched)
python3 scripts/apple_music_consolidate.py apply \
  --plan reports/<plan-file>.plan.json \
  --target-name "Playlist Name — Consolidated" --confirm-create

# Same-name merge: merge-audit / merge-apply follow the same pattern
```

## Repository layout

```
apple_music_consolidator/   Python reference implementation (engine)
scripts/                    CLI entry point
macos-app/ConsolidatorKit/  Swift package: core engine, Music bridge, app
macos-app/golden/           Fixtures exported from the reference implementation
macos-app/assets/           App icon generator and assets
reports/                    Plan, run-report, and result artifacts (the record)
docs/                       Design specs, implementation plans, workflow docs
```

`Library*.xml` library exports are local-only evidence and are excluded
from the repository.

## Author

Sergio Farfan
