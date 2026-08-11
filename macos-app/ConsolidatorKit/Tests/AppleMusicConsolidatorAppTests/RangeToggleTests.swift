// RangeToggleTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Wave A (spec A4) — the pure shift-click range toggle. No UI, no model,
// no Music: applyRangeToggle is a value-level function over row ids.
//
// 2026-08-11 final review, finding I4: plus `applyMergeRangeToggle`, the
// two-container variant the unified merge list needs — one range over the
// DISPLAYED rows, group names into `checkedGroupNames` and singleton
// persistent IDs into `checkedFreeFormSingletonPersistentIds`, same anchor
// semantics as above.

import Testing
import ConsolidatorCore
@testable import AppleMusicConsolidatorApp

@Suite("Shift-click range toggle (A4)")
struct RangeToggleTests {

    private let ordered = ["r1", "r2", "r3", "r4", "r5"]

    @Test("nil anchor is a plain toggle and establishes the anchor")
    func nilAnchorPlainToggle() {
        let checked = applyRangeToggle(
            anchor: nil, clicked: "r3", orderedIDs: ordered, current: []
        )
        #expect(checked.selection == ["r3"])
        #expect(checked.newAnchor == "r3")

        let unchecked = applyRangeToggle(
            anchor: nil, clicked: "r3", orderedIDs: ordered, current: ["r3", "r5"]
        )
        #expect(unchecked.selection == ["r5"])
        #expect(unchecked.newAnchor == "r3")
    }

    @Test("forward range applies to every row from anchor to clicked, inclusive")
    func forwardRange() {
        let outcome = applyRangeToggle(
            anchor: "r2", clicked: "r4", orderedIDs: ordered, current: ["r2"]
        )
        #expect(outcome.selection == ["r2", "r3", "r4"])
        #expect(outcome.newAnchor == "r4")
    }

    @Test("backward range covers the same inclusive range")
    func backwardRange() {
        let outcome = applyRangeToggle(
            anchor: "r4", clicked: "r2", orderedIDs: ordered, current: ["r4"]
        )
        #expect(outcome.selection == ["r2", "r3", "r4"])
        #expect(outcome.newAnchor == "r2")
    }

    @Test("the range takes the clicked row's NEW state in both directions")
    func rangeTakesClickedNewState() {
        // Clicked r4 is currently checked -> newState is UNCHECK: the whole
        // range unchecks; r5 (outside the range) survives.
        let uncheck = applyRangeToggle(
            anchor: "r1", clicked: "r4", orderedIDs: ordered,
            current: ["r1", "r3", "r4", "r5"]
        )
        #expect(uncheck.selection == ["r5"])
        #expect(uncheck.newAnchor == "r4")

        // Clicked r4 is currently unchecked -> newState is CHECK: the whole
        // range checks, including rows that were already checked.
        let check = applyRangeToggle(
            anchor: "r1", clicked: "r4", orderedIDs: ordered, current: ["r2"]
        )
        #expect(check.selection == ["r1", "r2", "r3", "r4"])
        #expect(check.newAnchor == "r4")
    }

    @Test("an anchor missing from orderedIDs degrades to a plain toggle")
    func anchorMissingFromOrder() {
        let outcome = applyRangeToggle(
            anchor: "gone", clicked: "r2", orderedIDs: ordered, current: []
        )
        #expect(outcome.selection == ["r2"])
        #expect(outcome.newAnchor == "r2")
    }

    @Test("a clicked id missing from orderedIDs degrades to a plain toggle")
    func clickedMissingFromOrder() {
        let outcome = applyRangeToggle(
            anchor: "r1", clicked: "ghost", orderedIDs: ordered, current: ["r1"]
        )
        #expect(outcome.selection == ["r1", "ghost"])
        #expect(outcome.newAnchor == "ghost")
    }

    @Test("anchor equal to clicked toggles exactly that one row")
    func anchorEqualsClicked() {
        let outcome = applyRangeToggle(
            anchor: "r3", clicked: "r3", orderedIDs: ordered, current: []
        )
        #expect(outcome.selection == ["r3"])
        #expect(outcome.newAnchor == "r3")
    }

    @Test("the returned anchor is ALWAYS the clicked id")
    func newAnchorAlwaysClicked() {
        for (anchor, clicked) in [(nil, "r1"), ("r1", "r5"), ("r5", "r1"), ("zz", "r2")]
            as [(String?, String)] {
            let outcome = applyRangeToggle(
                anchor: anchor, clicked: clicked, orderedIDs: ordered, current: []
            )
            #expect(outcome.newAnchor == clicked)
        }
    }
}

// MARK: - the unified merge rows' two-container range (finding I4)

private func rangeListing(id: Double, name: String, pid: String) -> PlaylistListing {
    PlaylistListing(
        playlistId: id, name: name, persistentId: pid,
        trackCount: 3, isSmart: false, specialKind: "none"
    )
}

/// Display order `Alpha (group), Beta (singleton), Charlie (group), Delta
/// (singleton)` — every adjacency a mixed range can hit.
private func mixedRows() -> [MergeBrowserRow] {
    mergeRows(
        sections: buildPlaylistBrowseSections(from: [
            rangeListing(id: 10, name: "Alpha", pid: "A-1"),
            rangeListing(id: 11, name: "Alpha", pid: "A-2"),
            rangeListing(id: 20, name: "Beta", pid: "B-1"),
            rangeListing(id: 30, name: "Charlie", pid: "C-1"),
            rangeListing(id: 31, name: "Charlie", pid: "C-2"),
            rangeListing(id: 40, name: "Delta", pid: "D-1"),
        ]),
        needle: "", key: .name, ascending: true
    )
}

@Suite("Shift-click range over the unified merge rows (I4)")
struct MergeRangeToggleTests {

    @Test("the fixture's display order really does interleave both kinds")
    func fixtureOrder() {
        #expect(mixedRows().map(\.id) == ["Alpha", "B-1", "Charlie", "D-1"])
    }

    @Test("a nil anchor is a plain toggle of the clicked row, whatever its kind")
    func nilAnchorPlainToggle() {
        let group = applyMergeRangeToggle(
            anchor: nil, clicked: "Charlie", rows: mixedRows(),
            checkedGroupNames: [], checkedSingletonIds: []
        )
        #expect(group.groupNames == ["Charlie"])
        #expect(group.singletonIds.isEmpty)
        #expect(group.newAnchor == "Charlie")

        let singleton = applyMergeRangeToggle(
            anchor: nil, clicked: "D-1", rows: mixedRows(),
            checkedGroupNames: [], checkedSingletonIds: []
        )
        #expect(singleton.groupNames.isEmpty)
        #expect(singleton.singletonIds == ["D-1"])
        #expect(singleton.newAnchor == "D-1")
    }

    @Test("a range across both kinds checks every crossed row into its own container")
    func mixedRangeChecks() {
        let outcome = applyMergeRangeToggle(
            anchor: "Alpha", clicked: "D-1", rows: mixedRows(),
            checkedGroupNames: ["Alpha"], checkedSingletonIds: []
        )
        #expect(outcome.groupNames == ["Alpha", "Charlie"])
        #expect(outcome.singletonIds == ["B-1", "D-1"])
        #expect(outcome.newAnchor == "D-1")
    }

    @Test("the range takes the clicked row's NEW state; rows outside it survive")
    func rangeTakesClickedNewState() {
        // Clicked Charlie is checked -> the whole Alpha..Charlie span
        // unchecks; D-1, outside the span, survives.
        let outcome = applyMergeRangeToggle(
            anchor: "Alpha", clicked: "Charlie", rows: mixedRows(),
            checkedGroupNames: ["Alpha", "Charlie"], checkedSingletonIds: ["B-1", "D-1"]
        )
        #expect(outcome.groupNames.isEmpty)
        #expect(outcome.singletonIds == ["D-1"])
        #expect(outcome.newAnchor == "Charlie")
    }

    @Test("backward ranges cover the same inclusive span")
    func backwardRange() {
        let outcome = applyMergeRangeToggle(
            anchor: "D-1", clicked: "B-1", rows: mixedRows(),
            checkedGroupNames: [], checkedSingletonIds: ["D-1"]
        )
        #expect(outcome.groupNames == ["Charlie"])
        #expect(outcome.singletonIds == ["B-1", "D-1"])
        #expect(outcome.newAnchor == "B-1")
    }

    @Test("checks hidden from the displayed rows survive, in order, ahead of the displayed ones")
    func hiddenChecksSurvive() {
        // "Zulu" is checked but not displayed (filtered out): it must keep
        // its check and lead the reconciled array, exactly as the
        // pre-unification group-only reconciliation did.
        let outcome = applyMergeRangeToggle(
            anchor: nil, clicked: "Alpha", rows: mixedRows(),
            checkedGroupNames: ["Zulu"], checkedSingletonIds: ["Z-9"]
        )
        #expect(outcome.groupNames == ["Zulu", "Alpha"])
        #expect(outcome.singletonIds == ["Z-9"])
    }

    @Test("an anchor missing from the displayed rows degrades to a plain toggle")
    func anchorMissing() {
        let outcome = applyMergeRangeToggle(
            anchor: "gone", clicked: "Charlie", rows: mixedRows(),
            checkedGroupNames: [], checkedSingletonIds: []
        )
        #expect(outcome.groupNames == ["Charlie"])
        #expect(outcome.singletonIds.isEmpty)
        #expect(outcome.newAnchor == "Charlie")
    }

    @Test("a clicked id absent from the displayed rows changes nothing and still re-anchors")
    func clickedMissing() {
        let outcome = applyMergeRangeToggle(
            anchor: "Alpha", clicked: "ghost", rows: mixedRows(),
            checkedGroupNames: ["Alpha"], checkedSingletonIds: ["B-1"]
        )
        #expect(outcome.groupNames == ["Alpha"])
        #expect(outcome.singletonIds == ["B-1"])
        #expect(outcome.newAnchor == "ghost")
    }

    @Test("a singleton-only row set ranges fine (the 0-group library)")
    func singletonOnlyRows() {
        let rows = mergeRows(
            sections: buildPlaylistBrowseSections(from: [
                rangeListing(id: 10, name: "Alpha", pid: "A-1"),
                rangeListing(id: 20, name: "Beta", pid: "B-1"),
                rangeListing(id: 30, name: "Charlie", pid: "C-1"),
            ]),
            needle: "", key: .name, ascending: true
        )
        let outcome = applyMergeRangeToggle(
            anchor: "A-1", clicked: "C-1", rows: rows,
            checkedGroupNames: [], checkedSingletonIds: ["A-1"]
        )
        #expect(outcome.singletonIds == ["A-1", "B-1", "C-1"])
        #expect(outcome.groupNames.isEmpty)
    }

    @Test("group membership is scalar-exact: an NFD twin name is never crossed by accident")
    func scalarExactGroupMembership() {
        // "Café" NFC and "Café" NFD are DISTINCT exact-name groups that
        // compare equal under String ==; a Set<String>-based range would
        // merge them.
        let nfc = "Caf\u{E9}"
        let nfd = "Cafe\u{301}"
        let rows = mergeRows(
            sections: buildPlaylistBrowseSections(from: [
                rangeListing(id: 10, name: nfc, pid: "N-1"),
                rangeListing(id: 11, name: nfc, pid: "N-2"),
                rangeListing(id: 20, name: nfd, pid: "D-1"),
                rangeListing(id: 21, name: nfd, pid: "D-2"),
            ]),
            needle: "", key: .name, ascending: true
        )
        #expect(rows.count == 2, "two distinct exact-name groups")
        let outcome = applyMergeRangeToggle(
            anchor: nil, clicked: nfc, rows: rows,
            checkedGroupNames: [], checkedSingletonIds: []
        )
        #expect(outcome.groupNames.count == 1)
        #expect(scalarExact(outcome.groupNames[0], nfc))
    }
}
