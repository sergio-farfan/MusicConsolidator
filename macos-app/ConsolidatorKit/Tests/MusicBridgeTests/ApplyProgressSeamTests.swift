// ApplyProgressSeamTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// M9 — the ADDITIVE apply-progress seam on MusicBridgeSession: an optional
// phase callback the orchestration invokes at its EXISTING internal stage
// boundaries (re-reading source(s) → revalidating → asserting target absent
// → compiling → executing guarded write → readback verify). The contract
// pinned here:
//   - phase ORDER on the happy path, both modes (FakeRunner-driven);
//   - failure paths STOP at the failing boundary and never reach the write
//     phases (fail-closed order preserved);
//   - a writer failure still reaches the read-only readback-inspection phase;
//   - callback nil ⇒ BYTE-IDENTICAL behavior: command transcript and
//     ApplyResult equal to a callback-carrying run over the same fixtures
//     (the only run-to-run variance is the compile artifact's UUID temp
//     directory, which differs between ANY two runs; the pin compares script
//     bytes per command and the compile→execute path linkage instead).
// No script is ever executed; all commands ride FakeRunner.

import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

// MARK: - wire fixtures (the read JXA's output shape; duration in SECONDS)

private func seamWireTrack(_ track: TrackSnapshot) -> String {
    let duration = track.durationMs.map { String(Double($0) / 1000.0) } ?? "null"
    let bitRate = track.bitRateKbps.map(String.init) ?? "null"
    let sampleRate = track.sampleRateHz.map(String.init) ?? "null"
    return """
    {"source_index": \(track.sourceIndex), "database_id": \(track.databaseId), \
    "persistent_id": "\(track.persistentId)", "title": "\(track.title)", \
    "artist": "\(track.artist)", "album": "\(track.album)", \
    "duration": \(duration), "kind": "\(track.kind)", \
    "bit_rate": \(bitRate), "sample_rate": \(sampleRate), \
    "cloud_status": "\(track.cloudStatus)", "is_file_track": \(track.isFileTrack)}
    """
}

private func seamWirePlaylist(_ playlist: PlaylistSnapshot, id: Int) -> String {
    """
    {"id": \(id), "name": "\(playlist.name)", "persistent_id": "\(playlist.persistentId)", \
    "tracks": [\(playlist.tracks.map(seamWireTrack).joined(separator: ", "))]}
    """
}

private func seamWireSnapshot(_ playlists: [(PlaylistSnapshot, Int)]) -> String {
    "{\"playlists\": [\(playlists.map { seamWirePlaylist($0.0, id: $0.1) }.joined(separator: ", "))]}"
}

private let emptyWireSnapshot = "{\"playlists\": []}"

/// The consolidate fixture: the M5 orchestration source (2 distinct tracks).
private func seamSource() -> PlaylistSnapshot {
    orchestrationSourceSnapshot()
}

/// Target readback matching the plan's winners exactly (db ids + pids in
/// order are what the verifier compares).
private func seamTargetReadback(name: String, tracks: [TrackSnapshot]) -> PlaylistSnapshot {
    PlaylistSnapshot(name: name, persistentId: "T", tracks: tracks)
}

/// The full happy-path consolidate apply transcript outputs, in dispatch
/// order: ensure read, target-absent read, compile, execute, source
/// readback, target readback.
private func consolidateHappyOutputs() throws -> (plan: ConsolidationPlan, outputs: [String]) {
    let source = seamSource()
    let plan = try buildPlan(source)
    let sourceWire = seamWireSnapshot([(source, 100)])
    let winners = plan.winnerSourceIndexes.map { source.tracks[$0] }
    let targetWire = seamWireSnapshot([(seamTargetReadback(name: "Target", tracks: winners), 900)])
    return (plan, [sourceWire, emptyWireSnapshot, "", "", sourceWire, targetWire])
}

/// The merge fixture: two same-name copies with distinct tracks (no dups),
/// so winners == the combined list.
private func seamMergeCopies() -> [PlaylistSnapshot] {
    [
        PlaylistSnapshot(
            name: "G",
            persistentId: "PID-A",
            tracks: [track(sourceIndex: 0, databaseId: 1, persistentId: "A0")]
        ),
        PlaylistSnapshot(
            name: "G",
            persistentId: "PID-B",
            tracks: [track(sourceIndex: 0, databaseId: 2, persistentId: "B0", title: "Two")]
        ),
    ]
}

private func mergeHappyOutputs() throws -> (plan: MergePlan, outputs: [String]) {
    let copies = seamMergeCopies()
    let plan = try buildMergePlan(name: "G", copies: copies)
    let copiesWire = seamWireSnapshot([(copies[0], 10), (copies[1], 20)])
    let combined = plan.combinedTracks
    let winners = plan.winnerSourceIndexes.map { combined[$0] }
    let targetWire = seamWireSnapshot([(seamTargetReadback(name: "G — Merged", tracks: winners), 900)])
    return (plan, [copiesWire, emptyWireSnapshot, "", "", copiesWire, targetWire])
}

/// Record phases synchronously (the callback fires on the calling thread).
private final class PhaseRecorder {
    private(set) var phases: [ApplyPhase] = []

    func callback() -> (ApplyPhase) -> Void {
        { [self] phase in phases.append(phase) }
    }
}

private func commandKinds(_ commands: [ScriptCommand]) -> [String] {
    commands.map { command in
        switch command {
        case .readJXA: return "read"
        case .compileAppleScript: return "compile"
        case .executeCompiledScript: return "execute"
        }
    }
}

// MARK: - happy-path order, both modes

@Suite("Apply progress seam (M9) — phase order")
struct ApplyProgressPhaseOrderTests {

    @Test("consolidate apply emits the six phases in guarded order")
    func consolidatePhaseOrder() throws {
        let (plan, outputs) = try consolidateHappyOutputs()
        let runner = FakeRunner(outputs: outputs)
        let session = MusicBridgeSession(runner: runner)
        let recorder = PhaseRecorder()
        session.applyProgress = recorder.callback()

        let result = try session.applyPlan(plan: plan, targetName: "Target")

        #expect(result.verificationOk == true)
        #expect(recorder.phases == [
            .rereadingSources,
            .revalidating,
            .assertingTargetAbsent,
            .compilingWriter,
            .executingGuardedWrite,
            .verifyingReadback,
        ])
        #expect(commandKinds(runner.calls)
            == ["read", "read", "compile", "execute", "read", "read"])
    }

    @Test("merge apply emits the six phases in guarded order")
    func mergePhaseOrder() throws {
        let (plan, outputs) = try mergeHappyOutputs()
        let runner = FakeRunner(outputs: outputs)
        let session = MusicBridgeSession(runner: runner)
        let recorder = PhaseRecorder()
        session.applyProgress = recorder.callback()

        let result = try session.applyMergePlan(plan: plan, targetName: "G — Merged")

        #expect(result.verificationOk == true)
        #expect(recorder.phases == [
            .rereadingSources,
            .revalidating,
            .assertingTargetAbsent,
            .compilingWriter,
            .executingGuardedWrite,
            .verifyingReadback,
        ])
        #expect(commandKinds(runner.calls)
            == ["read", "read", "compile", "execute", "read", "read"])
    }
}

// MARK: - failure paths stop at the failing boundary

@Suite("Apply progress seam (M9) — fail-closed boundaries")
struct ApplyProgressFailureBoundaryTests {

    @Test("source drift stops after revalidating; the write phases never fire")
    func driftStopsAtRevalidation() throws {
        let source = seamSource()
        let plan = try buildPlan(source)
        var driftedTrack = source.tracks[0]
        driftedTrack.title = "Changed"
        let drifted = PlaylistSnapshot(
            name: source.name, persistentId: source.persistentId,
            tracks: [driftedTrack, source.tracks[1]]
        )
        let runner = FakeRunner(outputs: [seamWireSnapshot([(drifted, 100)])])
        let session = MusicBridgeSession(runner: runner)
        let recorder = PhaseRecorder()
        session.applyProgress = recorder.callback()

        #expect(throws: MusicBridgeError.self) {
            try session.applyPlan(plan: plan, targetName: "Target")
        }
        #expect(recorder.phases == [.rereadingSources, .revalidating])
        #expect(commandKinds(runner.calls) == ["read"])
    }

    @Test("target collision stops after asserting absence; no compile, no write")
    func collisionStopsAtAssertion() throws {
        let source = seamSource()
        let plan = try buildPlan(source)
        let collision = seamWireSnapshot(
            [(PlaylistSnapshot(name: "Target", persistentId: "X", tracks: []), 900)]
        )
        let runner = FakeRunner(outputs: [seamWireSnapshot([(source, 100)]), collision])
        let session = MusicBridgeSession(runner: runner)
        let recorder = PhaseRecorder()
        session.applyProgress = recorder.callback()

        expectThrowsByteEqualMessage(
            "target user playlist already exists",
            context: "collision boundary"
        ) {
            _ = try session.applyPlan(plan: plan, targetName: "Target")
        }
        #expect(recorder.phases
            == [.rereadingSources, .revalidating, .assertingTargetAbsent])
        #expect(commandKinds(runner.calls) == ["read", "read"])
    }

    @Test("a writer failure still reaches the read-only readback phase")
    func writerFailureReachesReadbackPhase() throws {
        let source = seamSource()
        let plan = try buildPlan(source)
        let sourceWire = seamWireSnapshot([(source, 100)])
        let runner = FakeRunner(results: [
            .success(sourceWire),
            .success(emptyWireSnapshot),
            .success(""),
            .failure(MusicCommandError("simulated writer failure")),
            .success(sourceWire),
            .success(emptyWireSnapshot),
        ])
        let session = MusicBridgeSession(runner: runner)
        let recorder = PhaseRecorder()
        session.applyProgress = recorder.callback()

        let result = try session.applyPlan(plan: plan, targetName: "Target")

        #expect(result.verificationOk == false)
        #expect(result.mismatches.first == "write failed: simulated writer failure")
        #expect(recorder.phases == [
            .rereadingSources,
            .revalidating,
            .assertingTargetAbsent,
            .compilingWriter,
            .executingGuardedWrite,
            .verifyingReadback,
        ])
        // The write stage was issued exactly once and never retried.
        #expect(commandKinds(runner.calls)
            == ["read", "read", "compile", "execute", "read", "read"])
    }
}

// MARK: - nil callback = byte-identical behavior

@Suite("Apply progress seam (M9) — nil-callback transcript equality")
struct ApplyProgressNilEquivalenceTests {

    /// Compare two transcripts for byte-identical CONTENT: same command
    /// kinds, byte-equal scripts per index, compile artifacts named
    /// identically (basename), and each execute path equal to its own run's
    /// compile output path. The UUID temp directory is the only sanctioned
    /// variance (it differs between ANY two runs, callback or not).
    private func expectTranscriptsEquivalent(
        _ lhs: [ScriptCommand], _ rhs: [ScriptCommand]
    ) {
        #expect(lhs.count == rhs.count)
        var lhsCompilePath: String?
        var rhsCompilePath: String?
        for (index, pair) in zip(lhs, rhs).enumerated() {
            switch (pair.0, pair.1) {
            case (.readJXA(let a), .readJXA(let b)):
                expectByteEqual(a, b, context: "read script at command \(index)")
            case (.compileAppleScript(let a, let aPath), .compileAppleScript(let b, let bPath)):
                expectByteEqual(a, b, context: "writer script at command \(index)")
                #expect(
                    (aPath as NSString).lastPathComponent
                        == (bPath as NSString).lastPathComponent
                )
                lhsCompilePath = aPath
                rhsCompilePath = bPath
            case (.executeCompiledScript(let a), .executeCompiledScript(let b)):
                #expect(a == lhsCompilePath, "execute must target the run's own compiled artifact")
                #expect(b == rhsCompilePath, "execute must target the run's own compiled artifact")
            default:
                Issue.record("command kind mismatch at index \(index): \(pair.0) vs \(pair.1)")
            }
        }
    }

    @Test("consolidate: nil callback and set callback produce equal transcripts and results")
    func consolidateNilEquivalence() throws {
        let (plan, outputs) = try consolidateHappyOutputs()

        let nilRunner = FakeRunner(outputs: outputs)
        let nilSession = MusicBridgeSession(runner: nilRunner)
        #expect(nilSession.applyProgress == nil)
        let nilResult = try nilSession.applyPlan(plan: plan, targetName: "Target")

        let recordingRunner = FakeRunner(outputs: outputs)
        let recordingSession = MusicBridgeSession(runner: recordingRunner)
        let recorder = PhaseRecorder()
        recordingSession.applyProgress = recorder.callback()
        let recordedResult = try recordingSession.applyPlan(plan: plan, targetName: "Target")

        #expect(nilResult == recordedResult)
        #expect(recorder.phases.count == 6)
        expectTranscriptsEquivalent(nilRunner.calls, recordingRunner.calls)
    }

    @Test("merge: nil callback and set callback produce equal transcripts and results")
    func mergeNilEquivalence() throws {
        let (plan, outputs) = try mergeHappyOutputs()

        let nilRunner = FakeRunner(outputs: outputs)
        let nilResult = try MusicBridgeSession(runner: nilRunner)
            .applyMergePlan(plan: plan, targetName: "G — Merged")

        let recordingRunner = FakeRunner(outputs: outputs)
        let recordingSession = MusicBridgeSession(runner: recordingRunner)
        let recorder = PhaseRecorder()
        recordingSession.applyProgress = recorder.callback()
        let recordedResult = try recordingSession
            .applyMergePlan(plan: plan, targetName: "G — Merged")

        #expect(nilResult == recordedResult)
        #expect(recorder.phases.count == 6)
        expectTranscriptsEquivalent(nilRunner.calls, recordingRunner.calls)
    }
}
