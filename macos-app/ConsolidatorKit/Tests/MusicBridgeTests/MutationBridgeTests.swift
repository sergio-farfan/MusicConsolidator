// MutationBridgeTests.swift
// Wave B — the guarded mutation orchestration on MusicBridgeSession:
// performMutation's fail-closed sequence (fresh listing + fingerprint
// recheck -> compile -> execute the exact compiled artifact -> fresh
// listing + bijective diff), its MutationPhase progress seam, and the
// discipline that a writer failure NEVER flips to success. All commands
// ride FakeRunner; nothing here executes any script.

import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

// MARK: - listing fixtures (the wire shape parsePlaylistListing consumes)

private func listingEntry(
    id: Double,
    name: String,
    persistentId: String,
    trackCount: Int,
    isSmart: Bool = false,
    specialKind: String = "none"
) -> PlaylistListing {
    PlaylistListing(
        playlistId: id,
        name: name,
        persistentId: persistentId,
        trackCount: trackCount,
        isSmart: isSmart,
        specialKind: specialKind
    )
}

private func wireListingEntry(_ listing: PlaylistListing) -> String {
    """
    {"id": \(Int(listing.playlistId)), "name": "\(listing.name)", \
    "persistent_id": "\(listing.persistentId)", "track_count": \(listing.trackCount), \
    "smart": \(listing.isSmart), "special_kind": "\(listing.specialKind)"}
    """
}

private func wireListing(_ listings: [PlaylistListing]) -> String {
    "{\"playlists\": [\(listings.map(wireListingEntry).joined(separator: ", "))]}"
}

/// Three-entry baseline: the doomed plain playlist, an unrelated plain
/// playlist, and a smart playlist (whose count drift must stay
/// informational per the diff contract).
private func mutationBaseline() -> [PlaylistListing] {
    [
        listingEntry(id: 100, name: "Trance 2022", persistentId: "PID-DOOMED", trackCount: 2),
        listingEntry(id: 200, name: "Keep Me", persistentId: "PID-KEEP", trackCount: 5),
        listingEntry(
            id: 300, name: "Party Mix", persistentId: "PID-SMART", trackCount: 7,
            isSmart: true, specialKind: "none"
        ),
    ]
}

/// Build a MutationPlan over the baseline the way the gate does: the stored
/// fingerprint IS the baseline's fingerprint.
private func mutationPlan(
    kind: MutationKind,
    name: String = "Trance 2022",
    persistentID: String = "PID-DOOMED",
    trackCount: Int = 2,
    trackPIDs: [String] = ["T0", "T1"],
    newName: String? = nil,
    baseline: [PlaylistListing]
) -> MutationPlan {
    MutationPlan(
        kind: kind,
        playlistName: name,
        playlistPersistentID: persistentID,
        trackCount: trackCount,
        orderedTrackPersistentIDs: trackPIDs,
        newName: newName,
        listingFingerprint: listingFingerprint(of: baseline),
        evidence: nil,
        createdAtISO8601: "2026-08-03T12:00:00Z",
        sessionID: "TEST-SESSION-UUID"
    )
}

/// Record phases synchronously (the callback fires on the calling thread),
/// mirroring ApplyProgressSeamTests' PhaseRecorder.
private final class MutationPhaseRecorder {
    private(set) var phases: [MutationPhase] = []

    func callback() -> (MutationPhase) -> Void {
        { [self] phase in phases.append(phase) }
    }
}

private func mutationCommandKinds(_ commands: [ScriptCommand]) -> [String] {
    commands.map { command in
        switch command {
        case .readJXA: return "read"
        case .compileAppleScript: return "compile"
        case .executeCompiledScript: return "execute"
        }
    }
}

// MARK: - the orchestration suite

@Suite("MutationBridgeTests — performMutation orchestration")
struct MutationBridgeTests {

    @Test("a successful delete verifies through the bijective listing diff")
    func deleteHappyPathVerifies() throws {
        let baseline = mutationBaseline()
        let after = baseline.filter { $0.persistentId != "PID-DOOMED" }
        let runner = FakeRunner(outputs: [wireListing(baseline), "", "", wireListing(after)])
        let session = MusicBridgeSession(runner: runner)
        let recorder = MutationPhaseRecorder()
        let plan = mutationPlan(kind: .delete, baseline: baseline)

        let outcome = try session.performMutation(
            plan: plan,
            baseline: baseline,
            targetGuard: nil,
            progress: recorder.callback()
        )

        #expect(outcome.verified == true)
        #expect(outcome.mismatches.isEmpty)
        #expect(outcome.informational.isEmpty)
        #expect(recorder.phases == [.reValidating, .compiling, .executing, .verifyingListing])
        #expect(mutationCommandKinds(runner.calls) == ["read", "compile", "execute", "read"])

        // Compile-before-execute of the exact compiled artifact.
        var compiledPath: String?
        for call in runner.calls {
            if case .compileAppleScript(_, let outputPath) = call {
                compiledPath = outputPath
            }
            if case .executeCompiledScript(let path) = call {
                #expect(
                    path == compiledPath,
                    "execute must target this run's own compiled artifact"
                )
            }
        }
    }

    @Test("pre-execution fingerprint drift refuses fail-closed before compile")
    func fingerprintDriftRefusesBeforeCompile() throws {
        let baseline = mutationBaseline()
        var drifted = baseline
        drifted.append(
            listingEntry(id: 400, name: "Appeared Mid-Gate", persistentId: "PID-NEW", trackCount: 1)
        )
        let runner = FakeRunner(outputs: [wireListing(drifted)])
        let session = MusicBridgeSession(runner: runner)
        let recorder = MutationPhaseRecorder()
        let plan = mutationPlan(kind: .delete, baseline: baseline)

        #expect(throws: MusicBridgeError.self) {
            _ = try session.performMutation(
                plan: plan,
                baseline: baseline,
                targetGuard: nil,
                progress: recorder.callback()
            )
        }
        #expect(recorder.phases == [.reValidating])
        #expect(
            mutationCommandKinds(runner.calls) == ["read"],
            "no compile and no execute may be dispatched after a fingerprint refusal"
        )
    }

    @Test("a successful rename verifies with the pinned PID bearing the new name")
    func renameHappyPathVerifies() throws {
        let baseline = mutationBaseline()
        let after = baseline.map { entry in
            entry.persistentId == "PID-DOOMED"
                ? listingEntry(
                    id: entry.playlistId,
                    name: "Trance 2022 (fixed)",
                    persistentId: entry.persistentId,
                    trackCount: entry.trackCount
                )
                : entry
        }
        let runner = FakeRunner(outputs: [wireListing(baseline), "", "", wireListing(after)])
        let session = MusicBridgeSession(runner: runner)
        let recorder = MutationPhaseRecorder()
        let plan = mutationPlan(
            kind: .rename, newName: "Trance 2022 (fixed)", baseline: baseline
        )

        let outcome = try session.performMutation(
            plan: plan,
            baseline: baseline,
            targetGuard: nil,
            progress: recorder.callback()
        )

        #expect(outcome.verified == true)
        #expect(outcome.mismatches.isEmpty)
        #expect(outcome.informational.isEmpty)
        #expect(recorder.phases == [.reValidating, .compiling, .executing, .verifyingListing])
        #expect(mutationCommandKinds(runner.calls) == ["read", "compile", "execute", "read"])
    }

    @Test("a writer execution error never flips to success and reports verbatim")
    func writerFailureNeverFlipsToSuccess() throws {
        let baseline = mutationBaseline()
        let runner = FakeRunner(results: [
            .success(wireListing(baseline)),
            .success(""),
            .failure(MusicCommandError("simulated delete writer failure")),
            .success(wireListing(baseline)),
        ])
        let session = MusicBridgeSession(runner: runner)
        let recorder = MutationPhaseRecorder()
        let plan = mutationPlan(kind: .delete, baseline: baseline)

        let outcome = try session.performMutation(
            plan: plan,
            baseline: baseline,
            targetGuard: nil,
            progress: recorder.callback()
        )

        #expect(outcome.verified == false)
        expectByteEqual(
            outcome.mismatches.first ?? "<no mismatch recorded>",
            "write failed: simulated delete writer failure",
            context: "writer failure first mismatch"
        )
        // The doomed PID is still present in the readback, so the diff must
        // contribute at least one further verbatim mismatch — verification
        // is never claimed after a writer error.
        #expect(outcome.mismatches.count >= 2)
        #expect(recorder.phases == [.reValidating, .compiling, .executing, .verifyingListing])
        // Exactly one execute — never retried — and the post-failure
        // inspection is a read-only listing read.
        #expect(mutationCommandKinds(runner.calls) == ["read", "compile", "execute", "read"])
    }

    @Test("a post-execute verification read failure never throws and reports diagnostically")
    func postExecuteVerificationReadFailureNeverThrows() throws {
        let baseline = mutationBaseline()
        let runner = FakeRunner(results: [
            .success(wireListing(baseline)),
            .success(""),
            .success(""),
            .failure(MusicCommandError("simulated post-execute read failure")),
        ])
        let session = MusicBridgeSession(runner: runner)
        let recorder = MutationPhaseRecorder()
        let plan = mutationPlan(kind: .delete, baseline: baseline)

        let outcome = try session.performMutation(
            plan: plan,
            baseline: baseline,
            targetGuard: nil,
            progress: recorder.callback()
        )

        #expect(outcome.verified == false)
        expectByteEqual(
            outcome.mismatches.first ?? "<no mismatch recorded>",
            "post-execute verification read failed: simulated post-execute read failure",
            context: "post-execute verification read failure first mismatch"
        )
        #expect(recorder.phases == [.reValidating, .compiling, .executing, .verifyingListing])
        // Exactly one execute — never retried — and the final failed read is
        // still dispatched as a plain read, never repeated.
        #expect(mutationCommandKinds(runner.calls) == ["read", "compile", "execute", "read"])
    }

    @Test("a playlist added during the mutation window fails the bijective readback")
    func addedPlaylistDuringWindowFailsReadback() throws {
        let baseline = mutationBaseline()
        var after = baseline.filter { $0.persistentId != "PID-DOOMED" }
        after.append(
            listingEntry(id: 400, name: "Appeared Mid-Write", persistentId: "PID-NEW", trackCount: 3)
        )
        let runner = FakeRunner(outputs: [wireListing(baseline), "", "", wireListing(after)])
        let session = MusicBridgeSession(runner: runner)
        let recorder = MutationPhaseRecorder()
        let plan = mutationPlan(kind: .delete, baseline: baseline)

        let outcome = try session.performMutation(
            plan: plan,
            baseline: baseline,
            targetGuard: nil,
            progress: recorder.callback()
        )

        #expect(outcome.verified == false)
        #expect(
            !outcome.mismatches.isEmpty,
            "the bijective diff must report the added playlist verbatim"
        )
        #expect(recorder.phases == [.reValidating, .compiling, .executing, .verifyingListing])
    }

    @Test("cleanup deletes pass the target guard through to the writer source")
    func deleteTargetGuardPassthrough() throws {
        let baseline = mutationBaseline()
        let after = baseline.filter { $0.persistentId != "PID-DOOMED" }
        let guardPayload = MutationScriptBuilder.TargetGuardPayload(
            name: "Trance 2022 — Merged",
            orderedTrackPersistentIDs: ["M0", "M1", "M2"]
        )
        let runner = FakeRunner(outputs: [wireListing(baseline), "", "", wireListing(after)])
        let session = MusicBridgeSession(runner: runner)
        let plan = mutationPlan(kind: .delete, baseline: baseline)

        let outcome = try session.performMutation(
            plan: plan,
            baseline: baseline,
            targetGuard: guardPayload,
            progress: nil
        )

        #expect(outcome.verified == true)
        let expectedScript = MutationScriptBuilder.buildDeleteScript(
            expectedName: "Trance 2022",
            expectedPersistentID: "PID-DOOMED",
            expectedTrackPersistentIDs: ["T0", "T1"],
            targetGuard: guardPayload
        )
        var compiledSource: String?
        for call in runner.calls {
            if case .compileAppleScript(let script, _) = call {
                compiledSource = script
            }
        }
        expectByteEqual(
            compiledSource ?? "<no compile dispatched>",
            expectedScript,
            context: "delete writer passthrough with target guard"
        )
    }

    @Test("a rename plan missing its new name refuses before compile")
    func renameMissingNewNameRefuses() throws {
        let baseline = mutationBaseline()
        let runner = FakeRunner(outputs: [wireListing(baseline)])
        let session = MusicBridgeSession(runner: runner)
        let plan = mutationPlan(kind: .rename, newName: nil, baseline: baseline)

        #expect(throws: MusicBridgeError.self) {
            _ = try session.performMutation(
                plan: plan, baseline: baseline, targetGuard: nil, progress: nil
            )
        }
        #expect(mutationCommandKinds(runner.calls) == ["read"])
    }

    @Test("a rename with a target guard refuses rather than silently ignoring it")
    func renameWithTargetGuardRefuses() throws {
        let baseline = mutationBaseline()
        let runner = FakeRunner(outputs: [wireListing(baseline)])
        let session = MusicBridgeSession(runner: runner)
        let plan = mutationPlan(
            kind: .rename, newName: "Trance 2022 (fixed)", baseline: baseline
        )
        let guardPayload = MutationScriptBuilder.TargetGuardPayload(
            name: "Trance 2022 — Merged",
            orderedTrackPersistentIDs: ["M0"]
        )

        #expect(throws: MusicBridgeError.self) {
            _ = try session.performMutation(
                plan: plan, baseline: baseline, targetGuard: guardPayload, progress: nil
            )
        }
        #expect(mutationCommandKinds(runner.calls) == ["read"])
    }
}
