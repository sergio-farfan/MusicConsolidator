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
            allPlaylistsSection
        }
    }

    // MARK: all playlists (general guarded deletion; Sergio, 2026-08-05)

    /// Every live playlist, deletable behind the SAME Wave B gate the
    /// Library inspector uses — nothing new mutates; refusals surface as
    /// disabled buttons with the verbatim reason as the tooltip.
    @ViewBuilder
    private var allPlaylistsSection: some View {
        HStack(spacing: 8) {
            Text("All playlists")
                .font(.headline)
            BrowserSortHeader(model: model)
            Spacer()
            if !model.checkedCleanupPIDs.isEmpty {
                AppKitActionButton(
                    identifier: WaveBControlID.cleanupDeleteSelected,
                    title: "Delete selected (\(model.checkedCleanupPIDs.count))\u{2026}",
                    help: "One typed approval \u{2014} the selection count \u{2014} "
                        + "covers the batch; every playlist is still its own guarded, "
                        + "verified deletion."
                ) {
                    model.startBatchDeleteAudit(
                        persistentIDs: Array(model.checkedCleanupPIDs)
                    )
                }
                .disabled(
                    model.isMutationBusy || model.isRunning || model.isScanning
                        || model.isApplying || model.isUnattendedRunActive
                )
                AppKitActionButton(
                    identifier: WaveBControlID.cleanupClearSelection,
                    title: "Clear"
                ) {
                    model.clearCleanupSelection()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        if let loaded = model.loadedListing {
            let needle = model.searchText.lowercased()
            let rows = applyBrowserSort(
                loaded.listings.filter {
                    needle.isEmpty || $0.name.lowercased().contains(needle)
                },
                key: model.browserSortKey,
                ascending: model.browserSortAscending,
                count: { $0.trackCount }
            )
            List {
                ForEach(rows, id: \.persistentId) { listing in
                    let refusal = AuditFlowModel.mutationEntryRefusalReason(listing)
                    HStack(spacing: 8) {
                        AppKitCheckbox(
                            identifier: WaveBControlID.cleanupCheckbox(listing.persistentId),
                            isOn: model.checkedCleanupPIDs.contains(listing.persistentId),
                            help: refusal
                                ?? "Select for batch deletion (one typed approval per batch)."
                        ) {
                            model.toggleCleanupChecked(listing.persistentId)
                        }
                        .disabled(refusal != nil)
                        BrowserNameText(name: listing.name)
                        Text(trackCountText(copyCounts: [listing.trackCount]))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        IdentifierText(text: listing.persistentId)
                        Spacer()
                        AppKitActionButton(
                            identifier: WaveBControlID.cleanupDelete(listing.persistentId),
                            title: "Delete\u{2026}",
                            help: refusal ?? "One guarded, typed-confirmation deletion."
                        ) {
                            model.startMutationAudit(
                                kind: .delete, persistentID: listing.persistentId
                            )
                        }
                        .controlSize(.mini)
                        .disabled(
                            refusal != nil || model.isMutationBusy || model.isRunning
                                || model.isScanning || model.isApplying
                                || model.isUnattendedRunActive
                        )
                    }
                }
            }
            .listStyle(.inset)
        } else {
            Text("Rescan the library to list playlists here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(12)
        }
    }





}
