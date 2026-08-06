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

## Guarded delete and rename (AGENTS.md amendment, 2026-08-03)

The native app adds playlist delete and rename as a second guarded mutation
class under the AGENTS.md "guarded in-app mutations" amendment (Sergio,
2026-08-03). Creates remain the only batch-capable operation; delete and
rename are ATTENDED ONLY — they never run inside an unattended queue, never
inside any apply, and both gates are disabled while an unattended run is
active.

Every mutation is artifact-first and persistent-ID-pinned. Arming a gate
performs a fresh live audit and writes a reviewable
`.delete.plan.json` / `.rename.plan.json` plus `.summary.md` pair into
`reports/` (never overwritten). The artifact is session-bound and single-use:
it can only dispatch from the app launch that wrote it, within 10 minutes,
after a SHA-256 recheck from disk, and executing OR aborting consumes it —
nothing can ever re-arm a consumed artifact. The writer re-verifies the
pinned copy's exact name, track count, and ordered track persistent IDs
inside the same compiled execution, immediately before its single mutation
verb, and every execution ends in a bijective full-listing readback; any
drift fails closed with verbatim mismatches persisted in a
`.mutationresult.md` report. Failures are never repaired and never retried.

Typed confirmation must uniquely identify the pinned persistent ID, never a
name alone: when the typed name matches more than one live playlist the gate
also requires the copy's track count, and if that is ambiguous too, the last
four characters of the persistent ID. Typed input is never trimmed, folded,
or normalized anywhere in the app.

Refused outright, before any gate: smart playlists; special-kind playlists
(including folders); the scalar-exact names `#Musica xTotal` and
`#Musica xTotal — Consolidated`; and persistent IDs `E02030832FD20B07` and
`61EC0FC6E0F1C250` (the pilot source and its verified target, retained as
contract evidence). The same names are refused as rename destinations. Any
other rename collision is a warning, not a block — creating a same-name
group is often the intent, because that is what makes a near-match twin
mergeable on the next scan.

Three entry points exist. The Cleanup tab lists every live playlist
for gated deletion (2026-08-06: the post-merge group flow was removed
from the UI; the evidence scanner remains in the engine); contract-excluded
names and IDs stay refused up front. Eligible rows carry a checkbox
(refused rows cannot be checked): selecting N playlists and choosing
"Delete selected (N)…" arms one gate for the whole batch, whose typed
token is the exact selection count — the second named exception to
one-approval-per-playlist (Sergio, 2026-08-06). Every playlist in the
batch is still its own fresh-audited plan artifact and its own guarded
compiled execution with full-listing readback between deletes, and any
refusal at arm time refuses the whole batch fail-closed. The
Library and Cleanup lists order by clickable Name/Tracks headers —
display-only; ordering never feeds a guard, plan, or queue. Browser rows carry
Delete…/Rename… actions with refusals surfaced up front as disabled actions
plus the reason. NEAR MATCHES clusters carry "Align names…": the canonical
name is the variant equal to its own NFC form with no leading/trailing
whitespace and no invisible scalars (Sergio picks when none or several
qualify), and an N-variant cluster yields N−1 separately gated renames whose
typed confirmation is the canonical destination name, the deviant copy
pinned by persistent ID with its invisible-character diff displayed.

As the pilot section above records, deleting a playlist removes the
playlist, not its songs from the library. Source playlists of merges and
consolidations remain untouched by every create path; removal is only ever
this separate, individually gated operation.

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
name scalar-exactly, and — only on exactly one match — arms the existing
Wave B delete gate on that persistent ID (every guard, typed-token
requirement, artifact, and readback unchanged). The gate's sheet anchors on
the browser: armed from the failure or report screen, it presents when you
return to the browser, with the usual freshness window still counting down
from the arm. Zero or multiple matches, or a failed listing read, surface
an inline notice instead and arm nothing. The resolve read holds the OSA
slot in both directions like every other mutation activity: it refuses to
start while anything else runs, and nothing else — including the gate's own
Execute — dispatches while it is in flight.

## Destination navigation (Wave C2, 2026-08-04)

The native app's sidebar holds PLACES, not wizard steps: Library, Activity,
and Settings, with the existing Status section retained beneath them. The
five-step rail is gone; nothing changed inside the screens — containers
moved, content did not.

- Library is the unchanged source browser: Merge / Consolidate / Cleanup
  tabs, selection, the queue rail, and the mutation-gate sheet.
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
