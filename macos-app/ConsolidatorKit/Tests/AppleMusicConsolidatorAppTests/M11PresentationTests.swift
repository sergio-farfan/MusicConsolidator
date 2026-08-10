// M11PresentationTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// M11 pure layers: the run report's judgment summaries (pinned against the
// THREE REAL merge plans in reports/ — the live Trance 2022 / Soka Varios /
// SGI Artists ground truths), report rendering + never-overwrite artifact
// naming, history-browser entries, and the cache staleness text. No I/O
// beyond read-only fixture loads and per-test temp dirs.

import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

private func reportsURL(_ basename: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("reports")
        .appendingPathComponent(basename)
}

private func summaries(forRealPlan basename: String) throws -> JudgmentSummaries {
    let plan = try loadMergePlan(from: reportsURL(basename))
    let output = planOutputTracks(
        winnerSourceIndexes: plan.winnerSourceIndexes, from: plan.combinedTracks
    )
    return judgmentSummaries(
        decisions: plan.decisions,
        outputTracks: output,
        inputCount: plan.combinedTrackCount,
        outputCount: plan.winnerSourceIndexes.count
    )
}

@Suite("M11 — judgment summaries against the real plans")
struct JudgmentSummaryGroundTruthTests {

    @Test("Trance 2022: exactly the Gamemaster kept-pair, no distinct omissions")
    func trance() throws {
        let judgment = try summaries(forRealPlan: "Trance-2022-20260801-225539-0600.plan.json")
        #expect(judgment.nearIdenticalPairLines.count == 1)
        let line = judgment.nearIdenticalPairLines[0]
        #expect(line.contains("Gamemaster"))
        #expect(line.contains("6FDC9C6E5E713E50"))
        #expect(line.contains("59956C9C3E4F609F"))
        #expect(judgment.distinctOmissionLines.isEmpty)
        #expect(judgment.countAnomalyLines.isEmpty)
    }

    @Test("Soka Varios: exactly the Lotus Sutra kept-pair")
    func soka() throws {
        let judgment = try summaries(forRealPlan: "Soka-Varios-20260801-230842-0600.plan.json")
        #expect(judgment.nearIdenticalPairLines.count == 1)
        let line = judgment.nearIdenticalPairLines[0]
        #expect(line.contains("3C99CFC8FFC39860"))
        #expect(line.contains("326164DC51221921"))
        #expect(judgment.distinctOmissionLines.isEmpty)
    }

    @Test("SGI Artists: zero pairs, exactly the two Howard-Jones distinct omissions")
    func sgi() throws {
        let judgment = try summaries(forRealPlan: "SGI-Artists-20260801-230900-0600.plan.json")
        #expect(judgment.nearIdenticalPairLines.isEmpty)
        #expect(judgment.distinctOmissionLines.count == 2)
        #expect(judgment.distinctOmissionLines.allSatisfy { $0.contains("Howard Jones") })
        #expect(judgment.countAnomalyLines.isEmpty)
    }

    @Test("count anomalies flag empty inputs and empty outputs")
    func countAnomalies() {
        let empty = judgmentSummaries(
            decisions: [], outputTracks: [], inputCount: 0, outputCount: 0
        )
        #expect(!empty.countAnomalyLines.isEmpty)
        let clean = judgmentSummaries(
            decisions: [], outputTracks: [presentationTrack()],
            inputCount: 1, outputCount: 1
        )
        #expect(clean.countAnomalyLines.isEmpty)
    }
}

@Suite("M11 — run report rendering and artifact naming")
struct RunReportRenderingTests {

    private func sampleReport() -> BatchRunReport {
        BatchRunReport(
            mode: .merge,
            unattended: true,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_000_120),
            stoppedEarly: false,
            items: [
                RunItemRecord(
                    name: "Trance 2022",
                    outcome: .applied(trackCount: 10),
                    failureClass: nil,
                    inputCount: 19, outputCount: 10,
                    nearIdenticalPairLines: ["kept both: Gamemaster \u{2014} Matt Darey"],
                    distinctOmissionLines: [],
                    countAnomalyLines: [],
                    targetName: "Trance 2022 \u{2014} Merged",
                    planFileName: "Trance-2022.plan.json",
                    elapsedSeconds: 42
                ),
                RunItemRecord(
                    name: "Broken List",
                    outcome: .failed(reason: "live copy count changed after audit"),
                    failureClass: nil,
                    inputCount: nil, outputCount: nil,
                    nearIdenticalPairLines: [], distinctOmissionLines: [],
                    countAnomalyLines: [], targetName: nil, planFileName: nil,
                    elapsedSeconds: nil
                ),
            ]
        )
    }

    @Test("the rendered text carries outcomes, counts, and judgment lines verbatim")
    func renderedText() {
        let text = renderRunReportText(sampleReport())
        #expect(text.contains("Trance 2022"))
        #expect(text.contains("applied"))
        #expect(text.contains("19"))
        #expect(text.contains("kept both: Gamemaster \u{2014} Matt Darey"))
        #expect(text.contains("failed"))
        #expect(text.contains("live copy count changed after audit"))
        #expect(text.contains("unattended"))
    }

    @Test("report counters aggregate outcomes")
    func counters() {
        let report = sampleReport()
        #expect(report.appliedCount == 1)
        #expect(report.failedCount == 1)
        #expect(report.skippedCount == 0)
        #expect(report.notRunCount == 0)
        #expect(report.judgmentItemCount == 1)
        #expect(abs(report.totalSeconds - 120) < 0.001)
    }

    @Test("run report artifacts are never overwritten")
    func neverOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m11-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = runReportBaseName(startedAt: Date(timeIntervalSince1970: 1_000_000))
        #expect(base.contains(".runreport"))
        let first = try writeRunReportArtifact(
            text: "first", baseName: base, directoryPath: directory.path
        )
        let second = try writeRunReportArtifact(
            text: "second", baseName: base, directoryPath: directory.path
        )
        #expect(first != second)
        #expect(try String(contentsOfFile: first, encoding: .utf8) == "first")
        #expect(try String(contentsOfFile: second, encoding: .utf8) == "second")
    }
}

@Suite("M11 — history entries")
struct HistoryEntryTests {

    @Test("directory scan classifies plans and run reports; search filters")
    func entriesAndSearch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m11-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in [
            "Alpha-20260801-1.plan.json",
            "Alpha-20260801-1.detail.csv",
            "Alpha-20260801-1.summary.md",
            "Run-20260803-120000.runreport.md",
        ] {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent(name).path,
                contents: Data("x".utf8)
            )
        }

        let entries = historyEntries(inDirectoryPath: directory.path)
        #expect(entries.count == 4)
        let plans = entries.filter { $0.kind == .auditPlan }
        let reports = entries.filter { $0.kind == .runReport }
        #expect(plans.count == 1)
        #expect(reports.count == 1)
        #expect(plans[0].fileName == "Alpha-20260801-1.plan.json")
        #expect(reports[0].fileName == "Run-20260803-120000.runreport.md")

        let filtered = filteredHistoryEntries(entries, query: "runreport")
        #expect(filtered.count == 1)
        #expect(filteredHistoryEntries(entries, query: "ALPHA").count == 3)
        #expect(filteredHistoryEntries(entries, query: "").count == 4)
    }
}

@Suite("M11 — cache staleness text")
struct StalenessTextTests {

    @Test("relative staleness renders minutes, hours, and days")
    func staleness() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        #expect(listingStalenessText(
            scannedAt: now.addingTimeInterval(-30), now: now
        ) == "Scanned just now")
        #expect(listingStalenessText(
            scannedAt: now.addingTimeInterval(-5 * 60), now: now
        ) == "Scanned 5m ago")
        #expect(listingStalenessText(
            scannedAt: now.addingTimeInterval(-2 * 3600), now: now
        ) == "Scanned 2h ago")
        #expect(listingStalenessText(
            scannedAt: now.addingTimeInterval(-3 * 86400), now: now
        ) == "Scanned 3d ago")
    }
}
