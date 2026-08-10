// PlanModelsTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Port of tests/test_models.py cases covering the M2 model types
// (DuplicateDecision, ConsolidationPlan, MergePlan, AuditPaths, ApplyResult,
// combineSourceTracks), plus strict-decode guarantees mirroring the reference's
// `_require_*` validators in apple_music_consolidator/models.py.

import Foundation
import Testing
@testable import ConsolidatorCore

private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func decode<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(T.self, from: data)
}

@Suite("Plan model round-trips (tests/test_models.py::ModelTests)")
struct PlanModelRoundTripTests {

    @Test func nestedModelsRoundTripThroughJSON() throws {
        let winner = track(sourceIndex: 3)
        let omitted = track(sourceIndex: 7, persistentId: "DEF")
        let decision = DuplicateDecision(
            firstSourceIndex: 3,
            winner: winner,
            omitted: [omitted],
            reasonByOmittedIndex: [.init(sourceIndex: 7, reason: "lower quality")]
        )
        let plan = ConsolidationPlan(
            sourcePlaylistName: "Source",
            sourcePlaylistPersistentId: "PLAYLIST",
            sourceFingerprint: "fingerprint",
            sourceTrackCount: 2,
            sourceTracks: [winner, omitted],
            winnerSourceIndexes: [3],
            decisions: [decision],
            nonEligibleSourceIndexes: [9]
        )
        let paths = AuditPaths(planJson: "plan.json", detailCsv: "detail.csv", summaryMarkdown: "summary.md")
        let result = ApplyResult(
            sourceFingerprint: "fingerprint",
            plannedCount: 1,
            actualCount: 1,
            verificationOk: true,
            mismatches: []
        )

        #expect(try JSONDecoder().decode(DuplicateDecision.self, from: JSONEncoder().encode(decision)) == decision)
        #expect(try JSONDecoder().decode(ConsolidationPlan.self, from: JSONEncoder().encode(plan)) == plan)
        #expect(try JSONDecoder().decode(AuditPaths.self, from: JSONEncoder().encode(paths)) == paths)
        #expect(try JSONDecoder().decode(ApplyResult.self, from: JSONEncoder().encode(result)) == result)
    }

    @Test func wireFormatUsesTheExactPythonKeyNames() throws {
        let decision = DuplicateDecision(
            firstSourceIndex: 0,
            winner: track(),
            omitted: [track(sourceIndex: 1, persistentId: "DEF")],
            reasonByOmittedIndex: [.init(sourceIndex: 1, reason: "bit rate")]
        )
        let decisionKeys = Set(try jsonObject(decision).keys)
        #expect(decisionKeys == ["first_source_index", "winner", "omitted", "reason_by_omitted_index"])

        // reason_by_omitted_index serializes as [[index, reason]] pairs.
        let rawPairs = try #require(try jsonObject(decision)["reason_by_omitted_index"] as? [[Any]])
        #expect(rawPairs.count == 1)
        #expect(rawPairs[0].count == 2)
        #expect(rawPairs[0][0] as? Int == 1)
        #expect(rawPairs[0][1] as? String == "bit rate")

        let plan = ConsolidationPlan(
            sourcePlaylistName: "Source",
            sourcePlaylistPersistentId: "PLAYLIST",
            sourceFingerprint: "fingerprint",
            sourceTrackCount: 0,
            sourceTracks: [],
            winnerSourceIndexes: [],
            decisions: [],
            nonEligibleSourceIndexes: []
        )
        #expect(Set(try jsonObject(plan).keys) == [
            "source_playlist_name", "source_playlist_persistent_id",
            "source_fingerprint", "source_track_count", "source_tracks",
            "winner_source_indexes", "decisions", "non_eligible_source_indexes",
        ])

        let paths = AuditPaths(planJson: "a", detailCsv: "b", summaryMarkdown: "c")
        #expect(Set(try jsonObject(paths).keys) == ["plan_json", "detail_csv", "summary_markdown"])

        let result = ApplyResult(
            sourceFingerprint: "f", plannedCount: 1, actualCount: 1,
            verificationOk: true, mismatches: ["m"]
        )
        #expect(Set(try jsonObject(result).keys) == [
            "source_fingerprint", "planned_count", "actual_count",
            "verification_ok", "mismatches",
        ])
    }
}

@Suite("Strict decode for plan models")
struct PlanModelStrictDecodeTests {

    private func planObject() throws -> [String: Any] {
        let plan = try buildPlan(PlaylistSnapshot(
            name: "Source", persistentId: "PLAYLIST",
            tracks: [
                track(sourceIndex: 0, persistentId: "A"),
                track(sourceIndex: 1, persistentId: "B", sampleRateHz: 48000),
            ]
        ))
        return try jsonObject(plan)
    }

    @Test func consolidationPlanRejectsTheLegacySchemaWithoutSourceTracks() throws {
        var object = try planObject()
        object.removeValue(forKey: "source_tracks")

        do {
            _ = try decode(ConsolidationPlan.self, from: object)
            Issue.record("expected the legacy schema to be rejected")
        } catch let error as DecodingError {
            let message = String(describing: error)
            #expect(message.contains("legacy consolidation plan schema is unsupported"))
            #expect(message.contains("fresh audit"))
        }
    }

    @Test func consolidationPlanRejectsUnknownAndMissingFields() throws {
        var unknown = try planObject()
        unknown["surprise"] = 1
        #expect(throws: DecodingError.self) {
            _ = try decode(ConsolidationPlan.self, from: unknown)
        }

        var missing = try planObject()
        missing.removeValue(forKey: "source_fingerprint")
        #expect(throws: DecodingError.self) {
            _ = try decode(ConsolidationPlan.self, from: missing)
        }
    }

    @Test func consolidationPlanRejectsBooleanWhereIntegerIsRequired() throws {
        var booleanCount = try planObject()
        booleanCount["source_track_count"] = true
        #expect(throws: DecodingError.self) {
            _ = try decode(ConsolidationPlan.self, from: booleanCount)
        }

        var nestedBoolean = try planObject()
        var tracks = try #require(nestedBoolean["source_tracks"] as? [[String: Any]])
        tracks[0]["database_id"] = true
        nestedBoolean["source_tracks"] = tracks
        #expect(throws: DecodingError.self) {
            _ = try decode(ConsolidationPlan.self, from: nestedBoolean)
        }
    }

    @Test func duplicateDecisionRejectsMalformedReasonPairs() throws {
        let decision = DuplicateDecision(
            firstSourceIndex: 0,
            winner: track(),
            omitted: [track(sourceIndex: 1, persistentId: "DEF")],
            reasonByOmittedIndex: [.init(sourceIndex: 1, reason: "bit rate")]
        )

        var wrongLength = try jsonObject(decision)
        wrongLength["reason_by_omitted_index"] = [[1, "bit rate", "extra"]]
        #expect(throws: DecodingError.self) {
            _ = try decode(DuplicateDecision.self, from: wrongLength)
        }

        var emptyReason = try jsonObject(decision)
        emptyReason["reason_by_omitted_index"] = [[1, ""]]
        do {
            _ = try decode(DuplicateDecision.self, from: emptyReason)
            Issue.record("expected the empty reason to be rejected")
        } catch let error as DecodingError {
            #expect(String(describing: error).contains("must not be empty"))
        }

        var booleanIndex = try jsonObject(decision)
        booleanIndex["reason_by_omitted_index"] = [[true, "bit rate"]]
        #expect(throws: DecodingError.self) {
            _ = try decode(DuplicateDecision.self, from: booleanIndex)
        }

        var stringIndex = try jsonObject(decision)
        stringIndex["reason_by_omitted_index"] = [["1", "bit rate"]]
        #expect(throws: DecodingError.self) {
            _ = try decode(DuplicateDecision.self, from: stringIndex)
        }
    }

    @Test func auditPathsAndApplyResultRejectUnknownAndMissingFields() throws {
        let paths = AuditPaths(planJson: "a", detailCsv: "b", summaryMarkdown: "c")
        var unknownPaths = try jsonObject(paths)
        unknownPaths["surprise"] = 1
        #expect(throws: DecodingError.self) {
            _ = try decode(AuditPaths.self, from: unknownPaths)
        }
        var missingPaths = try jsonObject(paths)
        missingPaths.removeValue(forKey: "detail_csv")
        #expect(throws: DecodingError.self) {
            _ = try decode(AuditPaths.self, from: missingPaths)
        }

        let result = ApplyResult(
            sourceFingerprint: "f", plannedCount: 1, actualCount: 1,
            verificationOk: true, mismatches: []
        )
        var unknownResult = try jsonObject(result)
        unknownResult["surprise"] = 1
        #expect(throws: DecodingError.self) {
            _ = try decode(ApplyResult.self, from: unknownResult)
        }
        var missingResult = try jsonObject(result)
        missingResult.removeValue(forKey: "verification_ok")
        #expect(throws: DecodingError.self) {
            _ = try decode(ApplyResult.self, from: missingResult)
        }
    }
}

@Suite("MergePlan (tests/test_models.py::MergePlanTests)")
struct MergePlanPortedTests {

    private func copies() -> [PlaylistSnapshot] {
        [
            PlaylistSnapshot(
                name: "Trance 2022", persistentId: "PID-A",
                tracks: [
                    track(sourceIndex: 0, databaseId: 1, persistentId: "A0"),
                    track(sourceIndex: 1, databaseId: 2, persistentId: "A1",
                          title: "Second", sampleRateHz: 48000),
                ]
            ),
            PlaylistSnapshot(
                name: "Trance 2022", persistentId: "PID-B",
                tracks: [track(sourceIndex: 0, databaseId: 3, persistentId: "B0", title: "Third")]
            ),
        ]
    }

    @Test func combineSourceTracksReassignsASingleGlobalOrder() {
        let combined = combineSourceTracks(copies())
        #expect(combined.map(\.sourceIndex) == [0, 1, 2])
        #expect(combined.map(\.persistentId) == ["A0", "A1", "B0"])
    }

    @Test func derivedHelpersDescribeTheCombinedLayout() throws {
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies())
        #expect(plan.combinedTrackCount == 3)
        #expect(plan.copyBoundaries == [2, 3])
        #expect(plan.combinedTracks.map(\.persistentId) == ["A0", "A1", "B0"])
    }

    @Test func planRoundTripsThroughJSON() throws {
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies())
        let decoded = try JSONDecoder().decode(MergePlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded == plan)
        #expect(Set(try jsonObject(plan).keys) == [
            "merged_playlist_source_name", "copies", "merge_fingerprint",
            "winner_source_indexes", "decisions", "non_eligible_source_indexes",
        ])
    }

    @Test func decodeRejectsUnknownAndMissingFields() throws {
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies())

        var unknown = try jsonObject(plan)
        unknown["surprise"] = 1
        #expect(throws: DecodingError.self) {
            _ = try decode(MergePlan.self, from: unknown)
        }

        var missing = try jsonObject(plan)
        missing.removeValue(forKey: "merge_fingerprint")
        do {
            _ = try decode(MergePlan.self, from: missing)
            Issue.record("expected the missing field to be rejected")
        } catch let error as DecodingError {
            #expect(String(describing: error).contains("merge_fingerprint"))
        }
    }
}
