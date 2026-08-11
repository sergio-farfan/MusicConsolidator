// BrowserPresentation.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// M8 — pure presentation helpers under the sectioned source browser
// (Option B) and the confirm-gate diagnostics: visible rendering of
// invisible scalars (trailing space as ·, other invisibles as U+XXXX),
// first-divergence scalar diffs in the golden-test diagnostic style, the
// near-identical WINNER pairs classifier (the Gamemaster / Lotus-Sutra
// class), section search filtering, and the audit-queue value types (both modes).
// Everything here is a value-typed pure function — headlessly testable, no
// Music, no I/O.

import Foundation
import ConsolidatorCore

// MARK: - visible rendering of invisible scalars

/// True for scalars that render as nothing (or as bare width) in a playlist
/// name: Unicode Cf format scalars (ZWSP, FEFF, soft hyphen, ...), control
/// scalars, and every non-U+0020 whitespace scalar (NBSP, thin space, ...).
/// U+0020 itself is handled positionally (interior vs trailing) by
/// `renderNameWithVisibleScalars`.
private nonisolated func isInvisibleScalar(_ scalar: Unicode.Scalar) -> Bool {
    if scalar == " " { return false }
    switch scalar.properties.generalCategory {
    case .format, .control:
        return true
    default:
        return scalar.properties.isWhitespace
    }
}

/// Render a playlist name with every invisible scalar made visible:
/// trailing spaces become U+00B7 MIDDLE DOT, every other invisible scalar
/// becomes its "U+XXXX" spelling; visible scalars pass through untouched
/// (interior single/double spaces stay literal spaces — the sweep formula
/// does not flag them, and monospaced rendering shows the width).
nonisolated func renderNameWithVisibleScalars(_ name: String) -> String {
    let scalars = Array(name.unicodeScalars)
    var trailingRunStart = 0
    for (index, scalar) in scalars.enumerated()
    where scalar != " " && !isInvisibleScalar(scalar) {
        trailingRunStart = index + 1
    }
    var rendered = ""
    for (index, scalar) in scalars.enumerated() {
        if scalar == " " {
            rendered.append(index >= trailingRunStart ? "\u{B7}" : " ")
        } else if isInvisibleScalar(scalar) {
            rendered += String(format: "U+%04X", scalar.value)
        } else {
            rendered.unicodeScalars.append(scalar)
        }
    }
    return rendered
}

// MARK: - scalar divergence (golden-test diagnostic style)

/// The first scalar position where two strings differ. `expected == nil`
/// means the typed/other string continues past the expected one;
/// `actual == nil` means it ends early.
nonisolated struct ScalarDivergence: Equatable, Sendable {
    let index: Int
    let expected: Unicode.Scalar?
    let actual: Unicode.Scalar?
}

/// Scalar-level first divergence, or nil when the strings are scalar-equal.
nonisolated func firstScalarDivergence(expected: String, actual: String) -> ScalarDivergence? {
    let expectedScalars = Array(expected.unicodeScalars)
    let actualScalars = Array(actual.unicodeScalars)
    let shared = min(expectedScalars.count, actualScalars.count)
    for index in 0..<shared where expectedScalars[index] != actualScalars[index] {
        return ScalarDivergence(
            index: index, expected: expectedScalars[index], actual: actualScalars[index]
        )
    }
    if expectedScalars.count == actualScalars.count { return nil }
    return ScalarDivergence(
        index: shared,
        expected: shared < expectedScalars.count ? expectedScalars[shared] : nil,
        actual: shared < actualScalars.count ? actualScalars[shared] : nil
    )
}

/// "U+0020 (SPACE)" — code point plus the Unicode name when one exists.
nonisolated func scalarDisplay(_ scalar: Unicode.Scalar) -> String {
    let code = String(format: "U+%04X", scalar.value)
    if let name = scalar.properties.name {
        return "\(code) (\(name))"
    }
    return code
}

/// Operator-facing description of a confirm-gate near miss.
nonisolated func describeDivergence(_ divergence: ScalarDivergence) -> String {
    switch (divergence.expected, divergence.actual) {
    case (let expected?, let actual?):
        return "First difference at scalar index \(divergence.index): "
            + "expected \(scalarDisplay(expected)), typed \(scalarDisplay(actual))."
    case (nil, let actual?):
        return "Typed name continues past the expected name: "
            + "extra \(scalarDisplay(actual)) at scalar index \(divergence.index)."
    case (let expected?, nil):
        return "Typed name ends at scalar index \(divergence.index); "
            + "expected \(scalarDisplay(expected)) next."
    case (nil, nil):
        return "No difference."
    }
}

/// Inspector text for a near-match variant pair: which scalar makes `other`
/// differ from `reference`, with both names rendered visibly.
nonisolated func describeNameDifference(reference: String, other: String) -> String {
    let head = "\u{201C}\(renderNameWithVisibleScalars(other))\u{201D} differs from "
        + "\u{201C}\(renderNameWithVisibleScalars(reference))\u{201D}: "
    guard let divergence = firstScalarDivergence(expected: reference, actual: other) else {
        return head + "names are scalar-identical."
    }
    switch (divergence.expected, divergence.actual) {
    case (nil, let actual?):
        return head + "extra \(scalarDisplay(actual)) at scalar index \(divergence.index)."
    case (let expected?, nil):
        return head + "missing \(scalarDisplay(expected)) at scalar index \(divergence.index)."
    case (let expected?, let actual?):
        return head + "\(scalarDisplay(expected)) vs \(scalarDisplay(actual)) "
            + "at scalar index \(divergence.index)."
    case (nil, nil):
        return head + "names are scalar-identical."
    }
}

// MARK: - near-identical winner pairs (the Gamemaster / Lotus class)

/// Two OUTPUT tracks whose normalized title+artist match but whose exact
/// durations differ: the strict key keeps both (correctly — the live Trance
/// 2022 pilot proved the class holds genuinely distinct releases), and a
/// human should look at each pair once.
nonisolated struct NearIdenticalWinnerPair: Equatable, Sendable, Identifiable {
    let first: TrackSnapshot
    let second: TrackSnapshot

    var id: String { "\(first.sourceIndex)-\(second.sourceIndex)" }
}

/// Map winner indexes to output tracks the way the verifiers do (positional
/// indexing into the plan's own track list), bounds-guarded.
nonisolated func planOutputTracks(
    winnerSourceIndexes: [Int],
    from tracks: [TrackSnapshot]
) -> [TrackSnapshot] {
    winnerSourceIndexes.compactMap { index in
        tracks.indices.contains(index) ? tracks[index] : nil
    }
}

/// Find every near-identical winner pair in an output list. Grouping is by
/// normalized title+artist under SCALAR-exact keys (a plain String
/// dictionary key would merge canonically-equivalent normalized forms), in
/// output order; tracks whose title or artist normalize to empty are
/// skipped (no meaningful identity). Pairs require differing `durationMs`
/// (two output tracks with equal non-nil durations and matching normalized
/// fields cannot both exist — the strict key deduplicates them — and equal
/// nil durations carry no duration evidence).
nonisolated func nearIdenticalWinnerPairs(
    in outputTracks: [TrackSnapshot]
) -> [NearIdenticalWinnerPair] {
    struct NormalizedKey: Hashable {
        let title: [UInt32]
        let artist: [UInt32]
    }

    var keyOrder: [NormalizedKey] = []
    var buckets: [NormalizedKey: [TrackSnapshot]] = [:]
    for track in outputTracks {
        let title = normalizeText(track.title)
        let artist = normalizeText(track.artist)
        guard !title.isEmpty, !artist.isEmpty else { continue }
        let key = NormalizedKey(
            title: title.unicodeScalars.map(\.value),
            artist: artist.unicodeScalars.map(\.value)
        )
        if buckets[key] == nil {
            keyOrder.append(key)
            buckets[key] = [track]
        } else {
            buckets[key]!.append(track)
        }
    }

    var pairs: [NearIdenticalWinnerPair] = []
    for key in keyOrder {
        guard let members = buckets[key], members.count >= 2 else { continue }
        for first in 0..<(members.count - 1) {
            for second in (first + 1)..<members.count
            where members[first].durationMs != members[second].durationMs {
                pairs.append(
                    NearIdenticalWinnerPair(first: members[first], second: members[second])
                )
            }
        }
    }
    return pairs
}

// MARK: - browser search filtering

/// Filter every section by a case-insensitive name substring; the empty
/// query is the identity. Near-match clusters stay whole when ANY variant
/// matches (the pair is only reviewable together).
nonisolated func filteredSections(
    _ sections: PlaylistBrowseSections,
    query: String
) -> PlaylistBrowseSections {
    guard !query.isEmpty else { return sections }
    let needle = query.lowercased()
    func matches(_ name: String) -> Bool {
        name.lowercased().contains(needle)
    }
    return PlaylistBrowseSections(
        allPlaylists: sections.allPlaylists.filter { matches($0.name) },
        groups: sections.groups.filter { matches($0.name) },
        singletons: sections.singletons.filter { matches($0.name) },
        nearMatches: sections.nearMatches.filter { cluster in
            cluster.variants.contains { matches($0.name) }
        }
    )
}

// MARK: - browser selection and the audit queue (merge + consolidate)

/// One highlighted browser row. Selection is for INSPECTION only (M10) — the
/// other cases exist so the inspector can explain them (near matches get
/// the rename hint; singletons are inert in merge mode).
nonisolated enum BrowserSelection: Hashable, Sendable {
    /// A mergeable exact-name group, by its exact name.
    case group(String)
    /// A near-match cluster, by its normalized name.
    case nearMatch(String)
    /// A single-copy playlist, by its persistent ID.
    case singleton(String)
}

/// Per-item lifecycle of the batch queue — ONE state machine shared by both
/// modes since M10 (consolidate items are checked single-copy playlists;
/// merge items are checked exact-name groups; a queue is always all one
/// mode). Every item flows through its own plan review + confirm gate +
/// in-app apply (per-plan approval; no bulk approve) — the queue only
/// removes source-selection friction. M9: `.applied` (a verified in-app
/// apply) replaces the M7/M8 hand-off state; a failed apply lands the item
/// in `.failed`, whose Retry is a FRESH audit.
nonisolated enum AuditQueueStatus: Equatable, Sendable {
    case pending
    case audited
    case applied
    case skipped
    case failed

    var displayName: String {
        switch self {
        case .pending: return "pending"
        case .audited: return "ready"
        case .applied: return "applied"
        case .skipped: return "skipped"
        case .failed: return "failed"
        }
    }
}

/// One resolved free-form merge queue item's plan-build inputs (2026-08-06
/// free-form design): every source playlist pinned by persistent ID, in
/// ascending playlist-ID order — the exact order the copies are read,
/// deduped, and concatenated in (spec Decision 5). `targetName`/
/// `targetDescription` are computed once, at enqueue time
/// (`AuditFlowModel.startFreeFormMerge()`), from this exact ordering.
nonisolated struct FreeFormMergeSpec: Equatable, Sendable {
    let persistentIds: [String]
    let sourceNames: [String]
    let targetName: String
    let targetDescription: String
}

nonisolated struct AuditQueueItem: Equatable, Sendable, Identifiable {
    let name: String
    var status: AuditQueueStatus
    /// Per-copy track counts in the group's copy order (ascending playlist
    /// id — the merge concatenation order); a single count for consolidate
    /// items. Captured from the scan-time listing when the queue is built,
    /// refreshed with the audit's live counts when this item's audit
    /// completes (spec A5). Display-only — never a guard input. No default
    /// value on purpose: the compiler must surface every construction site.
    var copyCounts: [Int]
    /// nil for every consolidate item and every same-name merge item
    /// (`startQueue()`); non-nil for the ONE free-form merge item
    /// `startFreeFormMerge()` ever enqueues. No default value on purpose,
    /// like `copyCounts` above: the compiler must surface every
    /// construction site.
    let freeForm: FreeFormMergeSpec?

    var id: String { name }
}

// MARK: - shift-click range selection (Wave A, spec A4)

/// Pure shift-click range toggle over ONE checkable section. `orderedIDs`
/// is the section's row ids in DISPLAY order (group names on the merge tab,
/// persistent IDs on the consolidate tab); `current` is the checked set.
/// The clicked row's NEW state (`!current.contains(clicked)`) is applied to
/// every id in the inclusive [anchor, clicked] range, in either direction.
/// With no usable anchor — nil, or anchor/clicked not found in `orderedIDs`
/// (scalar-exact lookup, matching the browser's membership discipline) —
/// the click is a plain toggle of `clicked` only. The returned anchor is
/// ALWAYS `clicked`: the anchor is the last directly clicked row.
nonisolated func applyRangeToggle(
    anchor: String?,
    clicked: String,
    orderedIDs: [String],
    current: Set<String>
) -> (selection: Set<String>, newAnchor: String) {
    let newState = !current.contains(clicked)
    var selection = current

    func apply(_ id: String) {
        if newState {
            selection.insert(id)
        } else {
            selection.remove(id)
        }
    }

    let anchorIndex = anchor.flatMap { candidate in
        orderedIDs.firstIndex { scalarExact($0, candidate) }
    }
    let clickedIndex = orderedIDs.firstIndex { scalarExact($0, clicked) }
    guard let anchorIndex, let clickedIndex else {
        apply(clicked)
        return (selection, clicked)
    }
    for id in orderedIDs[min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)] {
        apply(id)
    }
    return (selection, clicked)
}

// MARK: - Wave B align names (spec B5): the canonical-name rule

/// Spec B5 canonical rule for a near-match variant: the name equals its own
/// NFC form (scalar-exact — String == would mask canonical drift), has no
/// leading or trailing whitespace scalar, contains no invisible scalar, and
/// is non-empty.
nonisolated func isCanonicalAlignName(_ name: String) -> Bool {
    guard !name.isEmpty else { return false }
    guard scalarExact(name, name.precomposedStringWithCanonicalMapping) else { return false }
    let scalars = Array(name.unicodeScalars)
    if scalars.first?.properties.isWhitespace == true { return false }
    if scalars.last?.properties.isWhitespace == true { return false }
    return !scalars.contains { isInvisibleScalar($0) }
}

/// The qualifying variant names of a cluster, in variant order. Exactly one
/// -> the clear canonical; none or several -> Sergio picks in the sheet.
nonisolated func canonicalAlignCandidates(in cluster: PlaylistNearMatchCluster) -> [String] {
    cluster.variants.map(\.name).filter(isCanonicalAlignName)
}

/// One separately gated rename: the deviant copy pinned by persistent ID,
/// renamed to the canonical destination.
nonisolated struct AlignRename: Equatable, Sendable, Identifiable {
    let persistentId: String
    let currentName: String
    let canonicalName: String

    var id: String { persistentId }
}

/// Every rename an align pass needs: one per LISTING of every variant that
/// is not the canonical (a deviant variant with k same-name copies yields k
/// renames). N single-listing variants yield N-1 renames.
nonisolated func alignRenames(
    in cluster: PlaylistNearMatchCluster,
    canonicalName: String
) -> [AlignRename] {
    cluster.variants
        .filter { !scalarExact($0.name, canonicalName) }
        .flatMap { variant in
            variant.listings.map { listing in
                AlignRename(
                    persistentId: listing.persistentId,
                    currentName: variant.name,
                    canonicalName: canonicalName
                )
            }
        }
}

// MARK: - browser sort (display-only; never feeds a guard or plan)

nonisolated enum BrowserSortKey: String, Equatable, Sendable {
    case name
    case count
}

/// Stable re-ordering of an already-name-ordered array (the Core builder
/// emits name order): name ascending is the identity, name descending is the
/// reversal; count sorts stably (index tiebreak) so equal counts keep the
/// name order.
nonisolated func applyBrowserSort<T>(
    _ items: [T],
    key: BrowserSortKey,
    ascending: Bool,
    count: (T) -> Int
) -> [T] {
    switch key {
    case .name:
        return ascending ? items : items.reversed()
    case .count:
        return items.enumerated().sorted { a, b in
            let ca = count(a.element)
            let cb = count(b.element)
            if ca != cb { return ascending ? ca < cb : ca > cb }
            return a.offset < b.offset
        }.map(\.element)
    }
}

// MARK: - unified merge list (2026-08-11 design): one alphabetical row per
// same-name group AND singleton

/// One row of the merge tab's unified ALL PLAYLISTS checklist (2026-08-11
/// design): a same-name group (>= 2 copies, one row for the whole group) or
/// a singleton, either one optionally carrying its near-match twin's display
/// name. `id` is the group's exact name or the singleton's persistent ID —
/// the same identities `checkedGroupNames`/
/// `checkedFreeFormSingletonPersistentIds` already key by.
///
/// `nearMatchTwin` is the OTHER variant's exact display name when this row's
/// own name is one of the (>= 2) variants of a `sections.nearMatches`
/// cluster; `nil` for a row outside every cluster. It carries on BOTH kinds
/// (final review finding I2): the near-match buckets are built over exact-name
/// CLASSES, and a class with >= 2 copies is a GROUP — so an all-group cluster
/// ("Trance 2022" x2 vs "Trance 2022 " x2) exists, and without the twin on
/// group rows its badge, and with it the near-match inspector's rename hint
/// and Align names… entry point, were unreachable.
nonisolated enum MergeBrowserRow: Identifiable, Equatable, Sendable {
    case group(PlaylistNameGroup, nearMatchTwin: String?)
    case singleton(PlaylistListing, nearMatchTwin: String?)

    var id: String {
        switch self {
        case .group(let group, _): return group.name
        case .singleton(let listing, _): return listing.persistentId
        }
    }

    /// The row's near-match twin, whatever its kind.
    var nearMatchTwin: String? {
        switch self {
        case .group(_, let twin), .singleton(_, let twin): return twin
        }
    }

    /// How many SOURCE playlists this row contributes to a merge: all of a
    /// group's copies, or the one singleton.
    var sourcePlaylistCount: Int {
        switch self {
        case .group(let group, _): return group.copies.count
        case .singleton: return 1
        }
    }
}

/// The unified list header's count (2026-08-11 design, final review minor b):
/// SOURCE playlists across the displayed rows — every group row's copies plus
/// one per singleton row — so `ALL PLAYLISTS (N)` counts the same noun on the
/// merge tab as it does on the consolidate tab (which counts
/// `sections.allPlaylists`), and matches the footer's own
/// `Selected: N playlists` noun.
nonisolated func mergeSourceCount(rows: [MergeBrowserRow]) -> Int {
    rows.reduce(0) { $0 + $1.sourcePlaylistCount }
}

/// Build the unified merge-tab checklist: every eligible same-name group
/// (one row per group) interleaved with every singleton, in ONE alphabetical
/// order, filtered by `needle`, and sortable like every other browser list.
/// Mirrors `cleanupRows`' shape (pure, display-only, never a guard/plan
/// input).
///
/// `sections.groups`/`sections.singletons` are each already alphabetical on
/// their own (the Core builder's contract), but `nameOrdered`/
/// `alphabeticallyOrdered` — the comparator that produced that order — are
/// `ConsolidatorCore`-internal and not visible here. Rather than
/// re-implementing that collation, this looks up each row's position in
/// `sections.allPlaylists`, which the SAME Core builder already sorted with
/// that exact comparator over every listing (group copies included): a
/// same-name group's copies are exact-name-identical, so they sort
/// contiguously there, and the group's first copy (its own input-order-
/// preserved first element) stands in for the whole row's position.
nonisolated func mergeRows(
    sections: PlaylistBrowseSections,
    needle: String,
    key: BrowserSortKey,
    ascending: Bool
) -> [MergeBrowserRow] {
    let query = needle.lowercased()
    func matches(_ name: String) -> Bool {
        query.isEmpty || name.lowercased().contains(query)
    }

    let groups = sections.groups.filter { matches($0.name) }
    let singletons = sections.singletons.filter { matches($0.name) }

    func position(ofPersistentId persistentId: String) -> Int {
        sections.allPlaylists.firstIndex {
            scalarExact($0.persistentId, persistentId)
        } ?? Int.max
    }

    // Keyed by the row's exact NAME, not by kind: a near-match cluster's
    // variants are exact-name classes, and a class with >= 2 copies is a
    // group — so this resolves the twin for group rows and singleton rows
    // alike (finding I2).
    func nearMatchTwin(forName name: String) -> String? {
        for cluster in sections.nearMatches {
            guard cluster.variants.contains(where: { scalarExact($0.name, name) })
            else { continue }
            // The first OTHER variant, in the cluster's own (alphabetical)
            // variant order — deterministic; a cluster with more than two
            // variants simply keeps the first one that is not this row's
            // own name (documented simplification, brief 2026-08-11).
            return cluster.variants.first { !scalarExact($0.name, name) }?.name
        }
        return nil
    }

    var ranked: [(position: Int, row: MergeBrowserRow)] = groups.map { group in
        (
            position(ofPersistentId: group.copies[0].persistentId),
            .group(group, nearMatchTwin: nearMatchTwin(forName: group.name))
        )
    }
    ranked += singletons.map { listing in
        (
            position(ofPersistentId: listing.persistentId),
            .singleton(listing, nearMatchTwin: nearMatchTwin(forName: listing.name))
        )
    }
    ranked.sort { $0.position < $1.position }
    let rows = ranked.map(\.row)

    return applyBrowserSort(rows, key: key, ascending: ascending) { row in
        switch row {
        case .group(let group, _): return group.combinedTrackCount
        case .singleton(let listing, _): return listing.trackCount
        }
    }
}

// MARK: - shift-click range over the unified merge rows (finding I4)

/// Pure shift-click range toggle over the merge tab's DISPLAYED unified rows.
/// `applyRangeToggle` (above) walks ONE checkable id space; the unified list
/// mixes two — group names in `checkedGroupNames` and singleton persistent IDs
/// in `checkedFreeFormSingletonPersistentIds` — so a range that crosses both
/// kinds must write each crossed row into ITS OWN container. Semantics mirror
/// `applyRangeToggle` exactly: the clicked row's NEW state applies to the
/// inclusive [anchor, clicked] span of DISPLAY order in either direction; no
/// usable anchor (nil, or absent from `rows`) degrades to a plain toggle of the
/// clicked row; the returned anchor is ALWAYS `clicked` (the anchor is the last
/// directly clicked row, of EITHER kind).
///
/// Both containers come in whole and go out whole: checked group names hidden
/// by the active filter keep their relative order ahead of the displayed ones
/// (the pre-unification reconciliation, preserved), and hidden singleton checks
/// survive untouched because only displayed persistent IDs are written. Group
/// membership is SCALAR-exact throughout — never `Set<String>`, whose hashing
/// merges canonically-equivalent names.
///
/// A `clicked` id absent from `rows` leaves both containers untouched and still
/// re-anchors (a bare id carries no row kind, so there is nothing to toggle);
/// the model's own guards make that unreachable in practice.
nonisolated func applyMergeRangeToggle(
    anchor: String?,
    clicked: String,
    rows: [MergeBrowserRow],
    checkedGroupNames: [String],
    checkedSingletonIds: Set<String>
) -> (groupNames: [String], singletonIds: Set<String>, newAnchor: String) {
    func isChecked(_ row: MergeBrowserRow) -> Bool {
        switch row {
        case .group(let group, _):
            return checkedGroupNames.contains { scalarExact($0, group.name) }
        case .singleton(let listing, _):
            return checkedSingletonIds.contains(listing.persistentId)
        }
    }

    let orderedIDs = rows.map(\.id)
    guard let clickedIndex = orderedIDs.firstIndex(where: { scalarExact($0, clicked) }) else {
        return (checkedGroupNames, checkedSingletonIds, clicked)
    }
    let newState = !isChecked(rows[clickedIndex])
    let anchorIndex = anchor.flatMap { candidate in
        orderedIDs.firstIndex { scalarExact($0, candidate) }
    }
    let otherEnd = anchorIndex ?? clickedIndex
    let span = min(otherEnd, clickedIndex)...max(otherEnd, clickedIndex)

    var singletonIds = checkedSingletonIds
    var crossedGroupNames: [String] = []
    for row in rows[span] {
        switch row {
        case .group(let group, _):
            crossedGroupNames.append(group.name)
        case .singleton(let listing, _):
            if newState {
                singletonIds.insert(listing.persistentId)
            } else {
                singletonIds.remove(listing.persistentId)
            }
        }
    }

    let displayedGroupNames: [String] = rows.compactMap { row in
        guard case .group(let group, _) = row else { return nil }
        return group.name
    }
    let hidden = checkedGroupNames.filter { checked in
        !displayedGroupNames.contains { scalarExact($0, checked) }
    }
    let displayedChecked = displayedGroupNames.filter { name in
        if crossedGroupNames.contains(where: { scalarExact($0, name) }) { return newState }
        return checkedGroupNames.contains { scalarExact($0, name) }
    }
    return (hidden + displayedChecked, singletonIds, clicked)
}

// MARK: - unified merge surface copy (final review minor d)

/// Every verbatim string the unified merge surface shows outside a plan
/// artifact — header, footer count, both footer actions with their help text,
/// and the two row advisories. Centralized so `MergeSurfaceCopyTests` can pin
/// the exact wording: these strings are the surface's contract with Sergio
/// (the spec quotes several of them verbatim), and a silent copy edit is
/// exactly the class of change that shipped an imperative "delete it first to
/// reprocess" advisory onto a row that no longer needs deleting (finding C1).
nonisolated enum MergeSurfaceCopy {
    /// The unified list's section header. `sourceCount` is
    /// `mergeSourceCount(rows:)` — group copies plus singletons, the same
    /// noun the footer counts.
    static func allPlaylistsHeader(sourceCount: Int) -> String {
        "ALL PLAYLISTS (\(sourceCount))"
    }

    /// The footer's selection readout (`mergeSelectedSourceCount`).
    static func selectedSources(count: Int) -> String {
        "Selected: \(count) playlists"
    }

    static let mergeAsOneTitle = "Merge selected as one\u{2026}"

    static let mergeAsOneHelp =
        "Combine every checked group and singleton into ONE new playlist, "
        + "named \u{201C}<first source> \u{2014} Merged\u{201D}."

    static let mergeEachGroupTitle = "Merge each group separately"

    static let mergeEachGroupHelp =
        "Runs one merge per checked group. Uncheck singletons to use this, "
        + "or use Merge selected as one."

    /// The `near match` chip's tooltip (both row kinds).
    static func nearMatchChipHelp(twin: String) -> String {
        "Near match: differs from \u{201C}\(twin)\u{201D} only by invisible "
            + "characters or edge whitespace \u{2014} select the row for the "
            + "rename hint."
    }

    /// The `already merged` chip's tooltip on a SINGLETON row — purely
    /// informational (finding C1): a singleton's checkbox contributes a SOURCE
    /// to "Merge selected as one…", whose target is named after the FIRST
    /// source, so an existing "<own name> — Merged" sibling is not a collision
    /// and nothing has to be deleted to use this row again.
    static func alreadyMergedSingletonAdvisory(sourceName: String) -> String {
        "A \u{201C}\(sourceName) \u{2014} Merged\u{201D} playlist exists "
            + "\u{2014} created by an earlier merge."
    }

    /// The `already merged` chip/checkbox tooltip on a GROUP row, where the
    /// per-group merge target IS "<name> — Merged": that target already
    /// existing does block a re-run, so this one stays imperative.
    static func alreadyMergedGroupHelp(sourceName: String) -> String {
        "Already merged: \u{201C}\(sourceName) \u{2014} Merged\u{201D} exists. "
            + "Review it, then clean up the sources; delete it first to "
            + "reprocess."
    }
}
