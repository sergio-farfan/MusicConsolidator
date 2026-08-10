// WaveCRunReportSurfaceTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Wave C1 Task 5 — the run-report screen (the live surface backed by
// RunItemRecords, spec C1.4/C1.5): failed items render the two additive
// lines, the guidance, and the delete shortcut; refusedBeforeWrite items
// render neither the leftover line nor the shortcut; the shortcut's click
// plumbing reaches startMutationAudit. Offscreen at 1200x800; offline.
//
// Fix round 1 (combined Task 4+5 review): the report renders one outcome
// PER ROW, unlike the attended failure screen's single outcome — every
// control here is keyed by the row's item name (WaveCControlID.report*),
// and the shared resolve spinner/notice must attach to its OWN row only.
// The acknowledgeRunReport()/isMutationBusy race (Important finding) is
// also pinned here, since the report screen's own Done button is the
// concrete navigation entry point.

import AppKit
import SwiftUI
import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

private let reportWindowBox = NSRect(x: 0, y: 0, width: 1200, height: 800)

@MainActor
private func expectReportContained(
    _ id: String,
    in hosting: NSView,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    guard let control = view(under: hosting, axIdentifier: id) else {
        Issue.record("control \(id) is missing", sourceLocation: sourceLocation)
        return
    }
    let frame = control.convert(control.bounds, to: hosting)
    #expect(reportWindowBox.contains(frame), "\(id) at \(frame)", sourceLocation: sourceLocation)
}

private let fixtureItemName = "Fixture List"
private let itemTargetName = "Fixture List \u{2014} Consolidated"
private let secondItemName = "Second List"

private func reportLeftoverListingWire() -> String {
    let entries = [
        gateEntry(id: 10, name: fixtureItemName, pid: "P-FX0000000000AA", count: 4),
        gateEntry(id: 900, name: itemTargetName, pid: "LEFTOVER00000000", count: 3),
    ]
    return "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

// (The leftover SNAPSHOT wire this file used to carry is gone with the gate
// audit it fed: final fix wave, Finding C1 — the shortcut now stages a
// direct delete confirmation off the resolve read alone, so no snapshot read
// happens on this path.)

/// One-item unattended run whose apply is a writer failure -> a finished
/// report with a single failed item (class writerFailed, target name set).
@MainActor
private func writerFailedReportHarness(
    extraOutputs: [Result<String, Error>] = []
) async throws -> (ModelHarness, ScriptedRunner) {
    let listing = "{\"playlists\": ["
        + gateEntry(id: 10, name: fixtureItemName, pid: "P-FX0000000000AA", count: 4) + "]}"
    let runner = ScriptedRunner(results: [
        .success(listing),
        .success(consolidateFixtureWire()),
        .success(consolidateFixtureWire()),
        .success(emptySnapshotWire()),
        .success(""),
        .failure(MusicCommandError("osascript exited 1: writer blew up")),
        .success(consolidateFixtureWire()),
        .success(emptySnapshotWire()),
    ] + extraOutputs)
    let harness = try ModelHarness(
        runner: runner, mode: .consolidate, playlistName: "",
        confirmEachApply: false
    )
    harness.model.rescanLibrary()
    await harness.model.scanTask?.value
    harness.model.toggleChecked(persistentId: "P-FX0000000000AA")
    harness.model.startQueue()
    #expect(await pollUntil { harness.model.finishedRunReport != nil })
    #expect(harness.model.finishedRunReport?.items.first?.failureClass == .writerFailed)
    return (harness, runner)
}

/// Two-item unattended run where BOTH items are writer failures — two
/// leftover-capable failed rows in the same report (the Critical finding's
/// duplication scenario). `extraOutputs` is scripted after both items'
/// sequences (16 calls: 1 listing + 2 x (1 audit read + 6 apply stages)).
@MainActor
private func twoFailedItemsReportHarness(
    extraOutputs: [Result<String, Error>] = []
) async throws -> ModelHarness {
    let listing = "{\"playlists\": ["
        + gateEntry(id: 10, name: fixtureItemName, pid: "P-FX0000000000AA", count: 4) + ", "
        + gateEntry(id: 20, name: secondItemName, pid: "P-SEC000000000BB", count: 4) + "]}"
    func writerFailureSequence(name: String, tag: String) -> [Result<String, Error>] {
        [
            .success(consolidateFixtureWire(name: name)),
            .success(consolidateFixtureWire(name: name)),
            .success(emptySnapshotWire()),
            .success(""),
            .failure(MusicCommandError("osascript exited 1: writer blew up (\(tag))")),
            .success(consolidateFixtureWire(name: name)),
            .success(emptySnapshotWire()),
        ]
    }
    let runner = ScriptedRunner(results: [.success(listing)]
        + writerFailureSequence(name: fixtureItemName, tag: "1")
        + writerFailureSequence(name: secondItemName, tag: "2")
        + extraOutputs)
    let harness = try ModelHarness(
        runner: runner, mode: .consolidate, playlistName: "",
        confirmEachApply: false
    )
    harness.model.rescanLibrary()
    await harness.model.scanTask?.value
    harness.model.toggleChecked(persistentId: "P-FX0000000000AA")
    harness.model.toggleChecked(persistentId: "P-SEC000000000BB")
    harness.model.startQueue()
    #expect(await pollUntil { harness.model.finishedRunReport != nil })
    #expect(harness.model.finishedRunReport?.items.count == 2)
    #expect(harness.model.finishedRunReport?.items.allSatisfy { $0.failureClass == .writerFailed }
        == true)
    return harness
}

@MainActor
@Suite("Offscreen structural view tests (Wave C1 run-report surface)", .serialized)
struct WaveCRunReportSurfaceTests {

    @Test("a failed item renders banner, leftover line, and shortcut, all contained")
    func failedItemSurface() async throws {
        let (harness, _) = try await writerFailedReportHarness()
        defer { harness.cleanUp() }

        let fixture = HostedFixture(
            RunReportView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)
        expectReportContained(WaveCControlID.reportFailureBanner(fixtureItemName), in: fixture.hosting)
        expectReportContained(WaveCControlID.reportLeftoverLine(fixtureItemName), in: fixture.hosting)
        expectReportContained(
            WaveCControlID.reportDeleteLeftover(fixtureItemName), in: fixture.hosting
        )

        let banner = try #require(
            view(
                under: fixture.hosting,
                axIdentifier: WaveCControlID.reportFailureBanner(fixtureItemName)
            ) as? NSTextField
        )
        #expect(banner.stringValue
            == "- Failure class: " + applyFailureClassLabel(.writerFailed))
        let leftover = try #require(
            view(
                under: fixture.hosting,
                axIdentifier: WaveCControlID.reportLeftoverLine(fixtureItemName)
            ) as? NSTextField
        )
        #expect(leftover.stringValue == "- Leftover target: \(itemTargetName)")
    }

    @Test("the persisted .runreport.md carries the same two lines")
    func persistedArtifactCarriesLines() async throws {
        let (harness, _) = try await writerFailedReportHarness()
        defer { harness.cleanUp() }
        let path = try #require(harness.model.runReportPath)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("- Failure (verbatim): "))
        #expect(text.contains(
            "- Failure class: " + applyFailureClassLabel(.writerFailed)))
        #expect(text.contains("- Leftover target: \(itemTargetName)"))
        #expect(!text.contains("- Created:"))
    }

    @Test("shortcut click on the report stages the direct delete confirmation")
    func reportShortcutClickStagesDirectDelete() async throws {
        // Final fix wave, Finding C1: the report's own shortcut used to arm
        // the retired Wave B gate (nothing on this screen could present it).
        // It now stages the direct confirmation, which THIS screen's own
        // sheet anchor presents.
        let (harness, runner) = try await writerFailedReportHarness(extraOutputs: [
            .success(reportLeftoverListingWire()),   // the one resolve read
        ])
        defer { harness.cleanUp() }
        let commandsBefore = runner.commands.count

        let fixture = HostedFixture(
            RunReportView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        let button = try #require(
            view(
                under: fixture.hosting,
                axIdentifier: WaveCControlID.reportDeleteLeftover(fixtureItemName)
            ) as? NSButton
        )
        #expect(button.isEnabled)
        button.performClick(nil)
        await harness.model.leftoverResolveTask?.value

        guard case .delete(let targets)? = harness.model.pendingDirectAction else {
            Issue.record("expected a staged direct delete")
            return
        }
        #expect(targets.count == 1)
        #expect(scalarExact(targets[0].persistentId, "LEFTOVER00000000"))
        #expect(harness.model.armedMutation == nil)
        #expect(runner.commands.count == commandsBefore + 1,
                "one resolve read; no gate audit")
    }

    @Test("a refusedBeforeWrite item renders the banner but no shortcut or leftover line")
    func refusedItemHidesShortcut() async throws {
        // Goddesses-in-queue: the target-absent read finds an exact-name
        // target, the apply is refused pre-write, the run finishes.
        let listing = "{\"playlists\": ["
            + gateEntry(id: 10, name: fixtureItemName, pid: "P-FX0000000000AA", count: 4) + "]}"
        let runner = ScriptedRunner(outputs: [
            listing,
            consolidateFixtureWire(),
            consolidateFixtureWire(),
            consolidateTargetReadbackWire(),
        ])
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "",
            confirmEachApply: false
        )
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-FX0000000000AA")
        harness.model.startQueue()
        #expect(await pollUntil { harness.model.finishedRunReport != nil })
        #expect(harness.model.finishedRunReport?.items.first?.failureClass
            == .refusedBeforeWrite)

        let fixture = HostedFixture(
            RunReportView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        expectReportContained(WaveCControlID.reportFailureBanner(fixtureItemName), in: fixture.hosting)
        #expect(view(
            under: fixture.hosting,
            axIdentifier: WaveCControlID.reportDeleteLeftover(fixtureItemName)
        ) == nil)
        #expect(view(
            under: fixture.hosting,
            axIdentifier: WaveCControlID.reportLeftoverLine(fixtureItemName)
        ) == nil)
    }

    @Test("two failed items render distinct per-row ids; a resolve notice attaches to its own row only")
    func twoFailedItemsHaveDistinctRowIdsAndScopedNotice() async throws {
        let harness = try await twoFailedItemsReportHarness(extraOutputs: [
            .success("{\"playlists\": []}"),   // resolve read: 0 live matches
        ])
        defer { harness.cleanUp() }

        let fixture = HostedFixture(
            RunReportView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)

        // Critical finding: both rows' controls exist with DISTINCT ids and
        // are each geometrically contained — the old static ids would have
        // collided (view(under:) finds only the first sibling).
        expectReportContained(WaveCControlID.reportFailureBanner(fixtureItemName), in: fixture.hosting)
        expectReportContained(WaveCControlID.reportFailureBanner(secondItemName), in: fixture.hosting)
        expectReportContained(WaveCControlID.reportLeftoverLine(fixtureItemName), in: fixture.hosting)
        expectReportContained(WaveCControlID.reportLeftoverLine(secondItemName), in: fixture.hosting)
        let button1 = try #require(
            view(
                under: fixture.hosting,
                axIdentifier: WaveCControlID.reportDeleteLeftover(fixtureItemName)
            ) as? NSButton
        )
        let button2 = try #require(
            view(
                under: fixture.hosting,
                axIdentifier: WaveCControlID.reportDeleteLeftover(secondItemName)
            ) as? NSButton
        )
        #expect(button1.isEnabled)
        #expect(button2.isEnabled)
        #expect(view(
            under: fixture.hosting,
            axIdentifier: WaveCControlID.reportResolveNotice(fixtureItemName)
        ) == nil)
        #expect(view(
            under: fixture.hosting,
            axIdentifier: WaveCControlID.reportResolveNotice(secondItemName)
        ) == nil)

        // Trigger a resolve for row 1 ONLY (scripted to 0 live matches, so
        // it settles as a notice, never a gate arm).
        button1.performClick(nil)
        await harness.model.leftoverResolveTask?.value
        fixture.pump()

        expectReportContained(WaveCControlID.reportResolveNotice(fixtureItemName), in: fixture.hosting)
        #expect(view(
            under: fixture.hosting,
            axIdentifier: WaveCControlID.reportResolveNotice(secondItemName)
        ) == nil, "row 2 must never render row 1's notice")
    }

    @Test("acknowledgeRunReport is refused while the report's own leftover resolve is in flight")
    func acknowledgeRunReportRefusedDuringResolve() async throws {
        // Important finding: click the shortcut, then immediately click
        // Done — the resolve must never be orphaned against a discarded
        // report. A fully successful (no failure needed) one-item run
        // reaches .report; the model call underneath the shortcut doesn't
        // require a real failed row, so the STAGED runner only needs to
        // hold the NEXT call (the resolve read) after the 8 that produced
        // the report.
        let listing = "{\"playlists\": ["
            + gateEntry(id: 10, name: fixtureItemName, pid: "P-FX0000000000AA", count: 4) + "]}"
        let runner = StagedBlockingRunner(
            outputs: [listing, consolidateFixtureWire()] + consolidateApplyOutputs(),
            blockAt: [8]
        )
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "",
            confirmEachApply: false
        )
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-FX0000000000AA")
        harness.model.startQueue()
        #expect(await pollUntil { harness.model.finishedRunReport != nil })
        let reportBefore = harness.model.finishedRunReport
        #expect(harness.model.step == .report)

        harness.model.startDeleteLeftoverTarget(named: itemTargetName)
        #expect(await pollUntil { runner.runCount == 9 })
        #expect(harness.model.isResolvingLeftoverTarget)
        #expect(harness.model.isMutationBusy)

        harness.model.acknowledgeRunReport()
        #expect(harness.model.finishedRunReport == reportBefore)
        #expect(harness.model.step == .report)
        #expect(harness.model.isResolvingLeftoverTarget)

        runner.proceed.signal()
        await harness.model.leftoverResolveTask?.value
        #expect(!harness.model.isResolvingLeftoverTarget)
        #expect(!harness.model.isMutationBusy)

        // Now that the resolve has finished, the SAME call succeeds.
        harness.model.acknowledgeRunReport()
        #expect(harness.model.finishedRunReport == nil)
    }
}
