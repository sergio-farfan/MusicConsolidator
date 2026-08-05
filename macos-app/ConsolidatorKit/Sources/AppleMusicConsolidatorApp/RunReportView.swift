// RunReportView.swift
// M11 — the mandatory post-run report screen (the batch amendment's
// after-the-fact review): outcomes per item, and PROMINENTLY every
// auto-decided judgment item — near-identical pairs kept, distinct-entry
// omissions, count anomalies — plus verbatim failure reasons. The persisted
// artifact path is shown with Reveal; the plan artifacts remain the durable
// record. All content in a ScrollView (bounded context); long verbatim
// blocks are height-capped.

import SwiftUI
import AppKit
import ConsolidatorCore

@MainActor
struct RunReportView: View {
    @Bindable var model: AuditFlowModel

    var body: some View {
        if let report = model.finishedRunReport {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryPanel(report)
                    if report.judgmentItemCount > 0 {
                        judgmentPanel(report)
                    }
                    itemsPanel(report)
                    artifactPanel
                }
                .padding(20)
                .frame(maxWidth: 880, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    AppKitActionButton(
                        identifier: M11ControlID.reportDone,
                        title: "Done \u{2014} back to the browser",
                        prominent: true
                    ) {
                        model.acknowledgeRunReport()
                    }
                    // Fix round 1 (combined Task 4+5 review, Important
                    // finding): never navigate away from the report while a
                    // row's leftover resolve holds the OSA slot — the model
                    // guard is load-bearing; this is belt and suspenders.
                    .disabled(model.isMutationBusy)
                    AppKitActionButton(
                        identifier: M11ControlID.revealRunReport,
                        title: "Reveal report artifact"
                    ) {
                        if let path = model.runReportPath {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: path)]
                            )
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
        } else {
            ContentUnavailableView(
                "No run report",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Finish a batch run; its report lands here.")
            )
        }
    }

    private func summaryPanel(_ report: BatchRunReport) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Batch run report", systemImage: "checklist.checked")
                    .font(.headline)
                HStack(spacing: 8) {
                    Chip(text: report.unattended ? "unattended" : "confirmed per item", tint: .blue)
                    Chip(text: report.mode.displayName, tint: .gray)
                    if report.stoppedEarly {
                        Chip(text: "stopped early", tint: .orange)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 2) {
                    GridRow {
                        statLabel("Applied"); statLabel("Failed")
                        statLabel("Skipped"); statLabel("Not run"); statLabel("Total time")
                    }
                    GridRow {
                        statValue("\(report.appliedCount)")
                        statValue("\(report.failedCount)")
                        statValue("\(report.skippedCount)")
                        statValue("\(report.notRunCount)")
                        statValue(ProgressPhaseView.elapsedText(
                            from: report.startedAt, to: report.finishedAt
                        ))
                    }
                }
                Text(
                    "Every engine guard ran unchanged on every item: fresh live "
                        + "audit, drift refusal, fingerprint check, readback "
                        + "verification, never-repair, one apply per audit."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    /// PROMINENT: everything the run decided on its own that a human should
    /// look at once.
    private func judgmentPanel(_ report: BatchRunReport) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "Needs your review: \(report.judgmentItemCount) "
                        + (report.judgmentItemCount == 1 ? "item" : "items")
                        + " with auto-decided judgment calls",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .bold()
                ForEach(report.items.filter(\.hasJudgmentItems)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        BrowserNameText(name: item.name)
                        judgmentLines(item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func judgmentLines(_ item: RunItemRecord) -> some View {
        let lines = item.nearIdenticalPairLines
            + item.distinctOmissionLines
            + item.countAnomalyLines
        return ScrollView([.vertical, .horizontal]) {
            Text(lines.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .frame(height: min(140, CGFloat(lines.count) * 22 + 18))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    private func itemsPanel(_ report: BatchRunReport) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Items (\(report.items.count))")
                    .font(.headline)
                ForEach(report.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Chip(
                                text: item.outcome.label,
                                tint: outcomeTint(item.outcome)
                            )
                            BrowserNameText(name: item.name)
                            if let input = item.inputCount, let output = item.outputCount {
                                Text("\(input) in \u{2192} \(output) out")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        if case .failed(let reason) = item.outcome {
                            Text(reason)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(4)
                                .padding(.leading, 12)
                        }
                        if case .failed = item.outcome, let failureClass = item.failureClass {
                            failureClassLines(failureClass: failureClass, item: item)
                                .padding(.leading, 12)
                        }
                        if let target = item.targetName, case .applied = item.outcome {
                            HStack(spacing: 6) {
                                Text("Created:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                IdentifierText(text: target)
                            }
                            .padding(.leading, 12)
                        }
                    }
                    .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    /// Wave C1 (spec C1.4/C1.5): the two additive per-failed-item lines —
    /// rendered exactly as the persisted artifact renders them — plus the
    /// guidance and, for leftover-capable classes with a recorded target,
    /// the guarded delete shortcut. This screen renders only after a run
    /// ends, so the unattended lockout is naturally satisfied here; the
    /// disabled predicate still guards the browser-side states.
    ///
    /// Fix round 1 (combined Task 4+5 review, Critical finding): unlike the
    /// attended failure screen (exactly one outcome, so its ids stay
    /// static), THIS panel renders once per failed row in a `ForEach` — a
    /// run with 2+ failed items would otherwise produce sibling NSViews
    /// sharing the same accessibility identifier. Every control here is
    /// keyed by `item.name` (the report's own dedupe key), and the shared
    /// `model.isResolvingLeftoverTarget` / `model.leftoverResolveNotice`
    /// only render under the row whose `targetName` matches
    /// `model.leftoverResolveTargetName` scalar-exactly — never under every
    /// qualifying row at once.
    private func failureClassLines(
        failureClass: ApplyFailureClass,
        item: RunItemRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            AppKitStaticText(
                identifier: WaveCControlID.reportFailureBanner(item.name),
                text: "- Failure class: \(applyFailureClassLabel(failureClass))",
                maximumLines: 3
            )
            Text(applyFailureClassGuidance(failureClass))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if applyFailureClassMayLeaveTarget(failureClass),
               let target = item.targetName {
                AppKitStaticText(
                    identifier: WaveCControlID.reportLeftoverLine(item.name),
                    text: "- Leftover target: \(target)",
                    maximumLines: 2
                )
                HStack(spacing: 12) {
                    AppKitActionButton(
                        identifier: WaveCControlID.reportDeleteLeftover(item.name),
                        title: "Delete leftover target\u{2026}"
                    ) {
                        model.startDeleteLeftoverTarget(named: target)
                    }
                    .disabled(
                        model.isMutationBusy || model.isRunning
                            || model.isScanning || model.isApplying
                            || model.isUnattendedRunActive
                    )
                    if model.isResolvingLeftoverTarget,
                       scalarExact(model.leftoverResolveTargetName ?? "", target) {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let notice = model.leftoverResolveNotice,
                   scalarExact(model.leftoverResolveTargetName ?? "", target) {
                    AppKitStaticText(
                        identifier: WaveCControlID.reportResolveNotice(item.name),
                        text: notice,
                        maximumLines: 3
                    )
                }
            }
        }
    }

    private var artifactPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text("Report artifact")
                    .font(.headline)
                if let failure = model.runReportWriteFailure {
                    // LOUD (fix round 1, minor a): the report is the
                    // mandatory artifact — a persistence failure is a red
                    // headline with the verbatim reason, never a footnote.
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("REPORT NOT PERSISTED")
                                .bold()
                            Text(failure)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(4)
                            Text(
                                "This screen is the only copy. Fix the reports "
                                    + "directory and keep this window open, or copy "
                                    + "the details out before dismissing."
                            )
                            .font(.caption)
                            .lineLimit(3)
                        }
                    } icon: {
                        Image(systemName: "xmark.octagon.fill")
                    }
                    .foregroundStyle(.red)
                } else {
                    IdentifierText(text: model.runReportPath ?? "\u{2014}")
                    Text(
                        "Persisted under the reports/ conventions (never overwritten); "
                            + "the plan artifacts remain the durable record."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func outcomeTint(_ outcome: RunItemOutcome) -> Color {
        switch outcome {
        case .applied: return .green
        case .failed: return .red
        case .skipped: return .gray
        case .notRun: return .secondary
        }
    }

    private func statLabel(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func statValue(_ text: String) -> some View {
        Text(text).font(.title3.monospacedDigit().bold())
    }
}
