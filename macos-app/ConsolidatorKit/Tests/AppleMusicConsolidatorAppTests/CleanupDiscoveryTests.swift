// CleanupDiscoveryTests.swift
// B3 discovery: reports/ scan, strict MergePlan gate, grouping by the
// copies' persistent-ID set, newest-plan selection by the basename stamp,
// and target-name resolution (run-report record, else the Merged default).
// Pure disk fixtures; the live closures are never invoked by discovery.

import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

@Suite("Cleanup discovery (B3)")
@MainActor
struct CleanupDiscoveryTests {
    @Test("plans group by their copies' persistent-ID set")
    func groupingByPersistentIdSet() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let plan = try buildMergePlan(name: "Trance 2022", copies: cleanupFixtureCopies())
        try fixture.writePlan(plan, at: Date(timeIntervalSince1970: 1_754_000_000))
        try fixture.writePlan(plan, at: Date(timeIntervalSince1970: 1_754_100_000))
        let otherCopy = PlaylistSnapshot(
            name: "Other List",
            persistentId: "CPYCCCC000000003",
            tracks: [
                presentationTrack(
                    sourceIndex: 0, databaseId: 9, persistentId: "T0000009", title: "Delta"
                )
            ]
        )
        let otherPlan = try buildMergePlan(name: "Other List", copies: [otherCopy])
        try fixture.writePlan(otherPlan, at: Date(timeIntervalSince1970: 1_754_200_000))

        let groups = fixture.scanner().discoverGroups()

        #expect(groups.count == 2)
        let trance = try #require(groups.first { $0.groupName == "Trance 2022" })
        #expect(trance.planFileNames.count == 2)
        #expect(trance.plan.copies.map(\.persistentId)
            == ["CPYAAAA000000001", "CPYBBBB000000002"])
        let other = try #require(groups.first { $0.groupName == "Other List" })
        #expect(other.planFileNames.count == 1)
    }

    @Test("the newest plan artifact (by basename timestamp) represents its group")
    func newestPlanSelection() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let plan = try buildMergePlan(name: "Trance 2022", copies: cleanupFixtureCopies())
        let older = try fixture.writePlan(plan, at: Date(timeIntervalSince1970: 1_754_000_000))
        let newer = try fixture.writePlan(plan, at: Date(timeIntervalSince1970: 1_754_100_000))

        let groups = fixture.scanner().discoverGroups()

        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.planFileName == newer)
        #expect(group.planFileName != older)
        #expect(Set(group.planFileNames) == Set([older, newer]))
    }

    @Test("target name comes from a run-report record when one references the group")
    func targetNameFromRunReportRecord() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let plan = try buildMergePlan(name: "Trance 2022", copies: cleanupFixtureCopies())
        let planName = try fixture.writePlan(plan, at: Date(timeIntervalSince1970: 1_754_000_000))
        let report = """
        # Batch run report

        - Mode: Merge

        ## Trance 2022 \u{2014} applied
        - Created: Custom Target (3 tracks)
        - Counts: 3 in \u{2192} 3 out
        - Plan artifact: \(planName)
        """
        try fixture.writeText(report, fileName: "Run-20260803-120000.runreport.md")

        let group = try #require(fixture.scanner().discoverGroups().first)
        #expect(group.targetName == "Custom Target")
    }

    @Test("Wave C1 regression: reports carrying the new failure lines parse identically")
    func waveCFailureLinesAreInvisibleToTheParser() async throws {
        // Spec C1.4: CleanupScanner's run-report parsing keys ONLY on
        // "## ", "- Created: ", and "- Plan artifact: " prefixes. A report
        // whose failed records carry "- Failure class: " and
        // "- Leftover target: " lines must resolve the SAME target name as
        // one without them — in particular a leftover line must never be
        // read as applied (Created) evidence.
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let plan = try buildMergePlan(name: "Trance 2022", copies: cleanupFixtureCopies())
        let planName = try fixture.writePlan(plan, at: Date(timeIntervalSince1970: 1_754_000_000))
        let report = """
        # Batch run report

        ## Goddesses \u{2014} failed
        - Failure (verbatim): target user playlist already exists
        - Failure class: Refused before write \u{2014} nothing was created.
        - Plan artifact: Goddesses-20260804-090000+0000.plan.json

        ## Trance 2022 \u{2014} applied
        - Created: Custom Target (3 tracks)
        - Plan artifact: \(planName)

        ## Daechir ESP ORIG \u{2014} failed
        - Failure (verbatim): source track count mismatch after write: planned 143, actual 141
        - Failure class: Source drifted after a verified write \u{2014} the created target matches the plan, but the source changed after the check.
        - Leftover target: Daechir ESP ORIG \u{2014} Consolidated
        - Plan artifact: Daechir-ESP-ORIG-20260804-090000+0000.plan.json
        """
        try fixture.writeText(report, fileName: "Run-20260804-090000.runreport.md")

        let group = try #require(fixture.scanner().discoverGroups().first)
        #expect(group.targetName == "Custom Target")
    }

    @Test("target name defaults to the Merged convention without a record")
    func targetNameDefaultsToMergedConvention() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let plan = try buildMergePlan(name: "Trance 2022", copies: cleanupFixtureCopies())
        try fixture.writePlan(plan, at: Date(timeIntervalSince1970: 1_754_000_000))

        let group = try #require(fixture.scanner().discoverGroups().first)
        #expect(group.targetName == "Trance 2022 \u{2014} Merged")
    }

    @Test("non-merge plan JSON is skipped silently")
    func nonMergePlanJSONSkipped() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        try fixture.writeText(
            "{\"kind\": \"not a merge plan\"}",
            fileName: "Foreign-20260803-120000+0000.plan.json"
        )
        let plan = try buildMergePlan(name: "Trance 2022", copies: cleanupFixtureCopies())
        try fixture.writePlan(plan, at: Date(timeIntervalSince1970: 1_754_000_000))

        let groups = fixture.scanner().discoverGroups()
        #expect(groups.count == 1)
        #expect(groups[0].groupName == "Trance 2022")
    }

    @Test("malformed JSON is skipped without crashing")
    func malformedJSONSkippedWithoutCrash() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        try fixture.writeText(
            "{ this is not JSON",
            fileName: "Broken-20260803-120000+0000.plan.json"
        )

        #expect(fixture.scanner().discoverGroups().isEmpty)
    }
}
