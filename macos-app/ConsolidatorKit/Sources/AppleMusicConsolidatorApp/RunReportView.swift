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

    /// Resizable height for the judgment log box (drag grabber below it).
    @State private var judgmentBoxHeight: CGFloat = 180
    @State private var judgmentDragBase: CGFloat?

    var body: some View {
        if let report = model.finishedRunReport {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryPanel(report)
                    if report.judgmentItemCount > 0 {
                        judgmentPanel(report)
                    }
                    itemsPanel(report)
                    // The report file itself is engine plumbing: it stays on
                    // disk under reports/ (Cleanup discovery and the delete
                    // accounting consume it as evidence) but the app never
                    // shows a filesystem path. The panel renders ONLY in the
                    // loud persistence-failure case; Save report… below
                    // exports a copy anywhere the user wants.
                    if model.runReportWriteFailure != nil {
                        artifactFailurePanel
                    }
                }
                .padding(20)
                .frame(maxWidth: 880, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    AppKitActionButton(
                        identifier: M11ControlID.reportDone,
                        title: "OK",
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
                        title: "Save report\u{2026}"
                    ) {
                        guard let path = model.runReportPath else { return }
                        let source = URL(fileURLWithPath: path)
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = source.lastPathComponent
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let destination = panel.url {
                            try? FileManager.default.removeItem(at: destination)
                            try? FileManager.default.copyItem(at: source, to: destination)
                        }
                    }
                    .disabled(model.runReportPath == nil)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
            // Final fix wave, Finding C1: this screen's per-row "Delete
            // leftover target…" shortcut now stages a direct delete
            // confirmation, and this is a separate navigation destination —
            // without its own anchor the confirmation (and any failure) would
            // have nowhere to present. Shared modifier, so the condition and
            // dismiss rule match every other anchor (Finding I1).
            .directMutationSheet(model: model)
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
                Label("Processing Report", systemImage: "checklist.checked")
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
                        + "read, drift refusal, fingerprint check, readback "
                        + "verification, never-repair, one apply per check."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    /// Informational record of everything the run decided on its own — the
    /// run is DONE; nothing here is pending (wording per Sergio, 2026-08-05).
    private func judgmentPanel(_ report: BatchRunReport) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "Playlists Processing Output Log",
                    systemImage: "checklist"
                )
                .foregroundStyle(.secondary)
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
        let contentEstimate = CGFloat(lines.count) * 22 + 18
        return VStack(spacing: 3) {
            ScrollView([.vertical, .horizontal]) {
                Text(lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: min(judgmentBoxHeight, contentEstimate))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            if contentEstimate > 120 {
                judgmentResizeGrabber
            }
        }
    }

    /// Drag handle below the log box (Sergio, 2026-08-06): dragging adjusts
    /// the box height, clamped so it can neither vanish nor swallow the
    /// screen. Display-only state.
    private var judgmentResizeGrabber: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.quaternary)
            .frame(width: 64, height: 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if judgmentDragBase == nil { judgmentDragBase = judgmentBoxHeight }
                        judgmentBoxHeight = min(
                            700, max(100, (judgmentDragBase ?? judgmentBoxHeight)
                                + value.translation.height)
                        )
                    }
                    .onEnded { _ in judgmentDragBase = nil }
            )
            .help("Drag to resize the log")
    }

    private func itemsPanel(_ report: BatchRunReport) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Action Summary")
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
                        if let note = item.note {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
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

    /// LOUD persistence-failure panel only (fix round 1, minor a): the
    /// report is the mandatory artifact — a persistence failure is a red
    /// headline with the verbatim reason, never a footnote. The SUCCESS case
    /// renders nothing here: the on-disk artifact is engine plumbing, and
    /// "Save report…" is the user-facing affordance.
    private var artifactFailurePanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                if let failure = model.runReportWriteFailure {
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
