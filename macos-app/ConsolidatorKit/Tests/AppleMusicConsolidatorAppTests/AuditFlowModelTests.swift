// AuditFlowModelTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Headless tests for the M7 review→approve flow's view model. All Music I/O
// is driven through scripted ScriptRunner fakes (no OSAKit, no Apple events,
// no live Music); persistence goes to per-test temp directories; UserDefaults
// uses throwaway suites. Covers: audit happy paths (both modes), failure
// rendering (verbatim messages, automation vs library-state classes), the
// confirm-gate state machine (scalar-exact typed re-entry), output-dir
// override + persistence, stale-state reset, single-flight, and cancellation
// between phases.

import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

@Suite("Audit flow — consolidate happy path")
@MainActor
struct ConsolidateHappyPathTests {
    @Test("read → plan → artifacts → review state")
    func happyPath() async throws {
        let runner = ScriptedRunner(outputs: [consolidateFixtureWire()])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        #expect(model.runState == .idle)
        #expect(model.result == nil)

        model.startAudit()
        await harness.awaitAudit()

        #expect(model.runState == .idle)
        let result = try #require(model.result)
        #expect(result.mode == .consolidate)
        #expect(result.sourceName == "Fixture List")
        #expect(result.inputCount == 4)
        #expect(result.outputCount == 3)
        #expect(result.omittedCount == 1)
        #expect(result.nonEligibleCount == 1)
        #expect(result.fingerprint.count == 64)
        #expect(result.decisions.count == 1)

        // The one omission is the distinct-library-entries class (different
        // persistent ID, database ID, and bit rate).
        let displays = decisionDisplays(result.decisions)
        #expect(distinctOmissions(displays).count == 1)
        #expect(displays[0].omitted[0].reason == "bit rate")

        // Non-eligible tracks are listed, retained in place.
        #expect(result.nonEligibleTracks.map(\.persistentId) == ["AAAA0004"])

        // Artifact triple exists on disk; the reservation was released.
        #expect(FileManager.default.fileExists(atPath: result.paths.planJson))
        #expect(FileManager.default.fileExists(atPath: result.paths.detailCsv))
        #expect(FileManager.default.fileExists(atPath: result.paths.summaryMarkdown))
        #expect(try harness.artifactFileCount() == 3)

        // Freshness note inputs: plan basename and completion timestamp.
        let planFileName = try #require(model.planFileName)
        #expect(planFileName.hasPrefix("Fixture-List-"))
        #expect(planFileName.hasSuffix(".plan.json"))
        #expect(result.totalSeconds >= result.readSeconds)
        #expect(result.readSeconds >= 0)

        // Success auto-advances to the review step; the gate starts closed.
        #expect(model.step == .review)
        #expect(model.reviewedPlanToggle == false)
        #expect(model.typedTargetName.isEmpty)
        #expect(model.gateSatisfied == false)
        #expect(model.canApply == false)
        #expect(model.targetName == "Fixture List \u{2014} Consolidated")

        // Exactly one runner call: the single read JXA.
        #expect(runner.commands.count == 1)
        if case .readJXA = runner.commands[0] {} else {
            Issue.record("expected the only command to be the read JXA")
        }
    }
}

@Suite("Audit flow — merge happy path")
@MainActor
struct MergeHappyPathTests {
    @Test("copies in playlist-id order, provenance, counts")
    func mergeHappyPath() async throws {
        let runner = ScriptedRunner(outputs: [mergeFixtureWire()])
        let harness = try ModelHarness(
            runner: runner, mode: .merge, playlistName: "Merge List"
        )
        defer { harness.cleanUp() }
        let model = harness.model

        model.startAudit()
        await harness.awaitAudit()

        #expect(model.runState == .idle)
        let result = try #require(model.result)
        #expect(result.mode == .merge)
        #expect(result.sourceName == "Merge List")
        #expect(result.inputCount == 4)
        #expect(result.outputCount == 3)
        #expect(result.omittedCount == 1)
        #expect(result.nonEligibleCount == 0)

        guard case .merge(let plan) = result.plan else {
            Issue.record("expected a merge plan")
            return
        }
        // The wire listed id 20 before id 10; plan order must be ascending id.
        #expect(plan.copies.map(\.persistentId) == ["C-LOW", "C-HIGH"])
        #expect(plan.copies.map(\.tracks.count) == [2, 2])

        // Provenance: shared group spans both copies; each copy contributes
        // one unique output track... except the shared winner comes from
        // copy 0 (source order).
        let provenance = copyProvenance(plan)
        #expect(provenance.map(\.outputTrackCount) == [2, 1])
        #expect(provenance.map(\.uniqueContributionCount) == [1, 1])

        // The shared-track omission is the identical-library-track class.
        let displays = decisionDisplays(result.decisions)
        #expect(displays.count == 1)
        #expect(displays[0].omitted[0].classification == .identicalLibraryTrack)
        #expect(distinctOmissions(displays).isEmpty)

        #expect(model.targetName == "Merge List \u{2014} Merged")
        #expect(try harness.artifactFileCount() == 3)
    }
}

@Suite("Audit flow — failure rendering")
@MainActor
struct FailureRenderingTests {
    @Test("automation failure renders the verbatim MusicCommandError message")
    func automationFailure() async throws {
        let message = "JXA execution failed: error -1743: Not authorized to send Apple events to Music."
        let runner = ScriptedRunner(results: [.failure(MusicCommandError(message))])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        model.startAudit()
        await harness.awaitAudit()

        guard case .failed(let failure) = model.runState else {
            Issue.record("expected a failed run state, got \(model.runState)")
            return
        }
        #expect(failure.category == "Automation failed")
        #expect(failure.message == message)
        #expect(model.result == nil)
        #expect(model.step == .source)
        #expect(try harness.artifactFileCount() == 0)
    }

    @Test("library-state failure renders the verbatim MusicBridgeError message")
    func libraryStateFailure() async throws {
        // Invalid wire JSON surfaces the reference-verbatim parse rejection.
        let runner = ScriptedRunner(outputs: ["this is not JSON"])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        model.startAudit()
        await harness.awaitAudit()

        guard case .failed(let failure) = model.runState else {
            Issue.record("expected a failed run state, got \(model.runState)")
            return
        }
        #expect(failure.category == "Library state")
        #expect(failure.message == "Music returned invalid JSON")
        #expect(try harness.artifactFileCount() == 0)
    }

    @Test("missing playlist failure is a library-state class with the reference message")
    func missingPlaylist() async throws {
        let runner = ScriptedRunner(outputs: [wireSnapshot(playlists: [])])
        let harness = try ModelHarness(runner: runner, playlistName: "Absent")
        defer { harness.cleanUp() }
        let model = harness.model

        model.startAudit()
        await harness.awaitAudit()

        guard case .failed(let failure) = model.runState else {
            Issue.record("expected a failed run state, got \(model.runState)")
            return
        }
        #expect(failure.category == "Library state")
        #expect(failure.message == "expected exactly one user playlist named 'Absent'")
    }
}

@Suite("Confirm gate state machine")
@MainActor
struct ConfirmGateTests {
    @Test("all gate permutations; typed re-entry is scalar-exact")
    func gatePermutations() async throws {
        let runner = ScriptedRunner(outputs: [consolidateFixtureWire(name: "Caf\u{E9}")])
        let harness = try ModelHarness(runner: runner, playlistName: "Caf\u{E9}")
        defer { harness.cleanUp() }
        let model = harness.model

        model.startAudit()
        await harness.awaitAudit()
        try #require(model.result != nil)

        let target = "Caf\u{E9} \u{2014} Consolidated"
        #expect(model.targetName == target)

        // Nothing satisfied.
        #expect(model.gateSatisfied == false)
        #expect(model.canApply == false)

        // Toggle only.
        model.reviewedPlanToggle = true
        model.typedTargetName = ""
        #expect(model.gateSatisfied == false)

        // Typed only.
        model.reviewedPlanToggle = false
        model.typedTargetName = target
        #expect(model.gateSatisfied == false)

        // Toggle + wrong name.
        model.reviewedPlanToggle = true
        model.typedTargetName = "Caf\u{E9} \u{2014} Merged"
        #expect(model.gateSatisfied == false)

        // Toggle + canonically-equivalent but scalar-different name (NFD):
        // Swift String == would accept it; the gate must not.
        let nfdTyped = "Cafe\u{301} \u{2014} Consolidated"
        model.typedTargetName = nfdTyped
        #expect(nfdTyped == target) // canonical equivalence holds...
        #expect(model.gateSatisfied == false) // ...but the gate is scalar-exact.
        #expect(model.canApply == false)

        // Toggle + exact name: the gate opens and reveals the Apply action
        // (M9 — the CLI hand-off panel is gone).
        model.typedTargetName = target
        #expect(model.gateSatisfied == true)
        #expect(model.canApply == true)

        // Closing any gate withdraws the Apply action again.
        model.reviewedPlanToggle = false
        #expect(model.gateSatisfied == false)
        #expect(model.canApply == false)
    }

    @Test("the merge gate opens the apply action the same way")
    func mergeGate() async throws {
        let runner = ScriptedRunner(outputs: [mergeFixtureWire()])
        let harness = try ModelHarness(
            runner: runner, mode: .merge, playlistName: "Merge List"
        )
        defer { harness.cleanUp() }
        let model = harness.model

        model.startAudit()
        await harness.awaitAudit()
        try #require(model.result != nil)

        #expect(model.canApply == false)
        model.reviewedPlanToggle = true
        model.typedTargetName = "Merge List \u{2014} Merged"
        #expect(model.gateSatisfied == true)
        #expect(model.canApply == true)
    }
}

@Suite("Output directory override")
@MainActor
struct OutputDirectoryTests {
    @Test("override redirects artifacts and persists in UserDefaults")
    func overridePersists() async throws {
        let runner = ScriptedRunner(outputs: [consolidateFixtureWire()])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        let override = FileManager.default.temporaryDirectory
            .appendingPathComponent("m7-override-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: override) }

        model.setOutputDirectory(path: override.path)
        #expect(model.outputDirectoryPath == override.path)

        model.startAudit()
        await harness.awaitAudit()

        let result = try #require(model.result)
        #expect(result.paths.planJson.hasPrefix(override.path))
        #expect(try harness.artifactFileCount() == 0) // nothing in the default dir
        let overrideContents = try FileManager.default.contentsOfDirectory(atPath: override.path)
        #expect(overrideContents.count == 3)

        // Persisted: a fresh model over the same defaults suite starts there.
        let second = AuditFlowModel(
            makeRunner: { runner },
            defaults: harness.defaults,
            defaultOutputDirectoryPath: harness.outputDirectory.path
        )
        #expect(second.outputDirectoryPath == override.path)
    }
}

@Suite("Stale-state reset")
@MainActor
struct StaleStateResetTests {
    @Test("start over clears the plan, gates, and step")
    func startOverClears() async throws {
        let runner = ScriptedRunner(outputs: [consolidateFixtureWire(), consolidateFixtureWire()])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        model.startAudit()
        await harness.awaitAudit()
        try #require(model.result != nil)
        model.reviewedPlanToggle = true
        model.typedTargetName = model.targetName ?? ""
        #expect(model.gateSatisfied == true)

        model.startOver()
        #expect(model.result == nil)
        #expect(model.runState == .idle)
        #expect(model.step == .source)
        #expect(model.reviewedPlanToggle == false)
        #expect(model.typedTargetName.isEmpty)
        #expect(model.gateSatisfied == false)
        #expect(model.canApply == false)

        // A new audit still works after the reset.
        model.startAudit()
        await harness.awaitAudit()
        #expect(model.result != nil)
    }

    @Test("starting a new audit clears the previous plan before running")
    func newAuditClearsPreviousPlan() async throws {
        let runner = ScriptedRunner(outputs: [consolidateFixtureWire(), consolidateFixtureWire()])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        model.startAudit()
        await harness.awaitAudit()
        try #require(model.result != nil)
        model.reviewedPlanToggle = true
        model.typedTargetName = model.targetName ?? ""

        model.startAudit()
        // Synchronously after startAudit: the stale plan and gates are gone.
        #expect(model.result == nil)
        #expect(model.reviewedPlanToggle == false)
        #expect(model.typedTargetName.isEmpty)
        await harness.awaitAudit()
        #expect(model.result != nil)
    }

    @Test("changing mode discards a completed audit")
    func modeChangeDiscards() async throws {
        let runner = ScriptedRunner(outputs: [consolidateFixtureWire()])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        model.startAudit()
        await harness.awaitAudit()
        try #require(model.result != nil)

        model.setMode(.merge)
        #expect(model.result == nil)
        #expect(model.step == .source)
        #expect(model.gateSatisfied == false)
    }
}

@Suite("Single flight and cancellation")
@MainActor
struct SingleFlightAndCancellationTests {
    @Test("a second start while running is ignored")
    func singleFlight() async throws {
        let runner = BlockingRunner(payload: consolidateFixtureWire())
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        model.startAudit()
        #expect(await pollUntil { runner.runCount == 1 })
        #expect(model.isRunning)

        model.startAudit() // must be a no-op while running
        #expect(model.isRunning)

        runner.proceed.signal()
        await harness.awaitAudit()
        #expect(runner.runCount == 1)
        #expect(model.result != nil)
    }

    @Test("cancel during the read discards the result and writes nothing")
    func cancelBetweenPhases() async throws {
        let runner = BlockingRunner(payload: consolidateFixtureWire())
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        model.startAudit()
        #expect(await pollUntil { runner.runCount == 1 })
        guard case .running(.reading) = model.runState else {
            Issue.record("expected the reading phase, got \(model.runState)")
            return
        }

        model.cancelAudit()
        runner.proceed.signal() // the blocking read returns AFTER the cancel
        await harness.awaitAudit()

        #expect(model.runState == .cancelled)
        #expect(model.result == nil)
        #expect(try harness.artifactFileCount() == 0)
    }
}
