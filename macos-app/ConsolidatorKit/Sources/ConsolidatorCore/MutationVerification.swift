// MutationVerification.swift
// Wave B (spec B1) — the inverted, bijective readback post-condition. The
// apply verifiers prove "sources unchanged"; this verifier proves: exactly
// this persistent ID changed in exactly the approved way, and NOTHING else
// changed. Strict persistent-ID-keyed bijection between the pre-mutation
// baseline and a fresh post-mutation listing, checked in BOTH directions,
// refusing outright on duplicate persistent IDs in either listing.
//
// Per-PID comparison scope (contract-fixed): plain user playlists
// (!isSmart && specialKind == "none", classified from the BEFORE entry) by
// PID + name (scalar-exact) + track count; smart and special-kind playlists
// by PID + name only, their count drift reported informationally (their
// counts move on their own and must not fail a correct mutation after the
// fact). All name comparisons use scalarEqual — Swift String == would
// silently ACCEPT canonically-equivalent (NFC/NFD) drift.
//
// This function only REPORTS: it never repairs and never retries. Callers
// (MusicBridgeSession.performMutation) treat any non-empty `mismatches` as a
// terminal fail-closed verification failure.

import Foundation

/// The approved change the fresh listing must show — nothing more.
public enum MutationExpectation: Equatable, Sendable {
    case deleted(persistentID: String)
    case renamed(persistentID: String, newName: String)
}

/// The verdict: empty `mismatches` means the mutation is exactly right.
/// `informational` carries smart/special count drift lines for the result
/// report; it never affects the verdict.
public struct ListingDiffResult: Equatable, Sendable {
    public let mismatches: [String]
    public let informational: [String]

    public init(mismatches: [String], informational: [String]) {
        self.mismatches = mismatches
        self.informational = informational
    }
}

/// A dictionary key that preserves scalar identity — Swift String keys hash
/// by canonical equivalence and would merge NFC/NFD-different IDs. Private
/// twin of PlaylistGrouping.swift's ScalarKey (both file-private by design).
private struct ScalarKey: Hashable {
    let scalars: [UInt32]

    init(_ value: String) {
        self.scalars = value.unicodeScalars.map(\.value)
    }
}

/// Contract classification: only plain user playlists get the strict
/// track-count comparison. Classified from the BEFORE entry.
private func isPlainUserPlaylist(_ entry: PlaylistListing) -> Bool {
    !entry.isSmart && scalarEqual(entry.specialKind, "none")
}

/// Bijective PID-keyed diff (spec B1). Returns empty mismatches when the
/// mutation is exactly right; otherwise verbatim mismatch strings, in a
/// deterministic order: duplicate refusals (before then after), pinned-PID
/// post-condition, forward pass over the other before-entries in scalar
/// persistent-ID order, then additions in scalar persistent-ID order.
public func listingMutationDiff(
    before: [PlaylistListing],
    after: [PlaylistListing],
    expectation: MutationExpectation
) -> ListingDiffResult {
    // 1. Duplicate persistent IDs make the diff ambiguous: refuse outright.
    var duplicateMismatches: [String] = []
    func indexByPid(_ listing: [PlaylistListing], label: String) -> [ScalarKey: PlaylistListing] {
        var byPid: [ScalarKey: PlaylistListing] = [:]
        var reported: Set<ScalarKey> = []
        for entry in listing {
            let key = ScalarKey(entry.persistentId)
            if byPid[key] != nil {
                if reported.insert(key).inserted {
                    duplicateMismatches.append(
                        "duplicate persistent ID \(entry.persistentId) in \(label) listing"
                    )
                }
            } else {
                byPid[key] = entry
            }
        }
        return byPid
    }
    let beforeByPid = indexByPid(before, label: "pre-mutation")
    let afterByPid = indexByPid(after, label: "post-mutation")
    if !duplicateMismatches.isEmpty {
        return ListingDiffResult(mismatches: duplicateMismatches, informational: [])
    }

    let pinnedID: String
    switch expectation {
    case .deleted(let persistentID):
        pinnedID = persistentID
    case .renamed(let persistentID, _):
        pinnedID = persistentID
    }
    let pinnedKey = ScalarKey(pinnedID)

    // 2. A baseline lacking the pinned playlist cannot verify the mutation.
    guard let pinnedBefore = beforeByPid[pinnedKey] else {
        return ListingDiffResult(
            mismatches: ["pinned persistent ID \(pinnedID) is not in the pre-mutation baseline"],
            informational: []
        )
    }

    var mismatches: [String] = []
    var informational: [String] = []

    // 3. The pinned entry's own post-condition.
    switch expectation {
    case .deleted:
        if let survivor = afterByPid[pinnedKey] {
            mismatches.append(
                "expected deleted playlist \(pinnedID) is still present (name: \(survivor.name))"
            )
        }
    case .renamed(_, let newName):
        if let renamed = afterByPid[pinnedKey] {
            if !scalarEqual(renamed.name, newName) {
                mismatches.append(
                    "renamed playlist \(pinnedID) bears name \(renamed.name), expected \(newName)"
                )
            }
            if renamed.trackCount != pinnedBefore.trackCount {
                mismatches.append(
                    "renamed playlist \(pinnedID) track count changed: "
                        + "before \(pinnedBefore.trackCount), after \(renamed.trackCount)"
                )
            }
        } else {
            mismatches.append(
                "expected renamed playlist \(pinnedID) missing from post-mutation listing"
            )
        }
    }

    // 4. Forward bijection over every OTHER before-entry.
    let others = before
        .filter { !scalarEqual($0.persistentId, pinnedID) }
        .sorted { scalarLess($0.persistentId, $1.persistentId) }
    for entry in others {
        guard let counterpart = afterByPid[ScalarKey(entry.persistentId)] else {
            mismatches.append(
                "playlist \(entry.persistentId) (\(entry.name)) missing from post-mutation listing"
            )
            continue
        }
        if !scalarEqual(counterpart.name, entry.name) {
            mismatches.append(
                "playlist \(entry.persistentId) name changed: "
                    + "before \(entry.name), after \(counterpart.name)"
            )
        }
        if counterpart.trackCount != entry.trackCount {
            if isPlainUserPlaylist(entry) {
                mismatches.append(
                    "playlist \(entry.persistentId) (\(entry.name)) track count changed: "
                        + "before \(entry.trackCount), after \(counterpart.trackCount)"
                )
            } else {
                informational.append(
                    "smart/special playlist \(entry.persistentId) (\(entry.name)) "
                        + "track count drifted: \(entry.trackCount) -> \(counterpart.trackCount)"
                )
            }
        }
    }

    // 5. Reverse bijection: nothing may have been added.
    let additions = after
        .filter { beforeByPid[ScalarKey($0.persistentId)] == nil }
        .sorted { scalarLess($0.persistentId, $1.persistentId) }
    for entry in additions {
        mismatches.append(
            "playlist \(entry.persistentId) (\(entry.name)) added during mutation window"
        )
    }

    return ListingDiffResult(mismatches: mismatches, informational: informational)
}
