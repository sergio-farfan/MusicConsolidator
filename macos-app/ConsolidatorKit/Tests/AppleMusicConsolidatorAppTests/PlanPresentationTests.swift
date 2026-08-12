// PlanPresentationTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Headless tests for the pure presentation layer the M7 screens render from:
// omission classification (identical library track vs distinct library
// entries), merge per-copy provenance, target-name suffixes, and the
// cli.py-parity hand-off command text (shlex.quote expectations pinned
// against python3 shlex on 2026-08-01).

import Foundation
import Testing
import ConsolidatorCore
@testable import AppleMusicConsolidatorApp

@Suite("Omission classification")
struct OmissionClassificationTests {
    @Test("same library track in two positions classifies as identical")
    func identicalLibraryTrack() {
        let winner = presentationTrack(sourceIndex: 0)
        let omitted = presentationTrack(sourceIndex: 7)
        #expect(omissionClass(winner: winner, omitted: omitted) == .identicalLibraryTrack)
    }

    @Test("a different persistent ID classifies as distinct entries")
    func distinctByPersistentID() {
        let winner = presentationTrack(sourceIndex: 0, persistentId: "PID0")
        let omitted = presentationTrack(sourceIndex: 1, persistentId: "PID1")
        #expect(omissionClass(winner: winner, omitted: omitted) == .distinctLibraryEntries)
    }

    @Test("a different database ID classifies as distinct entries")
    func distinctByDatabaseID() {
        let winner = presentationTrack(sourceIndex: 0, databaseId: 1)
        let omitted = presentationTrack(sourceIndex: 1, databaseId: 2)
        #expect(omissionClass(winner: winner, omitted: omitted) == .distinctLibraryEntries)
    }

    @Test("any quality-field difference classifies as distinct entries")
    func distinctByQualityField() {
        let winner = presentationTrack(sourceIndex: 0, bitRateKbps: 256)
        let byBitRate = presentationTrack(sourceIndex: 1, bitRateKbps: 128)
        #expect(omissionClass(winner: winner, omitted: byBitRate) == .distinctLibraryEntries)

        let byAlbum = presentationTrack(sourceIndex: 1, album: "Album, Deluxe")
        #expect(omissionClass(winner: winner, omitted: byAlbum) == .distinctLibraryEntries)

        let byCloudStatus = presentationTrack(sourceIndex: 1, cloudStatus: "no longer available")
        #expect(omissionClass(winner: winner, omitted: byCloudStatus) == .distinctLibraryEntries)
    }

    @Test("comparison is scalar-exact, not canonical-equivalent")
    func scalarExactClassification() {
        let winner = presentationTrack(sourceIndex: 0, title: "Caf\u{E9}")
        let nfdOmitted = presentationTrack(sourceIndex: 1, title: "Cafe\u{301}")
        #expect(omissionClass(winner: winner, omitted: nfdOmitted) == .distinctLibraryEntries)
    }

    @Test("decision displays carry reasons and surface the distinct subset")
    func decisionDisplaysAndDistinctSubset() {
        let winner = presentationTrack(sourceIndex: 0, persistentId: "W")
        let identical = presentationTrack(sourceIndex: 2, persistentId: "W")
        let distinct = presentationTrack(sourceIndex: 3, persistentId: "X", bitRateKbps: 128)
        let decision = DuplicateDecision(
            firstSourceIndex: 0,
            winner: winner,
            omitted: [identical, distinct],
            reasonByOmittedIndex: [
                .init(sourceIndex: 2, reason: "source order"),
                .init(sourceIndex: 3, reason: "bit rate"),
            ]
        )
        let displays = decisionDisplays([decision])
        #expect(displays.count == 1)
        #expect(displays[0].omitted.count == 2)
        #expect(displays[0].omitted[0].reason == "source order")
        #expect(displays[0].omitted[0].classification == .identicalLibraryTrack)
        #expect(displays[0].omitted[1].reason == "bit rate")
        #expect(displays[0].omitted[1].classification == .distinctLibraryEntries)
        #expect(displays[0].hasDistinctEntries)

        let distinctSubset = distinctOmissions(displays)
        #expect(distinctSubset.count == 1)
        #expect(distinctSubset[0].track.persistentId == "X")
    }
}

@Suite("Merge per-copy provenance")
struct CopyProvenanceTests {
    private func mergePlanFixture() throws -> MergePlan {
        // Copy 0 (C-LOW): [A, B]; copy 1 (C-HIGH): [A again, C].
        let trackA0 = presentationTrack(sourceIndex: 0, databaseId: 21, persistentId: "A", title: "Both Copies")
        let trackB = presentationTrack(sourceIndex: 1, databaseId: 22, persistentId: "B", title: "Low Only")
        let trackA1 = presentationTrack(sourceIndex: 0, databaseId: 21, persistentId: "A", title: "Both Copies")
        let trackC = presentationTrack(sourceIndex: 1, databaseId: 23, persistentId: "C", title: "High Only")
        let copies = [
            PlaylistSnapshot(name: "Merge List", persistentId: "C-LOW", tracks: [trackA0, trackB]),
            PlaylistSnapshot(name: "Merge List", persistentId: "C-HIGH", tracks: [trackA1, trackC]),
        ]
        return try buildMergePlan(name: "Merge List", copies: copies)
    }

    @Test("output counts and unique contributions per copy")
    func provenanceCounts() throws {
        let plan = try mergePlanFixture()
        let provenance = copyProvenance(plan)
        #expect(provenance.count == 2)

        #expect(provenance[0].ordinal == 0)
        #expect(provenance[0].persistentId == "C-LOW")
        #expect(provenance[0].trackCount == 2)
        // Winners 0 (Both Copies) and 1 (Low Only) sit in copy 0.
        #expect(provenance[0].outputTrackCount == 2)
        // Only "Low Only" would be lost without copy 0: the shared group
        // spans both copies.
        #expect(provenance[0].uniqueContributionCount == 1)

        #expect(provenance[1].ordinal == 1)
        #expect(provenance[1].persistentId == "C-HIGH")
        #expect(provenance[1].trackCount == 2)
        #expect(provenance[1].outputTrackCount == 1)
        #expect(provenance[1].uniqueContributionCount == 1)
    }

    @Test("every output track maps to its originating copy")
    func outputTrackOrigins() throws {
        let plan = try mergePlanFixture()
        let boundaries = plan.copyBoundaries
        let ordinals = plan.winnerSourceIndexes.map {
            copyOrdinal(forCombinedIndex: $0, boundaries: boundaries)
        }
        #expect(ordinals == [0, 0, 1])
    }
}

@Suite("Target names and hand-off command (cli.py parity)")
struct HandoffCommandTests {
    @Test("target name suffixes match the CLI exactly")
    func targetNameSuffixes() {
        #expect(
            defaultTargetName(mode: .consolidate, sourceName: "Fixture List")
                == "Fixture List \u{2014} Consolidated"
        )
        #expect(
            defaultTargetName(mode: .merge, sourceName: "Trance 2022")
                == "Trance 2022 \u{2014} Merged"
        )
    }

    @Test("shlexQuote matches python3 shlex.quote byte for byte")
    func shlexQuoteParity() {
        // Expected values pinned by running python3 shlex.quote (2026-08-01).
        #expect(
            shlexQuote("/Users/example/reports/Trance-2022-20260801-225539-0600.plan.json")
                == "/Users/example/reports/Trance-2022-20260801-225539-0600.plan.json"
        )
        #expect(shlexQuote("Trance 2022 \u{2014} Merged") == "'Trance 2022 \u{2014} Merged'")
        #expect(shlexQuote("It's") == "'It'\"'\"'s'")
        #expect(shlexQuote("") == "''")
        #expect(shlexQuote("Caf\u{E9} \u{2014} Consolidated") == "'Caf\u{E9} \u{2014} Consolidated'")
        #expect(shlexQuote("safe_@%+=:,./-STRING123") == "safe_@%+=:,./-STRING123")
        #expect(shlexQuote("has \"double\" quotes") == "'has \"double\" quotes'")
    }

    @Test("consolidate command text reproduces the audit's printed command")
    func consolidateCommand() {
        let command = applyCommandText(
            mode: .consolidate,
            planJsonPath: "/tmp/reports/Fixture-List-20260801-120000-0600.plan.json",
            targetName: "Fixture List \u{2014} Consolidated"
        )
        #expect(
            command == "python3 scripts/apple_music_consolidate.py apply "
                + "--plan /tmp/reports/Fixture-List-20260801-120000-0600.plan.json "
                + "--target-name 'Fixture List \u{2014} Consolidated' "
                + "--confirm-create"
        )
    }

    @Test("merge command text reproduces the audit's printed command")
    func mergeCommand() {
        let command = applyCommandText(
            mode: .merge,
            planJsonPath: "/tmp/reports/Trance-2022-20260801-120000-0600.plan.json",
            targetName: "Trance 2022 \u{2014} Merged"
        )
        #expect(
            command == "python3 scripts/apple_music_consolidate.py merge-apply "
                + "--plan /tmp/reports/Trance-2022-20260801-120000-0600.plan.json "
                + "--target-name 'Trance 2022 \u{2014} Merged' "
                + "--confirm-create"
        )
    }

    @Test("hand-off preambles carry the CLI's expected-count guarantees")
    func preambles() {
        #expect(
            handoffPreamble(mode: .consolidate, inputCount: 4, outputCount: 3)
                == "Copyable apply command (expected input count: 4; expected output count: 3):"
        )
        #expect(
            handoffPreamble(mode: .merge, inputCount: 19, outputCount: 10)
                == "Copyable merge-apply command "
                + "(expected combined input count: 19; expected output count: 10):"
        )
    }
}

@Suite("Display formatting")
struct DisplayFormattingTests {
    @Test("duration text renders minutes:seconds plus exact milliseconds")
    func durationText() {
        #expect(formattedDuration(ms: 482_013) == "8:02.013 (482013 ms)")
        #expect(formattedDuration(ms: 59_000) == "0:59.000 (59000 ms)")
        #expect(formattedDuration(ms: nil) == "\u{2014}")
    }
}
