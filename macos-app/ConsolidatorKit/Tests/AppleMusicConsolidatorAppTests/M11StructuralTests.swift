// M11StructuralTests.swift
// M11 structural cells: unattended-run in-flight, the post-run report
// screen (with a judgment-heavy report), the settings panel additions, and
// the history browser. Same offscreen discipline as the M8-M10 structural
// suites: never-shown windows, fixture-driven models, geometry containment.

import AppKit
import SwiftUI
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

private let m11WindowBox = NSRect(x: 0, y: 0, width: 1280, height: 860)

@MainActor
private func expectContained(
    _ id: String,
    in hosting: NSView,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    guard let control = view(under: hosting, axIdentifier: id) else {
        Issue.record("control \(id) is missing", sourceLocation: sourceLocation)
        return
    }
    let frame = control.convert(control.bounds, to: hosting)
    #expect(m11WindowBox.contains(frame), "\(id) at \(frame)", sourceLocation: sourceLocation)
}

private func m11Listing() -> String {
    """
    {"playlists": [{"id": 10, "name": "Alpha List", "persistent_id": "P-A", \
    "track_count": 4, "smart": false, "special_kind": "none"}]}
    """
}

@MainActor
@Suite("Offscreen structural view tests (M11)", .serialized)
struct M11StructuralTests {

    @Test("the unattended run surface fits, offers Stop, and never offers Cancel")
    func unattendedRunInFlightFits() async throws {
        let runner = StagedBlockingRunner(
            outputs: [m11Listing(), consolidateFixtureWire(name: "Alpha List")]
                + consolidateApplyOutputs(name: "Alpha List"),
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
        #expect(harness.model.isRunUnattended)

        let fixture = HostedFixture(ApplyFlowView(model: harness.model))
        let height = fixture.hosting.frame.height
        let stop = view(under: fixture.hosting, axIdentifier: M11ControlID.stopRun)
        let stopFrame = stop.map { $0.convert($0.bounds, to: fixture.hosting) }
        let cancel = view(under: fixture.hosting, axIdentifier: M8ControlID.cancelAudit)
        fixture.tearDown()

        runner.proceed.signal()
        #expect(await pollUntil { harness.model.finishedRunReport != nil })

        #expect(height <= 866, "unattended run height \(height)")
        let frame = try #require(stopFrame, "stop control missing during the run")
        #expect(m11WindowBox.contains(frame), "stop control at \(frame)")
        #expect(cancel == nil, "no cancel affordance during an unattended run")
    }

    @Test("the run report screen fits with judgment-heavy content; actions contained")
    func runReportFits() async throws {
        // A judgment-heavy run: the item has a distinct-entry omission and
        // long verbatim failure text on a second item.
        let runner = ScriptedRunner(results:
            [.success(m11Listing()),
             .success(consolidateFixtureWire(name: "Alpha List"))]
                + consolidateApplyOutputs(name: "Alpha List").map { .success($0) }
        )
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false
        )
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-A")
        harness.model.startQueue()
        #expect(await pollUntil { harness.model.finishedRunReport != nil })
        #expect(harness.model.step == .report)
        // The fixture's plan HAS a judgment item (the bit-rate distinct
        // omission), so the prominent section renders.
        #expect(harness.model.finishedRunReport?.judgmentItemCount == 1)

        let fixture = HostedFixture(RunReportView(model: harness.model))
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 866)
        expectContained(M11ControlID.reportDone, in: fixture.hosting)
        expectContained(M11ControlID.revealRunReport, in: fixture.hosting)
    }

    // Fix round 1, finding 1 (UI layer): the judgment-pause screen offers
    // Resume (continue to gate) / Skip item / Stop run — and Start over is
    // DISABLED (a silent wipe of the mandatory report is impossible).
    @Test("the pause screen offers resume, skip, and stop; start over is disabled")
    func pauseScreenAffordances() async throws {
        let runner = ScriptedRunner(outputs:
            [m11Listing(), consolidateFixtureWire(name: "Alpha List")]
        )
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false
        )
        defer { harness.cleanUp() }
        harness.model.setPauseOnJudgmentItems(true)
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-A")
        harness.model.startQueue()
        // consolidateFixtureWire HAS a distinct-entry omission -> pause.
        #expect(await pollUntil {
            harness.model.step == .review && harness.model.currentQueueItem?.status == .audited
        })
        #expect(harness.model.isUnattendedRunActive)

        let fixture = HostedFixture(PlanReviewView(model: harness.model))
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 866)

        let startOver = try #require(
            view(under: fixture.hosting, axIdentifier: M8ControlID.startOver) as? NSButton
        )
        #expect(!startOver.isEnabled, "start over must be disabled during an active run")
        let resume = try #require(
            view(under: fixture.hosting, axIdentifier: M8ControlID.continueToGate) as? NSButton
        )
        #expect(resume.isEnabled)
        expectContained(M11ControlID.pauseSkipItem, in: fixture.hosting)
        expectContained(M11ControlID.stopRun, in: fixture.hosting)
    }

    @Test("the settings destination exposes the batch toggles inside the window")
    func settingsPanelToggles() async throws {
        // confirmEachApply false here = the raw app default's rendering.
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: []), confirmEachApply: false
        )
        defer { harness.cleanUp() }
        let fixture = HostedFixture(SettingsDestinationView(model: harness.model))
        defer { fixture.tearDown() }

        #expect(fixture.hosting.frame.height <= 866)
        let confirm = try #require(
            view(under: fixture.hosting, axIdentifier: M11ControlID.confirmEachApply) as? NSButton
        )
        let pause = try #require(
            view(under: fixture.hosting, axIdentifier: M11ControlID.pauseOnJudgment) as? NSButton
        )
        #expect(confirm.state == .off) // Sergio's defaults
        #expect(pause.state == .off)
        expectContained(M11ControlID.confirmEachApply, in: fixture.hosting)
        expectContained(M11ControlID.pauseOnJudgment, in: fixture.hosting)

        // Click plumbing drives the persisted settings.
        confirm.performClick(nil)
        #expect(harness.model.confirmEachApply == true)
        pause.performClick(nil)
        #expect(harness.model.pauseOnJudgmentItems == true)
    }

    // Wave C2 (spec C2.4): the disclosure LEFT the browser footer — screen 1
    // must expose no settings controls anywhere in its hierarchy.
    @Test("screen 1 no longer hosts the settings disclosure")
    func screenOneHasNoSettingsControls() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: []), confirmEachApply: false
        )
        defer { harness.cleanUp() }
        let fixture = HostedFixture(SourceSelectionView(model: harness.model))
        defer { fixture.tearDown() }
        #expect(view(under: fixture.hosting, axIdentifier: M11ControlID.confirmEachApply) == nil)
        #expect(view(under: fixture.hosting, axIdentifier: M11ControlID.pauseOnJudgment) == nil)
    }

    @Test("the history browser lists artifacts, filters, and stays bounded")
    func historyBrowserFits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m11-hist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<8 {
            FileManager.default.createFile(
                atPath: directory
                    .appendingPathComponent("List-\(index)-20260803-\(index).plan.json").path,
                contents: Data("{}".utf8)
            )
        }
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent("Run-20260803-1.runreport.md").path,
            contents: Data("run".utf8)
        )

        let fixture = HostedFixture(HistoryBrowserView(directoryPath: directory.path))
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 866)
        #expect(view(under: fixture.hosting, axIdentifier: M11ControlID.historyFilter) != nil)
        // The rows materialize inside a List (9 artifacts).
        #expect(listContentCellCount(under: fixture.hosting) == 9)
    }
}
