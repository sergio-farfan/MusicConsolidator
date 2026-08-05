// ScalarEquality.swift
// Code-point-exact comparison helpers, internal to ConsolidatorCore.
//
// Python compares strings code-point-for-code-point (str ==, dataclass ==,
// substring `in`). Swift `String ==` instead uses Unicode canonical
// equivalence and would treat canonically-equivalent-but-scalar-different
// values as equal — the exact divergence the M1 review flagged for
// SemanticKey. Everywhere the reference's behavior depends on string equality
// (resolver winner/omitted partition, plan-integrity snapshot and canonical
// recompute comparisons), the port must use these scalar-level helpers, NOT
// `==` on String or on the synthesized struct conformances.

import Foundation

func scalarEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
}

/// Code-point substring search, mirroring Python's `needle in haystack`.
/// (Swift's `String.contains` matches by grapheme cluster with canonical
/// equivalence, which can disagree around combining marks.)
func scalarContains(_ haystack: String, _ needle: String) -> Bool {
    let haystackScalars = Array(haystack.unicodeScalars)
    let needleScalars = Array(needle.unicodeScalars)
    if needleScalars.isEmpty { return true }
    guard haystackScalars.count >= needleScalars.count else { return false }
    for start in 0...(haystackScalars.count - needleScalars.count) {
        var matched = true
        for offset in 0..<needleScalars.count where haystackScalars[start + offset] != needleScalars[offset] {
            matched = false
            break
        }
        if matched { return true }
    }
    return false
}

/// Python `str < str`: code-point lexicographic order.
func scalarLess(_ lhs: String, _ rhs: String) -> Bool {
    lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars)
}

func scalarEqual(_ lhs: TrackSnapshot, _ rhs: TrackSnapshot) -> Bool {
    lhs.sourceIndex == rhs.sourceIndex
        && lhs.databaseId == rhs.databaseId
        && scalarEqual(lhs.persistentId, rhs.persistentId)
        && scalarEqual(lhs.title, rhs.title)
        && scalarEqual(lhs.artist, rhs.artist)
        && scalarEqual(lhs.album, rhs.album)
        && lhs.durationMs == rhs.durationMs
        && scalarEqual(lhs.kind, rhs.kind)
        && lhs.bitRateKbps == rhs.bitRateKbps
        && lhs.sampleRateHz == rhs.sampleRateHz
        && scalarEqual(lhs.cloudStatus, rhs.cloudStatus)
        && lhs.isFileTrack == rhs.isFileTrack
}

func scalarEqual(_ lhs: [TrackSnapshot], _ rhs: [TrackSnapshot]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { scalarEqual($0, $1) }
}

func scalarEqual(
    _ lhs: DuplicateDecision.OmittedReason,
    _ rhs: DuplicateDecision.OmittedReason
) -> Bool {
    lhs.sourceIndex == rhs.sourceIndex && scalarEqual(lhs.reason, rhs.reason)
}

func scalarEqual(_ lhs: DuplicateDecision, _ rhs: DuplicateDecision) -> Bool {
    lhs.firstSourceIndex == rhs.firstSourceIndex
        && scalarEqual(lhs.winner, rhs.winner)
        && scalarEqual(lhs.omitted, rhs.omitted)
        && lhs.reasonByOmittedIndex.count == rhs.reasonByOmittedIndex.count
        && zip(lhs.reasonByOmittedIndex, rhs.reasonByOmittedIndex).allSatisfy { scalarEqual($0, $1) }
}

func scalarEqual(_ lhs: [DuplicateDecision], _ rhs: [DuplicateDecision]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { scalarEqual($0, $1) }
}

func scalarEqual(_ lhs: PlaylistSnapshot, _ rhs: PlaylistSnapshot) -> Bool {
    scalarEqual(lhs.name, rhs.name)
        && scalarEqual(lhs.persistentId, rhs.persistentId)
        && scalarEqual(lhs.tracks, rhs.tracks)
}

func scalarEqual(_ lhs: [PlaylistSnapshot], _ rhs: [PlaylistSnapshot]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { scalarEqual($0, $1) }
}

func scalarEqual(_ lhs: ConsolidationPlan, _ rhs: ConsolidationPlan) -> Bool {
    scalarEqual(lhs.sourcePlaylistName, rhs.sourcePlaylistName)
        && scalarEqual(lhs.sourcePlaylistPersistentId, rhs.sourcePlaylistPersistentId)
        && scalarEqual(lhs.sourceFingerprint, rhs.sourceFingerprint)
        && lhs.sourceTrackCount == rhs.sourceTrackCount
        && scalarEqual(lhs.sourceTracks, rhs.sourceTracks)
        && lhs.winnerSourceIndexes == rhs.winnerSourceIndexes
        && scalarEqual(lhs.decisions, rhs.decisions)
        && lhs.nonEligibleSourceIndexes == rhs.nonEligibleSourceIndexes
}

func scalarEqual(_ lhs: MergePlan, _ rhs: MergePlan) -> Bool {
    scalarEqual(lhs.mergedPlaylistSourceName, rhs.mergedPlaylistSourceName)
        && scalarEqual(lhs.copies, rhs.copies)
        && scalarEqual(lhs.mergeFingerprint, rhs.mergeFingerprint)
        && lhs.winnerSourceIndexes == rhs.winnerSourceIndexes
        && scalarEqual(lhs.decisions, rhs.decisions)
        && lhs.nonEligibleSourceIndexes == rhs.nonEligibleSourceIndexes
}
