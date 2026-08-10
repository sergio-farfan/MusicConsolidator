// MutationPersistenceTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// B2 artifact-first coverage for the mutation (delete/rename) persistence
// surface in Persistence.swift: the never-overwrite plan+summary artifact
// pair, and the StrictJSONScanner-gated fail-closed loader.
//
// All artifacts are written under FileManager.temporaryDirectory only.

import Foundation
import Testing
@testable import ConsolidatorCore

// MARK: - Fixed clock (same convention as PersistenceTests.swift)

private func fixedNow() -> Date {
    ISO8601DateFormatter().date(from: "2026-07-30T12:00:00Z")!
}

private func utcTimeZone() -> TimeZone {
    TimeZone(identifier: "UTC")!
}

private let fixedStamp = "20260730-120000+0000"

// MARK: - Fixtures

private func deletePlanFixture(evidence: MutationEvidence? = nil) -> MutationPlan {
    MutationPlan(
        kind: .delete,
        playlistName: "Trance 2022",
        playlistPersistentID: "1111AAAA2222BBBB",
        trackCount: 2,
        orderedTrackPersistentIDs: ["TRACK-A", "TRACK-B"],
        newName: nil,
        listingFingerprint: String(repeating: "ab", count: 32),
        evidence: evidence,
        createdAtISO8601: "2026-08-03T12:00:00Z",
        sessionID: "11111111-2222-3333-4444-555555555555"
    )
}

private func renamePlanFixture() -> MutationPlan {
    MutationPlan(
        kind: .rename,
        playlistName: "Trance 2022",
        playlistPersistentID: "3333CCCC4444DDDD",
        trackCount: 3,
        orderedTrackPersistentIDs: ["TRACK-A", "TRACK-B", "TRACK-C"],
        newName: "Trance 2022 (vinyl rips)",
        listingFingerprint: String(repeating: "cd", count: 32),
        evidence: nil,
        createdAtISO8601: "2026-08-03T12:05:00Z",
        sessionID: "11111111-2222-3333-4444-555555555555"
    )
}

private func writeMutationText(
    _ text: String,
    in dir: URL,
    name: String = "candidate.delete.plan.json"
) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// Parse a plan's canonical JSON into a mutable dictionary for tamper tests
/// (same pattern as PersistenceTests.swift's jsonObject helper).
private func mutationJSONObject(_ plan: MutationPlan) throws -> [String: Any] {
    try #require(
        try JSONSerialization.jsonObject(with: plan.canonicalJSONData()) as? [String: Any]
    )
}

// MARK: - Scalar-exact plan comparison (String == is canonical-equivalent and
// would mask NFC/NFD drift; every string field goes through scalarEqual).

private func scalarEqualStringArrays(_ lhs: [String], _ rhs: [String]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { scalarEqual($0, $1) }
}

private func scalarEqualOptionalStrings(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case (let left?, let right?): return scalarEqual(left, right)
    default: return false
    }
}

private func scalarEqualEvidence(_ lhs: MutationEvidence?, _ rhs: MutationEvidence?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case (let left?, let right?):
        return scalarEqual(left.mergePlanFileName, right.mergePlanFileName)
            && scalarEqualOptionalStrings(left.runReportFileName, right.runReportFileName)
            && scalarEqual(left.verificationNote, right.verificationNote)
    default:
        return false
    }
}

private func scalarEqualMutationPlans(_ lhs: MutationPlan, _ rhs: MutationPlan) -> Bool {
    lhs.kind == rhs.kind
        && scalarEqual(lhs.playlistName, rhs.playlistName)
        && scalarEqual(lhs.playlistPersistentID, rhs.playlistPersistentID)
        && lhs.trackCount == rhs.trackCount
        && scalarEqualStringArrays(lhs.orderedTrackPersistentIDs, rhs.orderedTrackPersistentIDs)
        && scalarEqualOptionalStrings(lhs.newName, rhs.newName)
        && scalarEqual(lhs.listingFingerprint, rhs.listingFingerprint)
        && scalarEqualEvidence(lhs.evidence, rhs.evidence)
        && scalarEqual(lhs.createdAtISO8601, rhs.createdAtISO8601)
        && scalarEqual(lhs.sessionID, rhs.sessionID)
}

// MARK: - writeMutationAudit + loadMutationPlan

@Suite("writeMutationAudit + loadMutationPlan (B2 artifact-first)")
struct MutationPersistenceTests {

    @Test func deleteAuditWritesAPlanAndSummaryPairWithDeleteSuffixes() throws {
        let plan = deletePlanFixture()
        try withTemporaryDirectory { dir in
            let paths = try writeMutationAudit(
                outputDir: dir,
                plan: plan,
                summaryText: "# Delete Trance 2022\n",
                now: fixedNow,
                timeZone: utcTimeZone()
            )
            #expect(paths.planURL.lastPathComponent == "Trance-2022-\(fixedStamp).delete.plan.json")
            #expect(paths.summaryURL.lastPathComponent == "Trance-2022-\(fixedStamp).summary.md")
            #expect(try String(contentsOf: paths.summaryURL, encoding: .utf8) == "# Delete Trance 2022\n")
            let planText = try String(contentsOf: paths.planURL, encoding: .utf8)
            #expect(planText.hasSuffix("\n"))
            // The reservation is removed on success (same contract as writeAudit).
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(!leftovers.contains { $0.hasSuffix(".reservation") }, "leftover reservation: \(leftovers)")
        }
    }

    @Test func renameAuditUsesTheRenamePlanSuffix() throws {
        let plan = renamePlanFixture()
        try withTemporaryDirectory { dir in
            let paths = try writeMutationAudit(
                outputDir: dir,
                plan: plan,
                summaryText: "# Rename Trance 2022\n",
                now: fixedNow,
                timeZone: utcTimeZone()
            )
            #expect(paths.planURL.lastPathComponent == "Trance-2022-\(fixedStamp).rename.plan.json")
            #expect(paths.summaryURL.lastPathComponent == "Trance-2022-\(fixedStamp).summary.md")
        }
    }

    @Test func secondWriteWithTheSameSlugAndStampCreatesNewNames() throws {
        let plan = deletePlanFixture()
        try withTemporaryDirectory { dir in
            let first = try writeMutationAudit(
                outputDir: dir, plan: plan, summaryText: "first\n",
                now: fixedNow, timeZone: utcTimeZone()
            )
            let firstPlanText = try String(contentsOf: first.planURL, encoding: .utf8)
            let second = try writeMutationAudit(
                outputDir: dir, plan: plan, summaryText: "second\n",
                now: fixedNow, timeZone: utcTimeZone()
            )

            #expect(first.planURL != second.planURL)
            #expect(second.planURL.lastPathComponent == "Trance-2022-\(fixedStamp)-1.delete.plan.json")
            #expect(second.summaryURL.lastPathComponent == "Trance-2022-\(fixedStamp)-1.summary.md")
            #expect(try String(contentsOf: first.planURL, encoding: .utf8) == firstPlanText)
            #expect(try String(contentsOf: first.summaryURL, encoding: .utf8) == "first\n")
            #expect(try String(contentsOf: second.summaryURL, encoding: .utf8) == "second\n")
        }
    }

    @Test func mutationPairNeverCollidesWithAnExistingSummaryArtifact() throws {
        // The mutation pair shares the ".summary.md" suffix with the audit
        // triple: a pre-existing summary at the candidate prefix must push the
        // pair to the next suffixed name and itself stay untouched.
        let plan = deletePlanFixture()
        try withTemporaryDirectory { dir in
            let sentinel = dir.appendingPathComponent("Trance-2022-\(fixedStamp).summary.md")
            try "sentinel".write(to: sentinel, atomically: true, encoding: .utf8)

            let paths = try writeMutationAudit(
                outputDir: dir, plan: plan, summaryText: "pair\n",
                now: fixedNow, timeZone: utcTimeZone()
            )

            #expect(paths.planURL.lastPathComponent == "Trance-2022-\(fixedStamp)-1.delete.plan.json")
            #expect(try String(contentsOf: sentinel, encoding: .utf8) == "sentinel")
        }
    }

    @Test func writtenPlansRoundTripToEqualValues() throws {
        let evidence = MutationEvidence(
            mergePlanFileName: "Trance-2022-20260701-000000+0000.plan.json",
            runReportFileName: "run-report-20260701-000100+0000.json",
            verificationNote: "target verified against plan: 2 copies, 3 tracks"
        )
        let decomposedNamePlan = MutationPlan(
            kind: .delete,
            playlistName: "Cafe\u{301} Mix", // NFD on purpose: String == alone would also match NFC
            playlistPersistentID: "5555EEEE6666FFFF",
            trackCount: 1,
            orderedTrackPersistentIDs: ["TRACK-Z"],
            newName: nil,
            listingFingerprint: String(repeating: "0f", count: 32),
            evidence: nil,
            createdAtISO8601: "2026-08-03T12:10:00Z",
            sessionID: "11111111-2222-3333-4444-555555555555"
        )
        for plan in [deletePlanFixture(evidence: evidence), renamePlanFixture(), decomposedNamePlan] {
            try withTemporaryDirectory { dir in
                let paths = try writeMutationAudit(
                    outputDir: dir, plan: plan, summaryText: "s\n",
                    now: fixedNow, timeZone: utcTimeZone()
                )
                let loaded = try loadMutationPlan(url: paths.planURL)
                #expect(loaded == plan)
                #expect(
                    scalarEqualMutationPlans(loaded, plan),
                    "scalar divergence for \(codePointRendering(plan.playlistName))"
                )
            }
        }
    }

    @Test func loaderRejectsAUTF8ByteOrderMark() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("candidate.delete.plan.json")
            try (Data([0xEF, 0xBB, 0xBF]) + deletePlanFixture().canonicalJSONData()).write(to: url)
            expectMutationPlanLoadRejection(url, .malformedJSON, messageContains: ["BOM"])
        }
    }

    @Test func loaderRejectsDuplicateObjectKeys() throws {
        // The StrictJSONScanner gate runs BEFORE decoding, so minimal
        // documents exercise it without depending on the plan schema.
        try withTemporaryDirectory { dir in
            let url = try writeMutationText("{\"a\": 1, \"a\": 2}", in: dir)
            expectMutationPlanLoadRejection(url, .malformedJSON, messageContains: ["duplicate object key"])
        }
    }

    @Test func loaderRejectsTrailingCommas() throws {
        try withTemporaryDirectory { dir in
            let inObject = try writeMutationText("{\"a\": 1,}", in: dir)
            expectMutationPlanLoadRejection(
                inObject, .malformedJSON, messageContains: ["trailing comma", "object"]
            )
            let inArray = try writeMutationText("{\"a\": [1,]}", in: dir, name: "array.delete.plan.json")
            expectMutationPlanLoadRejection(
                inArray, .malformedJSON, messageContains: ["trailing comma", "array"]
            )
        }
    }

    @Test func loaderRejectsFloatTypedNumberTokens() throws {
        // The integral-float raw-token walk runs before decoding too.
        try withTemporaryDirectory { dir in
            let url = try writeMutationText("{\"a\": 1.5}", in: dir)
            expectMutationPlanLoadRejection(url, .decodeRejected, messageContains: ["must be an integer"])
        }
    }

    @Test func loaderRejectsUnknownAndMissingKeys() throws {
        try withTemporaryDirectory { dir in
            var unknown = try mutationJSONObject(deletePlanFixture())
            unknown["surprise"] = 1
            let unknownURL = dir.appendingPathComponent("unknown.delete.plan.json")
            try JSONSerialization.data(withJSONObject: unknown).write(to: unknownURL)
            expectMutationPlanLoadRejection(unknownURL, .decodeRejected, messageContains: ["surprise"])

            var missing = try mutationJSONObject(deletePlanFixture())
            let removedKey = try #require(missing.keys.sorted().first)
            missing.removeValue(forKey: removedKey)
            let missingURL = dir.appendingPathComponent("missing.delete.plan.json")
            try JSONSerialization.data(withJSONObject: missing).write(to: missingURL)
            expectMutationPlanLoadRejection(
                missingURL, .decodeRejected, messageContains: ["missing", removedKey]
            )
        }
    }
}

// MARK: - Consumed sidecars + mutation result reports (B2 single-use)

@Suite("markMutationPlanConsumed + writeMutationResult (B2 single-use)")
struct MutationConsumedResultTests {

    @Test func consumedMarkerIsCreatedAndDetected() throws {
        let plan = deletePlanFixture()
        try withTemporaryDirectory { dir in
            let paths = try writeMutationAudit(
                outputDir: dir, plan: plan, summaryText: "s\n",
                now: fixedNow, timeZone: utcTimeZone()
            )
            #expect(!isMutationPlanConsumed(planURL: paths.planURL))
            try markMutationPlanConsumed(planURL: paths.planURL)
            #expect(isMutationPlanConsumed(planURL: paths.planURL))

            // Sidecar name is "<plan-file-name>.consumed", beside the artifact.
            let sidecarPath = paths.planURL.path + ".consumed"
            let sidecarText = try String(contentsOfFile: sidecarPath, encoding: .utf8)
            #expect(sidecarText == plan.sha256Hex() + "\n")
        }
    }

    @Test func markingNeverModifiesTheArtifactBytes() throws {
        let plan = renamePlanFixture()
        try withTemporaryDirectory { dir in
            let paths = try writeMutationAudit(
                outputDir: dir, plan: plan, summaryText: "s\n",
                now: fixedNow, timeZone: utcTimeZone()
            )
            let planBytesBefore = try Data(contentsOf: paths.planURL)
            let summaryBytesBefore = try Data(contentsOf: paths.summaryURL)

            try markMutationPlanConsumed(planURL: paths.planURL)
            // Re-marking is a no-op: no throw, marker bytes unchanged.
            try markMutationPlanConsumed(planURL: paths.planURL)

            #expect(try Data(contentsOf: paths.planURL) == planBytesBefore)
            #expect(try Data(contentsOf: paths.summaryURL) == summaryBytesBefore)
            let sidecarPath = paths.planURL.path + ".consumed"
            #expect(try String(contentsOfFile: sidecarPath, encoding: .utf8) == plan.sha256Hex() + "\n")
        }
    }

    @Test func absentPlanIsNotConsumedAndCannotBeMarked() throws {
        try withTemporaryDirectory { dir in
            let ghost = dir.appendingPathComponent("ghost.delete.plan.json")
            #expect(!isMutationPlanConsumed(planURL: ghost))
            #expect(throws: PlanLoadError.self) {
                try markMutationPlanConsumed(planURL: ghost)
            }
            #expect(!isMutationPlanConsumed(planURL: ghost))
        }
    }

    @Test func resultReportsNeverOverwrite() throws {
        try withTemporaryDirectory { dir in
            let base = "Trance-2022-\(fixedStamp)"
            let first = try writeMutationResult(outputDir: dir, baseName: base, text: "outcome: verified\n")
            let second = try writeMutationResult(outputDir: dir, baseName: base, text: "outcome: refused\n")

            #expect(first.lastPathComponent == "\(base).mutationresult.md")
            #expect(second.lastPathComponent == "\(base)-1.mutationresult.md")
            #expect(try String(contentsOf: first, encoding: .utf8) == "outcome: verified\n")
            #expect(try String(contentsOf: second, encoding: .utf8) == "outcome: refused\n")
        }
    }

    @Test func resultReportContentsRoundTripExactly() throws {
        // Verbatim readback text passes through unmodified, including the em
        // dash and multi-line proof blocks that mismatch reports carry.
        let text = "# Mutation result \u{2014} Trance 2022\n\n"
            + "- outcome: verified\n"
            + "- consumed plan: Trance-2022-\(fixedStamp).delete.plan.json\n"
            + "- plan sha256: \(deletePlanFixture().sha256Hex())\n"
            + "- readback: PID absent from fresh listing; bijection holds\n"
        try withTemporaryDirectory { dir in
            let url = try writeMutationResult(
                outputDir: dir, baseName: "Trance-2022-\(fixedStamp)", text: text
            )
            #expect(try String(contentsOf: url, encoding: .utf8) == text)
        }
    }
}
