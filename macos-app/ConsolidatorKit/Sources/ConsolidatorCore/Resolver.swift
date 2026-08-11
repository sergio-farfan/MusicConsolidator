// Resolver.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Swift port of apple_music_consolidator/resolver.py — deterministic duplicate
// resolution for immutable playlist snapshots. The Python reference implementation governs every
// behavioral detail; line references below point into resolver.py.
//
// Fingerprints (locked plan decision): the Swift side owns its OWN canonical
// encoding (JSONEncoder with sorted keys) hashed with CryptoKit SHA-256. They
// are deliberately NOT byte-identical to the Python fingerprints; parity tests
// compare RESULTS (winners/decisions/ordering), never fingerprint bytes. What
// is preserved is the reference's CONTRACT: the fingerprint covers every input
// field, so any metadata drift invalidates a previously persisted plan.

import CryptoKit
import Foundation

/// Thrown where the reference raises ValueError inside the resolver.
public struct ResolverError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }

    public init(_ message: String) {
        self.message = message
    }
}

/// Return whether the track is not marked unavailable by Apple Music.
/// Reference (resolver.py:18-20): `cloud_status.strip().casefold() != "no longer available"`.
/// Comparison is code-point exact, like Python `!=`.
public func isAvailable(_ track: TrackSnapshot) -> Bool {
    !scalarEqual(
        pythonCasefold(trimPythonWhitespace(track.cloudStatus)),
        "no longer available"
    )
}

/// Return whether the track kind identifies a lossless audio format.
/// Reference (resolver.py:23-26): casefolded substring search — code-point
/// based (`in`), hence `scalarContains` rather than `String.contains`.
public func isLossless(_ track: TrackSnapshot) -> Bool {
    let kind = pythonCasefold(track.kind)
    return scalarContains(kind, "lossless")
        || scalarContains(kind, "aiff")
        || scalarContains(kind, "wav")
}

/// The total ordering used to choose a duplicate winner. Mirrors the reference's
/// 6-part tuple (resolver.py:29-38):
/// `(0 if available else 1, 0 if lossless else 1, -(sample_rate_hz or 0),
///   -(bit_rate_kbps or 0), source_index, persistent_id)`.
/// `nil` rates negate to 0 exactly like Python's `or 0` (both `None` and `0`
/// collapse to `0`). The final `persistentId` tie-breaker compares by code
/// point, like Python string ordering.
public struct QualitySortKey: Equatable, Sendable {
    public let unavailableRank: Int
    public let lossyRank: Int
    public let negatedSampleRate: Int
    public let negatedBitRate: Int
    public let sourceIndex: Int
    public let persistentId: String

    public static func == (lhs: QualitySortKey, rhs: QualitySortKey) -> Bool {
        lhs.unavailableRank == rhs.unavailableRank
            && lhs.lossyRank == rhs.lossyRank
            && lhs.negatedSampleRate == rhs.negatedSampleRate
            && lhs.negatedBitRate == rhs.negatedBitRate
            && lhs.sourceIndex == rhs.sourceIndex
            && scalarEqual(lhs.persistentId, rhs.persistentId)
    }
}

extension QualitySortKey: Comparable {
    public static func < (lhs: QualitySortKey, rhs: QualitySortKey) -> Bool {
        if lhs.unavailableRank != rhs.unavailableRank { return lhs.unavailableRank < rhs.unavailableRank }
        if lhs.lossyRank != rhs.lossyRank { return lhs.lossyRank < rhs.lossyRank }
        if lhs.negatedSampleRate != rhs.negatedSampleRate { return lhs.negatedSampleRate < rhs.negatedSampleRate }
        if lhs.negatedBitRate != rhs.negatedBitRate { return lhs.negatedBitRate < rhs.negatedBitRate }
        if lhs.sourceIndex != rhs.sourceIndex { return lhs.sourceIndex < rhs.sourceIndex }
        return scalarLess(lhs.persistentId, rhs.persistentId)
    }
}

/// Return the total ordering used to choose a duplicate winner.
public func qualitySortKey(_ track: TrackSnapshot) -> QualitySortKey {
    QualitySortKey(
        unavailableRank: isAvailable(track) ? 0 : 1,
        lossyRank: isLossless(track) ? 0 : 1,
        negatedSampleRate: -(track.sampleRateHz ?? 0),
        negatedBitRate: -(track.bitRateKbps ?? 0),
        sourceIndex: track.sourceIndex,
        persistentId: track.persistentId
    )
}

private func sha256Hex<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // Encoding model structs cannot fail: every field is JSON-representable
    // (no Double, no non-string dictionary keys).
    let payload = try! encoder.encode(value)
    return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
}

/// Hash every input field so metadata drift invalidates prior plans.
/// Reference contract: resolver.py:41-45 (Swift-canonical bytes; see file header).
public func sourceFingerprint(_ tracks: [TrackSnapshot]) -> String {
    sha256Hex(tracks)
}

/// Describe the first quality criterion that favoured the winner.
/// Reference (resolver.py:48-61): the reason label set is a closed contract
/// validated by PlanIntegrity. String comparison is code-point exact.
public func decisiveReason(winner: TrackSnapshot, omitted: TrackSnapshot) throws -> String {
    if isAvailable(winner) != isAvailable(omitted) { return "available" }
    if isLossless(winner) != isLossless(omitted) { return "lossless kind" }
    if (winner.sampleRateHz ?? 0) != (omitted.sampleRateHz ?? 0) { return "sample rate" }
    if (winner.bitRateKbps ?? 0) != (omitted.bitRateKbps ?? 0) { return "bit rate" }
    if winner.sourceIndex != omitted.sourceIndex { return "source order" }
    if !scalarEqual(winner.persistentId, omitted.persistentId) { return "persistent ID" }
    throw ResolverError("duplicate tracks must differ by a quality tie-breaker")
}

/// Build a stable consolidation plan without changing the source playlist.
/// Reference: resolver.py:64-107. Grouping preserves the reference's dict-insertion
/// iteration order (Swift `Dictionary` is unordered, so groups live in an
/// ordered array indexed through the keyed dictionary), and both final sorts
/// rely on Swift's guaranteed-stable `sort()` to mirror Python's stable sort.
public func buildPlan(_ source: PlaylistSnapshot) throws -> ConsolidationPlan {
    var groupIndexByKey: [SemanticKey: Int] = [:]
    var groups: [[TrackSnapshot]] = []
    var retained: [(Int, TrackSnapshot)] = []
    var nonEligibleSourceIndexes: [Int] = []

    for track in source.tracks {
        if let key = semanticKey(track) {
            if let existingIndex = groupIndexByKey[key] {
                groups[existingIndex].append(track)
            } else {
                groupIndexByKey[key] = groups.count
                groups.append([track])
            }
        } else {
            retained.append((track.sourceIndex, track))
            nonEligibleSourceIndexes.append(track.sourceIndex)
        }
    }

    var decisions: [DuplicateDecision] = []
    for group in groups {
        // Python `min(group, key=quality_sort_key)`: first minimal element.
        var winner = group[0]
        var winnerKey = qualitySortKey(winner)
        for candidate in group.dropFirst() {
            let candidateKey = qualitySortKey(candidate)
            if candidateKey < winnerKey {
                winner = candidate
                winnerKey = candidateKey
            }
        }
        let firstSourceIndex = group.map(\.sourceIndex).min()!
        retained.append((firstSourceIndex, winner))
        // Python `track != winner` is field-wise code-point equality.
        let omitted = group.filter { !scalarEqual($0, winner) }
        if !omitted.isEmpty {
            decisions.append(
                DuplicateDecision(
                    firstSourceIndex: firstSourceIndex,
                    winner: winner,
                    omitted: omitted,
                    reasonByOmittedIndex: try omitted.map { omittedTrack in
                        DuplicateDecision.OmittedReason(
                            sourceIndex: omittedTrack.sourceIndex,
                            reason: try decisiveReason(winner: winner, omitted: omittedTrack)
                        )
                    }
                )
            )
        }
    }

    retained.sort { $0.0 < $1.0 }
    decisions.sort { $0.firstSourceIndex < $1.firstSourceIndex }
    return ConsolidationPlan(
        sourcePlaylistName: source.name,
        sourcePlaylistPersistentId: source.persistentId,
        sourceFingerprint: sourceFingerprint(source.tracks),
        sourceTrackCount: source.tracks.count,
        sourceTracks: source.tracks,
        winnerSourceIndexes: retained.map { $0.1.sourceIndex },
        decisions: decisions,
        nonEligibleSourceIndexes: nonEligibleSourceIndexes
    )
}

/// Hash every copy's identity and ordered tracks so any drift invalidates.
/// Reference contract: resolver.py:110-121 (Swift-canonical bytes; see header).
/// UNCHANGED for same-name plans — this is the exact function
/// `buildMergePlan` has always called; the free-form variant below is a
/// SEPARATE function precisely so this one, and every same-name plan's
/// `mergeFingerprint` value, stays byte-for-byte what it always was (the
/// Python-parity golden is the tripwire for that).
public func mergeFingerprint(_ copies: [PlaylistSnapshot]) -> String {
    sha256Hex(copies)
}

/// Canonical hash input for a FREE-FORM merge plan only (2026-08-06 review
/// finding I1): `mergeFingerprint(_:)` alone hashes just the copies, which
/// means a hand-edited `target_description` or `source_names` in a
/// persisted free-form plan.json passes every existing check — the
/// canonical-recompute-and-diff in `validateMergePlanIntegrity` otherwise
/// just ECHOES the persisted description straight back as its own
/// recompute input (there is nothing else in the plan to check it
/// against). Folding `targetDescription` and `sourceNames` into the hash
/// that gets PERSISTED alongside the plan turns that echo into a real
/// consistency check: `validateMergePlanIntegrity` recomputes this same
/// hash from the plan's own persisted fields and compares it to the
/// persisted `mergeFingerprint` — a plan whose description was edited
/// without recomputing the fingerprint to match no longer agrees with
/// itself, and load refuses. Same-name plans never call this; their
/// fingerprint input is untouched (see `mergeFingerprint(_:)` above).
private struct FreeFormFingerprintInput: Encodable {
    let copies: [PlaylistSnapshot]
    let targetDescription: String
    let sourceNames: [String]
}

public func freeFormMergeFingerprint(
    copies: [PlaylistSnapshot],
    targetDescription: String,
    sourceNames: [String]
) -> String {
    sha256Hex(
        FreeFormFingerprintInput(
            copies: copies, targetDescription: targetDescription, sourceNames: sourceNames
        )
    )
}

/// Build a stable merge plan by deduping the ordered copy concatenation.
/// Reference: resolver.py:124-137.
public func buildMergePlan(name: String, copies: [PlaylistSnapshot]) throws -> MergePlan {
    let combined = combineSourceTracks(copies)
    let consolidation = try buildPlan(
        PlaylistSnapshot(name: name, persistentId: "", tracks: combined)
    )
    return MergePlan(
        mergedPlaylistSourceName: name,
        copies: copies,
        mergeFingerprint: mergeFingerprint(copies),
        winnerSourceIndexes: consolidation.winnerSourceIndexes,
        decisions: consolidation.decisions,
        nonEligibleSourceIndexes: consolidation.nonEligibleSourceIndexes
    )
}

/// Build a free-form merge plan: the same dedup engine as `buildMergePlan`
/// (the UNCHANGED `build_plan` strict key over the caller-ordered copy
/// concatenation — 2026-08-06 free-form design, "Dedup" bullet), but the
/// copy set is pinned by explicit persistent ID rather than a shared name,
/// because free-form copies are not required to share a name.
///
/// `copies` must already be in playlist-ID order (the caller's
/// responsibility, mirrored from `buildMergePlan`'s same contract).
/// `sourceNames` is a caller-supplied, independently-recorded echo of each
/// copy's name in that SAME order — trusted call sites derive it directly
/// from `copies`, but it is validated here against `copies.map(\.name)`
/// rather than silently re-derived, so a caller bug (wrong order, stale
/// names) fails closed at plan-build time instead of surfacing later as a
/// silent provenance/description mismatch.
public func buildFreeFormMergePlan(
    copies: [PlaylistSnapshot],
    targetName: String,
    targetDescription: String,
    sourceNames: [String]
) throws -> MergePlan {
    guard sourceNames.count == copies.count,
        zip(sourceNames, copies).allSatisfy({ scalarEqual($0, $1.name) })
    else {
        throw ResolverError(
            "free-form merge source names do not match the supplied copies, in order"
        )
    }

    let combined = combineSourceTracks(copies)
    let consolidation = try buildPlan(
        PlaylistSnapshot(name: targetName, persistentId: "", tracks: combined)
    )
    return MergePlan(
        mergedPlaylistSourceName: targetName,
        copies: copies,
        mergeFingerprint: freeFormMergeFingerprint(
            copies: copies, targetDescription: targetDescription, sourceNames: sourceNames
        ),
        winnerSourceIndexes: consolidation.winnerSourceIndexes,
        decisions: consolidation.decisions,
        nonEligibleSourceIndexes: consolidation.nonEligibleSourceIndexes,
        sourcePersistentIDs: copies.map(\.persistentId),
        targetDescription: targetDescription,
        sourceNames: sourceNames
    )
}
