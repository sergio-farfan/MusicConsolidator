// OrchestrationTestSupport.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Shared fakes for the M5 orchestration suites, mirroring the reference's
// in-memory bridge fakes in tests/test_music_bridge.py (FakeRunner,
// InputCapturingRunner, InMemoryBridge, BoundaryRecordingBridge,
// SourceAfterWriteBridge, WriterFailureBridge, _FakeCopiesBridge,
// _MergeApplyBridge) and tests/helpers.py. Nothing here executes any script:
// the FakeRunner returns canned outputs only, and the subclass fakes carry an
// UnusedRunner that fails closed if the orchestration ever reaches the real
// runner seam through an overridden boundary.

import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

// The orchestration class is `MusicBridgeSession` (post-final-review fix
// M5-5), so the module name `MusicBridge` is unshadowed and the M4
// scalar-mirror pins' module-qualified `MusicBridge.scalarEqual(...)`
// spelling reaches ScalarSupport.swift's real implementations directly —
// no thunks or test-target forwarding extension are needed.

// MARK: - runner fakes (tests/test_music_bridge.py FakeRunner / InputCapturingRunner)

/// Scripted-responses runner: records every command, replays canned outputs
/// in order, and supports failure injection through `Result.failure`.
final class FakeRunner: ScriptRunner {
    private(set) var calls: [ScriptCommand] = []
    private var results: [Result<String, Error>]

    init(outputs: [String]) {
        self.results = outputs.map { .success($0) }
    }

    init(results: [Result<String, Error>]) {
        self.results = results
    }

    @discardableResult
    func run(_ command: ScriptCommand) throws -> String {
        calls.append(command)
        guard !results.isEmpty else {
            throw TestSupportError("FakeRunner has no scripted output left for \(command)")
        }
        return try results.removeFirst().get()
    }
}

/// Injected into subclass fakes whose overridden boundaries must make the real
/// runner unreachable (the reference fakes skip MusicBridge.__init__ entirely, so
/// any runner use there would crash too).
struct UnusedRunner: ScriptRunner {
    @discardableResult
    func run(_ command: ScriptCommand) throws -> String {
        throw TestSupportError("the injected runner must never be invoked by this fake bridge")
    }
}

// MARK: - fixtures

/// tests/test_music_bridge.py::source_snapshot
func orchestrationSourceSnapshot() -> PlaylistSnapshot {
    PlaylistSnapshot(
        name: "Source",
        persistentId: "P",
        tracks: [
            track(sourceIndex: 0, databaseId: 1, persistentId: "A"),
            track(
                sourceIndex: 1,
                databaseId: 2,
                persistentId: "B",
                title: "Second Song",
                sampleRateHz: 48000
            ),
        ]
    )
}

/// The reference's read fixture tests/fixtures/music_snapshot.json, read-only.
func musicSnapshotFixtureText() throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tests")
        .appendingPathComponent("fixtures")
        .appendingPathComponent("music_snapshot.json")
    return try String(contentsOf: url, encoding: .utf8)
}

/// NFC/NFD pin fixtures, built from explicit escapes so no editor or tool can
/// normalize them silently. Canonically equivalent, scalar-different.
let nfcCafe = "Caf\u{E9}"
let nfdCafe = "Cafe\u{301}"

// MARK: - subclass fakes (reference test bridges)

/// tests/test_music_bridge.py::InMemoryBridge — controlled apply boundary; no
/// Music automation is invoked by these tests.
class InMemoryBridge: MusicBridgeSession {
    let source: PlaylistSnapshot
    let readback: PlaylistSnapshot
    var writeCalls = 0

    init(source: PlaylistSnapshot, readback: PlaylistSnapshot) {
        self.source = source
        self.readback = readback
        super.init(runner: UnusedRunner())
    }

    override func snapshotPlaylist(name: String) throws -> PlaylistSnapshot {
        name == source.name ? source : readback
    }

    override func assertTargetAbsent(targetName: String) throws {}

    override func runApplyScript(
        plan: ConsolidationPlan,
        source: PlaylistSnapshot,
        targetName: String
    ) throws {
        writeCalls += 1
    }
}

/// tests/test_music_bridge.py::BoundaryRecordingBridge
final class BoundaryRecordingBridge: InMemoryBridge {
    var targetAbsenceChecks = 0

    override func assertTargetAbsent(targetName: String) throws {
        targetAbsenceChecks += 1
    }
}

/// tests/test_music_bridge.py::SourceAfterWriteBridge — one source before
/// dispatch and a controlled source afterward.
final class SourceAfterWriteBridge: MusicBridgeSession {
    let initialSource: PlaylistSnapshot
    let changedSource: PlaylistSnapshot
    let target: PlaylistSnapshot
    var writeCalls = 0

    init(
        initialSource: PlaylistSnapshot,
        changedSource: PlaylistSnapshot,
        target: PlaylistSnapshot
    ) {
        self.initialSource = initialSource
        self.changedSource = changedSource
        self.target = target
        super.init(runner: UnusedRunner())
    }

    override func snapshotPlaylist(name: String) throws -> PlaylistSnapshot {
        if name == initialSource.name {
            return writeCalls == 0 ? initialSource : changedSource
        }
        return target
    }

    override func assertTargetAbsent(targetName: String) throws {}

    override func runApplyScript(
        plan: ConsolidationPlan,
        source: PlaylistSnapshot,
        targetName: String
    ) throws {
        writeCalls += 1
    }
}

/// tests/test_music_bridge.py::WriterFailureBridge — raise at the writer
/// boundary and expose controlled read-only readback.
final class WriterFailureBridge: MusicBridgeSession {
    enum TargetState {
        case present(PlaylistSnapshot)
        case absent
        case failure(String)
    }

    let source: PlaylistSnapshot
    let targetState: TargetState
    var writeCalls = 0

    init(source: PlaylistSnapshot, targetState: TargetState) {
        self.source = source
        self.targetState = targetState
        super.init(runner: UnusedRunner())
    }

    override func snapshotPlaylist(name: String) throws -> PlaylistSnapshot {
        if name == source.name { return source }
        switch targetState {
        case .present(let target):
            return target
        case .absent:
            throw MusicBridgeError("expected exactly one user playlist named 'Target'")
        case .failure(let message):
            throw MusicBridgeError(message)
        }
    }

    override func snapshotPlaylistIfPresent(name: String) throws -> PlaylistSnapshot? {
        switch targetState {
        case .present(let target):
            return target
        case .absent:
            return nil
        case .failure(let message):
            throw MusicBridgeError(message)
        }
    }

    override func assertTargetAbsent(targetName: String) throws {}

    override func runApplyScript(
        plan: ConsolidationPlan,
        source: PlaylistSnapshot,
        targetName: String
    ) throws {
        writeCalls += 1
        throw MusicCommandError("simulated writer failure\nwith private control text")
    }
}

/// tests/test_music_bridge.py::_FakeCopiesBridge
final class FakeCopiesBridge: MusicBridgeSession {
    let copies: [PlaylistSnapshot]

    init(copies: [PlaylistSnapshot]) {
        self.copies = copies
        super.init(runner: UnusedRunner())
    }

    override func snapshotAllCopies(name: String) throws -> [PlaylistSnapshot] {
        copies
    }
}

/// tests/test_music_bridge.py::_MergeApplyBridge — in-memory merge apply
/// boundary; no Music automation runs.
class MergeApplyBridge: MusicBridgeSession {
    let copies: [PlaylistSnapshot]
    let targetReadback: PlaylistSnapshot
    let targetAbsent: Bool
    var writeCalls = 0
    var raiseOnWrite: Error?

    init(
        copies: [PlaylistSnapshot],
        targetReadback: PlaylistSnapshot,
        targetAbsent: Bool = true
    ) {
        self.copies = copies
        self.targetReadback = targetReadback
        self.targetAbsent = targetAbsent
        super.init(runner: UnusedRunner())
    }

    override func ensureAllCopiesMatch(plan: MergePlan) throws -> [PlaylistSnapshot] {
        copies
    }

    override func assertTargetAbsent(targetName: String) throws {
        if !targetAbsent {
            throw MusicBridgeError("target user playlist already exists")
        }
    }

    override func snapshotAllCopies(name: String) throws -> [PlaylistSnapshot] {
        copies
    }

    override func snapshotPlaylist(name: String) throws -> PlaylistSnapshot {
        targetReadback
    }

    override func snapshotPlaylistIfPresent(name: String) throws -> PlaylistSnapshot? {
        targetReadback
    }

    override func runMergeApplyScript(
        plan: MergePlan,
        verifiedCopies: [PlaylistSnapshot],
        targetName: String
    ) throws {
        writeCalls += 1
        if let raiseOnWrite {
            throw raiseOnWrite
        }
    }
}

/// tests/test_music_bridge.py::MergeApplyTests _DriftBridge
final class DriftMergeApplyBridge: MergeApplyBridge {
    var driftedCopies: [PlaylistSnapshot] = []

    override func snapshotAllCopies(name: String) throws -> [PlaylistSnapshot] {
        driftedCopies
    }
}

// MARK: - thrown-message assertion helpers (scalar-exact, never String ==)

/// Assert the body throws and the error's message is BYTE-equal to the
/// reference-verified text (String == would canonically equate NFC/NFD-divergent
/// messages, defeating the scalar pins).
func expectThrowsByteEqualMessage(
    _ expected: String,
    context: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation,
    _ body: () throws -> Void
) {
    do {
        try body()
        Issue.record(
            "\(context): an error was expected but none was thrown",
            sourceLocation: sourceLocation
        )
    } catch {
        expectByteEqual(
            String(describing: error),
            expected,
            context: context,
            sourceLocation: sourceLocation
        )
    }
}

/// Assert the body throws and the message contains the needle (byte search).
func expectThrowsMessageContaining(
    _ needle: String,
    context: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation,
    _ body: () throws -> Void
) {
    do {
        try body()
        Issue.record(
            "\(context): an error was expected but none was thrown",
            sourceLocation: sourceLocation
        )
    } catch {
        let message = String(describing: error)
        #expect(
            ByteText(message).contains(needle),
            "\(context): message \(message) does not contain \(needle)",
            sourceLocation: sourceLocation
        )
    }
}
