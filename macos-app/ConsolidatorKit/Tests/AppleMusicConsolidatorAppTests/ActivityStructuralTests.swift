// ActivityStructuralTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Wave C2 Tasks 4-5 — the Activity destination's state machine (spec C2.2):
// precedence cells rendered offscreen at 1200x800. Same discipline as every
// structural suite: never-shown windows, fixture-driven models, canned wire
// text, Music never contacted.

import AppKit
import SwiftUI
import Testing
import MusicBridge
@testable import AppleMusicConsolidatorApp

private let activityWindowBox = NSRect(x: 0, y: 0, width: 1200, height: 800)

private func activityListingWire() -> String {
    """
    {"playlists": [{"id": 10, "name": "Fixture List", "persistent_id": "P-A", \
    "track_count": 4, "smart": false, "special_kind": "none"}]}
    """
}

/// Two checked playlists, for the final-review Finding I-1 repro: item 1
/// pauses on a judgment item, item 2 is what restarts the queue after Skip.
private func twoItemQueueListingWire() -> String {
    """
    {"playlists": [{"id": 10, "name": "List One", "persistent_id": "P-A", \
    "track_count": 4, "smart": false, "special_kind": "none"}, \
    {"id": 11, "name": "List Two", "persistent_id": "P-B", \
    "track_count": 4, "smart": false, "special_kind": "none"}]}
    """
}

/// SwiftUI's indeterminate ProgressView materializes as an AppKit
/// NSProgressIndicator even offscreen (the established Wave A fact), so
/// the live progress row is countable structurally.
@MainActor
private func activitySpinnerCount(under root: NSView) -> Int {
    views(under: root, classNameContains: "ProgressIndicator").count
}

@MainActor
@Suite("Wave C2 activity destination", .serialized)
struct ActivityStructuralTests {

    @Test("precedence 1: an unattended run in flight renders the unattended surface")
    func unattendedRunWins() async throws {
        let runner = StagedBlockingRunner(
            outputs: [activityListingWire(), consolidateFixtureWire()]
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
        // Mid-run, result is nil during the item audit, but the run OWNS the
        // surface; step is .apply throughout.
        #expect(harness.model.isUnattendedRunActive)

        let fixture = HostedFixture(
            ActivityView(model: harness.model), width: 1200, height: 800
        )
        let height = fixture.hosting.frame.height
        let stop = view(under: fixture.hosting, axIdentifier: M11ControlID.stopRun)
        let stopFrame = stop.map { $0.convert($0.bounds, to: fixture.hosting) }
        fixture.tearDown()

        // Release the held read BEFORE asserting so a failure cannot strand
        // the detached pipeline.
        runner.proceed.signal()
        #expect(await pollUntil { harness.model.finishedRunReport != nil })

        #expect(height <= 806, "activity height \(height)")
        let frame = try #require(stopFrame, "stop control missing on the unattended surface")
        #expect(activityWindowBox.contains(frame), "stop control at \(frame)")
    }

    @Test("precedence 1: the judgment pause keeps today's pause surface reachable")
    func judgmentPauseSurfacePreserved() async throws {
        let runner = ScriptedRunner(
            outputs: [activityListingWire(), consolidateFixtureWire()]
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
            harness.model.step == .review
                && harness.model.currentQueueItem?.status == .audited
        })
        #expect(harness.model.isUnattendedRunActive)

        let fixture = HostedFixture(
            ActivityView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)
        // Design note 1: the pause affordances (PlanReviewView's resume +
        // the stop control) render — NOT a bare UnattendedRunScreen the
        // user cannot review from.
        #expect(view(under: fixture.hosting, axIdentifier: M8ControlID.continueToGate) != nil)
        #expect(view(under: fixture.hosting, axIdentifier: M11ControlID.stopRun) != nil)
    }

    @Test("precedence 2: an attended audited item renders the plan-review content")
    func attendedFlowRendersStagedContent() async throws {
        let runner = ScriptedRunner(
            outputs: [activityListingWire(), consolidateFixtureWire()]
        )
        // ModelHarness defaults confirmEachApply TRUE -> attended queue.
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-A")
        harness.model.startQueue()
        await harness.awaitAudit()
        #expect(harness.model.result != nil)
        #expect(harness.model.step == .review)
        #expect(!harness.model.isUnattendedRunActive)

        let fixture = HostedFixture(
            ActivityView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)
        #expect(view(under: fixture.hosting, axIdentifier: M8ControlID.continueToGate) != nil)
    }

    // Spec C2.2 state 4, controller amendment 2026-08-04 (design note 2):
    // an attended audit in flight — precedences 1-3 unmatched — must show
    // the live ticking progress row, never the "No run active" placeholder.
    @Test("precedence 4 amendment: an attended audit in flight shows live progress, not the placeholder")
    func attendedAuditShowsProgress() async throws {
        let blocking = BlockingRunner(payload: consolidateFixtureWire())
        let harness = try ModelHarness(runner: blocking)
        defer { harness.cleanUp() }
        harness.model.startAudit()
        #expect(await pollUntil { harness.model.isRunning })
        // Precedences 1-3 unmatched: attended, result nil, no report.
        #expect(!harness.model.isUnattendedRunActive)
        #expect(harness.model.result == nil)
        #expect(harness.model.finishedRunReport == nil)

        let fixture = HostedFixture(
            ActivityView(model: harness.model), width: 1200, height: 800
        )
        let height = fixture.hosting.frame.height
        let spinners = activitySpinnerCount(under: fixture.hosting)
        let caption = view(
            under: fixture.hosting, axIdentifier: WaveC2ControlID.activityIdleCaption
        )
        fixture.tearDown()

        // Release the held read BEFORE asserting so a failure cannot strand
        // the detached pipeline.
        blocking.proceed.signal()
        await harness.awaitAudit()

        #expect(height <= 806, "auditing-state height \(height)")
        #expect(spinners >= 1, "the live progress row must render during the audit")
        // The view is either/or: a spinner proves the progress branch took
        // (the placeholder branch renders zero spinners — pinned below),
        // and the last-outcome caption never renders while auditing.
        #expect(caption == nil, "no last-outcome caption while auditing")
    }

    @Test("precedence 3 then 4: the report renders, then idle carries the caption")
    func reportThenIdleCaption() async throws {
        let runner = ScriptedRunner(
            outputs: [activityListingWire(), consolidateFixtureWire()]
                + consolidateApplyOutputs()
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

        let reportFixture = HostedFixture(
            ActivityView(model: harness.model), width: 1200, height: 800
        )
        #expect(reportFixture.hosting.frame.height <= 806)
        #expect(
            view(under: reportFixture.hosting, axIdentifier: M11ControlID.reportDone) != nil
        )
        reportFixture.tearDown()

        harness.model.acknowledgeRunReport()
        let idleFixture = HostedFixture(
            ActivityView(model: harness.model), width: 1200, height: 800
        )
        defer { idleFixture.tearDown() }
        #expect(idleFixture.hosting.frame.height <= 806)
        let caption = try #require(
            view(under: idleFixture.hosting, axIdentifier: WaveC2ControlID.activityIdleCaption)
        )
        let frame = caption.convert(caption.bounds, to: idleFixture.hosting)
        #expect(activityWindowBox.contains(frame), "idle caption at \(frame)")
        #expect(
            (caption as? NSTextField)?.stringValue
                == "Last run: 1 applied, 0 failed."
        )
    }

    @Test("precedence 4: idle without a prior run shows no caption")
    func idleWithoutHistoryHasNoCaption() throws {
        let harness = try ModelHarness(runner: ScriptedRunner(outputs: []))
        defer { harness.cleanUp() }
        let fixture = HostedFixture(
            ActivityView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)
        #expect(
            view(under: fixture.hosting, axIdentifier: WaveC2ControlID.activityIdleCaption) == nil
        )
        #expect(
            activitySpinnerCount(under: fixture.hosting) == 0,
            "the placeholder branch renders no spinner"
        )
    }

    // MARK: Task 5 — the staged panel's chips

    @Test("the stage chips relocate the old step rows: presence, gating, click plumbing")
    func stageChipsDriveTheSequencer() async throws {
        let runner = ScriptedRunner(
            outputs: [activityListingWire(), consolidateFixtureWire()]
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-A")
        harness.model.startQueue()
        await harness.awaitAudit()
        #expect(harness.model.step == .review)

        let fixture = HostedFixture(
            ActivityView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)

        for id in [
            WaveC2ControlID.stageReview,
            WaveC2ControlID.stageConfirm,
            WaveC2ControlID.stageApply,
        ] {
            let chip = try #require(
                view(under: fixture.hosting, axIdentifier: id) as? NSButton, "\(id) missing"
            )
            let frame = chip.convert(chip.bounds, to: fixture.hosting)
            #expect(activityWindowBox.contains(frame), "\(id) at \(frame)")
        }

        // Gating mirrors canNavigate exactly: review visited -> confirm
        // unlocks; apply is entered by the Apply button, not navigation.
        let confirmChip = try #require(
            view(under: fixture.hosting, axIdentifier: WaveC2ControlID.stageConfirm) as? NSButton
        )
        #expect(confirmChip.isEnabled)
        let applyChip = try #require(
            view(under: fixture.hosting, axIdentifier: WaveC2ControlID.stageApply) as? NSButton
        )
        #expect(!applyChip.isEnabled)
        #expect(
            harness.model.stepBlockedReason(for: .apply)
                == "Apply from the confirm gate (step 3) first."
        )

        // Click plumbing: the chip drives navigate(to:) end to end.
        confirmChip.performClick(nil)
        #expect(harness.model.step == .confirm)
        fixture.pump()
        #expect(
            view(under: fixture.hosting, axIdentifier: M9ControlID.gateBackToReview) != nil,
            "the confirm-gate content renders after the chip click"
        )
    }

    @Test("no stage chips render on the unattended pause surface")
    func noChipsDuringUnattendedPause() async throws {
        let runner = ScriptedRunner(
            outputs: [activityListingWire(), consolidateFixtureWire()]
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
        #expect(await pollUntil {
            harness.model.step == .review
                && harness.model.currentQueueItem?.status == .audited
        })
        #expect(harness.model.isUnattendedRunActive)

        let fixture = HostedFixture(
            ActivityView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        // Precedence 1 (the run surface) renders chip-free — result is
        // non-nil during the pause, so this pins the precedence order.
        #expect(view(under: fixture.hosting, axIdentifier: WaveC2ControlID.stageReview) == nil)
        #expect(view(under: fixture.hosting, axIdentifier: M8ControlID.continueToGate) != nil)
    }

    // MARK: Final review, Finding I-1 — the pending-report banner

    @Test("""
    finding I-1: a report hidden behind a restarted attended audit stays \
    reachable through the banner, and Done still acknowledges it
    """)
    func pendingReportReachableThroughBanner() async throws {
        let runner = ScriptedRunner(
            outputs: [
                twoItemQueueListingWire(),
                consolidateFixtureWire(name: "List One"),
                consolidateFixtureWire(name: "List Two"),
            ]
        )
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false
        )
        defer { harness.cleanUp() }
        harness.model.setPauseOnJudgmentItems(true)
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-A")
        harness.model.toggleChecked(persistentId: "P-B")
        harness.model.startQueue()
        // Item 1 pauses at its judgment item.
        #expect(await pollUntil {
            harness.model.step == .review
                && harness.model.currentQueueItem?.status == .audited
        })
        #expect(harness.model.isUnattendedRunActive)

        // Stop after the current (paused) item: an idle boundary, so
        // finishRun() runs immediately. The report is set, but the
        // pre-existing zombie queue stays live — item 1 is still `.audited`,
        // not `.applied`, so Skip remains enabled.
        harness.model.requestStopAfterCurrentItem()
        #expect(harness.model.finishedRunReport != nil)
        #expect(harness.model.isQueueActive)
        #expect(!harness.model.isRunUnattended)

        // Skip restarts the queue as an ATTENDED audit (item 2) while the
        // report from item 1 is still pending and unacknowledged.
        harness.model.skipCurrentQueueItem()
        #expect(await pollUntil { harness.model.result != nil })
        #expect(harness.model.finishedRunReport != nil, "the report must survive the restart")
        #expect(harness.model.step == .review)

        // Precedence 2 (the staged panel) now wins over the pending report
        // — exactly the coexistence state the banner exists to fix.
        let fixture = HostedFixture(
            ActivityView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }

        let banner = try #require(
            view(under: fixture.hosting, axIdentifier: WaveC2ControlID.pendingReportBanner)
                as? NSButton,
            "the pending-report banner must render when the staged panel hides the report"
        )
        #expect(view(under: fixture.hosting, axIdentifier: WaveC2ControlID.stageReview) != nil)

        banner.performClick(nil)
        fixture.pump()
        #expect(
            view(under: fixture.hosting, axIdentifier: M11ControlID.reportDone) != nil,
            "the report must be reachable from the banner"
        )
        let back = try #require(
            view(under: fixture.hosting, axIdentifier: WaveC2ControlID.pendingReportBack)
                as? NSButton
        )

        // Back restores the staged panel without touching the report. The
        // banner is a fresh view each time it (re)appears (its own SwiftUI
        // `if` toggled off, then on), so re-query it rather than reuse the
        // now-detached reference.
        back.performClick(nil)
        fixture.pump()
        #expect(view(under: fixture.hosting, axIdentifier: WaveC2ControlID.stageReview) != nil)
        #expect(harness.model.finishedRunReport != nil)

        // Re-enter, then Done acknowledges through the unchanged model path.
        let bannerAgain = try #require(
            view(under: fixture.hosting, axIdentifier: WaveC2ControlID.pendingReportBanner)
                as? NSButton
        )
        bannerAgain.performClick(nil)
        fixture.pump()
        let done = try #require(
            view(under: fixture.hosting, axIdentifier: M11ControlID.reportDone) as? NSButton
        )
        done.performClick(nil)
        #expect(harness.model.finishedRunReport == nil)
        #expect(harness.model.selectedDestination == .library)
    }

    @Test("no pending-report banner when there is no pending report, or when the report is already the content")
    func noBannerBothSides() async throws {
        // Side A: no pending report at all (the mainline attended cell).
        let runnerA = ScriptedRunner(
            outputs: [activityListingWire(), consolidateFixtureWire()]
        )
        let harnessA = try ModelHarness(runner: runnerA, mode: .consolidate, playlistName: "")
        defer { harnessA.cleanUp() }
        harnessA.model.rescanLibrary()
        await harnessA.model.scanTask?.value
        harnessA.model.toggleChecked(persistentId: "P-A")
        harnessA.model.startQueue()
        await harnessA.awaitAudit()
        #expect(harnessA.model.finishedRunReport == nil)

        let fixtureA = HostedFixture(
            ActivityView(model: harnessA.model), width: 1200, height: 800
        )
        defer { fixtureA.tearDown() }
        #expect(
            view(under: fixtureA.hosting, axIdentifier: WaveC2ControlID.pendingReportBanner)
                == nil
        )

        // Side B: a pending report IS the content precedence 3 renders
        // directly (no higher precedence contends) — no banner needed.
        let runnerB = ScriptedRunner(
            outputs: [activityListingWire(), consolidateFixtureWire()]
                + consolidateApplyOutputs()
        )
        let harnessB = try ModelHarness(
            runner: runnerB, mode: .consolidate, playlistName: "", confirmEachApply: false
        )
        defer { harnessB.cleanUp() }
        harnessB.model.rescanLibrary()
        await harnessB.model.scanTask?.value
        harnessB.model.toggleChecked(persistentId: "P-A")
        harnessB.model.startQueue()
        #expect(await pollUntil { harnessB.model.finishedRunReport != nil })

        let fixtureB = HostedFixture(
            ActivityView(model: harnessB.model), width: 1200, height: 800
        )
        defer { fixtureB.tearDown() }
        #expect(
            view(under: fixtureB.hosting, axIdentifier: WaveC2ControlID.pendingReportBanner)
                == nil
        )
        #expect(view(under: fixtureB.hosting, axIdentifier: M11ControlID.reportDone) != nil)
    }

    @Test("""
    finding I-1 residual: a report hidden behind a RUNNING restarted audit \
    still shows live progress, with the banner reachable
    """)
    func pendingReportReachableWhileAuditIsRunning() async throws {
        let runner = StagedBlockingRunner(
            outputs: [
                twoItemQueueListingWire(),
                consolidateFixtureWire(name: "List One"),
                consolidateFixtureWire(name: "List Two"),
            ],
            blockAt: [2]
        )
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false
        )
        defer { harness.cleanUp() }
        harness.model.setPauseOnJudgmentItems(true)
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-A")
        harness.model.toggleChecked(persistentId: "P-B")
        harness.model.startQueue()
        // Item 1 pauses at its judgment item.
        #expect(await pollUntil {
            harness.model.step == .review
                && harness.model.currentQueueItem?.status == .audited
        })
        #expect(harness.model.isUnattendedRunActive)

        harness.model.requestStopAfterCurrentItem()
        #expect(harness.model.finishedRunReport != nil)
        #expect(harness.model.isQueueActive)
        #expect(!harness.model.isRunUnattended)

        // Skip restarts item 2's audit — held IN FLIGHT by StagedBlockingRunner
        // at call index 2 (after the listing + item 1's audit), so runState
        // stays .running while item 1's report is still pending.
        harness.model.skipCurrentQueueItem()
        #expect(await pollUntil { runner.runCount == 3 })
        #expect(harness.model.isRunning)
        #expect(harness.model.result == nil, "the restarted audit has not completed yet")
        #expect(harness.model.finishedRunReport != nil, "item 1's report must survive the restart")

        let fixture = HostedFixture(
            ActivityView(model: harness.model), width: 1200, height: 800
        )
        let spinners = activitySpinnerCount(under: fixture.hosting)
        let staleReport = view(under: fixture.hosting, axIdentifier: M11ControlID.reportDone)
        let banner = try #require(
            view(under: fixture.hosting, axIdentifier: WaveC2ControlID.pendingReportBanner)
                as? NSButton,
            "the pending-report banner must render above the live progress"
        )

        banner.performClick(nil)
        fixture.pump()
        let reachedFromBanner = view(under: fixture.hosting, axIdentifier: M11ControlID.reportDone)
        let back = try #require(
            view(under: fixture.hosting, axIdentifier: WaveC2ControlID.pendingReportBack)
                as? NSButton
        )
        back.performClick(nil)
        fixture.pump()
        let spinnersAfterBack = activitySpinnerCount(under: fixture.hosting)
        fixture.tearDown()

        // Release the held read BEFORE any remaining assertion so a failure
        // cannot strand the detached pipeline.
        runner.proceed.signal()
        #expect(await pollUntil { harness.model.result != nil })

        #expect(spinners >= 1, "the live progress row must render while the restarted audit runs")
        #expect(staleReport == nil, "the stale report must not render directly while an audit is running")
        #expect(reachedFromBanner != nil, "the report must be reachable from the banner even while the audit runs")
        #expect(spinnersAfterBack >= 1, "Back must restore the live progress, not the stale report")
    }

    // MARK: Final review, Finding I-2 — run-state-truthful idle cells

    @Test("finding I-2: a failed attended audit renders its verbatim outcome, not \"No run active\"")
    func failedAttendedAuditRendersFailure() async throws {
        let message = "JXA execution failed: error -1743: Not authorized to send Apple events to Music."
        let runner = ScriptedRunner(results: [.failure(MusicCommandError(message))])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startAudit()
        await harness.awaitAudit()
        guard case .failed = harness.model.runState else {
            Issue.record("expected a failed run state, got \(harness.model.runState)")
            return
        }

        let fixture = HostedFixture(
            ActivityView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806, "failure cell height \(fixture.hosting.frame.height)")

        let failureText = try #require(
            view(under: fixture.hosting, axIdentifier: WaveC2ControlID.activityAuditFailure)
                as? NSTextField
        )
        #expect(failureText.stringValue == message)
        let backButton = try #require(
            view(under: fixture.hosting, axIdentifier: WaveC2ControlID.activityBackToLibrary)
                as? NSButton
        )
        backButton.performClick(nil)
        #expect(harness.model.selectedDestination == .library)
    }

    @Test("finding I-2: a cancelled attended audit renders its outcome, not \"No run active\"")
    func cancelledAttendedAuditRendersCancellation() async throws {
        let runner = BlockingRunner(payload: consolidateFixtureWire())
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startAudit()
        #expect(await pollUntil { runner.runCount == 1 })
        harness.model.cancelAudit()
        runner.proceed.signal()
        await harness.awaitAudit()
        #expect(harness.model.runState == .cancelled)

        let fixture = HostedFixture(
            ActivityView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806, "cancellation cell height \(fixture.hosting.frame.height)")

        #expect(view(under: fixture.hosting, axIdentifier: WaveC2ControlID.activityIdleCaption) == nil)
        let backButton = try #require(
            view(under: fixture.hosting, axIdentifier: WaveC2ControlID.activityBackToLibrary)
                as? NSButton
        )
        backButton.performClick(nil)
        #expect(harness.model.selectedDestination == .library)
    }

    // MARK: Fix-before-close — AppKitActionButton toolTip

    @Test("a blocked stage chip's NSButton toolTip carries stepBlockedReason")
    func blockedStageChipCarriesToolTip() async throws {
        let runner = ScriptedRunner(
            outputs: [activityListingWire(), consolidateFixtureWire()]
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-A")
        harness.model.startQueue()
        await harness.awaitAudit()
        #expect(harness.model.step == .review)

        let fixture = HostedFixture(
            ActivityView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }

        let applyChip = try #require(
            view(under: fixture.hosting, axIdentifier: WaveC2ControlID.stageApply) as? NSButton
        )
        #expect(!applyChip.isEnabled)
        #expect(applyChip.toolTip == harness.model.stepBlockedReason(for: .apply))
        #expect(applyChip.toolTip == "Apply from the confirm gate (step 3) first.")
    }
}
