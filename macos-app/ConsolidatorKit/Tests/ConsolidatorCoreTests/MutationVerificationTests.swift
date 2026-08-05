// MutationVerificationTests.swift
// Wave B Task 2 — the inverted, bijective, persistent-ID-keyed listing diff
// (spec B1, test matrix B8). The apply verifiers prove "sources unchanged";
// this verifier proves "exactly this persistent ID changed in exactly the
// approved way, and nothing else changed", both directions, refusing on
// duplicate PIDs and reporting smart/special count drift informationally.

import Foundation
import Testing
@testable import ConsolidatorCore

private func listing(
    id: Double,
    name: String,
    pid: String,
    count: Int = 10,
    smart: Bool = false,
    specialKind: String = "none"
) -> PlaylistListing {
    PlaylistListing(
        playlistId: id,
        name: name,
        persistentId: pid,
        trackCount: count,
        isSmart: smart,
        specialKind: specialKind
    )
}

private let doomed = listing(id: 1, name: "Trance 2022", pid: "PID-DOOMED", count: 2)
private let keepA = listing(id: 2, name: "Positive", pid: "PID-A", count: 9)
private let keepB = listing(id: 3, name: "Kdrama", pid: "PID-B", count: 31)

@Suite("Bijective listing diff (spec B1/B8)")
struct MutationVerificationTests {

    @Test("an exact delete match verifies clean")
    func exactDeleteMatch() {
        let result = listingMutationDiff(
            before: [doomed, keepA, keepB],
            after: [keepA, keepB],
            expectation: .deleted(persistentID: "PID-DOOMED")
        )
        #expect(result == ListingDiffResult(mismatches: [], informational: []))
    }

    @Test("a deleted PID still present is a mismatch")
    func deletedPidStillPresent() {
        let result = listingMutationDiff(
            before: [doomed, keepA],
            after: [doomed, keepA],
            expectation: .deleted(persistentID: "PID-DOOMED")
        )
        #expect(result.mismatches == [
            "expected deleted playlist PID-DOOMED is still present (name: Trance 2022)"
        ])
        #expect(result.informational.isEmpty)
    }

    @Test("an unrelated playlist missing from the fresh listing is a mismatch")
    func unrelatedPlaylistMissing() {
        let result = listingMutationDiff(
            before: [doomed, keepA, keepB],
            after: [keepA],
            expectation: .deleted(persistentID: "PID-DOOMED")
        )
        #expect(result.mismatches == [
            "playlist PID-B (Kdrama) missing from post-mutation listing"
        ])
    }

    @Test("a playlist added during the mutation window is a mismatch")
    func playlistAddedDuringWindow() {
        let added = listing(id: 9, name: "Brand New", pid: "PID-NEW", count: 0)
        let result = listingMutationDiff(
            before: [doomed, keepA],
            after: [keepA, added],
            expectation: .deleted(persistentID: "PID-DOOMED")
        )
        #expect(result.mismatches == [
            "playlist PID-NEW (Brand New) added during mutation window"
        ])
    }

    @Test("a compensating rename+create pair cannot fool the PID bijection")
    func compensatingRenamePlusCreatePair() {
        // keepA ("Positive", PID-A) was renamed to "Beta" AND a new playlist
        // named "Positive" appeared: the post-mutation NAME multiset is
        // unchanged, so a name-keyed verifier would pass. The PID-keyed
        // bijection reports both drifts.
        let renamedA = listing(id: 2, name: "Beta", pid: "PID-A", count: 9)
        let impostor = listing(id: 9, name: "Positive", pid: "PID-X", count: 9)
        let result = listingMutationDiff(
            before: [doomed, keepA],
            after: [renamedA, impostor],
            expectation: .deleted(persistentID: "PID-DOOMED")
        )
        #expect(result.mismatches.count == 2)
        #expect(result.mismatches.contains(
            "playlist PID-A name changed: before Positive, after Beta"
        ))
        #expect(result.mismatches.contains(
            "playlist PID-X (Positive) added during mutation window"
        ))
    }

    @Test("track-count drift on a plain user playlist is a mismatch")
    func plainUserCountDrift() {
        let drifted = listing(id: 2, name: "Positive", pid: "PID-A", count: 10)
        let result = listingMutationDiff(
            before: [doomed, keepA],
            after: [drifted],
            expectation: .deleted(persistentID: "PID-DOOMED")
        )
        #expect(result.mismatches == [
            "playlist PID-A (Positive) track count changed: before 9, after 10"
        ])
        #expect(result.informational.isEmpty)
    }

    @Test("name drift is scalar-exact: trailing space")
    func nameDriftTrailingSpace() {
        let drifted = listing(id: 2, name: "Positive ", pid: "PID-A", count: 9)
        let result = listingMutationDiff(
            before: [doomed, keepA],
            after: [drifted],
            expectation: .deleted(persistentID: "PID-DOOMED")
        )
        #expect(result.mismatches == [
            "playlist PID-A name changed: before Positive, after Positive "
        ])
    }

    @Test("name drift is scalar-exact: NFC vs NFD (String == would accept it)")
    func nameDriftNFCNFD() {
        let nfcBefore = listing(id: 2, name: "Caf\u{E9}", pid: "PID-A", count: 9)
        let nfdAfter = listing(id: 2, name: "Cafe\u{301}", pid: "PID-A", count: 9)
        // The trap this test pins: Swift String == calls these names equal.
        #expect(nfcBefore.name == nfdAfter.name)
        let result = listingMutationDiff(
            before: [doomed, nfcBefore],
            after: [nfdAfter],
            expectation: .deleted(persistentID: "PID-DOOMED")
        )
        #expect(result.mismatches.count == 1)
        #expect(result.mismatches[0].hasPrefix("playlist PID-A name changed:"))
    }

    @Test("duplicate persistent IDs in either listing refuse the diff outright")
    func duplicatePidsRefused() {
        let twinA = listing(id: 2, name: "Positive", pid: "PID-A", count: 9)
        let twinA2 = listing(id: 3, name: "Positive copy", pid: "PID-A", count: 4)

        let dupBefore = listingMutationDiff(
            before: [doomed, twinA, twinA2],
            after: [twinA],
            expectation: .deleted(persistentID: "PID-DOOMED")
        )
        #expect(dupBefore.mismatches == [
            "duplicate persistent ID PID-A in pre-mutation listing"
        ])
        #expect(dupBefore.informational.isEmpty)

        let dupAfter = listingMutationDiff(
            before: [doomed, twinA],
            after: [twinA, twinA2],
            expectation: .deleted(persistentID: "PID-DOOMED")
        )
        #expect(dupAfter.mismatches == [
            "duplicate persistent ID PID-A in post-mutation listing"
        ])
    }

    @Test("duplicates in BOTH listings report before then after and short-circuit")
    func duplicatePidsBothSides() {
        // A distinct duplicate on each side simultaneously: the diff must
        // refuse with BOTH duplicate lines in deterministic order (pre before
        // post) and never fall through to the pinned/forward/reverse passes
        // (a bijection over an ambiguous index would be meaningless).
        let beforeDupA = listing(id: 2, name: "Positive", pid: "PID-A", count: 9)
        let beforeDupA2 = listing(id: 3, name: "Positive copy", pid: "PID-A", count: 4)
        let afterDupB = listing(id: 4, name: "Kdrama", pid: "PID-B", count: 31)
        let afterDupB2 = listing(id: 5, name: "Kdrama copy", pid: "PID-B", count: 7)
        let result = listingMutationDiff(
            before: [doomed, beforeDupA, beforeDupA2],
            after: [afterDupB, afterDupB2],
            expectation: .deleted(persistentID: "PID-DOOMED")
        )
        #expect(result.mismatches == [
            "duplicate persistent ID PID-A in pre-mutation listing",
            "duplicate persistent ID PID-B in post-mutation listing",
        ])
        // Short-circuit proof: no pinned/forward/reverse mismatch leaked in,
        // and nothing was reported informationally.
        #expect(result.mismatches.count == 2)
        #expect(result.informational.isEmpty)
    }

    @Test("smart/special count drift is informational, never a mismatch")
    func smartSpecialCountDriftInformational() {
        let smartBefore = listing(id: 4, name: "Top 25", pid: "PID-SMART", count: 25, smart: true)
        let smartAfter = listing(id: 4, name: "Top 25", pid: "PID-SMART", count: 24, smart: true)
        let folderBefore = listing(id: 5, name: "Mixes", pid: "PID-FOLDER", count: 3, specialKind: "folder")
        let folderAfter = listing(id: 5, name: "Mixes", pid: "PID-FOLDER", count: 5, specialKind: "folder")
        let result = listingMutationDiff(
            before: [doomed, smartBefore, folderBefore],
            after: [smartAfter, folderAfter],
            expectation: .deleted(persistentID: "PID-DOOMED")
        )
        #expect(result.mismatches.isEmpty)
        #expect(result.informational == [
            "smart/special playlist PID-FOLDER (Mixes) track count drifted: 3 -> 5",
            "smart/special playlist PID-SMART (Top 25) track count drifted: 25 -> 24",
        ])
    }

    @Test("a rename verifies when exactly the pinned PID bears the new name")
    func renameSuccess() {
        let before = listing(id: 2, name: "Positive ", pid: "PID-A", count: 9)
        let after = listing(id: 2, name: "Positive", pid: "PID-A", count: 9)
        let result = listingMutationDiff(
            before: [before, keepB],
            after: [after, keepB],
            expectation: .renamed(persistentID: "PID-A", newName: "Positive")
        )
        #expect(result == ListingDiffResult(mismatches: [], informational: []))
    }

    @Test("a rename to the wrong new name is a mismatch")
    func renameWrongNewName() {
        let before = listing(id: 2, name: "Positive ", pid: "PID-A", count: 9)
        let wrong = listing(id: 2, name: "Positive  ", pid: "PID-A", count: 9)
        let result = listingMutationDiff(
            before: [before, keepB],
            after: [wrong, keepB],
            expectation: .renamed(persistentID: "PID-A", newName: "Positive")
        )
        #expect(result.mismatches == [
            "renamed playlist PID-A bears name Positive  , expected Positive"
        ])
    }

    @Test("a rename that also changed the track count is a mismatch")
    func renameCountChanged() {
        let before = listing(id: 2, name: "Old", pid: "PID-A", count: 9)
        let after = listing(id: 2, name: "New", pid: "PID-A", count: 8)
        let result = listingMutationDiff(
            before: [before],
            after: [after],
            expectation: .renamed(persistentID: "PID-A", newName: "New")
        )
        #expect(result.mismatches == [
            "renamed playlist PID-A track count changed: before 9, after 8"
        ])
    }

    @Test("a renamed PID missing from the fresh listing is a mismatch")
    func renamedPidMissing() {
        let before = listing(id: 2, name: "Old", pid: "PID-A", count: 9)
        let result = listingMutationDiff(
            before: [before, keepB],
            after: [keepB],
            expectation: .renamed(persistentID: "PID-A", newName: "New")
        )
        #expect(result.mismatches == [
            "expected renamed playlist PID-A missing from post-mutation listing"
        ])
    }

    @Test("a pinned PID absent from the baseline refuses fail-closed")
    func pinnedPidAbsentFromBaseline() {
        let result = listingMutationDiff(
            before: [keepA],
            after: [keepA],
            expectation: .deleted(persistentID: "PID-GHOST")
        )
        #expect(result.mismatches == [
            "pinned persistent ID PID-GHOST is not in the pre-mutation baseline"
        ])
        #expect(result.informational.isEmpty)
    }
}
