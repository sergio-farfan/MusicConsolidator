// FreeFormMergeEngineTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// New coverage for the free-form merge engine (2026-08-06 free-form design,
// Task 1 — Swift-native, no Python counterpart, no CLI surface): the
// `MergePlan` free-form variant (`buildFreeFormMergePlan`), its Codable
// all-or-none discipline, and `validateMergePlanIntegrity`'s free-form
// branch. The writer/revalidation half of Task 1 (MusicBridge) is covered
// separately in Tests/MusicBridgeTests/FreeFormMergeEngineTests.swift.

import Foundation
import Testing
@testable import ConsolidatorCore

private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Two distinctly-named playlists sharing one duplicate track (by title) plus
/// one unique track each — the free-form counterpart of the "Trance 2022"
/// same-name fixture used throughout MusicScriptBuilderTests/PlanIntegrityTests,
/// but with names that deliberately do NOT match, since free-form copies are
/// not required to share a name.
private func freeFormCopies() -> [PlaylistSnapshot] {
    [
        PlaylistSnapshot(
            name: "DJ Set A",
            persistentId: "PID-A",
            tracks: [
                track(
                    sourceIndex: 0, databaseId: 1, persistentId: "LOSSY",
                    title: "One", durationMs: 180001, sampleRateHz: 44100
                ),
                track(
                    sourceIndex: 1, databaseId: 2, persistentId: "UNIQUE-A",
                    title: "Two", durationMs: 200002
                ),
            ]
        ),
        PlaylistSnapshot(
            name: "DJ Set B",
            persistentId: "PID-B",
            tracks: [
                track(
                    sourceIndex: 0, databaseId: 3, persistentId: "LOSSLESS",
                    title: "One", durationMs: 180001, kind: "AIFF audio file",
                    sampleRateHz: 96000
                ),
            ]
        ),
    ]
}

private let freeFormSourceNames = ["DJ Set A", "DJ Set B"]
private let freeFormTargetName = "DJ Set A — Merged"
private let freeFormDescription = "Merged on 2026-08-06 12:00 from: DJ Set A, DJ Set B"

@Suite("buildFreeFormMergePlan (Task 1, Engine)")
struct BuildFreeFormMergePlanTests {

    @Test("pins the free-form fields and records the computed target name")
    func pinsFreeFormFields() throws {
        let copies = freeFormCopies()
        let plan = try buildFreeFormMergePlan(
            copies: copies,
            targetName: freeFormTargetName,
            targetDescription: freeFormDescription,
            sourceNames: freeFormSourceNames
        )

        #expect(plan.isFreeForm)
        #expect(plan.mergedPlaylistSourceName == freeFormTargetName)
        #expect(plan.sourcePersistentIDs == ["PID-A", "PID-B"])
        #expect(plan.sourceNames == freeFormSourceNames)
        #expect(plan.targetDescription == freeFormDescription)
        #expect(plan.copies.map(\.persistentId) == ["PID-A", "PID-B"])
        // 2026-08-06 review finding I1: the free-form fingerprint covers
        // targetDescription/sourceNames too, so it is NOT the plain
        // copies-only mergeFingerprint(_:) same-name plans use.
        #expect(plan.mergeFingerprint == freeFormMergeFingerprint(
            copies: copies, targetDescription: freeFormDescription, sourceNames: freeFormSourceNames
        ))
        #expect(plan.mergeFingerprint != mergeFingerprint(copies))
    }

    @Test("dedup is identical to a same-name merge of the same snapshots")
    func dedupMatchesSameNameMerge() throws {
        let copies = freeFormCopies()
        let freeFormPlan = try buildFreeFormMergePlan(
            copies: copies,
            targetName: freeFormTargetName,
            targetDescription: freeFormDescription,
            sourceNames: freeFormSourceNames
        )

        // Same tracks, same order, but renamed to share ONE name — the
        // dedup engine (buildPlan over combineSourceTracks) depends only on
        // tracks and order, never on playlist name, so the winner/decision
        // shape must be identical either way.
        var renamedCopies = copies
        renamedCopies[0].name = "Combined"
        renamedCopies[1].name = "Combined"
        let sameNamePlan = try buildMergePlan(name: "Combined", copies: renamedCopies)

        #expect(freeFormPlan.winnerSourceIndexes == sameNamePlan.winnerSourceIndexes)
        #expect(scalarEqual(freeFormPlan.decisions, sameNamePlan.decisions))
        #expect(freeFormPlan.nonEligibleSourceIndexes == sameNamePlan.nonEligibleSourceIndexes)
        #expect(freeFormPlan.combinedTracks.count == sameNamePlan.combinedTracks.count)
    }

    @Test("rejects source names that do not match the copies, in order")
    func rejectsMismatchedSourceNames() throws {
        let copies = freeFormCopies()

        #expect(throws: ResolverError.self) {
            _ = try buildFreeFormMergePlan(
                copies: copies,
                targetName: freeFormTargetName,
                targetDescription: freeFormDescription,
                sourceNames: ["DJ Set B", "DJ Set A"] // swapped order
            )
        }
        #expect(throws: ResolverError.self) {
            _ = try buildFreeFormMergePlan(
                copies: copies,
                targetName: freeFormTargetName,
                targetDescription: freeFormDescription,
                sourceNames: ["DJ Set A"] // wrong count
            )
        }
    }

    @Test("builder is a pure function: repeated builds are identical")
    func builderIsDeterministic() throws {
        let copies = freeFormCopies()
        let first = try buildFreeFormMergePlan(
            copies: copies, targetName: freeFormTargetName,
            targetDescription: freeFormDescription, sourceNames: freeFormSourceNames
        )
        let second = try buildFreeFormMergePlan(
            copies: copies, targetName: freeFormTargetName,
            targetDescription: freeFormDescription, sourceNames: freeFormSourceNames
        )
        #expect(scalarEqual(first, second))
    }
}

@Suite("validateMergePlanIntegrity — free-form variant (Task 1, Engine)")
struct FreeFormMergePlanIntegrityTests {

    private func plan() throws -> MergePlan {
        try buildFreeFormMergePlan(
            copies: freeFormCopies(),
            targetName: freeFormTargetName,
            targetDescription: freeFormDescription,
            sourceNames: freeFormSourceNames
        )
    }

    private func expectRejection(
        _ plan: MergePlan,
        messageContains messagePart: String,
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) {
        do {
            try validateMergePlanIntegrity(plan)
            Issue.record("expected rejection (\(messagePart))", sourceLocation: sourceLocation)
        } catch let error as PlanIntegrityError {
            #expect(
                error.message.contains(messagePart),
                "unexpected message: \(error.message)",
                sourceLocation: sourceLocation
            )
        } catch {
            Issue.record("expected PlanIntegrityError, got \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test("a canonical free-form plan validates")
    func canonicalPlanValidates() throws {
        try validateMergePlanIntegrity(try plan())
    }

    @Test("rejects a tampered source persistent ID list")
    func rejectsTamperedPersistentIds() throws {
        let plan = try plan()
        let tampered = MergePlan(
            mergedPlaylistSourceName: plan.mergedPlaylistSourceName,
            copies: plan.copies,
            mergeFingerprint: plan.mergeFingerprint,
            winnerSourceIndexes: plan.winnerSourceIndexes,
            decisions: plan.decisions,
            nonEligibleSourceIndexes: plan.nonEligibleSourceIndexes,
            sourcePersistentIDs: ["PID-A", "PID-X"],
            targetDescription: plan.targetDescription,
            sourceNames: plan.sourceNames
        )
        expectRejection(tampered, messageContains: "source persistent IDs do not match the copies")
    }

    @Test("rejects a tampered source name list")
    func rejectsTamperedSourceNames() throws {
        let plan = try plan()
        let tampered = MergePlan(
            mergedPlaylistSourceName: plan.mergedPlaylistSourceName,
            copies: plan.copies,
            mergeFingerprint: plan.mergeFingerprint,
            winnerSourceIndexes: plan.winnerSourceIndexes,
            decisions: plan.decisions,
            nonEligibleSourceIndexes: plan.nonEligibleSourceIndexes,
            sourcePersistentIDs: plan.sourcePersistentIDs,
            targetDescription: plan.targetDescription,
            sourceNames: ["DJ Set A", "Tampered"]
        )
        expectRejection(tampered, messageContains: "source names do not match the copies")
    }

    // 2026-08-06 review finding I1 (write-path review, controller ruling):
    // the free-form fingerprint input now covers `targetDescription` and
    // `sourceNames` (see `freeFormMergeFingerprint` in Resolver.swift), so
    // editing the description WITHOUT recomputing the persisted
    // `merge_fingerprint` to match no longer validates — this in-memory
    // case constructs exactly that: everything else untouched, only
    // `targetDescription` differs from what `plan.mergeFingerprint` was
    // actually computed over.
    @Test("rejects a tampered target description (in-memory construction)")
    func rejectsTamperedDescriptionInMemory() throws {
        let plan = try plan()
        let tampered = MergePlan(
            mergedPlaylistSourceName: plan.mergedPlaylistSourceName,
            copies: plan.copies,
            mergeFingerprint: plan.mergeFingerprint,
            winnerSourceIndexes: plan.winnerSourceIndexes,
            decisions: plan.decisions,
            nonEligibleSourceIndexes: plan.nonEligibleSourceIndexes,
            sourcePersistentIDs: plan.sourcePersistentIDs,
            targetDescription: "Tampered description",
            sourceNames: plan.sourceNames
        )
        expectRejection(tampered, messageContains: "merge fingerprint does not match the persisted copies")
    }

    // The controller's exact tamper scenario: flip ONLY target_description
    // in a SERIALIZED free-form plan.json (leaving merge_fingerprint as
    // originally computed) → load refuses. Exercises the full
    // Codable-decode + validate path (loadMergePlan's decodeAndValidate
    // shape), not just an in-memory MergePlan construction.
    @Test("a hand-edited target_description in a serialized plan.json fails closed")
    func serializedDescriptionTamperFailsClosed() throws {
        let plan = try plan()
        var object = try jsonObject(plan)
        object["target_description"] = "Hand-edited description"
        // merge_fingerprint is left exactly as the untampered plan produced.
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MergePlan.self, from: data)
        // Codable's own all-or-none check does not fire (all three fields
        // are still present) — the fingerprint recheck is what must catch
        // this.
        #expect(decoded.targetDescription == "Hand-edited description")
        do {
            try validateMergePlanIntegrity(decoded)
            Issue.record("expected the hand-edited description to be refused")
        } catch let error as PlanIntegrityError {
            #expect(error.message.contains("merge fingerprint does not match the persisted copies"))
        } catch {
            Issue.record("expected PlanIntegrityError, got \(error)")
        }
    }

    @Test("rejects a same-name plan carrying free-form fields")
    func rejectsSameNamePlanWithFreeFormFields() throws {
        let sameName = try buildMergePlan(name: "Combined", copies: {
            var copies = freeFormCopies()
            copies[0].name = "Combined"
            copies[1].name = "Combined"
            return copies
        }())
        let mixed = MergePlan(
            mergedPlaylistSourceName: sameName.mergedPlaylistSourceName,
            copies: sameName.copies,
            mergeFingerprint: sameName.mergeFingerprint,
            winnerSourceIndexes: sameName.winnerSourceIndexes,
            decisions: sameName.decisions,
            nonEligibleSourceIndexes: sameName.nonEligibleSourceIndexes,
            sourcePersistentIDs: nil,
            targetDescription: "should not be here",
            sourceNames: nil
        )
        expectRejection(mixed, messageContains: "must not set free-form fields")
    }

    @Test("rejects a free-form plan missing one of the three fields (bypassing Codable)")
    func rejectsPartialFreeFormFields() throws {
        let plan = try plan()
        let partial = MergePlan(
            mergedPlaylistSourceName: plan.mergedPlaylistSourceName,
            copies: plan.copies,
            mergeFingerprint: plan.mergeFingerprint,
            winnerSourceIndexes: plan.winnerSourceIndexes,
            decisions: plan.decisions,
            nonEligibleSourceIndexes: plan.nonEligibleSourceIndexes,
            sourcePersistentIDs: plan.sourcePersistentIDs,
            targetDescription: nil,
            sourceNames: plan.sourceNames
        )
        expectRejection(partial, messageContains: "must set source_persistent_ids, target_description")
    }
}

@Suite("MergePlan Codable — free-form variant (Task 1, Engine)")
struct FreeFormMergePlanCodableTests {

    @Test("round-trips a free-form plan through JSON")
    func roundTripsThroughJSON() throws {
        let plan = try buildFreeFormMergePlan(
            copies: freeFormCopies(),
            targetName: freeFormTargetName,
            targetDescription: freeFormDescription,
            sourceNames: freeFormSourceNames
        )
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(MergePlan.self, from: data)
        #expect(scalarEqual(decoded, plan))
    }

    @Test("wire keys are snake_case; free-form fields are present only for a free-form plan")
    func wireKeysAreSnakeCaseAndOmittedForSameName() throws {
        let plan = try buildFreeFormMergePlan(
            copies: freeFormCopies(),
            targetName: freeFormTargetName,
            targetDescription: freeFormDescription,
            sourceNames: freeFormSourceNames
        )
        let object = try jsonObject(plan)
        #expect(object["source_persistent_ids"] != nil)
        #expect(object["target_description"] != nil)
        #expect(object["source_names"] != nil)

        // A same-name plan OMITS the three free-form keys entirely — the
        // rendered JSON stays byte-identical to the pre-2026-08-06 shape,
        // which the Python-reference golden-parity gates and every
        // persisted historical plan.json in reports/ already are.
        let sameName = try buildMergePlan(name: "Trance 2022", copies: [
            PlaylistSnapshot(name: "Trance 2022", persistentId: "PID-A", tracks: [track()]),
        ])
        let sameNameObject = try jsonObject(sameName)
        #expect(sameNameObject["source_persistent_ids"] == nil)
        #expect(sameNameObject["target_description"] == nil)
        #expect(sameNameObject["source_names"] == nil)
        #expect(Set(sameNameObject.keys) == [
            "merged_playlist_source_name", "copies", "merge_fingerprint",
            "winner_source_indexes", "decisions", "non_eligible_source_indexes",
        ])
    }

    @Test("a pre-2026-08-06 plan.json (no free-form keys at all) still decodes")
    func preFreeFormPlanJSONStillDecodes() throws {
        let plan = try buildMergePlan(name: "Trance 2022", copies: [
            PlaylistSnapshot(name: "Trance 2022", persistentId: "PID-A", tracks: [track()]),
        ])
        var object = try jsonObject(plan)
        // Simulate a plan.json written before the free-form fields existed:
        // the keys are not merely null, they are ABSENT.
        object.removeValue(forKey: "source_persistent_ids")
        object.removeValue(forKey: "target_description")
        object.removeValue(forKey: "source_names")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MergePlan.self, from: data)
        #expect(scalarEqual(decoded, plan))
        #expect(!decoded.isFreeForm)
    }

    @Test("rejects a plan mixing the same-name and free-form variants")
    func rejectsMixedVariantOnDecode() throws {
        let plan = try buildFreeFormMergePlan(
            copies: freeFormCopies(),
            targetName: freeFormTargetName,
            targetDescription: freeFormDescription,
            sourceNames: freeFormSourceNames
        )
        var object = try jsonObject(plan)
        object["target_description"] = NSNull() // only 2 of 3 free-form fields remain set
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(MergePlan.self, from: data)
        }
    }

    @Test("same-name plan Codable is unaffected by the new optional fields")
    func sameNamePlanRoundTrips() throws {
        let plan = try buildMergePlan(
            name: "Trance 2022",
            copies: [
                PlaylistSnapshot(name: "Trance 2022", persistentId: "PID-A", tracks: [track()]),
                PlaylistSnapshot(
                    name: "Trance 2022", persistentId: "PID-B",
                    tracks: [track(persistentId: "OTHER", title: "Two")]
                ),
            ]
        )
        #expect(!plan.isFreeForm)
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(MergePlan.self, from: data)
        #expect(scalarEqual(decoded, plan))
        try validateMergePlanIntegrity(decoded)
    }
}
