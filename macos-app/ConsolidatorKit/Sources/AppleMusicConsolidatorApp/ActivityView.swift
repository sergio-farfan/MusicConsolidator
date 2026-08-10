// ActivityView.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Wave C2 (spec C2.2) — the Activity destination: the run surface as a
// state machine rendered by precedence over EXISTING model state (no new
// run state is introduced). Precedence order is load-bearing: during a
// batch, `result` is also non-nil per item, so the unattended surface must
// win.
//
// 1. Unattended run active or paused -> the step-driven run surface
//    verbatim (ApplyFlowView -> UnattendedRunScreen while the run works,
//    step == .apply; the existing judgment-pause screens while paused —
//    the pause's resume/skip/stop affordances live on PlanReviewView and
//    MUST remain reachable; pinned structurally).
// 2. Attended flow (result != nil) -> the staged panel (Task 5 adds the
//    Review/Confirm/Apply chip header over this unchanged step content).
// 3. Run finished (finishedRunReport != nil) -> the report screen,
//    unchanged; the mandatory-report invariant is untouched.
// 4. Idle, RUN-STATE TRUTHFUL (spec C2.2 state 4, controller amendment
//    2026-08-04; final review, Finding I-2): while an attended audit is in
//    flight it renders the existing ProgressPhaseView under a pinned
//    caption — never a false "No run active" over a multi-minute read; a
//    failed or cancelled audit renders its verbatim outcome plus a Back to
//    Library affordance (Retry/Skip/Cancel live on the queue rail in
//    Library); otherwise ContentUnavailableView "No run active" plus the
//    session's last-outcome caption when one exists.
//
// Final review, Finding I-1: a pre-existing "zombie queue" can leave an
// unacknowledged `finishedRunReport` set while precedence 1 or 2 also
// matches (a fresh audit restarted after an early stop). `ActivityView`
// pins a banner above whichever precedence wins in that anomalous case —
// reachability only; it never changes which state renders by default, and
// the report is never destructible except through its existing acknowledged
// paths.
//
// Re-review of Finding I-1 (residual), 2026-08-04: the same zombie queue can
// leave the RESTARTED audit itself running, failed, or cancelled while the
// earlier item's report is still pending. Precedence 3 now additionally
// requires the restarted audit be quiescent (`runState == .idle`) before it
// renders the report directly, so a hot/failed/cancelled restart falls
// through to precedence 4's truthful idle view (Finding I-2) instead of the
// stale report — and the banner guard now covers that case too, keeping the
// report reachable either way.

import SwiftUI
import AppKit

@MainActor
struct ActivityView: View {
    @Bindable var model: AuditFlowModel

    // Final review, Finding I-1: a pre-existing "zombie queue" (finishRun
    // leaving the rail live) lets a fresh attended audit restart while a
    // report from an EARLIER item is still unacknowledged. When that
    // happens, precedence 1 or 2 wins the switch below and the pending
    // report would render nowhere, with no path back to it — the M11
    // mandatory-report invariant's only consumer, deleted by this wave with
    // no replacement. This flag is the replacement: it does not change the
    // precedence order (mainline rendering is untouched), it only adds a
    // way back to a report that precedence would otherwise hide.
    @State private var showPendingReport = false

    var body: some View {
        VStack(spacing: 0) {
            if pendingReportIsHiddenBehindOtherContent {
                pendingReportBanner
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if showPendingReport, model.finishedRunReport != nil {
            pendingReportScreen
        } else if model.isRunUnattended && model.isQueueActive {
            unattendedRunSurface
        } else if model.result != nil {
            ActivityStagedPanel(model: model)
        } else if model.finishedRunReport != nil, isAttendedAuditQuiescent {
            RunReportView(model: model)
        } else {
            ActivityIdleView(model: model)
        }
    }

    /// True exactly when a pending report exists AND is not what `content`
    /// would otherwise render: precedence 1 (the unattended surface) or
    /// precedence 2 (the staged panel) is winning over it, OR — re-review
    /// of Finding I-1 (residual), 2026-08-04 — a restarted attended audit
    /// is actively running, failed, or cancelled, so precedence 4's
    /// run-state-truthful idle view (Finding I-2) must win instead of the
    /// stale report. When none of that holds, `content`'s own precedence 3
    /// already renders the report directly, so no banner is needed.
    private var pendingReportIsHiddenBehindOtherContent: Bool {
        guard model.finishedRunReport != nil, !showPendingReport else { return false }
        if model.isRunUnattended && model.isQueueActive { return true }
        if model.result != nil { return true }
        if !isAttendedAuditQuiescent { return true }
        return false
    }

    /// True only when `runState == .idle`: the restarted attended audit
    /// (the zombie-queue path Finding I-1 covers) is not running, failed,
    /// or cancelled. Re-review of Finding I-1 (residual), 2026-08-04: while
    /// a pending report coexists with a HOT or just-concluded-abnormally
    /// runState, precedence 3 must defer to precedence 4's truthful idle
    /// view (Finding I-2's running/failed/cancelled branches), never render
    /// the stale report over it. `RunState` is `Equatable` (declared at
    /// AuditFlowModel.swift:125); `.idle` is the terminal state after a
    /// successful audit (AuditFlowModel.swift:1372/1773/1868).
    private var isAttendedAuditQuiescent: Bool {
        model.runState == .idle
    }

    private var pendingReportBanner: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                AppKitActionButton(
                    identifier: WaveC2ControlID.pendingReportBanner,
                    title: "View pending run report\u{2026}"
                ) {
                    showPendingReport = true
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.15))
            Divider()
        }
    }

    /// The report, entered via the banner. The report's own Done button
    /// (`M11ControlID.reportDone`) still runs `acknowledgeRunReport()`
    /// unchanged — clearing `finishedRunReport` makes this guard's condition
    /// false on the next render, retiring the toggle along with the report.
    private var pendingReportScreen: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AppKitActionButton(
                    identifier: WaveC2ControlID.pendingReportBack,
                    title: "Back"
                ) {
                    showPendingReport = false
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            RunReportView(model: model)
        }
    }

    /// Precedence 1: today's detail behavior during an unattended run,
    /// container-moved verbatim. `startQueue`/`advanceQueue` force
    /// step == .apply while the run works; the judgment pause sets
    /// step == .review.
    @ViewBuilder
    private var unattendedRunSurface: some View {
        switch model.step {
        case .review:
            PlanReviewView(model: model)
        case .confirm:
            ConfirmGateView(model: model)
        case .source, .apply, .report:
            // .source/.report are unreachable while a run owns the flow
            // (startQueue/advanceQueue force .apply; finishRun ends the run
            // before setting .report) — mapped defensively to the run
            // screen, which ApplyFlowView renders as UnattendedRunScreen.
            ApplyFlowView(model: model)
        }
    }
}

/// Precedence 4 — idle (spec C2.2 state 4, controller amendment
/// 2026-08-04): AUDIT-AWARE, and — final review, Finding I-2 — RUN-STATE
/// TRUTHFUL. `startQueue`/`startAudit` auto-select Activity, so every
/// `runState` case an attended audit can land in in flight must render
/// something true here, never the "No run active" placeholder over an
/// audit that in fact ran and stopped:
///
/// - `.running(phase)` — the live audit progress: `startAudit`
///   auto-navigated the user here, and a "No run active" placeholder over a
///   multi-minute read (~8-9 s + ~0.16 s/track) would be both false and a
///   bare-spinner violation. ProgressPhaseView is reused verbatim from
///   screen 1's footer (spinner + bold phase label + ticking elapsed).
/// - `.failed(failure)` — the verbatim failure (category + message) plus a
///   Back to Library affordance: Retry/Skip/Cancel all live on the queue
///   rail in Library, so the failure surface must point back there rather
///   than dead-end on "No run active".
/// - `.cancelled` — the same Back to Library affordance under a short
///   cancellation note.
/// - `.idle` — unchanged: "No run active" plus one caption line with the
///   session's last finished run outcome, when one exists.
///
/// The outcome caption and the failure text are AppKit-backed
/// (AppKitStaticText) so the structural tests can locate and contain them;
/// maximumLines caps growth (the lineLimit discipline).
///
/// Re-review of Finding I-1 (residual), 2026-08-04: this view is now also
/// what renders when a restarted attended audit is running/failed/cancelled
/// while an EARLIER item's report is still pending — `ActivityView.content`
/// only lets precedence 3 render the report while `runState == .idle`, so
/// these branches stay reachable instead of being hidden behind the stale
/// report; the pending-report banner renders above them in that case.
@MainActor
struct ActivityIdleView: View {
    @Bindable var model: AuditFlowModel

    var body: some View {
        switch model.runState {
        case .running(let phase):
            // The attended audit in flight — the exact presentation
            // screen 1's footer renders for the same RunState case.
            VStack(alignment: .leading, spacing: 8) {
                Text("Reading playlists \u{2014} the gate arms in Activity when the check finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                ProgressPhaseView(phase: phase)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 12) {
                Label(failure.category, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .bold()
                AppKitStaticText(
                    identifier: WaveC2ControlID.activityAuditFailure,
                    text: failure.message,
                    maximumLines: 4
                )
                backToLibraryButton
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .cancelled:
            VStack(alignment: .leading, spacing: 12) {
                Text("Cancelled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                backToLibraryButton
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .idle:
            VStack(spacing: 12) {
                ContentUnavailableView("No run active", systemImage: "play.circle")
                if let summary = model.lastRunSummary {
                    AppKitStaticText(
                        identifier: WaveC2ControlID.activityIdleCaption,
                        text: summary.caption,
                        maximumLines: 2
                    )
                    .frame(maxWidth: 480)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var backToLibraryButton: some View {
        AppKitActionButton(
            identifier: WaveC2ControlID.activityBackToLibrary,
            title: "Back to Library"
        ) {
            model.selectDestination(.library)
        }
    }
}

/// Precedence 2 — the attended staged panel (spec C2.2): Plan review →
/// Confirm gate → Apply as ONE detail view with a stage-chip header. The
/// chips are the old sidebar step rows relocated: `FlowStep`,
/// `canNavigate(to:)`, `hasVisitedReview`, and `stepBlockedReason(for:)`
/// survive verbatim as the panel's internal sequencer — the chips only
/// call `navigate(to:)`, and every gate condition is unchanged.
@MainActor
struct ActivityStagedPanel: View {
    @Bindable var model: AuditFlowModel

    var body: some View {
        VStack(spacing: 0) {
            stageChipHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var stageChipHeader: some View {
        HStack(spacing: 16) {
            stageChip(.review, title: "Review", identifier: WaveC2ControlID.stageReview)
            stageChip(.confirm, title: "Confirm", identifier: WaveC2ControlID.stageConfirm)
            stageChip(.apply, title: "Apply", identifier: WaveC2ControlID.stageApply)
            Spacer()
        }
    }

    /// One relocated row: an AppKit-backed button (the M8 discipline —
    /// NSButton enablement renders the gate introspectably, performClick
    /// exercises the plumbing) plus the shared status capsule. Blocked
    /// chips explain themselves via the sequencer's own reasons.
    private func stageChip(
        _ step: AuditFlowModel.FlowStep, title: String, identifier: String
    ) -> some View {
        HStack(spacing: 6) {
            AppKitActionButton(
                identifier: identifier,
                title: title,
                help: model.stepBlockedReason(for: step) ?? "Go to \(title)."
            ) {
                model.navigate(to: step)
            }
            .disabled(!model.canNavigate(to: step))
            StatusChipView(style: stageStyle(for: step))
        }
    }

    /// The old sidebar's completion marks, restyled through the shared
    /// QueueStatusStyle capsule: current wins, then complete, then pending.
    private func stageStyle(for step: AuditFlowModel.FlowStep) -> QueueStatusStyle {
        if model.step == step {
            return QueueStatusStyle(
                symbolName: "arrow.right.circle.fill", tint: .blue, label: "current"
            )
        }
        if isStageComplete(step) {
            return QueueStatusStyle(
                symbolName: "checkmark.circle.fill", tint: .green, label: "done"
            )
        }
        return QueueStatusStyle(symbolName: "circle.dotted", tint: .gray, label: "pending")
    }

    /// Relocated from the old root's `isStepComplete`, behavior identical
    /// for the three staged steps (.source/.report never render a chip).
    private func isStageComplete(_ step: AuditFlowModel.FlowStep) -> Bool {
        switch step {
        case .review:
            return model.result != nil && model.reviewedPlanToggle
        case .confirm:
            return model.gateSatisfied
        case .apply:
            if case .succeeded = model.applyState { return true }
            return false
        case .source, .report:
            return false
        }
    }

    /// The unchanged attended step content (Task 4's switch, absorbed).
    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .source, .review:
            PlanReviewView(model: model)
        case .confirm:
            ConfirmGateView(model: model)
        case .apply, .report:
            ApplyFlowView(model: model)
        }
    }
}
