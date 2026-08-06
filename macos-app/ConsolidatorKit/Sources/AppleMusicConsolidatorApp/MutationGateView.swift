// MutationGateView.swift
// Wave B (B2/B4/B5/B6) — the shared delete/rename mutation gate surface.
// Renders AuditFlowModel.mutationGatePhase end to end: the fresh-snapshot
// facts, the evidence panel (cleanup plans carry MutationEvidence), the
// typed identity tokens, the rename collision warning, live execution
// progress (spinner + ticking elapsed — never a bare spinner), and the
// fail-closed outcome with a HEIGHT-CAPPED verbatim mismatch panel.
//
// Token fields: the required value is SELECTABLE TEXT ABOVE an EMPTY field,
// never the field's placeholder — a placeholder echoing the expected answer
// reads as already-filled, the exact trap from the live walkthrough that
// the confirm gate fixed (ConfirmGateView.swift, "M8 walkthrough fix").
// Typed input is bound raw and never normalized.
//
// Load-bearing controls are AppKit-backed (AppKitActionButton,
// AppKitTokenField, AppKitStaticText) so the offscreen structural tests can
// locate them by identifier; every multiline SwiftUI Text carries an
// explicit lineLimit (both known layout-blowout mechanisms).
//
// B6: while an unattended run is active the whole gate is replaced by an
// explicit notice — nothing interactive renders.

import SwiftUI
import AppKit
import ConsolidatorCore
import MusicBridge

@MainActor
struct MutationGateView: View {
    @Bindable var model: AuditFlowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(20)
            .frame(maxWidth: 880, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                AppKitActionButton(
                    identifier: WaveBControlID.mutationDismiss,
                    title: dismissTitle
                ) {
                    model.dismissMutationGate()
                }
                .disabled(model.isMutationBusy)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    /// The armed BATCH-delete context (user-selected set): the cleanup
    /// context with no target guard. The evidence-group flow always carries
    /// a target guard; single mutations never set the context at all.
    private var batchDeleteContext: AuditFlowModel.CleanupGroupContext? {
        model.cleanupContext.flatMap { $0.targetGuard == nil ? $0 : nil }
    }

    private var dismissTitle: String {
        if case .armed = model.mutationGatePhase {
            return "Cancel \u{2014} consume this artifact"
        }
        return "Close"
    }

    @ViewBuilder
    private var content: some View {
        if model.isUnattendedRunActive {
            unattendedNotice
        } else {
            switch model.mutationGatePhase {
            case .idle:
                ContentUnavailableView(
                    "No mutation armed",
                    systemImage: "lock.shield",
                    description: Text(
                        "Start Delete\u{2026} or Rename\u{2026} from a browser row; "
                            + "the gate arms after a fresh safety check."
                    )
                )
            case .auditing(let started):
                auditingPanel(started: started)
            case .armed(let state):
                if let batch = batchDeleteContext {
                    batchPanel(batch)
                } else {
                    snapshotPanel(state: state)
                }
                if let evidence = state.plan.evidence {
                    evidencePanel(evidence)
                }
                if let warning = state.collisionWarning {
                    collisionPanel(warning)
                }
                tokensPanel(state: state)
                executePanel(state: state)
            case .executing(let progress):
                executingPanel(progress)
            case .finished(let display):
                finishedPanel(display)
            case .refused(let reason):
                refusedPanel(reason)
            }
        }
    }

    // MARK: unattended lockout (B6)

    private var unattendedNotice: some View {
        GroupBox {
            Label {
                AppKitStaticText(
                    identifier: WaveBControlID.unattendedNotice,
                    text: "Mutations are disabled while an unattended run is active: "
                        + "delete and rename never run inside any unattended run. "
                        + "Finish or stop the run first.",
                    maximumLines: 3
                )
            } icon: {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: auditing

    private func auditingPanel(started: Date) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Running the safety check\u{2026}")
                            .bold()
                        Text("elapsed \(ProgressPhaseView.elapsedText(from: started, to: context.date))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text(
                    "Fresh listing + fresh snapshot \u{2192} reviewable reports/ "
                        + "artifact. Read-only: nothing mutates until the typed gate "
                        + "below is satisfied and dispatched."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: snapshot facts

    /// Batch delete (AGENTS.md exception 2): every selected playlist,
    /// pinned by persistent ID; the typed token is the selection count.
    private func batchPanel(_ batch: AuditFlowModel.CleanupGroupContext) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label("Delete \(batch.plans.count) Playlists", systemImage: "trash")
                    .font(.headline)
                ForEach(batch.plans, id: \.playlistPersistentID) { plan in
                    HStack(spacing: 8) {
                        BrowserNameText(name: plan.playlistName)
                        Text("\(plan.trackCount) tracks")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        IdentifierText(text: plan.playlistPersistentID)
                        Spacer()
                    }
                    .font(.callout)
                }
                Text("Deleting a playlist never removes songs from the library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func snapshotPanel(state: AuditFlowModel.MutationGateState) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    state.plan.kind == .delete ? "Delete Playlist" : "Rename Playlist",
                    systemImage: state.plan.kind == .delete ? "trash" : "pencil"
                )
                .font(.headline)
                LabeledContent("Name") {
                    BrowserNameText(name: state.plan.playlistName)
                }
                LabeledContent("Persistent ID") {
                    IdentifierText(text: state.plan.playlistPersistentID)
                }
                LabeledContent("Tracks") {
                    Text("\(state.plan.trackCount) tracks")
                        .monospacedDigit()
                }
                if let destination = state.plan.newName {
                    LabeledContent("Rename to") {
                        BrowserNameText(name: destination)
                    }
                }
                if state.plan.kind == .delete {
                    Text("Deleting a playlist never removes songs from the library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: evidence (cleanup)

    private func evidencePanel(_ evidence: MutationEvidence) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Evidence")
                    .font(.headline)
                LabeledContent("Merge plan") {
                    IdentifierText(text: evidence.mergePlanFileName)
                }
                if let report = evidence.runReportFileName {
                    LabeledContent("Run report") {
                        IdentifierText(text: report)
                    }
                }
                Text(evidence.verificationNote)
                    .font(.caption)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: collision warning (rename; B5 — never a block)

    private func collisionPanel(_ warning: String) -> some View {
        GroupBox {
            Label {
                AppKitStaticText(
                    identifier: WaveBControlID.collisionWarning,
                    text: warning,
                    maximumLines: 4
                )
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: typed identity tokens (B4 unique-identity rule)

    private func tokensPanel(state: AuditFlowModel.MutationGateState) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Typed confirmation \u{2014} identifies this exact persistent ID")
                    .font(.headline)
                tokenField(
                    caption: batchDeleteContext != nil
                        ? "Type the number of playlists selected for deletion"
                        : scalarExact(state.confirmationName, state.plan.playlistName)
                            ? "Type the exact playlist name"
                            : "Type the canonical DESTINATION name \u{2014} the deviant "
                                + "current name stays pinned by persistent ID",
                    required: state.confirmationName,
                    identifier: WaveBControlID.mutationNameField,
                    text: $model.typedMutationName
                )
                if let divergence = model.mutationNameDivergence {
                    Label {
                        Text(describeDivergence(divergence))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    .foregroundStyle(.orange)
                }
                if batchDeleteContext == nil,
                   !scalarExact(state.confirmationName, state.plan.playlistName) {
                    Text(describeNameDifference(
                        reference: state.confirmationName, other: state.plan.playlistName
                    ))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                }
                if state.requiresCountToken {
                    tokenField(
                        caption: "More than one live playlist shares this exact name "
                            + "\u{2014} type this copy's track count",
                        required: String(state.plan.trackCount),
                        identifier: WaveBControlID.mutationCountField,
                        text: $model.typedMutationCount
                    )
                }
                if state.requiresPIDSuffixToken {
                    tokenField(
                        caption: "The track count is ambiguous too \u{2014} type the "
                            + "last 4 characters of the persistent ID",
                        required: String(state.plan.playlistPersistentID.suffix(4)),
                        identifier: WaveBControlID.mutationPIDField,
                        text: $model.typedMutationPIDSuffix
                    )
                }
                Text(
                    "Comparison is Unicode-scalar exact; typed input is never "
                        + "trimmed, folded, or normalized."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    /// One token: caption, then the REQUIRED VALUE as selectable text with a
    /// copy affordance, then the EMPTY AppKit-backed field beneath it. The
    /// field never carries placeholder text.
    private func tokenField(
        caption: String,
        required: String,
        identifier: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.callout)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text("Required:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(required)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                CopyButton(label: "Copy", text: required)
                    .controlSize(.mini)
            }
            if !scalarExact(renderNameWithVisibleScalars(required), required) {
                Text(
                    "With invisibles visible: "
                        + "\u{201C}\(renderNameWithVisibleScalars(required))\u{201D}"
                )
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            AppKitTokenField(identifier: identifier, text: text)
        }
    }

    // MARK: execute

    private func executePanel(state: AuditFlowModel.MutationGateState) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    batchDeleteContext != nil
                        ? "Execute \u{2014} Delete \(batchDeleteContext?.plans.count ?? 0) Playlists"
                        : state.plan.kind == .delete
                            ? "Execute \u{2014} Delete Playlist"
                            : "Execute \u{2014} Rename Playlist",
                    systemImage: "play.circle"
                )
                    .font(.headline)
                VStack(alignment: .leading, spacing: 3) {
                    reminderRow(
                        "The artifact is SHA-256-rechecked from disk and the live "
                            + "listing fingerprint re-verified immediately before "
                            + "dispatch; any drift refuses fail-closed."
                    )
                    reminderRow(
                        "Single use: executing or cancelling consumes the artifact "
                            + "\u{2014} nothing can ever re-arm it."
                    )
                    reminderRow(
                        "The writer revalidates the exact name, track count, and "
                            + "ordered track persistent IDs inside the same compiled "
                            + "execution, immediately before the one mutation verb."
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                AppKitActionButton(
                    identifier: WaveBControlID.mutationExecute,
                    title: executeTitle(state: state),
                    prominent: true
                ) {
                    model.executeMutation()
                }
                // Final review, Finding I-1: mirrors executeMutation()'s
                // model guard — never dispatch while a leftover resolve (or
                // any other mutation-busy activity) holds the OSA slot.
                .disabled(
                    !model.mutationGateSatisfied || model.isUnattendedRunActive
                        || model.isMutationBusy
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func executeTitle(state: AuditFlowModel.MutationGateState) -> String {
        if let batch = batchDeleteContext {
            return "Delete \(batch.plans.count) playlists now"
        }
        switch state.plan.kind {
        case .delete:
            return "Delete \u{201C}\(state.plan.playlistName)\u{201D} now"
        case .rename:
            return "Rename to \u{201C}\(state.plan.newName ?? "")\u{201D} now"
        }
    }

    private func reminderRow(_ text: String) -> some View {
        Label {
            Text(text)
                .lineLimit(3)
        } icon: {
            Image(systemName: "info.circle")
        }
    }

    // MARK: executing (spinner + ticking elapsed; the four phases listed)

    private func executingPanel(_ progress: AuditFlowModel.MutationExecutionProgress) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            progress.copyCount > 1
                                ? "Copy \(progress.copyIndex + 1) of \(progress.copyCount): "
                                    + phaseLabel(progress.phase)
                                : phaseLabel(progress.phase)
                        )
                        .bold()
                        .lineLimit(2)
                        Text("elapsed \(ProgressPhaseView.elapsedText(from: progress.startedAt, to: context.date))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(MutationPhase.allCases, id: \.rawValue) { phase in
                    HStack(spacing: 6) {
                        Image(systemName: phaseSymbol(for: phase, current: progress.phase))
                        Text(phaseLabel(phase))
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(phase == progress.phase ? Color.primary : Color.secondary)
                }
                Text(
                    "Uncancellable: the guarded mutation is one atomic operation "
                        + "from the app's view \u{2014} it verifies by readback or "
                        + "fails closed."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func phaseLabel(_ phase: MutationPhase) -> String {
        switch phase {
        case .reValidating: return "Re-validating the fresh listing"
        case .compiling: return "Compiling the guarded writer"
        case .executing: return "Executing the one mutation"
        case .verifyingListing: return "Verifying the full-listing readback"
        }
    }

    private func phaseSymbol(for phase: MutationPhase, current: MutationPhase) -> String {
        let ordered = MutationPhase.allCases
        guard let phaseIndex = ordered.firstIndex(of: phase),
              let currentIndex = ordered.firstIndex(of: current) else { return "circle" }
        if phaseIndex < currentIndex { return "checkmark.circle.fill" }
        if phaseIndex == currentIndex { return "circle.dotted" }
        return "circle"
    }

    // MARK: finished (verified or failed closed)

    private func finishedPanel(_ display: AuditFlowModel.MutationFinishDisplay) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(
                        display.verified
                            ? "Verified: exactly the approved \(display.kind.rawValue) "
                                + "happened \u{2014} and nothing else."
                            : "Failed closed \u{2014} nothing was repaired and nothing retries."
                    )
                    .bold()
                    .lineLimit(3)
                } icon: {
                    Image(systemName: display.verified ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .foregroundStyle(display.verified ? Color.green : Color.red)
                }
                LabeledContent("Playlist") {
                    BrowserNameText(name: display.playlistName)
                }
                if let newName = display.newName {
                    LabeledContent("Renamed to") {
                        BrowserNameText(name: newName)
                    }
                }
                LabeledContent("Consumed artifact") {
                    IdentifierText(text: display.consumedPlanFileName)
                }
                if let path = display.resultReportPath {
                    LabeledContent("Result report") {
                        IdentifierText(text: path)
                    }
                }
                if let failure = display.resultWriteFailure {
                    Label {
                        Text(failure)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(4)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                }
                if !display.mismatches.isEmpty {
                    verbatimList(title: "Verbatim mismatches", lines: display.mismatches)
                }
                if !display.informational.isEmpty {
                    verbatimList(
                        title: "Informational (smart/special-kind count drift)",
                        lines: display.informational
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    /// HEIGHT-CAPPED verbatim panel: long mismatch lists scroll inside a
    /// fixed 160 pt box instead of growing the screen (the layout-blowout
    /// class the structural gate exists to catch).
    private func verbatimList(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
    }

    // MARK: refused

    private func refusedPanel(_ reason: String) -> some View {
        GroupBox {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Refused \u{2014} fail closed")
                        .bold()
                    Text(reason)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(6)
                    Text("Run a fresh check to try again; nothing was mutated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.red)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}
