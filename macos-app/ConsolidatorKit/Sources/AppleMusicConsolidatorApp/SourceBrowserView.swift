// SourceBrowserView.swift
// M8 — the sectioned source browser (design Option B), recomposed in fix
// round 2. Merge tab: an eligibility-sectioned list (MERGEABLE GROUPS /
// NEAR MATCHES / SINGLETONS) where a tap highlights ONE row for the
// inspector, and — since M10 — GROUP rows carry native checkboxes building
// the merge batch queue (near matches and singletons stay non-checkable,
// their checkboxes disabled with an explanation, exactly like consolidate's
// blocked rows). Consolidate tab: the flat alphabetical ALL PLAYLISTS list
// with native checkboxes building the consolidate batch queue (group
// members disabled — the engine fails closed on ambiguous names). A
// trailing inspector explains the selected row; selection for inspection is
// independent of checking for the queue in both tabs.
//
// Fix round 2 rules:
// - The lists carry NO `selection:` binding (the broken composition shipped
//   a second SwiftUI selection list inside the NavigationSplitView, and
//   duplicate same-name `.tag` values multi-highlighted unrelated rows).
//   Selection is explicit: a row tap sets `model.browserSelection`; the
//   highlight derives from it and is row-unique, except that selecting a
//   same-name GROUP highlights all of that group's copies together — that
//   is the intended semantics now (the selection IS the group).
// - Checkboxes are native AppKit checkboxes (AppKitControls.swift) so the
//   offscreen structural tests can see and drive them.
// - No `.fixedSize(horizontal: false, vertical: true)` on long text (see
//   SourceSelectionView's header comment for the layout blowout it causes
//   in this hierarchy).
//
// Names render monospaced and quoted with invisible scalars made visible
// (trailing space as ·, other invisibles as U+XXXX) — the trailing-space
// twin trap from the 2026-08-02 walkthrough can never hide again.

import SwiftUI
import AppKit
import ConsolidatorCore

// MARK: - shared name rendering

/// Quoted, monospaced, invisible-scalar-visible playlist name.
struct BrowserNameText: View {
    let name: String

    var body: some View {
        Text("\u{201C}\(renderNameWithVisibleScalars(name))\u{201D}")
            .font(.system(.body, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

// MARK: - explicit row selection

/// Tap-to-select plus the derived highlight, shared by both tabs.
private struct BrowserRowSelection: ViewModifier {
    @Bindable var model: AuditFlowModel
    let selection: BrowserSelection

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { model.browserSelection = selection }
            .listRowBackground(
                model.browserSelection == selection
                    ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22)
                    : nil
            )
    }
}

extension View {
    fileprivate func browserRow(
        _ model: AuditFlowModel,
        selects selection: BrowserSelection
    ) -> some View {
        modifier(BrowserRowSelection(model: model, selection: selection))
    }
}

// MARK: - the merge tab

struct MergeBrowserList: View {
    @Bindable var model: AuditFlowModel
    let sections: PlaylistBrowseSections
    @State private var singletonsShown = false

    var body: some View {
        List {
            Section {
                if sections.groups.isEmpty {
                    Text("No same-name groups. Every playlist name is unique.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(applyBrowserSort(
                        sections.groups,
                        key: model.browserSortKey,
                        ascending: model.browserSortAscending,
                        count: { $0.copies.reduce(0) { $0 + $1.trackCount } }
                    ), id: \.name) { group in
                        HStack(spacing: 8) {
                            // M10: check a group to queue its merge. Checking
                            // is independent of the row highlight (which only
                            // feeds the inspector).
                            let alreadyDone = model.isAlreadyProcessed(name: group.name)
                            AppKitCheckbox(
                                identifier: M10ControlID.groupCheckbox(group.name),
                                isOn: model.isGroupChecked(group.name),
                                help: alreadyDone
                                    ? "Already merged: \u{201C}\(group.name) \u{2014} "
                                        + "Merged\u{201D} exists. Review it, then clean "
                                        + "up the sources; delete it first to reprocess."
                                    : "Queue \u{201C}\(group.name)\u{201D} "
                                        + "(\(group.copies.count) copies) for merging."
                            ) {
                                model.toggleChecked(
                                    name: group.name,
                                    rangeSelect: NSEvent.modifierFlags.contains(.shift)
                                )
                            }
                            .disabled(alreadyDone || model.isQueueActive)
                            if alreadyDone {
                                Chip(text: "already merged", tint: .green)
                            }
                            BrowserNameText(name: group.name)
                            Chip(text: "x\(group.copies.count)", tint: .blue)
                            Spacer()
                            Text(trackCountText(copyCounts: group.copies.map(\.trackCount)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .browserRow(model, selects: .group(group.name))
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text("MERGEABLE GROUPS (\(sections.groups.count))")
                    BrowserSortHeader(model: model)
                    Spacer()
                    AppKitActionButton(
                        identifier: WaveAControlID.selectAll,
                        title: "Select all",
                        keyEquivalent: "a",
                        keyEquivalentModifiers: [.command]
                    ) {
                        model.selectAllEligible()
                    }
                    .disabled(model.isQueueActive)
                    .help("Check every mergeable group (\u{2318}A).")
                    AppKitActionButton(
                        identifier: WaveAControlID.clearChecks,
                        title: "Clear",
                        keyEquivalent: "d",
                        keyEquivalentModifiers: [.command]
                    ) {
                        model.clearSelection()
                    }
                    .disabled(model.isQueueActive)
                    .help("Uncheck every group (\u{2318}D).")
                }
                .controlSize(.small)
            }

            Section("NEAR MATCHES \u{2014} rename to merge (\(sections.nearMatches.count))") {
                if sections.nearMatches.isEmpty {
                    Text("No invisible-character twins found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sections.nearMatches, id: \.normalizedName) { cluster in
                        HStack(spacing: 8) {
                            // Non-checkable, like consolidate's blocked rows:
                            // a disabled checkbox that explains itself.
                            AppKitCheckbox(
                                identifier: M10ControlID.blockedCheckbox(cluster.normalizedName),
                                isOn: false,
                                help: "Not mergeable \u{2014} these names differ by "
                                    + "invisible characters. Rename in Music first, "
                                    + "then rescan."
                            ) {}
                            .disabled(true)
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(cluster.variants, id: \.name) { variant in
                                    BrowserNameText(name: variant.name)
                                }
                            }
                            Spacer()
                            Text("not mergeable \u{2014} rename first")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .browserRow(model, selects: .nearMatch(cluster.normalizedName))
                    }
                }
            }

            Section("SINGLETONS (\(sections.singletons.count))") {
                DisclosureGroup(isExpanded: $singletonsShown) {
                    ForEach(sections.singletons, id: \.persistentId) { listing in
                        HStack(spacing: 8) {
                            AppKitCheckbox(
                                identifier: M10ControlID.blockedCheckbox(listing.persistentId),
                                isOn: false,
                                help: "Nothing to merge \u{2014} only one playlist "
                                    + "has this exact name."
                            ) {}
                            .disabled(true)
                            BrowserNameText(name: listing.name)
                            listingBadges(listing)
                            Spacer()
                            Text(trackCountText(copyCounts: [listing.trackCount]))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .browserRow(model, selects: .singleton(listing.persistentId))
                    }
                } label: {
                    Text(singletonsShown ? "Hide" : "Show")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - the consolidate tab

struct ConsolidateBrowserList: View {
    @Bindable var model: AuditFlowModel
    let sections: PlaylistBrowseSections

    var body: some View {
        let nearMatchNames = Set(sections.nearMatches.flatMap { $0.variants.map(\.name) })
        List {
            Section {
                ForEach(applyBrowserSort(
                    sections.allPlaylists,
                    key: model.browserSortKey,
                    ascending: model.browserSortAscending,
                    count: { $0.trackCount }
                ), id: \.persistentId) { listing in
                    // Fix round (Wave A fix wave, finding 7): scalar-exact,
                    // matching the checkbox/selection discipline elsewhere
                    // in this file. A canonical-equivalence `Set(names)
                    // .contains` here disagreed with `toggleChecked`'s
                    // scalar-exact group lookup — a canonically-equivalent-
                    // but-scalar-different name could render as blocked
                    // (or checkable) while the model disagreed.
                    let isGroupMember = sections.groups.contains { scalarExact($0.name, listing.name) }
                    let alreadyDone = model.isAlreadyProcessed(name: listing.name)
                    HStack(spacing: 8) {
                        AppKitCheckbox(
                            identifier: M8ControlID.checkbox(listing.persistentId),
                            isOn: model.checkedPersistentIds.contains(listing.persistentId),
                            help: alreadyDone
                                ? "Already consolidated: \u{201C}\(listing.name) "
                                    + "\u{2014} Consolidated\u{201D} exists. Review it, "
                                    + "then clean up; delete it first to reprocess."
                                : isGroupMember
                                    ? consolidateBlockedHelp(copyCount: copyCount(of: listing.name))
                                    : "Queue \u{201C}\(listing.name)\u{201D} for consolidation."
                        ) {
                            model.toggleChecked(
                                persistentId: listing.persistentId,
                                rangeSelect: NSEvent.modifierFlags.contains(.shift)
                            )
                        }
                        .disabled(alreadyDone || isGroupMember || model.isQueueActive)
                        BrowserNameText(name: listing.name)
                        if alreadyDone {
                            Chip(text: "already consolidated", tint: .green)
                        }
                        if nearMatchNames.contains(listing.name) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(
                                    "This name has a near-identical twin \u{2014} see the "
                                        + "Merge tab's NEAR MATCHES. Consolidating it is "
                                        + "still legal (it is a single copy)."
                                )
                        }
                        listingBadges(listing)
                        if isGroupMember {
                            Chip(text: "same-name copy", tint: .red)
                        }
                        Spacer()
                        Text(trackCountText(copyCounts: [listing.trackCount]))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .browserRow(
                        model,
                        selects: isGroupMember
                            ? .group(listing.name)
                            : .singleton(listing.persistentId)
                    )
                }
            } header: {
                HStack(spacing: 8) {
                    Text("ALL PLAYLISTS (\(sections.allPlaylists.count))")
                    BrowserSortHeader(model: model)
                    Spacer()
                    AppKitActionButton(
                        identifier: WaveAControlID.selectAll,
                        title: "Select all",
                        keyEquivalent: "a",
                        keyEquivalentModifiers: [.command]
                    ) {
                        model.selectAllEligible()
                    }
                    .disabled(model.isQueueActive)
                    .help("Check every checkable playlist (\u{2318}A).")
                    AppKitActionButton(
                        identifier: WaveAControlID.clearChecks,
                        title: "Clear",
                        keyEquivalent: "d",
                        keyEquivalentModifiers: [.command]
                    ) {
                        model.clearSelection()
                    }
                    .disabled(model.isQueueActive)
                    .help("Uncheck every playlist (\u{2318}D).")
                }
                .controlSize(.small)
            }
        }
        .listStyle(.inset)
    }

    private func copyCount(of name: String) -> Int {
        sections.groups.first { $0.name == name }?.copies.count ?? 2
    }
}

private func consolidateBlockedHelp(copyCount: Int) -> String {
    "Consolidate is blocked while \(copyCount) same-name copies exist "
        + "(the engine fails closed on ambiguous names) \u{2014} merge the group "
        + "first or rename."
}

@ViewBuilder
private func listingBadges(_ listing: PlaylistListing) -> some View {
    if listing.isSmart {
        Chip(text: "smart", tint: .purple)
    }
    if listing.specialKind != "none" && !listing.specialKind.isEmpty {
        Chip(text: listing.specialKind, tint: .gray)
    }
}

// MARK: - the inspector

/// Warning presentation for the gray inspector panel (fix round 4, item 1):
/// PRIMARY label text on a tinted warning capsule with an orange icon —
/// system label colors keep contrast on `underPageBackgroundColor` in both
/// appearances, where bare orange body text did not.
private struct InspectorWarning: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.35)))
    }
}

struct BrowserInspector: View {
    @Bindable var model: AuditFlowModel
    let sections: PlaylistBrowseSections

    /// The Align-names sheet (B5). `DirectMutationSheets` has its own single
    /// sheet anchor below; picking a rename closes this sheet first so the
    /// two never stack.
    @State private var alignSheetShown = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch model.browserSelection {
                case .group(let name):
                    if let group = sections.groups.first(where: { scalarExact($0.name, name) }) {
                        groupInspector(group)
                    } else {
                        emptyHint
                    }
                case .nearMatch(let normalized):
                    if let cluster = sections.nearMatches.first(
                        where: { scalarExact($0.normalizedName, normalized) }
                    ) {
                        nearMatchInspector(cluster)
                    } else {
                        emptyHint
                    }
                case .singleton(let persistentId):
                    singletonBody(persistentId: persistentId)
                case nil:
                    emptyHint
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        // Finding I1: the shared anchor (see DirectMutationSheets.swift) —
        // one condition and one dismiss rule across all four anchors.
        .directMutationSheet(model: model)
    }

    /// Resolve a persistent id: a true singleton gets the single-copy note;
    /// a group member's id resolves to its whole group (so the consolidate
    /// tab's blocked rows explain themselves).
    @ViewBuilder
    private func singletonBody(persistentId: String) -> some View {
        if let listing = sections.singletons.first(
            where: { scalarExact($0.persistentId, persistentId) }
        ) {
            singletonInspector(listing)
        } else if let member = sections.allPlaylists.first(
            where: { scalarExact($0.persistentId, persistentId) }
        ), let group = sections.groups.first(where: { scalarExact($0.name, member.name) }) {
            groupInspector(group)
        } else {
            emptyHint
        }
    }

    private var emptyHint: some View {
        Text(
            model.mode == .merge
                ? "Check groups to queue their merges (each gets its own read, review, and confirm gate); select any row to inspect it, or a near match to see its rename hint."
                : "Check the playlists to consolidate; each queued item gets its own read, review, and confirm gate."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: group

    private func groupInspector(_ group: PlaylistNameGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Same-name group")
                .font(.headline)
            BrowserNameText(name: group.name)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(group.copies.enumerated()), id: \.element.persistentId) { ordinal, copy in
                    HStack(spacing: 8) {
                        Text("Copy \(ordinal)")
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                        IdentifierText(text: copy.persistentId)
                        Text(trackCountText(copyCounts: [copy.trackCount]))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        copyActions(copy)
                    }
                    .font(.callout)
                }
            }
            LabeledContent("Combined input") {
                Text(trackCountText(copyCounts: [group.combinedTrackCount]))
                    .monospacedDigit()
            }
            .font(.callout)
            Text(
                "Copies are in ascending playlist-id order (the plan's copy order). "
                    + "No dedup estimate is shown before the check \u{2014} the read-only "
                    + "check computes the real numbers."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if model.mode == .consolidate {
                InspectorWarning(
                    text: "Consolidate is blocked for this name while \(group.copies.count) "
                        + "same-name copies exist (the engine fails closed on ambiguous "
                        + "names) \u{2014} merge the group first or rename."
                )
            }
        }
    }

    // MARK: near match

    private func nearMatchInspector(_ cluster: PlaylistNearMatchCluster) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Contrast (fix round 4, item 1): orange stays on the ICON;
            // text uses system label colors that hold on the gray panel.
            Label {
                Text("Near match \u{2014} rename to merge")
                    .font(.headline)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(cluster.variants, id: \.name) { variant in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        BrowserNameText(name: variant.name)
                        Text(variant.listings.count == 1
                            ? "1 playlist"
                            : "\(variant.listings.count) playlists")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !scalarExact(variant.name, cluster.normalizedName) {
                        Text(describeNameDifference(
                            reference: cluster.normalizedName, other: variant.name
                        ))
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    }
                }
            }
            Divider()
            Text(
                "These names differ only by invisible characters, so the strict "
                    + "exact-name contract keeps them separate (correctly). To merge "
                    + "them: rename the twin(s) in Music to the exact name below, "
                    + "then rescan \u{2014} the group appears under MERGEABLE GROUPS."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            LabeledContent("Exact target name") {
                IdentifierText(text: cluster.normalizedName)
            }
            .font(.callout)
            HStack(spacing: 8) {
                AppKitActionButton(
                    identifier: WaveBControlID.alignOpen,
                    title: "Align names\u{2026}"
                ) {
                    alignSheetShown = true
                }
                .disabled(
                    model.isScanning || model.isRunning || model.isApplying
                        || model.isMutationBusy || model.isQueueActive
                )
                .sheet(isPresented: $alignSheetShown) {
                    AlignNamesSheet(cluster: cluster) { persistentId, canonicalName in
                        model.requestDirectRename(
                            persistentID: persistentId, prefilledName: canonicalName
                        )
                    }
                }
                CopyButton(label: "Copy rename hint", text: cluster.normalizedName)
                    .help("Copies the exact corrected name to paste into Music's rename field.")
                AppKitActionButton(
                    identifier: M8ControlID.inspectorRescan,
                    title: "Rescan Library"
                ) {
                    model.rescanLibrary()
                }
                .disabled(model.isScanning || model.isRunning)
            }
            .controlSize(.small)
        }
    }

    // MARK: singleton

    private func singletonInspector(_ listing: PlaylistListing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Single copy")
                .font(.headline)
            BrowserNameText(name: listing.name)
            LabeledContent("Persistent ID") { IdentifierText(text: listing.persistentId) }
                .font(.callout)
            LabeledContent("Tracks") {
                Text(String(listing.trackCount)).monospacedDigit()
            }
            .font(.callout)
            Text(
                model.mode == .merge
                    ? "Nothing to merge \u{2014} only one playlist has this exact name. "
                        + "If you expected more copies, check NEAR MATCHES for "
                        + "invisible-character twins (trailing spaces render as \u{B7})."
                    : "Eligible for the consolidate queue (exactly one playlist has "
                        + "this exact name)."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            mutationActions(for: listing)
        }
    }

    // MARK: direct mutation actions (Task 5, Sergio 2026-08-06)

    /// Delete/Rename... for ONE pinned row, dispatched directly: NO refusal
    /// filtering (smart playlists, folders, even the contract-excluded pilot
    /// are all actionable here) — the confirm/rename sheet
    /// (`DirectMutationSheets`) is the only thing between a click and the
    /// guarded AppleScript writer.
    @ViewBuilder
    private func mutationActions(for listing: PlaylistListing) -> some View {
        Divider()
        HStack(spacing: 8) {
            AppKitActionButton(
                identifier: WaveBControlID.rowDelete(listing.persistentId),
                title: "Delete"
            ) {
                model.requestDirectDelete(persistentIDs: [listing.persistentId])
            }
            AppKitActionButton(
                identifier: WaveBControlID.rowRename(listing.persistentId),
                title: "Rename\u{2026}"
            ) {
                model.requestDirectRename(persistentID: listing.persistentId, prefilledName: nil)
            }
        }
        .controlSize(.small)
        .disabled(
            model.isScanning || model.isRunning || model.isApplying
                || model.isMutationBusy || model.isQueueActive
        )
        Text("Deleting a playlist never removes songs from the library.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    /// Mini per-copy actions for the group inspector's copy rows: same-name
    /// copies are the norm here, each pinned by its own persistent ID.
    private func copyActions(_ copy: PlaylistListing) -> some View {
        HStack(spacing: 6) {
            AppKitActionButton(
                identifier: WaveBControlID.rowDelete(copy.persistentId),
                title: "Delete"
            ) {
                model.requestDirectDelete(persistentIDs: [copy.persistentId])
            }
            AppKitActionButton(
                identifier: WaveBControlID.rowRename(copy.persistentId),
                title: "Rename\u{2026}"
            ) {
                model.requestDirectRename(persistentID: copy.persistentId, prefilledName: nil)
            }
        }
        .controlSize(.mini)
        .disabled(
            model.isScanning || model.isRunning || model.isApplying
                || model.isMutationBusy || model.isQueueActive
        )
    }
}

// MARK: - the queue rail

struct QueueRailView: View {
    @Bindable var model: AuditFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(
                    model.isQueueComplete
                        ? "Queue complete (\(model.queue.count) items)"
                        : "Queue: item \(min(model.queueIndex + 1, model.queue.count)) of \(model.queue.count)"
                )
                .bold()
                Spacer()
                if model.isQueueComplete {
                    Button("Done") { model.dismissQueue() }
                        .controlSize(.small)
                }
            }
            QueueTableView(rows: queueTableRows(for: model))
            if let current = model.currentQueueItem {
                HStack(spacing: 8) {
                    if current.status == .failed {
                        Button("Retry item") { model.retryCurrentQueueItem() }
                            .disabled(model.isRunning || model.isScanning)
                    }
                    if current.status == .audited {
                        Text("Finish this item's review, confirm gate, and apply; continue from the apply result.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Same guard set as the model (M8 fix round 1, finding
                    // 2; M9 fix round 1, finding 2: never skip an APPLIED
                    // item — the playlist exists in Music).
                    Button("Skip item") { model.skipCurrentQueueItem() }
                        .disabled(
                            model.isRunning || model.isScanning || model.isApplying
                                || current.status == .applied
                        )
                    // Fix round 1, folded minor: the queue read path carries
                    // the same cancel affordance as the single-audit path; a
                    // cancelled item lands as failed with Retry available.
                    if model.isRunning {
                        AppKitActionButton(
                            identifier: M8ControlID.cancelAudit,
                            title: "Cancel"
                        ) {
                            model.cancelAudit()
                        }
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - the Align-names sheet (B5)

/// Pick the canonical name, then dispatch N-1 separately confirmed renames.
/// The sheet is model-free: `onRename` (wired by the inspector) dismisses
/// this sheet and stages one pending direct rename, pre-filled with the
/// CANONICAL DESTINATION name; the shared `DirectMutationSheets` confirms
/// that single rename, the deviant copy pinned by persistent ID.
struct AlignNamesSheet: View {
    let cluster: PlaylistNearMatchCluster
    let onRename: (_ persistentId: String, _ canonicalName: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCanonical: String?

    init(
        cluster: PlaylistNearMatchCluster,
        initialSelection: String? = nil,
        onRename: @escaping (_ persistentId: String, _ canonicalName: String) -> Void
    ) {
        self.cluster = cluster
        self.onRename = onRename
        let candidates = canonicalAlignCandidates(in: cluster)
        _selectedCanonical = State(
            initialValue: initialSelection ?? (candidates.count == 1 ? candidates.first : nil)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Align names \u{2014} rename the deviant twins")
                .font(.headline)
            Text(
                "The canonical name is the variant that equals its own NFC form "
                    + "with no leading/trailing whitespace and no invisible scalars. "
                    + "Each rename below is separately confirmed."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            ForEach(cluster.variants, id: \.name) { variant in
                HStack(spacing: 8) {
                    AppKitActionButton(
                        identifier: WaveBControlID.alignPick(variant.name),
                        title: isSelected(variant.name) ? "Canonical" : "Pick"
                    ) {
                        selectedCanonical = variant.name
                    }
                    BrowserNameText(name: variant.name)
                    Chip(
                        text: isCanonicalAlignName(variant.name) ? "canonical form" : "deviant",
                        tint: isCanonicalAlignName(variant.name) ? .green : .orange
                    )
                    Spacer()
                }
                .controlSize(.small)
            }
            Divider()
            if let canonical = selectedCanonical {
                ForEach(alignRenames(in: cluster, canonicalName: canonical)) { rename in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            BrowserNameText(name: rename.currentName)
                            IdentifierText(text: rename.persistentId)
                            Spacer()
                            AppKitActionButton(
                                identifier: WaveBControlID.alignRename(rename.persistentId),
                                title: "Rename\u{2026}"
                            ) {
                                dismiss()
                                onRename(rename.persistentId, canonical)
                            }
                        }
                        .controlSize(.small)
                        Text(describeNameDifference(
                            reference: canonical, other: rename.currentName
                        ))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    }
                }
            } else {
                Text(
                    canonicalAlignCandidates(in: cluster).isEmpty
                        ? "No variant qualifies as canonical \u{2014} pick the name to keep."
                        : "Several variants qualify \u{2014} pick the name to keep."
                )
                .font(.callout)
                .lineLimit(2)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(16)
        .frame(minWidth: 560, alignment: .leading)
    }

    private func isSelected(_ name: String) -> Bool {
        guard let selected = selectedCanonical else { return false }
        return scalarExact(selected, name)
    }
}

// MARK: - sort header (display-only ordering; all modes)

/// Clickable Name/Tracks ordering. The active column shows its direction;
/// clicking it flips, clicking the other column selects it ascending.
struct BrowserSortHeader: View {
    @Bindable var model: AuditFlowModel

    var body: some View {
        HStack(spacing: 4) {
            sortButton(.name, label: "Name", id: WaveBControlID.sortByName)
            sortButton(.count, label: "Tracks", id: WaveBControlID.sortByCount)
        }
        .controlSize(.small)
    }

    private func sortButton(_ key: BrowserSortKey, label: String, id: String) -> some View {
        AppKitActionButton(
            identifier: id,
            title: model.browserSortKey == key
                ? "\(label) \(model.browserSortAscending ? "\u{25B2}" : "\u{25BC}")"
                : label,
            help: "Order the list by \(label.lowercased()) (click again to reverse)."
        ) {
            model.toggleBrowserSort(key)
        }
    }
}
