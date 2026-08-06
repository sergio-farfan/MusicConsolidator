# Music Project Instructions

## Scope

These instructions apply only to `/Users/sergio.farfan/projects/git/MusicConsolidator` and all
files below it. Global user instructions still apply.

## Project purpose

This project audits Apple Music playlists, identifies strict duplicate track
occurrences, selects one deterministic best-quality occurrence, and creates a
separate consolidated playlist. The source playlist is never modified by the
consolidator.

Use `python3`, not `python`.

This directory is a Git repository as of 2026-08-05, initialized at Sergio's
explicit request and pushed to the private remote
https://github.com/sergio-farfan/MusicConsolidator. The `Library*.xml`
evidence files exceed GitHub's file-size limit and stay local-only via
`.gitignore` — never remove that exclusion. Commits are authored solely by
Sergio Farfan; routine work may be committed and pushed, but never force-push
and never rewrite published history.

## Data protection

- Treat `Library.xml`, `Library-BKP.xml`, `Library copy.xml`, and
  `Library copy 2.xml` as read-only evidence.
- Never edit or import `Library.xml` or `Library.musicdb` as a write mechanism.
- Never delete, rename, empty, reorder, or otherwise modify a source playlist.
- Never automatically delete or repair a partial, mismatched, or colliding
  target playlist.
- Never overwrite an existing audit, plan, report, or compiled diagnostic.
  Create a newly named artifact instead.
- A write is allowed only after a fresh audit, exact plan review, and Sergio's
  explicit approval of the named plan.
- AMENDMENT (Sergio, 2026-08-03) — native-app BATCH runs only: per-plan human
  approval is replaced by a one-time batch-launch approval. Every engine guard
  is unchanged (fresh live audit per item, drift refusal, fingerprint check,
  readback verification, never-repair, one apply per audit), and the app must
  present a post-run report surfacing every auto-decided judgment item
  (near-identical pairs kept, distinct-entry omissions, count anomalies) for
  after-the-fact review. Escalation pausing is a settings toggle, default off.
  CLI use and every non-batch path keep the per-plan approval above.
- Every apply must create a separate target. Deletion or final renaming remains
  a manual, separately approved operation.
- AMENDMENT (Sergio, 2026-08-03) — guarded in-app mutations (native app
  only): the rule "Never delete, rename, empty, reorder, or otherwise modify
  a source playlist" is qualified as follows. Delete and rename — and only
  those two operations — are permitted on plain user playlists (never smart
  or special-kind playlists), source playlists included, exclusively through
  the app's guarded mutation flow: a fresh in-app mutation audit producing a
  reviewable `reports/` artifact that is session-bound, single-use, and
  SHA-256-rechecked immediately before execution; a typed confirmation that
  uniquely identifies the pinned persistent ID; a persistent-ID-pinned
  single-mutation writer that revalidates the playlist's exact name, track
  count, and ordered track persistent IDs inside the same compiled execution
  immediately before mutating; and a bijective full-listing readback proving
  exactly the approved change and nothing else. Empty, reorder, and every
  other modification remain forbidden. Mutations never run inside any apply
  or any unattended run. Approval is per playlist, with two exceptions: (1)
  a single typed approval may cover the source copies of one merge group
  after fresh re-verification of the merged target, deleted one mutation per
  compiled execution with readback between each; (2) (Sergio, 2026-08-06) a
  single typed approval — the exact selection COUNT — may cover a
  user-selected batch of playlists in the Cleanup list, each still its own
  fresh-audited plan artifact and its own guarded compiled execution with
  full-listing readback between deletes; contract-excluded and refused
  playlists cannot be selected, and any refusal at arm time refuses the
  whole batch fail-closed. Playlists named
  `#Musica xTotal` or `#Musica xTotal — Consolidated`, and persistent IDs
  `E02030832FD20B07` and `61EC0FC6E0F1C250`, are excluded from every
  mutation, including as rename destinations. The CLI has no delete or
  rename. Everything else in this section is unchanged. Design:
  `docs/superpowers/specs/2026-08-03-queue-tables-and-playlist-management-design.md`.
- AMENDMENT (Sergio, 2026-08-06) — direct user-responsible mutations,
  superseding the guarded in-app mutation flow above: in-app playlist
  delete and rename are DIRECT — a simple confirm dialog, then one
  compiled AppleScript execution pinned by persistent ID. No plan
  artifacts, typed approvals, freshness windows, fingerprint rechecks,
  or readback verification. NO playlist is refused: smart playlists,
  folders, and the pilot identities are all valid targets for delete
  and rename (the pilot CONSOLIDATION PLAN is still never applied
  again). Both prior exceptions to one-approval-per-playlist are moot.
  Unchanged: mutations never run inside any apply or unattended run;
  applies keep every guard; source playlists are never modified by any
  create path; Library*.xml evidence stays read-only.

## Duplicate and quality contract

A track is eligible for duplicate grouping only when title, artist, and duration
are present.

The strict duplicate key is:

1. Normalized title.
2. Normalized artist.
3. Exact rounded duration in milliseconds.

Text normalization uses NFKC, case folding, collapsed whitespace, equivalent
straight/curly quotes, and equivalent dash forms. Accents are preserved.
Do not broaden matching beyond this contract without a fresh design, audit, and
explicit approval.

Winner preference, in order:

1. Available over `no longer available`.
2. Lossless/AIFF/WAV over non-lossless.
3. Higher sample rate.
4. Higher bit rate.
5. Earlier source occurrence.
6. Persistent ID as the final deterministic tie-breaker.

All non-eligible tracks remain unchanged. Consolidation removes duplicate
occurrences from the new playlist; it does not delete songs from the library.

## Required workflow

### Audit

Run from Sergio's normal Terminal:

```bash
python3 scripts/apple_music_consolidate.py audit \
  --playlist '<exact playlist name>' \
  --output-dir reports
```

The audit is read-only and must produce a matching `.plan.json`, `.detail.csv`,
and `.summary.md`. Review all three. The CSV must account for every source
occurrence.

Approval must identify the exact plan filename. Recheck its SHA-256 immediately
before any apply.

### Apply

Use only the copyable command printed by that audit. Keep the exact plan path,
target name, and `--confirm-create`.

Apply must fail closed when:

- the plan is legacy, malformed, non-canonical, or stale;
- the live source name, persistent ID, count, order, identity, metadata,
  availability, or file-track status differs;
- an exact-name target already exists;
- compilation, execution, or readback is ambiguous;
- target count, database IDs, persistent IDs, or order differ.

The generated writer must validate the complete source before target lookup or
creation, perform one guarded create-and-duplicate operation, then verify both
source and target by readback.

### Existing-target collision

If apply reports `target user playlist already exists`:

1. Stop. Do not retry, rename, or delete anything.
2. Read the exact-name target count and persistent ID.
3. Compare the complete target against the approved winner sequence using both
   database ID and persistent ID in order.
4. Treat count-only or visual inspection as useful evidence, not proof.
5. Reuse an already complete target; do not create another copy.

Any apply error can leave a partial target. Always inspect it read-only.

## Same-name playlist merge

Some source playlists share an exact name. The merge workflow creates one new
`<Name> — Merged` playlist per same-name group, containing the union of the
copies' tracks with strict duplicates removed. It never renames, empties, or
modifies any source copy. Deleting the originals remains a manual, separately
approved operation.

The merge reuses the duplicate and quality contract above unchanged. Copies are
concatenated in ascending Apple Music playlist-ID order, then the same strict
key and winner preference deduplicate the combined list. A higher-quality
occurrence in a later copy still wins and is placed at its group's earliest
position. Do not broaden this beyond the existing contract without a fresh
design, audit, and explicit approval.

### Audit

```bash
python3 scripts/apple_music_consolidate.py merge-audit \
  --name '<exact playlist name>' --output-dir reports
```

The read-only audit reads every same-name copy live (never `Library.xml`) and
produces a matching `.plan.json`, `.detail.csv`, and `.summary.md`. The CSV has
one row per source occurrence across all copies with copy-ordinal /
copy-persistent-ID / within-copy provenance columns. Approval must identify the
exact plan filename.

### Apply

Use only the copyable command the audit prints. Keep the exact plan path,
`<Name> — Merged` target, and `--confirm-create`.

```bash
python3 scripts/apple_music_consolidate.py merge-apply \
  --plan '<printed plan path>' --target-name '<Name> — Merged' --confirm-create
```

Apply fails closed when the plan is legacy, malformed, non-canonical, stale, or
fingerprint-mismatched; when the live same-name copy set differs from the plan
(extra copy, missing copy, or a changed persistent ID); when any copy's count,
order, identity, metadata, availability, or file-track status differs; or when
an exact-name `<Name> — Merged` target already exists. The generated writer
looks up all same-name copies live, matches each expected copy by persistent ID
(never by name or position), revalidates every track of every copy before any
mutation, performs one guarded create-and-duplicate into the new playlist, then
verifies both every source copy (unchanged) and the target (ordered database IDs
and persistent IDs) by readback. A partial target is inspected read-only and
never deleted, renamed, or repaired.

The `merge_fingerprint` covers every copy's name, persistent ID, and ordered
tracks, so any drift in any copy invalidates the plan. The same macOS execution
boundary applies: Sergio runs the live `merge-audit` and `merge-apply` commands
from his normal Terminal.

### Merge pilot and rollout

Pilot `Trance 2022` (9 vs 10 tracks) end to end before any batch. Three-copy
groups (`SGI Artists`, `Soka Varios`) work unchanged. `#Musica xTotal` is a
special case — it already has a single-copy `#Musica xTotal — Consolidated`
artifact from the completed consolidator pilot, so merging its two copies is a
distinct, separately reviewed operation and must stay out of routine waves.

Design and plan: `docs/superpowers/specs/2026-07-31-playlist-merge-design.md`,
`docs/superpowers/plans/2026-07-31-playlist-merge.md`.

## macOS execution boundary

The Codex automation command runner is not attached to Sergio's logged-in macOS
GUI/Automation session. Direct Music queries from that runner can fail with:

```text
com.apple.hiservices-xpcservice: Connection invalid
Parameter is missing. (-1701)
```

Additional filesystem privilege or Sergio's conversational authorization does
not attach the runner to the GUI session or change the sending process's TCC
identity.

Therefore:

- Codex may generate, compile, decompile, hash, statically inspect, and offline
  test scripts.
- Codex may attempt one safe read-only query to establish whether the boundary
  still exists.
- After the confirmed `hiservices`/`-1701` failure, do not keep retrying.
- Sergio must execute live Music `audit`, preflight, verifier, and `apply`
  commands from his normal Terminal.
- Always ask Sergio to paste complete stdout and stderr.

A future native macOS app needs a stable signed identity, Apple Events
authorization, an `NSAppleEventsUsageDescription`, and the appropriate
Automation entitlement when applicable.

Authoritative references:

- Installed Music dictionary:
  `/System/Applications/Music.app/Contents/Resources/com.apple.Music.sdef`
- `man osascript` and `man osacompile` for the installed command behavior.
- Apple Events entitlement:
  <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events>
- Apple protected-resource/TCC guidance:
  <https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos>

## AppleScript and JXA implementation rules

- Target Music by absolute path: `/System/Applications/Music.app`.
- Escape every untrusted value embedded in JXA or AppleScript.
- Compile generated AppleScript before execution and execute the exact compiled
  artifact that passed the compiler gate.
- Keep large expected source data in a compact delimiter-encoded payload. Do
  not unroll one guard block per track.
- Declare writer runtime state explicitly `local` to prevent compiled-script
  save-back and internal-table overflow.
- Inside an application `tell`, use `my` for handlers defined on the script.
  Do not use `my` to read an explicit run-local variable.
- Compare playlist and track text by Unicode code-point lists (`id of text`),
  not AppleScript collation.
- Compare Music `cloud status` directly with the installed raw enum constants;
  do not coerce the enum to display text.
- Keep missing cloud status distinct from the `unknown` enum.
- Determine file-track status per track using its class. Do not project
  `database ID of every file track` from an empty subtype collection.
- Store `contents of` repeat variables before retaining playlist references.
- A read-only diagnostic must be inspected before execution and contain no
  create, make, duplicate, delete, move, remove, rename, write, empty, or
  property-assignment operation.

AppleScript references:

- Variable scope:
  <https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/conceptual/ASLR_variables.html>
- Handlers inside `tell`:
  <https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/conceptual/ASLR_about_handlers.html>
- Raw constants:
  <https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/conceptual/ASLR_raw_data.html>

## Testing and verification

For any production-code change:

1. Add a focused regression first.
2. Observe the expected RED failure.
3. Make the smallest production change.
4. Observe focused GREEN.
5. Run the complete suite and byte compilation.

Required commands:

```bash
python3 -m unittest discover -v
python3 -m compileall -q apple_music_consolidator scripts tests
```

Tests must never invoke or mutate live Music. Use compiled offline probes and
controlled in-memory bridges. Preserve the 1,600-track compiler and
compiled-state/hash regression.

Before handing off any compiled live diagnostic:

- bind it to the exact approved plan and expected target when applicable;
- compile and decompile it;
- verify plan and artifact hashes;
- confirm expected counts and all guarded fields;
- exercise comparison behavior offline with controlled exact and mismatch
  cases;
- obtain a read-only review;
- provide one short command for Sergio's normal Terminal.

## Verified pilot state — 2026-07-30

The `#Musica xTotal` pilot is complete. Do not apply it again.

- Approved plan:
  `reports/Musica-xTotal-20260730-114426-0600.plan.json`
- Approved plan SHA-256:
  `44d50901bbca997ff22f5c24866888129c8fb9bc615272ef6427a0a5c231851d`
- Source playlist: `#Musica xTotal`
- Source persistent ID: `E02030832FD20B07`
- Verified source count: 1,539
- Consolidated target: `#Musica xTotal — Consolidated`
- Target persistent ID: `61EC0FC6E0F1C250`
- Verified target count: 1,397
- Omitted duplicate occurrences: 142
- Exact target verification: all database IDs and persistent IDs match in
  approved order; zero mismatches.
- Sergio accepted the 48 historical songs absent from the live source. The
  pilot intentionally did not recover them.

Plan-specific preflight versions before v5 are obsolete and must not be run.
The v5 and target-verifier artifacts are retained as audit evidence, not as
templates for another playlist. Generate fresh plan-bound artifacts for every
new playlist.

Detailed history:

`docs/superpowers/sdd/2026-07-30-apple-music-native-consolidator/progress.md`

## Documentation and authorship

- Keep durable workflow changes synchronized with
  `docs/apple-music-consolidator.md`.
- Preserve report artifacts for auditability.
- Sergio Farfan is the sole author. Never add Codex or AI co-author credit.
