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

    /// The one `.sheet(isPresented:)` binding for `DirectMutationSheets`:
    /// presented while either a pending direct action or a dispatch error is
    /// set; a dismiss (Escape, sheet-swipe) cancels the pending action or
    /// clears the error, whichever is active.
    private var directSheetShown: Binding<Bool> {
        Binding(
            get: { model.pendingDirectAction != nil || model.directMutationError != nil },
            set: { shown in
                guard !shown else { return }
                if model.directMutationError != nil {
                    model.dismissDirectMutationError()
                } else {
                    model.cancelPendingDirectAction()
                }
            }
        )
    }

    var body: some View {
        candidateColumn
            .sheet(isPresented: directSheetShown) {
                DirectMutationSheets(model: model)
            }
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
            if !model.checkedCleanupPIDs.isEmpty {
                AppKitActionButton(
                    identifier: WaveBControlID.cleanupDeleteSelected,
                    title: "Delete selected (\(model.checkedCleanupPIDs.count))",
                    help: "One confirmation covers the whole selection."
                ) {
                    model.requestDirectDelete(
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
                        IdentifierText(text: listing.persistentId)
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
