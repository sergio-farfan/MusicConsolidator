// HistoryCountTests.swift
// Wave A (A5) — history entries carry input/output counts strictly decoded
// from their .plan.json artifacts through the same fail-closed loaders the
// apply uses. ANY loader failure yields an entry WITHOUT counts, never an
// error. Structural: the history browser stays bounded with count-bearing
// rows present.

import AppKit
import Foundation
import SwiftUI
import Testing
import ConsolidatorCore
@testable import AppleMusicConsolidatorApp

private func makeHistoryFixtureDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wave-a-history-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func twoTrackConsolidatePlan() throws -> ConsolidationPlan {
    try buildPlan(PlaylistSnapshot(
        name: "Alpha List",
        persistentId: "PL-A",
        tracks: [
            presentationTrack(
                sourceIndex: 0, databaseId: 1, persistentId: "AAAA0001", title: "First"
            ),
            presentationTrack(
                sourceIndex: 1, databaseId: 2, persistentId: "AAAA0002", title: "Second"
            ),
        ]
    ))
}

@Suite("Wave A — history entry counts")
struct HistoryCountTests {

    @Test("a consolidate plan artifact yields single-source counts")
    func consolidatePlanCounts() throws {
        let directory = try makeHistoryFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeAudit(outputDir: directory, plan: twoTrackConsolidatePlan())

        let entries = historyEntries(inDirectoryPath: directory.path)
        let planEntry = try #require(entries.first { $0.kind == .auditPlan })
        #expect(
            planEntry.planCounts
                == HistoryPlanCounts(inputCopyCounts: [2], outputCount: 2)
        )
    }

    @Test("a merge plan artifact yields per-copy counts in plan copy order")
    func mergePlanCounts() throws {
        let directory = try makeHistoryFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plan = try buildMergePlan(
            name: "Beta List",
            copies: [
                PlaylistSnapshot(
                    name: "Beta List",
                    persistentId: "PL-1",
                    tracks: [
                        presentationTrack(
                            sourceIndex: 0, databaseId: 1,
                            persistentId: "BBBB0001", title: "First"
                        ),
                    ]
                ),
                PlaylistSnapshot(
                    name: "Beta List",
                    persistentId: "PL-2",
                    tracks: [
                        presentationTrack(
                            sourceIndex: 0, databaseId: 2,
                            persistentId: "BBBB0002", title: "Second"
                        ),
                        presentationTrack(
                            sourceIndex: 1, databaseId: 3,
                            persistentId: "BBBB0003", title: "Third"
                        ),
                    ]
                ),
            ]
        )
        _ = try writeMergeAudit(outputDir: directory, plan: plan)

        let entries = historyEntries(inDirectoryPath: directory.path)
        let planEntry = try #require(entries.first { $0.kind == .auditPlan })
        #expect(
            planEntry.planCounts
                == HistoryPlanCounts(inputCopyCounts: [1, 2], outputCount: 3)
        )
    }

    @Test("malformed or non-plan JSON shows the entry without counts, never an error")
    func malformedPlanShowsNoCounts() throws {
        let directory = try makeHistoryFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent("Broken-20260803-1.plan.json").path,
            contents: Data("{not json".utf8)
        )
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent("Empty-20260803-1.plan.json").path,
            contents: Data("{}".utf8)
        )

        let entries = historyEntries(inDirectoryPath: directory.path)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.kind == .auditPlan })
        #expect(entries.allSatisfy { $0.planCounts == nil })
    }
}

@MainActor
@Suite("Wave A — history browser counts (structural)", .serialized)
struct HistoryCountStructuralTests {

    @Test("history browser renders count-bearing rows within bounds")
    func historyBrowserFitsWithCounts() throws {
        let directory = try makeHistoryFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeAudit(outputDir: directory, plan: try twoTrackConsolidatePlan())
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent("Broken-20260803-1.plan.json").path,
            contents: Data("{not json".utf8)
        )

        let fixture = HostedFixture(
            HistoryBrowserView(directoryPath: directory.path), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(
            fixture.hosting.frame.height <= 806,
            "history height \(fixture.hosting.frame.height)"
        )
        #expect(
            view(under: fixture.hosting, axIdentifier: M11ControlID.historyFilter) != nil
        )
        // Four rows: plan.json + detail.csv + summary.md + the malformed plan.
        #expect(listContentCellCount(under: fixture.hosting) == 4)
    }
}
