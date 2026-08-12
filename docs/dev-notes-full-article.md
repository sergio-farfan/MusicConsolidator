<!--
Developer notes — full-length article (original long draft, preserved 2026-08-12).
The published dev.to article is the shorter, reader-friendly version kept at the
repo root as dev-to-article.md. This copy keeps every implementation detail:
the Apple events cost model, the empty-playlist -1728 bug, the Unicode
case-folding notes, and the testing strategy.
-->

<p align="center">
  <img src="https://raw.githubusercontent.com/sergio-farfan/MusicConsolidator/faf0ba2/macos-app/assets/appicon/master-1024.png" width="150" alt="Apple Music Consolidator" />
</p>

You switched streaming services. Spotify to Apple Music, or YouTube Music, or Tidal — or you just got tired of paying two subscriptions at once. You ran one of the transfer tools, it churned for twenty minutes, and your playlists appeared in Music. Job done.

Then you started noticing things.

The transfer ran twice, because the first attempt looked like it stalled. Or it ran once, but iCloud Music Library pushed it to your Mac while your old local library was still sitting there. Or you imported from two services that shared half their playlists. Now you have **Road Trip**, **Road Trip**, and **Road Trip&nbsp;** — that last one with a trailing space, which Music is perfectly happy to let you keep — and all three have *slightly different* contents, because for the last eight months you've been adding songs to whichever one you happened to tap.

Inside them it's worse. The same song sits in one playlist three times: once as your ALAC rip from a CD, once as the 256 kbps Apple Music version, and once as a cloud entry that's now greyed out because the label pulled it. Same title, same artist, same duration. Three rows.

That's how mine got to just under 400 playlists, with dozens of duplicate groups buried in there.

## Now try fixing that by hand

Take one triple. Open two of the three side by side, sort both by name, and eyeball 300 rows against another 300 rows. Every time you hit a duplicate, decide which copy to keep — which means checking the bit rate of each one, and noticing that a third one is greyed out. Drag the survivors into a new playlist. Delete the two originals. Hope you didn't miss anything.

Thirty minutes for one group, if you're focused, and nobody stays focused past row 180. Now do that sixty times. That's a weekend gone, and the mistakes are silent: you don't discover you dropped a song until it isn't there on a drive six months later.

And the delete is forever. Music.app has no undo for a deleted playlist, no transaction log, no Recently Deleted. One misclick on a playlist you spent a decade building and it's simply gone.

## "Isn't there a tool for this?"

Sort of. I looked before writing anything. [Soundiiz](https://soundiiz.com/features) is the best-known playlist manager, and it genuinely does have both **Merge** and **Delete Duplicates**, and they work with Apple Music. Two things sent me back to my editor:

**They're subscription features.** Both sit behind Premium — $39/year or $5/month ([pricing](https://soundiiz.com/pricing)). The free plan is one-playlist-at-a-time transfers, up to 200 tracks. This is a chore I need to do properly once, and then again the next time a sync goes sideways; a recurring bill for that is a strange trade.

**It's a cloud service reaching in through the streaming API.** You authorize it against your Apple Music account, and it sees your library the way the API exposes it — as catalog tracks. It cannot see that *this* copy is your 1,411 kbps ALAC rip, *that* one is a 256 kbps AAC stream, and the third is flagged "no longer available." That is exactly the information that should decide which duplicate survives. It also can't see the local files that never came from the catalog at all.

Neither approach gives you the thing I actually wanted most: a chance to **read the exact change before it happens**, and proof afterward that what landed in the library is what I approved — on an operation that has no undo.

So I built **Apple Music Consolidator** — a native macOS app that merges duplicate playlists and deduplicates the tracks inside them, entirely on your Mac. Nothing is uploaded, no account is connected, nothing is behind a paywall. Every write is planned to a file first, executed by a writer that re-checks the library one statement before it mutates anything, and then proven correct by reading the library back.

**[Download the latest .dmg →](https://github.com/sergio-farfan/MusicConsolidator/releases/latest)** — open it and drag the app to Applications.

![The Merge tab: one checklist of every playlist — combine any of them, or merge same-name groups as units](https://raw.githubusercontent.com/sergio-farfan/MusicConsolidator/faf0ba2/docs/images/merge-tab.png)

---

## Features

- **Merge** — combines playlists into one new `<Name> — Merged` playlist, deduplicating across copies. Merge same-name copies as a unit, or check off any arbitrary mix of playlists and merge those; the new playlist's description records when it was merged and from which sources. Source playlists are never touched.
- **Consolidate** — deduplicates tracks *within* one playlist into a new `<Name> — Consolidated` playlist, with every omitted track individually accounted for in the plan.
- **Batch runs** — select any number of playlists and process them unattended. Each one still gets its own fresh library read, its own plan, its own guarded write, and its own readback verification.
- **Cleanup** — delete or rename any playlist behind a single confirmation, or batch-rename a whole page of them with per-row editable names and a find/replace fill helper (e.g. strip `" — Merged"` from thirty playlists in one pass).
- **A failure taxonomy instead of an error string** — a failed operation tells you the exact library state it left behind: refused before writing, writer failed, unverifiable, source drifted after a verified write, or target mismatch.

---

## The Stack

- **Swift 6.3**, strict concurrency, `@Observable` state
- **SwiftUI** app, macOS 14+, three targets in one Swift package: `ConsolidatorCore` (matching, planning, integrity — no I/O), `MusicBridge` (the only code that talks to Music), and the app
- **OSAKit** — the app compiles and runs generated AppleScript and JXA **in-process**, which makes the app itself the Apple-events sender
- **Swift Package Manager** only — no `.xcodeproj`. `swift build`, `swift test`, one build script
- **917 tests**, fully offline, none of which ever touch a real library

That OSAKit choice is load-bearing. A terminal-driven script sends Apple events as whatever launched it, so on a modern macOS it hits the automation-permission wall every time the sending context changes — and unattended batch runs are effectively impossible. Running the script inside the app means one permission grant, to one bundle, that survives updates.

---

## Everything Goes Through a Plan File

The core design rule: no code path anywhere in the app mutates the library from live state. It mutates from a **plan** — a JSON artifact on disk, with an integrity hash, that you can read before anything happens. Every audit writes three files: `.plan.json` (the machine contract), `.detail.csv` (every track and the decision made about it), and `.summary.md` (the human version).

Then the write happens in five steps, and each one can only fail closed:

1. **Fresh read.** Re-read the live library. Stale state is refused, never patched up.
2. **Plan.** Serialize the exact intended change, hash it.
3. **Guarded write.** Re-validate everything *inside the same compiled execution*, immediately before the one mutation verb.
4. **Readback.** Read the library back and compare it to the plan.
5. **Never repair, never retry.** A failure reports and stops. Recovery is a fresh, human-initiated pass.

Step 3 is the one that matters most, and it's the one people usually skip. Checking "is the playlist still what I expect?" from Swift and *then* sending a separate `duplicate` event leaves a window — the user can drag a track in Music between those two events. So the generated AppleScript does the checking and the mutating in one script, with the guards sitting directly above the verb:

```applescript
if (count of sourcePlaylists) is not 1 then error "expected exactly one source user playlist"
set sourcePlaylist to item 1 of sourcePlaylists

set liveSourcePlaylistPersistentID to persistent ID of sourcePlaylist
if (my textCodePointsMatch(expectedSourcePlaylistPersistentID, liveSourcePlaylistPersistentID)) is not true then error "source playlist persistent ID changed"
set sourceTracks to every track of sourcePlaylist
if (count of sourceTracks) is not expectedSourceTrackCount then error "source track count changed"
```

...and only after every track's eleven fields have been re-checked against the plan, and after confirming the target does **not** already exist:

```applescript
if (count of targetPlaylists) is not 0 then error "target user playlist already exists"

set destinationPlaylist to make new user playlist with properties {name:targetPlaylistName}
repeat with selectedSourcePosition in selectedSourcePositions
    set selectedTrack to item (selectedSourcePosition as integer) of sourceTracks
    duplicate selectedTrack to destinationPlaylist
end repeat
```

An existing target is refused, never reused and never appended to. If the plan says "create this playlist" and the playlist is already there, that's a state the app doesn't understand, so it stops.

---

## The Apple Events Cost Model

Here's the part I'd want to read if someone else had written it, because the documentation for this is essentially "good luck."

Every property you read off a Music object is an **Apple event** — a full IPC round trip. The obvious way to snapshot a playlist is a loop: for each track, ask for its title, then its artist, then its album, then eight more. That's ~11 events per track. On a 2,000-track playlist that's 22,000 round trips, and it takes minutes. My first version did exactly this and I assumed the slowness was Music being Music.

It isn't. JXA can fetch a whole **column** in one event — every title in the playlist, as an array — but only if you never let the specifier evaluate:

```javascript
const playlistRefs = Music.userPlaylists;      // NOT userPlaylists()
const expectedCount = playlistRefs.length;     // one `count` event

const ids = expectedCount === 0 ? [] : playlistRefs.id();          // one `get`, whole column
const names = expectedCount === 0 ? [] : playlistRefs.name();      // one `get`, whole column
```

The distinction between `Music.userPlaylists` and `Music.userPlaylists()` is the whole trick, and it cost me a review cycle to get right. **Un-called**, it's a chainable specifier collection: `.length` triggers one lean `count` event, and calling a property getter *on the collection* — `.name()` — triggers one `get` that returns the entire column. **Called**, the parentheses immediately evaluate it into a plain JavaScript `Array` of per-object specifiers, which has no `.name()` method at all. Every column read after that point dies with `TypeError: not a function`.

Two more things I had to learn empirically:

**There is no two-level version of this.** "Every track of every user playlist" is a legitimate idiom in genuinely Cocoa-Scriptable apps. Music is not one. So track counts come from a per-playlist loop that indexes into the *same* collection and stops one step short of evaluating: `playlistRefs[index].tracks.length` — one lean `count` per playlist, no track specifiers materialized. (Contrast `playlist.tracks()`, with parens, which materializes every track specifier before JavaScript reads `.length`: still one event, but one that drags back O(tracks) of data.)

**Every column must come off the same reference.** Read one column off `playlistRefs` and the next off a freshly re-filtered `Music.userPlaylists`, and you've silently assumed the library didn't change between two events. Reading them all off one bound reference makes index alignment true by construction — and then every column is checked against the count-first read anyway:

```javascript
if (!Array.isArray(names)) {
    throw new Error("column type mismatch: name");
}
if (names.length !== expectedCount) {
    throw new Error("column length mismatch: name");
}
```

If a playlist is created or deleted mid-scan, a column comes back the wrong length and the whole read fails with the column named. It doesn't return a partial snapshot — a partial snapshot is how you get a plan that deletes the wrong track.

The result, on my library: browsing 393 playlists went from ~2,358 Apple events to ~399, and the scan went from around seven seconds to about one. Per-playlist snapshots went from `1 + tracks × 11` events to a fixed **16, regardless of track count** — minutes to seconds.

---

## The Bug That Only Existed on an Empty Playlist

This one shipped past a full review and a green suite, and I found it the way you always find these: by using my own app.

I selected two random cloud playlists, hit merge, and got `-1728` — *"Can't get object."* Not a guard rejection with one of my own messages. A raw Apple Events error from inside the read.

The cause is a behavior I had assumed away. A columnar `get` on an **empty** element collection does not return `[]`. It throws. `playlist.tracks.name()` where the playlist has zero tracks resolves no object, so the whole event errors — and since my fast path was columnar-everything, any empty playlist anywhere in the read took the entire scan down with it.

Worse, it had a sibling. Cloud-only playlists have zero **file** tracks even when they have plenty of tracks, and the reader fetched a file-track column too (it needs those database IDs to derive `is_file_track`). So "playlist with tracks, none of them local files" hit the same throw by a different route.

The fix is small, and it's the same shape in both places — count first, short-circuit at zero, never send a columnar get into the void:

```javascript
// Live -1728 fix (2026-08-11): a columnar get against an EMPTY
// element collection resolves no object and errors. Count first;
// a zero-track playlist returns its record before any column get.
const trackRefs = playlist.tracks;
const expectedTrackCount = trackRefs.length;
if (expectedTrackCount === 0) {
    return {
        id: playlist.id(),
        name: playlist.name(),
        persistent_id: playlist.persistentID(),
        tracks: []
    };
}

// Cloud playlists have zero FILE tracks; skip that fetch too.
const fileTrackRefs = playlist.fileTracks;
const expectedFileTrackCount = fileTrackRefs.length;
const fileTrackDatabaseIdColumn =
    expectedFileTrackCount === 0 ? [] : fileTrackRefs.databaseID();
```

What I actually took away from it: my test doubles were **more polite than reality**. The JXA fake returned `[]` for an empty collection, because that's what a reasonable API does, and so 917 offline tests could not have caught this. The doubles were rewritten to throw the way Music actually throws — and *that* is the version of the suite that has a chance of catching the next one. A mock that's nicer than the system it stands in for is a test that lies to you.

It's also the clearest argument for the guard architecture I can give. This was a genuine live failure in the fastest, most-exercised path in the app, and its blast radius was an error dialog. Nothing was created, nothing was deleted, no half-merged playlist was left behind — because the read failed before a plan existed, and a write can't happen without a plan.

---

## Normalize to Match, Compare Exactly to Verify

Deduplication needs a definition of "the same song," and it has to be *strict*, because a false positive here silently drops a track you wanted. The key is a 3-tuple: normalized title, normalized artist, and exact duration in milliseconds — nothing fuzzy, no edit distance, no "close enough." Normalization does NFKC, maps curly quotes and en/em dashes to ASCII, collapses whitespace runs, and case-folds. Accents are **preserved**: "Nina Simone" and "Niña Simone" are different artists.

When several tracks share a key, the winner is decided by a total order — available before unavailable, lossless before lossy, then higher sample rate, higher bit rate, earlier position, and finally persistent ID as a deterministic tiebreak. Deterministic all the way down, so the same library always yields the same plan.

The subtle half is the other direction. Normalization is for *matching*; verification has to be **code-point exact**, and Swift's `String ==` is the wrong tool for that:

```swift
public static func == (lhs: SemanticKey, rhs: SemanticKey) -> Bool {
    lhs.durationMs == rhs.durationMs
        && lhs.title.unicodeScalars.elementsEqual(rhs.title.unicodeScalars)
        && lhs.artist.unicodeScalars.elementsEqual(rhs.artist.unicodeScalars)
}
```

Swift compares strings by Unicode canonical equivalence, so two scalar-different strings that render identically are `==`. That's usually a feature. For a readback proof it's a hole: "did the library end up with exactly the bytes my plan specified?" must not be answerable with "well, they look the same." Everything on the verification path — plan integrity, readback comparison, the AppleScript-side `textCodePointsMatch` handler — compares scalar by scalar. Trailing spaces, NFC vs NFD, invisible characters: all distinct values, treated as distinct.

Chasing exact case-folding parity produced my favorite piece of trivia in the codebase. Apple's `.folding(options: .caseInsensitive)` folds Cherokee **capitals down to smalls**; Unicode's `CaseFolding.txt` — which Python's `str.casefold()` follows — folds the **smalls up to capitals**, because the small letters were only added in Unicode 8. The two disagree on 86 code points, so there's a post-fold correction table. And `CharacterSet.whitespacesAndNewlines` includes U+200B ZERO WIDTH SPACE, which isn't whitespace at all (it's `Cf`), so trimming uses an explicit 29-code-point set derived by sweeping the entire Unicode range.

None of my playlists contain Cherokee. It's pinned by golden fixtures anyway, because "the matching key is stable" is either true for all inputs or it's a coin flip on the ones I haven't seen yet.

---

## Where the Ceremony Stops

The five-step protocol is right for creating a playlist derived from thousands of decisions across multiple sources. Applying it to "rename this playlist" was a mistake I shipped and then removed.

Delete and rename are now **direct**: one confirmation dialog, one compiled execution, no plan file, no readback. The reasoning is that the ceremony's value scales with how much derived state is at risk. A merge failing halfway is a mystery; a rename failing is a playlist with the old name. And a playlist delete in Music removes the *playlist*, not the songs — they stay in the library.

What the direct path keeps is the part that's correctness rather than ceremony: the lookup is pinned to a **persistent ID**, compared by code point, and refuses to proceed unless exactly one playlist matches.

```applescript
repeat with candidatePlaylist in every user playlist
    set candidatePID to persistent ID of candidatePlaylist
    if candidatePID is missing value then set candidatePID to ""
    if (my textCodePointsMatch(expectedPlaylistPersistentID, candidatePID)) is true then
        set end of matchedPlaylists to contents of candidatePlaylist
    end if
end repeat
if (count of matchedPlaylists) is 0 then error "playlist persistent ID is absent — rescan and retry"
if (count of matchedPlaylists) is not 1 then error "playlist persistent ID is duplicated"
set doomedPlaylist to item 1 of matchedPlaylists

delete doomedPlaylist
```

Never by name. Names are duplicated — that's the entire problem the app exists to solve — and a name-based delete on this library is a coin flip. "Fast" and "sloppy" are different axes: this path dropped the artifacts and the readback, and kept every line that decides *which object* gets hit.

---

## Testing Something With No Undo

917 tests, 191 suites, zero of them touching a real library. Three things carry most of the weight:

**Golden fixtures.** The matching, normalization, and plan-integrity behavior is pinned to fixture files, and the generated writer scripts are pinned **byte-for-byte**. Script generation is exactly the kind of code where a well-meaning refactor changes a guard's meaning while every behavioral test stays green.

**Scripted fakes at the one seam.** All Music access goes through a single injectable runner, so tests hand the bridge canned responses — including malformed ones, drifted ones, and (as of the `-1728` fix) ones that throw the way Music really throws.

**Offscreen structural tests.** SwiftUI views are rendered into an offscreen host at several window sizes and asserted geometrically — this label is inside its container, this button is hittable. That's how a clipped caption and a stretched status column got caught as failing tests instead of as screenshots I'd have to notice.

---

## Build & Install

**Easiest:** grab `AppleMusicConsolidator-<version>.dmg` from the [latest release](https://github.com/sergio-farfan/MusicConsolidator/releases/latest) (SHA-256 checksum alongside it), open it, and drag the app to **Applications**. It's signed with a personal certificate rather than notarized, so the first launch needs a right-click → **Open**. It will then ask permission to control Music — that grant is required for everything the app does, and it survives updates.

**From source** — Swift Package Manager, no Xcode project:

```bash
git clone git@github.com:sergio-farfan/MusicConsolidator.git
cd MusicConsolidator/macos-app/ConsolidatorKit
swift test            # 917 tests, fully offline

cd ../..
bash macos-app/scripts/build-app.sh     # build, assemble, sign the bundle
bash macos-app/scripts/package-dmg.sh   # package the installer
```

The build script signs with a stable self-signed certificate so the macOS Automation permission survives rebuilds. Requirements: macOS 14+, Swift 6, and Music.app with an Apple Music library.

---

## Source Code

MIT licensed, on GitHub: [github.com/sergio-farfan/MusicConsolidator](https://github.com/sergio-farfan/MusicConsolidator).

If you've fought with JXA columnar reads, Apple Events performance, or automation permissions from a SwiftUI app, I'd genuinely like to compare notes — issues are open.

---

*Built with Swift 6 and SwiftUI on macOS.*
