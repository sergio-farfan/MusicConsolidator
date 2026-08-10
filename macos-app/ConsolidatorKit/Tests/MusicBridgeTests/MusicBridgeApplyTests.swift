// MusicBridgeApplyTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Ported fail-closed apply orchestration cases from tests/test_music_bridge.py:
// PlanIntegrityBridgeTests, the source-drift-after-dispatch case,
// WriterFailureDiagnosticsTests, and MusicBridgeTests' orchestration cases
// (precompiled-artifact dispatch, target collision, stale plan, identity
// change, readback mismatches, ensure_source_matches). Expected messages were
// verified against the reference in python3 first. No script is ever executed.

import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

@Suite("Plan integrity at the apply boundary (ported PlanIntegrityBridgeTests)")
struct PlanIntegrityBridgePortTests {

    // test_altered_winner_indexes_are_rejected_before_target_lookup_or_write
    @Test("altered winner indexes are rejected before target lookup or write")
    func alteredWinnerIndexesRejected() throws {
        let source = PlaylistSnapshot(
            name: "Source",
            persistentId: "P",
            tracks: [
                track(sourceIndex: 0, databaseId: 10, persistentId: "LOW", sampleRateHz: 44100),
                track(sourceIndex: 1, databaseId: 20, persistentId: "HIGH", sampleRateHz: 48000),
            ]
        )
        let canonical = try buildPlan(source)
        let altered = ConsolidationPlan(
            sourcePlaylistName: canonical.sourcePlaylistName,
            sourcePlaylistPersistentId: canonical.sourcePlaylistPersistentId,
            sourceFingerprint: canonical.sourceFingerprint,
            sourceTrackCount: canonical.sourceTrackCount,
            sourceTracks: canonical.sourceTracks,
            winnerSourceIndexes: [0],
            decisions: canonical.decisions,
            nonEligibleSourceIndexes: canonical.nonEligibleSourceIndexes
        )
        let readback = PlaylistSnapshot(name: "Target", persistentId: "T", tracks: [source.tracks[0]])
        let bridge = BoundaryRecordingBridge(source: source, readback: readback)

        expectThrowsByteEqualMessage(
            "source playlist changed after audit or plan is non-canonical; "
                + "loaded consolidation plan is not canonical for the verified source; "
                + "create a fresh audit",
            context: "altered winners"
        ) {
            _ = try bridge.applyPlan(plan: altered, targetName: "Target")
        }
        #expect(bridge.targetAbsenceChecks == 0)
        #expect(bridge.writeCalls == 0)
    }

    // test_noncanonical_cloud_status_is_rejected_before_target_lookup
    @Test("noncanonical cloud status is rejected before target lookup")
    func noncanonicalCloudStatusRejected() throws {
        let source = PlaylistSnapshot(
            name: "Source",
            persistentId: "P",
            tracks: [
                track(
                    sourceIndex: 0,
                    databaseId: 10,
                    persistentId: "CLOUD-A",
                    cloudStatus: "Subscription"
                ),
            ]
        )
        let bridge = BoundaryRecordingBridge(
            source: source,
            readback: PlaylistSnapshot(name: "Target", persistentId: "T", tracks: [])
        )
        let plan = try buildPlan(source)

        expectThrowsByteEqualMessage(
            "source playlist changed after audit or plan is non-canonical; "
                + "unsupported cloud status 'Subscription' at source index 0; "
                + "create a fresh audit",
            context: "unsupported cloud status"
        ) {
            _ = try bridge.applyPlan(plan: plan, targetName: "Target")
        }
        #expect(bridge.targetAbsenceChecks == 0)
        #expect(bridge.writeCalls == 0)
    }
}

@Suite("Apply orchestration (ported MusicBridgeTests orchestration cases)")
struct ApplyOrchestrationPortTests {

    // test_writer_executes_exact_precompiled_artifact_without_state
    @Test("writer dispatch compiles then executes the exact precompiled artifact")
    func writerExecutesExactPrecompiledArtifact() throws {
        let source = PlaylistSnapshot(name: "Source", persistentId: "P", tracks: [track()])
        let runner = FakeRunner(outputs: ["", ""])
        let plan = try buildPlan(source)

        try MusicBridgeSession(runner: runner).runApplyScript(
            plan: plan, source: source, targetName: "Target"
        )

        #expect(runner.calls.count == 2)
        guard case .compileAppleScript(let script, let outputPath) = runner.calls[0] else {
            Issue.record("first call must be the compile: \(runner.calls)")
            return
        }
        let probe = ByteText(script)
        #expect(probe.contains("tell application \"/System/Applications/Music.app\""))
        #expect(probe.contains("make new user playlist"))
        #expect(outputPath.hasSuffix("writer.scpt"))
        guard case .executeCompiledScript(let path) = runner.calls[1] else {
            Issue.record("second call must execute the compiled artifact: \(runner.calls)")
            return
        }
        #expect(path == outputPath)
    }

    // test_target_collision_is_rejected_before_the_guarded_write
    @Test("target collision is rejected before the guarded write")
    func targetCollisionRejected() {
        let raw = """
        {"playlists": [{"name": "Target", "persistent_id": "T", "tracks": []}]}
        """
        let runner = FakeRunner(outputs: [raw])

        expectThrowsByteEqualMessage(
            "target user playlist already exists",
            context: "target collision"
        ) {
            try MusicBridgeSession(runner: runner).assertTargetAbsent(targetName: "Target")
        }
        #expect(runner.calls == [.readJXA(script: buildReadJXA(name: "Target"))])
    }

    // test_apply_refuses_a_stale_plan_before_creating_target
    @Test("apply refuses a stale plan before creating the target")
    func applyRefusesStalePlan() throws {
        let original = orchestrationSourceSnapshot()
        let plan = try buildPlan(original)
        let changed = PlaylistSnapshot(
            name: "Source",
            persistentId: "P",
            tracks: [
                track(sourceIndex: 0, databaseId: 1, persistentId: "A", bitRateKbps: 128),
                original.tracks[1],
            ]
        )
        let bridge = InMemoryBridge(source: changed, readback: changed)

        expectThrowsMessageContaining(
            "changed after audit",
            context: "stale plan"
        ) {
            _ = try bridge.applyPlan(plan: plan, targetName: "#Musica xTotal — Consolidated")
        }
        #expect(bridge.writeCalls == 0)
    }

    // test_apply_refuses_a_source_playlist_identity_change_before_writing
    @Test("apply refuses a source playlist identity change before writing")
    func applyRefusesSourceIdentityChange() throws {
        let original = orchestrationSourceSnapshot()
        let bridge = InMemoryBridge(
            source: PlaylistSnapshot(name: "Source", persistentId: "CHANGED", tracks: original.tracks),
            readback: original
        )
        let plan = try buildPlan(original)

        expectThrowsByteEqualMessage(
            "source playlist changed after audit or plan is non-canonical; "
                + "verified source persistent ID does not match consolidation plan; "
                + "create a fresh audit",
            context: "identity change"
        ) {
            _ = try bridge.applyPlan(plan: plan, targetName: "Target")
        }
        #expect(bridge.writeCalls == 0)
    }

    // test_apply_returns_mismatches_when_readback_order_or_ids_differ
    @Test("apply returns mismatches when readback order or ids differ")
    func applyReturnsMismatchesOnReadbackDivergence() throws {
        let source = orchestrationSourceSnapshot()
        let readback = PlaylistSnapshot(
            name: "Target", persistentId: "T", tracks: source.tracks.reversed()
        )
        let bridge = InMemoryBridge(source: source, readback: readback)

        let result = try bridge.applyPlan(plan: buildPlan(source), targetName: "Target")

        #expect(result.plannedCount == 2)
        #expect(result.actualCount == 2)
        #expect(result.verificationOk == false)
        #expect(!result.mismatches.isEmpty)
        #expect(bridge.writeCalls == 1)
    }

    // test_ensure_source_matches_returns_unchanged_audited_snapshot
    @Test("ensure_source_matches returns the unchanged audited snapshot")
    func ensureSourceMatchesReturnsUnchangedSnapshot() throws {
        let source = PlaylistSnapshot(
            name: "#Musica xTotal",
            persistentId: "PLAYLIST-123",
            tracks: [
                track(
                    sourceIndex: 0,
                    databaseId: 101,
                    persistentId: "TRACK-A",
                    title: "Rock—Song",
                    album: "Album One",
                    durationMs: 183456,
                    cloudStatus: "matched"
                ),
                track(
                    sourceIndex: 1,
                    databaseId: 202,
                    persistentId: "TRACK-B",
                    title: "Local Song",
                    artist: "Artist",
                    album: "",
                    durationMs: nil,
                    kind: "MPEG audio file",
                    bitRateKbps: nil,
                    sampleRateHz: nil,
                    isFileTrack: true
                ),
            ]
        )
        let runner = FakeRunner(outputs: [try musicSnapshotFixtureText()])

        let actual = try MusicBridgeSession(runner: runner).ensureSourceMatches(plan: buildPlan(source))

        // Module-qualified: resolves to ScalarSupport.swift's scalarEqual now
        // that the class no longer shadows the module name (fix M5-5). Bound
        // to a local because the #expect macro cannot expand a call qualified
        // by a module reference.
        let matchesVerifiedSource = MusicBridge.scalarEqual(actual, source)
        #expect(matchesVerifiedSource)
    }

    // test_ensure_source_matches_rejects_track_drift
    @Test("ensure_source_matches rejects track drift")
    func ensureSourceMatchesRejectsTrackDrift() throws {
        let auditedSource = PlaylistSnapshot(name: "Source", persistentId: "P", tracks: [track()])
        let changedPayload = """
        {"playlists": [{"name": "Source", "persistent_id": "P", "tracks": [
            {"source_index": 0, "database_id": 1, "persistent_id": "ABC",
             "title": "Changed", "artist": "Björk", "album": "Album",
             "duration": 183, "kind": "Apple Music AAC audio file",
             "bit_rate": 256, "sample_rate": 44100, "cloud_status": "",
             "is_file_track": false}
        ]}]}
        """
        let plan = try buildPlan(auditedSource)

        expectThrowsByteEqualMessage(
            "source playlist changed after audit or plan is non-canonical; "
                + "verified source fingerprint does not match consolidation plan; "
                + "create a fresh audit",
            context: "track drift"
        ) {
            _ = try MusicBridgeSession(runner: FakeRunner(outputs: [changedPayload]))
                .ensureSourceMatches(plan: plan)
        }
    }

    // test_source_drift_after_writer_dispatch_fails_even_when_target_matches
    @Test("source drift after writer dispatch fails even when the target matches")
    func sourceDriftAfterDispatchFails() throws {
        let source = orchestrationSourceSnapshot()
        let target = PlaylistSnapshot(name: "Target", persistentId: "T", tracks: source.tracks)
        // Python's `replace(source, tracks=tuple(reversed(source.tracks)))`
        // keeps each track's original source_index; only playlist order flips.
        let reindexedReversed = [source.tracks[1], source.tracks[0]]
        var changedDatabaseId = source.tracks[0]
        changedDatabaseId.databaseId = 999
        var changedTitle = source.tracks[0]
        changedTitle.title = "Changed"
        let mutations: [(label: String, changed: PlaylistSnapshot)] = [
            ("name", PlaylistSnapshot(name: "Renamed Source", persistentId: "P", tracks: source.tracks)),
            ("playlist persistent ID", PlaylistSnapshot(name: "Source", persistentId: "CHANGED", tracks: source.tracks)),
            ("track count", PlaylistSnapshot(name: "Source", persistentId: "P", tracks: [source.tracks[0]])),
            ("order", PlaylistSnapshot(name: "Source", persistentId: "P", tracks: reindexedReversed)),
            ("database ID", PlaylistSnapshot(name: "Source", persistentId: "P", tracks: [changedDatabaseId, source.tracks[1]])),
            ("title", PlaylistSnapshot(name: "Source", persistentId: "P", tracks: [changedTitle, source.tracks[1]])),
        ]
        let plan = try buildPlan(source)

        for mutation in mutations {
            let result = try SourceAfterWriteBridge(
                initialSource: source,
                changedSource: mutation.changed,
                target: target
            ).applyPlan(plan: plan, targetName: "Target")

            #expect(result.verificationOk == false, "mutation \(mutation.label)")
            #expect(
                result.mismatches.contains { mismatch in
                    ByteText(mismatch).contains("source") && ByteText(mismatch).contains(mutation.label)
                },
                "mutation \(mutation.label): \(result.mismatches)"
            )
        }
    }
}

@Suite("Writer failure diagnostics (ported WriterFailureDiagnosticsTests)")
struct WriterFailureDiagnosticsPortTests {

    private func apply(
        source: PlaylistSnapshot,
        targetState: WriterFailureBridge.TargetState
    ) throws -> ApplyResult {
        // The reference's helper fails the test if the writer failure escapes
        // apply_plan instead of returning diagnostics; a throw here surfaces
        // the same way through Swift Testing.
        try WriterFailureBridge(source: source, targetState: targetState)
            .applyPlan(plan: buildPlan(source), targetName: "Target")
    }

    // test_writer_failure_before_target_creation_returns_failed_diagnostics
    @Test("writer failure before target creation returns failed diagnostics")
    func writerFailureBeforeTargetCreation() throws {
        let result = try apply(source: orchestrationSourceSnapshot(), targetState: .absent)

        #expect(result.verificationOk == false)
        #expect(result.actualCount == 0)
        #expect(result.mismatches.contains(
            "write failed: simulated writer failure with private control text"
        ))
        #expect(result.mismatches.contains { ByteText($0).contains("no exact-name target exists") })
    }

    // test_writer_failure_reports_exact_partial_target_differences
    @Test("writer failure reports exact partial-target differences")
    func writerFailureReportsPartialTarget() throws {
        let source = orchestrationSourceSnapshot()
        let partial = PlaylistSnapshot(name: "Target", persistentId: "T", tracks: [source.tracks[0]])

        let result = try apply(source: source, targetState: .present(partial))

        #expect(result.verificationOk == false)
        #expect(result.actualCount == 1)
        #expect(result.mismatches.contains("track count mismatch: planned 2, actual 1"))
        #expect(result.mismatches.contains(
            "track 2 missing: planned database ID 2, persistent ID 'B'"
        ))
        #expect(result.mismatches.contains { $0.hasPrefix("write failed:") })
    }

    // test_writer_error_remains_failure_when_target_matches_complete_plan
    @Test("writer error remains a failure when the target matches the complete plan")
    func writerErrorRemainsFailureOnCompleteTarget() throws {
        let source = orchestrationSourceSnapshot()
        let complete = PlaylistSnapshot(name: "Target", persistentId: "T", tracks: source.tracks)

        let result = try apply(source: source, targetState: .present(complete))

        #expect(result.verificationOk == false)
        #expect(result.actualCount == 2)
        #expect(result.mismatches.contains { $0.hasPrefix("write failed:") })
        #expect(result.mismatches.contains { ByteText($0).contains("matches the complete plan") })
    }

    // test_writer_failure_reports_target_readback_failure_as_second_state
    @Test("writer failure reports a target readback failure as a second state")
    func writerFailureReportsReadbackFailure() throws {
        let result = try apply(
            source: orchestrationSourceSnapshot(),
            targetState: .failure("ambiguous target readback")
        )

        #expect(result.verificationOk == false)
        #expect(result.mismatches.contains { $0.hasPrefix("write failed:") })
        #expect(result.mismatches.contains {
            ByteText($0).contains("target readback failed: ambiguous target readback")
        })
    }
}
