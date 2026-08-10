// MusicBridgeMergeTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Ported same-name merge orchestration cases from tests/test_music_bridge.py:
// EnsureAllCopiesMatchTests and MergeApplyTests. Expected messages and result
// shapes were verified against the reference in python3 first (including the
// canonical merge winner order (2, 1) for the Trance 2022 fixture). No script
// is ever executed.

import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

/// tests/test_music_bridge.py::EnsureAllCopiesMatchTests._copies
private func ensureCopies() -> [PlaylistSnapshot] {
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

@Suite("ensure_all_copies_match (ported EnsureAllCopiesMatchTests)")
struct EnsureAllCopiesMatchPortTests {

    // test_returns_live_copies_in_plan_order
    @Test("returns live copies in plan order")
    func returnsLiveCopiesInPlanOrder() throws {
        let copies = ensureCopies()
        let plan = try buildMergePlan(name: "G", copies: copies)
        let reversedLive = Array(copies.reversed())

        let result = try FakeCopiesBridge(copies: reversedLive).ensureAllCopiesMatch(plan: plan)

        #expect(result.map(\.persistentId) == ["PID-A", "PID-B"])
    }

    // test_rejects_a_missing_copy
    @Test("rejects a missing copy")
    func rejectsMissingCopy() throws {
        let copies = ensureCopies()
        let plan = try buildMergePlan(name: "G", copies: copies)

        expectThrowsByteEqualMessage(
            "live copy count changed after audit: planned 2, actual 1; create a fresh audit",
            context: "missing copy"
        ) {
            _ = try FakeCopiesBridge(copies: [copies[0]]).ensureAllCopiesMatch(plan: plan)
        }
    }

    // test_rejects_an_extra_unexpected_copy
    @Test("rejects an extra unexpected copy")
    func rejectsExtraCopy() throws {
        let copies = ensureCopies()
        let plan = try buildMergePlan(name: "G", copies: copies)
        let extra = copies + [
            PlaylistSnapshot(
                name: "G",
                persistentId: "PID-C",
                tracks: [track(sourceIndex: 0, databaseId: 9, persistentId: "C0")]
            )
        ]

        expectThrowsByteEqualMessage(
            "live copy count changed after audit: planned 2, actual 3; create a fresh audit",
            context: "extra copy"
        ) {
            _ = try FakeCopiesBridge(copies: extra).ensureAllCopiesMatch(plan: plan)
        }
    }

    // test_rejects_track_drift_in_any_copy
    @Test("rejects track drift in any copy")
    func rejectsTrackDriftInAnyCopy() throws {
        let copies = ensureCopies()
        let plan = try buildMergePlan(name: "G", copies: copies)
        var driftedTrack = copies[1].tracks[0]
        driftedTrack.title = "Changed"
        let drifted = [
            copies[0],
            PlaylistSnapshot(name: "G", persistentId: "PID-B", tracks: [driftedTrack]),
        ]

        expectThrowsByteEqualMessage(
            "copy 'PID-B' changed after audit: source track 1 title mismatch after write: "
                + "planned 'Two', actual 'Changed'; create a fresh audit",
            context: "copy track drift"
        ) {
            _ = try FakeCopiesBridge(copies: drifted).ensureAllCopiesMatch(plan: plan)
        }
    }

    // Reference-verified extra fail-closed surfaces of ensure_all_copies_match
    // (python3: duplicate live PID and a same-count PID replacement).
    @Test("rejects duplicate live persistent IDs and an absent expected copy")
    func rejectsDuplicateAndAbsentPersistentIds() throws {
        let copies = ensureCopies()
        let plan = try buildMergePlan(name: "G", copies: copies)

        let duplicate = [
            copies[0],
            PlaylistSnapshot(name: "G", persistentId: "PID-A", tracks: copies[1].tracks),
        ]
        expectThrowsByteEqualMessage(
            "live copies contain a duplicate persistent ID",
            context: "duplicate live PID"
        ) {
            _ = try FakeCopiesBridge(copies: duplicate).ensureAllCopiesMatch(plan: plan)
        }

        let replaced = [
            copies[0],
            PlaylistSnapshot(name: "G", persistentId: "PID-X", tracks: copies[1].tracks),
        ]
        expectThrowsByteEqualMessage(
            "expected copy 'PID-B' is absent; create a fresh audit",
            context: "absent expected PID"
        ) {
            _ = try FakeCopiesBridge(copies: replaced).ensureAllCopiesMatch(plan: plan)
        }
    }
}

/// tests/test_music_bridge.py::MergeApplyTests._copies
private func mergeApplyCopies() -> [PlaylistSnapshot] {
    [
        PlaylistSnapshot(
            name: "Trance 2022",
            persistentId: "PID-A",
            tracks: [
                track(
                    sourceIndex: 0, databaseId: 1, persistentId: "LOSSY",
                    title: "One", durationMs: 180001, sampleRateHz: 44100
                ),
                track(
                    sourceIndex: 1, databaseId: 2, persistentId: "UNIQUE-A",
                    title: "Two", durationMs: 200002
                ),
            ]
        ),
        PlaylistSnapshot(
            name: "Trance 2022",
            persistentId: "PID-B",
            tracks: [
                track(
                    sourceIndex: 0, databaseId: 3, persistentId: "LOSSLESS",
                    title: "One", durationMs: 180001, kind: "AIFF audio file",
                    sampleRateHz: 96000
                ),
            ]
        ),
    ]
}

@Suite("Merge apply orchestration (ported MergeApplyTests)")
struct MergeApplyPortTests {

    private func plan() throws -> MergePlan {
        try buildMergePlan(name: "Trance 2022", copies: mergeApplyCopies())
    }

    private func winnerTracks(_ plan: MergePlan) -> [TrackSnapshot] {
        let combined = plan.combinedTracks
        return plan.winnerSourceIndexes.map { combined[$0] }
    }

    // test_verified_success_when_target_matches_winner_order
    @Test("verified success when the target matches winner order")
    func verifiedSuccess() throws {
        let plan = try plan()
        // Reference-verified: winner_source_indexes == (2, 1) for this fixture.
        #expect(plan.winnerSourceIndexes == [2, 1])
        let target = PlaylistSnapshot(
            name: "Trance 2022 — Merged", persistentId: "T", tracks: winnerTracks(plan)
        )
        let bridge = MergeApplyBridge(copies: mergeApplyCopies(), targetReadback: target)

        let result = try bridge.applyMergePlan(plan: plan, targetName: "Trance 2022 — Merged")

        #expect(result.verificationOk == true)
        #expect(result.plannedCount == plan.winnerSourceIndexes.count)
        #expect(result.actualCount == plan.winnerSourceIndexes.count)
        #expect(result.mismatches.isEmpty)
        #expect(bridge.writeCalls == 1)
    }

    // test_readback_order_mismatch_fails_closed
    @Test("readback order mismatch fails closed")
    func readbackOrderMismatchFailsClosed() throws {
        let plan = try plan()
        let target = PlaylistSnapshot(
            name: "Trance 2022 — Merged",
            persistentId: "T",
            tracks: winnerTracks(plan).reversed()
        )

        let result = try MergeApplyBridge(copies: mergeApplyCopies(), targetReadback: target)
            .applyMergePlan(plan: plan, targetName: "Trance 2022 — Merged")

        #expect(result.verificationOk == false)
        // Reference-verified exact mismatch sequence for the reversed readback.
        #expect(result.mismatches == [
            "track 1 database ID mismatch: planned 3, actual 2",
            "track 1 persistent ID mismatch: planned 'LOSSLESS', actual 'UNIQUE-A'",
            "track 2 database ID mismatch: planned 2, actual 3",
            "track 2 persistent ID mismatch: planned 'UNIQUE-A', actual 'LOSSLESS'",
        ])
    }

    // test_writer_failure_returns_inspected_diagnostics_without_raising
    @Test("writer failure returns inspected diagnostics without raising")
    func writerFailureReturnsDiagnostics() throws {
        let plan = try plan()
        let target = PlaylistSnapshot(
            name: "Trance 2022 — Merged",
            persistentId: "T",
            tracks: [winnerTracks(plan)[0]]
        )
        let bridge = MergeApplyBridge(copies: mergeApplyCopies(), targetReadback: target)
        bridge.raiseOnWrite = MusicCommandError("simulated merge writer failure")

        let result = try bridge.applyMergePlan(plan: plan, targetName: "Trance 2022 — Merged")

        #expect(result.verificationOk == false)
        // Reference-verified exact diagnostics for the partial merge target.
        #expect(result.mismatches == [
            "write failed: simulated merge writer failure",
            "track count mismatch: planned 2, actual 1",
            "track 2 missing: planned database ID 2, persistent ID 'UNIQUE-A'",
        ])
    }

    // test_merge_writer_error_remains_failure_when_target_matches_complete_plan
    @Test("merge writer error remains a failure when the target matches the complete plan")
    func mergeWriterErrorRemainsFailureOnCompleteTarget() throws {
        let plan = try plan()
        let target = PlaylistSnapshot(
            name: "Trance 2022 — Merged", persistentId: "T", tracks: winnerTracks(plan)
        )
        let bridge = MergeApplyBridge(copies: mergeApplyCopies(), targetReadback: target)
        bridge.raiseOnWrite = MusicCommandError("simulated merge writer failure")

        let result = try bridge.applyMergePlan(plan: plan, targetName: "Trance 2022 — Merged")

        #expect(result.verificationOk == false)
        #expect(result.mismatches == [
            "write failed: simulated merge writer failure",
            "target readback matches the complete plan despite writer failure",
        ])
    }

    // test_source_copy_drift_after_write_fails_even_if_target_matches
    @Test("source copy drift after write fails even if the target matches")
    func sourceCopyDriftAfterWriteFails() throws {
        let plan = try plan()
        let copies = mergeApplyCopies()
        let target = PlaylistSnapshot(
            name: "Trance 2022 — Merged", persistentId: "T", tracks: winnerTracks(plan)
        )
        var driftedTrack = copies[1].tracks[0]
        driftedTrack.title = "X"
        let bridge = DriftMergeApplyBridge(copies: copies, targetReadback: target)
        bridge.driftedCopies = [
            copies[0],
            PlaylistSnapshot(name: "Trance 2022", persistentId: "PID-B", tracks: [driftedTrack]),
        ]

        let result = try bridge.applyMergePlan(plan: plan, targetName: "Trance 2022 — Merged")

        #expect(result.verificationOk == false)
        #expect(result.mismatches.contains { mismatch in
            ByteText(mismatch).contains("copy") || ByteText(mismatch).contains("source")
        })
        // Reference-verified first diagnostic for the drifted copy title.
        #expect(result.mismatches.first ==
            "source track 1 title mismatch after write: planned 'One', actual 'X'")
        #expect(result.mismatches.count == 2)
        #expect(result.mismatches[1].hasPrefix("source fingerprint mismatch after write: planned "))
    }
}
