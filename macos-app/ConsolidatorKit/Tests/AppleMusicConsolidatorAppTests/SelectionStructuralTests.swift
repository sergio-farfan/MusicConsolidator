// SelectionStructuralTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Wave A (spec A4) — offscreen structural pins for the browser selection
// controls: Select all / Clear render on the ALL PLAYLISTS header, on both
// the merge tab (2026-08-11 unified list) and the consolidate tab ONLY,
// carry the Cmd+A / Cmd+D key equivalents, sit within the window bounds,
// and REALLY drive the model (performClick). Same harness rules as
// StructuralViewTests: never-shown NSWindow, fixture-driven model, no
// Music contact.

import AppKit
import SwiftUI
import Testing
import ConsolidatorCore
@testable import AppleMusicConsolidatorApp

private func selectionStructuralEntry(id: Int, name: String, pid: String, count: Int) -> String {
    """
    {"id": \(id), "name": "\(name)", "persistent_id": "\(pid)", \
    "track_count": \(count), "smart": false, "special_kind": "none"}
    """
}

/// Same shape as StructuralViewTests' fixture: one 2-copy group, one
/// trailing-space near-match pair, two plain singletons -> groups=1,
/// singletons=4 (S-C, S-D, S-E, S-F checkable on the consolidate tab).
private func selectionStructuralWire() -> String {
    let entries = [
        selectionStructuralEntry(id: 10, name: "Trance 2022", pid: "S-A", count: 9),
        selectionStructuralEntry(id: 20, name: "Trance 2022", pid: "S-B", count: 10),
        selectionStructuralEntry(id: 30, name: "Kdrama", pid: "S-C", count: 7),
        selectionStructuralEntry(id: 40, name: "Kdrama ", pid: "S-D", count: 9),
        selectionStructuralEntry(id: 50, name: "Solo List", pid: "S-E", count: 4),
        selectionStructuralEntry(id: 60, name: "Another List", pid: "S-F", count: 5),
    ]
    return "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

@MainActor
private func loadedSelectionStructuralHarness(
    mode: ConsolidatorMode
) async throws -> ModelHarness {
    let harness = try ModelHarness(
        runner: ScriptedRunner(outputs: [selectionStructuralWire()]),
        mode: mode,
        playlistName: ""
    )
    harness.model.rescanLibrary()
    await harness.model.scanTask?.value
    return harness
}

@MainActor
@Suite("Selection controls structural pins (A4)", .serialized)
struct SelectionStructuralTests {

    @Test("merge header shows Select all / Clear with key equivalents, within bounds")
    func mergeHeaderButtons() async throws {
        let harness = try await loadedSelectionStructuralHarness(mode: .merge)
        defer { harness.cleanUp() }
        let fixture = HostedFixture(
            SourceSelectionView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        let windowBox = NSRect(x: 0, y: 0, width: 1200, height: 800)

        let selectAll = try #require(
            view(under: fixture.hosting, axIdentifier: WaveAControlID.selectAll) as? NSButton
        )
        #expect(selectAll.keyEquivalent == "a")
        #expect(selectAll.keyEquivalentModifierMask.contains(.command))
        let selectAllFrame = selectAll.convert(selectAll.bounds, to: fixture.hosting)
        #expect(windowBox.contains(selectAllFrame), "Select all at \(selectAllFrame)")

        let clear = try #require(
            view(under: fixture.hosting, axIdentifier: WaveAControlID.clearChecks) as? NSButton
        )
        #expect(clear.keyEquivalent == "d")
        #expect(clear.keyEquivalentModifierMask.contains(.command))
        let clearFrame = clear.convert(clear.bounds, to: fixture.hosting)
        #expect(windowBox.contains(clearFrame), "Clear at \(clearFrame)")
    }

    @Test("consolidate header shows the buttons and they drive the model")
    func consolidateHeaderButtonsDriveModel() async throws {
        let harness = try await loadedSelectionStructuralHarness(mode: .consolidate)
        defer { harness.cleanUp() }
        let fixture = HostedFixture(
            SourceSelectionView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        let windowBox = NSRect(x: 0, y: 0, width: 1200, height: 800)

        let selectAll = try #require(
            view(under: fixture.hosting, axIdentifier: WaveAControlID.selectAll) as? NSButton
        )
        let selectAllFrame = selectAll.convert(selectAll.bounds, to: fixture.hosting)
        #expect(windowBox.contains(selectAllFrame), "Select all at \(selectAllFrame)")

        selectAll.performClick(nil)
        // Every checkable row checks: the four singletons, near-match twins
        // included; the two group members never check.
        #expect(harness.model.checkedPersistentIds == ["S-C", "S-D", "S-E", "S-F"])

        let clear = try #require(
            view(under: fixture.hosting, axIdentifier: WaveAControlID.clearChecks) as? NSButton
        )
        clear.performClick(nil)
        #expect(harness.model.checkedPersistentIds.isEmpty)
    }

    @Test("the Cleanup tab has a footer bar like the other modes: count plus batch actions, selection or not")
    func cleanupFooterMirrorsOtherModes() async throws {
        // Sergio, 2026-08-06: merge/consolidate carry a bottom bar (count +
        // primary action); Cleanup's batch controls hid in the header and
        // only with a selection. The footer renders them always.
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: [selectionStructuralWire()]),
            mode: .consolidate, playlistName: ""
        )
        defer { harness.cleanUp() }
        harness.model.setBrowserTab(.cleanup)
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value

        let fixture = HostedFixture(
            SourceSelectionView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        let windowBox = NSRect(x: 0, y: 0, width: 1200, height: 800)

        // Present and contained even with an EMPTY selection.
        let deleteSelected = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.cleanupDeleteSelected)
                as? NSButton
        )
        #expect(!deleteSelected.isEnabled, "no selection -> disabled, like Start Queue at 0")
        let deleteFrame = deleteSelected.convert(deleteSelected.bounds, to: fixture.hosting)
        #expect(windowBox.contains(deleteFrame), "Delete selected at \(deleteFrame)")
        let clear = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.cleanupClearSelection)
                as? NSButton
        )
        let clearFrame = clear.convert(clear.bounds, to: fixture.hosting)
        #expect(windowBox.contains(clearFrame), "Clear at \(clearFrame)")

        // With a selection the action enables.
        harness.model.toggleCleanupChecked("S-E")
        fixture.hosting.layoutSubtreeIfNeeded()
        let enabledDelete = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.cleanupDeleteSelected)
                as? NSButton
        )
        #expect(enabledDelete.isEnabled)
    }

    @Test("a scan launched on the Cleanup tab shows the shared scanning state, not the empty caption")
    func cleanupTabShowsScanningState() async throws {
        // Sergio, 2026-08-06: browserArea routed .cleanup straight past the
        // listingState switch, so a scan-in-flight rendered CleanupTabView's
        // "Rescan the library" empty caption inside a full-height void.
        let runner = BlockingRunner(payload: selectionStructuralWire())
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: ""
        )
        defer { harness.cleanUp() }
        harness.model.setBrowserTab(.cleanup)
        harness.model.rescanLibrary()
        guard case .scanning = harness.model.listingState else {
            Issue.record("expected a synchronous .scanning state")
            return
        }

        let fixture = HostedFixture(
            SourceSelectionView(model: harness.model), width: 1200, height: 800
        )
        let status = view(
            under: fixture.hosting,
            axIdentifier: WaveC2ControlID.browserScanningStatus
        )
        #expect(status != nil, "the shared scanning indicator renders on the Cleanup tab")
        fixture.tearDown()

        runner.proceed.signal()
        await harness.model.scanTask?.value
    }
}
