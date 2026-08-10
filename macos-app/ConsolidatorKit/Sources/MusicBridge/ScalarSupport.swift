// ScalarSupport.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Code-point-exact comparison helpers for the MusicBridge target.
//
// These mirror ConsolidatorCore's internal ScalarEquality helpers (only the
// subset the M4 builders need). They are duplicated rather than exposed from
// ConsolidatorCore because the M4 brief forbids touching the review-clean
// Core target, and Swift `String ==` / synthesized struct `==` use Unicode
// canonical equivalence where the Python reference implementation compares code points —
// exactly the divergence the fail-closed validators below must not have
// (a canonically-equivalent-but-scalar-different drift must be REJECTED,
// as the reference rejects it).

import Foundation
import ConsolidatorCore

func scalarEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
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
