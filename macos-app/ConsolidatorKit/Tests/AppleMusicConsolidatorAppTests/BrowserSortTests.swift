// BrowserSortTests.swift
// Browser list ordering (Sergio, 2026-08-05): the pure display-only sort,
// the model's toggle semantics, and the Cleanup tab's All-playlists section
// (general guarded deletion rows wired to the existing Wave B gate).
// Offline only.

import AppKit
import SwiftUI
import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

private struct Row: Equatable {
    let name: String
    let n: Int
}

@Suite("Browser sort (pure, display-only)")
struct BrowserSortPureTests {

    private let rows = [Row(name: "A", n: 5), Row(name: "B", n: 2),
                        Row(name: "C", n: 5), Row(name: "D", n: 1)]

    @Test("name ascending is the identity; descending is the exact reversal")
    func nameOrder() {
        #expect(applyBrowserSort(rows, key: .name, ascending: true, count: \.n) == rows)
        #expect(applyBrowserSort(rows, key: .name, ascending: false, count: \.n)
            == rows.reversed())
    }

    @Test("count sorts numerically both directions")
    func countOrder() {
        #expect(applyBrowserSort(rows, key: .count, ascending: true, count: \.n)
            .map(\.name) == ["D", "B", "A", "C"])
        #expect(applyBrowserSort(rows, key: .count, ascending: false, count: \.n)
            .map(\.name) == ["A", "C", "B", "D"])
    }

    @Test("count sort is stable: equal counts keep the incoming (name) order")
    func countStability() {
        let ties = [Row(name: "Z", n: 3), Row(name: "A", n: 3), Row(name: "M", n: 3)]
        #expect(applyBrowserSort(ties, key: .count, ascending: true, count: \.n) == ties)
        #expect(applyBrowserSort(ties, key: .count, ascending: false, count: \.n) == ties)
    }
}

@MainActor
@Suite("Browser sort toggle (model)")
struct BrowserSortModelTests {

    @Test("same key flips direction; a new key selects it ascending")
    func toggleSemantics() throws {
        let harness = try MutationGateHarness(runner: ScriptedRunner(outputs: []))
        defer { harness.cleanUp() }
        let model = harness.model
        #expect(model.browserSortKey == .name)
        #expect(model.browserSortAscending)

        model.toggleBrowserSort(.name)
        #expect(model.browserSortKey == .name)
        #expect(!model.browserSortAscending)

        model.toggleBrowserSort(.count)
        #expect(model.browserSortKey == .count)
        #expect(model.browserSortAscending)

        model.toggleBrowserSort(.count)
        #expect(!model.browserSortAscending)
    }
}

@MainActor
@Suite("Cleanup all-playlists section", .serialized)
struct CleanupAllPlaylistsTests {

    @Test("rows render with per-row delete; refused rows disable; click reaches the gate")
    func allPlaylistsRows() async throws {
        // gateListingWire carries a plain singleton (SOLO000000000001), a
        // smart playlist (SMART00000000001), and the contract-excluded
        // pilot PID — the refusal split is pinned per row.
        let runner = ScriptedRunner(outputs: [gateListingWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value
        #expect(model.loadedListing != nil)

        let fixture = HostedFixture(CleanupTabView(model: model), width: 1200, height: 800)
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)

        let plain = try #require(view(
            under: fixture.hosting,
            axIdentifier: WaveBControlID.cleanupDelete("SOLO000000000001")
        ) as? NSButton)
        #expect(plain.isEnabled)
        let box = NSRect(x: 0, y: 0, width: 1200, height: 800)
        #expect(box.contains(plain.convert(plain.bounds, to: fixture.hosting)))

        let smart = try #require(view(
            under: fixture.hosting,
            axIdentifier: WaveBControlID.cleanupDelete("SMART00000000001")
        ) as? NSButton)
        #expect(!smart.isEnabled, "smart playlists must be refused pre-gate")

        let pilot = try #require(view(
            under: fixture.hosting,
            axIdentifier: WaveBControlID.cleanupDelete("E02030832FD20B07")
        ) as? NSButton)
        #expect(!pilot.isEnabled, "contract-excluded PIDs must be refused pre-gate")

        // Click plumbing: the enabled row reaches the existing gate entry
        // (the empty runner then refuses the audit — the pin is that the
        // gate LEFT idle, exactly like the inspector's plumbing test).
        plain.performClick(nil)
        await harness.awaitMutation()
        if case .idle = model.mutationGatePhase {
            Issue.record("the Delete\u{2026} click never reached startMutationAudit")
        }
    }

    @Test("sort headers present; clicking Tracks switches the model key")
    func sortHeaderPlumbing() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        let fixture = HostedFixture(CleanupTabView(model: model), width: 1200, height: 800)
        defer { fixture.tearDown() }
        let tracks = try #require(view(
            under: fixture.hosting, axIdentifier: WaveBControlID.sortByCount
        ) as? NSButton)
        tracks.performClick(nil)
        #expect(model.browserSortKey == .count)
        #expect(model.browserSortAscending)
    }
}
