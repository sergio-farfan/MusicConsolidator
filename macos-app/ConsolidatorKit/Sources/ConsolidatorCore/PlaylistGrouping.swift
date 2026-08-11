// PlaylistGrouping.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// M8 — eligibility grouping for the sectioned source browser (design Option
// B). This is the first ConsolidatorCore surface WITHOUT a Python reference implementation
// counterpart: it derives browser sections from the playlist-enumeration
// listing (name + persistent ID + track count per playlist) and never
// touches plans, fingerprints, or the strict duplicate key.
//
// It lives in ConsolidatorCore (sanctioned by the M8 brief) because the
// near-match normalization reuses `trimPythonWhitespace` — the internal
// Python-strip parity table — and duplicating that table in the app layer
// would recreate the M4 ScalarSupport drift risk.
//
// Contract guarantees (fixed, see AGENTS.md "Same-name playlist merge" and
// its 2026-08-06 free-form amendment):
// - `groups` contains ONLY exact-scalar same-name classes with N >= 2
//   copies. The SAME-NAME merge path arms exclusively from `groups`. (The
//   2026-08-06 free-form path arms from an explicit user selection of any
//   groups and singletons instead — a separate, PID-pinned plan variant; it
//   does not widen what `groups` means here.)
// - `nearMatches` is ADVISORY: names that collide after the sweep
//   normalization (strip Cf format scalars, then collapse python-whitespace
//   runs and trim — " ".join(name.split()), the controller's 2026-08-02
//   library-sweep semantics that found the 7 trailing-space twin pairs) but
//   differ exactly. A near match is never a same-name GROUP — the UI shows a
//   rename hint — though its variants, being singletons, can be picked
//   individually for a free-form merge.
// - Name classes are keyed SCALAR-exactly (never Swift String ==):
//   canonically-equivalent-but-scalar-different names stay distinct classes,
//   exactly as the audit's exact-name filter treats them.

import Foundation

// MARK: - the enumeration listing model

/// One playlist as the enumeration script reports it: identity and counts
/// only, no tracks (the audit reads tracks later). `specialKind`/`isSmart`
/// annotate the kinds the read JXA's inclusion set already contains (smart
/// playlists, folder playlists).
public struct PlaylistListing: Equatable, Sendable {
    /// Session-scoped numeric playlist id (used only for ascending ordering;
    /// persistent IDs are the stable identity).
    public let playlistId: Double
    public let name: String
    public let persistentId: String
    public let trackCount: Int
    public let isSmart: Bool
    /// The raw `special kind` enum name ("none", "folder", "Genius", ...).
    public let specialKind: String

    public init(
        playlistId: Double,
        name: String,
        persistentId: String,
        trackCount: Int,
        isSmart: Bool,
        specialKind: String
    ) {
        self.playlistId = playlistId
        self.name = name
        self.persistentId = persistentId
        self.trackCount = trackCount
        self.isSmart = isSmart
        self.specialKind = specialKind
    }
}

// MARK: - browse sections

/// One exact-scalar same-name class with N >= 2 copies — the only mergeable
/// unit. Copies keep input order (ascending playlist id when the listing
/// comes from `parsePlaylistListing`).
public struct PlaylistNameGroup: Equatable, Sendable {
    public let name: String
    public let copies: [PlaylistListing]

    /// Sum of the copies' track counts — the merge audit's combined-input
    /// upper bound (the audit computes the real dedup numbers).
    public var combinedTrackCount: Int {
        copies.reduce(0) { $0 + $1.trackCount }
    }

    public init(name: String, copies: [PlaylistListing]) {
        self.name = name
        self.copies = copies
    }
}

/// One exact name inside a near-match cluster, with every playlist bearing
/// that exact name.
public struct PlaylistNearMatchVariant: Equatable, Sendable {
    public let name: String
    public let listings: [PlaylistListing]

    public init(name: String, listings: [PlaylistListing]) {
        self.name = name
        self.listings = listings
    }
}

/// Names that collide after the sweep normalization but differ exactly —
/// the rename-to-merge class (trailing space / ZWSP / NBSP twins). Always
/// >= 2 variants; never a same-name GROUP (the variants can still be picked
/// individually as singletons for a 2026-08-06 free-form merge).
public struct PlaylistNearMatchCluster: Equatable, Sendable {
    /// The shared normalized form (`nearMatchNormalizedName` of every
    /// variant) — also the natural rename target.
    public let normalizedName: String
    public let variants: [PlaylistNearMatchVariant]

    public init(normalizedName: String, variants: [PlaylistNearMatchVariant]) {
        self.normalizedName = normalizedName
        self.variants = variants
    }
}

/// The complete sectioning of one enumeration listing.
public struct PlaylistBrowseSections: Equatable, Sendable {
    /// Every playlist, alphabetical (casefold-insensitive, scalar tie-break).
    public let allPlaylists: [PlaylistListing]
    /// Exact-name classes with N >= 2 copies, alphabetical by name.
    public let groups: [PlaylistNameGroup]
    /// Exact-name classes with exactly one playlist, alphabetical by name.
    /// A singleton may ALSO appear inside a near-match cluster.
    public let singletons: [PlaylistListing]
    /// Normalization-collision clusters, ordered by normalized name.
    public let nearMatches: [PlaylistNearMatchCluster]

    public init(
        allPlaylists: [PlaylistListing],
        groups: [PlaylistNameGroup],
        singletons: [PlaylistListing],
        nearMatches: [PlaylistNearMatchCluster]
    ) {
        self.allPlaylists = allPlaylists
        self.groups = groups
        self.singletons = singletons
        self.nearMatches = nearMatches
    }
}

// MARK: - the sweep normalization

/// The 2026-08-02 library-sweep normalization (M8 fix round 1 semantics):
///
/// 1. Strip Unicode Cf (format) scalars anywhere in the name — the
///    ZWSP/FEFF/soft-hyphen detection the brief mandates. Cf-strip runs
///    FIRST so a format scalar can neither shield trailing whitespace from
///    the trim ("X \u{200B}" -> "X") nor split an interior whitespace run
///    ("A \u{200B} B" is ONE run).
/// 2. Collapse every run of Python whitespace — the byte-verified 29-scalar
///    `pythonStripScalars` set from Normalize.swift, reused, never
///    hand-copied — to a single U+0020, then trim. Steps 2+3 together are
///    exactly the sweep's `" ".join(name.split())` (Python str.split()
///    splits on the full whitespace set and drops leading/trailing runs).
///
/// No casefolding and no canonical normalization — do not broaden without a
/// fresh design decision.
public func nearMatchNormalizedName(_ name: String) -> String {
    var collapsed = String.UnicodeScalarView()
    var inWhitespaceRun = false
    for scalar in name.unicodeScalars {
        if scalar.properties.generalCategory == .format { continue }
        if pythonStripScalars.contains(scalar) {
            if !inWhitespaceRun {
                collapsed.append(" ")
                inWhitespaceRun = true
            }
        } else {
            collapsed.append(scalar)
            inWhitespaceRun = false
        }
    }
    return trimPythonWhitespace(String(collapsed))
}

// MARK: - grouping

/// A dictionary key that preserves scalar identity. Swift String keys hash
/// by canonical equivalence and would silently MERGE NFC/NFD-different
/// names into one class.
private struct ScalarKey: Hashable {
    let scalars: [UInt32]

    init(_ value: String) {
        self.scalars = value.unicodeScalars.map(\.value)
    }
}

/// Alphabetical ordering for display: Python-casefold-insensitive, with
/// scalar-exact tie-breaks (deterministic and locale-independent).
private func alphabeticallyOrdered(_ lhs: PlaylistListing, _ rhs: PlaylistListing) -> Bool {
    let lhsFold = pythonCasefold(lhs.name)
    let rhsFold = pythonCasefold(rhs.name)
    if !scalarEqual(lhsFold, rhsFold) { return scalarLess(lhsFold, rhsFold) }
    if !scalarEqual(lhs.name, rhs.name) { return scalarLess(lhs.name, rhs.name) }
    if !scalarEqual(lhs.persistentId, rhs.persistentId) {
        return scalarLess(lhs.persistentId, rhs.persistentId)
    }
    return lhs.playlistId < rhs.playlistId
}

private func nameOrdered(_ lhs: String, _ rhs: String) -> Bool {
    let lhsFold = pythonCasefold(lhs)
    let rhsFold = pythonCasefold(rhs)
    if !scalarEqual(lhsFold, rhsFold) { return scalarLess(lhsFold, rhsFold) }
    return scalarLess(lhs, rhs)
}

/// Section one enumeration listing into {groups, singletons, nearMatches}
/// plus the flat alphabetical list. Pure and deterministic.
public func buildPlaylistBrowseSections(from listings: [PlaylistListing]) -> PlaylistBrowseSections {
    // Exact-scalar name classes, preserving input order within a class.
    var classOrder: [ScalarKey] = []
    var classesByKey: [ScalarKey: (name: String, listings: [PlaylistListing])] = [:]
    for listing in listings {
        let key = ScalarKey(listing.name)
        if classesByKey[key] == nil {
            classOrder.append(key)
            classesByKey[key] = (listing.name, [listing])
        } else {
            classesByKey[key]!.listings.append(listing)
        }
    }
    let classes = classOrder.compactMap { classesByKey[$0] }

    let groups = classes
        .filter { $0.listings.count >= 2 }
        .map { PlaylistNameGroup(name: $0.name, copies: $0.listings) }
        .sorted { nameOrdered($0.name, $1.name) }

    let singletons = classes
        .filter { $0.listings.count == 1 }
        .map { $0.listings[0] }
        .sorted(by: alphabeticallyOrdered)

    // Near matches: bucket the exact-name classes by the sweep-normalized
    // name; any bucket spanning >= 2 distinct exact names is a cluster.
    var bucketOrder: [ScalarKey] = []
    var buckets: [ScalarKey: (normalized: String, classes: [(name: String, listings: [PlaylistListing])])] = [:]
    for nameClass in classes {
        let normalized = nearMatchNormalizedName(nameClass.name)
        let key = ScalarKey(normalized)
        if buckets[key] == nil {
            bucketOrder.append(key)
            buckets[key] = (normalized, [nameClass])
        } else {
            buckets[key]!.classes.append(nameClass)
        }
    }
    let nearMatches = bucketOrder
        .compactMap { buckets[$0] }
        .filter { $0.classes.count >= 2 }
        .map { bucket in
            PlaylistNearMatchCluster(
                normalizedName: bucket.normalized,
                variants: bucket.classes
                    .map { PlaylistNearMatchVariant(name: $0.name, listings: $0.listings) }
                    .sorted { nameOrdered($0.name, $1.name) }
            )
        }
        .sorted { nameOrdered($0.normalizedName, $1.normalizedName) }

    return PlaylistBrowseSections(
        allPlaylists: listings.sorted(by: alphabeticallyOrdered),
        groups: groups,
        singletons: singletons,
        nearMatches: nearMatches
    )
}
