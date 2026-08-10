// MutationPlan.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Wave B (spec B2, artifact-first) — the guarded-mutation artifact model:
// one reviewable, session-bound, single-use plan per delete/rename, plus the
// canonical full-listing fingerprint the gate rechecks against a fresh live
// listing immediately before mutation.
//
// Strict Codable discipline mirrors Models.swift exactly: decoding rejects
// unknown AND missing top-level keys via `requireExactTopLevelKeys` (the
// permissive raw-key enumeration lives there — see the Models.swift header
// for why a fixed-CodingKeys container can never see extra keys). Nullable
// fields (new_name, evidence, run_report_file_name) must be PRESENT as
// explicit JSON nulls; an absent key is a missing-field rejection.
//
// Hashing mirrors Resolver.swift's sha256Hex: a Swift-owned canonical
// encoding (JSONEncoder, sorted keys, unescaped slashes) hashed with
// CryptoKit SHA-256. Integral-float rejection for track_count is NOT done
// here — Codable cannot see raw number tokens, and JSONDecoder accepts 2.0
// for an Int on this platform (the Persistence.swift BINDING item). It lives
// in Persistence.swift's decodeMutationPlan(fromJSONData:source:) raw-token
// pre-pass, the same gate loadPlan/loadMergePlan use.
//
// NOTE on equality: the synthesized Equatable uses Swift String == (canonical
// equivalence). It exists for tests and plumbing only. Every fail-closed
// GUARD comparison in later Wave B tasks must use scalarEqual, never == on
// these structs or their String fields.

import CryptoKit
import Foundation

/// The only two mutation verbs Wave B permits (spec B7 amendment).
public enum MutationKind: String, Codable, Sendable {
    case delete
    case rename
}

/// Cleanup-delete evidence chain (spec B2/B3): the merge plan and run record
/// that justify this delete, plus a human-readable fresh-verification
/// summary. General deletes and renames carry no evidence (nil).
public struct MutationEvidence: Codable, Equatable, Sendable {
    public let mergePlanFileName: String
    public let runReportFileName: String?
    public let verificationNote: String

    public init(
        mergePlanFileName: String,
        runReportFileName: String?,
        verificationNote: String
    ) {
        self.mergePlanFileName = mergePlanFileName
        self.runReportFileName = runReportFileName
        self.verificationNote = verificationNote
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case mergePlanFileName = "merge_plan_file_name"
        case runReportFileName = "run_report_file_name"
        case verificationNote = "verification_note"
    }

    public init(from decoder: Decoder) throws {
        try requireExactTopLevelKeys(
            decoder: decoder,
            expected: Set(CodingKeys.allCases.map(\.stringValue)),
            context: "mutation evidence"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mergePlanFileName = try container.decode(String.self, forKey: .mergePlanFileName)
        self.runReportFileName = try container.decode(String?.self, forKey: .runReportFileName)
        self.verificationNote = try container.decode(String.self, forKey: .verificationNote)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mergePlanFileName, forKey: .mergePlanFileName)
        try container.encode(runReportFileName, forKey: .runReportFileName)
        try container.encode(verificationNote, forKey: .verificationNote)
    }
}

/// One reviewable mutation artifact (spec B2): the pinned target's identity
/// snapshot, the pre-mutation full-listing fingerprint, the evidence chain,
/// and the session binding the gate re-checks at arm and dispatch time.
public struct MutationPlan: Codable, Equatable, Sendable {
    public let kind: MutationKind
    public let playlistName: String
    public let playlistPersistentID: String
    public let trackCount: Int
    public let orderedTrackPersistentIDs: [String]
    public let newName: String?
    public let listingFingerprint: String
    public let evidence: MutationEvidence?
    public let createdAtISO8601: String
    public let sessionID: String

    public init(
        kind: MutationKind,
        playlistName: String,
        playlistPersistentID: String,
        trackCount: Int,
        orderedTrackPersistentIDs: [String],
        newName: String?,
        listingFingerprint: String,
        evidence: MutationEvidence?,
        createdAtISO8601: String,
        sessionID: String
    ) {
        self.kind = kind
        self.playlistName = playlistName
        self.playlistPersistentID = playlistPersistentID
        self.trackCount = trackCount
        self.orderedTrackPersistentIDs = orderedTrackPersistentIDs
        self.newName = newName
        self.listingFingerprint = listingFingerprint
        self.evidence = evidence
        self.createdAtISO8601 = createdAtISO8601
        self.sessionID = sessionID
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case playlistName = "playlist_name"
        case playlistPersistentID = "playlist_persistent_id"
        case trackCount = "track_count"
        case orderedTrackPersistentIDs = "ordered_track_persistent_ids"
        case newName = "new_name"
        case listingFingerprint = "listing_fingerprint"
        case evidence
        case createdAtISO8601 = "created_at_iso8601"
        case sessionID = "session_id"
    }

    public init(from decoder: Decoder) throws {
        try requireExactTopLevelKeys(
            decoder: decoder,
            expected: Set(CodingKeys.allCases.map(\.stringValue)),
            context: "mutation plan"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(MutationKind.self, forKey: .kind)
        self.playlistName = try container.decode(String.self, forKey: .playlistName)
        self.playlistPersistentID = try container.decode(String.self, forKey: .playlistPersistentID)
        self.trackCount = try container.decode(Int.self, forKey: .trackCount)
        self.orderedTrackPersistentIDs = try container.decode([String].self, forKey: .orderedTrackPersistentIDs)
        self.newName = try container.decode(String?.self, forKey: .newName)
        self.listingFingerprint = try container.decode(String.self, forKey: .listingFingerprint)
        self.evidence = try container.decode(MutationEvidence?.self, forKey: .evidence)
        self.createdAtISO8601 = try container.decode(String.self, forKey: .createdAtISO8601)
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(playlistName, forKey: .playlistName)
        try container.encode(playlistPersistentID, forKey: .playlistPersistentID)
        try container.encode(trackCount, forKey: .trackCount)
        try container.encode(orderedTrackPersistentIDs, forKey: .orderedTrackPersistentIDs)
        try container.encode(newName, forKey: .newName)
        try container.encode(listingFingerprint, forKey: .listingFingerprint)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(createdAtISO8601, forKey: .createdAtISO8601)
        try container.encode(sessionID, forKey: .sessionID)
    }

    /// Canonical sorted-keys encoding — the byte payload the SHA-256 covers
    /// and the payload the gate re-hashes from disk immediately before
    /// dispatch. Mirrors the fingerprint encoding in Resolver.swift.
    public func canonicalJSONData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding cannot fail: every field is JSON-representable (no Double,
        // no non-string dictionary keys) — same argument as Resolver.sha256Hex.
        return try! encoder.encode(self)
    }

    /// SHA-256 hex over canonicalJSONData() (spec B2 artifact hash).
    public func sha256Hex() -> String {
        SHA256.hash(data: canonicalJSONData())
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - canonical listing fingerprint

/// Canonical fingerprint of one full playlist-enumeration listing (contract
/// placement decision: here rather than PlaylistGrouping.swift, keeping the
/// grouping module mutation-free and the CryptoKit import in one file).
///
/// Encoding, pinned: one line per entry —
/// persistentId U+001F name U+001F trackCount U+001F isSmart U+001F
/// specialKind (isSmart rendered "true"/"false", trackCount decimal) — lines
/// sorted with scalarLess on the COMPOSED line, which orders by persistent ID
/// first (U+001F sorts below every scalar a persistent ID contains) and stays
/// total and deterministic even for pathological duplicate-PID listings
/// (Swift's sort is not stable; the DIFF, not the fingerprint, refuses
/// duplicates) — joined with U+001E, SHA-256 hex over UTF-8.
/// playlistId is deliberately EXCLUDED: it is session-scoped and would break
/// fingerprint stability across app launches.
public func listingFingerprint(of listing: [PlaylistListing]) -> String {
    let lines = listing.map { entry in
        [
            entry.persistentId,
            entry.name,
            String(entry.trackCount),
            entry.isSmart ? "true" : "false",
            entry.specialKind,
        ].joined(separator: "\u{1F}")
    }.sorted(by: scalarLess)
    let payload = lines.joined(separator: "\u{1E}")
    return SHA256.hash(data: Data(payload.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}
