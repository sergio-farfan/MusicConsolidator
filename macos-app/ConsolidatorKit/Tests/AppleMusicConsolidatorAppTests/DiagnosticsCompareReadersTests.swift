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

@Suite("Diagnostics compare-readers action (Task 3, bulk-read-speedup)")
struct DiagnosticsCompareReadersTests {

    // The brief's literal minimum: a fake runner returning identical wires
    // for both reads reports `identical` — extended (scope addition A) to
    // BOTH readers (listing + one playlist snapshot), with elapsed populated
    // for every one of the four reads so the speedup is visible.
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
        #expect(runner.commands.count == 4)
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

    @Test("an empty playlist-name field falls back to the first live-listing entry")
    func emptyNameFallsBackToFirstListingEntry() throws {
        let listing = listingWire(name: "Fallback List")
        let snapshot = consolidateFixtureWire(name: "Fallback List")
        let runner = ScriptedRunner(outputs: [listing, listing, snapshot, snapshot])

        let outcome = try ReadWorker.compareReaders(playlistName: "   ", runner: runner)

        #expect(outcome.snapshotPlaylistName == "Fallback List")
        #expect(outcome.isIdentical)
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
