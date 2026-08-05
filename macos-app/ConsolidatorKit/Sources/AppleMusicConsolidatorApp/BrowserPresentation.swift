// BrowserPresentation.swift
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
