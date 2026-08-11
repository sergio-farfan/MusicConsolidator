// PlanIntegrity.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Swift port of the VALIDATION half of apple_music_consolidator/audit.py:
// validate_plan_integrity / validate_merge_plan_integrity. Artifact writers
// and loaders (.plan.json/.detail.csv/.summary.md, atomic reservation,
// load_plan) are milestone M3 and intentionally absent here.
//
// Every check, its ORDER, and its message are ported verbatim from audit.py
// (line references below). Where the reference compares dataclasses/strings, the
// port uses code-point-exact comparison (see ScalarEquality.swift): Swift
// `String ==` canonical equivalence would ACCEPT canonically-equivalent-but-
// scalar-different tampering that the reference rejects — the wrong direction
// for a fail-closed gate.

import Foundation

/// Thrown where the reference raises ValueError inside the validators.
public struct PlanIntegrityError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }

    public init(_ message: String) {
        self.message = message
    }
}

/// The closed set of decisive reason labels (audit.py:20-27). ASCII-only, so
/// `Set<String>` membership is equivalent to Python's code-point membership.
let knownDecisiveReasons: Set<String> = [
    "available",
    "lossless kind",
    "sample rate",
    "bit rate",
    "source order",
    "persistent ID",
]

/// Reject malformed or non-canonical state before a plan reaches apply.
/// Reference: audit.py:207-350 (`validate_plan_integrity`).
public func validatePlanIntegrity(_ plan: ConsolidationPlan) throws {
    if plan.sourceTrackCount < 0 {
        throw PlanIntegrityError("source_track_count must not be negative")
    }
    if plan.sourceTrackCount != plan.sourceTracks.count {
        throw PlanIntegrityError(
            "source_track_count does not match the persisted source snapshot"
        )
    }

    for (position, track) in plan.sourceTracks.enumerated() {
        if track.sourceIndex != position {
            throw PlanIntegrityError(
                "persisted source track order is malformed: "
                    + "position \(position) contains source index \(track.sourceIndex)"
            )
        }
    }
    if sourceFingerprint(plan.sourceTracks) != plan.sourceFingerprint {
        throw PlanIntegrityError(
            "source fingerprint does not match the persisted source snapshot"
        )
    }

    let winners = plan.winnerSourceIndexes
    let winnerSet = Set(winners)
    if plan.sourceTrackCount != 0 && winners.isEmpty {
        throw PlanIntegrityError("winner partition is empty for a non-empty source")
    }
    if winnerSet.count != winners.count {
        throw PlanIntegrityError("winner_source_indexes contains a duplicate winner")
    }
    for sourceIndex in winners {
        if !(0..<plan.sourceTrackCount).contains(sourceIndex) {
            throw PlanIntegrityError(
                "winner source index \(sourceIndex) is out of range"
            )
        }
    }

    let nonEligible = plan.nonEligibleSourceIndexes
    let nonEligibleSet = Set(nonEligible)
    if nonEligibleSet.count != nonEligible.count {
        throw PlanIntegrityError("non-eligible source indexes contain a duplicate")
    }
    for sourceIndex in nonEligible {
        if !(0..<plan.sourceTrackCount).contains(sourceIndex) {
            throw PlanIntegrityError(
                "non-eligible source index \(sourceIndex) is out of range"
            )
        }
        if !winnerSet.contains(sourceIndex) {
            throw PlanIntegrityError(
                "non-eligible source index \(sourceIndex) is not retained"
            )
        }
    }

    var omittedSet: Set<Int> = []
    var decisionWinnerSet: Set<Int> = []
    var previousFirstSourceIndex = -1
    for (decisionPosition, decision) in plan.decisions.enumerated() {
        if decision.firstSourceIndex <= previousFirstSourceIndex {
            throw PlanIntegrityError(
                "duplicate decisions are not in strictly increasing source order"
            )
        }
        previousFirstSourceIndex = decision.firstSourceIndex

        let winnerIndex = decision.winner.sourceIndex
        if !(0..<plan.sourceTrackCount).contains(winnerIndex) {
            throw PlanIntegrityError(
                "decision \(decisionPosition) winner source index is out of range"
            )
        }
        if !scalarEqual(decision.winner, plan.sourceTracks[winnerIndex]) {
            throw PlanIntegrityError(
                "decision \(decisionPosition) winner does not match source snapshot"
            )
        }
        if !winnerSet.contains(winnerIndex) {
            throw PlanIntegrityError(
                "decision \(decisionPosition) winner is not retained"
            )
        }
        if decisionWinnerSet.contains(winnerIndex) {
            throw PlanIntegrityError("a winner is repeated across duplicate decisions")
        }
        decisionWinnerSet.insert(winnerIndex)

        if decision.omitted.isEmpty {
            throw PlanIntegrityError(
                "decision \(decisionPosition) must contain an omitted track"
            )
        }
        let omittedIndexes = decision.omitted.map(\.sourceIndex)
        if Set(omittedIndexes).count != omittedIndexes.count {
            throw PlanIntegrityError(
                "decision \(decisionPosition) repeats an omitted source index"
            )
        }
        for omitted in decision.omitted {
            let sourceIndex = omitted.sourceIndex
            if !(0..<plan.sourceTrackCount).contains(sourceIndex) {
                throw PlanIntegrityError(
                    "decision \(decisionPosition) omitted source index is out of range"
                )
            }
            if !scalarEqual(omitted, plan.sourceTracks[sourceIndex]) {
                throw PlanIntegrityError(
                    "decision \(decisionPosition) omitted track does not match "
                        + "source snapshot"
                )
            }
            if winnerSet.contains(sourceIndex) {
                throw PlanIntegrityError(
                    "winner/omitted partition overlaps at source index "
                        + "\(sourceIndex)"
                )
            }
            if omittedSet.contains(sourceIndex) {
                throw PlanIntegrityError(
                    "source index \(sourceIndex) is omitted by multiple decisions"
                )
            }
            omittedSet.insert(sourceIndex)
        }

        let reasonIndexes = decision.reasonByOmittedIndex.map(\.sourceIndex)
        if reasonIndexes != omittedIndexes {
            throw PlanIntegrityError(
                "decision \(decisionPosition) reason mapping must exactly match "
                    + "omitted source indexes"
            )
        }
        for reasonEntry in decision.reasonByOmittedIndex {
            if !knownDecisiveReasons.contains(reasonEntry.reason) {
                // Python renders `{reason!r}` with repr quotes.
                throw PlanIntegrityError(
                    "decision \(decisionPosition) has unknown reason '\(reasonEntry.reason)'"
                )
            }
        }

        let expectedFirst = ([winnerIndex] + omittedIndexes).min()!
        if decision.firstSourceIndex != expectedFirst {
            throw PlanIntegrityError(
                "decision \(decisionPosition) first source index is inconsistent"
            )
        }
    }

    let allSourceIndexes = Set(0..<plan.sourceTrackCount)
    if !winnerSet.isDisjoint(with: omittedSet) {
        throw PlanIntegrityError("winner and omitted source indexes overlap")
    }
    if winnerSet.union(omittedSet) != allSourceIndexes {
        throw PlanIntegrityError(
            "winner/omitted indexes do not form a complete source partition"
        )
    }

    let persistedSource = PlaylistSnapshot(
        name: plan.sourcePlaylistName,
        persistentId: plan.sourcePlaylistPersistentId,
        tracks: plan.sourceTracks
    )
    let canonical = try buildPlan(persistedSource)
    if !scalarEqual(canonical, plan) {
        throw PlanIntegrityError(
            "consolidation plan is not the canonical result for the persisted "
                + "source snapshot; create a fresh audit"
        )
    }
}

/// Reject malformed or non-canonical merge state before apply.
/// Reference: audit.py:471-488 (`validate_merge_plan_integrity`), extended
/// (2026-08-06 free-form design) to branch on the plan variant: a same-name
/// plan keeps the reference's "every copy shares this name" check; a
/// free-form plan instead checks its pinned persistent IDs and source names
/// against the copies, since free-form copies are not required to share a
/// name. Both variants share the same trailing fingerprint check and
/// canonical-recompute-and-diff gate, extended to call the matching builder.
public func validateMergePlanIntegrity(_ plan: MergePlan) throws {
    if plan.copies.isEmpty {
        throw PlanIntegrityError("merge plan must contain at least one source copy")
    }
    // Python set-of-str distinctness is code-point based; compare scalars.
    let persistentIds = plan.copies.map { Array($0.persistentId.unicodeScalars) }
    if Set(persistentIds).count != persistentIds.count {
        throw PlanIntegrityError("merge plan copies must have distinct persistent IDs")
    }

    if plan.isFreeForm {
        // Codable's init(from:) already rejects a partial free-form field
        // set on load; a plan built in-memory bypasses that decode path, so
        // re-check the all-or-none invariant here too (fail closed either
        // way this struct reaches the gate).
        guard let sourcePersistentIDs = plan.sourcePersistentIDs,
            let sourceNames = plan.sourceNames,
            plan.targetDescription != nil
        else {
            throw PlanIntegrityError(
                "free-form merge plan must set source_persistent_ids, target_description, "
                    + "and source_names together"
            )
        }
        if sourcePersistentIDs.count != plan.copies.count
            || !zip(sourcePersistentIDs, plan.copies).allSatisfy({ scalarEqual($0, $1.persistentId) })
        {
            throw PlanIntegrityError(
                "free-form merge plan source persistent IDs do not match the copies"
            )
        }
        if sourceNames.count != plan.copies.count
            || !zip(sourceNames, plan.copies).allSatisfy({ scalarEqual($0, $1.name) })
        {
            throw PlanIntegrityError(
                "free-form merge plan source names do not match the copies"
            )
        }
    } else {
        if plan.targetDescription != nil || plan.sourceNames != nil {
            throw PlanIntegrityError(
                "same-name merge plan must not set free-form fields"
            )
        }
        for copy in plan.copies {
            if !scalarEqual(copy.name, plan.mergedPlaylistSourceName) {
                throw PlanIntegrityError(
                    "merge plan copy name does not match the merged source name"
                )
            }
        }
    }

    // 2026-08-06 review finding I1: a free-form plan's fingerprint covers
    // targetDescription/sourceNames too (freeFormMergeFingerprint), so a
    // hand-edited description or source-name list — recomputed from the
    // SAME persisted fields checked above — no longer agrees with the
    // persisted fingerprint and fails closed here, even though the
    // canonical-recompute-and-diff below cannot see that tamper on its own
    // (it necessarily echoes the persisted description back as its own
    // input). Same-name plans are UNCHANGED: `mergeFingerprint(_:)` alone,
    // exactly as before.
    let expectedFingerprint = plan.isFreeForm
        ? freeFormMergeFingerprint(
            copies: plan.copies,
            targetDescription: plan.targetDescription!,
            sourceNames: plan.sourceNames!
        )
        : mergeFingerprint(plan.copies)
    if expectedFingerprint != plan.mergeFingerprint {
        throw PlanIntegrityError("merge fingerprint does not match the persisted copies")
    }
    let canonical: MergePlan
    if plan.isFreeForm {
        canonical = try buildFreeFormMergePlan(
            copies: plan.copies,
            targetName: plan.mergedPlaylistSourceName,
            targetDescription: plan.targetDescription!,
            sourceNames: plan.sourceNames!
        )
    } else {
        canonical = try buildMergePlan(
            name: plan.mergedPlaylistSourceName,
            copies: plan.copies
        )
    }
    if !scalarEqual(canonical, plan) {
        throw PlanIntegrityError(
            "merge plan is not the canonical result for the persisted copies; "
                + "create a fresh audit"
        )
    }
}
