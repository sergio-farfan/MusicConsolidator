// PlanIntegrityTests.swift
// Port of the validate_plan_integrity / validate_merge_plan_integrity cases
// from tests/test_audit.py (writer/loader cases are M3 and NOT ported here).
// Python's load_plan = from_dict + validate; the M2 equivalent is strict
// Codable decode + validatePlanIntegrity. Payloads are built from the SWIFT
// buildPlan (fingerprints are Swift-canonical; Python fingerprint bytes would
// never match by design) and then tampered, exactly like the reference tests
// tamper the Python-built payloads.

import Foundation
import Testing
@testable import ConsolidatorCore

private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Decode + validate, mirroring the reference's `load_plan` (minus file IO).
private func decodeAndValidate(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    let plan = try JSONDecoder().decode(ConsolidationPlan.self, from: data)
    try validatePlanIntegrity(plan)
}

/// Assert the payload is rejected with a `PlanIntegrityError` whose message
/// contains `messagePart` (the reference's ValueError text, ported verbatim).
private func expectIntegrityRejection(
    _ object: [String: Any],
    messageContains messagePart: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    do {
        try decodeAndValidate(object)
        Issue.record("expected rejection (\(messagePart))", sourceLocation: sourceLocation)
    } catch let error as PlanIntegrityError {
        #expect(
            error.message.contains(messagePart),
            "unexpected message: \(error.message)",
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record(
            "expected PlanIntegrityError, got \(error)",
            sourceLocation: sourceLocation
        )
    }
}

@Suite("validatePlanIntegrity (tests/test_audit.py::PlanIntegrityTests)")
struct PlanIntegrityPortedTests {

    /// tests/test_audit.py::_current_schema_payload — OMIT/WIN duplicates plus
    /// UNIQUE, serialized so individual fields can be tampered.
    private func currentSchemaObject() throws -> [String: Any] {
        let source = PlaylistSnapshot(
            name: "Source", persistentId: "PLAYLIST",
            tracks: [
                track(sourceIndex: 0, databaseId: 100, persistentId: "OMIT", sampleRateHz: 44100),
                track(sourceIndex: 1, databaseId: 101, persistentId: "WIN", sampleRateHz: 48000),
                track(sourceIndex: 2, databaseId: 102, persistentId: "UNIQUE", title: "Unique"),
            ]
        )
        return try jsonObject(try buildPlan(source))
    }

    @Test func canonicalPlanRoundTripsThroughDecodeAndValidate() throws {
        try decodeAndValidate(try currentSchemaObject())
    }

    @Test func rejectsInvalidWinnersAndPartitions() throws {
        var empty = try currentSchemaObject()
        empty["winner_source_indexes"] = [Int]()
        expectIntegrityRejection(empty, messageContains: "winner partition is empty for a non-empty source")

        var repeated = try currentSchemaObject()
        repeated["winner_source_indexes"] = [1, 1, 2]
        expectIntegrityRejection(repeated, messageContains: "winner_source_indexes contains a duplicate winner")

        var outOfRange = try currentSchemaObject()
        outOfRange["winner_source_indexes"] = [1, 2, 99]
        expectIntegrityRejection(outOfRange, messageContains: "winner source index 99 is out of range")

        var inconsistent = try currentSchemaObject()
        inconsistent["winner_source_indexes"] = [0, 1, 2]
        expectIntegrityRejection(inconsistent, messageContains: "winner/omitted partition overlaps at source index 0")

        // Retained but canonically-eligible track marked non-eligible: only the
        // canonical recompute catches it (same in the reference).
        var nonEligible = try currentSchemaObject()
        nonEligible["non_eligible_source_indexes"] = [2]
        expectIntegrityRejection(nonEligible, messageContains: "not the canonical result")
    }

    @Test func rejectsMalformedDecisionsAndReasonMappings() throws {
        var malformed = try currentSchemaObject()
        var decisions = try #require(malformed["decisions"] as? [[String: Any]])
        decisions[0]["reason_by_omitted_index"] = [[0, "available"], [0, "bit rate"]]
        malformed["decisions"] = decisions
        expectIntegrityRejection(
            malformed,
            messageContains: "reason mapping must exactly match omitted source indexes"
        )
    }

    @Test func rejectsUnknownDecisionReasons() throws {
        var unknownReason = try currentSchemaObject()
        var decisions = try #require(unknownReason["decisions"] as? [[String: Any]])
        decisions[0]["reason_by_omitted_index"] = [[0, "vibes"]]
        unknownReason["decisions"] = decisions
        expectIntegrityRejection(unknownReason, messageContains: "has unknown reason")
    }

    @Test func rejectsSnapshotFingerprintOrOrderTampering() throws {
        var badFingerprint = try currentSchemaObject()
        badFingerprint["source_fingerprint"] = String(repeating: "0", count: 64)
        expectIntegrityRejection(
            badFingerprint,
            messageContains: "source fingerprint does not match the persisted source snapshot"
        )

        var wrongOrder = try currentSchemaObject()
        var tracks = try #require(wrongOrder["source_tracks"] as? [[String: Any]])
        tracks.swapAt(0, 1)
        wrongOrder["source_tracks"] = tracks
        expectIntegrityRejection(
            wrongOrder,
            messageContains: "persisted source track order is malformed"
        )
    }

    @Test func rejectsTrackCountMismatch() throws {
        var mismatch = try currentSchemaObject()
        mismatch["source_track_count"] = 4
        expectIntegrityRejection(
            mismatch,
            messageContains: "source_track_count does not match the persisted source snapshot"
        )
    }
}

@Suite("validateMergePlanIntegrity (tests/test_audit.py::MergeAuditTests)")
struct MergePlanIntegrityPortedTests {

    /// tests/test_audit.py::MergeAuditTests._copies
    private func copies() -> [PlaylistSnapshot] {
        [
            PlaylistSnapshot(
                name: "Trance 2022", persistentId: "PID-A",
                tracks: [
                    track(sourceIndex: 0, databaseId: 1, persistentId: "LOSSY",
                          title: "One", durationMs: 180000, sampleRateHz: 44100),
                    track(sourceIndex: 1, databaseId: 2, persistentId: "UNIQUE-A",
                          title: "Two", durationMs: 200000),
                ]
            ),
            PlaylistSnapshot(
                name: "Trance 2022", persistentId: "PID-B",
                tracks: [
                    track(sourceIndex: 0, databaseId: 3, persistentId: "LOSSLESS",
                          title: "One", durationMs: 180000, kind: "AIFF audio file",
                          sampleRateHz: 96000),
                ]
            ),
        ]
    }

    private func expectMergeRejection(
        _ plan: MergePlan,
        messageContains messagePart: String,
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) {
        do {
            try validateMergePlanIntegrity(plan)
            Issue.record("expected rejection (\(messagePart))", sourceLocation: sourceLocation)
        } catch let error as PlanIntegrityError {
            #expect(
                error.message.contains(messagePart),
                "unexpected message: \(error.message)",
                sourceLocation: sourceLocation
            )
        } catch {
            Issue.record("expected PlanIntegrityError, got \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func canonicalMergePlanValidates() throws {
        try validateMergePlanIntegrity(try buildMergePlan(name: "Trance 2022", copies: copies()))
    }

    @Test func rejectsATamperedFingerprint() throws {
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies())
        let tampered = MergePlan(
            mergedPlaylistSourceName: plan.mergedPlaylistSourceName,
            copies: plan.copies,
            mergeFingerprint: String(repeating: "0", count: 64),
            winnerSourceIndexes: plan.winnerSourceIndexes,
            decisions: plan.decisions,
            nonEligibleSourceIndexes: plan.nonEligibleSourceIndexes
        )
        expectMergeRejection(tampered, messageContains: "merge fingerprint does not match the persisted copies")
    }

    @Test func rejectsNoncanonicalWinners() throws {
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies())
        let tampered = MergePlan(
            mergedPlaylistSourceName: plan.mergedPlaylistSourceName,
            copies: plan.copies,
            mergeFingerprint: plan.mergeFingerprint,
            winnerSourceIndexes: [0, 1, 2], // keeps the omitted duplicate
            decisions: plan.decisions,
            nonEligibleSourceIndexes: plan.nonEligibleSourceIndexes
        )
        expectMergeRejection(tampered, messageContains: "not the canonical result for the persisted copies")
    }

    @Test func rejectsStructurallyInvalidCopySets() throws {
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies())

        let noCopies = MergePlan(
            mergedPlaylistSourceName: plan.mergedPlaylistSourceName,
            copies: [],
            mergeFingerprint: plan.mergeFingerprint,
            winnerSourceIndexes: plan.winnerSourceIndexes,
            decisions: plan.decisions,
            nonEligibleSourceIndexes: plan.nonEligibleSourceIndexes
        )
        expectMergeRejection(noCopies, messageContains: "must contain at least one source copy")

        var duplicated = copies()
        duplicated[1].persistentId = "PID-A"
        let duplicateIds = MergePlan(
            mergedPlaylistSourceName: plan.mergedPlaylistSourceName,
            copies: duplicated,
            mergeFingerprint: plan.mergeFingerprint,
            winnerSourceIndexes: plan.winnerSourceIndexes,
            decisions: plan.decisions,
            nonEligibleSourceIndexes: plan.nonEligibleSourceIndexes
        )
        expectMergeRejection(duplicateIds, messageContains: "distinct persistent IDs")

        var renamed = copies()
        renamed[1].name = "Trance 2023"
        let nameMismatch = MergePlan(
            mergedPlaylistSourceName: plan.mergedPlaylistSourceName,
            copies: renamed,
            mergeFingerprint: plan.mergeFingerprint,
            winnerSourceIndexes: plan.winnerSourceIndexes,
            decisions: plan.decisions,
            nonEligibleSourceIndexes: plan.nonEligibleSourceIndexes
        )
        expectMergeRejection(nameMismatch, messageContains: "copy name does not match the merged source name")
    }
}
