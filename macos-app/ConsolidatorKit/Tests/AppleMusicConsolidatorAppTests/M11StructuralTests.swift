// M11StructuralTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
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

@Suite("Default output directory (public-portability fix, 2026-08-12)")
struct DefaultOutputDirectoryTests {
    // The default artifact directory must derive from the USER'S home, not
    // a hardcoded developer path — a stranger building this repo gets a
    // working default. An explicit Settings value still wins (pinned by the
    // existing defaults-key tests).
    @Test("the fallback derives from Application Support")
    func derivedDefault() {
        let expected = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("AppleMusicConsolidator/reports", isDirectory: true).path
        #expect(AuditFlowModel.defaultReportsDirectoryPath() == expected)
        #expect(
            AuditFlowModel.currentOutputDirectoryPath(defaults: InMemoryDefaults())
                == expected
        )
    }
}


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

    // UI rework Part 2: the batch toggles and the output-directory/
    // Automation-preflight plumbing were REMOVED from this view (the model
    // state and the preflight flow stay reachable elsewhere — the model
    // directly, and the preflight through the Diagnostics window's
    // "Preflight Automation" button); this view is now a genuine
    // preferences screen. Renamed from `settingsPanelToggles`.
    @Test("settings no longer hosts the batch toggles or the output-dir/preflight plumbing")
    func settingsNoLongerHostsBatchTogglesOrPlumbing() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: []), confirmEachApply: false
        )
        defer { harness.cleanUp() }
        let fixture = HostedFixture(SettingsDestinationView(model: harness.model))
        defer { fixture.tearDown() }

        #expect(fixture.hosting.frame.height <= 866)
        #expect(view(under: fixture.hosting, axIdentifier: M11ControlID.confirmEachApply) == nil)
        #expect(view(under: fixture.hosting, axIdentifier: M11ControlID.pauseOnJudgment) == nil)

        // The model-level state and mutators are untouched by the UI
        // removal — proven directly, without going through the view.
        harness.model.setConfirmEachApply(true)
        #expect(harness.model.confirmEachApply == true)
        harness.model.setPauseOnJudgmentItems(true)
        #expect(harness.model.pauseOnJudgmentItems == true)
    }

    @Test("the settings destination exposes the four new preference controls inside the window")
    func settingsExposesPreferenceControls() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: []), confirmEachApply: false
        )
        defer { harness.cleanUp() }
        let fixture = HostedFixture(SettingsDestinationView(model: harness.model))
        defer { fixture.tearDown() }
        // This test clicks the Dark appearance pill below, which sets the
        // process-wide NSApp.appearance — .serialized keeps this suite's own
        // tests from interleaving, but swift-testing can still run other
        // suites concurrently, so the mutation must not escape this test.
        defer { NSApp.appearance = nil }

        #expect(fixture.hosting.frame.height <= 866)
        for mode in AppearanceMode.allCases {
            expectContained(SettingsControlID.appearance(mode), in: fixture.hosting)
        }
        expectContained(SettingsControlID.reloadLibraryOnStart, in: fixture.hosting)
        for tab in BrowserTab.allCases {
            expectContained(SettingsControlID.defaultTabOnLaunch(tab), in: fixture.hosting)
        }
        expectContained(SettingsControlID.playSoundOnRunFinish, in: fixture.hosting)

        let reload = try #require(
            view(under: fixture.hosting, axIdentifier: SettingsControlID.reloadLibraryOnStart)
                as? NSButton
        )
        #expect(reload.state == .off) // default off
        reload.performClick(nil)
        #expect(harness.model.reloadLibraryOnStart == true)

        let sound = try #require(
            view(under: fixture.hosting, axIdentifier: SettingsControlID.playSoundOnRunFinish)
                as? NSButton
        )
        #expect(sound.state == .off) // default off
        sound.performClick(nil)
        #expect(harness.model.playSoundOnRunFinish == true)

        let dark = try #require(
            view(under: fixture.hosting, axIdentifier: SettingsControlID.appearance(.dark))
                as? NSButton
        )
        dark.performClick(nil)
        #expect(harness.model.appearanceMode == .dark)

        let cleanupTab = try #require(
            view(under: fixture.hosting, axIdentifier: SettingsControlID.defaultTabOnLaunch(.cleanup))
                as? NSButton
        )
        cleanupTab.performClick(nil)
        #expect(harness.model.defaultBrowserTabOnLaunch == .cleanup)
        // This preference control never touches the LIVE tab.
        #expect(harness.model.browserTab != .cleanup)
    }

    // The narrow-gate requirement: `SettingsDestinationView` does not
    // currently participate in NarrowWindowStructuralTests.swift's root-shell
    // suite (that suite covers the root shell + the Cleanup tab only), so
    // this is a standalone narrow check rather than an addition there.
    @Test("the settings destination's preference controls fit a narrow 900x620 window")
    func settingsPreferenceControlsFitNarrowWindow() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: []), confirmEachApply: false
        )
        defer { harness.cleanUp() }
        let fixture = HostedFixture(
            SettingsDestinationView(model: harness.model), width: 900, height: 620
        )
        defer { fixture.tearDown() }

        let narrowBox = NSRect(x: 0, y: 0, width: 900, height: 620)
        #expect(fixture.hosting.frame.height <= 620)
        for mode in AppearanceMode.allCases {
            let id = SettingsControlID.appearance(mode)
            let control = try #require(view(under: fixture.hosting, axIdentifier: id))
            let frame = control.convert(control.bounds, to: fixture.hosting)
            #expect(narrowBox.contains(frame), "\(id) at \(frame)")
        }
        let reloadID = SettingsControlID.reloadLibraryOnStart
        let reload = try #require(view(under: fixture.hosting, axIdentifier: reloadID))
        #expect(narrowBox.contains(reload.convert(reload.bounds, to: fixture.hosting)))
        for tab in BrowserTab.allCases {
            let id = SettingsControlID.defaultTabOnLaunch(tab)
            let control = try #require(view(under: fixture.hosting, axIdentifier: id))
            let frame = control.convert(control.bounds, to: fixture.hosting)
            #expect(narrowBox.contains(frame), "\(id) at \(frame)")
        }
        let soundID = SettingsControlID.playSoundOnRunFinish
        let sound = try #require(view(under: fixture.hosting, axIdentifier: soundID))
        #expect(narrowBox.contains(sound.convert(sound.bounds, to: fixture.hosting)))
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

    // historyBrowserFits removed 2026-08-05: it hosted HistoryBrowserView,
    // which was deleted along with the Reports destination that hosted it.
}
