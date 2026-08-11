// SelectionModelTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Wave A (spec A4) — the browser multi-selection model: per-tab select-all
// eligibility, the shift-click anchor lifecycle (every direct click
// re-anchors; rescan and mode switch clear it), and toggleChecked's range
// routing through applyRangeToggle. All Music I/O is canned listing wire
// through ScriptedRunner; nothing executes any script.
//
// 2026-08-11 final review, findings I4/I5: the merge tab's range walks the
// DISPLAYED UNIFIED ROWS (`mergeRows`) through `applyMergeRangeToggle`, so a
// single range crosses group and singleton rows and writes each crossed row
// into its own container (`checkedGroupNames` /
// `checkedFreeFormSingletonPersistentIds`) off ONE shared anchor. The
// select-all and group-range tests below now assert that third set too — the
// gap finding I5 named.

import Foundation
import Testing
import ConsolidatorCore
@testable import AppleMusicConsolidatorApp

// MARK: - listing fixture

private func selectionEntry(id: Int, name: String, pid: String, count: Int = 5) -> String {
    """
    {"id": \(id), "name": "\(jsonEscaped(name))", "persistent_id": "\(jsonEscaped(pid))", \
    "track_count": \(count), "smart": false, "special_kind": "none"}
    """
}

/// Three mergeable groups (Alpha, Beta, Gamma — alphabetical section
/// order), one trailing-space near-match pair (Delta / "Delta ", both
/// singletons), and two plain singletons. Consolidate-tab checkable display
/// order: D-1, D-2, E-1, F-1 (group members are never checkable).
///
/// The MERGE tab's unified display order (2026-08-11 `mergeRows`, the range
/// order since finding I4) interleaves both kinds:
/// `Alpha, Beta, D-1, D-2, E-1, F-1, Gamma`.
private func selectionListingWire() -> String {
    let entries = [
        selectionEntry(id: 10, name: "Alpha", pid: "A-1"),
        selectionEntry(id: 20, name: "Alpha", pid: "A-2"),
        selectionEntry(id: 30, name: "Beta", pid: "B-1"),
        selectionEntry(id: 40, name: "Beta", pid: "B-2"),
        selectionEntry(id: 50, name: "Gamma", pid: "G-1"),
        selectionEntry(id: 60, name: "Gamma", pid: "G-2"),
        selectionEntry(id: 70, name: "Delta", pid: "D-1"),
        selectionEntry(id: 80, name: "Delta ", pid: "D-2"),
        selectionEntry(id: 90, name: "Echo", pid: "E-1"),
        selectionEntry(id: 100, name: "Foxtrot", pid: "F-1"),
    ]
    return "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

/// A library with ZERO same-name groups — Sergio's real shape (333 singletons,
/// 0 groups, 2026-08-11): every merge-tab range must work here, which the
/// groups-only range order made impossible (finding I4).
private func singletonOnlyListingWire() -> String {
    let entries = [
        selectionEntry(id: 10, name: "Alpha", pid: "A-1"),
        selectionEntry(id: 20, name: "Beta", pid: "B-1"),
        selectionEntry(id: 30, name: "Echo", pid: "E-1"),
        selectionEntry(id: 40, name: "Foxtrot", pid: "F-1"),
    ]
    return "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

@MainActor
private func loadedSelectionHarness(
    mode: ConsolidatorMode,
    outputs: [String] = [selectionListingWire()]
) async throws -> ModelHarness {
    let harness = try ModelHarness(
        runner: ScriptedRunner(outputs: outputs), mode: mode, playlistName: ""
    )
    harness.model.rescanLibrary()
    await harness.model.scanTask?.value
    return harness
}

@MainActor
@Suite("Browser multi-selection model (A4)")
struct SelectionModelTests {

    // Finding I5: the title and assertions used to claim "and nothing else"
    // while never looking at the THIRD selection set the unified merge list
    // writes — `checkedFreeFormSingletonPersistentIds`, which select-all has
    // filled since 2026-08-11. Both are pinned here now.
    @Test("merge select-all checks every mergeable group AND every eligible singleton; the consolidate set stays empty")
    func mergeSelectAllEligibility() async throws {
        let harness = try await loadedSelectionHarness(mode: .merge)
        defer { harness.cleanUp() }

        harness.model.selectAllEligible()

        #expect(harness.model.checkedGroupNames == ["Alpha", "Beta", "Gamma"])
        #expect(
            harness.model.checkedFreeFormSingletonPersistentIds
                == Set(["D-1", "D-2", "E-1", "F-1"]),
            "every singleton, near-match twins included, is an eligible free-form source"
        )
        #expect(harness.model.checkedPersistentIds.isEmpty)
    }

    @Test("consolidate select-all checks every singleton including near-match twins")
    func consolidateSelectAllEligibility() async throws {
        let harness = try await loadedSelectionHarness(mode: .consolidate)
        defer { harness.cleanUp() }

        harness.model.selectAllEligible()

        #expect(harness.model.checkedPersistentIds == ["D-1", "D-2", "E-1", "F-1"])
        #expect(harness.model.checkedGroupNames.isEmpty)
    }

    @Test("select-all respects the active filter (only displayed rows check)")
    func selectAllRespectsFilter() async throws {
        let harness = try await loadedSelectionHarness(mode: .merge)
        defer { harness.cleanUp() }

        harness.model.searchText = "alp"
        harness.model.selectAllEligible()

        #expect(harness.model.checkedGroupNames == ["Alpha"])
        #expect(
            harness.model.checkedFreeFormSingletonPersistentIds.isEmpty,
            "no singleton's name matches the filter, so none checks"
        )
    }

    @Test("clear clears the active tab's checks and the anchor; the other tab survives")
    func clearScopedToActiveTab() async throws {
        let harness = try await loadedSelectionHarness(mode: .consolidate)
        defer { harness.cleanUp() }

        harness.model.toggleChecked(persistentId: "E-1")
        #expect(harness.model.selectionAnchor == "E-1")
        harness.model.setMode(.merge)
        harness.model.toggleChecked(name: "Alpha", rangeSelect: false)

        harness.model.clearSelection()

        #expect(harness.model.checkedGroupNames.isEmpty)
        #expect(harness.model.selectionAnchor == nil)
        // The consolidate tab's checks are mode-independent and survive
        // (setMode's documented contract).
        #expect(harness.model.checkedPersistentIds == ["E-1"])
    }

    @Test("every direct click re-anchors; rescan and mode switch clear the anchor")
    func anchorLifecycle() async throws {
        let harness = try await loadedSelectionHarness(
            mode: .consolidate,
            outputs: [selectionListingWire(), selectionListingWire()]
        )
        defer { harness.cleanUp() }

        harness.model.toggleChecked(persistentId: "D-1")
        #expect(harness.model.selectionAnchor == "D-1")
        harness.model.toggleChecked(persistentId: "E-1")
        #expect(harness.model.selectionAnchor == "E-1")

        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        #expect(harness.model.selectionAnchor == nil)

        harness.model.toggleChecked(persistentId: "F-1")
        #expect(harness.model.selectionAnchor == "F-1")
        harness.model.setMode(.merge)
        #expect(harness.model.selectionAnchor == nil)
    }

    @Test("consolidate shift-click ranges over the displayed checkable order")
    func consolidateRangeRouting() async throws {
        let harness = try await loadedSelectionHarness(mode: .consolidate)
        defer { harness.cleanUp() }

        harness.model.toggleChecked(persistentId: "D-1")
        harness.model.toggleChecked(persistentId: "F-1", rangeSelect: true)
        #expect(harness.model.checkedPersistentIds == ["D-1", "D-2", "E-1", "F-1"])
        #expect(harness.model.selectionAnchor == "F-1")

        // Shift-click on a CHECKED row: the whole range takes the clicked
        // row's new (unchecked) state; D-1 sits outside [D-2, F-1] and
        // survives.
        harness.model.toggleChecked(persistentId: "D-2", rangeSelect: true)
        #expect(harness.model.checkedPersistentIds == ["D-1"])
        #expect(harness.model.selectionAnchor == "D-2")
    }

    // Finding I5: this test's old title claimed the range walks "the group
    // section" — it walks the DISPLAYED UNIFIED ROWS since finding I4, so a
    // group-to-group range crosses the singleton rows between them and checks
    // each into its own set. Scoped to the GROUP entry point here; the mixed
    // and singleton entry points get their own tests below.
    @Test("merge shift-click from a GROUP row ranges over the displayed unified rows; a non-group name is refused")
    func mergeRangeRouting() async throws {
        let harness = try await loadedSelectionHarness(mode: .merge)
        defer { harness.cleanUp() }

        harness.model.toggleChecked(name: "Alpha", rangeSelect: false)
        harness.model.toggleChecked(name: "Gamma", rangeSelect: true)
        #expect(harness.model.checkedGroupNames == ["Alpha", "Beta", "Gamma"])
        // Alpha -> Gamma spans the WHOLE unified list, so the four singleton
        // rows between them check into their own set (finding I4).
        #expect(
            harness.model.checkedFreeFormSingletonPersistentIds
                == Set(["D-1", "D-2", "E-1", "F-1"])
        )
        #expect(harness.model.selectionAnchor == "Gamma")

        // A near-match singleton is not a mergeable group: refused, checks
        // and anchor unchanged.
        harness.model.toggleChecked(name: "Delta", rangeSelect: false)
        #expect(harness.model.checkedGroupNames == ["Alpha", "Beta", "Gamma"])
        #expect(
            harness.model.checkedFreeFormSingletonPersistentIds
                == Set(["D-1", "D-2", "E-1", "F-1"])
        )
        #expect(harness.model.selectionAnchor == "Gamma")
    }

    // MARK: mixed-kind ranges over the unified merge rows (finding I4)

    @Test("a merge range spanning group and singleton rows checks each crossed row into its own set")
    func mergeMixedRangeChecksBothSets() async throws {
        let harness = try await loadedSelectionHarness(mode: .merge)
        defer { harness.cleanUp() }
        let model = harness.model

        // Anchor on a GROUP row, then shift-click a SINGLETON row: the span
        // Alpha..E-1 covers Alpha, Beta (groups) and D-1, D-2, E-1
        // (singletons); Foxtrot and Gamma sit outside it.
        model.toggleChecked(name: "Alpha", rangeSelect: false)
        #expect(model.selectionAnchor == "Alpha")
        model.toggleCheckedFreeFormSingleton(persistentId: "E-1", rangeSelect: true)

        #expect(model.checkedGroupNames == ["Alpha", "Beta"])
        #expect(model.checkedFreeFormSingletonPersistentIds == Set(["D-1", "D-2", "E-1"]))
        #expect(model.selectionAnchor == "E-1", "the anchor is the last clicked row of EITHER kind")
        // Display order, not check order: 2 group copies each + 3 singletons.
        #expect(model.mergeSelectedSourceCount == 7)
        // The consolidate tab's own set never sees a merge-tab range.
        #expect(model.checkedPersistentIds.isEmpty)
    }

    @Test("a merge range anchored on a SINGLETON row unchecks back across both kinds")
    func mergeMixedRangeUnchecksBothSets() async throws {
        let harness = try await loadedSelectionHarness(mode: .merge)
        defer { harness.cleanUp() }
        let model = harness.model

        model.selectAllEligible()
        #expect(model.checkedGroupNames == ["Alpha", "Beta", "Gamma"])

        // One plain click on the LAST singleton row (F-1) plants the anchor
        // there (and unchecks F-1). Shift-clicking back to the Beta GROUP row
        // takes Beta's new state — UNCHECK, since select-all checked it — so
        // the whole Beta..F-1 span clears across both kinds; Alpha and Gamma
        // sit outside the span and survive.
        model.toggleCheckedFreeFormSingleton(persistentId: "F-1")
        #expect(model.checkedFreeFormSingletonPersistentIds == Set(["D-1", "D-2", "E-1"]))
        #expect(model.selectionAnchor == "F-1")
        model.toggleChecked(name: "Beta", rangeSelect: true)

        #expect(model.checkedGroupNames == ["Alpha", "Gamma"])
        #expect(model.checkedFreeFormSingletonPersistentIds.isEmpty)
        #expect(model.selectionAnchor == "Beta")
    }

    @Test("merge ranges work on a library with ZERO groups (the 333-singleton shape)")
    func mergeRangeWithNoGroups() async throws {
        let harness = try await loadedSelectionHarness(
            mode: .merge, outputs: [singletonOnlyListingWire()]
        )
        defer { harness.cleanUp() }
        let model = harness.model

        model.toggleCheckedFreeFormSingleton(persistentId: "A-1")
        #expect(model.checkedFreeFormSingletonPersistentIds == Set(["A-1"]))
        #expect(model.selectionAnchor == "A-1")

        model.toggleCheckedFreeFormSingleton(persistentId: "F-1", rangeSelect: true)
        #expect(
            model.checkedFreeFormSingletonPersistentIds == Set(["A-1", "B-1", "E-1", "F-1"]),
            "the range covers every displayed singleton row"
        )
        #expect(model.checkedGroupNames.isEmpty)
        #expect(model.selectionAnchor == "F-1")
    }

    @Test("a merge range respects the active filter (hidden checks of both kinds survive)")
    func mergeRangeRespectsFilter() async throws {
        let harness = try await loadedSelectionHarness(mode: .merge)
        defer { harness.cleanUp() }
        let model = harness.model

        // Check Gamma and Foxtrot while everything is displayed...
        model.toggleChecked(name: "Gamma", rangeSelect: false)
        model.toggleCheckedFreeFormSingleton(persistentId: "F-1")

        // ...then filter down to the Delta twins and range across them: the
        // hidden Gamma/F-1 checks are untouched.
        model.searchText = "delta"
        model.toggleCheckedFreeFormSingleton(persistentId: "D-1")
        model.toggleCheckedFreeFormSingleton(persistentId: "D-2", rangeSelect: true)

        #expect(model.checkedGroupNames == ["Gamma"])
        #expect(model.checkedFreeFormSingletonPersistentIds == Set(["F-1", "D-1", "D-2"]))
    }
}
