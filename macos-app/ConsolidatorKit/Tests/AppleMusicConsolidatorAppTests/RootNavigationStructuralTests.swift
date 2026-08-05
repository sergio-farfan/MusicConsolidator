// RootNavigationStructuralTests.swift
// Wave C2 Task 6 — the destination root (spec C2.5): four sidebar
// destination rows (present, contained, lock-aware), the live Activity
// chip, and per-destination detail spot-checks. Offscreen at 1200x800;
// fixture-driven injectable models (the root must never read the real
// defaults or listing cache); Music never contacted.

import AppKit
import SwiftUI
import Testing
@testable import AppleMusicConsolidatorApp

private let rootWindowBox = NSRect(x: 0, y: 0, width: 1200, height: 800)

private func rootListingWire() -> String {
    """
    {"playlists": [{"id": 10, "name": "Fixture List", "persistent_id": "P-A", \
    "track_count": 4, "smart": false, "special_kind": "none"}]}
    """
}

@MainActor
@Suite("Wave C2 root navigation", .serialized)
struct RootNavigationStructuralTests {

    @Test("the sidebar renders exactly the four destination rows, contained; the split fits")
    func destinationRowsRender() throws {
        let harness = try ModelHarness(runner: ScriptedRunner(outputs: []))
        defer { harness.cleanUp() }
        let fixture = HostedFixture(
            ConsolidatorFlowView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }

        for destination in AppDestination.allCases {
            let row = try #require(
                view(
                    under: fixture.hosting,
                    axIdentifier: WaveC2ControlID.destinationRow(destination)
                ) as? NSButton,
                "\(destination.rawValue) row missing"
            )
            let frame = row.convert(row.bounds, to: fixture.hosting)
            #expect(rootWindowBox.contains(frame), "\(destination.rawValue) row at \(frame)")
            #expect(row.isEnabled, "\(destination.rawValue) row enabled while idle")
        }
        // No grayed step rows exist anywhere: the only wc2.dest.* buttons
        // are the four destinations (the old rail had five unidentified
        // rows; its test is deleted with it).
        let destinationButtons = allViews(under: fixture.hosting)
            .compactMap { $0 as? NSButton }
            .filter { $0.accessibilityIdentifier().hasPrefix("wc2.dest.") }
        #expect(destinationButtons.count == 4)

        // Geometry sanity: window height + the calibrated 32 pt
        // unified-toolbar band the never-shown NavigationSplitView reserves
        // (the old flow-rail pin's allowance, rebased to 800).
        #expect(fixture.hosting.frame.height <= 840)
        for split in allViews(under: fixture.hosting).compactMap({ $0 as? NSSplitView }) {
            #expect(split.frame.height <= 840, "split view height \(split.frame.height)")
        }
    }

    @Test("the detail follows the selected destination, never the flow step")
    func detailFollowsDestination() async throws {
        let runner = ScriptedRunner(
            outputs: [rootListingWire(), consolidateFixtureWire()]
        )
        // Attended queue (harness default confirmEachApply true).
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-A")
        harness.model.startQueue()
        await harness.awaitAudit()
        #expect(harness.model.step == .review)
        #expect(harness.model.selectedDestination == .activity, "auto-selected by the queue")

        let fixture = HostedFixture(
            ConsolidatorFlowView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        // Activity: the staged panel hosts the plan review.
        #expect(view(under: fixture.hosting, axIdentifier: WaveC2ControlID.stageReview) != nil)
        #expect(view(under: fixture.hosting, axIdentifier: M8ControlID.continueToGate) != nil)

        // Library while step == .review: the browser renders — the detail
        // keys on the destination; the sequencer is untouched.
        let libraryRow = try #require(
            view(
                under: fixture.hosting,
                axIdentifier: WaveC2ControlID.destinationRow(.library)
            ) as? NSButton
        )
        libraryRow.performClick(nil)
        #expect(harness.model.selectedDestination == .library)
        #expect(harness.model.step == .review, "navigation never moves the step")
        fixture.pump()
        #expect(view(under: fixture.hosting, axIdentifier: M8ControlID.scanLibrary) != nil)

        // Reports hosts the history browser (over the harness temp dir —
        // hermetic by construction).
        let reportsRow = try #require(
            view(
                under: fixture.hosting,
                axIdentifier: WaveC2ControlID.destinationRow(.reports)
            ) as? NSButton
        )
        reportsRow.performClick(nil)
        fixture.pump()
        #expect(view(under: fixture.hosting, axIdentifier: M11ControlID.historyFilter) != nil)

        // Settings hosts the relocated panel.
        let settingsRow = try #require(
            view(
                under: fixture.hosting,
                axIdentifier: WaveC2ControlID.destinationRow(.settings)
            ) as? NSButton
        )
        settingsRow.performClick(nil)
        fixture.pump()
        #expect(view(under: fixture.hosting, axIdentifier: M11ControlID.confirmEachApply) != nil)
    }

    @Test("hot lock: rows disable, Activity stays enabled, the sidebar chip goes live")
    func lockedRowsRenderDisabled() async throws {
        let runner = StagedBlockingRunner(
            outputs: [rootListingWire(), consolidateFixtureWire()]
                + consolidateApplyOutputs(),
            blockAt: [1]
        )
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false
        )
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-A")
        harness.model.startQueue()
        #expect(await pollUntil { runner.runCount == 2 })
        #expect(harness.model.isDestinationLocked)

        let fixture = HostedFixture(
            ConsolidatorFlowView(model: harness.model), width: 1200, height: 800
        )
        var enabledByDestination: [AppDestination: Bool] = [:]
        for destination in AppDestination.allCases {
            let row = view(
                under: fixture.hosting,
                axIdentifier: WaveC2ControlID.destinationRow(destination)
            ) as? NSButton
            enabledByDestination[destination] = row?.isEnabled
        }
        // The Activity row's chip is the only sidebar spinner while hot.
        let sidebarHosts = views(
            under: fixture.hosting, classNameContains: "SidebarStyleContext"
        )
        let sidebarSpinners = sidebarHosts.reduce(0) {
            $0 + views(under: $1, classNameContains: "ProgressIndicator").count
        }
        fixture.tearDown()

        // Release the held read BEFORE asserting so a failure cannot strand
        // the detached pipeline.
        runner.proceed.signal()
        #expect(await pollUntil { harness.model.finishedRunReport != nil })

        #expect(enabledByDestination[.activity] == true)
        #expect(enabledByDestination[.library] == false)
        #expect(enabledByDestination[.reports] == false)
        #expect(enabledByDestination[.settings] == false)
        #expect(sidebarSpinners >= 1, "the Activity chip must spin during the run")
    }

    // Fix-before-close (final review, parked-item triage): SwiftUI's
    // `.help(_:)` never reaches an NSViewRepresentable's NSButton, so the
    // hot-lock's ONLY explanation for a disabled destination row must ride
    // through AppKitActionButton's own `help:` parameter instead.
    @Test("a locked destination row's NSButton toolTip carries destinationBlockedReason")
    func lockedRowCarriesToolTip() async throws {
        let runner = StagedBlockingRunner(
            outputs: [rootListingWire(), consolidateFixtureWire()]
                + consolidateApplyOutputs(),
            blockAt: [1]
        )
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false
        )
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-A")
        harness.model.startQueue()
        #expect(await pollUntil { runner.runCount == 2 })
        #expect(harness.model.isDestinationLocked)

        let fixture = HostedFixture(
            ConsolidatorFlowView(model: harness.model), width: 1200, height: 800
        )
        let libraryRow = view(
            under: fixture.hosting, axIdentifier: WaveC2ControlID.destinationRow(.library)
        ) as? NSButton
        let toolTip = libraryRow?.toolTip
        let expectedReason = harness.model.destinationBlockedReason(for: .library)
        fixture.tearDown()

        runner.proceed.signal()
        #expect(await pollUntil { harness.model.finishedRunReport != nil })

        #expect(toolTip == "Wait for the running check to finish.")
        #expect(toolTip == expectedReason)
    }
}
