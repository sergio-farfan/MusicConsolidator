// RunReport.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// M11 — the mandatory post-run report: pure data + rendering for the batch
// run's after-the-fact review (the AGENTS.md batch amendment's relocated
// conscience). Every auto-decided judgment item is surfaced PROMINENTLY:
// near-identical pairs kept (the screen-2 panel data), distinct-entry
// omissions, and count anomalies; failures carry their verbatim reasons.
// The report is persisted as an artifact under the reports/ conventions
// (never-overwrite naming, new ".runreport.md" suffix); the canonical plan
// artifact files remain the durable record.

import Foundation
import ConsolidatorCore

// MARK: - judgment summaries

/// The judgment-item lines for one audited plan, rendered once (pure) and
/// reused by the report screen, the artifact text, and the pause-on-judgment
/// setting.
nonisolated struct JudgmentSummaries: Equatable, Sendable {
    let nearIdenticalPairLines: [String]
    let distinctOmissionLines: [String]
    let countAnomalyLines: [String]

    var isEmpty: Bool {
        nearIdenticalPairLines.isEmpty
            && distinctOmissionLines.isEmpty
            && countAnomalyLines.isEmpty
    }
}

private nonisolated func durationText(_ ms: Int?) -> String {
    ms.map { "\($0) ms" } ?? "no duration"
}

/// Build the judgment lines from CANONICAL plan data (the same classifiers
/// screens 2 uses: `nearIdenticalWinnerPairs` + `distinctOmissions`).
/// Count anomalies are deliberately narrow and honest: an empty input or an
/// empty planned output — the classes where a human should ask why the run
/// touched this item at all.
nonisolated func judgmentSummaries(
    decisions: [DuplicateDecision],
    outputTracks: [TrackSnapshot],
    inputCount: Int,
    outputCount: Int
) -> JudgmentSummaries {
    let pairLines = nearIdenticalWinnerPairs(in: outputTracks).map { pair in
        "kept both: \(pair.first.title) \u{2014} \(pair.first.artist) "
            + "(\(pair.first.persistentId) @ \(durationText(pair.first.durationMs)) / "
            + "\(pair.second.persistentId) @ \(durationText(pair.second.durationMs)))"
    }
    let omissionLines = distinctOmissions(decisionDisplays(decisions)).map { omission in
        "dropped distinct entry: \(omission.track.title) \u{2014} \(omission.track.artist) "
            + "(\(omission.track.persistentId), reason: \(omission.reason))"
    }
    var anomalies: [String] = []
    if inputCount == 0 { anomalies.append("input is empty (0 tracks)") }
    if outputCount == 0 { anomalies.append("planned output is empty (0 tracks)") }
    return JudgmentSummaries(
        nearIdenticalPairLines: pairLines,
        distinctOmissionLines: omissionLines,
        countAnomalyLines: anomalies
    )
}

// MARK: - run records

nonisolated enum RunItemOutcome: Equatable, Sendable {
    case applied(trackCount: Int)
    case failed(reason: String)
    case skipped
    case notRun

    var label: String {
        switch self {
        case .applied: return "applied"
        case .failed: return "failed"
        case .skipped: return "skipped"
        case .notRun: return "not run"
        }
    }
}

nonisolated struct RunItemRecord: Equatable, Sendable, Identifiable {
    let name: String
    let outcome: RunItemOutcome
    /// Wave C1 (spec C1.3, additive): the classified failure; nil unless
    /// `outcome` is `.failed` and the apply path classified it (records
    /// from other outcomes, and pre-C1 shapes, stay nil).
    let failureClass: ApplyFailureClass?
    let inputCount: Int?
    let outputCount: Int?
    let nearIdenticalPairLines: [String]
    let distinctOmissionLines: [String]
    let countAnomalyLines: [String]
    let targetName: String?
    let planFileName: String?
    let elapsedSeconds: Double?
    /// Optional advisory (e.g. "already done" pre-skip guidance).
    var note: String? = nil
    /// 2026-08-06 final review, finding M5: the free-form item's source
    /// playlist names (`FreeFormMergeSpec.sourceNames`), in copy order; nil
    /// for every consolidate item and every same-name merge item, exactly
    /// like `AuditQueueItem.freeForm` itself.
    var freeFormSourceNames: [String]? = nil

    var id: String { name }

    var hasJudgmentItems: Bool {
        !nearIdenticalPairLines.isEmpty
            || !distinctOmissionLines.isEmpty
            || !countAnomalyLines.isEmpty
    }
}

nonisolated struct BatchRunReport: Equatable, Sendable {
    let mode: ConsolidatorMode
    let unattended: Bool
    let startedAt: Date
    let finishedAt: Date
    let stoppedEarly: Bool
    let items: [RunItemRecord]

    var appliedCount: Int {
        items.filter { if case .applied = $0.outcome { return true }; return false }.count
    }
    var failedCount: Int {
        items.filter { if case .failed = $0.outcome { return true }; return false }.count
    }
    var skippedCount: Int { items.filter { $0.outcome == .skipped }.count }
    var notRunCount: Int { items.filter { $0.outcome == .notRun }.count }
    var judgmentItemCount: Int { items.filter(\.hasJudgmentItems).count }
    var totalSeconds: Double { finishedAt.timeIntervalSince(startedAt) }
}

// MARK: - artifact rendering + never-overwrite persistence

private nonisolated func elapsedText(_ seconds: Double) -> String {
    let whole = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", whole / 60, whole % 60)
}

/// The persisted artifact text (markdown). Failures and judgment lines are
/// carried VERBATIM.
nonisolated func renderRunReportText(_ report: BatchRunReport) -> String {
    var lines: [String] = []
    lines.append("# Batch run report")
    lines.append("")
    lines.append("- Mode: \(report.mode.displayName)")
    lines.append("- Run: \(report.unattended ? "unattended" : "confirm-each-apply")")
    lines.append("- Started: \(report.startedAt)")
    lines.append("- Finished: \(report.finishedAt) (total \(elapsedText(report.totalSeconds)))")
    if report.stoppedEarly {
        lines.append("- STOPPED EARLY on request; remaining items were not run.")
    }
    lines.append(
        "- Outcomes: \(report.appliedCount) applied, \(report.failedCount) failed, "
            + "\(report.skippedCount) skipped, \(report.notRunCount) not run"
    )
    lines.append("- Items needing after-the-fact review: \(report.judgmentItemCount)")
    lines.append("")
    for item in report.items {
        lines.append("## \(item.name) \u{2014} \(item.outcome.label)")
        // 2026-08-06 final review, finding M5: a free-form item's report
        // record names its sources, like the plan summary already does;
        // same-name items are unchanged (freeFormSourceNames stays nil).
        if let sourceNames = item.freeFormSourceNames, !sourceNames.isEmpty {
            lines.append("- Sources: \(sourceNames.joined(separator: ", "))")
        }
        if case .applied(let trackCount) = item.outcome {
            lines.append("- Created: \(item.targetName ?? "\u{2014}") (\(trackCount) tracks)")
        }
        if case .failed(let reason) = item.outcome {
            lines.append("- Failure (verbatim): \(reason)")
            // Wave C1 (spec C1.4): the classified failure and — for the four
            // classes that can leave a target behind — the leftover pointer.
            // Deliberately "- Leftover target: ", NEVER "- Created: "
            // (CleanupScanner parses Created lines as applied evidence).
            if let failureClass = item.failureClass {
                lines.append("- Failure class: \(applyFailureClassLabel(failureClass))")
                if applyFailureClassMayLeaveTarget(failureClass),
                   let target = item.targetName {
                    lines.append("- Leftover target: \(target)")
                }
            }
        }
        if let input = item.inputCount, let output = item.outputCount {
            lines.append("- Counts: \(input) in \u{2192} \(output) out")
        }
        if let plan = item.planFileName {
            lines.append("- Plan artifact: \(plan)")
        }
        if let elapsed = item.elapsedSeconds {
            lines.append("- Item time: \(elapsedText(elapsed))")
        }
        if let note = item.note {
            lines.append("- Note: \(note)")
        }
        for line in item.nearIdenticalPairLines { lines.append("- JUDGMENT: \(line)") }
        for line in item.distinctOmissionLines { lines.append("- JUDGMENT: \(line)") }
        for line in item.countAnomalyLines { lines.append("- JUDGMENT: \(line)") }
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

/// "Run-yyyyMMdd-HHmmss.runreport.md" (local time, like the audit
/// artifacts, with the same locale/calendar pins so user settings can never
/// change the artifact naming).
nonisolated func runReportBaseName(startedAt: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "Run-\(formatter.string(from: startedAt)).runreport.md"
}

nonisolated struct RunReportWriteError: Error, CustomStringConvertible {
    let description: String
}

/// Write the report artifact with never-overwrite naming: on a name
/// collision, "-1", "-2", ... are appended before the suffix (the reports/
/// convention — existing artifacts are never touched).
nonisolated func writeRunReportArtifact(
    text: String,
    baseName: String,
    directoryPath: String
) throws -> String {
    let suffix = ".runreport.md"
    let stem = baseName.hasSuffix(suffix)
        ? String(baseName.dropLast(suffix.count))
        : baseName
    let fileManager = FileManager.default
    for attempt in 0...10_000 {
        let candidate = attempt == 0 ? "\(stem)\(suffix)" : "\(stem)-\(attempt)\(suffix)"
        let path = directoryPath + "/" + candidate
        if !fileManager.fileExists(atPath: path) {
            guard fileManager.createFile(atPath: path, contents: Data(text.utf8)) else {
                throw RunReportWriteError(description: "could not write the run report at \(path)")
            }
            return path
        }
    }
    throw RunReportWriteError(description: "no free run-report name under \(directoryPath)")
}

// MARK: - history entries (M11 requirement 5; presentation only)

/// Input/output counts strictly decoded from one .plan.json artifact (A5).
/// Presentation only: a file that fails ANY loader gate simply shows no
/// counts — the history browser never surfaces a load error.
nonisolated struct HistoryPlanCounts: Equatable, Sendable {
    /// One count per source copy (merge plans, plan copy order) or the
    /// single source count (consolidation plans).
    let inputCopyCounts: [Int]
    let outputCount: Int
}

/// Decode the artifact through the SAME fail-closed loaders the apply uses
/// (ConsolidatorCore loadPlan / loadMergePlan — strict JSON, strict decode,
/// full integrity validation). Both plan schemas reject each other's fields,
/// so at most one loader accepts; any failure of both means nil, never an
/// error.
nonisolated func historyPlanCounts(atPath path: String) -> HistoryPlanCounts? {
    let url = URL(fileURLWithPath: path)
    if let plan = try? loadPlan(from: url) {
        return HistoryPlanCounts(
            inputCopyCounts: [plan.sourceTrackCount],
            outputCount: plan.winnerSourceIndexes.count
        )
    }
    if let plan = try? loadMergePlan(from: url) {
        return HistoryPlanCounts(
            inputCopyCounts: plan.copies.map { $0.tracks.count },
            outputCount: plan.winnerSourceIndexes.count
        )
    }
    return nil
}

nonisolated struct HistoryEntry: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case auditPlan
        case runReport
        case other
    }

    let fileName: String
    let path: String
    let kind: Kind
    let modifiedAt: Date?
    /// Strictly decoded plan counts; nil for non-plan artifacts and for any
    /// plan file the fail-closed loaders reject.
    let planCounts: HistoryPlanCounts?

    var id: String { path }

    var kindLabel: String {
        switch kind {
        case .auditPlan: return "plan"
        case .runReport: return "run report"
        case .other: return "artifact"
        }
    }
}

/// Scan one directory (non-recursive) for artifacts, newest first. The
/// FILES remain the durable record; this is presentation only.
nonisolated func historyEntries(inDirectoryPath directoryPath: String) -> [HistoryEntry] {
    let fileManager = FileManager.default
    guard let names = try? fileManager.contentsOfDirectory(atPath: directoryPath) else {
        return []
    }
    return names
        .filter { !$0.hasPrefix(".") }
        .map { name -> HistoryEntry in
            let path = directoryPath + "/" + name
            let kind: HistoryEntry.Kind
            if name.hasSuffix(".plan.json") {
                kind = .auditPlan
            } else if name.contains(".runreport") {
                kind = .runReport
            } else {
                kind = .other
            }
            let modified = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate]
                as? Date
            return HistoryEntry(
                fileName: name,
                path: path,
                kind: kind,
                modifiedAt: modified,
                planCounts: kind == .auditPlan ? historyPlanCounts(atPath: path) : nil
            )
        }
        .sorted { lhs, rhs in
            let left = lhs.modifiedAt ?? .distantPast
            let right = rhs.modifiedAt ?? .distantPast
            if left != right { return left > right }
            return lhs.fileName < rhs.fileName
        }
}

/// Case-insensitive filename filter; the empty query is the identity.
nonisolated func filteredHistoryEntries(
    _ entries: [HistoryEntry],
    query: String
) -> [HistoryEntry] {
    guard !query.isEmpty else { return entries }
    let needle = query.lowercased()
    return entries.filter { $0.fileName.lowercased().contains(needle) }
}
