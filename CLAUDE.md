# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read AGENTS.md first

`AGENTS.md` is the authoritative operating contract for this project and must be
followed exactly. Non-negotiables it defines in full:

- This directory is a **Git repository** (since 2026-08-05, at Sergio's
  request; private remote `sergio-farfan/MusicConsolidator`). `Library*.xml`
  evidence stays local-only via `.gitignore`. Sergio Farfan is the sole
  commit author; no force-pushes or history rewrites.
- `Library.xml` and its copies at the repo root are read-only evidence. Source
  playlists are never modified; every apply creates a separate new target.
- Writes require a fresh audit, review of the named `.plan.json`, a SHA-256
  recheck, and Sergio's explicit approval of that exact plan filename.
- The strict duplicate key (normalized title + normalized artist + exact
  rounded duration) and the winner-preference order are a fixed contract — do
  not broaden matching without a fresh design and approval.
- Live Music commands (`audit`, preflight, `apply`) must be run by Sergio in
  his normal Terminal. The automation runner is outside the macOS GUI/TCC
  session and fails with `hiservices` / `-1701`; after one confirmed failure,
  stop retrying and hand Sergio the command instead.
- The `#Musica xTotal` pilot is complete and must not be applied again.

Use `python3`, never `python`.

## Commands

```bash
# Full test suite (required before claiming any change works)
python3 -m unittest discover -v

# Single test module / case / method
python3 -m unittest tests.test_resolver -v
python3 -m unittest tests.test_music_bridge.TestClassName.test_method -v

# Byte-compilation gate (required alongside the suite)
python3 -m compileall -q apple_music_consolidator scripts tests

# Read-only audit (Sergio runs this in his Terminal, not the agent)
python3 scripts/apple_music_consolidate.py audit \
  --playlist '<exact playlist name>' --output-dir reports
```

There is no packaging, linter, or dependency file — stdlib-only Python. The
`scripts/apple_music_consolidate.py` entry point inserts the repo root into
`sys.path`; run everything from the project root.

Development is strict TDD (see AGENTS.md "Testing and verification"): focused
regression first, observe RED, smallest change, GREEN, then full suite +
compileall. Tests must never touch live Music — use the in-memory bridge
fakes in `tests/helpers.py` and `tests/fixtures/music_snapshot.json`.

## Architecture

`apple_music_consolidator/` is a small pipeline of pure, offline-testable
modules; all live Music access is isolated behind one bridge:

- `models.py` — immutable dataclasses (`TrackSnapshot`, plans, `ApplyResult`)
  exchanged between every stage.
- `music_bridge.py` — the **only** module that talks to Music. Reads playlist
  snapshots via `osascript`, and generates + compiles the guarded AppleScript
  writer for apply. Injectable `SubprocessRunner` is what tests replace to stay
  offline. This is also where the fail-closed apply guards live (stale-plan
  rejection, source revalidation, existing-target refusal, readback
  verification of database IDs and persistent IDs in order).
- `normalize.py` — strict text/duration normalization for the duplicate key
  (NFKC, casefold, whitespace/quote/dash equivalence; accents preserved).
- `resolver.py` — deterministic duplicate grouping and winner selection;
  produces the canonical plan including its integrity hash.
- `audit.py` — writes the reviewable artifact triple (`.plan.json`,
  `.detail.csv`, `.summary.md`) into `reports/` and loads/validates plans for
  apply. Never overwrite existing artifacts; new runs create newly named files.
- `cli.py` — `audit`/`apply` (single-playlist consolidation) and
  `merge-audit`/`merge-apply` (same-name playlist merge) subcommands wiring the
  above together; both apply commands require `--plan`, `--target-name`, and
  `--confirm-create`.

The same-name merge path (`merge-audit`/`merge-apply`, `MergePlan`,
`build_merge_plan`, `build_merge_apply_script`) is additive and reuses the
unchanged strict key and winner preference: it concatenates same-name copies in
playlist-ID order and runs the same `build_plan` dedup over the combined list,
with an N-copy guarded writer that distinguishes copies by persistent ID. See
`docs/apple-music-consolidator.md` and the "Same-name playlist merge" section of
`AGENTS.md`.

Data flow: `cli` → `music_bridge` (read-only snapshot) → `normalize` →
`resolver` (plan) → `audit` (artifacts). Apply is the reverse: `audit.load_plan`
→ `music_bridge` guarded writer → readback verification of source and target.

AppleScript/JXA generation has its own detailed correctness rules (escaping,
compile-before-execute, code-point comparison, raw enum constants, `local`
declarations) — see the "AppleScript and JXA implementation rules" section of
AGENTS.md before touching `music_bridge.py` script templates.

Durable workflow changes must stay synchronized with
`docs/apple-music-consolidator.md`. Sergio Farfan is the sole author on all
artifacts.
