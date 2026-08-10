// PersistenceTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Port of the WRITER and LOADER cases from tests/test_audit.py (the
// validate-only cases were ported in M2's PlanIntegrityTests and are not
// duplicated), plus the M3 binding items:
//   1. integral-JSON-float rejection at the load surface (183000.0 must be
//      rejected wherever the reference's `type(value) is int` rejects it),
//   2. direct reject-path coverage for every validate_plan_integrity branch,
//      exercised through loadPlan,
//   3. a pinning test for the deliberate output-directory path normalization.
// Slugify pins beyond the reference test were verified against the reference
// empirically (python3 apple_music_consolidator.audit.slugify) on 2026-07-31.
//
// All artifacts are written under FileManager.temporaryDirectory only.

import Foundation
import Testing
@testable import ConsolidatorCore

// MARK: - Fixed clock (mirrors tests/test_audit.py patching audit.datetime)

private func fixedNow() -> Date {
    // datetime(2026, 7, 30, 12, 0, tzinfo=timezone.utc), as in the reference test.
    ISO8601DateFormatter().date(from: "2026-07-30T12:00:00Z")!
}

private func utcTimeZone() -> TimeZone {
    TimeZone(identifier: "UTC")!
}

private let fixedStamp = "20260730-120000+0000"

// MARK: - Shared fixtures

/// tests/test_audit.py::_current_schema_payload source (OMIT/WIN/UNIQUE).
private func currentSchemaPlan() throws -> ConsolidationPlan {
    try buildPlan(
        PlaylistSnapshot(
            name: "Source", persistentId: "PLAYLIST",
            tracks: [
                track(sourceIndex: 0, databaseId: 100, persistentId: "OMIT", sampleRateHz: 44100),
                track(sourceIndex: 1, databaseId: 101, persistentId: "WIN", sampleRateHz: 48000),
                track(sourceIndex: 2, databaseId: 102, persistentId: "UNIQUE", title: "Unique"),
            ]
        )
    )
}

/// tests/test_audit.py::MergeAuditTests._copies
private func tranceCopies() -> [PlaylistSnapshot] {
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

private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func writeJSONObject(_ object: [String: Any], in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent("candidate.plan.json")
    try JSONSerialization.data(withJSONObject: object).write(to: url)
    return url
}

private func writeText(_ text: String, in dir: URL, name: String = "candidate.plan.json") throws -> URL {
    let url = dir.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// Compact canonical JSON used for raw-token float mutations: with
/// `.sortedKeys` only, JSONEncoder emits `"key":value` with no whitespace,
/// so `"duration_ms":183000` can be rewritten to `"duration_ms":183000.0`
/// deterministically. The helper fails the test if nothing was replaced.
private func mutatedCompactJSON<T: Encodable>(
    _ value: T,
    replacing target: String,
    with replacement: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let text = String(decoding: try encoder.encode(value), as: UTF8.self)
    #expect(text.contains(target), "mutation target \(target) not found", sourceLocation: sourceLocation)
    return text.replacingOccurrences(of: target, with: replacement)
}

// MARK: - slugify

@Suite("slugify (tests/test_audit.py::AuditTests + reference-verified pins)")
struct SlugifyTests {

    @Test func replacesPathSeparatorsWithSafeStemCharacters() {
        // tests/test_audit.py::test_slugify_replaces_path_separators...
        #expect(slugify("Road/Trip\\2026") == "Road-Trip-2026")
    }

    @Test func matchesReferenceOnEdgeCases() {
        // Every pair below was produced by the Python reference implementation (2026-07-31).
        let pins: [(String, String)] = [
            ("#Musica xTotal", "Musica-xTotal"),
            ("", "playlist"),
            ("...", "playlist"),
            ("Björk\u{2019}s Mix", "Björk-s-Mix"),
            ("e\u{0301}x", "e-x"),          // combining acute is not a word char
            ("a\u{00B2}b", "a\u{00B2}b"),   // superscript two IS a word char
            ("x\u{2460}y", "x\u{2460}y"),   // circled digit one IS a word char
            ("_a_", "_a_"),
            ("Mix.2022", "Mix.2022"),
            ("  pad  ", "pad"),
            ("a--b", "a--b"),
            (".-hidden-.", "hidden"),
        ]
        for (input, expected) in pins {
            let actual = slugify(input)
            #expect(
                scalarEqual(actual, expected),
                "slugify(\(input)) -> \(actual) [\(codePointRendering(actual))], expected \(expected)"
            )
        }
    }
}

// MARK: - write_audit

@Suite("writeAudit (tests/test_audit.py::AuditTests + ProvenanceTests)")
struct WriteAuditTests {

    private func roadTripPlan() throws -> ConsolidationPlan {
        try buildPlan(
            PlaylistSnapshot(
                name: "Road Trip", persistentId: "PID",
                tracks: [
                    track(sourceIndex: 0, persistentId: "A"),
                    track(sourceIndex: 1, persistentId: "B", sampleRateHz: 48000),
                ]
            )
        )
    }

    @Test func writesReloadableJSONCSVAndMarkdown() throws {
        // test_audit_writes_reloadable_json_csv_and_markdown
        let plan = try buildPlan(
            PlaylistSnapshot(
                name: "#Musica xTotal", persistentId: "PID",
                tracks: [
                    track(sourceIndex: 0, persistentId: "A"),
                    track(sourceIndex: 1, persistentId: "B", sampleRateHz: 48000),
                ]
            )
        )
        try withTemporaryDirectory { dir in
            let paths = try writeAudit(outputDir: dir, plan: plan)

            let loaded = try loadPlan(from: URL(fileURLWithPath: paths.planJson))
            #expect(scalarEqual(loaded, plan))
            let csvText = try String(contentsOfFile: paths.detailCsv, encoding: .utf8)
            #expect(csvText.lowercased().contains("winner"))
            let markdown = try String(contentsOfFile: paths.summaryMarkdown, encoding: .utf8)
            #expect(markdown.contains("#Musica xTotal"))
            let planText = try String(contentsOfFile: paths.planJson, encoding: .utf8)
            #expect(planText.hasSuffix("\n"))

            #expect(auditArtifactsExist(paths))
            // The reservation is removed on success (audit.py finally-branch).
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(!leftovers.contains { $0.hasSuffix(".reservation") }, "leftover reservation: \(leftovers)")
        }
    }

    @Test func usesNewPathsWhenATimestampedArtifactSetExists() throws {
        // test_audit_uses_new_paths_when_a_timestamped_artifact_set_exists,
        // plus exact-name pins for the reference's stem/suffix scheme.
        let plan = try roadTripPlan()
        try withTemporaryDirectory { dir in
            let first = try writeAudit(outputDir: dir, plan: plan, now: fixedNow, timeZone: utcTimeZone())
            let firstContents = try String(contentsOfFile: first.planJson, encoding: .utf8)
            let second = try writeAudit(outputDir: dir, plan: plan, now: fixedNow, timeZone: utcTimeZone())

            #expect(first.planJson != second.planJson)
            #expect(try String(contentsOfFile: first.planJson, encoding: .utf8) == firstContents)
            #expect(scalarEqual(try loadPlan(from: URL(fileURLWithPath: second.planJson)), plan))

            // Naming scheme: {slug}-{%Y%m%d-%H%M%S%z}[-N].{plan.json|detail.csv|summary.md}
            #expect(URL(fileURLWithPath: first.planJson).lastPathComponent == "Road-Trip-\(fixedStamp).plan.json")
            #expect(URL(fileURLWithPath: first.detailCsv).lastPathComponent == "Road-Trip-\(fixedStamp).detail.csv")
            #expect(URL(fileURLWithPath: first.summaryMarkdown).lastPathComponent == "Road-Trip-\(fixedStamp).summary.md")
            #expect(URL(fileURLWithPath: second.planJson).lastPathComponent == "Road-Trip-\(fixedStamp)-1.plan.json")
        }
    }

    @Test func foreignReservationForcesTheNextSuffix() throws {
        // Ports the open("x") FileExistsError branch of _reserve_paths: an
        // existing reservation (a concurrent audit attempt) is never touched
        // and the writer moves to the next suffixed candidate.
        let plan = try roadTripPlan()
        try withTemporaryDirectory { dir in
            let foreign = dir.appendingPathComponent("Road-Trip-\(fixedStamp).plan.reservation")
            try "".write(to: foreign, atomically: true, encoding: .utf8)

            let paths = try writeAudit(outputDir: dir, plan: plan, now: fixedNow, timeZone: utcTimeZone())

            #expect(URL(fileURLWithPath: paths.planJson).lastPathComponent == "Road-Trip-\(fixedStamp)-1.plan.json")
            #expect(FileManager.default.fileExists(atPath: foreign.path), "foreign reservation must not be removed")
        }
    }

    @Test func existingArtifactSkipsTheCandidateAndReleasesItsReservation() throws {
        // Ports the artifact-existence recheck after a successful reservation:
        // the candidate is abandoned, its transient reservation unlinked, and
        // the pre-existing artifact left untouched.
        let plan = try roadTripPlan()
        try withTemporaryDirectory { dir in
            let sentinel = dir.appendingPathComponent("Road-Trip-\(fixedStamp).summary.md")
            try "sentinel".write(to: sentinel, atomically: true, encoding: .utf8)

            let paths = try writeAudit(outputDir: dir, plan: plan, now: fixedNow, timeZone: utcTimeZone())

            #expect(URL(fileURLWithPath: paths.planJson).lastPathComponent == "Road-Trip-\(fixedStamp)-1.plan.json")
            #expect(try String(contentsOf: sentinel, encoding: .utf8) == "sentinel")
            let transient = dir.appendingPathComponent("Road-Trip-\(fixedStamp).plan.reservation")
            #expect(!FileManager.default.fileExists(atPath: transient.path))
        }
    }

    @Test func dottedPlaylistNameKeepsTheFullStemAndNeverOverwrites() throws {
        // DELIBERATE DEVIATION, pinned: the reference builds artifact paths with
        // Path.with_suffix, which TRUNCATES a dot-containing slug at its last
        // dot ("Mix.2022-<stamp>" -> "Mix.plan.json") and then livelocks on
        // the second write_audit because every suffixed candidate collapses to
        // the same truncated name (verified against the reference 2026-07-31).
        // The Swift port appends suffixes to the full stem instead, keeping
        // the AGENTS.md no-overwrite contract for every playlist name.
        let plan = try buildPlan(
            PlaylistSnapshot(
                name: "Mix.2022", persistentId: "PID",
                tracks: [track(sourceIndex: 0, persistentId: "A")]
            )
        )
        try withTemporaryDirectory { dir in
            let first = try writeAudit(outputDir: dir, plan: plan, now: fixedNow, timeZone: utcTimeZone())
            let second = try writeAudit(outputDir: dir, plan: plan, now: fixedNow, timeZone: utcTimeZone())

            #expect(URL(fileURLWithPath: first.planJson).lastPathComponent == "Mix.2022-\(fixedStamp).plan.json")
            #expect(URL(fileURLWithPath: second.planJson).lastPathComponent == "Mix.2022-\(fixedStamp)-1.plan.json")
            #expect(scalarEqual(try loadPlan(from: URL(fileURLWithPath: first.planJson)), plan))
            #expect(scalarEqual(try loadPlan(from: URL(fileURLWithPath: second.planJson)), plan))
        }
    }

    @Test func normalizesTheOutputDirectoryPath() throws {
        // Binding item 3 pin: the reference round-trips paths through
        // Path()/str(), which drops "." components and doubled separators.
        // Swift standardizes the output directory URL before use, so the
        // persisted AuditPaths strings are clean even for messy inputs.
        let plan = try roadTripPlan()
        try withTemporaryDirectory { dir in
            let messy = URL(fileURLWithPath: dir.path + "/./deep//", isDirectory: true)
            let paths = try writeAudit(outputDir: messy, plan: plan, now: fixedNow, timeZone: utcTimeZone())

            #expect(!paths.planJson.contains("/./"), "unnormalized path: \(paths.planJson)")
            #expect(!paths.planJson.contains("//"), "unnormalized path: \(paths.planJson)")
            let expected = dir.appendingPathComponent("deep")
                .appendingPathComponent("Road-Trip-\(fixedStamp).plan.json")
            #expect(FileManager.default.fileExists(atPath: expected.path))
        }
    }

    @Test func accentedPlaylistNamesKeepTheirScalarsInArtifactNames() throws {
        // Fix round 1, finding 2. Reference behavior (verified 2026-07-31):
        // slugify(NFC "Café") keeps U+00E9 and the on-disk basename is NFC
        // ("Café-<stamp>.plan.json", bytes 43 61 66 C3 A9 …); NFD input
        // "Cafe\u{0301}" slugifies to "Cafe" because the combining acute is
        // not a word character. URL path APIs decompose NFC to NFD, so the
        // writer must build artifact names without a URL round-trip.
        try withTemporaryDirectory { dir in
            let nfcPlan = try buildPlan(
                PlaylistSnapshot(
                    name: "Caf\u{E9}", persistentId: "PID",
                    tracks: [track(sourceIndex: 0, persistentId: "A")]
                )
            )
            let nfcPaths = try writeAudit(outputDir: dir, plan: nfcPlan, now: fixedNow, timeZone: utcTimeZone())
            let nfcName = String(nfcPaths.planJson.split(separator: "/").last!)
            #expect(
                scalarEqual(nfcName, "Caf\u{E9}-\(fixedStamp).plan.json"),
                "NFC basename diverged: \(codePointRendering(nfcName))"
            )
            let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(
                listed.contains { scalarEqual($0, "Caf\u{E9}-\(fixedStamp).plan.json") },
                "on-disk names: \(listed.map(codePointRendering))"
            )

            let nfdPlan = try buildPlan(
                PlaylistSnapshot(
                    name: "Cafe\u{301}", persistentId: "PID",
                    tracks: [track(sourceIndex: 0, persistentId: "A")]
                )
            )
            let nfdPaths = try writeAudit(outputDir: dir, plan: nfdPlan, now: fixedNow, timeZone: utcTimeZone())
            let nfdName = String(nfdPaths.planJson.split(separator: "/").last!)
            #expect(
                scalarEqual(nfdName, "Cafe-\(fixedStamp).plan.json"),
                "NFD basename diverged: \(codePointRendering(nfdName))"
            )
        }
    }

    @Test func csvAccountsForEverySourceOccurrenceAndActionClass() throws {
        // tests/test_audit.py::ProvenanceTests, exercised through the real
        // file-writing path (renderer-level parity is pinned by the goldens).
        let source = PlaylistSnapshot(
            name: "#Musica xTotal", persistentId: "PLAYLIST",
            tracks: [
                track(sourceIndex: 0, databaseId: 100, persistentId: "OMITTED",
                      title: "Same", artist: "Artist", album: "Old", durationMs: 180001,
                      kind: "Apple Music AAC audio file", bitRateKbps: 128, sampleRateHz: 44100,
                      cloudStatus: "No Longer Available", isFileTrack: false),
                track(sourceIndex: 1, databaseId: 101, persistentId: "WINNER",
                      title: "Same", artist: "Artist", album: "Master", durationMs: 180001,
                      kind: "AIFF audio file", bitRateKbps: 1411, sampleRateHz: 96000,
                      cloudStatus: "matched", isFileTrack: true),
                track(sourceIndex: 2, databaseId: 102, persistentId: "UNIQUE",
                      title: "Unique", artist: "Solo", album: "Only", durationMs: 200002,
                      bitRateKbps: 256, sampleRateHz: 48000, cloudStatus: "uploaded"),
                track(sourceIndex: 3, databaseId: 103, persistentId: "NONELIGIBLE",
                      title: "Missing Artist", artist: "", album: "Unknown", durationMs: 210003,
                      kind: "MPEG audio file", bitRateKbps: nil, sampleRateHz: nil,
                      cloudStatus: "", isFileTrack: true),
            ]
        )
        let plan = try buildPlan(source)
        try withTemporaryDirectory { dir in
            let paths = try writeAudit(outputDir: dir, plan: plan)
            let csvText = try String(contentsOfFile: paths.detailCsv, encoding: .utf8)
            let markdown = try String(contentsOfFile: paths.summaryMarkdown, encoding: .utf8)

            let (_, records) = parseCSVRecords(csvText)
            #expect(records.count == source.tracks.count)
            let byIndex = Dictionary(uniqueKeysWithValues: records.map { ($0["source_source_index"]!, $0) })
            #expect(Set(byIndex.keys) == ["0", "1", "2", "3"])

            let omitted = try #require(byIndex["0"])
            #expect(omitted["action"] == "omitted duplicate")
            #expect(omitted["reason"] == "available")
            #expect(omitted["source_database_id"] == "100")
            #expect(omitted["source_duration_ms"] == "180001")
            #expect(omitted["source_is_file_track"] == "False")
            #expect(omitted["winner_source_index"] == "1")
            #expect(omitted["winner_persistent_id"] == "WINNER")
            #expect(omitted["winner_bit_rate_kbps"] == "1411")
            #expect(omitted["winner_is_file_track"] == "True")

            let retainedWinner = try #require(byIndex["1"])
            #expect(retainedWinner["action"] == "retained duplicate winner")
            #expect(retainedWinner["reason"] == "selected duplicate winner")

            let unique = try #require(byIndex["2"])
            #expect(unique["action"] == "retained unique")
            #expect(unique["reason"] == "unique")

            let nonEligible = try #require(byIndex["3"])
            #expect(nonEligible["action"] == "retained non-eligible")
            #expect(nonEligible["reason"] == "non-eligible; retained unchanged")
            #expect(nonEligible["source_artist"] == "")
            #expect(nonEligible["source_bit_rate_kbps"] == "")
            #expect(nonEligible["winner_persistent_id"] == "NONELIGIBLE")

            #expect(markdown.contains("Input count: 4"))
            #expect(markdown.contains("Output count: 3"))
            #expect(markdown.contains("Omitted count: 1"))
            #expect(markdown.contains("Non-eligible count: 1"))
            #expect(markdown.contains("CSV accounts for every source occurrence: 4 rows."))
            #expect(markdown.contains("Winner: Same — Artist (source index 1)"))
            #expect(markdown.contains("Winner unavailable: False"))
            #expect(markdown.contains("Omitted: Same — Artist (source index 0)"))
            #expect(markdown.contains("Reason: available"))
            #expect(markdown.contains("Unavailable: True"))
        }
    }
}

// MARK: - write_merge_audit

@Suite("writeMergeAudit (tests/test_audit.py::MergeAuditTests)")
struct WriteMergeAuditTests {

    @Test func mergeAuditRoundTripsAndReportsEveryOccurrence() throws {
        let plan = try buildMergePlan(name: "Trance 2022", copies: tranceCopies())
        try withTemporaryDirectory { dir in
            let paths = try writeMergeAudit(outputDir: dir, plan: plan)
            let loaded = try loadMergePlan(from: URL(fileURLWithPath: paths.planJson))
            #expect(scalarEqual(loaded, plan))

            let csvText = try String(contentsOfFile: paths.detailCsv, encoding: .utf8)
            let (_, records) = parseCSVRecords(csvText)
            // One row per source occurrence across all copies (2 + 1 = 3).
            #expect(records.count == 3)
            let byPid = Dictionary(uniqueKeysWithValues: records.map { ($0["source_persistent_id"]!, $0) })
            #expect(byPid["LOSSY"]?["action"] == "omitted duplicate")
            #expect(byPid["LOSSY"]?["winner_persistent_id"] == "LOSSLESS")
            #expect(byPid["LOSSY"]?["source_copy_ordinal"] == "0")
            #expect(byPid["LOSSY"]?["source_copy_persistent_id"] == "PID-A")
            #expect(byPid["LOSSLESS"]?["source_copy_ordinal"] == "1")
            #expect(byPid["UNIQUE-A"]?["action"] == "retained unique")

            let markdown = try String(contentsOfFile: paths.summaryMarkdown, encoding: .utf8)
            #expect(markdown.contains("Trance 2022"))
            #expect(markdown.contains("Copies: 2"))
            #expect(markdown.contains("Combined input count: 3"))
            #expect(markdown.contains("Output count: 2"))
        }
    }

    @Test func writeMergeAuditNeverOverwrites() throws {
        let plan = try buildMergePlan(name: "Trance 2022", copies: tranceCopies())
        try withTemporaryDirectory { dir in
            let first = try writeMergeAudit(outputDir: dir, plan: plan)
            let second = try writeMergeAudit(outputDir: dir, plan: plan)
            #expect(first.planJson != second.planJson)
            #expect(auditArtifactsExist(first))
            #expect(auditArtifactsExist(second))
        }
    }
}

// MARK: - loadPlan decode surface

@Suite("loadPlan decode rejections (tests/test_audit.py::PlanIntegrityTests)")
struct PlanLoaderDecodeTests {

    @Test func roundTripsTheCompleteOrderedSourceSnapshot() throws {
        // test_plan_json_round_trips_the_complete_ordered_source_snapshot
        let source = PlaylistSnapshot(
            name: "Source", persistentId: "PLAYLIST",
            tracks: [
                track(sourceIndex: 0, databaseId: 10, persistentId: "A"),
                track(sourceIndex: 1, databaseId: 20, persistentId: "B", title: "Other", durationMs: nil),
            ]
        )
        let plan = try buildPlan(source)
        try withTemporaryDirectory { dir in
            let paths = try writeAudit(outputDir: dir, plan: plan)
            let loaded = try loadPlan(from: URL(fileURLWithPath: paths.planJson))
            #expect(scalarEqual(loaded, plan))
            #expect(scalarEqual(loaded.sourceTracks, source.tracks))
        }
    }

    @Test func emptyPlaylistPlanRoundTrips() throws {
        let plan = try buildPlan(PlaylistSnapshot(name: "Empty", persistentId: "PID", tracks: []))
        try withTemporaryDirectory { dir in
            let url = try writeText(renderPlanJSON(plan), in: dir)
            #expect(scalarEqual(try loadPlan(from: url), plan))
        }
    }

    @Test func rejectsLegacySchemaWithFreshAuditMessage() throws {
        // test_load_plan_rejects_legacy_schema_with_fresh_audit_message
        var object = try jsonObject(try currentSchemaPlan())
        object.removeValue(forKey: "source_tracks")
        try withTemporaryDirectory { dir in
            expectPlanLoadRejection(
                try writeJSONObject(object, in: dir),
                .decodeRejected,
                messageContains: ["fresh audit"]
            )
        }
    }

    @Test func rejectsUnknownMissingAndWrongTypedFields() throws {
        // test_load_plan_rejects_unknown_missing_and_wrong_typed_fields
        try withTemporaryDirectory { dir in
            var unknown = try jsonObject(try currentSchemaPlan())
            unknown["unexpected"] = "value"
            expectPlanLoadRejection(
                try writeJSONObject(unknown, in: dir),
                .decodeRejected,
                messageContains: ["unexpected"]
            )

            var missing = try jsonObject(try currentSchemaPlan())
            missing.removeValue(forKey: "source_fingerprint")
            expectPlanLoadRejection(
                try writeJSONObject(missing, in: dir),
                .decodeRejected,
                messageContains: ["missing", "source_fingerprint"]
            )

            var booleanCount = try jsonObject(try currentSchemaPlan())
            booleanCount["source_track_count"] = true
            expectPlanLoadRejection(
                try writeJSONObject(booleanCount, in: dir),
                .decodeRejected,
                messageContains: ["source_track_count"]
            )

            var booleanTrackId = try jsonObject(try currentSchemaPlan())
            var tracks = try #require(booleanTrackId["source_tracks"] as? [[String: Any]])
            tracks[0]["database_id"] = true
            booleanTrackId["source_tracks"] = tracks
            expectPlanLoadRejection(
                try writeJSONObject(booleanTrackId, in: dir),
                .decodeRejected,
                messageContains: ["database_id"]
            )
        }
    }

    @Test func rejectsAMissingFile() throws {
        try withTemporaryDirectory { dir in
            expectPlanLoadRejection(
                dir.appendingPathComponent("absent.plan.json"),
                .fileUnreadable,
                messageContains: ["absent.plan.json"]
            )
        }
    }

    @Test func rejectsMalformedJSON() throws {
        try withTemporaryDirectory { dir in
            expectPlanLoadRejection(
                try writeText("{not json", in: dir),
                .malformedJSON,
                messageContains: []
            )
        }
    }

    @Test func rejectsIntegralJSONFloatsForEveryIntField() throws {
        // BINDING item 1: the reference's `type(value) is int` rejects 183000.0;
        // JSONDecoder alone would accept it. Every Int field class is mutated
        // at the raw-token level and must be rejected at load.
        let plan = try currentSchemaPlan()
        let mutations: [(target: String, replacement: String, field: String)] = [
            ("\"duration_ms\":183000", "\"duration_ms\":183000.0", "duration_ms"),
            ("\"source_index\":0", "\"source_index\":0.0", "source_index"),
            ("\"database_id\":100", "\"database_id\":100.0", "database_id"),
            ("\"source_track_count\":3", "\"source_track_count\":3.0", "source_track_count"),
            ("\"winner_source_indexes\":[1,2]", "\"winner_source_indexes\":[1.0,2]", "winner_source_indexes"),
            ("\"first_source_index\":0", "\"first_source_index\":0.0", "first_source_index"),
            ("\"reason_by_omitted_index\":[[0,", "\"reason_by_omitted_index\":[[0.0,", "reason_by_omitted_index"),
            ("\"sample_rate_hz\":44100", "\"sample_rate_hz\":44100.0", "sample_rate_hz"),
            ("\"bit_rate_kbps\":256", "\"bit_rate_kbps\":256.5", "bit_rate_kbps"),
            ("\"duration_ms\":183000", "\"duration_ms\":1.83e5", "duration_ms"),
        ]
        try withTemporaryDirectory { dir in
            for mutation in mutations {
                let text = try mutatedCompactJSON(plan, replacing: mutation.target, with: mutation.replacement)
                expectPlanLoadRejection(
                    try writeText(text, in: dir),
                    .decodeRejected,
                    messageContains: [mutation.field, "must be an integer"]
                )
            }
        }
    }
}

// MARK: - loadPlan strict byte/syntax gate (fix round 1, finding 1)

@Suite("loadPlan strict byte and syntax gate (reference read_text + json.loads parity)")
struct PlanLoaderStrictSyntaxTests {

    private func compactPlanText() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(try currentSchemaPlan()), as: UTF8.self)
    }

    private func writeBytes(_ data: Data, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("candidate.plan.json")
        try data.write(to: url)
        return url
    }

    @Test func acceptsPlainUTF8() throws {
        let plan = try currentSchemaPlan()
        try withTemporaryDirectory { dir in
            let url = try writeBytes(Data(try compactPlanText().utf8), in: dir)
            #expect(scalarEqual(try loadPlan(from: url), plan))
        }
    }

    @Test func rejectsAUTF8ByteOrderMark() throws {
        // Reference: json.loads raises "Unexpected UTF-8 BOM" (verified 2026-07-31).
        let payload = Data([0xEF, 0xBB, 0xBF]) + Data(try compactPlanText().utf8)
        try withTemporaryDirectory { dir in
            expectPlanLoadRejection(
                try writeBytes(payload, in: dir),
                .malformedJSON,
                messageContains: ["BOM"]
            )
        }
    }

    @Test func rejectsUTF16Documents() throws {
        // Reference: read_text(encoding="utf-8") raises UnicodeDecodeError for
        // both endiannesses with a BOM and for BOM-less UTF-16 of this
        // payload (verified 2026-07-31). JSONSerialization would happily
        // auto-detect and accept all three.
        let text = try compactPlanText()
        let variants: [(String, Data)] = [
            ("utf16-le+bom", Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!),
            ("utf16-be+bom", Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!),
            ("utf16-le no bom", text.data(using: .utf16LittleEndian)!),
        ]
        try withTemporaryDirectory { dir in
            for (label, payload) in variants {
                expectPlanLoadRejection(
                    try writeBytes(payload, in: dir),
                    .malformedJSON,
                    messageContains: ["UTF-8"]
                )
                _ = label
            }
        }
    }

    @Test func rejectsTrailingCommas() throws {
        // Reference: "Illegal trailing comma before end of object/array"
        // (verified 2026-07-31); JSONSerialization tolerates both.
        let text = try compactPlanText()
        #expect(text.hasSuffix("]}"))
        let inObject = String(text.dropLast()) + ",}"
        let inArray = text.replacingOccurrences(
            of: "\"winner_source_indexes\":[1,2]",
            with: "\"winner_source_indexes\":[1,2,]"
        )
        #expect(inArray != text)
        try withTemporaryDirectory { dir in
            expectPlanLoadRejection(
                try writeBytes(Data(inObject.utf8), in: dir),
                .malformedJSON,
                messageContains: ["trailing comma", "object"]
            )
            expectPlanLoadRejection(
                try writeBytes(Data(inArray.utf8), in: dir),
                .malformedJSON,
                messageContains: ["trailing comma", "array"]
            )
        }
    }

    @Test func rejectsDuplicateObjectKeysAtAnyNestingLevel() throws {
        // DELIBERATE STRICT-DIRECTION DEVIATION, pinned: Python's json.loads
        // silently keeps the LAST duplicate key, so a tampered-last value is
        // caught by validation but a tampered-FIRST value is silently ignored
        // and the reference ACCEPTS the document (verified 2026-07-31).
        // JSONSerialization keeps the FIRST, inverting which tampering wins —
        // the fail-open the M3 review reproduced. The Swift loader rejects
        // duplicate keys outright at every nesting level.
        let text = try compactPlanText()
        let mutations: [(String, String, String)] = [
            ("top-level tampered last", "\"source_track_count\":3",
             "\"source_track_count\":3,\"source_track_count\":999"),
            ("top-level tampered first", "\"source_track_count\":3",
             "\"source_track_count\":999,\"source_track_count\":3"),
            ("nested tampered last", "\"database_id\":100",
             "\"database_id\":100,\"database_id\":999"),
            ("nested tampered first", "\"database_id\":100",
             "\"database_id\":999,\"database_id\":100"),
        ]
        try withTemporaryDirectory { dir in
            for (label, target, replacement) in mutations {
                #expect(text.contains(target), "mutation target missing for \(label)")
                let mutated = text.replacingOccurrences(of: target, with: replacement)
                expectPlanLoadRejection(
                    try writeBytes(Data(mutated.utf8), in: dir),
                    .malformedJSON,
                    messageContains: ["duplicate", label.hasPrefix("top") ? "source_track_count" : "database_id"]
                )
            }
        }
    }

    @Test func rejectsRawControlCharactersInStrings() throws {
        // json.loads (strict=True) rejects unescaped control characters.
        let text = try compactPlanText().replacingOccurrences(
            of: "\"title\":\"Unique\"",
            with: "\"title\":\"Uni\nque\""
        )
        try withTemporaryDirectory { dir in
            expectPlanLoadRejection(
                try writeBytes(Data(text.utf8), in: dir),
                .malformedJSON,
                messageContains: ["control character"]
            )
        }
    }

    @Test func rejectsDeeplyNestedDocumentsWithoutCrashing() throws {
        // Fix round 2: the round-1 scanner recursed once per nesting level
        // with no cap — 200,000 nested "[" SIGSEGVed the loader (exit 139,
        // reproduced out-of-process pre-fix; the reference raises a clean
        // RecursionError, its effective cap being Python's ~1000 recursion
        // limit). The scanner now fails CLOSED past 128 levels. Depths here
        // are far past the cap but small enough to run fast; the 200k crash
        // scale is re-verified out-of-process (see m3-report.md fix round 2).
        let depth = 10_000
        let nestedArrays = String(repeating: "[", count: depth)
            + String(repeating: "]", count: depth)
        let nestedObjects = String(repeating: "{\"k\":", count: depth)
            + "1" + String(repeating: "}", count: depth)
        try withTemporaryDirectory { dir in
            for document in [nestedArrays, nestedObjects] {
                expectPlanLoadRejection(
                    try writeBytes(Data(document.utf8), in: dir),
                    .malformedJSON,
                    messageContains: ["nested too deeply"]
                )
            }
            // Just past the cap must also reject; a plan-shaped depth must not.
            let justPast = String(repeating: "[", count: 129) + String(repeating: "]", count: 129)
            expectPlanLoadRejection(
                try writeBytes(Data(justPast.utf8), in: dir),
                .malformedJSON,
                messageContains: ["nested too deeply"]
            )
        }
    }

    @Test func acceptsPlanShapedNestingWellUnderTheDepthCap() throws {
        // Real plans nest ~5 levels (root -> decisions -> decision ->
        // omitted/reasons -> track/pair); the cap must be invisible to them.
        let plan = try currentSchemaPlan()
        try withTemporaryDirectory { dir in
            let url = try writeBytes(Data(try compactPlanText().utf8), in: dir)
            #expect(scalarEqual(try loadPlan(from: url), plan))
        }
    }

    @Test func mergeLoaderSharesTheStrictGate() throws {
        let plan = try buildMergePlan(name: "Trance 2022", copies: tranceCopies())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = Data([0xEF, 0xBB, 0xBF]) + (try encoder.encode(plan))
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("candidate.plan.json")
            try payload.write(to: url)
            expectMergePlanLoadRejection(url, .malformedJSON, messageContains: ["BOM"])
        }
    }
}

// MARK: - loadPlan integrity surface (binding item 2)

@Suite("loadPlan integrity rejections (every validate_plan_integrity branch)")
struct PlanLoaderIntegrityTests {

    private func reject(
        _ mutate: (inout [String: Any]) throws -> Void,
        messageContains parts: [String],
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) throws {
        var object = try jsonObject(try currentSchemaPlan())
        try mutate(&object)
        try withTemporaryDirectory { dir in
            expectPlanLoadRejection(
                try writeJSONObject(object, in: dir),
                .integrityRejected,
                messageContains: parts,
                sourceLocation: sourceLocation
            )
        }
    }

    private func mutateDecision(
        _ object: inout [String: Any],
        at index: Int = 0,
        _ change: (inout [String: Any]) throws -> Void
    ) throws {
        var decisions = try #require(object["decisions"] as? [[String: Any]])
        try change(&decisions[index])
        object["decisions"] = decisions
    }

    private func sourceTrack(_ object: [String: Any], _ index: Int) throws -> [String: Any] {
        let tracks = try #require(object["source_tracks"] as? [[String: Any]])
        return tracks[index]
    }

    @Test func rejectsNegativeSourceTrackCount() throws {
        try reject({ $0["source_track_count"] = -1 }, messageContains: ["source_track_count must not be negative"])
    }

    @Test func rejectsDuplicateNonEligibleIndexes() throws {
        try reject(
            { $0["non_eligible_source_indexes"] = [2, 2] },
            messageContains: ["non-eligible source indexes contain a duplicate"]
        )
    }

    @Test func rejectsOutOfRangeNonEligibleIndex() throws {
        try reject(
            { $0["non_eligible_source_indexes"] = [99] },
            messageContains: ["non-eligible source index 99 is out of range"]
        )
    }

    @Test func rejectsNonEligibleIndexThatIsNotRetained() throws {
        try reject(
            { $0["non_eligible_source_indexes"] = [0] },
            messageContains: ["non-eligible source index 0 is not retained"]
        )
    }

    @Test func rejectsDecisionsNotInStrictlyIncreasingOrder() throws {
        try reject(
            { object in
                try self.mutateDecision(&object) { $0["first_source_index"] = -1 }
            },
            messageContains: ["duplicate decisions are not in strictly increasing source order"]
        )
    }

    @Test func rejectsDecisionWinnerOutOfRange() throws {
        try reject(
            { object in
                try self.mutateDecision(&object) { decision in
                    var winner = try #require(decision["winner"] as? [String: Any])
                    winner["source_index"] = 99
                    decision["winner"] = winner
                }
            },
            messageContains: ["decision 0 winner source index is out of range"]
        )
    }

    @Test func rejectsDecisionWinnerThatDoesNotMatchTheSnapshot() throws {
        try reject(
            { object in
                try self.mutateDecision(&object) { decision in
                    var winner = try #require(decision["winner"] as? [String: Any])
                    winner["title"] = "Tampered"
                    decision["winner"] = winner
                }
            },
            messageContains: ["decision 0 winner does not match source snapshot"]
        )
    }

    @Test func rejectsDecisionWinnerThatIsNotRetained() throws {
        try reject(
            { object in
                let omittedTrack = try self.sourceTrack(object, 0)
                try self.mutateDecision(&object) { $0["winner"] = omittedTrack }
            },
            messageContains: ["decision 0 winner is not retained"]
        )
    }

    @Test func rejectsAWinnerRepeatedAcrossDecisions() throws {
        try reject(
            { object in
                var decisions = try #require(object["decisions"] as? [[String: Any]])
                var duplicate = decisions[0]
                duplicate["first_source_index"] = 1
                decisions.append(duplicate)
                object["decisions"] = decisions
            },
            messageContains: ["a winner is repeated across duplicate decisions"]
        )
    }

    @Test func rejectsADecisionWithoutOmittedTracks() throws {
        try reject(
            { object in
                try self.mutateDecision(&object) { decision in
                    decision["omitted"] = [[String: Any]]()
                    decision["reason_by_omitted_index"] = [[Any]]()
                }
            },
            messageContains: ["decision 0 must contain an omitted track"]
        )
    }

    @Test func rejectsADecisionRepeatingAnOmittedIndex() throws {
        try reject(
            { object in
                let omittedTrack = try self.sourceTrack(object, 0)
                try self.mutateDecision(&object) { $0["omitted"] = [omittedTrack, omittedTrack] }
            },
            messageContains: ["decision 0 repeats an omitted source index"]
        )
    }

    @Test func rejectsAnOmittedIndexOutOfRange() throws {
        try reject(
            { object in
                try self.mutateDecision(&object) { decision in
                    var omitted = try #require(decision["omitted"] as? [[String: Any]])
                    omitted[0]["source_index"] = 99
                    decision["omitted"] = omitted
                }
            },
            messageContains: ["decision 0 omitted source index is out of range"]
        )
    }

    @Test func rejectsAnOmittedTrackThatDoesNotMatchTheSnapshot() throws {
        try reject(
            { object in
                try self.mutateDecision(&object) { decision in
                    var omitted = try #require(decision["omitted"] as? [[String: Any]])
                    omitted[0]["album"] = "Tampered"
                    decision["omitted"] = omitted
                }
            },
            messageContains: ["decision 0 omitted track does not match source snapshot"]
        )
    }

    @Test func rejectsAnOmittedTrackThatIsAlsoRetained() throws {
        try reject(
            { object in
                let retained = try self.sourceTrack(object, 2)
                try self.mutateDecision(&object) { decision in
                    decision["omitted"] = [retained]
                    decision["reason_by_omitted_index"] = [[2, "sample rate"] as [Any]]
                }
            },
            messageContains: ["winner/omitted partition overlaps at source index 2"]
        )
    }

    @Test func rejectsASourceIndexOmittedByMultipleDecisions() throws {
        try reject(
            { object in
                let omittedTrack = try self.sourceTrack(object, 0)
                let uniqueTrack = try self.sourceTrack(object, 2)
                var decisions = try #require(object["decisions"] as? [[String: Any]])
                decisions.append([
                    "first_source_index": 2,
                    "winner": uniqueTrack,
                    "omitted": [omittedTrack],
                    "reason_by_omitted_index": [[0, "available"] as [Any]],
                ])
                object["decisions"] = decisions
            },
            messageContains: ["source index 0 is omitted by multiple decisions"]
        )
    }

    @Test func rejectsAnInconsistentFirstSourceIndex() throws {
        try reject(
            { object in
                try self.mutateDecision(&object) { $0["first_source_index"] = 1 }
            },
            messageContains: ["decision 0 first source index is inconsistent"]
        )
    }

    @Test func rejectsAnIncompleteWinnerOmittedPartition() throws {
        try reject(
            { $0["winner_source_indexes"] = [1] },
            messageContains: ["winner/omitted indexes do not form a complete source partition"]
        )
    }

    // Fix round 1, finding 3: the seven single-plan reference rejection classes
    // previously exercised only via direct validator calls (M2), now each
    // reached through the loadPlan file surface with the verbatim message.

    @Test func rejectsATrackCountMismatchThroughTheLoader() throws {
        try reject(
            { $0["source_track_count"] = 4 },
            messageContains: ["source_track_count does not match the persisted source snapshot"]
        )
    }

    @Test func rejectsAMalformedSourceOrderThroughTheLoader() throws {
        try reject(
            { object in
                var tracks = try #require(object["source_tracks"] as? [[String: Any]])
                tracks.swapAt(0, 1)
                object["source_tracks"] = tracks
            },
            messageContains: ["persisted source track order is malformed"]
        )
    }

    @Test func rejectsEmptyWinnersForANonEmptySourceThroughTheLoader() throws {
        try reject(
            { $0["winner_source_indexes"] = [Int]() },
            messageContains: ["winner partition is empty for a non-empty source"]
        )
    }

    @Test func rejectsADuplicateWinnerThroughTheLoader() throws {
        try reject(
            { $0["winner_source_indexes"] = [1, 1, 2] },
            messageContains: ["winner_source_indexes contains a duplicate winner"]
        )
    }

    @Test func rejectsAnOutOfRangeWinnerThroughTheLoader() throws {
        try reject(
            { $0["winner_source_indexes"] = [1, 2, 99] },
            messageContains: ["winner source index 99 is out of range"]
        )
    }

    @Test func rejectsAnUnknownDecisionReasonThroughTheLoader() throws {
        try reject(
            { object in
                try self.mutateDecision(&object) {
                    $0["reason_by_omitted_index"] = [[0, "vibes"] as [Any]]
                }
            },
            messageContains: ["decision 0 has unknown reason 'vibes'"]
        )
    }

    @Test func rejectsANonCanonicalPlanThroughTheLoader() throws {
        // Eligible retained track marked non-eligible: every structural check
        // passes and only the canonical recompute catches it (audit.py:345-350).
        try reject(
            { $0["non_eligible_source_indexes"] = [2] },
            messageContains: ["not the canonical result for the persisted source snapshot"]
        )
    }

    @Test func rejectsATamperedReasonMappingThroughTheLoader() throws {
        // test_load_plan_rejects_malformed_decisions_and_reason_mappings,
        // exercised through the file-loading surface.
        try reject(
            { object in
                try self.mutateDecision(&object) {
                    $0["reason_by_omitted_index"] = [[0, "available"] as [Any], [0, "bit rate"] as [Any]]
                }
            },
            messageContains: ["reason mapping must exactly match omitted source indexes"]
        )
    }

    @Test func rejectsSnapshotFingerprintTamperingThroughTheLoader() throws {
        // test_load_plan_rejects_snapshot_fingerprint_or_order_tampering.
        try reject(
            { $0["source_fingerprint"] = String(repeating: "0", count: 64) },
            messageContains: ["source fingerprint does not match the persisted source snapshot"]
        )
    }
}

// MARK: - loadMergePlan

@Suite("loadMergePlan (tests/test_audit.py::MergeAuditTests loaders)")
struct MergePlanLoaderTests {

    @Test func roundTripsARenderedMergePlan() throws {
        let plan = try buildMergePlan(name: "Trance 2022", copies: tranceCopies())
        try withTemporaryDirectory { dir in
            let url = try writeText(renderMergePlanJSON(plan), in: dir)
            #expect(scalarEqual(try loadMergePlan(from: url), plan))
        }
    }

    @Test func rejectsATamperedFingerprint() throws {
        // test_load_merge_plan_rejects_a_tampered_fingerprint
        let plan = try buildMergePlan(name: "Trance 2022", copies: tranceCopies())
        var object = try jsonObject(plan)
        object["merge_fingerprint"] = String(repeating: "0", count: 64)
        try withTemporaryDirectory { dir in
            expectMergePlanLoadRejection(
                try writeJSONObject(object, in: dir),
                .integrityRejected,
                messageContains: ["merge fingerprint does not match the persisted copies"]
            )
        }
    }

    @Test func rejectsNoncanonicalWinners() throws {
        // test_load_merge_plan_rejects_noncanonical_winners
        let plan = try buildMergePlan(name: "Trance 2022", copies: tranceCopies())
        var object = try jsonObject(plan)
        object["winner_source_indexes"] = [0, 1, 2] // keeps the omitted duplicate
        try withTemporaryDirectory { dir in
            expectMergePlanLoadRejection(
                try writeJSONObject(object, in: dir),
                .integrityRejected,
                messageContains: ["not the canonical result for the persisted copies"]
            )
        }
    }

    // Fix round 1, finding 3: the three merge reference rejection classes
    // previously exercised only via direct validator calls (M2), now each
    // reached through the loadMergePlan file surface.

    private func rejectMerge(
        _ mutate: (inout [String: Any]) throws -> Void,
        messageContains parts: [String],
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) throws {
        var object = try jsonObject(try buildMergePlan(name: "Trance 2022", copies: tranceCopies()))
        try mutate(&object)
        try withTemporaryDirectory { dir in
            expectMergePlanLoadRejection(
                try writeJSONObject(object, in: dir),
                .integrityRejected,
                messageContains: parts,
                sourceLocation: sourceLocation
            )
        }
    }

    @Test func rejectsAnEmptyCopySetThroughTheLoader() throws {
        try rejectMerge(
            { $0["copies"] = [[String: Any]]() },
            messageContains: ["merge plan must contain at least one source copy"]
        )
    }

    @Test func rejectsDuplicateCopyPersistentIdsThroughTheLoader() throws {
        try rejectMerge(
            { object in
                var copies = try #require(object["copies"] as? [[String: Any]])
                copies[1]["persistent_id"] = "PID-A"
                object["copies"] = copies
            },
            messageContains: ["merge plan copies must have distinct persistent IDs"]
        )
    }

    @Test func rejectsACopyNameMismatchThroughTheLoader() throws {
        try rejectMerge(
            { object in
                var copies = try #require(object["copies"] as? [[String: Any]])
                copies[1]["name"] = "Trance 2023"
                object["copies"] = copies
            },
            messageContains: ["merge plan copy name does not match the merged source name"]
        )
    }

    @Test func rejectsUnknownFields() throws {
        let plan = try buildMergePlan(name: "Trance 2022", copies: tranceCopies())
        var object = try jsonObject(plan)
        object["unexpected"] = "value"
        try withTemporaryDirectory { dir in
            expectMergePlanLoadRejection(
                try writeJSONObject(object, in: dir),
                .decodeRejected,
                messageContains: ["unexpected"]
            )
        }
    }

    @Test func rejectsIntegralJSONFloatsInCopiesAndWinners() throws {
        // BINDING item 1 on the merge surface.
        let plan = try buildMergePlan(name: "Trance 2022", copies: tranceCopies())
        try withTemporaryDirectory { dir in
            let durationFloat = try mutatedCompactJSON(
                plan,
                replacing: "\"duration_ms\":180000",
                with: "\"duration_ms\":180000.0"
            )
            expectMergePlanLoadRejection(
                try writeText(durationFloat, in: dir),
                .decodeRejected,
                messageContains: ["duration_ms", "must be an integer"]
            )

            let winnersFloat = try mutatedCompactJSON(
                plan,
                replacing: "\"winner_source_indexes\":[2",
                with: "\"winner_source_indexes\":[2.0"
            )
            expectMergePlanLoadRejection(
                try writeText(winnersFloat, in: dir),
                .decodeRejected,
                messageContains: ["winner_source_indexes", "must be an integer"]
            )
        }
    }

    @Test func rejectsAMissingFileAndMalformedJSON() throws {
        try withTemporaryDirectory { dir in
            expectMergePlanLoadRejection(
                dir.appendingPathComponent("absent.plan.json"),
                .fileUnreadable,
                messageContains: ["absent.plan.json"]
            )
            expectMergePlanLoadRejection(
                try writeText("[1, 2", in: dir),
                .malformedJSON,
                messageContains: []
            )
        }
    }
}
