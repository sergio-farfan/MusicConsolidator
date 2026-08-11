// UnifiedMergeRowTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// 2026-08-11 unified merge list, Task 1 — the pure row builder (`mergeRows`)
// that interleaves same-name groups and singletons into ONE alphabetical
// ALL PLAYLISTS checklist (mirrors `cleanupRows`' shape: pure, display-only,
// needle-filtered, sortable), plus the selection plumbing it feeds:
// `selectAllEligible`'s merge branch now also checks eligible singletons
// (skipping already-processed sources of either kind), and
// `mergeSelectedSourceCount` reports the total SOURCE playlist count (group
// copies + singletons) the unified footer needs. Offline only — no Music,
// no view code (Task 2 builds the view over these).

import Foundation
import Testing
import ConsolidatorCore
@testable import AppleMusicConsolidatorApp

// MARK: - listing fixtures (pure `mergeRows` tests)

private func rowListing(
    id: Double, name: String, pid: String, count: Int = 5
) -> PlaylistListing {
    PlaylistListing(
        playlistId: id, name: name, persistentId: pid,
        trackCount: count, isSmart: false, specialKind: "none"
    )
}

@Suite("mergeRows (pure, display-only)")
struct MergeRowsTests {

    @Test("groups and singletons interleave in one alphabetical order")
    func interleaveOrder() {
        // "M-Group" must land BETWEEN the two singletons alphabetically —
        // proving the interleave is a real merge, not groups-then-singletons.
        let sections = buildPlaylistBrowseSections(from: [
            rowListing(id: 20, name: "M-Group", pid: "M-1"),
            rowListing(id: 21, name: "M-Group", pid: "M-2"),
            rowListing(id: 10, name: "L-Solo", pid: "L-1"),
            rowListing(id: 40, name: "N-Solo", pid: "N-1"),
        ])

        let rows = mergeRows(sections: sections, needle: "", key: .name, ascending: true)
        #expect(rows.map(\.id) == ["L-1", "M-Group", "N-1"])
        guard case .group(let group) = rows[1] else {
            Issue.record("expected the middle row to be the M-Group group row")
            return
        }
        #expect(group.copies.map(\.persistentId) == ["M-1", "M-2"])

        // Descending is the exact reversal (applyBrowserSort's `.name`
        // contract over pre-sorted input, reused here).
        let descending = mergeRows(sections: sections, needle: "", key: .name, ascending: false)
        #expect(descending.map(\.id) == ["N-1", "M-Group", "L-1"])
    }

    @Test("needle filters both row kinds by a case-insensitive name substring")
    func needleFiltering() {
        let sections = buildPlaylistBrowseSections(from: [
            rowListing(id: 10, name: "Trance 2022", pid: "T-1"),
            rowListing(id: 11, name: "Trance 2022", pid: "T-2"),
            rowListing(id: 20, name: "Trance Extras", pid: "E-1"),
            rowListing(id: 30, name: "House Anthems", pid: "H-1"),
        ])

        let rows = mergeRows(sections: sections, needle: "trance", key: .name, ascending: true)
        #expect(rows.map(\.id) == ["Trance 2022", "E-1"])
    }

    @Test("a near-match singleton carries the OTHER variant's name as its twin; a plain singleton carries nil")
    func nearMatchTwin() {
        let sections = buildPlaylistBrowseSections(from: [
            rowListing(id: 10, name: "Kdrama", pid: "K-A"),
            rowListing(id: 20, name: "Kdrama ", pid: "K-B"),
            rowListing(id: 30, name: "Foxtrot", pid: "F-1"),
        ])
        #expect(sections.nearMatches.map(\.normalizedName) == ["Kdrama"])
        let rows = mergeRows(sections: sections, needle: "", key: .name, ascending: true)

        func singletonRow(id: String) -> MergeBrowserRow? {
            rows.first { $0.id == id }
        }

        if case .singleton(_, let twin) = singletonRow(id: "K-A") {
            #expect(twin == "Kdrama ")
        } else {
            Issue.record("expected K-A to be a singleton row")
        }
        if case .singleton(_, let twin) = singletonRow(id: "K-B") {
            #expect(twin == "Kdrama")
        } else {
            Issue.record("expected K-B to be a singleton row")
        }
        if case .singleton(_, let twin) = singletonRow(id: "F-1") {
            #expect(twin == nil, "a singleton outside every near-match cluster has no twin")
        } else {
            Issue.record("expected F-1 to be a singleton row")
        }
    }

    @Test("count-sort uses a group's SUMMED copy counts, not its number of copies")
    func countSortUsesSummedCopies() {
        // Alpha's summed copies (5 + 6 = 11) exceed Beta's single count (8);
        // a copy-COUNT bug (2) would sort Alpha first ascending instead.
        let sections = buildPlaylistBrowseSections(from: [
            rowListing(id: 10, name: "Alpha", pid: "A-1", count: 5),
            rowListing(id: 11, name: "Alpha", pid: "A-2", count: 6),
            rowListing(id: 20, name: "Beta", pid: "B-1", count: 8),
        ])

        let ascending = mergeRows(sections: sections, needle: "", key: .count, ascending: true)
        #expect(ascending.map(\.id) == ["B-1", "Alpha"])
        let descending = mergeRows(sections: sections, needle: "", key: .count, ascending: false)
        #expect(descending.map(\.id) == ["Alpha", "B-1"])
    }
}

// MARK: - model plumbing fixtures (selectAllEligible + mergeSelectedSourceCount)

private func plumbingEntry(id: Int, name: String, pid: String, count: Int) -> String {
    """
    {"id": \(id), "name": "\(jsonEscaped(name))", "persistent_id": "\(jsonEscaped(pid))", \
    "track_count": \(count), "smart": false, "special_kind": "none"}
    """
}

private func plumbingListingWire(_ entries: [String]) -> String {
    "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

/// One already-processed group (Alpha, target "Alpha \u{2014} Merged"
/// already exists), one already-processed singleton (Beta, target
/// "Beta \u{2014} Merged" already exists), and one plain unprocessed
/// singleton (Gamma) — exercises the already-processed skip for BOTH row
/// kinds in a single fixture. The two "\u{2014} Merged" listings are
/// themselves eligible singletons (their own targets do not exist).
private func selectAllPlumbingListingWire() -> String {
    plumbingListingWire([
        plumbingEntry(id: 10, name: "Alpha", pid: "A-1", count: 3),
        plumbingEntry(id: 11, name: "Alpha", pid: "A-2", count: 4),
        plumbingEntry(id: 12, name: "Alpha \u{2014} Merged", pid: "A-DONE", count: 7),
        plumbingEntry(id: 20, name: "Beta", pid: "B-SRC", count: 2),
        plumbingEntry(id: 21, name: "Beta \u{2014} Merged", pid: "B-DONE", count: 2),
        plumbingEntry(id: 30, name: "Gamma", pid: "G-1", count: 5),
    ])
}

@MainActor
@Suite("selectAllEligible merge branch gains singletons (2026-08-11)")
struct SelectAllEligibleMergeSingletonsTests {

    @Test("select-all checks every eligible group AND singleton, skipping already-processed sources of both kinds")
    func selectsGroupsAndSingletonsSkippingProcessed() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: [selectAllPlumbingListingWire()]),
            mode: .merge, playlistName: ""
        )
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        // Alpha's target already exists: the group itself is skipped.
        #expect(model.isAlreadyProcessed(name: "Alpha"))
        // Beta's target already exists: the singleton itself is skipped.
        #expect(model.isAlreadyProcessed(name: "Beta"))

        model.selectAllEligible()

        #expect(model.checkedGroupNames.isEmpty, "Alpha is already processed")
        #expect(
            model.checkedFreeFormSingletonPersistentIds
                == Set(["A-DONE", "B-DONE", "G-1"])
        )
        #expect(!model.checkedFreeFormSingletonPersistentIds.contains("B-SRC"),
                 "Beta is already processed")
        // The consolidate tab's own selection set is untouched.
        #expect(model.checkedPersistentIds.isEmpty)
    }
}

/// One 2-copy group ("Trance 2022") plus one singleton ("Solo List") — the
/// spec's own footer example.
private func sourceCountListingWire() -> String {
    plumbingListingWire([
        plumbingEntry(id: 10, name: "Trance 2022", pid: "T-LOW", count: 3),
        plumbingEntry(id: 20, name: "Trance 2022", pid: "T-HIGH", count: 4),
        plumbingEntry(id: 5, name: "Solo List", pid: "S-SOLO", count: 2),
    ])
}

@MainActor
@Suite("mergeSelectedSourceCount (unified footer's total source count)")
struct MergeSelectedSourceCountTests {

    @Test("2-copy group + 1 singleton = 3 total source playlists")
    func footerArithmetic() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: [sourceCountListingWire()]),
            mode: .merge, playlistName: ""
        )
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value
        #expect(model.mergeSelectedSourceCount == 0)

        model.toggleCheckedGroup(name: "Trance 2022")
        #expect(model.mergeSelectedSourceCount == 2, "the group alone contributes both its copies")

        model.toggleCheckedFreeFormSingleton(persistentId: "S-SOLO")
        #expect(model.mergeSelectedSourceCount == 3)

        // Distinct from mergeCheckedCount, which counts PICKS (one per
        // checked row: 1 group + 1 singleton = 2), not source playlists.
        #expect(model.mergeCheckedCount == 2)

        model.clearSelection()
        #expect(model.mergeSelectedSourceCount == 0)
    }
}
