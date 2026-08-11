# Apple Music Playlist Consolidator Pilot

This pilot creates a separate consolidated playlist from an audited Apple Music
playlist. It never renames, empties, or modifies the source playlist.

Sergio accepted the 48 historical songs that are absent from the live source.
The pilot does not add recovery behavior for them.

## Superseded plan

`Musica-xTotal-20260730-102319-0600.plan.json` is superseded by the
plan-integrity schema change and must not be applied. The new schema records the
complete ordered source snapshot and curly-double-quote normalization has also
changed. A fresh read-only audit is therefore mandatory; its counts are the only
counts to use for the pilot.

## Fresh audit and exact handoff

```bash
# 1. Safe dry-run only
python3 scripts/apple_music_consolidate.py audit --playlist '#Musica xTotal' --output-dir reports
```

The audit prints all three exact artifact paths, the expected input/output
counts, and a directly copyable `apply` command. Review the newly printed
`.summary.md`, the one-row-per-source-occurrence `.detail.csv`, and its matching
`.plan.json`. Use only the exact plan path and command printed by that fresh
audit; do not substitute the superseded path or a placeholder.

After Sergio explicitly approves that named fresh plan, copy the printed command
without changing its `--plan`, separate `--target-name`, or
`--confirm-create` arguments.

The apply operation rejects legacy, malformed, non-canonical, or stale plans. It
refuses an existing exact-name target. Immediately before creation, its guarded
writer validates every source occurrence in order, including all identity,
metadata, availability, and file-track fields. Before Music can execute it, the
exact generated writer is compiled in a private temporary directory and that
same compiled script is passed to `osascript`. After the writer returns, the
utility reads both playlists again and requires the source to remain unchanged
and the new playlist's ordered database IDs and persistent IDs to match the
plan.

Any apply error may leave a partial target. The utility never deletes or changes
that target during error handling. Retain both playlists for inspection, along
with the audit artifacts. If Sergio later chooses to remove only the new
playlist, do so manually in Music. Apple confirms that
[deleting a playlist removes the playlist, not its songs from the library](https://support.apple.com/guide/music/create-edit-and-delete-playlists-musd5d051981/mac).

Verified success prints the source/target verification statement and then
requires a manual Music inspection of unavailable-item flags and several
quality decisions. Do not delete either playlist or start batch consolidation
until Sergio explicitly approves the pilot.

## Same-name playlist merge

The library contains groups of user playlists that share an exact name. The
merge workflow creates one new `<Name> — Merged` playlist per group, containing
the union of the copies' tracks with strict duplicates removed. It never
renames, empties, or modifies any source copy; deleting the originals stays a
manual, separately approved step.

The merge reuses the consolidator's audited logic unchanged: the strict
duplicate key (normalized title + normalized artist + exact rounded duration)
and the winner preference (available → lossless → sample rate → bit rate →
earlier position → persistent ID). Copies are concatenated in ascending Apple
Music playlist-ID order (creation order), then deduplicated over the combined
list. Alternate album versions of a song (different persistent IDs, usually
different durations) are both kept — only true duplicates collapse. A
higher-quality occurrence in a later copy wins on quality and is duplicated
into the earliest position of its group.

### Fresh audit and exact handoff

```bash
# Safe dry-run only — reads every same-name copy live; never touches Music.
python3 scripts/apple_music_consolidate.py merge-audit \
  --name '<exact playlist name>' --output-dir reports
```

The audit prints the three artifact paths, the copy count, the combined input
count, the output count, and a directly copyable `merge-apply` command whose
`--target-name` is `<Name> — Merged`. Review the `.summary.md` (per-copy counts
and duplicate decisions), the `.detail.csv` (one row per source occurrence
across all copies, with copy-ordinal / copy-persistent-ID / within-copy
provenance columns), and the matching `.plan.json`.

After Sergio explicitly approves the named fresh plan, copy the printed command
without changing its `--plan`, `--target-name`, or `--confirm-create`.

```bash
python3 scripts/apple_music_consolidate.py merge-apply \
  --plan '<printed plan path>' --target-name '<Name> — Merged' --confirm-create
```

`merge-apply` fails closed: it rejects a non-canonical, stale, or
fingerprint-mismatched plan; re-reads every copy live and refuses any drift in
count, identity, order, metadata, availability, file-track status, or the
same-name copy set (extra or missing copy, changed persistent ID); refuses an
existing `<Name> — Merged` target; performs one guarded create-and-duplicate;
then verifies that every source copy is unchanged and the new playlist's ordered
database IDs and persistent IDs match the plan. Any apply error may leave a
partial target — the utility inspects it read-only and never deletes, renames,
or repairs it. If Sergio later chooses to remove a source copy, he does so
manually in Music.

### Pilot and rollout

Pilot one small different-membership group first — `Trance 2022` (9 vs 10) —
end to end (audit → review the named plan/CSV → `merge-apply --confirm-create`
→ verify → manual inspection in Music). Only after that pilot is accepted do the
remaining same-name groups proceed in reviewed batches. Three-copy groups
(`SGI Artists`, `Soka Varios`) work unchanged. `#Musica xTotal` is a special
case: it already has a single-copy `#Musica xTotal — Consolidated` artifact from
the earlier pilot, so merging its two copies is a distinct, separately reviewed
operation — keep it out of routine waves.

### Free-form merge (AGENTS.md amendment, 2026-08-06)

The native app can also merge ANY user-selected set of playlists, with no
same-name requirement. On the Merge tab, check any mix of same-name groups and
SINGLETONS — a checked group contributes all its copies, a checked singleton
contributes itself — and the footer's second action, `Merge selected as one…`,
enqueues ONE item for the whole selection; the footer's `Queued: N playlists`
count counts checked groups plus checked singletons, and the button enables at
two or more source playlists. `Start Queue` keeps its own meaning (one merge per
checked group). The tab's caption states both paths:
“Check same-name groups and Start Queue to merge one group at a time, or
check any mix of groups and singletons and use ‘Merge selected as one…’
to combine them into a single new playlist.” A near match is still not a
same-name group — rename its variants in Music to merge them as a group, or
check them individually as singletons.

The target name is automatic — `<first source> — Merged`, where "first" is the
first source in ascending Apple Music playlist-ID order (the same copy order
same-name merges use), so there is no naming sheet: the queue row shows the
computed name immediately. The new playlist's `description` is set inside the
same guarded writer execution that creates it, to exactly
`Merged on <YYYY-MM-DD HH:MM> from: <source names, comma-separated, in
playlist-ID order>`, and the readback verifies it. Sources are never modified;
the description is written to the NEW playlist only.

Every guard is unchanged: the copy set is pinned by PERSISTENT ID instead of by
a shared name, so revalidation re-reads each pinned ID and refuses if any is
missing, renamed, or drifted in count, order, identity, metadata, availability,
or file-track status; the plan's integrity hash covers the new fields (source
IDs, source names, description); an existing playlist with the computed target
name refuses the item up front with the standard already-done advisory; and the
apply is the same one guarded create-and-duplicate followed by readback of every
source (unchanged) plus the target's name, description, and ordered database and
persistent IDs. Dedup is the UNCHANGED strict key and winner preference over the
concatenated copies. The artifact triple is the standard one, and the
`.summary.md` for a free-form plan names every source playlist beside its
persistent ID and lists the exact `Target description:` the writer will set.
Cleanup's merge-group discovery SKIPS free-form plans: its model is "a group of
same-name copies", which a free-form plan is not, so source cleanup after a
free-form merge stays manual. Free-form merge is app-only — the CLI keeps
same-name `merge-audit` / `merge-apply`.

First live run (checklist): pick TWO SMALL unrelated singletons, check both,
click `Merge selected as one…`, review the named plan artifacts, then apply. In
Music, verify the new playlist's NAME is `<first source> — Merged` and its
DESCRIPTION reads `Merged on <timestamp> from: <both names>`; verify both source
playlists are untouched (same names, same track counts); and verify the
`reports/` triple plus the run report exist, with the `.summary.md` listing both
source names and the description text.

## Native app batch mode (AGENTS.md amendment, 2026-08-03)

The native macOS app runs batch consolidations and merges FULLY UNATTENDED:
one launch approval starts the queue, and each item runs a fresh live audit,
loads its own persisted plan artifact through the fail-closed loaders, and
performs one guarded, readback-verified apply — every engine guard above is
unchanged. Item failures fail closed and the run continues. The run ends in a
MANDATORY post-run report (persisted as a never-overwritten
`Run-….runreport.md` artifact next to the plan files and shown in the app's
history browser) that surfaces every auto-decided judgment item —
near-identical pairs kept, distinct-entry omissions, count anomalies — for
after-the-fact review. Two app settings govern the behavior, both default
off: "Confirm each apply" restores the per-item review + typed-name gate, and
"Pause on judgment items" holds flagged items for review mid-run. The app's
listing cache serves the source browser only; audits and applies always
re-read Music live. This amendment covers app batch runs only — CLI use and
every non-batch path keep the per-plan approval workflow above.

### Queue tables, multi-selection, and track counts (2026-08-03)

The app's queue surfaces — the browser queue rail and the unattended run
screen — render one shared two-column Playlist | Status table with
color-coded status chips (pending / auditing / awaiting review / applying
step k of 7 / applied / skipped / failed); the apply progress list is a
three-column Step | Status | Elapsed table that shows all seven guarded
steps up front. The source browser supports shift-click range selection
plus Cmd+A / Cmd+D, scoped per tab (the Merge tab selects mergeable groups
only; the Consolidate tab selects every checkable row). Every surface that
names a playlist shows its track count in one shared wording: "551 tracks"
for a single playlist, per-copy counts joined with " + " for merge groups
("9 + 10 tracks"). Run surfaces show the freshest audit-derived count when
one exists, otherwise the scan-time listing count; browser rows keep the
scan-time count until the next rescan. History entries show input/output
counts strictly decoded from their `.plan.json` artifacts through the same
fail-closed loaders the apply uses — a file those loaders reject simply
shows no counts. Counts are display-only everywhere and never feed a guard.

## Direct delete and rename (AGENTS.md amendment, 2026-08-06)

The native app's playlist delete and rename are direct, user-responsible
actions — Music.app parity — superseding the guarded in-app mutation flow
(AGENTS.md amendment, 2026-08-03) and both of its named exceptions to
one-approval-per-playlist. Delete and rename remain ATTENDED ONLY: they
never run inside an unattended queue, never inside any apply, and both
are disabled while a scan, audit, apply, or unattended run is active. One
direct mutation runs at a time.

Each action is one compiled AppleScript execution addressed by persistent
ID — delete the matching playlist, or set its name — behind a single
confirm dialog. There are no plan artifacts, no typed approvals, no
freshness windows, no fingerprint rechecks, and no readback verification;
a failure returns the verbatim script error, never repaired and never
retried. No `.plan.json` or `.mutationresult.md` files are written for a
direct action — History and Reports cover applies only. The former
guarded machinery (script builders, plan artifact writers,
`CleanupGroupContext`) stays in the codebase, dormant, for a possible
later cleanup wave, but no user-visible path arms it anymore.

No playlist is refused: smart playlists, special-kind playlists
(including folders), and the pilot identities — the scalar-exact names
`#Musica xTotal` and `#Musica xTotal — Consolidated`, and persistent IDs
`E02030832FD20B07` and `61EC0FC6E0F1C250` — are all valid delete and
rename targets. (The rule that the pilot CONSOLIDATION PLAN is never
applied again is unaffected; only the playlists' deletability and
renamability changed.) Duplicate names are permitted on rename, exactly
as in Music.app — creating a same-name group is often the intent, because
that is what makes a near-match twin mergeable on the next scan.

Three entry points share the same confirm/rename sheet. The Cleanup tab
lists every live playlist as a full-width list — the former gate detail
pane is gone. Each row carries a checkbox, a Delete button, and a
Rename… button; the header caption reads "Delete or rename any playlist
directly. Deleting a playlist never removes songs from your library."
Deleting shows one alert — `Delete "Name"?` / `Songs stay in your
library.` — with an added line, `Deleting a folder also deletes the
playlists inside it.`, when the target is a folder; confirming executes
immediately. Renaming opens a sheet pre-filled with the current name;
Enter or the Rename button commits, Escape cancels, and committing the
unchanged name is a no-op (no script runs at all). Checking N rows and
choosing "Delete selected (N)" raises one alert — `Delete N playlists?`,
with the same folder-cascade line if any selection is a folder — then
runs the batch: deletes execute sequentially in selection order, each
success removes the row from the list immediately, and the first failure
stops the batch, surfaces the verbatim error, and leaves the remaining
rows untouched.

Checking N rows and choosing `Rename selected (N)…` opens one sheet titled
`Rename N playlists` that lists every selected playlist with an editable,
pre-filled name field per row; a `Find` / `Replace with` / `Apply to all`
helper runs a literal, case-sensitive replacement over every row's current
draft (not the original names), so a second use composes on the first. The
caption reads `Unchanged names are skipped. Duplicates allowed.`; the commit
button reads `Rename N playlists`, where N counts only drafts that are
non-empty and differ from their original name, and stays disabled at zero.
The sheet lists the selected playlists in that same alphabetical order, not
the order they were checked in. Confirming renames sequentially in
alphabetical (name, then persistent ID) order, skips any draft that is
empty or unchanged, patches each row's display name live as its rename
lands, and stops at the first verbatim script error, leaving the remaining
rows untouched — the sheet stays up through dispatch, same as every other
direct-mutation sheet. Like every direct action, batch rename writes no
`.plan.json` or `.mutationresult.md`.

The Library and Cleanup lists still order by clickable
Name/Tracks headers — display-only; ordering never feeds a mutation.
Browser rows (Merge/Consolidate tabs) carry the same Delete and Rename…
actions. NEAR MATCHES clusters carry "Align names…": the canonical name
is the variant equal to its own NFC form with no leading/trailing
whitespace and no invisible scalars (Sergio picks when none or several
qualify), and each deviant copy in the cluster opens the same pre-filled
rename sheet — one confirm per rename, no typed gate.

As the pilot section above records, deleting a playlist removes the
playlist, not its songs from the library. Source playlists of merges and
consolidations remain untouched by every create path; removal is only ever
this separate, per-playlist confirmed action.

## Apply failure taxonomy (Wave C1, 2026-08-04)

Every failed apply in the native app is now classified into one of five
library-state classes, derived purely from the failed stage plus the
returned readback evidence — reporting only; no engine guard, writer
script, reference, or contract model changed:

- **Refused before write** — nothing was created (plan load, source
  re-read, revalidation, existing-target refusal, or compile failed).
- **Writer failed** — the guarded write itself failed; a partial target may
  exist. Identified by the bridge's pinned `write failed: ` first mismatch.
- **Unverifiable** — the write may have completed, but verification could
  not read the library back: the readback threw, or any post-write readback
  READ failed (the bridge surfaces caught read errors as
  `source readback failed after write:` /
  `source copies readback failed after write:` /
  `target readback failed after write:` lines — a read failure means
  comparison never happened for that side, so state-unknown dominates even
  when genuine drift lines are also present). The conservative fallback
  class.
- **Source drifted** — the created target verified against the plan, but
  the source changed after the audit (every mismatch line carries the
  bridge's `source ` prefix and none is a read-failure line; the target
  readback always runs, so the inference is sound).
- **Target mismatch** — a target exists and does not match the plan (any
  non-`source ` comparison mismatch line dominates; read-failure lines
  classify unverifiable instead).

A classified failure still counts as **failed** everywhere; nothing is
repaired and nothing retries. The class banner and a per-class guidance
line render on the attended failure screen, and the run report — the live
screen and the persisted `.runreport.md` — gains two additive lines per
failed item after the verbatim failure line: `- Failure class: <label>`
and, for the four classes that can leave a target behind,
`- Leftover target: <name>` (deliberately never `- Created:`, which the
cleanup scanner parses as applied evidence; a regression test pins that the
scanner ignores both new lines).

Both surfaces also offer **Delete leftover target…** for those four
classes: it re-reads the live listing fresh, matches the recorded target
name scalar-exactly, and — only on exactly one match — stages the SAME
direct delete confirmation as every other delete (2026-08-06), built from
that fresh listing row and presented right there on the failure screen or
the run report. Confirm deletes it; Cancel walks away. Nothing is written
to `reports/` by this path, and no audit read runs beyond the one resolve.
Zero or multiple matches, or a failed listing read, surface an inline
notice instead and stage nothing. The resolve read holds the OSA slot in
both directions like every other mutation activity: it refuses to start
while anything else runs, and nothing else dispatches while it is in
flight.

## Destination navigation (Wave C2, 2026-08-04)

The native app's sidebar holds PLACES, not wizard steps: Library, Activity,
and Settings, with the existing Status section retained beneath them. The
five-step rail is gone; nothing changed inside the screens — containers
moved, content did not.

- Library is the unchanged source browser: Merge / Consolidate / Cleanup
  tabs, selection, the queue rail, and the direct confirm/rename sheet.
  That same sheet is anchored on the attended failure screen and the run
  report too, so **Delete leftover target…** stages its confirmation where
  you clicked it instead of parking anything on another screen.
- Activity is the run surface, rendered by precedence over existing state:
  an active or paused unattended run shows the run screen exactly as before
  (including the judgment-pause review surface); an attended flow with a
  completed audit shows a staged panel — Review → Confirm → Apply chips
  over the unchanged screens, with the same navigation legality, visited-
  review requirement, and typed-confirm gates; a finished run shows the
  mandatory report; an attended audit in flight shows its live ticking
  progress; otherwise an idle placeholder with the session's last run
  outcome.
- The Reports destination and its in-app history browser have been removed
  (Part 1, 2026-08-05); report artifacts remain on disk as the durable
  record, and each finished run's own report screen still offers
  "Save report…" to export it. The standalone History window (and its
  Cmd-Shift-H shortcut) was already removed in an earlier wave; the
  Diagnostics window (Cmd-Shift-D) is unchanged.
- Settings is a user-preferences screen (Part 2, 2026-08-05): Appearance
  (System / Light / Dark, applied immediately via `NSApp.appearance`),
  Startup ("Reload library on app start", plus the default browser tab —
  Merge / Consolidate / Cleanup — applied to the live tab once, at
  launch), and Notifications ("Play sound when a run finishes"). All four
  persist via `UserDefaults` (defaults: System appearance, reload off,
  Merge tab, sound off). This replaced the "Artifacts & Automation" panel
  Wave C2 promoted here: the output directory, the two batch toggles
  ("Confirm each apply", "Pause on judgment items"), and the Automation
  preflight button are no longer surfaced in Settings. Their model state
  and behavior are unchanged (both toggles still default off), and the
  Automation preflight stays reachable from the Diagnostics window
  (Cmd-Shift-D).

Starting an audit, a queue, or an apply auto-selects Activity. While the
write path is hot — an apply in flight, or an unattended run actively
working — the other destinations disable with the existing wait reasons,
and dismissing the run report returns to Library. A pending, unacknowledged
run report can never become unreachable: whenever newer activity would
render above it, Activity shows a pinned "View pending run report…" banner
that swaps the report in (and back out) without consuming it — only its own
Done acknowledges it. A failed or cancelled attended audit shows its
verbatim outcome on Activity, never a false idle. Run state stays visible
from every destination via a live status chip on the Activity row
(running / paused / finished / idle), and disabled rows and stage chips
carry their wait reason as a native tooltip. Every engine guard, gate,
artifact convention, and mutation lockout is untouched by this change.

## Packaging and distribution (2026-08-06)

`bash macos-app/scripts/build-app.sh` builds and signs
`macos-app/build/AppleMusicConsolidator.app` (v1.0.0);
`bash macos-app/scripts/package-dmg.sh` then packages it into
`macos-app/dist/AppleMusicConsolidator-<version>.dmg` — a compressed
installer image with an /Applications drag-symlink, Finder icon layout,
volume icon, and a `.sha256` checksum file beside it. The DMG is
verified (`hdiutil verify`) before the checksum is written; `dist/` is
git-ignored. All source files carry the project header naming
Sergio Farfan <sergio.farfan@gmail.com> as the sole author
(`scripts/add_source_headers.py`, idempotent).

## Read performance (2026-08-11)

The library listing (source browser) and playlist snapshot reads (audit,
merge, Diagnostics) are now COLUMNAR: each track/playlist property is
fetched as one whole-column Apple Event off an un-called specifier
collection, instead of one Apple Event per property per row. Every column's
length and type is checked against that same collection's count-first read,
fail-closed — a mid-scan mutation (a playlist or track added or removed
while the read is in flight) surfaces as a verbatim `column length
mismatch: <field>` or `column type mismatch: <field>` error, never as
misaligned or wrong data. The wire JSON contract
(`parsePlaylistListing`, `parseExactPlaylistSnapshot`, `parseAllCopies`) is
unchanged — every consumer downstream of a read is untouched.

The pre-columnar per-row builders (`legacyListPlaylistsScript`,
`legacyReadJXAScript`) are retained for ONE release, for Diagnostics'
"Compare readers" action only (Cmd-Shift-D): it runs legacy vs columnar for
both the library listing and one playlist's snapshot, diffs the PARSED
results, and reports `identical` or the first difference, with elapsed time
per reader so the speedup is visible. Nothing else calls the legacy
builders; they are removed once the columnar readers are validated against
them live. Both carry `@available(*, deprecated, …)` as the removal reminder,
so any new direct caller is flagged at compile time; the sanctioned callers
(the cross-check and the byte pins) reach them through the two seam accessors
described in `MusicScriptBuilder.swift`, and seam, pins and builders are
deleted in one sweep.

Pick a SMALL playlist before pressing "Compare readers": by construction half
of what it runs is the pre-columnar reader, whose cost still grows with the
track count (roughly one Apple Event per property per track), so on a large
playlist the legacy half alone can take minutes — that is the old cost being
measured on purpose, not a regression.

Before trusting the new readers, Sergio should exercise: a normal Rescan
(compare its elapsed before and after this change), the Diagnostics
"Compare readers" action, and three playlists that exercise the edge cases
where Apple Events can return a bare scalar or an empty reply instead of a
list — a 1-TRACK playlist, an EMPTY playlist, and a CLOUD-ONLY playlist (no
file tracks). Every one of these fails closed with a named column error
(`column type mismatch: <field>` / `column length mismatch: <field>`) if the
columnar idiom is wrong for that shape — that error is a BUG REPORT, never
data corruption.
