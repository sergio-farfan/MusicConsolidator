// M11FlowTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// M11 — the unattended batch state machine (the contract-amendment path),
// the settings that govern it, the mandatory post-run report, and the
// listing cache. All fakes; nothing executes any script or contacts Music.
// The engine guards are UNCHANGED and re-pinned on the new path: every item
// is a fresh live audit + one-apply-per-audit from its persisted artifact,
// single-flight, generation-guarded.

import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

private func m11ListingWire(_ names: [(String, String)]) -> String {
    let entries = names.enumerated().map { index, entry in
        """
        {"id": \(10 + index * 10), "name": "\(entry.0)", "persistent_id": "\(entry.1)", \
        "track_count": 4, "smart": false, "special_kind": "none"}
        """
    }
    return "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

/// A consolidate fixture with NO judgment items: no duplicate pair (all
/// distinct titles), no non-eligible tracks.
private func cleanConsolidateWire(name: String) -> String {
    wireSnapshot(playlists: [
        wirePlaylist(
            id: 100, name: name, persistentId: "PL-\(name.hashValue.magnitude % 1000)",
            tracks: [
                wireTrack(sourceIndex: 0, databaseId: 31, persistentId: "CLN0001", title: "One"),
                wireTrack(sourceIndex: 1, databaseId: 32, persistentId: "CLN0002", title: "Two"),
            ]
        )
    ])
}

/// The clean fixture's apply sequence (winners [0, 1]).
private func cleanApplyOutputs(name: String) -> [String] {
    let target = wireSnapshot(playlists: [
        wirePlaylist(
            id: 900, name: "\(name) \u{2014} Consolidated", persistentId: "TGT0",
            tracks: [
                wireTrack(sourceIndex: 0, databaseId: 31, persistentId: "CLN0001", title: "One"),
                wireTrack(sourceIndex: 1, databaseId: 32, persistentId: "CLN0002", title: "Two"),
            ]
        )
    ])
    return [
        cleanConsolidateWire(name: name),
        emptySnapshotWire(),
        "",
        "",
        cleanConsolidateWire(name: name),
        target,
    ]
}

// MARK: - unattended runs

@MainActor
@Suite("M11 — unattended batch runs")
struct UnattendedRunTests {

    @Test("launch once: audits and applies straight through, report at the end")
    func unattendedHappyPath() async throws {
        let runner = ScriptedRunner(outputs:
            [m11ListingWire([("Alpha List", "P-A"), ("Beta List", "P-B")])]
                + [cleanConsolidateWire(name: "Alpha List")] + cleanApplyOutputs(name: "Alpha List")
                + [cleanConsolidateWire(name: "Beta List")] + cleanApplyOutputs(name: "Beta List")
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false)
        defer { harness.cleanUp() }
        let model = harness.model
        #expect(model.confirmEachApply == false) // Sergio's default

        model.rescanLibrary()
        await model.scanTask?.value
        model.toggleChecked(persistentId: "P-A")
        model.toggleChecked(persistentId: "P-B")
        model.startQueue()
        #expect(model.isRunUnattended)
        #expect(model.step == .apply)

        // NO gate interaction of any kind: the run drives itself to the end.
        #expect(await pollUntil { model.finishedRunReport != nil })
        let report = try #require(model.finishedRunReport)
        #expect(model.step == .report)
        #expect(model.queue.map(\.status) == [.applied, .applied])
        #expect(report.items.map(\.name) == ["Alpha List", "Beta List"])
        #expect(report.appliedCount == 2)
        #expect(report.failedCount == 0)
        #expect(report.unattended)
        for item in report.items {
            if case .applied(let count) = item.outcome {
                #expect(count == 2)
            } else {
                Issue.record("expected applied outcome, got \(item.outcome)")
            }
            #expect(item.inputCount == 2)
            #expect(item.outputCount == 2)
        }

        // The report artifact exists, with the never-overwrite suffix, in
        // the same reports directory.
        let path = try #require(model.runReportPath)
        #expect(path.hasPrefix(harness.outputDirectory.path))
        #expect(path.contains(".runreport"))
        #expect(FileManager.default.fileExists(atPath: path))

        // Transcript: 1 listing + 2 x (1 audit read + 6 apply commands) —
        // every item was a FRESH live audit and a full guarded apply.
        #expect(runner.commands.count == 15)
    }

    @Test("an item failure fails closed, is recorded verbatim, and the run continues")
    func failureContinues() async throws {
        let runner = ScriptedRunner(results:
            [.success(m11ListingWire([("Alpha List", "P-A"), ("Beta List", "P-B")]))]
                + [.success(cleanConsolidateWire(name: "Alpha List")),
                   .failure(MusicCommandError("apply exploded mid-run"))]
                + [.success(cleanConsolidateWire(name: "Beta List"))]
                + cleanApplyOutputs(name: "Beta List").map { .success($0) }
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false)
        defer { harness.cleanUp() }
        let model = harness.model

        model.rescanLibrary()
        await model.scanTask?.value
        model.toggleChecked(persistentId: "P-A")
        model.toggleChecked(persistentId: "P-B")
        model.startQueue()
        #expect(await pollUntil { model.finishedRunReport != nil })

        #expect(model.queue.map(\.status) == [.failed, .applied])
        let report = try #require(model.finishedRunReport)
        #expect(report.failedCount == 1)
        #expect(report.appliedCount == 1)
        if case .failed(let reason) = report.items[0].outcome {
            #expect(reason.contains("apply exploded mid-run"))
        } else {
            Issue.record("expected a failed outcome for item 1")
        }
    }

    @Test("an audit failure also continues the run and is recorded")
    func auditFailureContinues() async throws {
        let runner = ScriptedRunner(results:
            [.success(m11ListingWire([("Alpha List", "P-A"), ("Beta List", "P-B")]))]
                + [.failure(MusicCommandError("read failed"))]
                + [.success(cleanConsolidateWire(name: "Beta List"))]
                + cleanApplyOutputs(name: "Beta List").map { .success($0) }
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false)
        defer { harness.cleanUp() }
        let model = harness.model

        model.rescanLibrary()
        await model.scanTask?.value
        model.toggleChecked(persistentId: "P-A")
        model.toggleChecked(persistentId: "P-B")
        model.startQueue()
        #expect(await pollUntil { model.finishedRunReport != nil })

        #expect(model.queue.map(\.status) == [.failed, .applied])
        let report = try #require(model.finishedRunReport)
        if case .failed(let reason) = report.items[0].outcome {
            #expect(reason == "read failed")
        } else {
            Issue.record("expected a failed outcome for the audit-failed item")
        }
    }

    @Test("stop after the current item ends the run early; the rest is recorded as not run")
    func stopAfterCurrentItem() async throws {
        // Block on item 1's apply execute so the stop lands mid-item.
        let runner = StagedBlockingRunner(
            outputs: [m11ListingWire([("Alpha List", "P-A"), ("Beta List", "P-B")])]
                + [cleanConsolidateWire(name: "Alpha List")] + cleanApplyOutputs(name: "Alpha List"),
            blockAt: [5] // the guarded write execute
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false)
        defer { harness.cleanUp() }
        let model = harness.model

        model.rescanLibrary()
        await model.scanTask?.value
        model.toggleChecked(persistentId: "P-A")
        model.toggleChecked(persistentId: "P-B")
        model.startQueue()
        #expect(await pollUntil { runner.runCount == 6 })

        model.requestStopAfterCurrentItem()
        runner.proceed.signal()
        #expect(await pollUntil { model.finishedRunReport != nil })

        let report = try #require(model.finishedRunReport)
        #expect(report.stoppedEarly)
        #expect(report.items.count == 2)
        if case .applied = report.items[0].outcome {} else {
            Issue.record("item 1 must have finished its guarded apply")
        }
        #expect(report.items[1].outcome == .notRun)
        // Item 2 was never audited: the traffic stops at item 1's full
        // sequence (1 listing + 1 audit read + 6 apply commands).
        #expect(runner.runCount == 8)
    }

    @Test("navigation locks to the apply surface while the unattended run works")
    func navigationLocksDuringRun() async throws {
        let runner = StagedBlockingRunner(
            outputs: [m11ListingWire([("Alpha List", "P-A")])]
                + [cleanConsolidateWire(name: "Alpha List")] + cleanApplyOutputs(name: "Alpha List"),
            blockAt: [1] // the item's audit read
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false)
        defer { harness.cleanUp() }
        let model = harness.model

        model.rescanLibrary()
        await model.scanTask?.value
        model.toggleChecked(persistentId: "P-A")
        model.startQueue()
        #expect(await pollUntil { runner.runCount == 2 })
        #expect(model.isRunning)
        #expect(!model.canNavigate(to: .source))
        #expect(!model.canNavigate(to: .review))
        #expect(model.canNavigate(to: .apply))

        runner.proceed.signal()
        #expect(await pollUntil { model.finishedRunReport != nil })
        #expect(model.canNavigate(to: .report))
    }
}

// MARK: - settings restore the attended flow

@MainActor
@Suite("M11 — settings govern the run")
struct RunSettingsTests {

    @Test("confirm-each-apply ON restores the M9 per-item gate flow")
    func confirmEachApplyRestoresGate() async throws {
        let runner = ScriptedRunner(outputs:
            [m11ListingWire([("Alpha List", "P-A")]),
             cleanConsolidateWire(name: "Alpha List")]
                + cleanApplyOutputs(name: "Alpha List")
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false)
        defer { harness.cleanUp() }
        let model = harness.model
        model.setConfirmEachApply(true)

        model.rescanLibrary()
        await model.scanTask?.value
        model.toggleChecked(persistentId: "P-A")
        model.startQueue()
        #expect(!model.isRunUnattended)
        await harness.awaitAudit()

        // The attended pause: review step, idle apply, gate required.
        #expect(model.step == .review)
        if case .idle = model.applyState {} else {
            Issue.record("attended runs must not auto-apply")
        }
        #expect(runner.commands.count == 2) // listing + the one audit read
        #expect(!model.canApply)

        model.reviewedPlanToggle = true
        model.typedTargetName = try #require(model.targetName)
        model.startApply()
        await harness.awaitApply()
        #expect(model.queue.map(\.status) == [.applied])
        model.continueQueueAfterApply()
        // Attended queue completion also lands on the mandatory report.
        #expect(model.finishedRunReport != nil)
        #expect(model.finishedRunReport?.unattended == false)
    }

    @Test("pause-on-judgment holds items with judgment data for review; clean items flow")
    func pauseOnJudgmentItems() async throws {
        // Item 1 "Alpha List" is clean and flows unattended; item 2
        // "Fixture List" HAS a distinct-entry omission (judgment) and must
        // pause for review.
        let orderedRunner = ScriptedRunner(outputs:
            [m11ListingWire([("Alpha List", "P-A"), ("Fixture List", "P-FIX")])]
                + [cleanConsolidateWire(name: "Alpha List")] + cleanApplyOutputs(name: "Alpha List")
                + [consolidateFixtureWire(name: "Fixture List")]
                + consolidateApplyOutputs(name: "Fixture List")
        )
        let harness = try ModelHarness(
            runner: orderedRunner, mode: .consolidate, playlistName: "",
            confirmEachApply: false
        )
        defer { harness.cleanUp() }
        let model = harness.model
        model.setPauseOnJudgmentItems(true)

        model.rescanLibrary()
        await model.scanTask?.value
        model.toggleChecked(persistentId: "P-A")
        model.toggleChecked(persistentId: "P-FIX")
        model.startQueue()
        #expect(model.isRunUnattended)

        // Item 1 (clean) flows through; item 2 (judgment) pauses at review.
        #expect(await pollUntil {
            model.step == .review && model.queue.first?.status == .applied
        })
        #expect(model.queue.map(\.status) == [.applied, .audited])
        if case .idle = model.applyState {} else {
            Issue.record("a paused item must not auto-apply")
        }
        #expect(model.finishedRunReport == nil)

        // The human reviews, then completes the item through the M9 gate;
        // the run resumes and finishes.
        model.reviewedPlanToggle = true
        model.typedTargetName = try #require(model.targetName)
        model.startApply()
        #expect(await pollUntil { model.finishedRunReport != nil })
        #expect(model.queue.map(\.status) == [.applied, .applied])
        let report = try #require(model.finishedRunReport)
        #expect(report.items[1].hasJudgmentItems)
        #expect(!report.items[0].hasJudgmentItems)
    }

    /// Fix round 1, finding 1: during a judgment PAUSE (nothing running,
    /// nothing applying) the run is still active — the mutating entry
    /// points must not silently wipe the mandatory report after live
    /// writes. Start over / mode change / dismiss are REFUSED; the stop
    /// action finishes the run and PERSISTS the report immediately.
    @Test("a judgment pause cannot be wiped; stop finishes and persists the report")
    func pausedRunCannotBeWiped() async throws {
        let runner = ScriptedRunner(outputs:
            [m11ListingWire([("Alpha List", "P-A"), ("Fixture List", "P-FIX")])]
                + [cleanConsolidateWire(name: "Alpha List")] + cleanApplyOutputs(name: "Alpha List")
                + [consolidateFixtureWire(name: "Fixture List")]
        )
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false
        )
        defer { harness.cleanUp() }
        let model = harness.model
        model.setPauseOnJudgmentItems(true)

        model.rescanLibrary()
        await model.scanTask?.value
        model.toggleChecked(persistentId: "P-A")
        model.toggleChecked(persistentId: "P-FIX")
        model.startQueue()
        // Item 1 auto-applies (a LIVE write happened); item 2 pauses.
        #expect(await pollUntil {
            model.step == .review && model.queue.first?.status == .applied
        })
        #expect(model.isUnattendedRunActive)

        // The wipe attempts: all REFUSED — the run state and the pending
        // report data survive.
        model.startOver()
        #expect(model.isQueueActive)
        #expect(model.queue.map(\.status) == [.applied, .audited])
        #expect(model.result != nil)
        model.setMode(.merge)
        #expect(model.mode == .consolidate)
        #expect(model.isQueueActive)
        model.dismissQueue()
        #expect(model.isQueueActive)

        // Stop at the pause boundary: the run finishes NOW — the report is
        // built and persisted; the applied write's record survives, and the
        // paused item's judgment data is in the report.
        model.requestStopAfterCurrentItem()
        let report = try #require(model.finishedRunReport)
        #expect(report.stoppedEarly)
        if case .applied = report.items[0].outcome {} else {
            Issue.record("the live write's record was lost: \(report.items[0].outcome)")
        }
        #expect(report.items[1].outcome == .notRun)
        #expect(report.items[1].hasJudgmentItems) // the paused item's data survives
        let path = try #require(model.runReportPath)
        #expect(FileManager.default.fileExists(atPath: path))

        // After the run finished, start over works again.
        model.startOver()
        #expect(!model.isQueueActive)
    }

    /// Fix round 1, minor a: the report is the MANDATORY artifact — a
    /// persistence failure must be loud, not a silent try?.
    @Test("a run-report write failure is surfaced loudly in the run state")
    func reportWriteFailureIsLoud() async throws {
        let runner = ScriptedRunner(outputs:
            [m11ListingWire([("Alpha List", "P-A")])]
                + [cleanConsolidateWire(name: "Alpha List")] + cleanApplyOutputs(name: "Alpha List")
        )
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false
        )
        defer { harness.cleanUp() }
        let model = harness.model

        // Make the reports directory unwritable BEFORE the run finishes.
        let lockedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m11-locked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lockedDirectory, withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: lockedDirectory.path
            )
            try? FileManager.default.removeItem(at: lockedDirectory)
        }

        model.rescanLibrary()
        await model.scanTask?.value
        model.toggleChecked(persistentId: "P-A")
        model.setOutputDirectory(path: lockedDirectory.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: lockedDirectory.path
        )
        model.startQueue()
        #expect(await pollUntil { model.finishedRunReport != nil })

        #expect(model.runReportPath == nil)
        let failure = try #require(model.runReportWriteFailure)
        #expect(failure.contains(lockedDirectory.path))
    }

    /// Fix round 1, finding 2: the test harness must be hermetic — NO plist
    /// may ever materialize in the real ~/Library/Preferences (the leak
    /// class: one m7-tests-<UUID>.plist per harness).
    @Test("a harness lifecycle leaves zero files in the real Preferences directory")
    func harnessLeavesNoPreferencePlists() throws {
        let preferencesPath = ("~/Library/Preferences" as NSString).expandingTildeInPath
        let before = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: preferencesPath)) ?? []
        )

        let harness = try ModelHarness(runner: ScriptedRunner(outputs: []))
        harness.model.setConfirmEachApply(true) // the write that used to materialize it
        harness.model.setOutputDirectory(path: harness.outputDirectory.path)
        _ = harness.defaults.synchronize()
        harness.cleanUp()

        let after = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: preferencesPath)) ?? []
        )
        let leaked = after.subtracting(before).filter { $0.hasPrefix("m7-tests-") }
        #expect(leaked.isEmpty, "leaked preference plists: \(leaked)")
    }

    @Test("settings default off and persist across models on the same defaults suite")
    func settingsPersist() throws {
        let harness = try ModelHarness(runner: ScriptedRunner(outputs: []))
        defer { harness.cleanUp() }

        // The RAW app defaults (Sergio's): both OFF. Pinned via a direct
        // model over untouched (hermetic, in-memory) defaults — the harness
        // itself opts the pre-M11 tests into the attended flow.
        let fresh = AuditFlowModel(
            makeRunner: { ScriptedRunner(outputs: []) },
            defaults: InMemoryDefaults(),
            defaultOutputDirectoryPath: harness.outputDirectory.path,
            cacheDirectoryPath: harness.cacheDirectory.path
        )
        #expect(fresh.confirmEachApply == false)
        #expect(fresh.pauseOnJudgmentItems == false)

        harness.model.setConfirmEachApply(true)
        harness.model.setPauseOnJudgmentItems(true)
        let second = AuditFlowModel(
            makeRunner: { ScriptedRunner(outputs: []) },
            defaults: harness.defaults,
            defaultOutputDirectoryPath: harness.outputDirectory.path,
            cacheDirectoryPath: harness.cacheDirectory.path
        )
        #expect(second.confirmEachApply == true)
        #expect(second.pauseOnJudgmentItems == true)
    }
}

// MARK: - listing cache (browser only; audits stay live-read)

@MainActor
@Suite("M11 — listing cache")
struct ListingCacheTests {

    @Test("a scan persists the cache; a fresh model starts from it instantly")
    func cacheRoundTrip() async throws {
        let runner = ScriptedRunner(outputs: [m11ListingWire([("Alpha List", "P-A")])])
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false)
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        let scannedAt = try #require(harness.model.loadedListing?.scannedAt)
        #expect(harness.model.loadedListing?.fromCache == false)

        // A fresh model over the same cache directory loads WITHOUT any
        // runner call, marked as cached with the original timestamp.
        let coldRunner = ScriptedRunner(outputs: [])
        let second = AuditFlowModel(
            makeRunner: { coldRunner },
            defaults: harness.defaults,
            defaultOutputDirectoryPath: harness.outputDirectory.path,
            cacheDirectoryPath: harness.cacheDirectory.path
        )
        let cached = try #require(second.loadedListing)
        #expect(cached.fromCache)
        #expect(abs(cached.scannedAt.timeIntervalSince(scannedAt)) < 1.0)
        #expect(cached.listings.map(\.name) == ["Alpha List"])
        #expect(coldRunner.commands.isEmpty)
    }

    @Test("audits stay live-read from a cached listing; refresh re-scans live")
    func auditsStayLive() async throws {
        // Prime the cache.
        let primer = ScriptedRunner(outputs: [m11ListingWire([("Alpha List", "P-A")])])
        let primeHarness = try ModelHarness(runner: primer, mode: .consolidate, playlistName: "")
        defer { primeHarness.cleanUp() }
        primeHarness.model.rescanLibrary()
        await primeHarness.model.scanTask?.value

        // A fresh model from cache: its FIRST runner command is the audit's
        // own LIVE read — the cache never feeds an audit.
        let liveRunner = ScriptedRunner(outputs: [cleanConsolidateWire(name: "Alpha List")])
        let model = AuditFlowModel(
            makeRunner: { liveRunner },
            defaults: primeHarness.defaults,
            defaultOutputDirectoryPath: primeHarness.outputDirectory.path,
            cacheDirectoryPath: primeHarness.cacheDirectory.path
        )
        #expect(model.loadedListing?.fromCache == true)
        model.playlistName = "Alpha List"
        model.startAudit()
        await model.auditTask?.value
        #expect(model.result != nil)
        #expect(liveRunner.commands.count == 1)
        if case .readJXA(let script) = liveRunner.commands[0] {
            #expect(script == buildReadJXA(name: "Alpha List"))
        } else {
            Issue.record("the audit must be a live read")
        }
    }
}
