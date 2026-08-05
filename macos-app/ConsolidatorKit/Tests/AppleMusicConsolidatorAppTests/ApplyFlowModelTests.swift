// ApplyFlowModelTests.swift
// M9 — headless flow tests for IN-APP APPLY (screens 4-6). Everything rides
// scripted ScriptRunner fakes: no OSAKit, no Apple events, no live Music,
// and no script is ever executed. The contract pinned here:
//   - the apply path goes loadPlan/loadMergePlan(PERSISTED ARTIFACT) ->
//     MusicBridgeSession.applyPlan/applyMergePlan — never the in-memory plan
//     (loader rejections of a tampered artifact prove the artifact is what
//     is applied);
//   - the runner receives EXACTLY the M5 command sequence (dev-reference
//     cross-check: the app-layer transcript byte-matches a direct
//     MusicBridgeSession run over the same loaded plan);
//   - ONE APPLY PER FRESH AUDIT: success OR failure consumes the audit; the
//     write stage is never issued twice; re-apply is impossible without a
//     fresh audit (start over / next queue item);
//   - every failure class renders distinctly (PlanLoadError cases,
//     MusicCommandError = automation, MusicBridgeError = library drift,
//     verification failure with verbatim mismatches);
//   - single-flight; queue transitions including mid-queue failure.

import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

// MARK: - happy paths

@MainActor
@Suite("In-app apply — happy paths")
struct ApplyHappyPathTests {

    @Test("consolidate apply: artifact loaded, phases in order, success state")
    func consolidateHappyPath() async throws {
        let runner = ScriptedRunner(outputs: [consolidateFixtureWire()] + consolidateApplyOutputs())
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        try await harness.auditAndSatisfyGate()
        #expect(model.canApply)
        let auditResult = try #require(model.result)

        model.startApply()
        #expect(model.step == .apply)
        await harness.awaitApply()

        guard case .succeeded(let success) = model.applyState else {
            Issue.record("expected success, got \(model.applyState)")
            return
        }
        #expect(success.mode == .consolidate)
        #expect(success.targetName == "Fixture List \u{2014} Consolidated")
        #expect(success.trackCount == 3)
        #expect(success.plannedCount == 3)
        #expect(success.paths == auditResult.paths)
        #expect(success.fingerprint == auditResult.fingerprint)

        // The audit result survives for read-only review; the gate is
        // consumed: no re-apply.
        #expect(model.result != nil)
        #expect(model.isApplyConsumed)
        #expect(!model.canApply)

        // EXACTLY the M5 command sequence after the audit read: ensure
        // re-read, target-absent read, compile, execute, source readback,
        // target readback.
        let commands = runner.commands
        #expect(commands.count == 7)
        #expect(commands[1] == .readJXA(script: buildReadJXA(name: "Fixture List")))
        #expect(commands[2] == .readJXA(script: buildReadJXA(name: "Fixture List \u{2014} Consolidated")))
        guard case .compileAppleScript(let script, let outputPath) = commands[3] else {
            Issue.record("expected the compile at index 3: \(commands)")
            return
        }
        #expect(script.contains("make new user playlist"))
        #expect(outputPath.hasSuffix("writer.scpt"))
        #expect(commands[4] == .executeCompiledScript(path: outputPath))
        #expect(commands[5] == .readJXA(script: buildReadJXA(name: "Fixture List")))
        #expect(commands[6] == .readJXA(script: buildReadJXA(name: "Fixture List \u{2014} Consolidated")))

        // Stage progression: the app-level artifact load, then the six
        // bridge phases, in guarded order.
        let stages = try #require(model.completedApplyStages)
        #expect(stages == [
            .loadingPlan,
            .bridge(.rereadingSources),
            .bridge(.revalidating),
            .bridge(.assertingTargetAbsent),
            .bridge(.compilingWriter),
            .bridge(.executingGuardedWrite),
            .bridge(.verifyingReadback),
        ])
    }

    @Test("merge apply: artifact loaded via loadMergePlan, success state")
    func mergeHappyPath() async throws {
        let runner = ScriptedRunner(outputs: [mergeFixtureWire()] + mergeApplyOutputs())
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "Merge List")
        defer { harness.cleanUp() }
        let model = harness.model

        try await harness.auditAndSatisfyGate()
        #expect(model.canApply)

        model.startApply()
        await harness.awaitApply()

        guard case .succeeded(let success) = model.applyState else {
            Issue.record("expected success, got \(model.applyState)")
            return
        }
        #expect(success.mode == .merge)
        #expect(success.targetName == "Merge List \u{2014} Merged")
        #expect(success.trackCount == 3)

        let commands = runner.commands
        #expect(commands.count == 7)
        #expect(commands[1] == .readJXA(script: buildReadJXA(name: "Merge List")))
        #expect(commands[2] == .readJXA(script: buildReadJXA(name: "Merge List \u{2014} Merged")))
        guard case .compileAppleScript(_, let outputPath) = commands[3] else {
            Issue.record("expected the compile at index 3: \(commands)")
            return
        }
        #expect(outputPath.hasSuffix("merge-writer.scpt"))
        #expect(commands[4] == .executeCompiledScript(path: outputPath))
    }

    /// Dev-reference cross-check: the app layer adds NO script content of its
    /// own — its transcript byte-matches a direct M5 orchestration run over
    /// the SAME persisted plan artifact (the M5 pins govern that run).
    @Test("app-layer transcript byte-matches the direct M5 orchestration transcript")
    func transcriptMatchesDirectOrchestration() async throws {
        let appRunner = ScriptedRunner(outputs: [consolidateFixtureWire()] + consolidateApplyOutputs())
        let harness = try ModelHarness(runner: appRunner)
        defer { harness.cleanUp() }

        try await harness.auditAndSatisfyGate()
        let planPath = try #require(harness.model.result?.paths.planJson)
        harness.model.startApply()
        await harness.awaitApply()
        if case .succeeded = harness.model.applyState {} else {
            Issue.record("expected apply success, got \(harness.model.applyState)")
        }

        // Direct M5 run: same artifact through the fail-closed loader, same
        // target, fresh fake with the identical apply outputs.
        let directRunner = ScriptedRunner(outputs: consolidateApplyOutputs())
        let plan = try loadPlan(from: URL(fileURLWithPath: planPath))
        let session = MusicBridgeSession(runner: directRunner)
        let direct = try session.applyPlan(
            plan: plan, targetName: "Fixture List \u{2014} Consolidated"
        )
        #expect(direct.verificationOk == true)

        let appApply = Array(appRunner.commands.dropFirst()) // drop the audit read
        let directCommands = directRunner.commands
        #expect(appApply.count == directCommands.count)
        var appCompilePath: String?
        var directCompilePath: String?
        for (index, pair) in zip(appApply, directCommands).enumerated() {
            switch (pair.0, pair.1) {
            case (.readJXA(let a), .readJXA(let b)):
                // Scalar-exact, never String ==: canonical equivalence would
                // mask NFC/NFD drift sneaking in at the app layer.
                #expect(scalarExact(a, b), "read script diverged at apply command \(index)")
            case (.compileAppleScript(let a, let aPath), .compileAppleScript(let b, let bPath)):
                #expect(scalarExact(a, b), "writer script diverged at apply command \(index)")
                #expect(
                    (aPath as NSString).lastPathComponent
                        == (bPath as NSString).lastPathComponent
                )
                appCompilePath = aPath
                directCompilePath = bPath
            case (.executeCompiledScript(let a), .executeCompiledScript(let b)):
                #expect(a == appCompilePath)
                #expect(b == directCompilePath)
            default:
                Issue.record("command kind mismatch at apply command \(index)")
            }
        }
    }
}

// MARK: - loader rejections (the plan is applied FROM THE ARTIFACT)

@MainActor
@Suite("In-app apply — tampered artifact is rejected by the loader")
struct ApplyLoaderRejectionTests {

    private func auditedHarness() async throws -> (ModelHarness, ScriptedRunner) {
        let runner = ScriptedRunner(outputs: [consolidateFixtureWire()])
        let harness = try ModelHarness(runner: runner)
        try await harness.auditAndSatisfyGate()
        return (harness, runner)
    }

    private func applyAndExpectFailure(
        _ harness: ModelHarness,
        _ runner: ScriptedRunner
    ) async -> ApplyFailureDisplay? {
        harness.model.startApply()
        await harness.awaitApply()
        // The apply never reached Music: the only command remains the
        // audit's own read.
        #expect(runner.commands.count == 1)
        guard case .failed(let failure) = harness.model.applyState else {
            Issue.record("expected a failed apply, got \(harness.model.applyState)")
            return nil
        }
        // Consumed: no re-apply without a fresh audit.
        #expect(!harness.model.canApply)
        harness.model.startApply()
        #expect(runner.commands.count == 1)
        return failure
    }

    @Test("a deleted plan file fails as fileUnreadable with its own copy")
    func fileUnreadable() async throws {
        let (harness, runner) = try await auditedHarness()
        defer { harness.cleanUp() }
        let planPath = try #require(harness.model.result?.paths.planJson)
        try FileManager.default.removeItem(atPath: planPath)

        let failure = await applyAndExpectFailure(harness, runner)
        #expect(failure?.failureClass == .planFileUnreadable)
        #expect(failure?.headline == "Plan file unreadable")
    }

    @Test("a syntactically corrupted plan file fails as malformedJSON")
    func malformedJSON() async throws {
        let (harness, runner) = try await auditedHarness()
        defer { harness.cleanUp() }
        let planPath = try #require(harness.model.result?.paths.planJson)
        try Data("this is not JSON".utf8).write(to: URL(fileURLWithPath: planPath))

        let failure = await applyAndExpectFailure(harness, runner)
        #expect(failure?.failureClass == .planMalformedJSON)
        #expect(failure?.headline == "Plan file rejected \u{2014} not valid JSON")
    }

    @Test("a schema-tampered plan file fails as decodeRejected")
    func decodeRejected() async throws {
        let (harness, runner) = try await auditedHarness()
        defer { harness.cleanUp() }
        let planPath = try #require(harness.model.result?.paths.planJson)
        let url = URL(fileURLWithPath: planPath)
        let text = try String(contentsOf: url, encoding: .utf8)
        let tampered = text.replacingOccurrences(
            of: "\"winner_source_indexes\"", with: "\"winner_source_indexes_x\""
        )
        #expect(tampered != text)
        try Data(tampered.utf8).write(to: url)

        let failure = await applyAndExpectFailure(harness, runner)
        #expect(failure?.failureClass == .planDecodeRejected)
        #expect(failure?.headline == "Plan file rejected \u{2014} strict decode failed")
    }

    @Test("a fingerprint-tampered plan file fails as integrityRejected")
    func integrityRejected() async throws {
        let (harness, runner) = try await auditedHarness()
        defer { harness.cleanUp() }
        let result = try #require(harness.model.result)
        let url = URL(fileURLWithPath: result.paths.planJson)
        let text = try String(contentsOf: url, encoding: .utf8)
        let tampered = text.replacingOccurrences(
            of: result.fingerprint, with: String(repeating: "0", count: 64)
        )
        #expect(tampered != text)
        try Data(tampered.utf8).write(to: url)

        let failure = await applyAndExpectFailure(harness, runner)
        #expect(failure?.failureClass == .planIntegrityRejected)
        #expect(failure?.headline == "Plan file rejected \u{2014} integrity check failed")
    }
}

// MARK: - the M5 failure taxonomy at the app layer

@MainActor
@Suite("In-app apply — failure classes")
struct ApplyFailureDisplayClassTests {

    @Test("an automation failure during the apply renders its verbatim message")
    func automationFailure() async throws {
        let message = "JXA execution failed: error -1743: Not authorized to send Apple events to Music."
        let runner = ScriptedRunner(results: [
            .success(consolidateFixtureWire()),
            .failure(MusicCommandError(message)),
        ])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }

        try await harness.auditAndSatisfyGate()
        harness.model.startApply()
        await harness.awaitApply()

        guard case .failed(let failure) = harness.model.applyState else {
            Issue.record("expected a failed apply")
            return
        }
        #expect(failure.failureClass == .automationFailed)
        #expect(failure.headline == "Automation failed")
        #expect(failure.message == message)
        // No write was ever dispatched.
        #expect(runner.commands.count == 2)
        #expect(!harness.model.canApply)
    }

    @Test("library drift fails closed before any write; the write stage is never issued")
    func libraryDrift() async throws {
        // The apply's ensure re-read returns a DIFFERENT library state than
        // the audited one (bit rate flipped on the winner).
        let drifted = wireSnapshot(playlists: [
            wirePlaylist(
                id: 100, name: "Fixture List", persistentId: "PLAYLIST0",
                tracks: [
                    wireTrack(
                        sourceIndex: 0, databaseId: 11, persistentId: "AAAA0001",
                        title: "Shared Song", bitRate: 96
                    ),
                    wireTrack(
                        sourceIndex: 1, databaseId: 12, persistentId: "AAAA0002",
                        title: "Shared Song", bitRate: 256
                    ),
                    wireTrack(
                        sourceIndex: 2, databaseId: 13, persistentId: "AAAA0003",
                        title: "Only Once"
                    ),
                    wireTrack(
                        sourceIndex: 3, databaseId: 14, persistentId: "AAAA0004",
                        title: "No Duration", duration: nil
                    ),
                ]
            )
        ])
        let runner = ScriptedRunner(outputs: [consolidateFixtureWire(), drifted])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }

        try await harness.auditAndSatisfyGate()
        harness.model.startApply()
        await harness.awaitApply()

        guard case .failed(let failure) = harness.model.applyState else {
            Issue.record("expected a failed apply")
            return
        }
        #expect(failure.failureClass == .libraryDrift)
        #expect(failure.headline == "Library changed since the audit")
        #expect(failure.message.contains("changed after audit"))
        #expect(failure.message.contains("create a fresh audit"))
        // Only the audit read + the ensure re-read ever ran: no target
        // lookup, no compile, no execute.
        #expect(runner.commands.count == 2)
        for command in runner.commands {
            if case .readJXA = command {} else {
                Issue.record("non-read command dispatched on the drift path: \(command)")
            }
        }
    }

    @Test("a writer failure returns fail-closed diagnostics; exactly one write was issued")
    func writerFailure() async throws {
        let runner = ScriptedRunner(results: [
            .success(consolidateFixtureWire()),
            .success(consolidateFixtureWire()),
            .success(emptySnapshotWire()),
            .success(""),
            .failure(MusicCommandError("simulated writer failure")),
            .success(consolidateFixtureWire()),
            .success(emptySnapshotWire()),
        ])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }

        try await harness.auditAndSatisfyGate()
        harness.model.startApply()
        await harness.awaitApply()

        guard case .failed(let failure) = harness.model.applyState else {
            Issue.record("expected a failed apply")
            return
        }
        #expect(failure.failureClass == .verificationFailed)
        #expect(failure.mismatches.first == "write failed: simulated writer failure")
        #expect(failure.mismatches.contains { $0.contains("no exact-name target exists") })
        #expect(failure.actualCount == 0)

        // The write stage was issued exactly once — never retried (the M5
        // no-post-failure-mutation pins extended to the app layer).
        let executes = runner.commands.filter {
            if case .executeCompiledScript = $0 { return true }
            return false
        }
        let compiles = runner.commands.filter {
            if case .compileAppleScript = $0 { return true }
            return false
        }
        #expect(executes.count == 1)
        #expect(compiles.count == 1)
        #expect(!harness.model.canApply)
    }

    @Test("a readback mismatch fails with verbatim mismatches and a partial-target count")
    func readbackMismatch() async throws {
        // Target readback comes back in REVERSED order.
        let reversedTarget = wireSnapshot(playlists: [
            wirePlaylist(
                id: 900,
                name: "Fixture List \u{2014} Consolidated",
                persistentId: "TARGET0",
                tracks: [
                    wireTrack(
                        sourceIndex: 0, databaseId: 14, persistentId: "AAAA0004",
                        title: "No Duration", duration: nil
                    ),
                    wireTrack(
                        sourceIndex: 1, databaseId: 13, persistentId: "AAAA0003",
                        title: "Only Once"
                    ),
                    wireTrack(
                        sourceIndex: 2, databaseId: 12, persistentId: "AAAA0002",
                        title: "Shared Song", bitRate: 256
                    ),
                ]
            )
        ])
        let runner = ScriptedRunner(outputs: [
            consolidateFixtureWire(),
            consolidateFixtureWire(),
            emptySnapshotWire(),
            "",
            "",
            consolidateFixtureWire(),
            reversedTarget,
        ])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }

        try await harness.auditAndSatisfyGate()
        harness.model.startApply()
        await harness.awaitApply()

        guard case .failed(let failure) = harness.model.applyState else {
            Issue.record("expected a failed apply")
            return
        }
        #expect(failure.failureClass == .verificationFailed)
        #expect(!failure.mismatches.isEmpty)
        #expect(failure.mismatches.contains {
            $0.contains("database ID mismatch") || $0.contains("persistent ID mismatch")
        })
        #expect(failure.actualCount == 3)
        #expect(failure.plannedCount == 3)
    }
}

// MARK: - one apply per audit + single flight

@MainActor
@Suite("In-app apply — consumption and single flight")
struct ApplyConsumptionTests {

    @Test("a successful apply consumes the audit; start over is the only path back")
    func successConsumes() async throws {
        let runner = ScriptedRunner(
            outputs: [consolidateFixtureWire()] + consolidateApplyOutputs()
                + [consolidateFixtureWire()]
        )
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        try await harness.auditAndSatisfyGate()
        model.startApply()
        await harness.awaitApply()
        if case .succeeded = model.applyState {} else {
            Issue.record("expected success")
        }
        let commandCount = runner.commands.count

        // Re-apply is impossible: no state change, no new commands.
        model.startApply()
        #expect(runner.commands.count == commandCount)
        if case .succeeded = model.applyState {} else {
            Issue.record("a refused re-apply must not disturb the success state")
        }

        // Start over clears everything; a fresh audit works.
        model.startOver()
        if case .idle = model.applyState {} else {
            Issue.record("start over must reset the apply state")
        }
        #expect(model.result == nil)
        #expect(!model.gateSatisfied)
        model.startAudit()
        await harness.awaitAudit()
        #expect(model.result != nil)
        if case .idle = model.applyState {} else {
            Issue.record("a fresh audit must start with an idle apply state")
        }
    }

    @Test("a failed apply equally consumes the audit")
    func failureConsumes() async throws {
        let runner = ScriptedRunner(results: [
            .success(consolidateFixtureWire()),
            .failure(MusicCommandError("boom")),
        ])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }

        try await harness.auditAndSatisfyGate()
        harness.model.startApply()
        await harness.awaitApply()
        if case .failed = harness.model.applyState {} else {
            Issue.record("expected failure")
        }
        #expect(!harness.model.canApply)
        harness.model.startApply()
        #expect(runner.commands.count == 2)
        // The consumed plan remains reviewable read-only.
        #expect(harness.model.canNavigate(to: .review))
    }

    @Test("apply is single-flight and mutually exclusive with reads; navigation locks")
    func singleFlight() async throws {
        // Block on the apply's FIRST command (index 1: the ensure re-read).
        let runner = StagedBlockingRunner(
            outputs: [consolidateFixtureWire()] + consolidateApplyOutputs(),
            blockAt: [1]
        )
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        try await harness.auditAndSatisfyGate()
        model.startApply()
        #expect(await pollUntil { runner.runCount == 2 })
        #expect(model.isApplying)

        // Second apply: no-op (single-flight).
        model.startApply()
        #expect(runner.runCount == 2)

        // Reads are refused while the apply holds the OSA slot.
        model.startAudit()
        #expect(model.result != nil) // the audit was NOT discarded
        #expect(!model.isRunning)
        model.rescanLibrary()
        #expect(!model.isScanning)

        // Navigation is locked to the apply screen.
        #expect(!model.canNavigate(to: .review))
        #expect(!model.canNavigate(to: .source))
        #expect(model.canNavigate(to: .apply))
        model.navigate(to: .review)
        #expect(model.step == .apply)

        // Start over is refused mid-apply (the write may be in flight).
        model.startOver()
        #expect(model.result != nil)
        #expect(model.isApplying)

        runner.proceed.signal()
        await harness.awaitApply()
        if case .succeeded = model.applyState {} else {
            Issue.record("expected the released apply to succeed, got \(model.applyState)")
        }
    }
}

// MARK: - fix round 1, finding 1: mode changes mid-apply

@MainActor
@Suite("In-app apply — mode-change guard (fix round 1)")
struct ApplyModeChangeGuardTests {

    /// The orphaned-apply regression: a mid-apply mode flip used to bump the
    /// generation and reset apply state, silently DROPPING the guarded
    /// write's outcome (including fail-closed diagnostics after a write that
    /// may have landed in Music). The mode change must be refused; the
    /// outcome must land on screen 6.
    @Test("a mid-apply mode change is refused; the apply outcome still lands")
    func modeChangeRefusedMidApply() async throws {
        // Writer-failure scenario: the outcome is fail-closed DIAGNOSTICS —
        // exactly the evidence a dropped outcome would have destroyed.
        let failingRunner = StagedBlockingRunnerResults(
            results: [
                .success(consolidateFixtureWire()),          // 0: audit read
                .success(consolidateFixtureWire()),          // 1: ensure (BLOCKED)
                .success(emptySnapshotWire()),               // 2: target absent
                .success(""),                                // 3: compile
                .failure(MusicCommandError("writer blew up")), // 4: execute
                .success(consolidateFixtureWire()),          // 5: source readback
                .success(emptySnapshotWire()),               // 6: target readback
            ],
            blockAt: [1]
        )
        let harness = try ModelHarness(runner: failingRunner)
        defer { harness.cleanUp() }
        let model = harness.model

        try await harness.auditAndSatisfyGate()
        model.startApply()
        #expect(await pollUntil { failingRunner.runCount == 2 })
        #expect(model.isApplying)

        // The mode change is REFUSED while the apply runs.
        model.setMode(.merge)
        #expect(model.mode == .consolidate)
        #expect(model.result != nil)
        #expect(model.isApplying)

        failingRunner.proceed.signal()
        await harness.awaitApply()

        // The outcome landed: fail-closed diagnostics, not silence.
        guard case .failed(let failure) = model.applyState else {
            Issue.record("the apply outcome was dropped: \(model.applyState)")
            return
        }
        #expect(failure.failureClass == .verificationFailed)
        #expect(failure.mismatches.first == "write failed: writer blew up")

        // After the apply finished, a mode change works again and discards.
        model.setMode(.merge)
        #expect(model.mode == .merge)
        #expect(model.result == nil)
        if case .idle = model.applyState {} else {
            Issue.record("a legal mode change must reset the apply state")
        }
    }

    @Test("a same-mode set is a no-op and never discards")
    func sameModeSetIsNoOp() async throws {
        let runner = ScriptedRunner(outputs: [consolidateFixtureWire()])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        model.startAudit()
        await harness.awaitAudit()
        try #require(model.result != nil)

        model.setMode(.consolidate)
        #expect(model.result != nil)
        #expect(model.step == .review)
    }
}

/// StagedBlockingRunner over explicit Result values (failure injection +
/// blocking in one fake).
final class StagedBlockingRunnerResults: ScriptRunner, @unchecked Sendable {
    let proceed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var results: [Result<String, Error>]
    private let blockAt: Set<Int>
    private var callCount = 0

    init(results: [Result<String, Error>], blockAt: Set<Int>) {
        self.results = results
        self.blockAt = blockAt
    }

    var runCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    @discardableResult
    func run(_ command: ScriptCommand) throws -> String {
        lock.lock()
        let index = callCount
        callCount += 1
        let next = results.isEmpty ? nil : results.removeFirst()
        lock.unlock()
        if blockAt.contains(index) { proceed.wait() }
        guard let next else {
            throw AppTestError("StagedBlockingRunnerResults has no scripted output left")
        }
        return try next.get()
    }
}

// MARK: - queue wiring

@MainActor
@Suite("In-app apply — queue transitions")
struct ApplyQueueTests {

    private func listingWire() -> String {
        let entries = [
            """
            {"id": 30, "name": "Fixture List", "persistent_id": "P-FIX", \
            "track_count": 4, "smart": false, "special_kind": "none"}
            """,
            """
            {"id": 40, "name": "Solo List", "persistent_id": "P-SOLO", \
            "track_count": 4, "smart": false, "special_kind": "none"}
            """,
        ]
        return "{\"playlists\": [\(entries.joined(separator: ", "))]}"
    }

    @Test("apply success marks the item applied; continue starts the next audit")
    func applySuccessAdvancesQueue() async throws {
        let runner = ScriptedRunner(
            outputs: [listingWire(), consolidateFixtureWire(name: "Fixture List")]
                + consolidateApplyOutputs(name: "Fixture List")
                + [consolidateFixtureWire(name: "Solo List")]
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        let model = harness.model

        model.rescanLibrary()
        await model.scanTask?.value
        model.toggleChecked(persistentId: "P-FIX")
        model.toggleChecked(persistentId: "P-SOLO")
        model.startQueue()
        await harness.awaitAudit()
        #expect(model.queue.map(\.status) == [.audited, .pending])

        // Continue is refused until the item's apply has succeeded.
        model.continueQueueAfterApply()
        #expect(model.queue.map(\.status) == [.audited, .pending])

        model.reviewedPlanToggle = true
        model.typedTargetName = try #require(model.targetName)
        model.startApply()
        await harness.awaitApply()
        #expect(model.queue.map(\.status) == [.applied, .pending])

        model.continueQueueAfterApply()
        await harness.awaitAudit()
        #expect(model.queue.map(\.status) == [.applied, .audited])
        #expect(model.result?.sourceName == "Solo List")
        // The next item starts with a clean gate and an idle apply.
        #expect(model.reviewedPlanToggle == false)
        if case .idle = model.applyState {} else {
            Issue.record("the next queue item must start with an idle apply state")
        }
    }

    @Test("a mid-queue apply failure marks the item failed; retry is a fresh audit")
    func midQueueFailureAndRetry() async throws {
        let runner = ScriptedRunner(results: [
            .success(listingWire()),
            .success(consolidateFixtureWire(name: "Fixture List")),
            .failure(MusicCommandError("apply blew up")),
            .success(consolidateFixtureWire(name: "Fixture List")),
        ])
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        let model = harness.model

        model.rescanLibrary()
        await model.scanTask?.value
        model.toggleChecked(persistentId: "P-FIX")
        model.startQueue()
        await harness.awaitAudit()
        #expect(model.queue.map(\.status) == [.audited])

        model.reviewedPlanToggle = true
        model.typedTargetName = try #require(model.targetName)
        model.startApply()
        await harness.awaitApply()
        #expect(model.queue.map(\.status) == [.failed])
        if case .failed(let failure) = model.applyState {
            #expect(failure.failureClass == .automationFailed)
        } else {
            Issue.record("expected a failed apply state")
        }

        // Retry = a FRESH audit of the item (round-1 queue semantics).
        model.retryCurrentQueueItem()
        await harness.awaitAudit()
        #expect(model.queue.map(\.status) == [.audited])
        #expect(model.result?.sourceName == "Fixture List")
        if case .idle = model.applyState {} else {
            Issue.record("retry must reset the apply state")
        }
    }

    @Test("skip can never overwrite an applied item (the write happened)")
    func skipAfterAppliedIsNoOp() async throws {
        let runner = ScriptedRunner(
            outputs: [listingWire(), consolidateFixtureWire(name: "Fixture List")]
                + consolidateApplyOutputs(name: "Fixture List")
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        let model = harness.model

        model.rescanLibrary()
        await model.scanTask?.value
        model.toggleChecked(persistentId: "P-FIX")
        model.startQueue()
        await harness.awaitAudit()
        model.reviewedPlanToggle = true
        model.typedTargetName = try #require(model.targetName)
        model.startApply()
        await harness.awaitApply()
        #expect(model.queue.map(\.status) == [.applied])

        // Fix round 1, finding 2: the playlist WAS created in Music — Skip
        // must never rewrite the record to .skipped.
        model.skipCurrentQueueItem()
        #expect(model.queue.map(\.status) == [.applied])
        #expect(model.currentQueueItem?.name == "Fixture List")
        #expect(!model.isQueueComplete)

        // The legitimate path out is unchanged.
        model.continueQueueAfterApply()
        #expect(model.isQueueComplete)
    }

    @Test("dismissQueue is refused while an apply is in flight")
    func dismissQueueRefusedDuringApply() async throws {
        let runner = StagedBlockingRunner(
            outputs: [listingWire(), consolidateFixtureWire(name: "Fixture List")]
                + consolidateApplyOutputs(name: "Fixture List"),
            blockAt: [2]
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        let model = harness.model

        model.rescanLibrary()
        await model.scanTask?.value
        model.toggleChecked(persistentId: "P-FIX")
        model.startQueue()
        await harness.awaitAudit()
        model.reviewedPlanToggle = true
        model.typedTargetName = try #require(model.targetName)
        model.startApply()
        #expect(await pollUntil { runner.runCount == 3 })
        #expect(model.isApplying)

        // Fix round 1, folded minor a: the same guard every other queue
        // action carries.
        model.dismissQueue()
        #expect(model.isQueueActive)
        #expect(model.queue.map(\.name) == ["Fixture List"])

        runner.proceed.signal()
        await harness.awaitApply()
        #expect(model.queue.map(\.status) == [.applied])
    }

    @Test("queue actions are refused while an apply is in flight")
    func queueActionsRefusedDuringApply() async throws {
        let runner = StagedBlockingRunner(
            outputs: [listingWire(), consolidateFixtureWire(name: "Fixture List")]
                + consolidateApplyOutputs(name: "Fixture List"),
            blockAt: [2] // the apply's ensure re-read
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        let model = harness.model

        model.rescanLibrary()
        await model.scanTask?.value
        model.toggleChecked(persistentId: "P-FIX")
        model.startQueue()
        await harness.awaitAudit()

        model.reviewedPlanToggle = true
        model.typedTargetName = try #require(model.targetName)
        model.startApply()
        #expect(await pollUntil { runner.runCount == 3 })
        #expect(model.isApplying)

        model.skipCurrentQueueItem()
        #expect(model.queue.map(\.status) == [.audited])
        model.continueQueueAfterApply()
        #expect(model.currentQueueItem?.name == "Fixture List")

        runner.proceed.signal()
        await harness.awaitApply()
        #expect(model.queue.map(\.status) == [.applied])
    }
}
