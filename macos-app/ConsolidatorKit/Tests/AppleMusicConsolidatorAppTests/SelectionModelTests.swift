// SelectionModelTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Wave A (spec A4) — the browser multi-selection model: per-tab select-all
// eligibility, the shift-click anchor lifecycle (every direct click
// re-anchors; rescan and mode switch clear it), and toggleChecked's range
// routing through applyRangeToggle. All Music I/O is canned listing wire
// through ScriptedRunner; nothing executes any script.

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

    @Test("merge select-all checks every mergeable group name and nothing else")
    func mergeSelectAllEligibility() async throws {
        let harness = try await loadedSelectionHarness(mode: .merge)
        defer { harness.cleanUp() }

        harness.model.selectAllEligible()

        #expect(harness.model.checkedGroupNames == ["Alpha", "Beta", "Gamma"])
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

    @Test("merge shift-click ranges over the group section; non-groups are refused")
    func mergeRangeRouting() async throws {
        let harness = try await loadedSelectionHarness(mode: .merge)
        defer { harness.cleanUp() }

        harness.model.toggleChecked(name: "Alpha", rangeSelect: false)
        harness.model.toggleChecked(name: "Gamma", rangeSelect: true)
        #expect(harness.model.checkedGroupNames == ["Alpha", "Beta", "Gamma"])
        #expect(harness.model.selectionAnchor == "Gamma")

        // A near-match singleton is not a mergeable group: refused, checks
        // and anchor unchanged.
        harness.model.toggleChecked(name: "Delta", rangeSelect: false)
        #expect(harness.model.checkedGroupNames == ["Alpha", "Beta", "Gamma"])
        #expect(harness.model.selectionAnchor == "Gamma")
    }
}
