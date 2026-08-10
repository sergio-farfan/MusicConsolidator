// AppTestSupport.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Test-local support for the M7 view-model suites. The library test targets'
// fakes (Tests/MusicBridgeTests/OrchestrationTestSupport.swift) are
// test-target-internal by design, so this target carries its own scripted
// ScriptRunner fakes, wire-JSON fixture builders, and a temp-dir +
// UserDefaults harness. Nothing here executes any script or contacts Music:
// the fakes return canned wire JSON strings only.

import AppKit
import Foundation
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

struct AppTestError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    init(_ message: String) { self.message = message }
}

// MARK: - scripted runners

/// Replays canned results in order and records every command. Thread-safe
/// because the model invokes the runner from a detached task; tests assert
/// only after awaiting the audit task.
final class ScriptedRunner: ScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<String, Error>]
    private var recordedCommands: [ScriptCommand] = []

    init(outputs: [String]) {
        self.results = outputs.map { .success($0) }
    }

    init(results: [Result<String, Error>]) {
        self.results = results
    }

    var commands: [ScriptCommand] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }

    /// Count of unconsumed scripted outputs — a batch's exact command shape
    /// pin (e.g. "cancel dispatched nothing").
    var remainingOutputs: Int {
        lock.lock()
        defer { lock.unlock() }
        return results.count
    }

    @discardableResult
    func run(_ command: ScriptCommand) throws -> String {
        lock.lock()
        recordedCommands.append(command)
        let next = results.isEmpty ? nil : results.removeFirst()
        lock.unlock()
        guard let next else {
            throw AppTestError("ScriptedRunner has no scripted output left")
        }
        return try next.get()
    }
}

/// Blocks inside `run` (on the detached read stage's own thread, never the
/// main actor) until the test releases it — the seam for exercising
/// single-flight and cancellation between phases (the read call itself is
/// uncancellable, like the real OSA execution; the pipeline checks
/// cancellation after it).
final class BlockingRunner: ScriptRunner, @unchecked Sendable {
    let proceed = DispatchSemaphore(value: 0)
    private let payload: String
    private let lock = NSLock()
    private var enteredCount = 0

    init(payload: String) {
        self.payload = payload
    }

    var runCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return enteredCount
    }

    @discardableResult
    func run(_ command: ScriptCommand) throws -> String {
        lock.lock()
        enteredCount += 1
        lock.unlock()
        proceed.wait()
        return payload
    }
}

/// Replays canned results in order like ScriptedRunner, but BLOCKS inside
/// `run` (on the detached stage's own thread) at the given 0-based call
/// indexes until the test signals `proceed` — the seam for holding an apply
/// (or scan/read) in flight while other actions are attempted (M9).
final class StagedBlockingRunner: ScriptRunner, @unchecked Sendable {
    let proceed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var results: [Result<String, Error>]
    private let blockAt: Set<Int>
    private var callCount = 0

    init(outputs: [String], blockAt: Set<Int>) {
        self.results = outputs.map { .success($0) }
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
            throw AppTestError("StagedBlockingRunner has no scripted output left")
        }
        return try next.get()
    }
}

/// Poll a condition WITHOUT blocking the main actor: the model's pipeline
/// task needs the main actor to reach its detached read stage, so a test
/// that blocked the main thread on a semaphore here would deadlock before
/// the runner is ever entered. `Task.sleep` suspends instead, letting the
/// pipeline run. Returns false on timeout (~5 s) rather than hanging.
@MainActor
func pollUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

// MARK: - wire JSON fixture builders (the read JXA's output shape)

/// Minimal JSON string escaping for fixture text (quote, backslash, C0).
func jsonEscaped(_ value: String) -> String {
    var out = ""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out
}

/// One wire track object as the read JXA emits it: duration in SECONDS,
/// `bit_rate` / `sample_rate` wire names.
func wireTrack(
    sourceIndex: Int,
    databaseId: Int,
    persistentId: String,
    title: String,
    artist: String = "Artist",
    album: String = "Album",
    duration: Double? = 200.0,
    kind: String = "AAC audio file",
    bitRate: Int? = 256,
    sampleRate: Int? = 44100,
    cloudStatus: String = "subscription",
    isFileTrack: Bool = false
) -> String {
    let durationText = duration.map { String($0) } ?? "null"
    let bitRateText = bitRate.map(String.init) ?? "null"
    let sampleRateText = sampleRate.map(String.init) ?? "null"
    return """
    {"source_index": \(sourceIndex), "database_id": \(databaseId), \
    "persistent_id": "\(jsonEscaped(persistentId))", "title": "\(jsonEscaped(title))", \
    "artist": "\(jsonEscaped(artist))", "album": "\(jsonEscaped(album))", \
    "duration": \(durationText), "kind": "\(jsonEscaped(kind))", \
    "bit_rate": \(bitRateText), "sample_rate": \(sampleRateText), \
    "cloud_status": "\(jsonEscaped(cloudStatus))", "is_file_track": \(isFileTrack)}
    """
}

func wirePlaylist(id: Int, name: String, persistentId: String, tracks: [String]) -> String {
    """
    {"id": \(id), "name": "\(jsonEscaped(name))", \
    "persistent_id": "\(jsonEscaped(persistentId))", "tracks": [\(tracks.joined(separator: ", "))]}
    """
}

func wireSnapshot(playlists: [String]) -> String {
    "{\"playlists\": [\(playlists.joined(separator: ", "))]}"
}

/// A single-playlist snapshot with one duplicate pair (distinct library
/// entries, bit-rate decision), one unique track, and one non-eligible track
/// (null duration).
func consolidateFixtureWire(name: String = "Fixture List") -> String {
    wireSnapshot(playlists: [
        wirePlaylist(
            id: 100,
            name: name,
            persistentId: "PLAYLIST0",
            tracks: [
                wireTrack(
                    sourceIndex: 0, databaseId: 11, persistentId: "AAAA0001",
                    title: "Shared Song", bitRate: 128
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
}

/// Two same-name copies listed OUT of playlist-id order in the wire payload
/// (id 20 before id 10) so plan-order assertions prove the ascending-id sort.
/// Copy id 10 (pid "C-LOW"): [A, B]; copy id 20 (pid "C-HIGH"): [A again
/// (same library track), C]. Expected merge: winner A from the earlier copy
/// (source order), B and C unique.
func mergeFixtureWire(name: String = "Merge List") -> String {
    let sharedLow = wireTrack(
        sourceIndex: 0, databaseId: 21, persistentId: "BBBB0001", title: "Both Copies"
    )
    let uniqueLow = wireTrack(
        sourceIndex: 1, databaseId: 22, persistentId: "BBBB0002", title: "Low Only"
    )
    let sharedHigh = wireTrack(
        sourceIndex: 0, databaseId: 21, persistentId: "BBBB0001", title: "Both Copies"
    )
    let uniqueHigh = wireTrack(
        sourceIndex: 1, databaseId: 23, persistentId: "BBBB0003", title: "High Only"
    )
    return wireSnapshot(playlists: [
        wirePlaylist(id: 20, name: name, persistentId: "C-HIGH", tracks: [sharedHigh, uniqueHigh]),
        wirePlaylist(id: 10, name: name, persistentId: "C-LOW", tracks: [sharedLow, uniqueLow]),
    ])
}

// MARK: - apply-sequence wire fixtures (M9)

/// The empty read result the target-absence check expects.
func emptySnapshotWire() -> String {
    "{\"playlists\": []}"
}

/// Target readback matching `consolidateFixtureWire`'s plan winners exactly:
/// winner indexes [1, 2, 3] -> database IDs [12, 13, 14], persistent IDs
/// [AAAA0002, AAAA0003, AAAA0004] in output order (the verifier compares
/// ordered database IDs + persistent IDs).
func consolidateTargetReadbackWire(sourceName: String = "Fixture List") -> String {
    wireSnapshot(playlists: [
        wirePlaylist(
            id: 900,
            name: "\(sourceName) \u{2014} Consolidated",
            persistentId: "TARGET0",
            tracks: [
                wireTrack(
                    sourceIndex: 0, databaseId: 12, persistentId: "AAAA0002",
                    title: "Shared Song", bitRate: 256
                ),
                wireTrack(
                    sourceIndex: 1, databaseId: 13, persistentId: "AAAA0003",
                    title: "Only Once"
                ),
                wireTrack(
                    sourceIndex: 2, databaseId: 14, persistentId: "AAAA0004",
                    title: "No Duration", duration: nil
                ),
            ]
        )
    ])
}

/// The six apply-sequence outputs for a `consolidateFixtureWire` audit, in
/// dispatch order: ensure re-read, target-absent read, compile, execute,
/// source readback, target readback.
func consolidateApplyOutputs(name: String = "Fixture List") -> [String] {
    [
        consolidateFixtureWire(name: name),
        emptySnapshotWire(),
        "",
        "",
        consolidateFixtureWire(name: name),
        consolidateTargetReadbackWire(sourceName: name),
    ]
}

/// Target readback matching `mergeFixtureWire`'s plan winners exactly:
/// combined order is copy C-LOW [A, B] then C-HIGH [A again, C]; winners
/// [0, 1, 3] -> database IDs [21, 22, 23], persistent IDs [BBBB0001,
/// BBBB0002, BBBB0003].
func mergeTargetReadbackWire(sourceName: String = "Merge List") -> String {
    wireSnapshot(playlists: [
        wirePlaylist(
            id: 900,
            name: "\(sourceName) \u{2014} Merged",
            persistentId: "TARGET0",
            tracks: [
                wireTrack(
                    sourceIndex: 0, databaseId: 21, persistentId: "BBBB0001",
                    title: "Both Copies"
                ),
                wireTrack(
                    sourceIndex: 1, databaseId: 22, persistentId: "BBBB0002",
                    title: "Low Only"
                ),
                wireTrack(
                    sourceIndex: 2, databaseId: 23, persistentId: "BBBB0003",
                    title: "High Only"
                ),
            ]
        )
    ])
}

/// The six merge apply-sequence outputs for a `mergeFixtureWire` audit.
func mergeApplyOutputs(name: String = "Merge List") -> [String] {
    [
        mergeFixtureWire(name: name),
        emptySnapshotWire(),
        "",
        "",
        mergeFixtureWire(name: name),
        mergeTargetReadbackWire(sourceName: name),
    ]
}

// MARK: - hermetic in-memory defaults (M11 fix round 1, finding 2)

/// A UserDefaults that NEVER touches disk: every named suite used to
/// materialize an m7-tests-<UUID>.plist in the real ~/Library/Preferences
/// on first write (876 accumulated). All accessors the model uses are
/// overridden onto a plain dictionary; `synchronize` is a no-op, so no
/// cfprefsd traffic and no file, ever. The zero-leak regression pin lives
/// in M11FlowTests.
final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private var storage: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }

    override func string(forKey defaultName: String) -> String? {
        storage[defaultName] as? String
    }

    override func bool(forKey defaultName: String) -> Bool {
        storage[defaultName] as? Bool ?? false
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        storage[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        storage[defaultName] = nil
    }

    override func removePersistentDomain(forName domainName: String) {
        storage = [:]
    }

    override func synchronize() -> Bool {
        true
    }
}

// MARK: - model harness (temp output dir + hermetic in-memory defaults)

@MainActor
struct ModelHarness {
    let model: AuditFlowModel
    let outputDirectory: URL
    let cacheDirectory: URL
    let defaults: UserDefaults

    /// `confirmEachApply` defaults TRUE here (not the app default, which is
    /// false — pinned by the M11 suite via direct construction): the
    /// pre-M11 queue tests pin the ATTENDED per-item machinery, which
    /// remains reachable exactly through this setting. M11's unattended
    /// tests pass `confirmEachApply: false` explicitly.
    init(
        runner: any ScriptRunner & Sendable,
        mode: ConsolidatorMode = .consolidate,
        playlistName: String = "Fixture List",
        confirmEachApply: Bool = true,
        playFinishSound: @escaping @Sendable () -> Void = { NSSound(named: "Glass")?.play() }
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m7-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.outputDirectory = directory
        // M11: an isolated per-test cache directory — tests must never
        // touch the real Application Support cache.
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m11-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true
        )
        self.cacheDirectory = cacheDirectory
        // Hermetic: an in-memory defaults object — no plist can ever
        // materialize in the real ~/Library/Preferences (fix round 1,
        // finding 2).
        let suite = InMemoryDefaults()
        self.defaults = suite
        let model = AuditFlowModel(
            makeRunner: { runner },
            defaults: suite,
            defaultOutputDirectoryPath: directory.path,
            cacheDirectoryPath: cacheDirectory.path,
            playFinishSound: playFinishSound
        )
        model.setMode(mode)
        model.playlistName = playlistName
        model.setConfirmEachApply(confirmEachApply)
        self.model = model
    }

    /// Await the in-flight audit task, if any.
    func awaitAudit() async {
        await model.auditTask?.value
    }

    /// Await the in-flight apply task, if any (M9).
    func awaitApply() async {
        await model.applyTask?.value
    }

    /// Drive audit -> satisfied gate: run one audit and complete both
    /// confirm gates with the exact target name (M9 helper).
    func auditAndSatisfyGate() async throws {
        model.startAudit()
        await awaitAudit()
        guard let target = model.targetName else {
            throw AppTestError("audit did not complete; no target name")
        }
        model.reviewedPlanToggle = true
        model.typedTargetName = target
    }

    func artifactFileCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).count
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: "in-memory")
        try? FileManager.default.removeItem(at: outputDirectory)
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}

// MARK: - track builder for pure presentation tests

func presentationTrack(
    sourceIndex: Int = 0,
    databaseId: Int = 1,
    persistentId: String = "PID0",
    title: String = "Title",
    artist: String = "Artist",
    album: String = "Album",
    durationMs: Int? = 200_000,
    kind: String = "AAC audio file",
    bitRateKbps: Int? = 256,
    sampleRateHz: Int? = 44100,
    cloudStatus: String = "subscription",
    isFileTrack: Bool = false
) -> TrackSnapshot {
    TrackSnapshot(
        sourceIndex: sourceIndex,
        databaseId: databaseId,
        persistentId: persistentId,
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        kind: kind,
        bitRateKbps: bitRateKbps,
        sampleRateHz: sampleRateHz,
        cloudStatus: cloudStatus,
        isFileTrack: isFileTrack
    )
}
