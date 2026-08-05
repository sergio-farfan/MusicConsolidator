// CleanupTabView.swift
// Wave B (B3) — the third browser tab: evidence-discovered cleanup
// candidates on the left (per-copy rows with counts and dispositions;
// disqualified groups grayed with their verbatim reason), the shared
// MutationGateView on the right. Selecting a candidate runs the gate-arm
// re-check (startCleanupAudit) and the gate pane takes over: evidence
// panel, ONE typed group-name token, per-copy execution progress, and the
// fail-closed result — all Task 13 surfaces, rendered unchanged.
//
// Composition rules carried from SourceBrowserView/SourceSelectionView:
// AppKit-backed load-bearing buttons (offscreen-introspectable), explicit
// lineLimit on every multiline Text, no fixedSize on long text.

import SwiftUI
import AppKit
import ConsolidatorCore
import MusicBridge

@MainActor
struct CleanupTabView: View {
    @Bindable var model: AuditFlowModel

    var body: some View {
        HStack(spacing: 0) {
            candidateColumn
                .frame(minWidth: 320, maxWidth: .infinity)
                .layoutPriority(1)
            Divider()
            // Wave C hotfix (2026-08-04): was a FIXED `.frame(width: 480)` —
            // a pane that could never compress, the M8 defect class. The
            // gate's own content is a ScrollView with an internal
            // maxWidth: 880 (MutationGateView.swift), so it compresses fine
            // down to this floor; NarrowWindowStructuralTests pins the
            // whole composition fits at 900x620.
            MutationGateView(model: model)
                .frame(minWidth: 340, idealWidth: 480, maxWidth: 520)
        }
    }

    // MARK: candidate column

    private var candidateColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Post-merge cleanup")
                    .font(.headline)
                Spacer()
                AppKitActionButton(
                    identifier: WaveBControlID.cleanupRefresh,
                    title: "Refresh"
                ) {
                    model.refreshCleanup()
                }
                .disabled(
                    model.isMutationBusy || model.isRunning || model.isScanning
                        || model.isApplying || model.isUnattendedRunActive
                )
                .help("Re-scan reports/ evidence against one fresh live listing; full verification runs when you open a group's gate.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            scanContent
        }
    }

    @ViewBuilder
    private var scanContent: some View {
        switch model.cleanupScanState {
        case .idle:
            VStack(alignment: .leading, spacing: 6) {
                Text("Candidates are discovered from reports/ merge-plan evidence, never guesswork.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text("Refresh reads the artifacts and one fresh live listing (read-only); opening a group's gate re-verifies it fully.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .scanning(let started):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning cleanup evidence\u{2026}")
                        .bold()
                    Text("elapsed \(ProgressPhaseView.elapsedText(from: started, to: context.date))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Cleanup scan failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .bold()
                Text(message)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .loaded(let candidates, _):
            candidateList(candidates)
        }
    }

    private func candidateList(_ candidates: [CleanupCandidate]) -> some View {
        List {
            if candidates.isEmpty {
                Text("No cleanup candidates: no merge-plan group has surviving live copies.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            ForEach(candidates) { candidate in
                Section {
                    candidateHeader(candidate)
                    ForEach(candidate.copies, id: \.persistentID) { copy in
                        copyRow(copy)
                            .opacity(candidate.disqualification == nil ? 1 : 0.55)
                    }
                    if let reason = candidate.disqualification {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func candidateHeader(_ candidate: CleanupCandidate) -> some View {
        HStack(spacing: 8) {
            BrowserNameText(name: candidate.groupName)
                .opacity(candidate.disqualification == nil ? 1 : 0.55)
            Chip(
                text: "x\(candidate.copies.count)",
                tint: candidate.disqualification == nil ? .blue : .gray
            )
            if candidate.disqualification == nil {
                Chip(
                    text: candidate.targetPresent
                        ? "target present \u{2014} verified at gate" : "target unverified",
                    tint: candidate.targetPresent ? .green : .orange
                )
            } else {
                Chip(text: "not a candidate", tint: .gray)
            }
            Spacer()
            AppKitActionButton(
                identifier: WaveBControlID.cleanupOpenGate(candidate.planFileName),
                title: "Clean up\u{2026}"
            ) {
                model.startCleanupAudit(planFileName: candidate.planFileName)
            }
            .disabled(
                candidate.disqualification != nil || model.isMutationBusy
                    || model.isRunning || model.isScanning || model.isApplying
                    || model.isUnattendedRunActive
            )
            .help(
                "One typed approval covers ONLY this group's source copies; "
                    + "each copy is still one guarded compiled execution with "
                    + "readback between copies."
            )
        }
    }

    private func copyRow(_ copy: CleanupCopyStatus) -> some View {
        HStack(spacing: 8) {
            BrowserNameText(name: copy.name)
            Text(trackCountText(copyCounts: [copy.trackCount]))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            IdentifierText(text: copy.persistentID)
            Spacer()
            dispositionView(copy.disposition)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func dispositionView(_ disposition: CleanupCopyStatus.Disposition) -> some View {
        switch disposition {
        case .live:
            Chip(text: "live", tint: .green)
        case .alreadyDeleted:
            Chip(text: "already deleted (recorded)", tint: .gray)
        case .drifted(let reason):
            HStack(spacing: 6) {
                Chip(text: "drifted", tint: .orange)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
