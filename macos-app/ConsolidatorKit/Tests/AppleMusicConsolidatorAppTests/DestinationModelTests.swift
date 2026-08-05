// DestinationModelTests.swift
// Wave C2 Task 1 — the destination selection state machine (spec C2.1/C2.3):
// auto-select on the three run entry points, the hot-path lock (the exact
// canNavigate predicate), the reused blocked-reason strings, and the report
// invariant (destination changes never clear finishedRunReport). All
// offline: ScriptedRunner / StagedBlockingRunner / BlockingRunner /
// ModelHarness / InMemoryDefaults — Music is never contacted.

import Foundation
import Testing
@testable import AppleMusicConsolidatorApp

/// One single-copy playlist named exactly like the ModelHarness default
/// ("Fixture List") so queue items audit against consolidateFixtureWire().
private func destinationListingWire() -> String {
    """
    {"playlists": [{"id": 10, "name": "Fixture List", "persistent_id": "P-A", \
    "track_count": 4, "smart": false, "special_kind": "none"}]}
    """
}

@MainActor
@Suite("Wave C2 destination model", .serialized)
struct DestinationModelTests {

    @Test("the app starts on Library")
    func startsOnLibrary() throws {
        let harness = try ModelHarness(runner: ScriptedRunner(outputs: []))
        defer { harness.cleanUp() }
        #expect(harness.model.selectedDestination == .library)
        #expect(!harness.model.isDestinationLocked)
    }

    @Test("startAudit auto-selects Activity")
    func startAuditAutoSelects() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: [consolidateFixtureWire()])
        )
        defer { harness.cleanUp() }
        #expect(harness.model.selectedDestination == .library)
        harness.model.startAudit()
        #expect(harness.model.selectedDestination == .activity)
        await harness.awaitAudit()
        #expect(harness.model.result != nil)
    }

    @Test("startQueue auto-selects Activity")
    func startQueueAutoSelects() async throws {
        let runner = ScriptedRunner(
            outputs: [destinationListingWire(), consolidateFixtureWire()]
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-A")
        harness.model.selectDestination(.reports)
        #expect(harness.model.selectedDestination == .reports)
        harness.model.startQueue()
        #expect(harness.model.selectedDestination == .activity)
        await harness.awaitAudit()
    }

    @Test("startApply auto-selects Activity through startApplyCore")
    func startApplyAutoSelects() async throws {
        let runner = ScriptedRunner(
            outputs: [consolidateFixtureWire()] + consolidateApplyOutputs()
        )
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        try await harness.auditAndSatisfyGate()
        harness.model.selectDestination(.library)
        #expect(harness.model.selectedDestination == .library)
        harness.model.startApply()
        #expect(harness.model.selectedDestination == .activity)
        await harness.awaitApply()
        #expect(harness.model.isApplyConsumed)
    }

    @Test("the unattended hot path locks selection to Activity and unlocks after")
    func unattendedHotLock() async throws {
        let runner = StagedBlockingRunner(
            outputs: [destinationListingWire(), consolidateFixtureWire()]
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

        // Hot: unattended + queue active + audit running.
        #expect(harness.model.isDestinationLocked)
        #expect(harness.model.canSelect(.activity))
        #expect(!harness.model.canSelect(.library))
        #expect(!harness.model.canSelect(.reports))
        #expect(!harness.model.canSelect(.settings))
        harness.model.selectDestination(.library)
        #expect(
            harness.model.selectedDestination == .activity,
            "a locked selection must be a no-op"
        )
        #expect(
            harness.model.destinationBlockedReason(for: .library)
                == "Wait for the running check to finish."
        )
        #expect(harness.model.destinationBlockedReason(for: .activity) == nil)

        runner.proceed.signal()
        #expect(await pollUntil { harness.model.finishedRunReport != nil })
        #expect(!harness.model.isDestinationLocked)
        #expect(harness.model.canSelect(.library))
        #expect(harness.model.destinationBlockedReason(for: .library) == nil)
    }

    @Test("an apply in flight locks selection with the apply reason")
    func applyHotLock() async throws {
        let runner = StagedBlockingRunner(
            outputs: [consolidateFixtureWire()] + consolidateApplyOutputs(),
            blockAt: [1]
        )
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        try await harness.auditAndSatisfyGate()
        harness.model.startApply()
        #expect(await pollUntil { runner.runCount == 2 })
        #expect(harness.model.isApplying)
        #expect(harness.model.isDestinationLocked)
        #expect(
            harness.model.destinationBlockedReason(for: .settings)
                == "Wait for the running apply to finish."
        )
        harness.model.selectDestination(.settings)
        #expect(harness.model.selectedDestination == .activity)
        runner.proceed.signal()
        await harness.awaitApply()
        #expect(!harness.model.isDestinationLocked)
    }

    @Test("an attended audit does not lock selection (the exact canNavigate predicate)")
    func attendedAuditDoesNotLock() async throws {
        let runner = BlockingRunner(payload: consolidateFixtureWire())
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startAudit()
        #expect(await pollUntil { harness.model.isRunning })
        // Attended audit: running, but neither applying nor unattended-hot —
        // today's canNavigate does not lock here, so neither does selection.
        #expect(!harness.model.isDestinationLocked)
        #expect(harness.model.canSelect(.library))
        harness.model.selectDestination(.library)
        #expect(harness.model.selectedDestination == .library)
        runner.proceed.signal()
        await harness.awaitAudit()
    }

    @Test("destination changes never clear the report; Done returns to Library")
    func reportInvariantAndDoneReturnsToLibrary() async throws {
        let runner = ScriptedRunner(
            outputs: [destinationListingWire(), consolidateFixtureWire()]
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
        #expect(harness.model.selectedDestination == .activity)

        harness.model.selectDestination(.reports)
        #expect(harness.model.finishedRunReport != nil, "report invariant")
        harness.model.selectDestination(.library)
        #expect(harness.model.finishedRunReport != nil, "report invariant")

        harness.model.acknowledgeRunReport()
        #expect(harness.model.finishedRunReport == nil)
        #expect(harness.model.selectedDestination == .library)
    }
}

// MARK: - Wave C2 Task 2: the Activity chip and the last-run summary

@Suite("Wave C2 activity chip (pure)")
struct ActivityChipTests {

    @Test("chip precedence: running beats paused beats finished beats idle")
    func chipPrecedence() {
        #expect(activityChipState(
            isRunning: true, isApplying: false, isUnattendedRunActive: true,
            hasAttendedResult: false, hasFinishedReport: false
        ) == .running)
        #expect(activityChipState(
            isRunning: false, isApplying: true, isUnattendedRunActive: false,
            hasAttendedResult: true, hasFinishedReport: false
        ) == .running)
        #expect(activityChipState(
            isRunning: false, isApplying: false, isUnattendedRunActive: true,
            hasAttendedResult: true, hasFinishedReport: false
        ) == .paused, "the judgment pause is paused, not running")
        #expect(activityChipState(
            isRunning: false, isApplying: false, isUnattendedRunActive: false,
            hasAttendedResult: true, hasFinishedReport: false
        ) == .paused, "an attended flow parked at review/confirm/outcome is paused")
        #expect(activityChipState(
            isRunning: false, isApplying: false, isUnattendedRunActive: false,
            hasAttendedResult: false, hasFinishedReport: true
        ) == .finished)
        #expect(activityChipState(
            isRunning: false, isApplying: false, isUnattendedRunActive: false,
            hasAttendedResult: false, hasFinishedReport: false
        ) == .idle)
    }

    @Test("chip styles: running is live; the other three carry symbols")
    func chipStyles() {
        let running = activityChipStyle(for: .running)
        #expect(running.isLive)
        #expect(running.label == "running\u{2026}")
        let paused = activityChipStyle(for: .paused)
        #expect(paused.symbolName == "pause.circle")
        #expect(paused.label == "paused")
        let finished = activityChipStyle(for: .finished)
        #expect(finished.symbolName == "checkmark.circle.fill")
        #expect(finished.label == "finished")
        let idle = activityChipStyle(for: .idle)
        #expect(idle.symbolName == "circle.dotted")
        #expect(idle.label == "idle")
    }

    @Test("the last-run caption renders the spec's exact wording")
    func lastRunCaption() {
        let summary = LastRunSummary(appliedCount: 1, failedCount: 2)
        #expect(summary.caption == "Last run: 1 applied, 2 failed \u{2014} see Reports.")
    }
}

@MainActor
@Suite("Wave C2 activity chip (model)", .serialized)
struct ActivityChipModelTests {

    @Test("the model derives the chip from live state and retains the last-run summary")
    func chipAndSummaryFollowTheRun() async throws {
        let runner = StagedBlockingRunner(
            outputs: [destinationListingWire(), consolidateFixtureWire()]
                + consolidateApplyOutputs(),
            blockAt: [1]
        )
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false
        )
        defer { harness.cleanUp() }
        #expect(harness.model.activityChip == .idle)
        #expect(harness.model.lastRunSummary == nil)
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        #expect(harness.model.activityChip == .idle, "scanning is not a run")
        harness.model.toggleChecked(persistentId: "P-A")
        harness.model.startQueue()
        #expect(await pollUntil { runner.runCount == 2 })
        #expect(harness.model.activityChip == .running)

        runner.proceed.signal()
        #expect(await pollUntil { harness.model.finishedRunReport != nil })
        #expect(harness.model.activityChip == .finished)
        #expect(
            harness.model.lastRunSummary
                == LastRunSummary(appliedCount: 1, failedCount: 0)
        )

        harness.model.acknowledgeRunReport()
        #expect(harness.model.activityChip == .idle)
        #expect(
            harness.model.lastRunSummary
                == LastRunSummary(appliedCount: 1, failedCount: 0),
            "the summary survives acknowledging the report (session-scoped)"
        )
    }
}
