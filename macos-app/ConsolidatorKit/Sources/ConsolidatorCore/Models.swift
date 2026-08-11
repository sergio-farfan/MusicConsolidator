// Models.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Swift port of apple_music_consolidator/models.py: TrackSnapshot,
// PlaylistSnapshot (M1) plus DuplicateDecision, ConsolidationPlan, MergePlan,
// AuditPaths, ApplyResult, and combineSourceTracks (M2).
//
// The Python reference implementation enforces `_require_exact_fields`: decoding a dict rejects both
// missing AND unknown top-level keys. Swift's default `Decodable` synthesis silently
// ignores unknown keys and only fails on missing keys lacking a default, so both
// types below implement a custom `init(from:)` that inspects the raw JSON keys.
//
// Gotcha (verified empirically, not just in theory): a `KeyedDecodingContainer`
// keyed by a *fixed* `CodingKeys` enum silently drops any JSON key that doesn't
// match one of the enum's cases from `allKeys` — Foundation's decoder builds
// `allKeys` by calling `CodingKeys(stringValue:)` per raw JSON key and discarding
// the `nil` results. So checking `allKeys` against a `KeyedDecodingContainer<CodingKeys>`
// can NEVER see an unknown/extra key; it always looks "exact" even when the
// payload has a `"surprise"` field. To see the real raw key set we must first
// decode a container keyed by a permissive `AnyCodingKey` that accepts any
// string, whose `allKeys` therefore reflects every key actually present.

import Foundation

/// A `CodingKey` that accepts any string, used only to enumerate the raw set of
/// keys present in a JSON object (Foundation's real `CodingKeys` enums silently
/// drop unmatched keys from `allKeys` — see note above).
private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Mirrors Python's `_require_exact_fields`: the set of keys present in the
/// payload must equal `expected` exactly — no missing, no extras.
func requireExactTopLevelKeys(decoder: Decoder, expected: Set<String>, context: String) throws {
    let rawContainer = try decoder.container(keyedBy: AnyCodingKey.self)
    let present = Set(rawContainer.allKeys.map(\.stringValue))
    let missing = expected.subtracting(present).sorted()
    let unknown = present.subtracting(expected).sorted()
    if !missing.isEmpty {
        throw DecodingError.keyNotFound(
            AnyCodingKey(stringValue: missing[0])!,
            DecodingError.Context(
                codingPath: rawContainer.codingPath,
                debugDescription: "\(context) missing field(s): \(missing.joined(separator: ", "))"
            )
        )
    }
    if !unknown.isEmpty {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: rawContainer.codingPath,
                debugDescription: "\(context) has unexpected field(s): \(unknown.joined(separator: ", "))"
            )
        )
    }
}

/// Like `requireExactTopLevelKeys`, but an `optional` subset of keys may be
/// entirely ABSENT rather than required-present (possibly null). Used for
/// `MergePlan`'s free-form fields (2026-08-06 free-form design): plan.json
/// files written before that design has no `source_persistent_ids` /
/// `target_description` / `source_names` keys at all, and must keep loading
/// unchanged — `requireExactTopLevelKeys`'s "no missing, no extras" would
/// reject every one of them. `required` keys must all be present;
/// `optional` keys may be present (with any legal value, including an
/// explicit null) or absent; anything outside `required ∪ optional` is
/// still rejected as unknown, exactly like `requireExactTopLevelKeys`.
func requireTopLevelKeys(
    decoder: Decoder,
    required: Set<String>,
    optional: Set<String>,
    context: String
) throws {
    let rawContainer = try decoder.container(keyedBy: AnyCodingKey.self)
    let present = Set(rawContainer.allKeys.map(\.stringValue))
    let missing = required.subtracting(present).sorted()
    let unknown = present.subtracting(required.union(optional)).sorted()
    if !missing.isEmpty {
        throw DecodingError.keyNotFound(
            AnyCodingKey(stringValue: missing[0])!,
            DecodingError.Context(
                codingPath: rawContainer.codingPath,
                debugDescription: "\(context) missing field(s): \(missing.joined(separator: ", "))"
            )
        )
    }
    if !unknown.isEmpty {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: rawContainer.codingPath,
                debugDescription: "\(context) has unexpected field(s): \(unknown.joined(separator: ", "))"
            )
        )
    }
}

/// Immutable snapshot of a single Apple Music track, as produced by the Python
/// reference's `TrackSnapshot` dataclass (see apple_music_consolidator/models.py).
public struct TrackSnapshot: Equatable, Hashable, Codable, Sendable {
    public var sourceIndex: Int
    public var databaseId: Int
    public var persistentId: String
    public var title: String
    public var artist: String
    public var album: String
    public var durationMs: Int?
    public var kind: String
    public var bitRateKbps: Int?
    public var sampleRateHz: Int?
    public var cloudStatus: String
    public var isFileTrack: Bool

    public init(
        sourceIndex: Int,
        databaseId: Int,
        persistentId: String,
        title: String,
        artist: String,
        album: String,
        durationMs: Int?,
        kind: String,
        bitRateKbps: Int?,
        sampleRateHz: Int?,
        cloudStatus: String,
        isFileTrack: Bool
    ) {
        self.sourceIndex = sourceIndex
        self.databaseId = databaseId
        self.persistentId = persistentId
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.kind = kind
        self.bitRateKbps = bitRateKbps
        self.sampleRateHz = sampleRateHz
        self.cloudStatus = cloudStatus
        self.isFileTrack = isFileTrack
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case sourceIndex = "source_index"
        case databaseId = "database_id"
        case persistentId = "persistent_id"
        case title
        case artist
        case album
        case durationMs = "duration_ms"
        case kind
        case bitRateKbps = "bit_rate_kbps"
        case sampleRateHz = "sample_rate_hz"
        case cloudStatus = "cloud_status"
        case isFileTrack = "is_file_track"
    }

    public init(from decoder: Decoder) throws {
        try requireExactTopLevelKeys(
            decoder: decoder,
            expected: Set(CodingKeys.allCases.map(\.stringValue)),
            context: "track"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.sourceIndex = try container.decode(Int.self, forKey: .sourceIndex)
        self.databaseId = try container.decode(Int.self, forKey: .databaseId)
        self.persistentId = try container.decode(String.self, forKey: .persistentId)
        self.title = try container.decode(String.self, forKey: .title)
        self.artist = try container.decode(String.self, forKey: .artist)
        self.album = try container.decode(String.self, forKey: .album)
        self.durationMs = try container.decode(Int?.self, forKey: .durationMs)
        self.kind = try container.decode(String.self, forKey: .kind)
        self.bitRateKbps = try container.decode(Int?.self, forKey: .bitRateKbps)
        self.sampleRateHz = try container.decode(Int?.self, forKey: .sampleRateHz)
        self.cloudStatus = try container.decode(String.self, forKey: .cloudStatus)
        self.isFileTrack = try container.decode(Bool.self, forKey: .isFileTrack)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceIndex, forKey: .sourceIndex)
        try container.encode(databaseId, forKey: .databaseId)
        try container.encode(persistentId, forKey: .persistentId)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(kind, forKey: .kind)
        try container.encode(bitRateKbps, forKey: .bitRateKbps)
        try container.encode(sampleRateHz, forKey: .sampleRateHz)
        try container.encode(cloudStatus, forKey: .cloudStatus)
        try container.encode(isFileTrack, forKey: .isFileTrack)
    }
}

/// Immutable snapshot of a playlist and its ordered tracks, mirroring Python's
/// `PlaylistSnapshot` dataclass.
public struct PlaylistSnapshot: Equatable, Hashable, Codable, Sendable {
    public var name: String
    public var persistentId: String
    public var tracks: [TrackSnapshot]

    public init(name: String, persistentId: String, tracks: [TrackSnapshot]) {
        self.name = name
        self.persistentId = persistentId
        self.tracks = tracks
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case persistentId = "persistent_id"
        case tracks
    }

    public init(from decoder: Decoder) throws {
        try requireExactTopLevelKeys(
            decoder: decoder,
            expected: Set(CodingKeys.allCases.map(\.stringValue)),
            context: "playlist"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.name = try container.decode(String.self, forKey: .name)
        self.persistentId = try container.decode(String.self, forKey: .persistentId)
        self.tracks = try container.decode([TrackSnapshot].self, forKey: .tracks)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(persistentId, forKey: .persistentId)
        try container.encode(tracks, forKey: .tracks)
    }
}

/// One resolved duplicate group: the retained winner, every omitted copy, and
/// the decisive reason per omitted source index. Mirrors Python's
/// `DuplicateDecision` dataclass; `reason_by_omitted_index` serializes as a
/// JSON array of `[source_index, reason]` two-element arrays, exactly like the
/// reference's `to_dict`.
public struct DuplicateDecision: Equatable, Hashable, Codable, Sendable {
    public let firstSourceIndex: Int
    public let winner: TrackSnapshot
    public let omitted: [TrackSnapshot]
    public let reasonByOmittedIndex: [OmittedReason]

    /// One `[source_index, reason]` pair. Decoding ports the reference's checks
    /// (models.py `DuplicateDecision.from_dict`): exactly two values, an
    /// integer index (booleans rejected), a non-empty string reason.
    public struct OmittedReason: Equatable, Hashable, Codable, Sendable {
        public let sourceIndex: Int
        public let reason: String

        public init(sourceIndex: Int, reason: String) {
            self.sourceIndex = sourceIndex
            self.reason = reason
        }

        public init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            let position = decoder.codingPath.last?.intValue.map(String.init) ?? "?"
            if let count = container.count, count != 2 {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "duplicate decision reason mapping \(position) "
                            + "must contain exactly two values"
                    )
                )
            }
            self.sourceIndex = try container.decode(Int.self)
            self.reason = try container.decode(String.self)
            if !container.isAtEnd {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "duplicate decision reason mapping \(position) "
                            + "must contain exactly two values"
                    )
                )
            }
            if reason.isEmpty {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "duplicate decision reason mapping \(position) "
                            + "reason must not be empty"
                    )
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(sourceIndex)
            try container.encode(reason)
        }
    }

    public init(
        firstSourceIndex: Int,
        winner: TrackSnapshot,
        omitted: [TrackSnapshot],
        reasonByOmittedIndex: [OmittedReason]
    ) {
        self.firstSourceIndex = firstSourceIndex
        self.winner = winner
        self.omitted = omitted
        self.reasonByOmittedIndex = reasonByOmittedIndex
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case firstSourceIndex = "first_source_index"
        case winner
        case omitted
        case reasonByOmittedIndex = "reason_by_omitted_index"
    }

    public init(from decoder: Decoder) throws {
        try requireExactTopLevelKeys(
            decoder: decoder,
            expected: Set(CodingKeys.allCases.map(\.stringValue)),
            context: "duplicate decision"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.firstSourceIndex = try container.decode(Int.self, forKey: .firstSourceIndex)
        self.winner = try container.decode(TrackSnapshot.self, forKey: .winner)
        self.omitted = try container.decode([TrackSnapshot].self, forKey: .omitted)
        self.reasonByOmittedIndex = try container.decode([OmittedReason].self, forKey: .reasonByOmittedIndex)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(firstSourceIndex, forKey: .firstSourceIndex)
        try container.encode(winner, forKey: .winner)
        try container.encode(omitted, forKey: .omitted)
        try container.encode(reasonByOmittedIndex, forKey: .reasonByOmittedIndex)
    }
}

/// A complete, reviewable single-playlist consolidation plan. Mirrors Python's
/// `ConsolidationPlan` dataclass, including the explicit rejection of the
/// legacy schema that lacked the persisted `source_tracks` snapshot.
public struct ConsolidationPlan: Equatable, Hashable, Codable, Sendable {
    public let sourcePlaylistName: String
    public let sourcePlaylistPersistentId: String
    public let sourceFingerprint: String
    public let sourceTrackCount: Int
    public let sourceTracks: [TrackSnapshot]
    public let winnerSourceIndexes: [Int]
    public let decisions: [DuplicateDecision]
    public let nonEligibleSourceIndexes: [Int]

    public init(
        sourcePlaylistName: String,
        sourcePlaylistPersistentId: String,
        sourceFingerprint: String,
        sourceTrackCount: Int,
        sourceTracks: [TrackSnapshot],
        winnerSourceIndexes: [Int],
        decisions: [DuplicateDecision],
        nonEligibleSourceIndexes: [Int]
    ) {
        self.sourcePlaylistName = sourcePlaylistName
        self.sourcePlaylistPersistentId = sourcePlaylistPersistentId
        self.sourceFingerprint = sourceFingerprint
        self.sourceTrackCount = sourceTrackCount
        self.sourceTracks = sourceTracks
        self.winnerSourceIndexes = winnerSourceIndexes
        self.decisions = decisions
        self.nonEligibleSourceIndexes = nonEligibleSourceIndexes
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case sourcePlaylistName = "source_playlist_name"
        case sourcePlaylistPersistentId = "source_playlist_persistent_id"
        case sourceFingerprint = "source_fingerprint"
        case sourceTrackCount = "source_track_count"
        case sourceTracks = "source_tracks"
        case winnerSourceIndexes = "winner_source_indexes"
        case decisions
        case nonEligibleSourceIndexes = "non_eligible_source_indexes"
    }

    public init(from decoder: Decoder) throws {
        // Reference order (models.py ConsolidationPlan.from_dict): the legacy
        // schema check runs BEFORE the exact-fields check, so a payload
        // without `source_tracks` gets the explicit fresh-audit message
        // rather than a generic missing-field error.
        let rawContainer = try decoder.container(keyedBy: AnyCodingKey.self)
        if !rawContainer.allKeys.contains(where: { $0.stringValue == "source_tracks" }) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: rawContainer.codingPath,
                    debugDescription: "legacy consolidation plan schema is unsupported; "
                        + "a fresh audit is required"
                )
            )
        }
        try requireExactTopLevelKeys(
            decoder: decoder,
            expected: Set(CodingKeys.allCases.map(\.stringValue)),
            context: "consolidation plan"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sourcePlaylistName = try container.decode(String.self, forKey: .sourcePlaylistName)
        self.sourcePlaylistPersistentId = try container.decode(String.self, forKey: .sourcePlaylistPersistentId)
        self.sourceFingerprint = try container.decode(String.self, forKey: .sourceFingerprint)
        self.sourceTrackCount = try container.decode(Int.self, forKey: .sourceTrackCount)
        self.sourceTracks = try container.decode([TrackSnapshot].self, forKey: .sourceTracks)
        self.winnerSourceIndexes = try container.decode([Int].self, forKey: .winnerSourceIndexes)
        self.decisions = try container.decode([DuplicateDecision].self, forKey: .decisions)
        self.nonEligibleSourceIndexes = try container.decode([Int].self, forKey: .nonEligibleSourceIndexes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourcePlaylistName, forKey: .sourcePlaylistName)
        try container.encode(sourcePlaylistPersistentId, forKey: .sourcePlaylistPersistentId)
        try container.encode(sourceFingerprint, forKey: .sourceFingerprint)
        try container.encode(sourceTrackCount, forKey: .sourceTrackCount)
        try container.encode(sourceTracks, forKey: .sourceTracks)
        try container.encode(winnerSourceIndexes, forKey: .winnerSourceIndexes)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(nonEligibleSourceIndexes, forKey: .nonEligibleSourceIndexes)
    }
}

/// Concatenate copies in order, reassigning one global source index.
/// Mirrors Python's `combine_source_tracks`.
public func combineSourceTracks(_ copies: [PlaylistSnapshot]) -> [TrackSnapshot] {
    var combined: [TrackSnapshot] = []
    for copy in copies {
        for copyTrack in copy.tracks {
            var reindexed = copyTrack
            reindexed.sourceIndex = combined.count
            combined.append(reindexed)
        }
    }
    return combined
}

/// A complete, reviewable playlist merge plan. Mirrors Python's `MergePlan`
/// dataclass, including the derived helpers over the ordered copy
/// concatenation, PLUS the free-form variant (2026-08-06 design amendment,
/// Swift-native — no Python counterpart): `sourcePersistentIDs`,
/// `targetDescription`, and `sourceNames` are nil for a same-name plan and
/// ALL non-nil for a free-form plan (never mixed — enforced in both
/// `init(from:)` below and `validateMergePlanIntegrity`). For a same-name
/// plan, `mergedPlaylistSourceName` is the name every copy shares (used to
/// re-read "every copy of this name"); for a free-form plan it is the
/// COMPUTED TARGET name (`buildFreeFormMergePlan`'s `targetName`) — copies
/// carry their own distinct names instead, recorded in `sourceNames`.
public struct MergePlan: Equatable, Hashable, Codable, Sendable {
    public let mergedPlaylistSourceName: String
    public let copies: [PlaylistSnapshot]
    public let mergeFingerprint: String
    public let winnerSourceIndexes: [Int]
    public let decisions: [DuplicateDecision]
    public let nonEligibleSourceIndexes: [Int]
    public let sourcePersistentIDs: [String]?
    public let targetDescription: String?
    public let sourceNames: [String]?

    /// True for a free-form plan (copy set pinned by persistent ID, no
    /// shared name); false for a same-name plan. Reads `sourcePersistentIDs`
    /// alone — callers that also trust `targetDescription`/`sourceNames`
    /// together with this flag should check `freeFormFieldsAreConsistent`
    /// first (2026-08-06 review finding m1): `init(from:)` and
    /// `validateMergePlanIntegrity` both reject a partial free-form field
    /// set on the LOAD path, but a plan assembled in-memory (tests, or any
    /// future caller) bypasses both, so the write-path routing seams
    /// (`ensureFreeFormCopiesMatch`, `applyFreeFormMergePlan`,
    /// `buildMergeApplyScript`) assert it themselves before trusting this
    /// flag to mean what it says.
    public var isFreeForm: Bool {
        sourcePersistentIDs != nil
    }

    /// All-or-none check for the three free-form fields (2026-08-06 review
    /// finding m1): true when all three are nil (same-name) or all three
    /// are non-nil (free-form); false for a mixed/partial set that must
    /// never reach a write-path seam. See `isFreeForm`'s doc for which
    /// seams assert this and why.
    public var freeFormFieldsAreConsistent: Bool {
        let presence = [sourcePersistentIDs != nil, targetDescription != nil, sourceNames != nil]
        return Set(presence).count == 1
    }

    public var combinedTracks: [TrackSnapshot] {
        combineSourceTracks(copies)
    }

    public var combinedTrackCount: Int {
        copies.reduce(0) { $0 + $1.tracks.count }
    }

    public var copyBoundaries: [Int] {
        var boundaries: [Int] = []
        var running = 0
        for copy in copies {
            running += copy.tracks.count
            boundaries.append(running)
        }
        return boundaries
    }

    public init(
        mergedPlaylistSourceName: String,
        copies: [PlaylistSnapshot],
        mergeFingerprint: String,
        winnerSourceIndexes: [Int],
        decisions: [DuplicateDecision],
        nonEligibleSourceIndexes: [Int],
        sourcePersistentIDs: [String]? = nil,
        targetDescription: String? = nil,
        sourceNames: [String]? = nil
    ) {
        self.mergedPlaylistSourceName = mergedPlaylistSourceName
        self.copies = copies
        self.mergeFingerprint = mergeFingerprint
        self.winnerSourceIndexes = winnerSourceIndexes
        self.decisions = decisions
        self.nonEligibleSourceIndexes = nonEligibleSourceIndexes
        self.sourcePersistentIDs = sourcePersistentIDs
        self.targetDescription = targetDescription
        self.sourceNames = sourceNames
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case mergedPlaylistSourceName = "merged_playlist_source_name"
        case copies
        case mergeFingerprint = "merge_fingerprint"
        case winnerSourceIndexes = "winner_source_indexes"
        case decisions
        case nonEligibleSourceIndexes = "non_eligible_source_indexes"
        case sourcePersistentIDs = "source_persistent_ids"
        case targetDescription = "target_description"
        case sourceNames = "source_names"
    }

    /// The 6 fields every merge plan has always had; every plan.json written
    /// before the 2026-08-06 free-form design has exactly these keys.
    private static let requiredCodingKeys: Set<String> = Set([
        CodingKeys.mergedPlaylistSourceName, .copies, .mergeFingerprint,
        .winnerSourceIndexes, .decisions, .nonEligibleSourceIndexes,
    ].map(\.stringValue))

    /// The 3 free-form fields: OPTIONALLY absent (never required), so a
    /// pre-2026-08-06 plan.json keeps decoding unchanged — see
    /// `requireTopLevelKeys`'s header for why this can't reuse
    /// `requireExactTopLevelKeys`.
    private static let optionalCodingKeys: Set<String> = Set([
        CodingKeys.sourcePersistentIDs, .targetDescription, .sourceNames,
    ].map(\.stringValue))

    public init(from decoder: Decoder) throws {
        try requireTopLevelKeys(
            decoder: decoder,
            required: Self.requiredCodingKeys,
            optional: Self.optionalCodingKeys,
            context: "merge plan"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mergedPlaylistSourceName = try container.decode(String.self, forKey: .mergedPlaylistSourceName)
        self.copies = try container.decode([PlaylistSnapshot].self, forKey: .copies)
        self.mergeFingerprint = try container.decode(String.self, forKey: .mergeFingerprint)
        self.winnerSourceIndexes = try container.decode([Int].self, forKey: .winnerSourceIndexes)
        self.decisions = try container.decode([DuplicateDecision].self, forKey: .decisions)
        self.nonEligibleSourceIndexes = try container.decode([Int].self, forKey: .nonEligibleSourceIndexes)
        // `decodeIfPresent` treats BOTH an absent key and an explicit JSON
        // null as nil, which is exactly the "not a free-form plan" signal —
        // a pre-2026-08-06 plan.json (key absent) and a same-name plan
        // freshly re-encoded (key omitted, see `encode(to:)` below) decode
        // identically.
        self.sourcePersistentIDs = try container.decodeIfPresent([String].self, forKey: .sourcePersistentIDs)
        self.targetDescription = try container.decodeIfPresent(String.self, forKey: .targetDescription)
        self.sourceNames = try container.decodeIfPresent([String].self, forKey: .sourceNames)

        // Strict Codable rejects a plan mixing the same-name and free-form
        // variants: the three free-form fields must be all-nil or all-non-nil,
        // never a partial set (2026-08-06 free-form design, Engine section).
        let presence = [
            self.sourcePersistentIDs != nil,
            self.targetDescription != nil,
            self.sourceNames != nil,
        ]
        if Set(presence).count != 1 {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription:
                        "merge plan must set source_persistent_ids, target_description, "
                        + "and source_names together, or omit all three"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mergedPlaylistSourceName, forKey: .mergedPlaylistSourceName)
        try container.encode(copies, forKey: .copies)
        try container.encode(mergeFingerprint, forKey: .mergeFingerprint)
        try container.encode(winnerSourceIndexes, forKey: .winnerSourceIndexes)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(nonEligibleSourceIndexes, forKey: .nonEligibleSourceIndexes)
        // `encodeIfPresent` OMITS the key entirely when nil (never writes an
        // explicit null): a same-name plan's rendered JSON therefore stays
        // BYTE-IDENTICAL to the pre-2026-08-06 shape — the six keys above,
        // nothing else — which is what the Python-reference golden-parity
        // gates (AuditGoldenTests) and every persisted historical plan.json
        // in reports/ already are.
        try container.encodeIfPresent(sourcePersistentIDs, forKey: .sourcePersistentIDs)
        try container.encodeIfPresent(targetDescription, forKey: .targetDescription)
        try container.encodeIfPresent(sourceNames, forKey: .sourceNames)
    }
}

/// The three audit artifact paths. Mirrors Python's `AuditPaths` dataclass;
/// paths are stored as strings (the reference serializes `str(Path)`).
/// Decode is stricter than the reference's permissive `from_dict` (exact keys),
/// matching the M1 direction of keeping the STRICT side of any asymmetry.
public struct AuditPaths: Equatable, Hashable, Codable, Sendable {
    public let planJson: String
    public let detailCsv: String
    public let summaryMarkdown: String

    public init(planJson: String, detailCsv: String, summaryMarkdown: String) {
        self.planJson = planJson
        self.detailCsv = detailCsv
        self.summaryMarkdown = summaryMarkdown
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case planJson = "plan_json"
        case detailCsv = "detail_csv"
        case summaryMarkdown = "summary_markdown"
    }

    public init(from decoder: Decoder) throws {
        try requireExactTopLevelKeys(
            decoder: decoder,
            expected: Set(CodingKeys.allCases.map(\.stringValue)),
            context: "audit paths"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.planJson = try container.decode(String.self, forKey: .planJson)
        self.detailCsv = try container.decode(String.self, forKey: .detailCsv)
        self.summaryMarkdown = try container.decode(String.self, forKey: .summaryMarkdown)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(planJson, forKey: .planJson)
        try container.encode(detailCsv, forKey: .detailCsv)
        try container.encode(summaryMarkdown, forKey: .summaryMarkdown)
    }
}

/// Outcome of a guarded apply plus readback verification. Mirrors Python's
/// `ApplyResult` dataclass. Decode is stricter than the reference's permissive
/// `from_dict` (exact keys), matching the M1 strict direction.
public struct ApplyResult: Equatable, Hashable, Codable, Sendable {
    public let sourceFingerprint: String
    public let plannedCount: Int
    public let actualCount: Int
    public let verificationOk: Bool
    public let mismatches: [String]

    public init(
        sourceFingerprint: String,
        plannedCount: Int,
        actualCount: Int,
        verificationOk: Bool,
        mismatches: [String]
    ) {
        self.sourceFingerprint = sourceFingerprint
        self.plannedCount = plannedCount
        self.actualCount = actualCount
        self.verificationOk = verificationOk
        self.mismatches = mismatches
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case sourceFingerprint = "source_fingerprint"
        case plannedCount = "planned_count"
        case actualCount = "actual_count"
        case verificationOk = "verification_ok"
        case mismatches
    }

    public init(from decoder: Decoder) throws {
        try requireExactTopLevelKeys(
            decoder: decoder,
            expected: Set(CodingKeys.allCases.map(\.stringValue)),
            context: "apply result"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceFingerprint = try container.decode(String.self, forKey: .sourceFingerprint)
        self.plannedCount = try container.decode(Int.self, forKey: .plannedCount)
        self.actualCount = try container.decode(Int.self, forKey: .actualCount)
        self.verificationOk = try container.decode(Bool.self, forKey: .verificationOk)
        self.mismatches = try container.decode([String].self, forKey: .mismatches)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceFingerprint, forKey: .sourceFingerprint)
        try container.encode(plannedCount, forKey: .plannedCount)
        try container.encode(actualCount, forKey: .actualCount)
        try container.encode(verificationOk, forKey: .verificationOk)
        try container.encode(mismatches, forKey: .mismatches)
    }
}
