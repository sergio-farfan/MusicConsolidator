// MutationPlanTests.swift
// Wave B Task 1 — the guarded-mutation artifact model (spec B2): strict
// Codable (unknown AND missing keys reject; nullable fields must be explicit
// nulls), the integral-float raw-token gate, canonical sorted-keys SHA-256,
// and the canonical full-listing fingerprint.

import Foundation
import Testing
@testable import ConsolidatorCore

private func makeListing(
    id: Double = 1,
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

private let fixtureListing: [PlaylistListing] = [
    makeListing(id: 1, name: "Trance 2022", pid: "PID-DOOMED", count: 2),
    makeListing(id: 2, name: "Positive", pid: "PID-KEEP", count: 9),
    makeListing(id: 3, name: "Top 25", pid: "PID-SMART", count: 25, smart: true),
]

private func makeDeletePlan() -> MutationPlan {
    MutationPlan(
        kind: .delete,
        playlistName: "Trance 2022",
        playlistPersistentID: "PID-DOOMED",
        trackCount: 2,
        orderedTrackPersistentIDs: ["T0", "T1"],
        newName: nil,
        listingFingerprint: listingFingerprint(of: fixtureListing),
        evidence: MutationEvidence(
            mergePlanFileName: "Trance-2022-20260803-100000-0500.plan.json",
            runReportFileName: nil,
            verificationNote: "target verified against plan at 2026-08-03T10:00:00-05:00"
        ),
        createdAtISO8601: "2026-08-03T10:00:00-05:00",
        sessionID: "6F9619FF-8B86-D011-B42D-00CF4FC964FF"
    )
}

private let mutationPlanJSONKeys: Set<String> = [
    "kind", "playlist_name", "playlist_persistent_id", "track_count",
    "ordered_track_persistent_ids", "new_name", "listing_fingerprint",
    "evidence", "created_at_iso8601", "session_id",
]

private func mutationPlanJSONObject(
    overrides: [String: Any] = [:],
    omitting: Set<String> = []
) -> [String: Any] {
    var object: [String: Any] = [
        "kind": "delete",
        "playlist_name": "Trance 2022",
        "playlist_persistent_id": "PID-DOOMED",
        "track_count": 2,
        "ordered_track_persistent_ids": ["T0", "T1"],
        "new_name": NSNull(),
        "listing_fingerprint": listingFingerprint(of: fixtureListing),
        "evidence": NSNull(),
        "created_at_iso8601": "2026-08-03T10:00:00-05:00",
        "session_id": "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
    ]
    for (key, value) in overrides { object[key] = value }
    for key in omitting { object.removeValue(forKey: key) }
    return object
}

@Suite("MutationPlan strict Codable, canonical hash, listing fingerprint")
struct MutationPlanTests {

    @Test("a delete plan round-trips with exactly the snake_case wire keys")
    func deletePlanRoundTrips() throws {
        let plan = makeDeletePlan()
        let data = plan.canonicalJSONData()

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == mutationPlanJSONKeys)

        let decoded = try JSONDecoder().decode(MutationPlan.self, from: data)
        #expect(decoded == plan)
    }

    @Test("a rename plan with newName and nil evidence round-trips")
    func renamePlanRoundTrips() throws {
        let plan = MutationPlan(
            kind: .rename,
            playlistName: "Positive ",
            playlistPersistentID: "PID-KEEP",
            trackCount: 9,
            orderedTrackPersistentIDs: ["T7"],
            newName: "Positive",
            listingFingerprint: listingFingerprint(of: fixtureListing),
            evidence: nil,
            createdAtISO8601: "2026-08-03T10:05:00-05:00",
            sessionID: "6F9619FF-8B86-D011-B42D-00CF4FC964FF"
        )
        let decoded = try JSONDecoder().decode(MutationPlan.self, from: plan.canonicalJSONData())
        #expect(decoded == plan)
        #expect(decoded.newName == "Positive")
        #expect(decoded.evidence == nil)
    }

    @Test("decoding throws on an unexpected extra field")
    func decodingThrowsOnUnknownField() throws {
        let data = try JSONSerialization.data(
            withJSONObject: mutationPlanJSONObject(overrides: ["surprise": 1])
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MutationPlan.self, from: data)
        }
    }

    @Test("decoding throws when a required field is missing")
    func decodingThrowsOnMissingField() throws {
        let data = try JSONSerialization.data(
            withJSONObject: mutationPlanJSONObject(omitting: ["listing_fingerprint"])
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MutationPlan.self, from: data)
        }
    }

    @Test("nullable fields must still be present as explicit nulls")
    func decodingThrowsOnMissingNullableField() throws {
        let data = try JSONSerialization.data(
            withJSONObject: mutationPlanJSONObject(omitting: ["new_name"])
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MutationPlan.self, from: data)
        }
    }

    @Test("the evidence object rejects unknown and missing keys")
    func evidenceStrictDecode() throws {
        let goodEvidence: [String: Any] = [
            "merge_plan_file_name": "Trance-2022-20260803-100000-0500.plan.json",
            "run_report_file_name": NSNull(),
            "verification_note": "fresh verification passed",
        ]
        var withEvidence = mutationPlanJSONObject()
        withEvidence["evidence"] = goodEvidence
        let goodData = try JSONSerialization.data(withJSONObject: withEvidence)
        let decoded = try JSONDecoder().decode(MutationPlan.self, from: goodData)
        #expect(decoded.evidence?.mergePlanFileName == "Trance-2022-20260803-100000-0500.plan.json")
        #expect(decoded.evidence?.runReportFileName == nil)

        var extra = goodEvidence
        extra["surprise"] = true
        var withExtra = mutationPlanJSONObject()
        withExtra["evidence"] = extra
        let extraData = try JSONSerialization.data(withJSONObject: withExtra)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MutationPlan.self, from: extraData)
        }

        var missing = goodEvidence
        missing.removeValue(forKey: "verification_note")
        var withMissing = mutationPlanJSONObject()
        withMissing["evidence"] = missing
        let missingData = try JSONSerialization.data(withJSONObject: withMissing)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MutationPlan.self, from: missingData)
        }
    }

    @Test("an integral-float track_count is rejected by the raw-token gate")
    func integralFloatCountRejected() throws {
        // JSONDecoder alone ACCEPTS {"track_count": 2.0} for an Int on this
        // platform (probed 2026-08-03; the Persistence.swift header records
        // the same as the BINDING item) — the raw-token pre-pass is what
        // rejects it, exactly like loadPlan/loadMergePlan.
        // canonicalJSONData() is compact sorted-keys JSON, so track_count is
        // the LAST top-level key and its value is followed by "}".
        let canonical = String(decoding: makeDeletePlan().canonicalJSONData(), as: UTF8.self)
        let tampered = canonical.replacingOccurrences(
            of: "\"track_count\":2}", with: "\"track_count\":2.0}"
        )
        #expect(tampered != canonical)
        #expect(throws: PlanLoadError.self) {
            _ = try decodeMutationPlan(fromJSONData: Data(tampered.utf8), source: "test payload")
        }
        // Control: the untampered document decodes through the same gate.
        let plan = try decodeMutationPlan(
            fromJSONData: Data(canonical.utf8), source: "test payload"
        )
        #expect(plan == makeDeletePlan())
    }

    @Test("the sha is stable across JSON key order")
    func shaStableAcrossKeyOrder() throws {
        let plan = makeDeletePlan()
        // Same object, keys deliberately scrambled relative to sorted order.
        let scrambled = """
        {"session_id": "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
         "track_count": 2,
         "kind": "delete",
         "new_name": null,
         "playlist_persistent_id": "PID-DOOMED",
         "ordered_track_persistent_ids": ["T0", "T1"],
         "listing_fingerprint": "\(listingFingerprint(of: fixtureListing))",
         "created_at_iso8601": "2026-08-03T10:00:00-05:00",
         "evidence": {"verification_note": "target verified against plan at 2026-08-03T10:00:00-05:00",
                      "merge_plan_file_name": "Trance-2022-20260803-100000-0500.plan.json",
                      "run_report_file_name": null},
         "playlist_name": "Trance 2022"}
        """
        let decoded = try decodeMutationPlan(
            fromJSONData: Data(scrambled.utf8), source: "test payload"
        )
        #expect(decoded == plan)
        #expect(decoded.sha256Hex() == plan.sha256Hex())
        #expect(plan.sha256Hex().count == 64)
        #expect(plan.sha256Hex().allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test("the sha changes when a field changes")
    func shaSensitiveToContent() {
        let base = makeDeletePlan()
        let differentName = MutationPlan(
            kind: base.kind,
            playlistName: "Trance 2023",
            playlistPersistentID: base.playlistPersistentID,
            trackCount: base.trackCount,
            orderedTrackPersistentIDs: base.orderedTrackPersistentIDs,
            newName: base.newName,
            listingFingerprint: base.listingFingerprint,
            evidence: base.evidence,
            createdAtISO8601: base.createdAtISO8601,
            sessionID: base.sessionID
        )
        #expect(base.sha256Hex() != differentName.sha256Hex())
    }

    @Test("the listing fingerprint is stable under listing order permutation")
    func fingerprintStableUnderPermutation() {
        let base = listingFingerprint(of: fixtureListing)
        #expect(listingFingerprint(of: Array(fixtureListing.reversed())) == base)
        let rotated = Array(fixtureListing[1...]) + [fixtureListing[0]]
        #expect(listingFingerprint(of: rotated) == base)
    }

    @Test("the listing fingerprint is sensitive to every fingerprinted field and to membership")
    func fingerprintSensitiveToEachField() {
        let base = listingFingerprint(of: fixtureListing)

        func variant(replacing index: Int, with entry: PlaylistListing) -> String {
            var entries = fixtureListing
            entries[index] = entry
            return listingFingerprint(of: entries)
        }

        // persistent ID
        #expect(variant(replacing: 1, with: makeListing(id: 2, name: "Positive", pid: "PID-DRIFT", count: 9)) != base)
        // name: trailing space
        #expect(variant(replacing: 1, with: makeListing(id: 2, name: "Positive ", pid: "PID-KEEP", count: 9)) != base)
        // name: NFC vs NFD differ (Swift String == would call these equal)
        let nfc = variant(replacing: 1, with: makeListing(id: 2, name: "Caf\u{E9}", pid: "PID-KEEP", count: 9))
        let nfd = variant(replacing: 1, with: makeListing(id: 2, name: "Cafe\u{301}", pid: "PID-KEEP", count: 9))
        #expect(("Caf\u{E9}" as String) == ("Cafe\u{301}" as String))
        #expect(nfc != nfd)
        // track count
        #expect(variant(replacing: 1, with: makeListing(id: 2, name: "Positive", pid: "PID-KEEP", count: 10)) != base)
        // isSmart
        #expect(variant(replacing: 1, with: makeListing(id: 2, name: "Positive", pid: "PID-KEEP", count: 9, smart: true)) != base)
        // specialKind
        #expect(variant(replacing: 1, with: makeListing(id: 2, name: "Positive", pid: "PID-KEEP", count: 9, specialKind: "folder")) != base)
        // membership: added and removed entries change the fingerprint
        #expect(listingFingerprint(of: fixtureListing + [makeListing(id: 4, name: "New", pid: "PID-NEW", count: 1)]) != base)
        #expect(listingFingerprint(of: Array(fixtureListing.dropLast())) != base)
        // playlistId is session-scoped and deliberately NOT fingerprinted
        #expect(variant(replacing: 1, with: makeListing(id: 99, name: "Positive", pid: "PID-KEEP", count: 9)) == base)
    }
}
