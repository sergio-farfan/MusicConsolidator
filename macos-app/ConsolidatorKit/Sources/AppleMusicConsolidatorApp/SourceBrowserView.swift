// SourceBrowserView.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// M8 — the sectioned source browser (design Option B), recomposed in fix
// round 2 and unified in the 2026-08-11 merge-list redesign. Merge tab: ONE
// alphabetical ALL PLAYLISTS checklist (`mergeRows`) — a same-name group is
// one row (all copies), interleaved with every singleton — where a tap
// highlights ONE row for the inspector, GROUP rows carry native checkboxes
// building the merge batch queue (`toggleChecked(name:)`, M10; disabled once
// that group's own "<name> — Merged" target exists), and SINGLETON rows carry
// live checkboxes too (2026-08-06 free-form design: they contribute to "Merge
// selected as one…", and stay live even with a "<own name> — Merged" sibling —
// final review finding C1). A near-match row of EITHER kind carries a badge
// and selects its cluster (not itself) so the inspector's rename hint,
// per-listing Delete/Rename…, and Align names… stay reachable without a
// separate non-checkable cluster row (findings I2/I3) — the old MERGEABLE
// GROUPS / NEAR MATCHES / SINGLETONS three-section anatomy and its collapsed-
// singletons disclosure are retired. Consolidate tab: the flat alphabetical
// ALL PLAYLISTS list with native checkboxes building the consolidate batch
// queue (group members disabled — the engine fails closed on ambiguous
// names). A trailing inspector explains the selected row; selection for
// inspection is independent of checking for the queue in both tabs.
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

/// The near-match cluster a listing belongs to, by its normalized name.
func nearMatchClusterName(
    for listing: PlaylistListing, in sections: PlaylistBrowseSections
) -> String? {
    nearMatchClusterName(forName: listing.name, in: sections)
}

/// The near-match cluster an exact NAME belongs to (the class-level lookup
/// behind both row kinds' routing — near-match variants ARE exact-name
/// classes, and a class with >= 2 copies is a group).
func nearMatchClusterName(
    forName name: String, in sections: PlaylistBrowseSections
) -> String? {
    sections.nearMatches.first { cluster in
        cluster.variants.contains { scalarExact($0.name, name) }
    }?.normalizedName
}

/// The row-tap selection target for a merge-tab singleton row (2026-08-11
/// unified merge list): a near-match twin selects its CLUSTER, by
/// `nearMatchClusterName` — so tapping EITHER twin's row resolves to the
/// same `.nearMatch` selection (mirroring how selecting a same-name GROUP
/// highlights every copy together) and the near-match inspector detail +
/// Align names… entry point stay reachable without a standalone NEAR
/// MATCHES row; a plain singleton (no twin) selects itself. Pure and
/// directly testable — no click simulation needed to pin the routing.
func mergeSingletonRowSelection(
    for listing: PlaylistListing,
    nearMatchTwin: String?,
    in sections: PlaylistBrowseSections
) -> BrowserSelection {
    guard nearMatchTwin != nil, let clusterName = nearMatchClusterName(for: listing, in: sections)
    else {
        return .singleton(listing.persistentId)
    }
    return .nearMatch(clusterName)
}

/// The row-tap selection target for a merge-tab GROUP row (final review
/// finding I2), mirroring `mergeSingletonRowSelection`: a group whose exact
/// name is one variant of a near-match cluster selects the CLUSTER, so an
/// ALL-GROUP cluster ("Trance 2022" x2 vs "Trance 2022 " x2) still reaches the
/// near-match inspector's rename hint and Align names… entry point — before
/// this, only singleton variants could, and an all-group cluster had no route
/// to Align names… at all. An unbadged group selects itself.
func mergeGroupRowSelection(
    for group: PlaylistNameGroup,
    nearMatchTwin: String?,
    in sections: PlaylistBrowseSections
) -> BrowserSelection {
    guard nearMatchTwin != nil,
          let clusterName = nearMatchClusterName(forName: group.name, in: sections)
    else {
        return .group(group.name)
    }
    return .nearMatch(clusterName)
}

/// The merge tab's unified ALL PLAYLISTS checklist (2026-08-11 design): one
/// alphabetical `List` of `mergeRows` — a same-name group (one row, all
/// copies) interleaved with every singleton; every singleton row is
/// checkable, and a group row is checkable until its own merge target
/// exists. Replaces the old MERGEABLE GROUPS / NEAR MATCHES / SINGLETONS
/// three-section anatomy and its collapsed-singletons disclosure entirely: a
/// near match's rename hint now surfaces as a badge on its (still checkable)
/// row — singleton or group — instead of a separate non-checkable cluster row.
struct MergeBrowserList: View {
    @Bindable var model: AuditFlowModel
    let sections: PlaylistBrowseSections

    var body: some View {
        // `sections` already passed the active search filter (the caller
        // applies `filteredSections` once, same as ConsolidateBrowserList),
        // so `mergeRows` is called with an empty needle here.
        let rows = mergeRows(
            sections: sections, needle: "",
            key: model.browserSortKey, ascending: model.browserSortAscending
        )
        List {
            Section {
                ForEach(rows) { row in
                    switch row {
                    case .group(let group, let nearMatchTwin):
                        groupRow(group, nearMatchTwin: nearMatchTwin)
                    case .singleton(let listing, let nearMatchTwin):
                        singletonRow(listing, nearMatchTwin: nearMatchTwin)
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    // Minor (b): the header counts SOURCE playlists (group
                    // copies + singletons), the same noun the consolidate
                    // header and this tab's own footer count — not rows.
                    Text(MergeSurfaceCopy.allPlaylistsHeader(
                        sourceCount: mergeSourceCount(rows: rows)
                    ))
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
                    .help("Check every eligible group and singleton (\u{2318}A).")
                    AppKitActionButton(
                        identifier: WaveAControlID.clearChecks,
                        title: "Clear",
                        keyEquivalent: "d",
                        keyEquivalentModifiers: [.command]
                    ) {
                        model.clearSelection()
                    }
                    .disabled(model.isQueueActive)
                    .help("Uncheck every group and singleton (\u{2318}D).")
                }
                .controlSize(.small)
            }
        }
        .listStyle(.inset)
    }

    // MARK: rows

    /// A same-name group row: name, `xN` badge, per-copy counts, checkbox ->
    /// `toggleChecked(name:)`, already-merged chip, PLUS a near match badge
    /// when this group's exact name is one variant of a cluster (finding I2 —
    /// an all-group cluster is possible and had no route to Align names…).
    /// A group row's per-group merge target IS "<name> — Merged", so an
    /// existing target genuinely blocks a re-run and the checkbox stays
    /// disabled here (unlike a singleton row's — finding C1).
    @ViewBuilder
    private func groupRow(_ group: PlaylistNameGroup, nearMatchTwin: String?) -> some View {
        let alreadyDone = model.isAlreadyProcessed(name: group.name)
        HStack(spacing: 8) {
            // M10: check a group to queue its merge. Checking is
            // independent of the row highlight (which only feeds the
            // inspector).
            AppKitCheckbox(
                identifier: M10ControlID.groupCheckbox(group.name),
                isOn: model.isGroupChecked(group.name),
                help: alreadyDone
                    ? MergeSurfaceCopy.alreadyMergedGroupHelp(sourceName: group.name)
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
                    .help(MergeSurfaceCopy.alreadyMergedGroupHelp(sourceName: group.name))
            }
            BrowserNameText(name: group.name)
            Chip(text: "x\(group.copies.count)", tint: .blue)
            if let nearMatchTwin {
                Chip(text: "near match", tint: .orange)
                    .help(MergeSurfaceCopy.nearMatchChipHelp(twin: nearMatchTwin))
            }
            Spacer()
            Text(trackCountText(copyCounts: group.copies.map(\.trackCount)))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .browserRow(
            model,
            selects: mergeGroupRowSelection(
                for: group, nearMatchTwin: nearMatchTwin, in: sections
            )
        )
    }

    /// A singleton row: checkbox -> `toggleCheckedFreeFormSingleton`,
    /// already-merged chip (2026-08-11: extended to singletons — the same
    /// `isAlreadyProcessed` skip `selectAllEligible` already applies to a
    /// checked-out singleton is now visible on its row too), PLUS a near
    /// match badge when this row carries a twin. Selecting the row targets
    /// the near-match cluster instead of the plain singleton when a twin is
    /// present, keeping the rename hint reachable.
    ///
    /// Finding C1: the checkbox is NEVER disabled by `isAlreadyProcessed`.
    /// A singleton's checkbox contributes a SOURCE to "Merge selected as
    /// one…", whose target is named after the FIRST source in playlist-ID
    /// order — an existing "<own name> — Merged" sibling is not a target
    /// collision for that merge, so disabling the row would permanently
    /// poison every free-form merge's first source for future merges. The
    /// chip stays as a purely informational advisory.
    @ViewBuilder
    private func singletonRow(_ listing: PlaylistListing, nearMatchTwin: String?) -> some View {
        let alreadyDone = model.isAlreadyProcessed(name: listing.name)
        HStack(spacing: 8) {
            // 2026-08-06 free-form design: a singleton cannot merge with
            // itself, but it CAN contribute to a free-form merge alongside
            // other checked groups/singletons.
            AppKitCheckbox(
                identifier: M10ControlID.singletonCheckbox(listing.persistentId),
                isOn: model.isFreeFormSingletonChecked(persistentId: listing.persistentId),
                help: "Check to include \u{201C}\(listing.name)\u{201D} as a "
                    + "source in \u{201C}Merge selected as one\u{2026}\u{201D}."
            ) {
                model.toggleCheckedFreeFormSingleton(
                    persistentId: listing.persistentId,
                    rangeSelect: NSEvent.modifierFlags.contains(.shift)
                )
            }
            .disabled(model.isQueueActive)
            if alreadyDone {
                Chip(text: "already merged", tint: .green)
                    .help(MergeSurfaceCopy.alreadyMergedSingletonAdvisory(
                        sourceName: listing.name
                    ))
            }
            BrowserNameText(name: listing.name)
            listingBadges(listing)
            if let nearMatchTwin {
                Chip(text: "near match", tint: .orange)
                    .help(MergeSurfaceCopy.nearMatchChipHelp(twin: nearMatchTwin))
            }
            Spacer()
            Text(trackCountText(copyCounts: [listing.trackCount]))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .browserRow(
            model,
            selects: mergeSingletonRowSelection(
                for: listing, nearMatchTwin: nearMatchTwin, in: sections
            )
        )
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
                                    "This name has a near-identical twin \u{2014} see its "
                                        + "\u{201C}near match\u{201D} badge on the Merge tab. "
                                        + "Consolidating it is still legal (it is a single "
                                        + "copy)."
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
                ? "Check any groups and singletons to merge (each queued item gets its own read, review, and confirm gate); select any row to inspect it, including a near match's rename hint."
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
                    // Two lines per copy: the single-line HStack squeezed the
                    // count to one character per line at the pane's 220pt
                    // minimum once Rename… joined Delete (M8 defect class;
                    // pinned by groupCopyRowsCompactAtPaneWidth).
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Copy \(ordinal)")
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .leading)
                            Text(trackCountText(copyCounts: [copy.trackCount]))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            copyActions(copy)
                        }
                        IdentifierText(text: copy.persistentId)
                            .padding(.leading, 60)
                    }
                    .font(.callout)
                    .padding(.bottom, 2)
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
                    // Finding I3: the same Delete/Rename… the singleton and
                    // group inspectors carry, per LISTING of every variant.
                    // This inspector is now the ONLY inspector a badged row
                    // reaches (2026-08-11 routing, extended to group rows by
                    // finding I2), so without these a near-match twin — the
                    // one class of row whose fix IS a rename — was the only
                    // row in the browser with no row actions at all.
                    ForEach(variant.listings, id: \.persistentId) { listing in
                        IdentifierText(text: listing.persistentId)
                        mutationActions(for: listing)
                    }
                }
            }
            Divider()
            Text(
                "These names differ only by invisible characters, so the strict "
                    + "exact-name contract keeps them separate (correctly). To merge "
                    + "them: rename the twin(s) in Music to the exact name below, "
                    + "then rescan \u{2014} the group becomes ONE checkable row in "
                    + "ALL PLAYLISTS."
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
                        + "If you expected more copies, look for a \u{201C}near "
                        + "match\u{201D} badge \u{2014} invisible-character twins render "
                        + "as separate rows (trailing spaces render as \u{B7})."
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
