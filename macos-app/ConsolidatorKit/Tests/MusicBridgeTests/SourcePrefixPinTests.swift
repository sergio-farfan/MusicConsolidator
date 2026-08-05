// SourcePrefixPinTests.swift
// Wave C1 Task 2 — pins the "source " prefix contract the taxonomy's rule 4
// rides on (spec C1.2): EVERY source-side readback message constructor in
// MusicBridge.swift emits a line whose first seven scalars are exactly
// "source ", so a future message change breaks HERE (red) before it can
// silently flip sourceDrifted/targetMismatch classification in the app.
// Characterization pins: green against current behavior by design; the
// messages themselves are reference-verbatim and MUST NOT be changed to
// satisfy this suite.

import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

private func scalarPrefixed(_ line: String, _ prefix: String) -> Bool {
    line.unicodeScalars.starts(with: prefix.unicodeScalars)
}

@Suite("Wave C1 — every source-side mismatch message begins 'source '")
struct SourcePrefixPinTests {

    @Test("sourceMismatches: every constructor fires and every line is prefixed")
    func sourceMismatchesAllPrefixed() {
        let expected = PlaylistSnapshot(
            name: "Daechir ESP ORIG",
            persistentId: "PID-EXPECTED0001",
            tracks: [
                track(sourceIndex: 0, databaseId: 1, persistentId: "T0"),
                track(sourceIndex: 1, databaseId: 2, persistentId: "T1"),
            ]
        )
        // The readback differs in the playlist name, the playlist persistent
        // ID, the track count, and EVERY compared field of track 1 (order
        // included), so all sixteen message constructors in sourceMismatches
        // fire at least once: name, playlist PID, count, order, the eleven
        // per-field messages, and the fingerprint.
        let actual = PlaylistSnapshot(
            name: "Daechir ESP ORIG (renamed)",
            persistentId: "PID-DRIFTED00001",
            tracks: [
                track(
                    sourceIndex: 9, databaseId: 99, persistentId: "T9",
                    title: "Other", artist: "Else", album: "Elsewhere",
                    durationMs: 1, kind: "MPEG audio file", bitRateKbps: 96,
                    sampleRateHz: 22050, cloudStatus: "uploaded", isFileTrack: true
                ),
                track(sourceIndex: 1, databaseId: 2, persistentId: "T1"),
                track(sourceIndex: 2, databaseId: 3, persistentId: "T2"),
            ]
        )
        let lines = sourceMismatches(expected: expected, actual: actual)
        #expect(lines.count == 16, "constructor coverage drifted: \(lines.count) lines")
        for line in lines {
            #expect(scalarPrefixed(line, "source "), "unprefixed source message: \(line)")
        }
    }

    @Test("copiesMismatches: copy-count and missing-copy messages are prefixed")
    func copiesMismatchesAllPrefixed() {
        let copyA = PlaylistSnapshot(
            name: "New Age Favs", persistentId: "CPY-A", tracks: [track()]
        )
        let copyB = PlaylistSnapshot(
            name: "New Age Favs", persistentId: "CPY-B", tracks: [track()]
        )
        let lines = copiesMismatches(expectedCopies: [copyA, copyB], actualCopies: [copyA])
        // "source copy count mismatch after write: …" plus
        // "source copy 'CPY-B' missing after write" (copyA matches itself).
        #expect(lines.count == 2)
        for line in lines {
            #expect(scalarPrefixed(line, "source "), "unprefixed copy message: \(line)")
        }
    }
}

// MARK: - rule 3b read-failure prefixes (spec C1.2 rule 3b, controller amendment 2026-08-04)

/// applyPlan boundary fake: the write SUCCEEDS, then the requested
/// post-write read (source or target) throws — the bridge must surface the
/// caught error as a mismatch LINE with the pinned prefix. Same subclass
/// pattern as the OrchestrationTestSupport fakes; UnusedRunner guarantees
/// nothing reaches a real runner seam.
private final class PostWriteReadFailureBridge: MusicBridgeSession {
    let source: PlaylistSnapshot
    let target: PlaylistSnapshot
    let failSourceReadback: Bool
    let failTargetReadback: Bool
    var writeCalls = 0

    init(
        source: PlaylistSnapshot,
        target: PlaylistSnapshot,
        failSourceReadback: Bool,
        failTargetReadback: Bool
    ) {
        self.source = source
        self.target = target
        self.failSourceReadback = failSourceReadback
        self.failTargetReadback = failTargetReadback
        super.init(runner: UnusedRunner())
    }

    override func snapshotPlaylist(name: String) throws -> PlaylistSnapshot {
        if name == source.name {
            if writeCalls > 0, failSourceReadback {
                throw MusicCommandError(
                    "JXA execution failed: error -1728: Error: Error: Can't get object."
                )
            }
            return source
        }
        if failTargetReadback {
            throw MusicCommandError(
                "JXA execution failed: error -1728: Error: Error: Can't get object."
            )
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

/// applyMergePlan boundary fake: the write SUCCEEDS, then the post-write
/// copies re-read throws — the real New Age Favs shape.
private final class MergeCopiesReadFailureBridge: MusicBridgeSession {
    let copies: [PlaylistSnapshot]
    let target: PlaylistSnapshot
    var writeCalls = 0

    init(copies: [PlaylistSnapshot], target: PlaylistSnapshot) {
        self.copies = copies
        self.target = target
        super.init(runner: UnusedRunner())
    }

    override func snapshotAllCopies(name: String) throws -> [PlaylistSnapshot] {
        if writeCalls > 0 {
            throw MusicCommandError(
                "JXA execution failed: error -1728: Error: Error: Can't get object."
            )
        }
        return copies
    }

    override func snapshotPlaylist(name: String) throws -> PlaylistSnapshot {
        target
    }

    override func assertTargetAbsent(targetName: String) throws {}

    override func runMergeApplyScript(
        plan: MergePlan,
        verifiedCopies: [PlaylistSnapshot],
        targetName: String
    ) throws {
        writeCalls += 1
    }
}

@Suite("Wave C1 — rule 3b readback-READ failure line prefixes (pinned)")
struct ReadbackFailurePrefixPinTests {

    @Test("a post-write SOURCE read failure surfaces the pinned line; target still verifies")
    func sourceReadFailureLinePinned() throws {
        let source = orchestrationSourceSnapshot()
        let plan = try buildPlan(source)
        let target = PlaylistSnapshot(name: "Target", persistentId: "T", tracks: source.tracks)
        let bridge = PostWriteReadFailureBridge(
            source: source, target: target,
            failSourceReadback: true, failTargetReadback: false
        )

        let result = try bridge.applyPlan(plan: plan, targetName: "Target")

        #expect(!result.verificationOk)
        // The clean target contributes no lines (finding 1: the target read
        // and comparison still ran), so the caught source-read error is the
        // ONLY line — with the exact rule-3b prefix.
        #expect(result.mismatches.count == 1)
        #expect(scalarPrefixed(
            result.mismatches[0], "source readback failed after write: "
        ), "wording drifted: \(result.mismatches)")
    }

    @Test("a post-write TARGET read failure surfaces the pinned line")
    func targetReadFailureLinePinned() throws {
        let source = orchestrationSourceSnapshot()
        let plan = try buildPlan(source)
        let bridge = PostWriteReadFailureBridge(
            source: source,
            target: PlaylistSnapshot(name: "Target", persistentId: "T", tracks: source.tracks),
            failSourceReadback: false, failTargetReadback: true
        )

        let result = try bridge.applyPlan(plan: plan, targetName: "Target")

        #expect(!result.verificationOk)
        #expect(result.mismatches.count == 1)
        #expect(scalarPrefixed(
            result.mismatches[0], "target readback failed after write: "
        ), "wording drifted: \(result.mismatches)")
    }

    @Test("a post-write COPIES read failure surfaces the pinned line (New Age Favs shape)")
    func copiesReadFailureLinePinned() throws {
        let copies = [
            PlaylistSnapshot(
                name: "New Age Favs", persistentId: "PID-A",
                tracks: [track(sourceIndex: 0, databaseId: 1, persistentId: "A0")]
            ),
            PlaylistSnapshot(
                name: "New Age Favs", persistentId: "PID-B",
                tracks: [track(sourceIndex: 0, databaseId: 2, persistentId: "B0", title: "Two")]
            ),
        ]
        let plan = try buildMergePlan(name: "New Age Favs", copies: copies)
        // Distinct titles -> both tracks win in combined (copy) order, so
        // this target verifies clean and contributes no lines.
        let target = PlaylistSnapshot(
            name: "Target", persistentId: "T",
            tracks: [copies[0].tracks[0], copies[1].tracks[0]]
        )
        let bridge = MergeCopiesReadFailureBridge(copies: copies, target: target)

        let result = try bridge.applyMergePlan(plan: plan, targetName: "Target")

        #expect(!result.verificationOk)
        #expect(result.mismatches.count == 1)
        #expect(scalarPrefixed(
            result.mismatches[0], "source copies readback failed after write: "
        ), "wording drifted: \(result.mismatches)")
    }
}
