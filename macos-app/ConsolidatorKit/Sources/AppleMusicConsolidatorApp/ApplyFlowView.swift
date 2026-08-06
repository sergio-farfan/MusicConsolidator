// ApplyFlowView.swift
// M9 — screens 4-6: apply progress (the guarded sequence streamed as a
// phase list with an elapsed ticker; NO cancel — the guarded write is
// atomic from the app's view), success (the CLI's verification sentence
// contract + next-gate guidance), and fail-closed failure rendering
// (verbatim mismatches monospaced/scrollable/selectable, the never-repair
// notice, non-destructive actions only).
//
// Layout discipline (both pinned blowout classes): every screen's content
// lives in a ScrollView (the proven-bounded context for long fixedSize
// text — the screens-2/3 structural pin), the action bars are pinned via
// safeAreaInset like screens 2/3, NO DisclosureGroup composes here, and the
// tall mismatch list renders inside its own height-capped scroll box. The
// geometry is pinned per state by ApplyStructuralViewTests.

import SwiftUI
import AppKit
import ConsolidatorCore
import MusicBridge

@MainActor
struct ApplyFlowView: View {
    @Bindable var model: AuditFlowModel

    var body: some View {
        // M11: an unattended run owns this surface for its whole duration —
        // audits, applies, and the moments in between.
        if model.isRunUnattended && model.isQueueActive {
            UnattendedRunScreen(model: model)
        } else {
            switch model.applyState {
            case .idle:
                ContentUnavailableView(
                    "No apply yet",
                    systemImage: "play.circle",
                    description: Text(
                        "Complete a check, review its plan, and satisfy the confirm "
                            + "gate (step 3); Apply starts from there."
                    )
                )
            case .running(let stages):
                ApplyProgressScreen(model: model, stages: stages)
            case .succeeded(let success):
                ApplySuccessScreen(model: model, success: success)
            case .failed(let failure):
                ApplyFailureScreen(model: model, failure: failure)
            }
        }
    }
}

// MARK: - M11: the unattended run surface

private struct UnattendedRunScreen: View {
    @Bindable var model: AuditFlowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "\(model.mode == .merge ? "Merge" : "Consolidate") Run "
                                + "\u{2014} \(min(model.queueIndex + 1, model.queue.count)) "
                                + "of \(model.queue.count)",
                            systemImage: "play.circle.fill"
                        )
                        .font(.headline)
                        if let started = model.runStartedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(
                                    "Run elapsed "
                                        + ProgressPhaseView.elapsedText(
                                            from: started, to: context.date
                                        )
                                )
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            }
                        }
                        if let current = model.currentQueueItem {
                            HStack(spacing: 8) {
                                Text("Current:")
                                    .foregroundStyle(.secondary)
                                BrowserNameText(name: current.name)
                                Text(trackCountText(copyCounts: current.copyCounts))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                // Wave A fix wave, finding 2: the SAME
                                // style-map chip the table row below uses,
                                // via the shared derivation — a bare
                                // `Chip(current.status.displayName)` here
                                // bypassed the A1 style map and could
                                // disagree with the table (e.g. showing
                                // "audited" while the row spins "applying").
                                if let state = currentQueueDisplayState(for: model) {
                                    StatusChipView(state: state)
                                }
                            }
                            .font(.callout)
                        }
                        currentActivity
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox {
                    QueueTableView(rows: queueTableRows(for: model))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }

                GroupBox {
                    Label {
                        Text(
                            "Every item is its own fresh live read and guarded, "
                                + "verified apply; failures fail closed and the run "
                                + "continues. The post-run report collects every "
                                + "auto-decided judgment item for review."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                    } icon: {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(.blue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
            .padding(20)
            .frame(maxWidth: 880, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                AppKitActionButton(
                    identifier: M11ControlID.stopRun,
                    title: "Stop after current item"
                ) {
                    model.requestStopAfterCurrentItem()
                }
                Text("The current item always finishes its guarded apply first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var currentActivity: some View {
        if case .running(let phase) = model.runState {
            ProgressPhaseView(phase: phase)
        } else if case .running(let stages) = model.applyState {
            ApplyStageListView(stages: stages)
        } else if model.currentQueueItem?.status == .audited {
            Text(
                "Paused for review (judgment items) \u{2014} finish this item "
                    + "through steps 2\u{2013}3; the run resumes after its apply."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        } else {
            Text("Advancing\u{2026}")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - the per-item stage list (M11: counter + per-step elapsed + total)

/// The guarded sequence as a checklist: "Step k of N", per-step elapsed on
/// completed steps (next start − own start), a ticking clock on the current
/// step, and the item's total elapsed.
struct ApplyStageListView: View {
    let stages: [ApplyStageEntry]

    private var totalStages: Int { 1 + ApplyPhase.allCases.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Step \(stages.count) of \(totalStages)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    stageHeaderCell("Step")
                    stageHeaderCell("Status")
                    stageHeaderCell("Elapsed")
                }
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                ForEach(applyStageRows(stages: stages)) { row in
                    GridRow {
                        stageLabelCell(row)
                        stageStatusCell(row)
                        stageElapsedCell(row)
                    }
                    .padding(.vertical, 3)
                    .font(.callout)
                }
            }
            if let first = stages.first {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(
                        "Item elapsed "
                            + ProgressPhaseView.elapsedText(from: first.started, to: context.date)
                    )
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stageHeaderCell(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .bold()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.vertical, 3)
    }

    @ViewBuilder
    private func stageLabelCell(_ row: ApplyStageRowModel) -> some View {
        switch row.status {
        case .pending:
            Text(row.label)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        case .completed:
            Text(row.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .current:
            Text(row.label)
                .bold()
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func stageStatusCell(_ row: ApplyStageRowModel) -> some View {
        switch row.status {
        case .pending:
            Text("pending")
                .font(.caption)
                .foregroundStyle(.gray)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .current:
            ProgressView()
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func stageElapsedCell(_ row: ApplyStageRowModel) -> some View {
        switch row.status {
        case .pending:
            Text("")
        case .completed(let started, let finishedAt):
            Text(ProgressPhaseView.elapsedText(from: started, to: finishedAt))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        case .current(let started):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(
                    "elapsed "
                        + ProgressPhaseView.elapsedText(from: started, to: context.date)
                )
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - screen 4: apply progress

private struct ApplyProgressScreen: View {
    @Bindable var model: AuditFlowModel
    let stages: [ApplyStageEntry]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Applying \u{2014} one guarded write", systemImage: "play.circle.fill")
                            .font(.headline)
                        ApplyStageListView(stages: stages)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                GroupBox {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No Cancel is offered.")
                                .bold()
                            // Fix round 1, minor c: accurate atomicity copy —
                            // the guarantee is verify-or-fail-closed, not
                            // immunity to force-quit.
                            Text(
                                "The guarded write verifies by readback or fails "
                                    + "closed; force-quitting the app mid-write can "
                                    + "leave a partial target, which is never repaired "
                                    + "automatically \u{2014} re-check to inspect."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                        }
                    } icon: {
                        Image(systemName: "lock.circle")
                            .foregroundStyle(.blue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
            .padding(20)
            .frame(maxWidth: 880, alignment: .leading)
        }
    }

}

// MARK: - screen 5: success

private struct ApplySuccessScreen: View {
    @Bindable var model: AuditFlowModel
    let success: ApplySuccessDisplay

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Applied and verified", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        // The CLI's exact verification sentence contract.
                        Text(applyVerifiedText(mode: success.mode))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)
                        LabeledContent("New playlist") {
                            IdentifierText(text: success.targetName)
                        }
                        LabeledContent("Tracks") {
                            Text(
                                trackCountText(copyCounts: [success.trackCount])
                                    + " (planned \(success.plannedCount))"
                            )
                            .monospacedDigit()
                            .lineLimit(1)
                        }
                        LabeledContent("Fingerprint") {
                            IdentifierText(text: success.fingerprint)
                        }
                        if let seconds = model.lastApplySeconds {
                            LabeledContent("Apply time") {
                                Text(ProgressPhaseView.elapsedText(
                                    from: Date(timeIntervalSinceNow: -seconds), to: Date()
                                ))
                                .monospacedDigit()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Records (the reviewed record of this apply)")
                            .font(.headline)
                        artifactRow(label: "Plan JSON", path: success.paths.planJson)
                        artifactRow(label: "Detail CSV", path: success.paths.detailCsv)
                        artifactRow(label: "Summary Markdown", path: success.paths.summaryMarkdown)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Next gate")
                            .font(.headline)
                        // Next-gate line ported from cli.py verbatim; the
                        // deletion reminder is the documented time-proof
                        // rewording (see applyDeletionReminderText).
                        Text(applyNextGateText(mode: success.mode))
                            .font(.callout)
                            .lineLimit(3)
                        Text(applyDeletionReminderText(mode: success.mode))
                            .font(.callout)
                            .lineLimit(4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
            .padding(20)
            .frame(maxWidth: 880, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                if model.currentQueueItem?.status == .applied {
                    AppKitActionButton(
                        identifier: M9ControlID.applyContinue,
                        title: "Applied \u{2014} continue to next item",
                        prominent: true
                    ) {
                        model.continueQueueAfterApply()
                    }
                    // Final review, Finding I-2 (symmetry): mirrors the
                    // model guard's isMutationBusy addition.
                    .disabled(
                        model.isRunning || model.isScanning || model.isApplying
                            || model.isMutationBusy
                    )
                }
                AppKitActionButton(
                    identifier: M9ControlID.applyStartOver,
                    title: "Start over"
                ) {
                    model.startOver()
                }
                // Fix round 1 (combined Task 4+5 review, Important finding):
                // never navigate away while a leftover resolve (or any other
                // mutation-gate activity) holds the OSA slot.
                .disabled(model.isMutationBusy)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func artifactRow(label: String, path: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)
            IdentifierText(text: path)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .controlSize(.small)
        }
        .font(.callout)
    }
}

// MARK: - screen 6: fail-closed failure rendering

private struct ApplyFailureScreen: View {
    @Bindable var model: AuditFlowModel
    let failure: ApplyFailureDisplay

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(failure.headline, systemImage: "xmark.octagon.fill")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text(failure.guidance)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                        if !failure.message.isEmpty {
                            // The thrown error, VERBATIM.
                            Text(failure.message)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                // Wave C1 (spec C1.4): the library-state class banner and
                // guidance, above the unchanged verbatim mismatch panel.
                // NOTE: `failure.failureClass` below is the M9 DISPLAY class
                // (ApplyFailureDisplayClass); the Wave C taxonomy rides
                // `model.applyFailureClass`.
                if let failureClass = model.applyFailureClass {
                    failureClassPanel(failureClass)
                }

                if failure.failureClass == .automationFailed {
                    automationPanel
                }

                if !failure.mismatches.isEmpty {
                    mismatchesPanel
                }

                if let actualCount = failure.actualCount, actualCount > 0 {
                    partialTargetPanel(actualCount: actualCount)
                }

                neverRepairNotice
            }
            .padding(20)
            .frame(maxWidth: 880, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                if model.currentQueueItem?.status == .failed {
                    AppKitActionButton(
                        identifier: M9ControlID.applyRetry,
                        title: "Retry item",
                        prominent: true
                    ) {
                        model.retryCurrentQueueItem()
                    }
                    // Final review, Finding I-2: mirrors the model guard's
                    // isMutationBusy addition — never retry while this
                    // screen's own leftover resolve is in flight.
                    .disabled(
                        model.isRunning || model.isScanning || model.isApplying
                            || model.isMutationBusy
                    )
                    AppKitActionButton(
                        identifier: M9ControlID.applySkip,
                        title: "Skip item"
                    ) {
                        model.skipCurrentQueueItem()
                    }
                    .disabled(
                        model.isRunning || model.isScanning || model.isApplying
                            || model.isMutationBusy
                    )
                }
                AppKitActionButton(
                    identifier: M9ControlID.applyStartOver,
                    title: "Start over"
                ) {
                    model.startOver()
                }
                // Fix round 1 (combined Task 4+5 review, Important finding):
                // never navigate away while a leftover resolve (this
                // screen's own shortcut, above) or any other mutation-gate
                // activity holds the OSA slot.
                .disabled(model.isMutationBusy)
                AppKitActionButton(
                    identifier: M9ControlID.applyBackToReview,
                    title: "Back to review (read-only)"
                ) {
                    model.navigate(to: .review)
                }
                if model.result != nil {
                    AppKitActionButton(
                        identifier: M9ControlID.applyRevealPlan,
                        title: "Reveal artifacts"
                    ) {
                        if let path = model.result?.paths.planJson {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: path)]
                            )
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
        // Final fix wave, Finding C1: the "Delete leftover target…" shortcut
        // below now stages a direct delete confirmation, and this failure
        // screen is its own navigation destination — neither the Cleanup nor
        // the browser anchor is mounted here, so without this one the
        // confirmation (and any failure) could never present. Shared
        // modifier, so the condition and dismiss rule match every other
        // anchor (Finding I1).
        .directMutationSheet(model: model)
    }

    /// Wave C1 (spec C1.4/C1.5): the class banner (AppKit-backed, exact
    /// label copy), the guidance line, and — for the four leftover-capable
    /// classes with a known target name — the guarded delete shortcut plus
    /// its resolve notice.
    private func failureClassPanel(_ failureClass: ApplyFailureClass) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                AppKitStaticText(
                    identifier: WaveCControlID.failureClassBanner,
                    text: applyFailureClassLabel(failureClass),
                    maximumLines: 3
                )
                Text(applyFailureClassGuidance(failureClass))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if applyFailureClassMayLeaveTarget(failureClass),
                   let targetName = model.targetName {
                    HStack(spacing: 12) {
                        AppKitActionButton(
                            identifier: WaveCControlID.deleteLeftoverTarget,
                            title: "Delete leftover target\u{2026}"
                        ) {
                            model.startDeleteLeftoverTarget(named: targetName)
                        }
                        .disabled(
                            model.isMutationBusy || model.isRunning
                                || model.isScanning || model.isApplying
                                || model.isUnattendedRunActive
                        )
                        if model.isResolvingLeftoverTarget {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    if let notice = model.leftoverResolveNotice {
                        AppKitStaticText(
                            identifier: WaveCControlID.leftoverResolveNotice,
                            text: notice,
                            maximumLines: 3
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    /// Automation class: surface the preflight state (grant; Music running).
    private var automationPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Automation preflight")
                    .font(.headline)
                HStack(spacing: 8) {
                    Button("Check Automation access") { model.runPreflight() }
                        .controlSize(.small)
                        .disabled(model.isPreflightRunning)
                    if model.isPreflightRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let preflight = model.preflight {
                    Label {
                        Text(preflight.displayText)
                            .font(.caption)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    } icon: {
                        Image(systemName: preflight == .granted
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(preflight == .granted ? Color.green : Color.orange)
                    }
                } else {
                    Text(
                        "Not checked in this session. Music must be RUNNING, and this "
                            + "app must hold the Automation grant for Music."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    /// ApplyResult.mismatches VERBATIM: monospaced, scrollable, selectable.
    /// The scroll box is height-capped so even the tall fixture (60+ long
    /// lines) cannot grow the screen (structural pin).
    private var mismatchesPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Verification diagnostics (\(failure.mismatches.count), verbatim)")
                        .font(.headline)
                    Spacer()
                    CopyButton(
                        label: "Copy all",
                        text: failure.mismatches.joined(separator: "\n")
                    )
                    .controlSize(.small)
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(failure.mismatches.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 220)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    /// The partial-target readback evidence, READ-ONLY.
    private func partialTargetPanel(actualCount: Int) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Label("Partial target readback (read-only)", systemImage: "doc.questionmark")
                    .font(.headline)
                LabeledContent("Target tracks found") {
                    Text(
                        "\(actualCount)"
                            + (failure.plannedCount.map { " (planned \($0))" } ?? "")
                    )
                    .monospacedDigit()
                }
                Text(
                    "A target playlist exists in Music but did not verify against the "
                        + "plan. It was only READ \u{2014} inspect it in Music yourself; "
                        + "deleting or fixing it is a manual decision."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var neverRepairNotice: some View {
        GroupBox {
            Label {
                Text("This tool will never delete, rename, or repair a partial target.")
                    .bold()
                    .lineLimit(2)
            } icon: {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.blue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}
