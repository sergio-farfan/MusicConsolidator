// CleanupTabView.swift
// Wave B (B3) — the third browser tab: every live playlist, deletable and
// renamable directly (Sergio, 2026-08-06). The evidence-discovered gate pane
// is retired from this composition: Delete and Rename... on a row (or
// Delete selected... on a batch) stage a `pendingDirectAction` and the
// shared `DirectMutationSheets` confirm/rename/error sheet is the only
// thing standing between a click and the guarded AppleScript writer.
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
        // Finding I1: the shared anchor — presented through the whole
        // dispatch, so a failure replaces the in-progress panel in place
        // instead of re-presenting a sheet that is animating out.
        candidateColumn
            .directMutationSheet(model: model)
    }

    // MARK: candidate column

    private var candidateColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            allPlaylistsSection
        }
    }

    // MARK: all playlists (direct deletion/rename; Sergio, 2026-08-06)

    /// Every live playlist, deletable and renamable directly — ZERO refusal
    /// filtering (smart playlists, folders, even the contract-excluded pilot
    /// are all actionable here); the confirm/rename sheet is the only gate.
    @ViewBuilder
    private var allPlaylistsSection: some View {
        HStack(spacing: 8) {
            Text("All playlists")
                .font(.headline)
            BrowserSortHeader(model: model)
            Spacer()
            // Sergio, 2026-08-06: the batch controls live in the shared
            // footer bar now (SourceSelectionView.cleanupFooter), matching
            // the merge/consolidate bottom-bar anatomy.
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
                    HStack(spacing: 8) {
                        AppKitCheckbox(
                            identifier: WaveBControlID.cleanupCheckbox(listing.persistentId),
                            isOn: model.checkedCleanupPIDs.contains(listing.persistentId),
                            help: "Select for batch deletion."
                        ) {
                            model.toggleCleanupChecked(listing.persistentId)
                        }
                        BrowserNameText(name: listing.name)
                        Text(trackCountText(copyCounts: [listing.trackCount]))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        AppKitActionButton(
                            identifier: WaveBControlID.cleanupDelete(listing.persistentId),
                            title: "Delete",
                            help: "One confirmation deletes this playlist."
                        ) {
                            model.requestDirectDelete(persistentIDs: [listing.persistentId])
                        }
                        .controlSize(.mini)
                        .disabled(
                            model.isMutationBusy || model.isRunning
                                || model.isScanning || model.isApplying
                                || model.isUnattendedRunActive
                        )
                        AppKitActionButton(
                            identifier: DirectControlID.rowRename(listing.persistentId),
                            title: "Rename\u{2026}"
                        ) {
                            model.requestDirectRename(
                                persistentID: listing.persistentId, prefilledName: nil
                            )
                        }
                        .controlSize(.mini)
                        .disabled(
                            model.isMutationBusy || model.isRunning
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
