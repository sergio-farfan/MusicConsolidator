// ScalarExactnessTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Fix round 1 regressions: the fail-closed builder validators must compare at
// SCALAR level, not Swift String == (Unicode canonical equivalence). Feeding
// canonically-equivalent-but-scalar-different (NFC vs NFD) inputs must be
// REJECTED with the reference-verbatim message fragments — verified against the
// reference first (python3, 2026-07-31):
//   apply/name-drift   -> "verified source name does not match consolidation plan"
//   apply/title-drift  -> "verified source fingerprint does not match consolidation plan"
//   merge/copy-name    -> "verified copies do not match the merge plan copies"
//   merge/title-drift  -> "verified copies do not match the merge plan copies"
//
// Mutation sensitivity: with ScalarSupport's scalarEqual(String) mutated to
// plain `lhs == rhs`, the name-drift and both merge cases are silently
// ACCEPTED (fail-open) and these tests go RED; the apply title-drift case
// stays rejected even under mutation because the Swift-canonical fingerprint
// bytes differ — it pins the reference's message selection order instead.
//
// The mirror-pin suite additionally locks MusicBridge's ScalarSupport to
// ConsolidatorCore's ScalarEquality semantics over a canonical-equivalence
// corpus (both modules are @testable-imported and compared result-for-result).

import Foundation
import Testing
@testable import ConsolidatorCore
@testable import MusicBridge

// Canonically-equivalent, scalar-different fixtures (built via code points so
// no invisible characters appear in this source).
private let nfcName = "Caf" + scalarString(0xE9)                 // Café precomposed
private let nfdName = "Cafe" + scalarString(0x301)               // Cafe + combining acute
private let nfcTitle = "Caf" + scalarString(0xE9) + " Song"
private let nfdTitle = "Cafe" + scalarString(0x301) + " Song"

@Suite("Canonical-equivalence drift is rejected (scalar-exactness regressions)")
struct CanonicalEquivalenceDriftTests {

    @Test("Swift String == treats the NFC/NFD fixtures as equal (precondition)")
    func fixturesAreCanonicallyEquivalentButScalarDifferent() {
        // If either assertion fails the corpus no longer exercises the
        // scalar-vs-canonical divergence and every test below is vacuous.
        #expect(nfcName == nfdName)
        #expect(nfcTitle == nfdTitle)
        #expect(!nfcName.unicodeScalars.elementsEqual(nfdName.unicodeScalars))
        #expect(!nfcTitle.unicodeScalars.elementsEqual(nfdTitle.unicodeScalars))
    }

    @Test("apply rejects an NFD-drifted verified source name")
    func applyRejectsNFDDriftedSourceName() throws {
        let source = PlaylistSnapshot(name: nfcName, persistentId: "P", tracks: [track()])
        let plan = try buildPlan(source)
        let drifted = PlaylistSnapshot(name: nfdName, persistentId: "P", tracks: source.tracks)
        #expect {
            _ = try buildApplyScript(plan: plan, verifiedSource: drifted, targetName: "Target")
        } throws: { error in
            String(describing: error)
                .contains("verified source name does not match consolidation plan")
        }
    }

    @Test("apply rejects an NFD-drifted track title in the verified snapshot")
    func applyRejectsNFDDriftedTrackTitle() throws {
        let source = PlaylistSnapshot(
            name: "Source", persistentId: "P", tracks: [track(title: nfcTitle)]
        )
        let plan = try buildPlan(source)
        var driftedTrack = source.tracks[0]
        driftedTrack.title = nfdTitle
        let drifted = PlaylistSnapshot(name: "Source", persistentId: "P", tracks: [driftedTrack])
        #expect {
            _ = try buildApplyScript(plan: plan, verifiedSource: drifted, targetName: "Target")
        } throws: { error in
            String(describing: error)
                .contains("verified source fingerprint does not match consolidation plan")
        }
    }

    private func mergeCopies() -> [PlaylistSnapshot] {
        [
            PlaylistSnapshot(name: nfcName, persistentId: "PID-A", tracks: [track(title: nfcTitle)]),
            PlaylistSnapshot(
                name: nfcName, persistentId: "PID-B",
                tracks: [track(sourceIndex: 0, databaseId: 2, persistentId: "B0", title: "Other")]
            ),
        ]
    }

    @Test("merge rejects an NFD-drifted copy name")
    func mergeRejectsNFDDriftedCopyName() throws {
        let copies = mergeCopies()
        let plan = try buildMergePlan(name: nfcName, copies: copies)
        var driftedCopy = copies[0]
        driftedCopy.name = nfdName
        #expect {
            _ = try buildMergeApplyScript(
                plan: plan, verifiedCopies: [driftedCopy, copies[1]], targetName: "T"
            )
        } throws: { error in
            String(describing: error)
                .contains("verified copies do not match the merge plan copies")
        }
    }

    @Test("merge rejects an NFD-drifted track title inside a verified copy")
    func mergeRejectsNFDDriftedTrackTitle() throws {
        let copies = mergeCopies()
        let plan = try buildMergePlan(name: nfcName, copies: copies)
        var driftedCopy = copies[0]
        var driftedTrack = driftedCopy.tracks[0]
        driftedTrack.title = nfdTitle
        driftedCopy.tracks = [driftedTrack]
        #expect {
            _ = try buildMergeApplyScript(
                plan: plan, verifiedCopies: [driftedCopy, copies[1]], targetName: "T"
            )
        } throws: { error in
            String(describing: error)
                .contains("verified copies do not match the merge plan copies")
        }
    }
}

@Suite("ScalarSupport mirror pin (scalar-exact equality semantics)")
struct ScalarSupportMirrorPinTests {

    /// Canonically-equivalent, scalar-different pairs. Every pair compares
    /// EQUAL under Swift String == (asserted, so a scalarEqual -> == mutation
    /// flips the expected verdicts) and UNEQUAL under scalar-exact equality.
    private var equivalentPairs: [(label: String, lhs: String, rhs: String)] {
        [
            ("e-acute NFC vs NFD", scalarString(0xE9), "e" + scalarString(0x301)),
            (
                "U+0390 vs iota+diaeresis+acute",
                scalarString(0x390),
                scalarString(0x3B9) + scalarString(0x308) + scalarString(0x301)
            ),
            ("Angstrom singleton vs A-ring", scalarString(0x212B), scalarString(0xC5)),
            ("A-ring NFC vs NFD", scalarString(0xC5), "A" + scalarString(0x30A)),
            (
                "combining-mark reordering",
                "q" + scalarString(0x307) + scalarString(0x323),
                "q" + scalarString(0x323) + scalarString(0x307)
            ),
            (
                "Hangul syllable vs jamo",
                scalarString(0xAC01),
                scalarString(0x1100) + scalarString(0x1161) + scalarString(0x11A8)
            ),
        ]
    }

    @Test("equality is true only for identical scalar sequences")
    func scalarExactVerdictsOverTheCanonicalEquivalenceCorpus() {
        for pair in equivalentPairs {
            // Precondition: the pair really is canonically equivalent...
            #expect(pair.lhs == pair.rhs, "\(pair.label): should be String ==")
            // ...and scalar-different.
            #expect(
                !pair.lhs.unicodeScalars.elementsEqual(pair.rhs.unicodeScalars),
                "\(pair.label): should be scalar-different"
            )
            // The mirror must reject it in both argument orders.
            let forward = MusicBridge.scalarEqual(pair.lhs, pair.rhs)
            let backward = MusicBridge.scalarEqual(pair.rhs, pair.lhs)
            let identityLhs = MusicBridge.scalarEqual(pair.lhs, pair.lhs)
            let identityRhs = MusicBridge.scalarEqual(pair.rhs, pair.rhs)
            #expect(!forward, "\(pair.label)")
            #expect(!backward, "\(pair.label) (swapped)")
            // Identity stays true.
            #expect(identityLhs, "\(pair.label) (identity lhs)")
            #expect(identityRhs, "\(pair.label) (identity rhs)")
        }
        // Plainly different strings stay unequal.
        let different = MusicBridge.scalarEqual("a", "b")
        #expect(!different)
    }

    @Test("mirror verdicts match ConsolidatorCore's ScalarEquality exactly")
    func mirrorMatchesCoreScalarEquality() {
        var corpus: [(String, String)] = equivalentPairs.map { ($0.lhs, $0.rhs) }
        corpus.append(contentsOf: [
            ("same", "same"), ("", ""), ("a", "b"), ("x y", "xy"),
            (nfcTitle, nfdTitle), (nfcName, nfcName),
        ])
        for (lhs, rhs) in corpus {
            let mirrorVerdict = MusicBridge.scalarEqual(lhs, rhs)
            let coreVerdict = ConsolidatorCore.scalarEqual(lhs, rhs)
            #expect(
                mirrorVerdict == coreVerdict,
                "string verdicts diverged for \(lhs.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")) vs \(rhs.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "))"
            )
        }

        // Field-level composition: a track/playlist differing only by an
        // NFC/NFD title must be unequal under BOTH mirrors (while Swift's
        // synthesized == calls them equal).
        let nfc = track(title: nfcTitle)
        let nfd = track(title: nfdTitle)
        #expect(nfc == nfd, "precondition: synthesized == is canonical")
        let mirrorTrackDrift = MusicBridge.scalarEqual(nfc, nfd)
        let coreTrackDrift = ConsolidatorCore.scalarEqual(nfc, nfd)
        let mirrorTrackIdentity = MusicBridge.scalarEqual(nfc, nfc)
        let coreTrackIdentity = ConsolidatorCore.scalarEqual(nfc, nfc)
        #expect(!mirrorTrackDrift)
        #expect(!coreTrackDrift)
        #expect(mirrorTrackIdentity && coreTrackIdentity)

        let playlistNFC = PlaylistSnapshot(name: nfcName, persistentId: "P", tracks: [nfc])
        let playlistNFD = PlaylistSnapshot(name: nfdName, persistentId: "P", tracks: [nfc])
        #expect(playlistNFC == playlistNFD, "precondition: synthesized == is canonical")
        let mirrorPlaylistDrift = MusicBridge.scalarEqual(playlistNFC, playlistNFD)
        let corePlaylistDrift = ConsolidatorCore.scalarEqual(playlistNFC, playlistNFD)
        let mirrorPlaylistListDrift = MusicBridge.scalarEqual([playlistNFC], [playlistNFD])
        #expect(!mirrorPlaylistDrift)
        #expect(!corePlaylistDrift)
        #expect(!mirrorPlaylistListDrift)
    }
}
