// MutationGateModelTests.swift
// Wave B (B2/B4/B5/B6) — the mutation gate state machine on AuditFlowModel:
// artifact-first arming (fresh listing + fresh snapshot -> MutationPlan ->
// writeMutationAudit), entry refusals, the unique-identity typed tokens
// (never normalized), the B2 dispatch re-checks (session, 600 s age, SHA-256
// from disk, consumed marker), consumption on execution AND on abort, and
// the B6 unattended-run lockout. Offline only: ScriptedRunner fakes.

import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

// MARK: - injectable clock

/// A mutable, thread-safe clock behind the model's injected `now` closure —
/// the seam for the 600 s artifact-freshness contract (B2).
final class MutationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_770_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(bySeconds seconds: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(seconds)
        lock.unlock()
    }
}

// MARK: - harness (temp reports dir + hermetic defaults + pinned session/clock)

@MainActor
struct MutationGateHarness {
    let model: AuditFlowModel
    let outputDirectory: URL
    let clock: MutationTestClock

    init(runner: any ScriptRunner & Sendable, sessionID: String = "SESSION-A") throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        outputDirectory = directory
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true
        )
        let clock = MutationTestClock()
        self.clock = clock
        model = AuditFlowModel(
            makeRunner: { runner },
            defaults: InMemoryDefaults(),
            defaultOutputDirectoryPath: directory.path,
            cacheDirectoryPath: cacheDirectory.path,
            appSessionID: sessionID,
            now: { clock.now }
        )
    }

    func awaitMutation() async {
        await model.mutationTask?.value
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: outputDirectory)
    }
}

// MARK: - wire fixtures (shared with the Task 13 structural suite)

func gateEntry(
    id: Int, name: String, pid: String, count: Int,
    smart: Bool = false, specialKind: String = "none"
) -> String {
    """
    {"id": \(id), "name": "\(jsonEscaped(name))", "persistent_id": "\(jsonEscaped(pid))", \
    "track_count": \(count), "smart": \(smart), "special_kind": "\(jsonEscaped(specialKind))"}
    """
}

/// The standing library fixture: a deletable singleton, a
/// count-disambiguated twin pair, a fully ambiguous twin pair, a
/// trailing-space name, a smart playlist, a folder, and both
/// contract-excluded identities.
func gateListingWire(excludingPersistentID excluded: String? = nil) -> String {
    let entries = [
        gateEntry(id: 10, name: "Solo List", pid: "SOLO000000000001", count: 2),
        gateEntry(id: 20, name: "Twin", pid: "TWIN00000000AAAA", count: 3),
        gateEntry(id: 30, name: "Twin", pid: "TWIN00000000BBBB", count: 5),
        gateEntry(id: 40, name: "Twinsame", pid: "SAME000000003333", count: 4),
        gateEntry(id: 50, name: "Twinsame", pid: "SAME000000004444", count: 4),
        gateEntry(id: 60, name: "Kdrama ", pid: "TRAIL00000000001", count: 2),
        gateEntry(id: 70, name: "Smarty", pid: "SMART00000000001", count: 6, smart: true),
        gateEntry(id: 80, name: "Folder", pid: "FOLD000000000001", count: 0, specialKind: "folder"),
        gateEntry(id: 90, name: "#Musica xTotal", pid: "XTOTAL0000000001", count: 100),
        gateEntry(id: 100, name: "Pilot Source", pid: "E02030832FD20B07", count: 9),
    ].filter { excluded == nil || !$0.contains("\"persistent_id\": \"\(excluded!)\"") }
    return "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

func soloSnapshotWire() -> String {
    wireSnapshot(playlists: [
        wirePlaylist(id: 10, name: "Solo List", persistentId: "SOLO000000000001", tracks: [
            wireTrack(sourceIndex: 0, databaseId: 1, persistentId: "S0", title: "First"),
            wireTrack(sourceIndex: 1, databaseId: 2, persistentId: "S1", title: "Second"),
        ])
    ])
}

func twinSnapshotWire() -> String {
    wireSnapshot(playlists: [
        wirePlaylist(id: 20, name: "Twin", persistentId: "TWIN00000000AAAA", tracks: [
            wireTrack(sourceIndex: 0, databaseId: 11, persistentId: "TA0", title: "A0"),
            wireTrack(sourceIndex: 1, databaseId: 12, persistentId: "TA1", title: "A1"),
            wireTrack(sourceIndex: 2, databaseId: 13, persistentId: "TA2", title: "A2"),
        ]),
        wirePlaylist(id: 30, name: "Twin", persistentId: "TWIN00000000BBBB", tracks: [
            wireTrack(sourceIndex: 0, databaseId: 21, persistentId: "TB0", title: "B0"),
            wireTrack(sourceIndex: 1, databaseId: 22, persistentId: "TB1", title: "B1"),
            wireTrack(sourceIndex: 2, databaseId: 23, persistentId: "TB2", title: "B2"),
            wireTrack(sourceIndex: 3, databaseId: 24, persistentId: "TB3", title: "B3"),
            wireTrack(sourceIndex: 4, databaseId: 25, persistentId: "TB4", title: "B4"),
        ]),
    ])
}

func twinsameSnapshotWire() -> String {
    wireSnapshot(playlists: [
        wirePlaylist(id: 40, name: "Twinsame", persistentId: "SAME000000003333", tracks: [
            wireTrack(sourceIndex: 0, databaseId: 31, persistentId: "SA0", title: "S0"),
            wireTrack(sourceIndex: 1, databaseId: 32, persistentId: "SA1", title: "S1"),
            wireTrack(sourceIndex: 2, databaseId: 33, persistentId: "SA2", title: "S2"),
            wireTrack(sourceIndex: 3, databaseId: 34, persistentId: "SA3", title: "S3"),
        ]),
        wirePlaylist(id: 50, name: "Twinsame", persistentId: "SAME000000004444", tracks: [
            wireTrack(sourceIndex: 0, databaseId: 41, persistentId: "SB0", title: "S0"),
            wireTrack(sourceIndex: 1, databaseId: 42, persistentId: "SB1", title: "S1"),
            wireTrack(sourceIndex: 2, databaseId: 43, persistentId: "SB2", title: "S2"),
            wireTrack(sourceIndex: 3, databaseId: 44, persistentId: "SB3", title: "S3"),
        ]),
    ])
}

func kdramaSnapshotWire() -> String {
    wireSnapshot(playlists: [
        wirePlaylist(id: 60, name: "Kdrama ", persistentId: "TRAIL00000000001", tracks: [
            wireTrack(sourceIndex: 0, databaseId: 51, persistentId: "K0", title: "K0"),
            wireTrack(sourceIndex: 1, databaseId: 52, persistentId: "K1", title: "K1"),
        ])
    ])
}

// MARK: - the gate suite

@MainActor
@Suite("Mutation gate model (Wave B)")
struct MutationGateModelTests {

    @Test("a clean delete audit arms the gate and writes the artifact pair")
    func deleteAuditArms() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire(), soloSnapshotWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(kind: .delete, persistentID: "SOLO000000000001")
        await harness.awaitMutation()

        let armed = try #require(harness.model.armedMutation)
        #expect(armed.plan.kind == .delete)
        #expect(armed.plan.playlistName == "Solo List")
        #expect(armed.plan.playlistPersistentID == "SOLO000000000001")
        #expect(armed.plan.trackCount == 2)
        #expect(armed.plan.orderedTrackPersistentIDs == ["S0", "S1"])
        #expect(armed.plan.newName == nil)
        #expect(armed.plan.sessionID == "SESSION-A")
        #expect(!armed.requiresCountToken)
        #expect(!armed.requiresPIDSuffixToken)
        #expect(armed.collisionWarning == nil)
        #expect(armed.paths.planURL.lastPathComponent.hasSuffix(".delete.plan.json"))
        #expect(FileManager.default.fileExists(atPath: armed.paths.planURL.path))
        #expect(FileManager.default.fileExists(atPath: armed.paths.summaryURL.path))
        #expect(!isMutationPlanConsumed(planURL: armed.paths.planURL))

        // Unambiguous name: the name token alone satisfies the gate.
        #expect(!harness.model.mutationGateSatisfied)
        harness.model.typedMutationName = "Solo List"
        #expect(harness.model.mutationGateSatisfied)
    }

    @Test("entry refusals: smart, special kind, xTotal name, pilot persistent ID")
    func entryRefusals() async throws {
        let cases: [(pid: String, fragment: String)] = [
            ("SMART00000000001", "smart playlist"),
            ("FOLD000000000001", "special kind"),
            ("XTOTAL0000000001", "contract-excluded"),
            ("E02030832FD20B07", "contract-excluded"),
        ]
        for entry in cases {
            let runner = ScriptedRunner(outputs: [gateListingWire()])
            let harness = try MutationGateHarness(runner: runner)
            defer { harness.cleanUp() }
            harness.model.startMutationAudit(kind: .delete, persistentID: entry.pid)
            await harness.awaitMutation()
            guard case .refused(let reason) = harness.model.mutationGatePhase else {
                Issue.record("expected a refusal for \(entry.pid)")
                continue
            }
            #expect(reason.contains(entry.fragment), "\(entry.pid): \(reason)")
            // A refusal at entry writes NO artifact.
            #expect(
                try FileManager.default
                    .contentsOfDirectory(atPath: harness.outputDirectory.path).isEmpty
            )
        }
    }

    @Test("rename destinations matching the contract-excluded names are refused at entry")
    func renameDestinationRefused() async throws {
        let runner = ScriptedRunner(outputs: [])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(
            kind: .rename,
            persistentID: "SOLO000000000001",
            newName: "#Musica xTotal \u{2014} Consolidated"
        )
        await harness.awaitMutation()
        guard case .refused(let reason) = harness.model.mutationGatePhase else {
            Issue.record("expected an entry refusal")
            return
        }
        #expect(reason.contains("rename destination"))
        // Refused BEFORE any Music read: zero commands dispatched.
        #expect(runner.commands.isEmpty)
    }

    @Test("same-name copies require the count token; same-count twins also require the PID suffix")
    func ambiguityTokens() async throws {
        // Count-disambiguated twin: name + count.
        let runner = ScriptedRunner(outputs: [gateListingWire(), twinSnapshotWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(kind: .delete, persistentID: "TWIN00000000AAAA")
        await harness.awaitMutation()
        let armed = try #require(harness.model.armedMutation)
        #expect(armed.requiresCountToken)
        #expect(!armed.requiresPIDSuffixToken)
        harness.model.typedMutationName = "Twin"
        #expect(!harness.model.mutationGateSatisfied)
        harness.model.typedMutationCount = "3"
        #expect(harness.model.mutationGateSatisfied)

        // Fully ambiguous twin: name + count + last-4-of-PID.
        let runner2 = ScriptedRunner(outputs: [gateListingWire(), twinsameSnapshotWire()])
        let harness2 = try MutationGateHarness(runner: runner2)
        defer { harness2.cleanUp() }
        harness2.model.startMutationAudit(kind: .delete, persistentID: "SAME000000003333")
        await harness2.awaitMutation()
        let armed2 = try #require(harness2.model.armedMutation)
        #expect(armed2.requiresCountToken)
        #expect(armed2.requiresPIDSuffixToken)
        harness2.model.typedMutationName = "Twinsame"
        harness2.model.typedMutationCount = "4"
        #expect(!harness2.model.mutationGateSatisfied)
        harness2.model.typedMutationPIDSuffix = "3333"
        #expect(harness2.model.mutationGateSatisfied)
    }

    @Test("typed confirmation is never normalized: a trailing-space name requires the trailing space")
    func typedInputNeverNormalized() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire(), kdramaSnapshotWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(kind: .delete, persistentID: "TRAIL00000000001")
        await harness.awaitMutation()
        #expect(harness.model.armedMutation != nil)

        harness.model.typedMutationName = "Kdrama" // missing the trailing space
        #expect(!harness.model.mutationGateSatisfied)
        let divergence = try #require(harness.model.mutationNameDivergence)
        #expect(divergence.index == 6)
        #expect(divergence.expected == " ")
        #expect(divergence.actual == nil)

        harness.model.typedMutationName = "Kdrama " // exact, trailing space typed
        #expect(harness.model.mutationNameDivergence == nil)
        #expect(harness.model.mutationGateSatisfied)
    }

    @Test("a rename collision is a warning, never a block; a free name warns nothing")
    func renameCollisionWarning() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire(), soloSnapshotWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(
            kind: .rename, persistentID: "SOLO000000000001", newName: "Twin"
        )
        await harness.awaitMutation()
        let armed = try #require(harness.model.armedMutation)
        #expect(armed.plan.newName == "Twin")
        #expect(armed.paths.planURL.lastPathComponent.hasSuffix(".rename.plan.json"))
        let warning = try #require(armed.collisionWarning)
        #expect(warning.contains("same-name group"))

        let runner2 = ScriptedRunner(outputs: [gateListingWire(), soloSnapshotWire()])
        let harness2 = try MutationGateHarness(runner: runner2)
        defer { harness2.cleanUp() }
        harness2.model.startMutationAudit(
            kind: .rename, persistentID: "SOLO000000000001", newName: "Fresh Name"
        )
        await harness2.awaitMutation()
        let armed2 = try #require(harness2.model.armedMutation)
        #expect(armed2.collisionWarning == nil)
    }

    @Test("the dispatch precondition refuses an out-of-session artifact")
    func sessionMismatchRefused() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire(), soloSnapshotWire()])
        let harness = try MutationGateHarness(runner: runner, sessionID: "SESSION-A")
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(kind: .delete, persistentID: "SOLO000000000001")
        await harness.awaitMutation()
        let armed = try #require(harness.model.armedMutation)

        let reason = AuditFlowModel.mutationPreconditionFailure(
            armedPlan: armed.plan,
            planURL: armed.paths.planURL,
            sessionID: "SESSION-B",
            at: harness.clock.now
        )
        #expect(try #require(reason).contains("session"))
        // The same plan under the SAME session passes every precondition.
        #expect(
            AuditFlowModel.mutationPreconditionFailure(
                armedPlan: armed.plan,
                planURL: armed.paths.planURL,
                sessionID: "SESSION-A",
                at: harness.clock.now
            ) == nil
        )
    }

    @Test("dispatch refuses a stale artifact (age > 600 s), consumes it, and never reaches the writer")
    func staleDispatchRefused() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire(), soloSnapshotWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(kind: .delete, persistentID: "SOLO000000000001")
        await harness.awaitMutation()
        let armed = try #require(harness.model.armedMutation)
        harness.model.typedMutationName = "Solo List"

        harness.clock.advance(bySeconds: 601)
        harness.model.executeMutation()
        await harness.awaitMutation()

        guard case .refused(let reason) = harness.model.mutationGatePhase else {
            Issue.record("expected a staleness refusal")
            return
        }
        #expect(reason.contains("stale"))
        #expect(isMutationPlanConsumed(planURL: armed.paths.planURL))
        // Only the two audit reads happened — no compile, no execute.
        #expect(runner.commands.count == 2)
    }

    @Test("dispatch refuses when the artifact bytes changed on disk (SHA-256 recheck)")
    func shaRecheckRefused() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire(), soloSnapshotWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(kind: .delete, persistentID: "SOLO000000000001")
        await harness.awaitMutation()
        let armed = try #require(harness.model.armedMutation)
        harness.model.typedMutationName = "Solo List"

        // Tamper: a still-strictly-decodable plan whose canonical body (and
        // so its SHA-256) no longer matches the armed plan.
        let url = armed.paths.planURL
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object["track_count"] = 3
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        harness.model.executeMutation()
        await harness.awaitMutation()
        guard case .refused(let reason) = harness.model.mutationGatePhase else {
            Issue.record("expected a SHA refusal")
            return
        }
        #expect(reason.contains("SHA-256"))
        #expect(isMutationPlanConsumed(planURL: url))
        #expect(runner.commands.count == 2)
    }

    @Test("a consumed artifact can never dispatch again")
    func consumedArtifactRefused() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire(), soloSnapshotWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(kind: .delete, persistentID: "SOLO000000000001")
        await harness.awaitMutation()
        let armed = try #require(harness.model.armedMutation)
        harness.model.typedMutationName = "Solo List"

        try markMutationPlanConsumed(planURL: armed.paths.planURL)
        harness.model.executeMutation()
        await harness.awaitMutation()
        guard case .refused(let reason) = harness.model.mutationGatePhase else {
            Issue.record("expected a consumed-artifact refusal")
            return
        }
        #expect(reason.contains("consumed"))
        #expect(runner.commands.count == 2)
    }

    @Test("a verified delete consumes the artifact and writes the result report")
    func verifiedDeleteExecution() async throws {
        // Audit: listing + snapshot. Dispatch (performMutation): fresh
        // listing, compile, execute, post listing WITHOUT the doomed PID.
        let runner = ScriptedRunner(outputs: [
            gateListingWire(),
            soloSnapshotWire(),
            gateListingWire(),
            "",
            "",
            gateListingWire(excludingPersistentID: "SOLO000000000001"),
        ])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(kind: .delete, persistentID: "SOLO000000000001")
        await harness.awaitMutation()
        let armed = try #require(harness.model.armedMutation)
        harness.model.typedMutationName = "Solo List"

        harness.model.executeMutation()
        await harness.awaitMutation()
        guard case .finished(let display) = harness.model.mutationGatePhase else {
            Issue.record("expected a finished phase, got \(harness.model.mutationGatePhase)")
            return
        }
        #expect(display.verified)
        #expect(display.mismatches.isEmpty)
        #expect(display.kind == .delete)
        #expect(display.consumedPlanFileName.hasSuffix(".delete.plan.json"))
        #expect(isMutationPlanConsumed(planURL: armed.paths.planURL))
        let resultPath = try #require(display.resultReportPath)
        #expect(resultPath.hasSuffix(".mutationresult.md"))
        #expect(FileManager.default.fileExists(atPath: resultPath))
        #expect(display.resultWriteFailure == nil)
        // Command shape: read, read (audit), then read, compile, execute,
        // read (performMutation).
        #expect(runner.commands.count == 6)
        if case .compileAppleScript = runner.commands[3] {} else {
            Issue.record("command 3 must be the compile")
        }
        if case .executeCompiledScript = runner.commands[4] {} else {
            Issue.record("command 4 must be the execute")
        }
        // Typed tokens are cleared at the terminal transition.
        #expect(harness.model.typedMutationName.isEmpty)
    }

    @Test("dismissing an armed gate aborts it and consumes the artifact")
    func dismissArmedGateConsumes() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire(), soloSnapshotWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(kind: .delete, persistentID: "SOLO000000000001")
        await harness.awaitMutation()
        let armed = try #require(harness.model.armedMutation)
        harness.model.typedMutationName = "Solo List"

        harness.model.dismissMutationGate()
        #expect(isMutationPlanConsumed(planURL: armed.paths.planURL))
        guard case .idle = harness.model.mutationGatePhase else {
            Issue.record("expected the idle phase after dismissal")
            return
        }
        #expect(harness.model.typedMutationName.isEmpty)
        // A consumed artifact can never re-arm: re-dispatch is impossible
        // because the gate is idle, and executeMutation is a no-op.
        harness.model.executeMutation()
        #expect(harness.model.mutationTask == nil || harness.model.armedMutation == nil)
    }

    @Test("an active unattended run blocks the mutation gate at entry (B6)")
    func unattendedRunBlocksEntry() async throws {
        // Judgment pause: isUnattendedRunActive stays true while idle
        // (the M11 pause pattern — consolidateFixtureWire HAS a judgment).
        let runner = ScriptedRunner(outputs: [
            "{\"playlists\": [" + gateEntry(id: 10, name: "Alpha List", pid: "P-A", count: 4) + "]}",
            consolidateFixtureWire(name: "Alpha List"),
        ])
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
            harness.model.isUnattendedRunActive && !harness.model.isRunning
        })

        harness.model.startMutationAudit(kind: .delete, persistentID: "P-A")
        guard case .idle = harness.model.mutationGatePhase else {
            Issue.record("the gate must stay idle during an unattended run")
            return
        }
        #expect(harness.model.mutationTask == nil)
    }
}
