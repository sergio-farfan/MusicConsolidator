// DiagnosticsCompareReadersTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Task 3 (bulk-read-speedup): the Diagnostics "Compare readers" action —
// legacy vs columnar for BOTH the library listing (`legacyListPlaylistsScript`
// vs the live `buildListPlaylistsJXA`) and one playlist snapshot
// (`legacyReadJXAScript` vs the live `buildReadJXA`), diffed on their PARSED
// results (never raw script text). Model-level only: `ReadWorker.compareReaders`
// is exercised directly through a fake ScriptRunner (`ScriptedRunner`,
// AppTestSupport.swift) so nothing here ever contacts Music.

import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

private func listingWire(
    id: Int = 10,
    name: String = "Trance 2022",
    persistentId: String = "S-A",
    trackCount: Int = 2
) -> String {
    """
    {"playlists": [{"id": \(id), "name": "\(jsonEscaped(name))", \
    "persistent_id": "\(jsonEscaped(persistentId))", "track_count": \(trackCount), \
    "smart": false, "special_kind": "none"}]}
    """
}

private func emptyListingWire() -> String {
    "{\"playlists\": []}"
}

// Canonically EQUIVALENT but scalar-DIFFERENT spellings of the same grapheme:
// Swift `String ==` (and every synthesized Equatable built on it) calls these
// two equal, a scalar-exact comparator does not. Finding I1's fixtures.
private let nfcCafe = "Caf\u{00E9}"           // U+0043 U+0061 U+0066 U+00E9
private let nfdCafe = "Cafe\u{0301}"          // U+0043 U+0061 U+0066 U+0065 U+0301

@Suite("Diagnostics compare-readers action (Task 3, bulk-read-speedup)")
struct DiagnosticsCompareReadersTests {

    // The brief's literal minimum: a fake runner returning identical wires
    // for both reads reports `identical` — extended (scope addition A) to
    // BOTH readers (listing + one playlist snapshot), with elapsed populated
    // for every one of the four reads so the speedup is visible.
    // The positional pin below asserts against the legacy builders through the
    // `legacyListingScript()`/`legacyReadScript(name:)` seam accessors (M1; see
    // MusicScriptBuilder.swift, "legacy-builder deprecation seam"), so it pins
    // their exact text without a standing deprecation warning.
    @Test("identical wires for every reader report identical, with elapsed populated")
    func identicalWiresReportIdentical() throws {
        let listing = listingWire()
        let snapshot = consolidateFixtureWire(name: "Trance 2022")
        let runner = ScriptedRunner(outputs: [listing, listing, snapshot, snapshot])

        let outcome = try ReadWorker.compareReaders(playlistName: "Trance 2022", runner: runner)

        #expect(outcome.isIdentical)
        #expect(outcome.firstDifference == nil)
        #expect(outcome.snapshotPlaylistName == "Trance 2022")
        #expect(outcome.listingElapsed.legacySeconds >= 0)
        #expect(outcome.listingElapsed.liveSeconds >= 0)
        #expect(outcome.snapshotElapsed.legacySeconds >= 0)
        #expect(outcome.snapshotElapsed.liveSeconds >= 0)

        // I5 (final review, 2026-08-11): the four dispatched scripts are pinned
        // POSITIONALLY against their builders, not merely counted. A bare
        // `commands.count == 4` passed even if the harness ran the LIVE reader
        // four times, or ran the legacy and live scripts in the wrong order —
        // i.e. it could not detect a cross-check that was not cross-checking
        // anything. Same convention as ApplyFlowModelTests' M5 command-sequence
        // pin. Order is the contract: legacy listing, live listing, legacy
        // snapshot, live snapshot.
        let commands = runner.commands
        #expect(commands.count == 4)
        #expect(commands[0] == .readJXA(script: legacyListingScript()))
        #expect(commands[1] == .readJXA(script: buildListPlaylistsJXA()))
        #expect(commands[2] == .readJXA(script: legacyReadScript(name: "Trance 2022")))
        #expect(commands[3] == .readJXA(script: buildReadJXA(name: "Trance 2022")))
    }

    // I1 (final review, 2026-08-11): the comparators must be SCALAR-exact.
    // Before the fix these two tests failed — the listing comparator used the
    // synthesized `PlaylistListing !=` and the snapshot comparator used
    // `TrackSnapshot !=`/`String !=`, all of which compare text by Unicode
    // canonical equivalence, so a wire that spelled the very same name or title
    // in NFD instead of NFC was reported as `identical`. A fidelity probe that
    // normalizes away byte differences cannot detect byte differences.
    @Test("a listing name differing only NFC-vs-NFD is a difference, not identical")
    func nfcVersusNfdListingNameIsADifference() throws {
        let legacyListing = listingWire(name: nfcCafe)
        let liveListing = listingWire(name: nfdCafe)
        let snapshot = consolidateFixtureWire(name: "Trance 2022")
        let runner = ScriptedRunner(outputs: [legacyListing, liveListing, snapshot, snapshot])

        // Guard the premise: Swift's own String == cannot tell these apart.
        #expect(nfcCafe == nfdCafe)
        #expect(!nfcCafe.unicodeScalars.elementsEqual(nfdCafe.unicodeScalars))

        let outcome = try ReadWorker.compareReaders(playlistName: "Trance 2022", runner: runner)

        #expect(!outcome.isIdentical)
        let difference = try #require(outcome.firstDifference)
        #expect(difference.contains("listing entry 1 name differs"))
    }

    @Test("a track title differing only NFC-vs-NFD is a difference, not identical")
    func nfcVersusNfdTrackTitleIsADifference() throws {
        let listing = listingWire()
        // The playlist NAME cannot diverge here (parseAllCopies filters both
        // sides scalar-exactly on the requested name), so the divergence is
        // planted in a TRACK field — the snapshot comparator's own path.
        func snapshotWire(title: String) -> String {
            wireSnapshot(playlists: [
                wirePlaylist(id: 100, name: "Trance 2022", persistentId: "PLAYLIST0", tracks: [
                    wireTrack(sourceIndex: 0, databaseId: 11, persistentId: "AAAA0001", title: title)
                ])
            ])
        }
        let runner = ScriptedRunner(outputs: [
            listing, listing, snapshotWire(title: nfcCafe), snapshotWire(title: nfdCafe),
        ])

        let outcome = try ReadWorker.compareReaders(playlistName: "Trance 2022", runner: runner)

        #expect(!outcome.isIdentical)
        let difference = try #require(outcome.firstDifference)
        #expect(difference.contains("copy 1 track 1 title differs"))
    }

    @Test("a differing listing wire is reported as the first difference")
    func differingListingReportsFirstDifference() throws {
        let legacyListing = listingWire(trackCount: 2)
        let liveListing = listingWire(trackCount: 3)
        let snapshot = consolidateFixtureWire(name: "Trance 2022")
        let runner = ScriptedRunner(outputs: [legacyListing, liveListing, snapshot, snapshot])

        let outcome = try ReadWorker.compareReaders(playlistName: "Trance 2022", runner: runner)

        #expect(!outcome.isIdentical)
        let difference = try #require(outcome.firstDifference)
        #expect(difference.contains("listing"))
    }

    @Test("a differing snapshot wire (listing agrees) is reported as the first difference")
    func differingSnapshotReportsFirstDifference() throws {
        let listing = listingWire()
        let legacySnapshot = consolidateFixtureWire(name: "Trance 2022")
        let liveSnapshot = wireSnapshot(playlists: [
            wirePlaylist(id: 100, name: "Trance 2022", persistentId: "PLAYLIST0", tracks: [])
        ])
        let runner = ScriptedRunner(outputs: [listing, listing, legacySnapshot, liveSnapshot])

        let outcome = try ReadWorker.compareReaders(playlistName: "Trance 2022", runner: runner)

        #expect(!outcome.isIdentical)
        let difference = try #require(outcome.firstDifference)
        #expect(difference.contains("copy"))
    }

    @Test("an empty playlist-name field falls back to the first LEGACY-listing entry")
    func emptyNameFallsBackToFirstListingEntry() throws {
        let listing = listingWire(name: "Fallback List")
        let snapshot = consolidateFixtureWire(name: "Fallback List")
        let runner = ScriptedRunner(outputs: [listing, listing, snapshot, snapshot])

        let outcome = try ReadWorker.compareReaders(playlistName: "   ", runner: runner)

        #expect(outcome.snapshotPlaylistName == "Fallback List")
        #expect(outcome.isIdentical)
    }

    // M6 (final review, 2026-08-11): the fallback subject comes from the
    // REFERENCE (legacy) listing, never from the live listing — the reader
    // under test must not choose what it is judged against. The two listings
    // are made to disagree so the choice is observable: the snapshot compared
    // is the legacy listing's first entry.
    @Test("when the listings disagree, the fallback subject is the legacy reader's first entry")
    func fallbackSubjectComesFromTheLegacyReader() throws {
        let legacyListing = listingWire(id: 10, name: "Legacy First", persistentId: "S-A")
        let liveListing = listingWire(id: 10, name: "Live First", persistentId: "S-A")
        let snapshot = consolidateFixtureWire(name: "Legacy First")
        let runner = ScriptedRunner(outputs: [legacyListing, liveListing, snapshot, snapshot])

        let outcome = try ReadWorker.compareReaders(playlistName: "", runner: runner)

        #expect(outcome.snapshotPlaylistName == "Legacy First")
        // The listings themselves differ, so the run is not identical — but the
        // snapshot pair still ran, against the legacy-chosen name.
        #expect(!outcome.isIdentical)
        let commands = runner.commands
        #expect(commands.count == 4)
        #expect(commands[2] == .readJXA(script: legacyReadScript(name: "Legacy First")))
        #expect(commands[3] == .readJXA(script: buildReadJXA(name: "Legacy First")))
    }

    @Test("an empty library (no user playlists) fails closed with a named stage")
    func emptyLibraryFailsClosed() throws {
        let runner = ScriptedRunner(outputs: [emptyListingWire(), emptyListingWire()])

        #expect {
            _ = try ReadWorker.compareReaders(playlistName: "", runner: runner)
        } throws: { error in
            guard let failure = error as? ReaderCompareFailure else { return false }
            return failure.stage == "snapshot"
        }
    }
}
