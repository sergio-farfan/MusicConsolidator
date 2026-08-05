// PlanGoldenTests.swift
// Golden-fixture parity for the resolver: assert Swift buildPlan /
// buildMergePlan match the Python reference implementation exactly, using fixtures exported by
// macos-app/golden/generate_plan_golden.py. Fingerprint bytes are deliberately
// NOT compared (Swift owns its own canonical encoding); everything else —
// winner indexes, full decisions, non-eligible indexes, and full output track
// ordering — is compared with scalar-level string equality.

import Foundation
import Testing
@testable import ConsolidatorCore

private func goldenFileURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("golden")
        .appendingPathComponent(name)
}

private struct PlanGolden: Decodable {
    let buildPlanCases: [BuildPlanCase]
    let buildMergePlanCases: [BuildMergePlanCase]

    enum CodingKeys: String, CodingKey {
        case buildPlanCases = "build_plan_cases"
        case buildMergePlanCases = "build_merge_plan_cases"
    }
}

private struct BuildPlanCase: Decodable {
    let name: String
    let source: PlaylistSnapshot
    let expected: ExpectedPlan
}

private struct ExpectedPlan: Decodable {
    let sourcePlaylistName: String
    let sourcePlaylistPersistentId: String
    let sourceTrackCount: Int
    let winnerSourceIndexes: [Int]
    let decisions: [DuplicateDecision]
    let nonEligibleSourceIndexes: [Int]
    let outputTracks: [TrackSnapshot]?

    enum CodingKeys: String, CodingKey {
        case sourcePlaylistName = "source_playlist_name"
        case sourcePlaylistPersistentId = "source_playlist_persistent_id"
        case sourceTrackCount = "source_track_count"
        case winnerSourceIndexes = "winner_source_indexes"
        case decisions
        case nonEligibleSourceIndexes = "non_eligible_source_indexes"
        case outputTracks = "output_tracks"
    }
}

private struct BuildMergePlanCase: Decodable {
    let name: String
    let mergedName: String
    let copies: [PlaylistSnapshot]
    let expected: ExpectedMergePlan

    enum CodingKeys: String, CodingKey {
        case name
        case mergedName = "merged_name"
        case copies
        case expected
    }
}

private struct ExpectedMergePlan: Decodable {
    let mergedPlaylistSourceName: String
    let winnerSourceIndexes: [Int]
    let decisions: [DuplicateDecision]
    let nonEligibleSourceIndexes: [Int]
    let combinedTrackCount: Int
    let copyBoundaries: [Int]
    let combinedTracks: [TrackSnapshot]
    let outputTracks: [TrackSnapshot]

    enum CodingKeys: String, CodingKey {
        case mergedPlaylistSourceName = "merged_playlist_source_name"
        case winnerSourceIndexes = "winner_source_indexes"
        case decisions
        case nonEligibleSourceIndexes = "non_eligible_source_indexes"
        case combinedTrackCount = "combined_track_count"
        case copyBoundaries = "copy_boundaries"
        case combinedTracks = "combined_tracks"
        case outputTracks = "output_tracks"
    }
}

private func loadGolden() throws -> PlanGolden {
    let data = try Data(contentsOf: goldenFileURL("plan_golden.json"))
    return try JSONDecoder().decode(PlanGolden.self, from: data)
}

/// Stable JSON rendering for mismatch diagnostics.
private func renderJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return "<unencodable>" }
    return String(data: data, encoding: .utf8) ?? "<unencodable>"
}

private func codePoints(_ value: String) -> String {
    value.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
}

/// Scalar-level track-list comparison with a code-point diagnostic on mismatch.
private func expectTracksMatch(
    _ actual: [TrackSnapshot],
    _ expected: [TrackSnapshot],
    context: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    guard !scalarEqual(actual, expected) else { return }
    Issue.record(
        """
        \(context) diverged from the Python reference implementation
          actual:   \(renderJSON(actual))
          expected: \(renderJSON(expected))
          actual titles:   \(actual.map { codePoints($0.title) })
          expected titles: \(expected.map { codePoints($0.title) })
        """,
        sourceLocation: sourceLocation
    )
}

@Suite("Plan golden fixture parity (build_plan)")
struct BuildPlanGoldenTests {

    @Test("buildPlan matches the Python reference implementation for every golden case")
    func buildPlanMatchesGolden() throws {
        let cases = try loadGolden().buildPlanCases
        #expect(!cases.isEmpty)
        for goldenCase in cases {
            let plan = try buildPlan(goldenCase.source)
            let expected = goldenCase.expected

            #expect(
                scalarEqual(plan.sourcePlaylistName, expected.sourcePlaylistName),
                "\(goldenCase.name): source_playlist_name"
            )
            #expect(
                scalarEqual(plan.sourcePlaylistPersistentId, expected.sourcePlaylistPersistentId),
                "\(goldenCase.name): source_playlist_persistent_id"
            )
            #expect(plan.sourceTrackCount == expected.sourceTrackCount, "\(goldenCase.name): source_track_count")
            #expect(
                plan.winnerSourceIndexes == expected.winnerSourceIndexes,
                "\(goldenCase.name): winner_source_indexes \(plan.winnerSourceIndexes) vs \(expected.winnerSourceIndexes)"
            )
            #expect(
                scalarEqual(plan.decisions, expected.decisions),
                """
                \(goldenCase.name): decisions diverged
                  actual:   \(renderJSON(plan.decisions))
                  expected: \(renderJSON(expected.decisions))
                """
            )
            #expect(
                plan.nonEligibleSourceIndexes == expected.nonEligibleSourceIndexes,
                "\(goldenCase.name): non_eligible_source_indexes"
            )
            // The persisted snapshot must be the source, unchanged and in order.
            expectTracksMatch(plan.sourceTracks, goldenCase.source.tracks, context: "\(goldenCase.name): source_tracks")

            // Full output track ordering (winner track per output position).
            if let expectedOutput = expected.outputTracks {
                let byIndex = Dictionary(
                    uniqueKeysWithValues: goldenCase.source.tracks.map { ($0.sourceIndex, $0) }
                )
                let actualOutput = plan.winnerSourceIndexes.compactMap { byIndex[$0] }
                #expect(actualOutput.count == plan.winnerSourceIndexes.count, "\(goldenCase.name): output lookup")
                expectTracksMatch(actualOutput, expectedOutput, context: "\(goldenCase.name): output ordering")
            }

            // Every plan built from a WELL-FORMED snapshot (source index ==
            // position) must pass its own integrity gate. Synthetic cases with
            // non-positional indexes are rejected by the reference's validator
            // too (audit.py:216-221), so they are exercised above only.
            let positional = goldenCase.source.tracks.enumerated()
                .allSatisfy { $0.element.sourceIndex == $0.offset }
            if positional {
                try validatePlanIntegrity(plan)
            }
        }
    }
}

@Suite("Plan golden fixture parity (build_merge_plan)")
struct BuildMergePlanGoldenTests {

    @Test("buildMergePlan matches the Python reference implementation for every golden case")
    func buildMergePlanMatchesGolden() throws {
        let cases = try loadGolden().buildMergePlanCases
        #expect(!cases.isEmpty)
        for goldenCase in cases {
            let plan = try buildMergePlan(name: goldenCase.mergedName, copies: goldenCase.copies)
            let expected = goldenCase.expected

            #expect(
                scalarEqual(plan.mergedPlaylistSourceName, expected.mergedPlaylistSourceName),
                "\(goldenCase.name): merged_playlist_source_name"
            )
            #expect(
                plan.winnerSourceIndexes == expected.winnerSourceIndexes,
                "\(goldenCase.name): winner_source_indexes \(plan.winnerSourceIndexes) vs \(expected.winnerSourceIndexes)"
            )
            #expect(
                scalarEqual(plan.decisions, expected.decisions),
                """
                \(goldenCase.name): decisions diverged
                  actual:   \(renderJSON(plan.decisions))
                  expected: \(renderJSON(expected.decisions))
                """
            )
            #expect(
                plan.nonEligibleSourceIndexes == expected.nonEligibleSourceIndexes,
                "\(goldenCase.name): non_eligible_source_indexes"
            )
            #expect(plan.combinedTrackCount == expected.combinedTrackCount, "\(goldenCase.name): combined_track_count")
            #expect(plan.copyBoundaries == expected.copyBoundaries, "\(goldenCase.name): copy_boundaries")

            let combined = plan.combinedTracks
            expectTracksMatch(combined, expected.combinedTracks, context: "\(goldenCase.name): combined_tracks")

            let actualOutput = plan.winnerSourceIndexes.map { combined[$0] }
            expectTracksMatch(actualOutput, expected.outputTracks, context: "\(goldenCase.name): output ordering")

            try validateMergePlanIntegrity(plan)
        }
    }
}
