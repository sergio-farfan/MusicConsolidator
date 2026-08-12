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

So I built **Apple Music Consolidator** — a native macOS app that merges duplicate playlists and deduplicates the tracks inside them, entirely on your Mac. Nothing is uploaded, no account is connected, nothing is behind a paywall. Every write is planned first, executed through a guarded writer, and then proven correct by reading the library back.

**[Download the latest .dmg →](https://github.com/sergio-farfan/MusicConsolidator/releases/latest)** — open it and drag the app to Applications.

![The Merge tab: one checklist of every playlist — combine any of them, or merge same-name groups as units](https://raw.githubusercontent.com/sergio-farfan/MusicConsolidator/faf0ba2/docs/images/merge-tab.png)

---

## What It Does

- **Merge** — combines playlists into one new `<Name> — Merged` playlist, deduplicating across copies. Merge same-name copies as a unit, or check off any arbitrary mix of playlists and merge those; the new playlist's description records when it was merged and from which sources. Source playlists are never touched.
- **Consolidate** — deduplicates tracks *within* one playlist into a new `<Name> — Consolidated` playlist, with every omitted track individually accounted for.
- **Batch runs** — select any number of playlists and process them unattended. Each one still gets its own fresh library read, its own plan, and its own verification.
- **Cleanup** — delete or rename any playlist behind a single confirmation, or batch-rename a whole page of them with a find/replace fill helper (e.g. strip `" — Merged"` from thirty playlists in one pass).

---

## How It Works

Everything runs on your Mac, inside one small native app (Swift 6, SwiftUI). It talks to Music.app directly; macOS asks you once for permission to allow that, and the grant survives updates.

**What counts as a duplicate.** Two tracks match only when their normalized title, normalized artist, and exact duration all agree. Normalization is forgiving where it's safe — curly quotes match straight quotes, dashes match hyphens, extra whitespace and letter case don't matter — and strict where it isn't: accents are preserved, so "Nina" and "Niña" stay different artists, and there is no fuzzy "close enough" matching. A false match silently drops a song you wanted to keep, so when in doubt the app keeps both rows.

**Which copy survives.** When several tracks match, the app keeps the best one by a fixed, predictable preference: available beats greyed-out, lossless beats lossy, then higher sample rate, then higher bit rate. This is the comparison a cloud service can't make — it takes actually seeing your files. The same library always produces the same answer.

**Every change is planned, then proven.** No operation ever mutates the library from live state. First the app re-reads your library fresh, then it writes the exact intended change to a small report you can read — every track, every keep-or-omit decision, and why. Only after that does it execute, through a writer that re-checks the playlists one final time *immediately* before the single create step, and refuses to touch anything that has changed since the plan — or to reuse a playlist that already exists. Then it reads the library back and confirms, track for track, that what landed is what the plan said. If any step disagrees, the app stops and tells you exactly what state it left behind. It never retries and never "repairs" — recovery is always a fresh pass that you start.

**Sources are never modified.** Merge and Consolidate always create a *new* playlist. Your originals sit untouched until you delete them yourself in Cleanup, after you've verified the result.

**And it's fast.** Reading a library through Apple events is normally the slow part of any Music automation. The app fetches data in bulk columns instead of track by track, so scanning ~400 playlists takes about a second, and snapshotting a big playlist takes seconds instead of minutes.

---

## Take It for a Test Drive

1. **Install** — download the `.dmg`, drag the app to Applications, right-click → **Open** on first launch (it's signed with a personal certificate, not notarized), and grant it permission to control Music.
2. **Scan** — one click reads your whole library. Same-name duplicate groups are highlighted automatically.
3. **Pick your victims** — in the Merge tab, every playlist is one checklist. Run a duplicate group as a unit, or check any combination and **Merge selected as one…**
4. **Read the plan** — before anything happens, you see exactly what will be created and every duplicate decision the app intends to make.
5. **Apply** — a new `<Name> — Merged` playlist appears, its description recording when it was merged and from which sources. The app reads the library back and confirms the result matches the plan.
6. **Tidy up** — happy with the merge? Use Cleanup to batch-delete the originals, or batch-rename to drop the `" — Merged"` suffix.

Start small: pick one duplicate pair you know well, merge it, and inspect the result in Music before turning it loose on sixty groups. That's what the plan-first design is for.

---

## Build & Install

**Easiest:** grab `AppleMusicConsolidator-<version>.dmg` from the [latest release](https://github.com/sergio-farfan/MusicConsolidator/releases/latest) (SHA-256 checksum alongside it), open it, and drag the app to **Applications**.

**From source** — Swift Package Manager, no Xcode project:

```bash
git clone git@github.com:sergio-farfan/MusicConsolidator.git
cd MusicConsolidator/macos-app/ConsolidatorKit
swift test            # 917 tests, fully offline

cd ../..
bash macos-app/scripts/build-app.sh     # build, assemble, sign the bundle
bash macos-app/scripts/package-dmg.sh   # package the installer
```

Requirements: macOS 14+, Swift 6, and Music.app with an Apple Music library.

---

## Source Code

MIT licensed, on GitHub: [github.com/sergio-farfan/MusicConsolidator](https://github.com/sergio-farfan/MusicConsolidator).

If you're curious about the engineering underneath — the Apple events cost model that took library scans from minutes to seconds, a bug that only reproduced on empty playlists in a live library, and why verification compares strings code point by code point — the [full developer notes](https://github.com/sergio-farfan/MusicConsolidator/blob/main/docs/dev-notes-full-article.md) are in the repo.

Issues and feedback are open — if this untangles your library, I'd love to hear about it.

---

*Built with Swift 6 and SwiftUI on macOS.*
