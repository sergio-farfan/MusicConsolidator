// CleanupCandidacyTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// B3 candidacy rules 1-4 over injected live fixtures: one fixture per rule
// outcome, plus the partially-cleaned-still-candidate and
// zero-copies-left-drops-out boundaries. No live Music, ever.

import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

/// Build a scanner whose listing is derived from `live` (exact-name keyed
/// snapshots, one listing row per snapshot) plus `extraListings`. scan() is
/// listing-only now, so this is the only live surface a scan-level test can
/// influence; per-track content in `live` (e.g. metadata/track drift) is
/// invisible to the listing and only matters to armVerification-direct tests.
@MainActor
private func candidacyScanner(
    fixture: CleanupFixture,
    live: [String: [PlaylistSnapshot]],
    extraListings: [PlaylistListing] = []
) -> CleanupScanner {
    var listings: [PlaylistListing] = extraListings
    var nextId = 1.0
    for name in live.keys.sorted() {
        for snapshot in live[name]! {
            listings.append(cleanupLiveListing(snapshot, id: nextId))
            nextId += 1
        }
    }
    return fixture.scanner(listPlaylists: { listings })
}

/// Identity-preserving metadata drift: same PIDs/name/count/order, different
/// databaseId and bit rate (must still count as a matching live copy).
private func metadataDrifted(_ snapshot: PlaylistSnapshot) -> PlaylistSnapshot {
    PlaylistSnapshot(
        name: snapshot.name,
        persistentId: snapshot.persistentId,
        tracks: snapshot.tracks.map { track in
            var drifted = track
            drifted.databaseId += 1000
            drifted.bitRateKbps = 320
            return drifted
        }
    )
}

/// Fix round 1 (CRITICAL fail-open closed): legitimate recorded-delete
/// accounting is now backed by a REAL, consumed *.delete.plan.json artifact
/// pinned to `persistentID` — never a hand-picked sha. Writes the artifact
/// via the real `writeMutationAudit`, consumes it via the real
/// `markMutationPlanConsumed` (which recomputes and writes the sha itself),
/// then writes the `.mutationresult.md` "deleted-ok" line citing that SAME
/// recomputed sha. Returns the sha for tests that need to reference it.
@MainActor
@discardableResult
private func writeGenuineDeleteAccounting(
    _ fixture: CleanupFixture,
    playlistName: String,
    persistentID: String,
    trackPersistentIDs: [String],
    planDate: Date,
    resultFileName: String
) throws -> String {
    let plan = MutationPlan(
        kind: .delete,
        playlistName: playlistName,
        playlistPersistentID: persistentID,
        trackCount: trackPersistentIDs.count,
        orderedTrackPersistentIDs: trackPersistentIDs,
        newName: nil,
        listingFingerprint: String(repeating: "ab", count: 32),
        evidence: nil,
        createdAtISO8601: "2026-08-03T12:00:00Z",
        sessionID: "11111111-2222-3333-4444-555555555555"
    )
    let paths = try writeMutationAudit(
        outputDir: fixture.reportsDir,
        plan: plan,
        summaryText: "# Delete \(playlistName)\n",
        now: { planDate },
        timeZone: TimeZone(identifier: "UTC")!
    )
    try markMutationPlanConsumed(planURL: paths.planURL)
    let sha = plan.sha256Hex()
    try fixture.writeText(
        """
        # Mutation result

        - Outcome: deleted
        deleted-ok \(persistentID) \(sha)
        """,
        fileName: resultFileName
    )
    return sha
}

@Suite("Cleanup candidacy (B3 rules 1-4)")
@MainActor
struct CleanupCandidacyTests {
    private let planDate = Date(timeIntervalSince1970: 1_754_000_000)

    @Test("an intact group is a candidate; copy matching is identity-only")
    func intactGroupIsCandidate() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let copies = cleanupFixtureCopies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        try fixture.writePlan(plan, at: planDate)
        let target = verifiedCleanupTarget(for: plan, name: "Trance 2022 \u{2014} Merged")
        let scanner = candidacyScanner(fixture: fixture, live: [
            "Trance 2022": copies.map(metadataDrifted),
            "Trance 2022 \u{2014} Merged": [target],
        ])

        let candidates = try scanner.scan()

        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.disqualification == nil)
        #expect(candidate.targetPresent == true)
        #expect(candidate.groupName == "Trance 2022")
        #expect(candidate.copies.map(\.disposition) == [.live, .live])
        #expect(candidate.copies.map(\.persistentID)
            == ["CPYAAAA000000001", "CPYBBBB000000002"])
    }

    @Test("rule 1 at scan time: a target present exactly once by name is NOT disqualified, even mid database-ID churn (a listing has no database IDs)")
    func rule1TargetPresentButUnverifiedAtScanTime() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let copies = cleanupFixtureCopies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        try fixture.writePlan(plan, at: planDate)
        // Database-ID churn on the target: persistent IDs still match but the
        // fresh verifyMergeOutput trust standard (ordered database IDs +
        // persistent IDs) would refuse. At scan time this is invisible: the
        // listing only has a name/persistentId/trackCount row, so the target
        // still counts as present-by-name.
        let churned = metadataDrifted(
            verifiedCleanupTarget(for: plan, name: "Trance 2022 \u{2014} Merged")
        )
        let scanner = candidacyScanner(fixture: fixture, live: [
            "Trance 2022": copies,
            "Trance 2022 \u{2014} Merged": [churned],
        ])

        let candidate = try #require(try scanner.scan().first)
        #expect(candidate.targetPresent == true)
        #expect(candidate.disqualification == nil)
    }

    @Test("rule 1 at gate-arm: armVerification catches target database-ID churn that scan-time listing presence cannot")
    func armVerificationCatchesTargetChurn() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let copies = cleanupFixtureCopies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        try fixture.writePlan(plan, at: planDate)
        let churned = metadataDrifted(
            verifiedCleanupTarget(for: plan, name: "Trance 2022 \u{2014} Merged")
        )
        let scanner = fixture.scanner()
        let group = try #require(scanner.discoverGroups().first)

        let reason = try #require(try scanner.armVerification(
            group: group,
            listing: [],
            groupLiveCopies: copies,
            targetLiveCopies: [churned]
        ))
        #expect(reason.contains("failed fresh verification"))
    }

    @Test("rule 2 at scan time: a copy's per-track drift is invisible at listing level, so the copy reads as .live")
    func rule2CopyTrackDriftIsLiveAtScanTime() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let copies = cleanupFixtureCopies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        try fixture.writePlan(plan, at: planDate)
        var driftedTrack = copies[1].tracks[0]
        driftedTrack.persistentId = "T9999999"
        let driftedCopy = PlaylistSnapshot(
            name: copies[1].name,
            persistentId: copies[1].persistentId,
            tracks: [driftedTrack]
        )
        let target = verifiedCleanupTarget(for: plan, name: "Trance 2022 \u{2014} Merged")
        let scanner = candidacyScanner(fixture: fixture, live: [
            "Trance 2022": [copies[0], driftedCopy],
            "Trance 2022 \u{2014} Merged": [target],
        ])

        let candidate = try #require(try scanner.scan().first)
        #expect(candidate.disqualification == nil)
        #expect(candidate.copies.map(\.disposition) == [.live, .live])
    }

    @Test("rule 2 at gate-arm: armVerification catches per-track persistent-ID drift that scan-time listing presence cannot")
    func armVerificationCatchesCopyTrackDrift() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let copies = cleanupFixtureCopies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        try fixture.writePlan(plan, at: planDate)
        var driftedTrack = copies[1].tracks[0]
        driftedTrack.persistentId = "T9999999"
        let driftedCopy = PlaylistSnapshot(
            name: copies[1].name,
            persistentId: copies[1].persistentId,
            tracks: [driftedTrack]
        )
        let target = verifiedCleanupTarget(for: plan, name: "Trance 2022 \u{2014} Merged")
        let scanner = fixture.scanner()
        let group = try #require(scanner.discoverGroups().first)

        let reason = try #require(try scanner.armVerification(
            group: group,
            listing: [],
            groupLiveCopies: [copies[0], driftedCopy],
            targetLiveCopies: [target]
        ))
        #expect(reason.contains("drifted"))
        #expect(reason.contains("CPYBBBB000000002"))
    }

    @Test("rule 2 at gate-arm: armVerification catches a copy that is still live but renamed away from the group name (present in the full listing, absent from the name-scoped snapshot)")
    func armVerificationCatchesRenamedLiveCopy() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let copies = cleanupFixtureCopies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        try fixture.writePlan(plan, at: planDate)
        let target = verifiedCleanupTarget(for: plan, name: "Trance 2022 \u{2014} Merged")
        let scanner = fixture.scanner()
        let group = try #require(scanner.discoverGroups().first)
        // Copy B (CPYBBBB000000002) is still live in the library, but has
        // been renamed away from the group's exact name since the plan was
        // written -- still present in the FULL listing by persistent ID, but
        // no longer returned by the name-scoped snapshot() (groupLiveCopies).
        let renamedListingEntry = PlaylistListing(
            playlistId: 42,
            name: "Trance 2022 (renamed)",
            persistentId: copies[1].persistentId,
            trackCount: copies[1].tracks.count,
            isSmart: false,
            specialKind: "none"
        )

        let reason = try #require(try scanner.armVerification(
            group: group,
            listing: [renamedListingEntry],
            groupLiveCopies: [copies[0]],
            targetLiveCopies: [target]
        ))
        #expect(reason.contains("CPYBBBB000000002"))
        #expect(reason.contains("no longer bears the group name"))
    }

    @Test("rule 2: an absent copy WITHOUT a recorded delete disqualifies")
    func rule2AbsentUnaccountedDisqualifies() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let copies = cleanupFixtureCopies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        try fixture.writePlan(plan, at: planDate)
        let target = verifiedCleanupTarget(for: plan, name: "Trance 2022 \u{2014} Merged")
        let scanner = candidacyScanner(fixture: fixture, live: [
            "Trance 2022": [copies[0]],
            "Trance 2022 \u{2014} Merged": [target],
        ])

        let candidate = try #require(try scanner.scan().first)
        let reason = try #require(candidate.disqualification)
        #expect(reason.contains("without a recorded delete"))
        #expect(reason.contains("CPYBBBB000000002"))
    }

    @Test("rule 2: a partially cleaned group with accounting stays a candidate")
    func partiallyCleanedGroupStillCandidate() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let copies = cleanupFixtureCopies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        try fixture.writePlan(plan, at: planDate)
        try writeGenuineDeleteAccounting(
            fixture,
            playlistName: "Trance 2022",
            persistentID: "CPYBBBB000000002",
            trackPersistentIDs: ["T0000003"],
            planDate: planDate.addingTimeInterval(900),
            resultFileName: "Trance-2022-20260803-121500+0000.mutationresult.md"
        )
        let target = verifiedCleanupTarget(for: plan, name: "Trance 2022 \u{2014} Merged")
        let scanner = candidacyScanner(fixture: fixture, live: [
            "Trance 2022": [copies[0]],
            "Trance 2022 \u{2014} Merged": [target],
        ])

        let candidate = try #require(try scanner.scan().first)
        #expect(candidate.disqualification == nil)
        #expect(candidate.copies.map(\.disposition) == [.live, .alreadyDeleted])
    }

    @Test("rule 3: an unknown same-name live persistent ID disqualifies")
    func rule3UnknownSameNamePIDDisqualifies() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let copies = cleanupFixtureCopies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        try fixture.writePlan(plan, at: planDate)
        let target = verifiedCleanupTarget(for: plan, name: "Trance 2022 \u{2014} Merged")
        let unknown = PlaylistListing(
            playlistId: 99,
            name: "Trance 2022",
            persistentId: "CPYXXXX000000009",
            trackCount: 4,
            isSmart: false,
            specialKind: "none"
        )
        let scanner = candidacyScanner(
            fixture: fixture,
            live: [
                "Trance 2022": copies,
                "Trance 2022 \u{2014} Merged": [target],
            ],
            extraListings: [unknown]
        )

        let candidate = try #require(try scanner.scan().first)
        let reason = try #require(candidate.disqualification)
        #expect(reason.contains("CPYXXXX000000009"))
        #expect(reason.contains("not in the plan"))
    }

    @Test("rule 4: the #Musica xTotal name is excluded without rule 1-3 ever consulting the listing")
    func rule4ProtectedNameExcludedWithoutLiveReads() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let copies = cleanupFixtureCopies(name: "#Musica xTotal")
        let plan = try buildMergePlan(name: "#Musica xTotal", copies: copies)
        try fixture.writePlan(plan, at: planDate)
        // scan() now fetches the listing exactly ONCE, unconditionally,
        // before any group is evaluated (see
        // scanConsumesExactlyOneListingReadRegardlessOfGroupCount) — a
        // pilot-only report no longer skips the listPlaylists closure call
        // itself. What's still guaranteed is that rule 4's DECISION never
        // consults listing content: an empty listing (which would fail rule
        // 1 for any non-pilot group, target absent) still yields the
        // CONTRACT reason, not a rule 1/2/3 one, proving rule 4 short-
        // circuits candidacy() before rules 1-3 run.
        let scanner = fixture.scanner(listPlaylists: { [] })

        let candidate = try #require(try scanner.scan().first)
        let reason = try #require(candidate.disqualification)
        #expect(reason.hasPrefix("excluded by contract: #Musica xTotal"))
        #expect(candidate.targetPresent == false)
    }

    @Test("rule 4: the protected pilot persistent IDs are excluded")
    func rule4ProtectedPersistentIDExcluded() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let pilotCopy = PlaylistSnapshot(
            name: "Renamed Pilot",
            persistentId: "E02030832FD20B07",
            tracks: [
                presentationTrack(
                    sourceIndex: 0, databaseId: 7, persistentId: "T0000007", title: "Pilot"
                )
            ]
        )
        let plan = try buildMergePlan(name: "Renamed Pilot", copies: [pilotCopy])
        try fixture.writePlan(plan, at: planDate)
        // See rule4ProtectedNameExcludedWithoutLiveReads: scan() always
        // fetches the listing once now, so an empty listing (not a throw)
        // is what proves rule 4's decision is listing-content-independent.
        let scanner = fixture.scanner(listPlaylists: { [] })

        let candidate = try #require(try scanner.scan().first)
        let reason = try #require(candidate.disqualification)
        #expect(reason.contains("E02030832FD20B07"))
    }

    @Test("a group with zero remaining live copies drops out of the results")
    func zeroLiveCopiesDropsOut() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let copies = cleanupFixtureCopies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        try fixture.writePlan(plan, at: planDate)
        try writeGenuineDeleteAccounting(
            fixture,
            playlistName: "Trance 2022",
            persistentID: "CPYAAAA000000001",
            trackPersistentIDs: ["T0000001", "T0000002"],
            planDate: planDate.addingTimeInterval(900),
            resultFileName: "Trance-2022-20260803-121500+0000.mutationresult.md"
        )
        try writeGenuineDeleteAccounting(
            fixture,
            playlistName: "Trance 2022",
            persistentID: "CPYBBBB000000002",
            trackPersistentIDs: ["T0000003"],
            planDate: planDate.addingTimeInterval(1800),
            resultFileName: "Trance-2022-20260803-122500+0000.mutationresult.md"
        )
        let target = verifiedCleanupTarget(for: plan, name: "Trance 2022 \u{2014} Merged")
        let scanner = candidacyScanner(fixture: fixture, live: [
            "Trance 2022": [],
            "Trance 2022 \u{2014} Merged": [target],
        ])

        #expect(try scanner.scan().isEmpty)
    }

    @Test("fix round 1: a deleted-ok line reusing a DIFFERENT plan's sha does not account, even though that other plan is a real, consumed delete plan")
    func forgedAccountingReusingAnotherPlansShaDisqualifies() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let copies = cleanupFixtureCopies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        try fixture.writePlan(plan, at: planDate)
        // A real, consumed delete plan exists for a WHOLLY UNRELATED
        // playlist (not either copy in this group).
        let otherSha = try writeGenuineDeleteAccounting(
            fixture,
            playlistName: "Some Other Playlist",
            persistentID: "CPYZZZZ000000099",
            trackPersistentIDs: ["T9999998"],
            planDate: planDate.addingTimeInterval(900),
            resultFileName: "Some-Other-Playlist-20260803-121500+0000.mutationresult.md"
        )
        // Forged: copy CPYBBBB000000002 is absent, and the only deleted-ok
        // line naming it cites the OTHER plan's sha, not one recomputed from
        // a delete plan pinned to CPYBBBB000000002 itself.
        try fixture.writeText(
            "deleted-ok CPYBBBB000000002 \(otherSha)\n",
            fileName: "Trance-2022-20260803-122500+0000.mutationresult.md"
        )
        let target = verifiedCleanupTarget(for: plan, name: "Trance 2022 \u{2014} Merged")
        let scanner = candidacyScanner(fixture: fixture, live: [
            "Trance 2022": [copies[0]],
            "Trance 2022 \u{2014} Merged": [target],
        ])

        let candidate = try #require(try scanner.scan().first)
        let reason = try #require(candidate.disqualification)
        #expect(reason.contains("without a recorded delete"))
        #expect(reason.contains("CPYBBBB000000002"))
        guard case .drifted = candidate.copies[1].disposition else {
            Issue.record("forged accounting must not yield .alreadyDeleted, got \(candidate.copies[1].disposition)")
            return
        }
    }

    @Test("fix round 1: a consumed rename plan's sha cannot back a delete accounting claim for its own PID")
    func renamePlanShaCannotAccountADelete() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        let copies = cleanupFixtureCopies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        try fixture.writePlan(plan, at: planDate)
        let renamePlan = MutationPlan(
            kind: .rename,
            playlistName: "Trance 2022",
            playlistPersistentID: "CPYBBBB000000002",
            trackCount: 1,
            orderedTrackPersistentIDs: ["T0000003"],
            newName: "Trance 2022 (renamed)",
            listingFingerprint: String(repeating: "cd", count: 32),
            evidence: nil,
            createdAtISO8601: "2026-08-03T12:05:00Z",
            sessionID: "11111111-2222-3333-4444-555555555555"
        )
        let renamePaths = try writeMutationAudit(
            outputDir: fixture.reportsDir,
            plan: renamePlan,
            summaryText: "# Rename Trance 2022\n",
            now: { planDate.addingTimeInterval(900) },
            timeZone: TimeZone(identifier: "UTC")!
        )
        try markMutationPlanConsumed(planURL: renamePaths.planURL)
        // The rename's OWN PID, and its OWN recomputed sha — still must not
        // account: rule 2's accounting requires a delete-kind plan.
        try fixture.writeText(
            "deleted-ok CPYBBBB000000002 \(renamePlan.sha256Hex())\n",
            fileName: "Trance-2022-20260803-121500+0000.mutationresult.md"
        )
        let target = verifiedCleanupTarget(for: plan, name: "Trance 2022 \u{2014} Merged")
        let scanner = candidacyScanner(fixture: fixture, live: [
            "Trance 2022": [copies[0]],
            "Trance 2022 \u{2014} Merged": [target],
        ])

        let candidate = try #require(try scanner.scan().first)
        let reason = try #require(candidate.disqualification)
        #expect(reason.contains("without a recorded delete"))
        #expect(reason.contains("CPYBBBB000000002"))
    }

    @Test("scan() reads the listing exactly once, no matter how many groups are discovered")
    func scanConsumesExactlyOneListingReadRegardlessOfGroupCount() async throws {
        let fixture = try CleanupFixture()
        defer { fixture.cleanUp() }
        var allListings: [PlaylistListing] = []
        var nextId = 1.0
        let groupNames = ["Alpha List", "Beta List", "Gamma List", "Delta List", "Epsilon List"]
        for (index, groupName) in groupNames.enumerated() {
            let copy = PlaylistSnapshot(
                name: groupName,
                persistentId: "CPYGRP\(index)00000001",
                tracks: [
                    presentationTrack(
                        sourceIndex: 0,
                        databaseId: index,
                        persistentId: "TGRP\(index)0000001",
                        title: "Track \(index)"
                    )
                ]
            )
            let plan = try buildMergePlan(name: groupName, copies: [copy])
            try fixture.writePlan(plan, at: planDate.addingTimeInterval(Double(index)))
            let target = verifiedCleanupTarget(for: plan, name: "\(groupName) \u{2014} Merged")
            allListings.append(cleanupLiveListing(copy, id: nextId))
            nextId += 1
            allListings.append(cleanupLiveListing(target, id: nextId))
            nextId += 1
        }

        // A minimal thread-safe counter: scan() is @MainActor and calls the
        // closure synchronously, but the counter itself makes no such
        // assumption so the test stays correct even if that ever changes.
        final class ReadCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() {
                lock.lock()
                value += 1
                lock.unlock()
            }
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }
        let counter = ReadCounter()
        let scanner = fixture.scanner(listPlaylists: {
            counter.increment()
            return allListings
        })

        // Class-level compile-time guarantee: CleanupScanner.init no longer
        // has a snapshotAllCopies parameter at all, so scan() cannot possibly
        // trigger a per-track live read regardless of how many groups exist
        // — the only live surface left is the single listPlaylists closure.
        let candidates = try scanner.scan()

        #expect(candidates.count == groupNames.count)
        #expect(counter.count == 1)
    }
}
