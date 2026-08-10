// SourceSelectionView.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Screen 1 — M8 sectioned source browser (Option B), recomposed in fix
// round 2. The typed playlist name is REPLACED by the browsable listing:
// Merge tab = checkbox-per-group batch queue (M10); highlight = inspection;
// Consolidate tab = checkboxes building the batch queue. The listing comes
// from the STATIC enumeration script (read-only); nothing here can write to
// Music.
//
// Fix round 2 composition rules (each one is load-bearing; the offscreen
// structural tests pin them):
// - NO `.toolbar` / `.searchable` on the detail content: the mode picker,
//   filter field, and scan control live in a content-level header bar, so
//   the composition matches the M7-proven "plain content in the detail
//   column" posture and every load-bearing control is AppKit-backed and
//   introspectable (AppKitControls.swift).
// - NO `.fixedSize(horizontal: false, vertical: true)` on long text
//   anywhere in this hierarchy: during the split view's width negotiation
//   SwiftUI proposes near-zero widths, a fixedSize text then reports its
//   fully-wrapped height (thousands of points), NSHostingView adopts that
//   as the REQUIRED minimum height, and the whole screen renders taller
//   than the window — center-cropped, header above the toolbar, footer
//   below the bottom, scrollbar out of bounds (the exact live failure).
//   Text in VStacks wraps fine without it.
// - Scanning is explicit (never automatic on launch): the first Apple
//   event — and the TCC consent prompt — fires only on the user's own
//   Scan click.

import SwiftUI
import ConsolidatorCore

@MainActor
struct SourceSelectionView: View {
    @Bindable var model: AuditFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            browserArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private var scanButtonTitle: String {
        model.loadedSections == nil ? "Scan Library (read-only)" : "Rescan"
    }

    private var mergeStartQueueTitle: String {
        let count = model.checkedGroupNames.count
        return count == 0 ? "Merge" : "Merge \(count) groups"
    }

    private var consolidateStartQueueTitle: String {
        let count = model.checkedPersistentIds.count
        return count == 0 ? "Consolidate" : "Consolidate \(count) playlists"
    }

    // MARK: mode/tab pill selector

    private var tabPillSelector: some View {
        HStack(spacing: 4) {
            ForEach(BrowserTab.allCases) { tab in
                ZStack {
                    if model.browserTab == tab {
                        Capsule().fill(Color.accentColor.opacity(0.22))
                    }
                    AppKitActionButton(
                        identifier: WaveBControlID.tabPill(tab),
                        title: tab.displayName,
                        compressible: true,
                        systemImage: tabSymbolName(tab)
                    ) {
                        model.setBrowserTab(tab)
                    }
                    .padding(2)
                }
            }
        }
        // Wave C hotfix (2026-08-04): was a FIXED `.frame(width: 320)` on
        // the segmented control it replaced — compresses down to 240
        // instead of forcing the header past a narrow window's width.
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
        .disabled(
            model.isRunning || model.isQueueActive || model.isApplying
                || model.isMutationBusy
        )
    }

    private func tabSymbolName(_ tab: BrowserTab) -> String {
        switch tab {
        case .merge: return "arrow.triangle.merge"
        case .consolidate: return "rectangle.stack"
        case .cleanup: return "sparkles"
        }
    }

    // MARK: header (mode tabs + filter + scan)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Mode changes route through the model's guarded setter
                // (fix round 1, finding 1): a mid-apply flip would orphan
                // the guarded write's outcome, so the model refuses it AND
                // the pill selector disables during an apply.
                tabPillSelector

                AppKitFilterField(
                    identifier: M8ControlID.filterField,
                    placeholder: "Filter playlists",
                    text: $model.searchText
                )
                // Wave C hotfix: was a fixed `.frame(width: 220)`.
                .frame(minWidth: 120, idealWidth: 160, maxWidth: 220)

                AppKitActionButton(
                    identifier: M8ControlID.scanLibrary,
                    title: scanButtonTitle
                ) {
                    model.rescanLibrary()
                }
                .disabled(model.isScanning || model.isRunning)
                .help("Re-run the read-only playlist enumeration.")

                Spacer()

                if let loaded = model.loadedListing {
                    // M11: staleness indicator — the cache serves the
                    // browser only; Refresh (the Rescan control) is live.
                    HStack(spacing: 6) {
                        Text(
                            "\(loaded.listings.count) playlists \u{B7} "
                                + listingStalenessText(scannedAt: loaded.scannedAt, now: Date())
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if loaded.fromCache {
                            Chip(text: "cached", tint: .orange)
                                .help(
                                    "Restored from the local cache for instant "
                                        + "startup. Reads and applies ALWAYS re-read "
                                        + "Music live; Rescan refreshes this list."
                                )
                        }
                    }
                }
            }
            Text(modeCaption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modeCaption: String {
        if model.browserTab == .cleanup {
            return "Delete or rename any playlist directly. Deleting a "
                + "playlist never removes songs from your library."
        }
        switch model.mode {
        case .consolidate:
            return "Consolidate checks ONE single-copy playlist for strict duplicates. "
                + "Check playlists to build a batch queue \u{2014} every item still gets "
                + "its own plan review, confirm gate, and apply."
        case .merge:
            return "Merge operates on exact-same-name groups ONLY: check the groups "
                + "to queue \u{2014} every group still gets its own plan review, confirm "
                + "gate, and apply. Near matches are never mergeable \u{2014} rename "
                + "them in Music first."
        }
    }

    // MARK: browser area

    /// The idle / scanning / failed states are shared by ALL three tabs
    /// (Sergio, 2026-08-06: Cleanup previously bypassed this switch and
    /// showed its empty caption inside a full-height void while a scan was
    /// in flight). Only a loaded listing routes to the Cleanup list.
    @ViewBuilder
    private var browserArea: some View {
        if case .loaded = model.listingState, model.browserTab == .cleanup {
            CleanupTabView(model: model)
        } else {
            existingBrowserArea
        }
    }

    @ViewBuilder
    private var existingBrowserArea: some View {
        switch model.listingState {
        case .idle:
            VStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Scan the library to browse playlists")
                    .font(.headline)
                Text(
                    "The scan is a read-only enumeration (name, persistent ID, and "
                        + "track count per playlist). Nothing is modified. Use "
                        + "Scan Library above."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .scanning(let started):
            // Same centered anatomy as the idle state: spinner, status line,
            // caption. The status label is AppKit-backed so the structural
            // tests can pin this state on every tab (SwiftUI Text publishes
            // no NSView); fixedSize keeps the short single-line label hugging
            // its content instead of stretching the row edge-to-edge.
            VStack(spacing: 10) {
                ProgressView()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 8) {
                        AppKitStaticText(
                            identifier: WaveC2ControlID.browserScanningStatus,
                            text: "Scanning library\u{2026}",
                            maximumLines: 1
                        )
                        .fixedSize()
                        Text("elapsed \(ProgressPhaseView.elapsedText(from: started, to: context.date))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                }
                Text("One enumeration pass over every user playlist; no tracks are read.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 8) {
                Label(failure.category, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .bold()
                Text(failure.message)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Button("Retry scan") { model.rescanLibrary() }
                    .disabled(model.isScanning || model.isRunning)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .loaded(let loaded):
            let sections = filteredSections(loaded.sections, query: model.searchText)
            HStack(spacing: 0) {
                Group {
                    switch model.mode {
                    case .merge:
                        MergeBrowserList(model: model, sections: sections)
                    case .consolidate:
                        ConsolidateBrowserList(model: model, sections: sections)
                    }
                }
                // Wave C hotfix (2026-08-04): was minWidth 420; lowered so
                // the list keeps a usable row width (checkbox + name + chip
                // + count) without forcing the whole detail past a narrow
                // window.
                .frame(minWidth: 280, maxWidth: .infinity)
                .layoutPriority(1)
                .disabled(model.isRunning)
                Divider()
                BrowserInspector(model: model, sections: sections)
                    // Wave C hotfix: was a FIXED `.frame(width: 300)` — the
                    // same "SourceBrowserView inspector" fixed-width pane
                    // the hotfix's known-contributors list called out;
                    // treated identically to CleanupTabView's gate pane.
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 320)
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.browserTab == .cleanup {
                cleanupFooter
            } else {
                switch model.mode {
                case .merge:
                    mergeFooter
                case .consolidate:
                    consolidateFooter
                }
            }
            runStatus
        }
    }

    /// Sergio, 2026-08-06: Cleanup gets the same bottom-bar anatomy as the
    /// other modes — count on the left, primary action on the right, always
    /// visible (disabled at zero, like Start Queue). The batch controls
    /// moved here from the tab header.
    @ViewBuilder
    private var cleanupFooter: some View {
        HStack(spacing: 12) {
            Text("Selected: \(model.checkedCleanupPIDs.count) playlists")
                .bold()
            Spacer()
            AppKitActionButton(
                identifier: WaveBControlID.cleanupClearSelection,
                title: "Clear"
            ) {
                model.clearCleanupSelection()
            }
            .disabled(model.checkedCleanupPIDs.isEmpty)
            AppKitActionButton(
                identifier: WaveBControlID.cleanupDeleteSelected,
                title: "Delete selected (\(model.checkedCleanupPIDs.count))",
                prominent: true,
                help: "One confirmation covers the whole selection."
            ) {
                model.requestDirectDelete(
                    persistentIDs: Array(model.checkedCleanupPIDs)
                )
            }
            .disabled(
                model.checkedCleanupPIDs.isEmpty || model.isMutationBusy
                    || model.isRunning || model.isScanning || model.isApplying
                    || model.isUnattendedRunActive
            )
        }
    }

    /// M10: the merge footer mirrors the consolidate footer — the queue is
    /// the ONE path (a single merge is a one-group queue); the M8 arming
    /// footer is superseded. The Start Queue control shares its id with the
    /// consolidate footer's (exactly one renders at a time).
    @ViewBuilder
    private var mergeFooter: some View {
        if model.isQueueActive {
            QueueRailView(model: model)
        } else {
            HStack(spacing: 12) {
                // Sergio, 2026-08-06: same noun as the consolidate footer —
                // each queued group produces exactly one merged playlist.
                Text("Queued: \(model.checkedGroupNames.count) playlists")
                    .bold()
                Spacer()
                AppKitActionButton(
                    identifier: M8ControlID.startQueue,
                    title: mergeStartQueueTitle,
                    prominent: true
                ) {
                    model.startQueue()
                }
                .disabled(
                    model.checkedGroupNames.isEmpty
                        || model.loadedSections == nil
                        || model.isRunning
                        || model.isScanning
                        || model.isApplying
                )
                if model.isRunning {
                    AppKitActionButton(
                        identifier: M8ControlID.cancelAudit,
                        title: "Cancel"
                    ) {
                        model.cancelAudit()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var consolidateFooter: some View {
        if model.isQueueActive {
            QueueRailView(model: model)
        } else {
            HStack(spacing: 12) {
                Text("Queued: \(model.checkedPersistentIds.count) playlists")
                    .bold()
                Spacer()
                AppKitActionButton(
                    identifier: M8ControlID.startQueue,
                    title: consolidateStartQueueTitle,
                    prominent: true
                ) {
                    model.startQueue()
                }
                .disabled(
                    model.checkedPersistentIds.isEmpty
                        || model.loadedSections == nil
                        || model.isRunning
                        || model.isScanning
                        || model.isApplying
                )
                if model.isRunning {
                    AppKitActionButton(
                        identifier: M8ControlID.cancelAudit,
                        title: "Cancel"
                    ) {
                        model.cancelAudit()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var runStatus: some View {
        switch model.runState {
        case .idle:
            EmptyView()
        case .running(let phase):
            ProgressPhaseView(phase: phase)
        case .cancelled:
            Label {
                Text(
                    "Cancelled. Nothing was applied; any artifacts already "
                        + "written remain on disk (they are never overwritten)."
                )
            } icon: {
                Image(systemName: "xmark.circle")
            }
            .foregroundStyle(.secondary)
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 4) {
                Label(failure.category, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .bold()
                // Verbatim: the package error types are message-bearing by
                // design; nothing is paraphrased.
                Text(failure.message)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}
