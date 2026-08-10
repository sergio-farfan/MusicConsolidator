// AlignNamesTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Wave B (B5 Align names) — the canonical-name rule (NFC-equal, no
// leading/trailing whitespace, no invisible scalars), candidate selection
// (clear winner / none / several), the N-1 rename derivation, and the
// model-level align gate whose typed token is the canonical DESTINATION
// name. Offline only: pure values plus ScriptedRunner fakes.

import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

private func alignListing(_ name: String, pid: String, id: Double) -> PlaylistListing {
    PlaylistListing(
        playlistId: id, name: name, persistentId: pid,
        trackCount: 3, isSmart: false, specialKind: "none"
    )
}

/// A cluster of single-listing variants (PID-0, PID-1, ...), like the
/// library's real trailing-space twins.
private func alignCluster(_ names: [String]) -> PlaylistNearMatchCluster {
    PlaylistNearMatchCluster(
        normalizedName: "Kdrama",
        variants: names.enumerated().map { offset, name in
            PlaylistNearMatchVariant(
                name: name,
                listings: [alignListing(name, pid: "PID-\(offset)", id: Double(10 + offset))]
            )
        }
    )
}

@Suite("Align names canonical rule and rename derivation (Wave B)")
struct AlignNamesTests {

    @Test("the canonical rule: NFC-equal, no edge whitespace, no invisibles, non-empty")
    func canonicalRule() {
        #expect(isCanonicalAlignName("Kdrama"))
        #expect(isCanonicalAlignName("Caf\u{E9} List"))          // precomposed NFC
        #expect(!isCanonicalAlignName("Kdrama "))                 // trailing space
        #expect(!isCanonicalAlignName(" Kdrama"))                 // leading space
        #expect(!isCanonicalAlignName("Kdrama\u{A0}"))            // trailing NBSP
        #expect(!isCanonicalAlignName("Kdra\u{200B}ma"))          // interior ZWSP
        #expect(!isCanonicalAlignName("Cafe\u{301} List"))        // NFD, not its own NFC form
        #expect(!isCanonicalAlignName(""))
    }

    @Test("a clear winner: exactly one variant qualifies")
    func clearWinner() {
        let cluster = alignCluster(["Kdrama", "Kdrama "])
        #expect(canonicalAlignCandidates(in: cluster) == ["Kdrama"])
    }

    @Test("no variant qualifies: the candidate list is empty and Sergio must pick")
    func noneQualify() {
        let cluster = alignCluster(["Kdrama ", "Kdrama\u{A0}"])
        #expect(canonicalAlignCandidates(in: cluster).isEmpty)
    }

    @Test("several variants qualify: all are offered and Sergio must pick")
    func severalQualify() {
        let cluster = alignCluster(["Trance 2022", "Trance  2022"])
        #expect(canonicalAlignCandidates(in: cluster) == ["Trance 2022", "Trance  2022"])
    }

    @Test("a 3-variant cluster yields exactly 2 renames, each pinned by persistent ID")
    func threeVariantsTwoRenames() {
        let cluster = alignCluster(["Kdrama", "Kdrama ", "Kdrama\u{A0}"])
        let renames = alignRenames(in: cluster, canonicalName: "Kdrama")
        #expect(renames.count == 2)
        #expect(renames.map(\.persistentId) == ["PID-1", "PID-2"])
        #expect(renames.map(\.currentName) == ["Kdrama ", "Kdrama\u{A0}"])
        #expect(renames.allSatisfy { $0.canonicalName == "Kdrama" })
    }

    @Test("a deviant variant with two same-name copies yields one rename per copy")
    func multiListingVariant() {
        let cluster = PlaylistNearMatchCluster(
            normalizedName: "Kdrama",
            variants: [
                PlaylistNearMatchVariant(
                    name: "Kdrama",
                    listings: [alignListing("Kdrama", pid: "PID-0", id: 10)]
                ),
                PlaylistNearMatchVariant(
                    name: "Kdrama ",
                    listings: [
                        alignListing("Kdrama ", pid: "PID-1", id: 20),
                        alignListing("Kdrama ", pid: "PID-2", id: 30),
                    ]
                ),
            ]
        )
        let renames = alignRenames(in: cluster, canonicalName: "Kdrama")
        #expect(renames.map(\.persistentId) == ["PID-1", "PID-2"])
    }
}

// MARK: - the align gate: typed token is the canonical DESTINATION name

@MainActor
@Suite("Align rename gate (Wave B)")
struct AlignGateTests {

    @Test("an align rename arms with confirmationName = destination; the deviant name never satisfies")
    func alignGateTokenIsDestination() async throws {
        // gateListingWire has "Kdrama " (trailing space) at TRAIL00000000001.
        let runner = ScriptedRunner(outputs: [gateListingWire(), kdramaSnapshotWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(
            kind: .rename,
            persistentID: "TRAIL00000000001",
            newName: "Kdrama",
            confirmWithDestinationName: true
        )
        await harness.awaitMutation()

        let armed = try #require(harness.model.armedMutation)
        #expect(armed.plan.playlistName == "Kdrama ")
        #expect(armed.plan.newName == "Kdrama")
        #expect(armed.confirmationName == "Kdrama")

        // The deviant CURRENT name does not satisfy the gate...
        harness.model.typedMutationName = "Kdrama "
        #expect(!harness.model.mutationGateSatisfied)
        // ...the canonical destination name does (scalar-exact, unnormalized).
        harness.model.typedMutationName = "Kdrama"
        #expect(harness.model.mutationNameDivergence == nil)
        #expect(harness.model.mutationGateSatisfied)
    }

    @Test("a plain rename still confirms with the CURRENT name (default seam unchanged)")
    func plainRenameStillConfirmsCurrentName() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire(), kdramaSnapshotWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(
            kind: .rename, persistentID: "TRAIL00000000001", newName: "Kdrama"
        )
        await harness.awaitMutation()
        let armed = try #require(harness.model.armedMutation)
        #expect(armed.confirmationName == "Kdrama ")
        harness.model.typedMutationName = "Kdrama "
        #expect(harness.model.mutationGateSatisfied)
    }
}
