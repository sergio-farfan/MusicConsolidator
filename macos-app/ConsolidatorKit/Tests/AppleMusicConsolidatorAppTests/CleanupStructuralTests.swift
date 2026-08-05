// CleanupStructuralTests.swift
// Wave B — offscreen structural cells for the third browser tab: the
// Cleanup candidate list inside SourceSelectionView at 1200x800, geometric
// containment, a contained Refresh control, an enabled open-gate button on
// the qualified candidate and a disabled one on the disqualified (grayed)
// group. Same offscreen discipline as the M8-M11 suites; Music is never
// contacted (ScriptedRunner canned wire text only).

import AppKit
import SwiftUI
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

private let cleanupWindowBox = NSRect(x: 0, y: 0, width: 1200, height: 800)
private let planDate = Date(timeIntervalSince1970: 1_754_000_000)

/// Second (disqualified) group: two live copies, target ABSENT from the
/// live sample -> rule 1 disqualifies; the row renders grayed with reason.
private func houseCopies() -> [PlaylistSnapshot] {
    [
        PlaylistSnapshot(name: "House 2021", persistentId: "CPYDDDD000000004",
            tracks: [presentationTrack(sourceIndex: 0, databaseId: 11,
                persistentId: "T0000011", title: "Delta")]),
        PlaylistSnapshot(name: "House 2021", persistentId: "CPYEEEE000000005",
            tracks: [presentationTrack(sourceIndex: 0, databaseId: 12,
                persistentId: "T0000012", title: "Echo")]),
    ]
}

private func houseWirePlaylists() -> [String] {
    [
        wirePlaylist(id: 200, name: "House 2021", persistentId: "CPYDDDD000000004",
            tracks: [wireTrack(sourceIndex: 0, databaseId: 11,
                persistentId: "T0000011", title: "Delta")]),
        wirePlaylist(id: 210, name: "House 2021", persistentId: "CPYEEEE000000005",
            tracks: [wireTrack(sourceIndex: 0, databaseId: 12,
                persistentId: "T0000012", title: "Echo")]),
    ]
}

@MainActor
@Suite("Offscreen structural view tests (Wave B cleanup tab)", .serialized)
struct CleanupStructuralTests {

    @Test("the cleanup tab fits 1200x800 with a qualified and a disqualified group")
    func cleanupTabWithinBounds() async throws {
        // Live sample: Trance copies + verified target + House copies,
        // House target ABSENT. Wave C hotfix #2 (2026-08-05): refreshCleanup
        // is listing-only now — ONE listPlaylists() read regardless of group
        // count, so the runner needs only the `listing` wire below; listing =
        // trance listing entries + the two House rows.
        var listingEntries = [
            gateEntry(id: 10, name: cleanupGroupName, pid: "CPYAAAA000000001", count: 1),
            gateEntry(id: 20, name: cleanupGroupName, pid: "CPYBBBB000000002", count: 1),
            gateEntry(id: 30, name: cleanupGroupName, pid: "CPYCCCC000000003", count: 1),
            gateEntry(id: 100, name: cleanupTargetName, pid: "TARGET0000000001", count: 3),
        ]
        listingEntries.append(gateEntry(id: 200, name: "House 2021",
            pid: "CPYDDDD000000004", count: 1))
        listingEntries.append(gateEntry(id: 210, name: "House 2021",
            pid: "CPYEEEE000000005", count: 1))
        let listing = "{\"playlists\": [\(listingEntries.joined(separator: ", "))]}"
        let runner = ScriptedRunner(outputs: [listing])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        let utc = TimeZone(identifier: "UTC")!
        let trancePlan = try buildMergePlan(
            name: cleanupGroupName, copies: cleanupOrchestrationCopies()
        )
        let trancePaths = try writeMergeAudit(
            outputDir: harness.outputDirectory, plan: trancePlan,
            now: { planDate }, timeZone: utc
        )
        let housePlan = try buildMergePlan(name: "House 2021", copies: houseCopies())
        let housePaths = try writeMergeAudit(
            outputDir: harness.outputDirectory, plan: housePlan,
            now: { planDate }, timeZone: utc
        )

        model.setBrowserTab(.cleanup)
        #expect(model.browserTab == .cleanup)
        model.refreshCleanup()
        await model.cleanupScanTask?.value
        guard case .loaded(let candidates, _) = model.cleanupScanState else {
            Issue.record("expected .loaded, got \(model.cleanupScanState)")
            return
        }
        #expect(candidates.count == 2)
        #expect(candidates.contains { $0.disqualification != nil })

        let fixture = HostedFixture(SourceSelectionView(model: model), width: 1200, height: 800)
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)
        #expect(listContentCellCount(under: fixture.hosting) > 0)

        let refresh = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.cleanupRefresh)
        )
        let refreshFrame = refresh.convert(refresh.bounds, to: fixture.hosting)
        #expect(cleanupWindowBox.contains(refreshFrame), "\(refreshFrame)")

        let tranceGate = try #require(view(
            under: fixture.hosting,
            axIdentifier: WaveBControlID.cleanupOpenGate(artifactBasename(trancePaths.planJson))
        ) as? NSButton)
        #expect(tranceGate.isEnabled)
        let gateFrame = tranceGate.convert(tranceGate.bounds, to: fixture.hosting)
        #expect(cleanupWindowBox.contains(gateFrame), "\(gateFrame)")

        let houseGate = try #require(view(
            under: fixture.hosting,
            axIdentifier: WaveBControlID.cleanupOpenGate(artifactBasename(housePaths.planJson))
        ) as? NSButton)
        #expect(!houseGate.isEnabled, "a disqualified group must not open the gate")
    }
}
