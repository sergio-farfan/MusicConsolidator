// MusicBridge.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Swift port of the IMPURE orchestration half of
// apple_music_consolidator/music_bridge.py (M5): strict parsing of the read
// JXA's JSON output, the fail-closed ensure/assert preflight, the guarded
// apply dispatch, and readback verification. Comments carry music_bridge.py
// line references; every message is reference-verbatim (verified in python3
// before porting — see the M5 report).
//
// Fail-closed contract (AGENTS.md "Apply"/"Same-name playlist merge"):
// stale/non-canonical plans, live drift, and target collisions are rejected
// BEFORE the writer runs; a writer/runner error NEVER flips to success; a
// partial target is inspected READ-ONLY and never deleted, renamed, or
// repaired; verification compares ordered database IDs and persistent IDs.
//
// Every string comparison on these surfaces is scalar-exact (`scalarEqual`),
// never Swift `String ==`: canonical equivalence would silently ACCEPT
// NFC/NFD-drifted names, titles, and persistent IDs that the reference rejects
// (the fail-open class the M4 review caught).
//
// Wire JSON is decoded through JSONDecoder into the dynamic `WireJSON` tree
// below, NOT through JSONSerialization: on this toolchain JSONSerialization
// silently strips a leading U+FEFF from every string value and key (a
// FEFF-only value becomes ""), while `json.loads` preserves it — so every
// scalar-exact comparison downstream would run on pre-normalized text
// (fix round 1, F1; verified empirically for escaped and raw FEFF, keys,
// FEFF-only values; JSONDecoder preserves all of them, along with combining
// marks, NFD sequences, ZWSP, and mid-string FEFF).
//
// Live Music is NEVER contacted here: all commands go through the injected
// `ScriptRunner`, and the real runner is M6.

import Foundation
import ConsolidatorCore

// MARK: - scalar-preserving wire JSON (fix round 1, F1)

/// A `CodingKey` accepting any string, used to enumerate JSON object keys.
private struct WireCodingKey: CodingKey {
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

/// Dynamic JSON value decoded via JSONDecoder (scalar-preserving; see the
/// file header) AFTER the StrictJSONScanner pre-pass in `loadWireJSON`,
/// which closes JSONDecoder's accept-direction leniencies (trailing commas,
/// document-leading BOM, duplicate object keys — fix round 2). Numbers keep
/// Python's int/float split: integer literals in Int range decode as
/// `.integer`, everything else numeric as `.double`. Remaining platform
/// limits vs the arbitrary-precision reference: reject-direction — integer
/// FIELDS beyond Int64 lose exactness (rejected by the integer extractors)
/// and lone surrogate escapes are unrepresentable in Swift.String ("Music
/// returned invalid JSON" where Python parses them); deferred
/// accept-with-divergent-values (sanctioned, hostile-only) — numeric values
/// above 2^53 that are NOT extracted as exact Ints (the copy-id sort key,
/// integer duration seconds) pass through Double and can differ from the
/// reference's bignum arithmetic; real Music ids and durations sit orders of
/// magnitude below 2^53.
enum WireJSON: Decodable {
    case object([String: WireJSON])
    case array([WireJSON])
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: WireCodingKey.self) {
            var object: [String: WireJSON] = [:]
            // Canonically-equivalent duplicate keys would merge here (Swift
            // String hashing); the wire field names are ASCII, which is
            // normalization-invariant, so lookups are unaffected.
            for key in keyed.allKeys {
                object[key.stringValue] = try keyed.decode(WireJSON.self, forKey: key)
            }
            self = .object(object)
        } else if var unkeyed = try? decoder.unkeyedContainer() {
            var array: [WireJSON] = []
            while !unkeyed.isAtEnd {
                array.append(try unkeyed.decode(WireJSON.self))
            }
            self = .array(array)
        } else {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() {
                self = .null
            } else if let boolean = try? single.decode(Bool.self) {
                self = .bool(boolean)
            } else if let integer = try? single.decode(Int.self) {
                self = .integer(integer)
            } else if let number = try? single.decode(Double.self) {
                self = .double(number)
            } else {
                self = .string(try single.decode(String.self))
            }
        }
    }
}

// MARK: - strict JSON helpers (music_bridge.py:198-207 _require_mapping/_require_list)

private func loadWireJSON(_ raw: String) throws -> WireJSON {
    do {
        // Fix round 2: strict syntax pre-pass, REUSING ConsolidatorCore's
        // StrictJSONScanner (the M3 loader gate) rather than a divergent
        // copy. It rejects what json.loads rejects but JSONDecoder accepts —
        // trailing commas, a document-leading BOM, malformed
        // escapes/numbers/literals, extra trailing data — plus duplicate
        // object keys at ANY nesting level, the sanctioned fail-closed
        // resolution of the duplicate-key winner flip (Swift resolves
        // first-wins, json.loads last-wins; rejection removes the
        // divergence, consistent with the plan loader's documented
        // deviation). FEFF inside string literals passes through untouched
        // (F1 preservation holds). Every rejection is classified the way
        // the reference classifies wire syntax errors
        // (music_bridge.py:234-236: json.JSONDecodeError -> ValueError
        // "Music returned invalid JSON").
        try StrictJSONScanner.check(raw)
        return try JSONDecoder().decode(WireJSON.self, from: Data(raw.utf8))
    } catch {
        throw MusicBridgeError("Music returned invalid JSON")
    }
}

private func requireMapping(_ value: WireJSON?, _ context: String) throws -> [String: WireJSON] {
    guard case .object(let mapping)? = value else {
        throw MusicBridgeError("\(context) must be a JSON object")
    }
    return mapping
}

private func requireList(_ value: WireJSON?, _ context: String) throws -> [WireJSON] {
    guard case .array(let list)? = value else {
        throw MusicBridgeError("\(context) must be a JSON array")
    }
    return list
}

/// Strict wire-field extraction. The dynamically-typed reference indexes these
/// fields without type checks (music_bridge.py:210-228) — KeyError when a
/// required key is missing — and the statically-typed port keeps the STRICT
/// side of that asymmetry (M1 precedent) with explicit fail-closed messages.
/// Booleans never satisfy numeric fields (`.bool` is a distinct case).
private func requireWireInt(_ object: [String: WireJSON], _ key: String, context: String) throws -> Int {
    switch object[key] {
    case .integer(let value)?:
        return value
    case .double(let value)?:
        guard let exact = Int(exactly: value) else {
            throw MusicBridgeError("\(context) \(key) must be an integer")
        }
        return exact
    default:
        throw MusicBridgeError("\(context) \(key) must be an integer")
    }
}

private func requireWireString(_ object: [String: WireJSON], _ key: String, context: String) throws -> String {
    guard case .string(let value)? = object[key] else {
        throw MusicBridgeError("\(context) \(key) must be a string")
    }
    return value
}

private func requireWireBool(_ object: [String: WireJSON], _ key: String, context: String) throws -> Bool {
    guard case .bool(let value)? = object[key] else {
        throw MusicBridgeError("\(context) \(key) must be a boolean")
    }
    return value
}

/// Present-but-null parses as nil; a MISSING key fails closed — the reference
/// indexes `track["bit_rate"]`/`track["sample_rate"]` directly, so a missing
/// key is a KeyError there, never a silent None (fix round 1, F2).
private func optionalWireInt(_ object: [String: WireJSON], _ key: String, context: String) throws -> Int? {
    switch object[key] {
    case .null?:
        return nil
    case .integer(let value)?:
        return value
    case .double(let value)?:
        guard let exact = Int(exactly: value) else {
            throw MusicBridgeError("\(context) \(key) must be an integer or null")
        }
        return exact
    default:
        throw MusicBridgeError("\(context) \(key) must be an integer or null")
    }
}

// MARK: - track/playlist parsing (music_bridge.py:210-278)

/// music_bridge.py:210-228 `_parse_track`. The wire shape is the read JXA's
/// output (duration in seconds, `bit_rate`/`sample_rate` wire names), so the
/// model's own Codable (plan-artifact shape) does not apply here.
private func parseWireTrack(_ value: WireJSON) throws -> TrackSnapshot {
    let trackObject = try requireMapping(value, "track")

    // music_bridge.py:212-214: the only optional wire key (`.get`) and the
    // only explicit type check the reference makes.
    let duration: Double?
    switch trackObject["duration"] {
    case nil, .null?:
        duration = nil
    case .integer(let value)?:
        duration = Double(value)
    case .double(let value)?:
        duration = value
    default:
        throw MusicBridgeError("track duration must be a number or null")
    }

    // Fix round 1, F3: the arbitrary-precision reference parses any magnitude;
    // Swift Int(Double) TRAPS beyond Int range, so the wire path fails closed
    // with a catchable error instead (documented reject-direction deviation).
    let durationMs: Int?
    if let seconds = duration {
        let milliseconds = (seconds * 1000).rounded(.toNearestOrEven)
        guard Int(exactly: milliseconds) != nil else {
            throw MusicBridgeError("track duration milliseconds exceed the supported integer range")
        }
        durationMs = durationToMs(seconds)
    } else {
        durationMs = nil
    }

    return TrackSnapshot(
        sourceIndex: try requireWireInt(trackObject, "source_index", context: "track"),
        databaseId: try requireWireInt(trackObject, "database_id", context: "track"),
        persistentId: try requireWireString(trackObject, "persistent_id", context: "track"),
        title: try requireWireString(trackObject, "title", context: "track"),
        artist: try requireWireString(trackObject, "artist", context: "track"),
        album: try requireWireString(trackObject, "album", context: "track"),
        durationMs: durationMs,
        kind: try requireWireString(trackObject, "kind", context: "track"),
        bitRateKbps: try optionalWireInt(trackObject, "bit_rate", context: "track"),
        sampleRateHz: try optionalWireInt(trackObject, "sample_rate", context: "track"),
        cloudStatus: try requireWireString(trackObject, "cloud_status", context: "track"),
        isFileTrack: try requireWireBool(trackObject, "is_file_track", context: "track")
    )
}

private func parseWirePlaylist(_ playlist: [String: WireJSON]) throws -> PlaylistSnapshot {
    let tracks = try requireList(playlist["tracks"], "playlist tracks")
    return PlaylistSnapshot(
        name: try requireWireString(playlist, "name", context: "playlist"),
        persistentId: try requireWireString(playlist, "persistent_id", context: "playlist"),
        tracks: try tracks.map(parseWireTrack)
    )
}

/// music_bridge.py:281-292 `_exact_playlist_matches`: exact-name playlists
/// from the read JXA response. Name matching is SCALAR-exact, like Python's
/// `==` over str — an NFD-drifted name is NOT a match.
func exactPlaylistMatches(raw: String, name: String) throws -> [[String: WireJSON]] {
    let payload = try requireMapping(loadWireJSON(raw), "Music snapshot")
    let playlists = try requireList(payload["playlists"], "playlists")
    return playlists.compactMap { item in
        guard case .object(let playlist) = item,
              case .string(let candidate)? = playlist["name"],
              scalarEqual(candidate, name) else {
            return nil
        }
        return playlist
    }
}

/// Parse exactly one requested playlist from a JXA JSON result
/// (music_bridge.py:231-251).
public func parseExactPlaylistSnapshot(raw: String, name: String) throws -> PlaylistSnapshot {
    let matches = try exactPlaylistMatches(raw: raw, name: name)
    guard matches.count == 1 else {
        throw MusicBridgeError("expected exactly one user playlist named \(pythonRepr(name))")
    }
    return try parseWirePlaylist(matches[0])
}

/// Parse every exact-name copy, ordered by ascending numeric playlist ID
/// (music_bridge.py:254-278). The sort is stable, like Python's `sorted`.
public func parseAllCopies(raw: String, name: String) throws -> [PlaylistSnapshot] {
    let matches = try exactPlaylistMatches(raw: raw, name: name)
    guard !matches.isEmpty else {
        throw MusicBridgeError("expected at least one user playlist named \(pythonRepr(name))")
    }
    let keyed = try matches.enumerated().map { entry -> (id: Double, offset: Int, playlist: [String: WireJSON]) in
        let idValue: Double
        switch entry.element["id"] {
        case .integer(let value)?:
            idValue = Double(value)
        case .double(let value)?:
            idValue = value
        default:
            throw MusicBridgeError("playlist id must be a number")
        }
        return (idValue, entry.offset, entry.element)
    }
    let ordered = keyed.sorted { lhs, rhs in
        lhs.id != rhs.id ? lhs.id < rhs.id : lhs.offset < rhs.offset
    }
    return try ordered.map { try parseWirePlaylist($0.playlist) }
}

/// The PID-set counterpart to `exactPlaylistMatches` (2026-08-06 free-form
/// design, Swift-native — no Python counterpart): playlists from
/// `buildReadByPersistentIdsJXA`'s response whose persistent ID
/// scalar-exact-matches ANY of `persistentIds` — an NFD-drifted or
/// otherwise canonically-equivalent-but-scalar-different ID is NOT a match,
/// exactly as `exactPlaylistMatches`' name comparison is scalar-exact.
func exactPersistentIdMatches(
    raw: String, persistentIds: [String]
) throws -> [[String: WireJSON]] {
    let payload = try requireMapping(loadWireJSON(raw), "Music snapshot")
    let playlists = try requireList(payload["playlists"], "playlists")
    return playlists.compactMap { item in
        guard case .object(let playlist) = item,
            case .string(let candidate)? = playlist["persistent_id"],
            persistentIds.contains(where: { scalarEqual($0, candidate) })
        else {
            return nil
        }
        return playlist
    }
}

/// Parse every live playlist matching one of the pinned persistent IDs from
/// a `buildReadByPersistentIdsJXA` result (2026-08-06 free-form design,
/// Swift-native — no Python counterpart). Wire order only; the caller
/// (`ensureFreeFormCopiesMatch`) re-orders to plan order and rejects
/// missing/duplicate PIDs itself, mirroring `parseAllCopies`'s division of
/// labor with `ensureAllCopiesMatch`.
public func parseCopiesByPersistentIds(
    raw: String, persistentIds: [String]
) throws -> [PlaylistSnapshot] {
    try exactPersistentIdMatches(raw: raw, persistentIds: persistentIds).map(parseWirePlaylist)
}

// MARK: - playlist listing parse (M8; no reference counterpart)

/// Parse the playlist-enumeration wire payload (the static
/// `buildListPlaylistsJXA` script's output) through the SAME strict wire
/// gate as every other read: StrictJSONScanner pre-pass + scalar-preserving
/// WireJSON decode, then fail-closed typed extraction. Duplicate NAMES are
/// legal — surfacing them is the point of the listing — but duplicate
/// persistent IDs (scalar-exact) are rejected: they would make group copies
/// indistinguishable. Entries are returned ordered by ascending numeric
/// playlist id with a stable wire-order tie-break, mirroring
/// `parseAllCopies`.
public func parsePlaylistListing(raw: String) throws -> [PlaylistListing] {
    let payload = try requireMapping(loadWireJSON(raw), "Music playlist listing")
    let entries = try requireList(payload["playlists"], "playlists")

    var keyed: [(id: Double, offset: Int, listing: PlaylistListing)] = []
    for (offset, entry) in entries.enumerated() {
        guard case .object(let object) = entry else {
            throw MusicBridgeError("playlist listing entry must be a JSON object")
        }
        let idValue: Double
        switch object["id"] {
        case .integer(let value)?:
            idValue = Double(value)
        case .double(let value)?:
            idValue = value
        default:
            throw MusicBridgeError("playlist id must be a number")
        }
        let trackCount = try requireWireInt(object, "track_count", context: "playlist")
        guard trackCount >= 0 else {
            throw MusicBridgeError("playlist track_count must be a non-negative integer")
        }
        let listing = PlaylistListing(
            playlistId: idValue,
            name: try requireWireString(object, "name", context: "playlist"),
            persistentId: try requireWireString(object, "persistent_id", context: "playlist"),
            trackCount: trackCount,
            isSmart: try requireWireBool(object, "smart", context: "playlist"),
            specialKind: try requireWireString(object, "special_kind", context: "playlist")
        )
        keyed.append((idValue, offset, listing))
    }

    for (index, entry) in keyed.enumerated() {
        if keyed[..<index].contains(where: {
            scalarEqual($0.listing.persistentId, entry.listing.persistentId)
        }) {
            throw MusicBridgeError("playlist listing contains a duplicate persistent ID")
        }
    }

    return keyed
        .sorted { lhs, rhs in
            lhs.id != rhs.id ? lhs.id < rhs.id : lhs.offset < rhs.offset
        }
        .map(\.listing)
}

// MARK: - readback comparison (music_bridge.py:634-693, 696-705, 708-823)

/// music_bridge.py:634-693 `_source_mismatches`: field-by-field comparison of
/// a source snapshot against its post-write readback. Text fields are
/// scalar-exact; messages render values with Python `repr` semantics.
func sourceMismatches(expected: PlaylistSnapshot, actual: PlaylistSnapshot) -> [String] {
    var mismatches: [String] = []
    if !scalarEqual(actual.name, expected.name) {
        mismatches.append(
            "source name mismatch after write: planned \(pythonRepr(expected.name)), "
                + "actual \(pythonRepr(actual.name))"
        )
    }
    if !scalarEqual(actual.persistentId, expected.persistentId) {
        mismatches.append(
            "source playlist persistent ID mismatch after write: "
                + "planned \(pythonRepr(expected.persistentId)), "
                + "actual \(pythonRepr(actual.persistentId))"
        )
    }
    if actual.tracks.count != expected.tracks.count {
        mismatches.append(
            "source track count mismatch after write: "
                + "planned \(expected.tracks.count), actual \(actual.tracks.count)"
        )
    }

    for (offset, pair) in zip(expected.tracks, actual.tracks).enumerated() {
        let position = offset + 1
        let (planned, readback) = pair
        if readback.sourceIndex != planned.sourceIndex {
            mismatches.append(
                "source track order mismatch at position \(position): "
                    + "planned source index \(planned.sourceIndex), "
                    + "actual \(readback.sourceIndex)"
            )
        }
        func field(_ label: String, _ plannedValue: String, _ actualValue: String) {
            mismatches.append(
                "source track \(position) \(label) mismatch after write: "
                    + "planned \(plannedValue), actual \(actualValue)"
            )
        }
        if readback.databaseId != planned.databaseId {
            field("database ID", String(planned.databaseId), String(readback.databaseId))
        }
        if !scalarEqual(readback.persistentId, planned.persistentId) {
            field("persistent ID", pythonRepr(planned.persistentId), pythonRepr(readback.persistentId))
        }
        if !scalarEqual(readback.title, planned.title) {
            field("title", pythonRepr(planned.title), pythonRepr(readback.title))
        }
        if !scalarEqual(readback.artist, planned.artist) {
            field("artist", pythonRepr(planned.artist), pythonRepr(readback.artist))
        }
        if !scalarEqual(readback.album, planned.album) {
            field("album", pythonRepr(planned.album), pythonRepr(readback.album))
        }
        if readback.durationMs != planned.durationMs {
            field("duration", pythonRepr(planned.durationMs), pythonRepr(readback.durationMs))
        }
        if !scalarEqual(readback.kind, planned.kind) {
            field("kind", pythonRepr(planned.kind), pythonRepr(readback.kind))
        }
        if readback.bitRateKbps != planned.bitRateKbps {
            field("bit rate", pythonRepr(planned.bitRateKbps), pythonRepr(readback.bitRateKbps))
        }
        if readback.sampleRateHz != planned.sampleRateHz {
            field("sample rate", pythonRepr(planned.sampleRateHz), pythonRepr(readback.sampleRateHz))
        }
        if !scalarEqual(readback.cloudStatus, planned.cloudStatus) {
            field("cloud status", pythonRepr(planned.cloudStatus), pythonRepr(readback.cloudStatus))
        }
        if readback.isFileTrack != planned.isFileTrack {
            field("file-track status", pythonRepr(planned.isFileTrack), pythonRepr(readback.isFileTrack))
        }
    }

    if !scalarEqual(actual.tracks, expected.tracks) {
        mismatches.append(
            "source fingerprint mismatch after write: "
                + "planned \(sourceFingerprint(expected.tracks)), "
                + "actual \(sourceFingerprint(actual.tracks))"
        )
    }
    return mismatches
}

/// music_bridge.py:804-823 `_copies_mismatches`.
func copiesMismatches(
    expectedCopies: [PlaylistSnapshot],
    actualCopies: [PlaylistSnapshot]
) -> [String] {
    var mismatches: [String] = []
    if actualCopies.count != expectedCopies.count {
        mismatches.append(
            "source copy count mismatch after write: "
                + "planned \(expectedCopies.count), actual \(actualCopies.count)"
        )
    }
    for expected in expectedCopies {
        // Python builds a dict keyed by persistent ID (last occurrence wins)
        // and looks each expected copy up scalar-exactly.
        guard let actual = actualCopies.last(
            where: { scalarEqual($0.persistentId, expected.persistentId) }
        ) else {
            mismatches.append(
                "source copy \(pythonRepr(expected.persistentId)) missing after write"
            )
            continue
        }
        mismatches.append(contentsOf: sourceMismatches(expected: expected, actual: actual))
    }
    return mismatches
}

/// music_bridge.py:696-705 `_planned_tracks`.
func plannedTracks(plan: ConsolidationPlan, source: PlaylistSnapshot) throws -> [TrackSnapshot] {
    var tracksBySourceIndex: [Int: TrackSnapshot] = [:]
    for track in source.tracks {
        tracksBySourceIndex[track.sourceIndex] = track
    }
    return try plan.winnerSourceIndexes.map { index in
        guard let track = tracksBySourceIndex[index] else {
            throw MusicBridgeError("winner source index \(index) is absent from verified source")
        }
        return track
    }
}

/// The ordered database-ID + persistent-ID comparison both verifiers share
/// (identical bodies in music_bridge.py:716-752 and :768-794).
private func targetTrackMismatches(
    expected: [TrackSnapshot],
    actual: [TrackSnapshot]
) -> [String] {
    var mismatches: [String] = []
    if actual.count != expected.count {
        mismatches.append(
            "track count mismatch: planned \(expected.count), actual \(actual.count)"
        )
    }
    for (offset, pair) in zip(expected, actual).enumerated() {
        let position = offset + 1
        let (planned, readback) = pair
        if readback.databaseId != planned.databaseId {
            mismatches.append(
                "track \(position) database ID mismatch: "
                    + "planned \(planned.databaseId), actual \(readback.databaseId)"
            )
        }
        if !scalarEqual(readback.persistentId, planned.persistentId) {
            mismatches.append(
                "track \(position) persistent ID mismatch: "
                    + "planned \(pythonRepr(planned.persistentId)), "
                    + "actual \(pythonRepr(readback.persistentId))"
            )
        }
    }
    if actual.count < expected.count {
        for (offset, planned) in expected[actual.count...].enumerated() {
            let position = actual.count + 1 + offset
            mismatches.append(
                "track \(position) missing: planned database ID \(planned.databaseId), "
                    + "persistent ID \(pythonRepr(planned.persistentId))"
            )
        }
    } else if actual.count > expected.count {
        for (offset, readback) in actual[expected.count...].enumerated() {
            let position = expected.count + 1 + offset
            mismatches.append(
                "track \(position) unexpected: actual database ID \(readback.databaseId), "
                    + "persistent ID \(pythonRepr(readback.persistentId))"
            )
        }
    }
    return mismatches
}

/// Compare the created playlist to the audited winners without modifying
/// Music (music_bridge.py:708-760 `verify_output`).
public func verifyOutput(
    plan: ConsolidationPlan,
    source: PlaylistSnapshot,
    actual: PlaylistSnapshot
) throws -> ApplyResult {
    let expected = try plannedTracks(plan: plan, source: source)
    let mismatches = targetTrackMismatches(expected: expected, actual: actual.tracks)
    return ApplyResult(
        sourceFingerprint: plan.sourceFingerprint,
        plannedCount: expected.count,
        actualCount: actual.tracks.count,
        verificationOk: mismatches.isEmpty,
        mismatches: mismatches
    )
}

/// Compare the merged target to the audited winners without changing Music
/// (music_bridge.py:763-801 `verify_merge_output`). The reference indexes the
/// combined list directly; the port guards the bounds fail-closed.
public func verifyMergeOutput(plan: MergePlan, actual: PlaylistSnapshot) throws -> ApplyResult {
    let combined = plan.combinedTracks
    let expected = try plan.winnerSourceIndexes.map { index -> TrackSnapshot in
        guard combined.indices.contains(index) else {
            throw MusicBridgeError("winner source index \(index) is absent from combined tracks")
        }
        return combined[index]
    }
    let mismatches = targetTrackMismatches(expected: expected, actual: actual.tracks)
    return ApplyResult(
        sourceFingerprint: plan.mergeFingerprint,
        plannedCount: expected.count,
        actualCount: actual.tracks.count,
        verificationOk: mismatches.isEmpty,
        mismatches: mismatches
    )
}

// MARK: - apply progress seam (M9; no reference counterpart)

/// The guarded apply's internal stage boundaries, in dispatch order. Emitted
/// through `MusicBridgeSession.applyProgress` PURELY as progress reporting:
/// the seam is ADDITIVE — no orchestration decision reads it, and a nil
/// callback leaves behavior byte-identical (pinned by
/// ApplyProgressSeamTests). `verifyingReadback` covers both the post-write
/// verification and the read-only inspection after a writer failure — both
/// are readbacks and neither ever mutates Music.
public enum ApplyPhase: String, Equatable, Sendable, CaseIterable {
    case rereadingSources
    case revalidating
    case assertingTargetAbsent
    case compilingWriter
    case executingGuardedWrite
    case verifyingReadback
}

// MARK: - the bridge (music_bridge.py:295-596)

/// Read snapshots and dispatch the guarded writers through an injected
/// command boundary. Every method that touches Music goes through `runner`;
/// tests substitute fakes (the reference's own test mechanics).
///
/// Ports the reference's `MusicBridge` class. Named `MusicBridgeSession` (not
/// `MusicBridge`) so it does not shadow the module name — a same-named type
/// would swallow every module-qualified reference (`MusicBridge.X`) in
/// importing targets (post-final-review fix M5-5).
public class MusicBridgeSession {
    private let runner: ScriptRunner

    /// Optional apply-progress callback (M9). Invoked synchronously on the
    /// calling thread at the existing internal stage boundaries of
    /// applyPlan/applyMergePlan. nil (the default) is byte-identical to the
    /// pre-seam behavior; the orchestration never branches on it.
    public var applyProgress: ((ApplyPhase) -> Void)?

    public init(runner: ScriptRunner) {
        self.runner = runner
    }

    /// Read one exact-name user playlist without changing Music
    /// (music_bridge.py:301-304).
    public func snapshotPlaylist(name: String) throws -> PlaylistSnapshot {
        let raw = try runner.run(.readJXA(script: buildReadJXA(name: name)))
        return try parseExactPlaylistSnapshot(raw: raw, name: name)
    }

    /// Read every exact-name user playlist without changing Music
    /// (music_bridge.py:306-309).
    public func snapshotAllCopies(name: String) throws -> [PlaylistSnapshot] {
        let raw = try runner.run(.readJXA(script: buildReadJXA(name: name)))
        return try parseAllCopies(raw: raw, name: name)
    }

    /// Enumerate every user playlist (identity + counts only, no tracks)
    /// without changing Music — the M8 source browser's listing read. The
    /// dispatched script is the STATIC `buildListPlaylistsJXA` text.
    public func listPlaylists() throws -> [PlaylistListing] {
        let raw = try runner.run(.readJXA(script: buildListPlaylistsJXA()))
        return try parsePlaylistListing(raw: raw)
    }

    /// Read every live playlist pinned by persistent ID for a free-form
    /// merge, without changing Music (2026-08-06 free-form design,
    /// Swift-native — no Python counterpart): the PID-pinned sibling of
    /// `snapshotAllCopies(name:)`, needed because free-form copies are not
    /// required to share a name.
    public func snapshotCopiesByPersistentIds(_ persistentIds: [String]) throws -> [PlaylistSnapshot] {
        let raw = try runner.run(.readJXA(script: buildReadByPersistentIdsJXA(persistentIds: persistentIds)))
        return try parseCopiesByPersistentIds(raw: raw, persistentIds: persistentIds)
    }

    /// Reject any drift in the live same-name copy set before a merge write
    /// (music_bridge.py:311-343). Copies are matched by persistent ID only,
    /// scalar-exactly; the returned copies are in plan order.
    public func ensureAllCopiesMatch(plan: MergePlan) throws -> [PlaylistSnapshot] {
        guard !plan.isFreeForm else {
            throw MusicBridgeError(
                "ensureAllCopiesMatch requires a same-name merge plan; use ensureFreeFormCopiesMatch"
            )
        }
        applyProgress?(.rereadingSources)
        let live = try snapshotAllCopies(name: plan.mergedPlaylistSourceName)
        applyProgress?(.revalidating)
        if live.count != plan.copies.count {
            throw MusicBridgeError(
                "live copy count changed after audit: "
                    + "planned \(plan.copies.count), actual \(live.count); create a fresh audit"
            )
        }
        for (index, copy) in live.enumerated() {
            if live[..<index].contains(where: { scalarEqual($0.persistentId, copy.persistentId) }) {
                throw MusicBridgeError("live copies contain a duplicate persistent ID")
            }
        }

        var ordered: [PlaylistSnapshot] = []
        for expected in plan.copies {
            guard let actual = live.first(
                where: { scalarEqual($0.persistentId, expected.persistentId) }
            ) else {
                throw MusicBridgeError(
                    "expected copy \(pythonRepr(expected.persistentId)) is absent; "
                        + "create a fresh audit"
                )
            }
            try validateCloudStatusNames(actual.tracks)
            let mismatches = sourceMismatches(expected: expected, actual: actual)
            if let first = mismatches.first {
                throw MusicBridgeError(
                    "copy \(pythonRepr(expected.persistentId)) changed after audit: "
                        + "\(first); create a fresh audit"
                )
            }
            ordered.append(actual)
        }
        return ordered
    }

    /// The PID-pinned sibling of `ensureAllCopiesMatch` for a free-form
    /// merge (2026-08-06 free-form design, Swift-native — no Python
    /// counterpart): re-reads each pinned persistent ID's live snapshot
    /// through `snapshotCopiesByPersistentIds` instead of "every copy of
    /// this name", and refuses missing/renamed/drifted with the SAME
    /// full-snapshot comparison (`sourceMismatches`, which already checks
    /// name first — so a live rename of a pinned copy is caught here with
    /// no special-casing, exactly like the extra fail-closed surfaces
    /// `ensureAllCopiesMatch` already covers). The returned copies are in
    /// plan order.
    public func ensureFreeFormCopiesMatch(plan: MergePlan) throws -> [PlaylistSnapshot] {
        // 2026-08-06 review finding m1: assert the all-or-none invariant at
        // this seam explicitly, in the house fail-closed style, rather than
        // trusting `sourcePersistentIDs` alone and silently force-unwrapping
        // `targetDescription`/`sourceNames` elsewhere later.
        guard plan.freeFormFieldsAreConsistent else {
            throw MusicBridgeError(
                "merge plan mixes free-form and same-name fields; refusing"
            )
        }
        guard let expectedPersistentIds = plan.sourcePersistentIDs else {
            throw MusicBridgeError(
                "ensureFreeFormCopiesMatch requires a free-form merge plan; use ensureAllCopiesMatch"
            )
        }
        applyProgress?(.rereadingSources)
        let live = try snapshotCopiesByPersistentIds(expectedPersistentIds)
        applyProgress?(.revalidating)
        if live.count != plan.copies.count {
            throw MusicBridgeError(
                "live copy count changed after audit: "
                    + "planned \(plan.copies.count), actual \(live.count); create a fresh audit"
            )
        }
        for (index, copy) in live.enumerated() {
            if live[..<index].contains(where: { scalarEqual($0.persistentId, copy.persistentId) }) {
                throw MusicBridgeError("live copies contain a duplicate persistent ID")
            }
        }

        var ordered: [PlaylistSnapshot] = []
        for expected in plan.copies {
            guard let actual = live.first(
                where: { scalarEqual($0.persistentId, expected.persistentId) }
            ) else {
                throw MusicBridgeError(
                    "expected copy \(pythonRepr(expected.persistentId)) is absent; "
                        + "create a fresh audit"
                )
            }
            try validateCloudStatusNames(actual.tracks)
            let mismatches = sourceMismatches(expected: expected, actual: actual)
            if let first = mismatches.first {
                throw MusicBridgeError(
                    "copy \(pythonRepr(expected.persistentId)) changed after audit: "
                        + "\(first); create a fresh audit"
                )
            }
            ordered.append(actual)
        }
        return ordered
    }

    /// Reject a source whose tracks changed after the audit
    /// (music_bridge.py:345-355). Reuses the M4 fail-closed validator; only
    /// its errors are wrapped, snapshot errors propagate raw, as in the
    /// reference's `except ValueError` around `_validate_verified_source`.
    public func ensureSourceMatches(plan: ConsolidationPlan) throws -> PlaylistSnapshot {
        applyProgress?(.rereadingSources)
        let source = try snapshotPlaylist(name: plan.sourcePlaylistName)
        applyProgress?(.revalidating)
        do {
            try validateVerifiedSource(plan: plan, verifiedSource: source)
        } catch {
            throw MusicBridgeError(
                "source playlist changed after audit or plan is non-canonical; "
                    + "\(String(describing: error)); create a fresh audit"
            )
        }
        return source
    }

    /// Refuse to create a target whose exact name is already in Music
    /// (music_bridge.py:357-361). Name matching is scalar-exact — a
    /// canonically-equivalent-but-different name is NOT a collision.
    public func assertTargetAbsent(targetName: String) throws {
        applyProgress?(.assertingTargetAbsent)
        let raw = try runner.run(.readJXA(script: buildReadJXA(name: targetName)))
        if try !exactPlaylistMatches(raw: raw, name: targetName).isEmpty {
            throw MusicBridgeError("target user playlist already exists")
        }
    }

    /// Read zero or one exact-name playlist, rejecting ambiguity
    /// (music_bridge.py:363-380).
    public func snapshotPlaylistIfPresent(name: String) throws -> PlaylistSnapshot? {
        let raw = try runner.run(.readJXA(script: buildReadJXA(name: name)))
        let matches = try exactPlaylistMatches(raw: raw, name: name)
        if matches.isEmpty {
            return nil
        }
        guard matches.count == 1 else {
            throw MusicBridgeError("expected at most one user playlist named \(pythonRepr(name))")
        }
        return try parseWirePlaylist(matches[0])
    }

    /// Perform the one guarded create-and-duplicate operation
    /// (music_bridge.py:382-398): build, compile into a temporary artifact,
    /// then execute the exact compiled artifact — never raw source.
    public func runApplyScript(
        plan: ConsolidationPlan,
        source: PlaylistSnapshot,
        targetName: String
    ) throws {
        let script = try buildApplyScript(
            plan: plan, verifiedSource: source, targetName: targetName
        )
        try compileAndExecute(script: script, artifactName: "writer.scpt")
    }

    /// Preflight, create exactly once, then return exact output verification
    /// (music_bridge.py:400-413). A writer error NEVER flips to success.
    public func applyPlan(plan: ConsolidationPlan, targetName: String) throws -> ApplyResult {
        let source = try ensureSourceMatches(plan: plan)
        try assertTargetAbsent(targetName: targetName)
        do {
            try runApplyScript(plan: plan, source: source, targetName: targetName)
        } catch {
            return try writerFailureResult(
                plan: plan, source: source, targetName: targetName, error: error
            )
        }
        return try verifyAfterWrite(plan: plan, source: source, targetName: targetName)
    }

    /// Perform the one guarded create-and-duplicate merge operation
    /// (music_bridge.py:505-514).
    public func runMergeApplyScript(
        plan: MergePlan,
        verifiedCopies: [PlaylistSnapshot],
        targetName: String
    ) throws {
        let script = try buildMergeApplyScript(
            plan: plan, verifiedCopies: verifiedCopies, targetName: targetName
        )
        try compileAndExecute(script: script, artifactName: "merge-writer.scpt")
    }

    /// Preflight every copy, create exactly once, then verify the merged
    /// output (music_bridge.py:516-525).
    public func applyMergePlan(plan: MergePlan, targetName: String) throws -> ApplyResult {
        let verifiedCopies = try ensureAllCopiesMatch(plan: plan)
        try assertTargetAbsent(targetName: targetName)
        do {
            try runMergeApplyScript(
                plan: plan, verifiedCopies: verifiedCopies, targetName: targetName
            )
        } catch {
            return try mergeWriterFailureResult(
                plan: plan, verifiedCopies: verifiedCopies, targetName: targetName, error: error
            )
        }
        return try verifyMergeAfterWrite(
            plan: plan, verifiedCopies: verifiedCopies, targetName: targetName
        )
    }

    /// The free-form sibling of `applyMergePlan` (2026-08-06 free-form
    /// design, Swift-native — no Python counterpart, no CLI surface): same
    /// preflight-create-verify shape, PID-pinned revalidation
    /// (`ensureFreeFormCopiesMatch`) in place of the same-name path's
    /// "every copy of this name" (`ensureAllCopiesMatch`). Everything after
    /// revalidation — target-absence check, the guarded writer dispatch,
    /// failure/verify readback — is the SAME shared merge-apply machinery
    /// `applyMergePlan` uses; `buildMergeApplyScript` and `verifyMergeOutput`
    /// branch on the plan's variant internally, so this method does not
    /// duplicate them.
    public func applyFreeFormMergePlan(plan: MergePlan, targetName: String) throws -> ApplyResult {
        // 2026-08-06 review finding m1: assert at THIS seam too, before
        // delegating — `ensureFreeFormCopiesMatch` re-asserts it on its own,
        // but a top-level entry point should not rely on a callee's guard
        // to keep its own contract honest.
        guard plan.freeFormFieldsAreConsistent else {
            throw MusicBridgeError(
                "merge plan mixes free-form and same-name fields; refusing"
            )
        }
        // 2026-08-06 Task 2 review finding F2: a free-form target name is NOT
        // caller-chosen. The PLAN computed it (`mergedPlaylistSourceName` =
        // `buildFreeFormMergePlan`'s `targetName`), the writer sets exactly
        // it, the description records the merge under it, and the readback
        // verifies it — so a caller-supplied name that disagrees would create
        // a playlist under a name no reviewed artifact mentions. Assert the
        // agreement here rather than trusting the caller; scalar-exact, like
        // every other name gate in this file (Swift `==` would accept
        // canonically-equivalent drift). Gated on `isFreeForm` so a same-name
        // plan still falls through to `ensureFreeFormCopiesMatch`'s existing
        // variant refusal, and the same-name path is untouched.
        if plan.isFreeForm, !scalarEqual(targetName, plan.mergedPlaylistSourceName) {
            throw MusicBridgeError(
                "free-form target name does not match the plan's computed target name; refusing"
            )
        }
        let verifiedCopies = try ensureFreeFormCopiesMatch(plan: plan)
        try assertTargetAbsent(targetName: targetName)
        do {
            try runMergeApplyScript(
                plan: plan, verifiedCopies: verifiedCopies, targetName: targetName
            )
        } catch {
            return try mergeWriterFailureResult(
                plan: plan, verifiedCopies: verifiedCopies, targetName: targetName, error: error
            )
        }
        return try verifyMergeAfterWrite(
            plan: plan, verifiedCopies: verifiedCopies, targetName: targetName
        )
    }

    // MARK: private

    /// Compile into a fresh temporary directory and execute the compiled
    /// artifact, mirroring the reference's tempfile.TemporaryDirectory scope
    /// (prefix "apple-music-consolidator-"); the directory is removed even
    /// when a runner call throws.
    private func compileAndExecute(script: String, artifactName: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apple-music-consolidator-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let compiledScript = directory.appendingPathComponent(artifactName)
        applyProgress?(.compilingWriter)
        try runner.run(.compileAppleScript(script: script, outputPath: compiledScript.path))
        applyProgress?(.executingGuardedWrite)
        try runner.run(.executeCompiledScript(path: compiledScript.path))
    }

    /// Inspect, but never change, state left by a failed writer call
    /// (music_bridge.py:415-464). `verificationOk` is unconditionally false.
    private func writerFailureResult(
        plan: ConsolidationPlan,
        source: PlaylistSnapshot,
        targetName: String,
        error: Error
    ) throws -> ApplyResult {
        applyProgress?(.verifyingReadback)
        var mismatches = ["write failed: \(sanitizedException(error))"]

        do {
            let postWriteSource = try snapshotPlaylist(name: plan.sourcePlaylistName)
            mismatches.append(
                contentsOf: sourceMismatches(expected: source, actual: postWriteSource)
            )
        } catch {
            mismatches.append(
                "source readback failed after writer error: \(sanitizedException(error))"
            )
        }

        var actualCount = 0
        var readbackTarget: PlaylistSnapshot?
        var targetReadbackSucceeded = true
        do {
            readbackTarget = try snapshotPlaylistIfPresent(name: targetName)
        } catch {
            targetReadbackSucceeded = false
            mismatches.append("target readback failed: \(sanitizedException(error))")
        }
        if targetReadbackSucceeded {
            if let actual = readbackTarget {
                let targetResult = try verifyOutput(plan: plan, source: source, actual: actual)
                actualCount = targetResult.actualCount
                mismatches.append(contentsOf: targetResult.mismatches)
                if targetResult.mismatches.isEmpty {
                    mismatches.append(
                        "target readback matches the complete plan despite writer failure"
                    )
                }
            } else {
                mismatches.append("target readback confirmed no exact-name target exists")
            }
        }

        return ApplyResult(
            sourceFingerprint: plan.sourceFingerprint,
            plannedCount: plan.winnerSourceIndexes.count,
            actualCount: actualCount,
            verificationOk: false,
            mismatches: mismatches
        )
    }

    /// Verify both the unchanged source and the exact target readback
    /// (music_bridge.py:466-503).
    private func verifyAfterWrite(
        plan: ConsolidationPlan,
        source: PlaylistSnapshot,
        targetName: String
    ) throws -> ApplyResult {
        applyProgress?(.verifyingReadback)
        var mismatches: [String] = []
        do {
            let postWriteSource = try snapshotPlaylist(name: plan.sourcePlaylistName)
            mismatches.append(
                contentsOf: sourceMismatches(expected: source, actual: postWriteSource)
            )
        } catch {
            mismatches.append("source readback failed after write: \(sanitizedException(error))")
        }

        var actualCount = 0
        var readbackTarget: PlaylistSnapshot?
        do {
            readbackTarget = try snapshotPlaylist(name: targetName)
        } catch {
            mismatches.append("target readback failed after write: \(sanitizedException(error))")
        }
        if let actual = readbackTarget {
            let targetResult = try verifyOutput(plan: plan, source: source, actual: actual)
            actualCount = targetResult.actualCount
            mismatches.append(contentsOf: targetResult.mismatches)
        }

        return ApplyResult(
            sourceFingerprint: plan.sourceFingerprint,
            plannedCount: plan.winnerSourceIndexes.count,
            actualCount: actualCount,
            verificationOk: mismatches.isEmpty,
            mismatches: mismatches
        )
    }

    /// Re-read the merge's source copies post-write, routed by plan variant
    /// (2026-08-06 free-form design): a same-name plan's copies share a
    /// name to re-read "every copy of"; a free-form plan's do not — for
    /// that variant `plan.mergedPlaylistSourceName` is the TARGET name, not
    /// a source name, so re-reading by it here would read the wrong thing
    /// (or the target itself). Shared by `verifyMergeAfterWrite` and
    /// `mergeWriterFailureResult`, the two callers that used to call
    /// `snapshotAllCopies(name: plan.mergedPlaylistSourceName)` directly.
    private func rereadMergeCopies(for plan: MergePlan) throws -> [PlaylistSnapshot] {
        if let expectedPersistentIds = plan.sourcePersistentIDs {
            return try snapshotCopiesByPersistentIds(expectedPersistentIds)
        }
        return try snapshotAllCopies(name: plan.mergedPlaylistSourceName)
    }

    /// Verify both the unchanged source copies and the exact target readback
    /// (music_bridge.py:527-557).
    private func verifyMergeAfterWrite(
        plan: MergePlan,
        verifiedCopies: [PlaylistSnapshot],
        targetName: String
    ) throws -> ApplyResult {
        applyProgress?(.verifyingReadback)
        var mismatches: [String] = []
        do {
            let postCopies = try rereadMergeCopies(for: plan)
            mismatches.append(
                contentsOf: copiesMismatches(expectedCopies: verifiedCopies, actualCopies: postCopies)
            )
        } catch {
            mismatches.append(
                "source copies readback failed after write: \(sanitizedException(error))"
            )
        }

        var actualCount = 0
        var readbackTarget: PlaylistSnapshot?
        do {
            readbackTarget = try snapshotPlaylist(name: targetName)
        } catch {
            mismatches.append("target readback failed after write: \(sanitizedException(error))")
        }
        if let actual = readbackTarget {
            let targetResult = try verifyMergeOutput(plan: plan, actual: actual)
            actualCount = targetResult.actualCount
            mismatches.append(contentsOf: targetResult.mismatches)
        }

        return ApplyResult(
            sourceFingerprint: plan.mergeFingerprint,
            plannedCount: plan.winnerSourceIndexes.count,
            actualCount: actualCount,
            verificationOk: mismatches.isEmpty,
            mismatches: mismatches
        )
    }

    /// Inspect, but never change, state left by a failed merge writer call
    /// (music_bridge.py:559-596).
    private func mergeWriterFailureResult(
        plan: MergePlan,
        verifiedCopies: [PlaylistSnapshot],
        targetName: String,
        error: Error
    ) throws -> ApplyResult {
        applyProgress?(.verifyingReadback)
        var mismatches = ["write failed: \(sanitizedException(error))"]

        do {
            let postCopies = try rereadMergeCopies(for: plan)
            mismatches.append(
                contentsOf: copiesMismatches(expectedCopies: verifiedCopies, actualCopies: postCopies)
            )
        } catch {
            mismatches.append(
                "source copies readback failed after writer error: \(sanitizedException(error))"
            )
        }

        var actualCount = 0
        var readbackTarget: PlaylistSnapshot?
        var targetReadbackSucceeded = true
        do {
            readbackTarget = try snapshotPlaylistIfPresent(name: targetName)
        } catch {
            targetReadbackSucceeded = false
            mismatches.append("target readback failed: \(sanitizedException(error))")
        }
        if targetReadbackSucceeded {
            if let actual = readbackTarget {
                let targetResult = try verifyMergeOutput(plan: plan, actual: actual)
                actualCount = targetResult.actualCount
                mismatches.append(contentsOf: targetResult.mismatches)
                if targetResult.mismatches.isEmpty {
                    mismatches.append(
                        "target readback matches the complete plan despite writer failure"
                    )
                }
            } else {
                mismatches.append("target readback confirmed no exact-name target exists")
            }
        }

        return ApplyResult(
            sourceFingerprint: plan.mergeFingerprint,
            plannedCount: plan.winnerSourceIndexes.count,
            actualCount: actualCount,
            verificationOk: false,
            mismatches: mismatches
        )
    }
}

// MARK: - guarded mutation orchestration (Wave B, spec B1)

/// The guarded mutation's internal stage boundaries, in dispatch order.
/// Reported through `performMutation`'s progress parameter exactly the way
/// `ApplyPhase` rides `applyProgress` (M9): synchronously on the calling
/// thread, purely additive — no orchestration decision ever reads it.
public enum MutationPhase: String, Equatable, Sendable, CaseIterable {
    case reValidating      // fresh listing + fingerprint recheck
    case compiling
    case executing
    case verifyingListing  // fresh listing + bijective diff
}

/// The outcome of one guarded mutation. `verified` is true ONLY when a clean
/// execution was followed by a bijective listing diff with zero mismatches;
/// a writer failure or any diff mismatch NEVER flips to success.
public struct MutationOutcome: Equatable, Sendable {
    public let verified: Bool
    public let mismatches: [String]
    public let informational: [String]

    public init(verified: Bool, mismatches: [String], informational: [String]) {
        self.verified = verified
        self.mismatches = mismatches
        self.informational = informational
    }
}

extension MusicBridgeSession {
    /// Fail-closed orchestration for ONE mutation: (1) fresh listing whose
    /// fingerprint must equal `listingFingerprint(of: baseline)` — for a
    /// single mutation the gate passes the listing it fingerprinted into the
    /// plan; for cleanup copy k>1 it passes the post-copy-(k-1) listing —
    /// (2) build + compile the writer, (3) execute the exact compiled
    /// artifact, (4) fresh listing + `listingMutationDiff` against the
    /// baseline. Never repair, never retry.
    public func performMutation(
        plan: MutationPlan,
        baseline: [PlaylistListing],
        targetGuard: MutationScriptBuilder.TargetGuardPayload?,
        progress: ((MutationPhase) -> Void)?
    ) throws -> MutationOutcome {
        progress?(.reValidating)
        let fresh = try listPlaylists()
        let baselineFingerprint = listingFingerprint(of: baseline)
        let freshFingerprint = listingFingerprint(of: fresh)
        guard scalarEqual(freshFingerprint, baselineFingerprint) else {
            throw MusicBridgeError(
                "live playlist listing changed before mutation: baseline fingerprint "
                    + "\(baselineFingerprint), fresh fingerprint \(freshFingerprint); "
                    + "create a fresh mutation audit"
            )
        }

        let script: String
        let expectation: MutationExpectation
        switch plan.kind {
        case .delete:
            script = MutationScriptBuilder.buildDeleteScript(
                expectedName: plan.playlistName,
                expectedPersistentID: plan.playlistPersistentID,
                expectedTrackPersistentIDs: plan.orderedTrackPersistentIDs,
                targetGuard: targetGuard
            )
            expectation = .deleted(persistentID: plan.playlistPersistentID)
        case .rename:
            guard targetGuard == nil else {
                throw MusicBridgeError(
                    "a rename mutation accepts no target guard; refusing rather than "
                        + "silently ignoring it"
                )
            }
            guard let newName = plan.newName else {
                throw MusicBridgeError("rename mutation plan is missing its new name")
            }
            script = MutationScriptBuilder.buildRenameScript(
                expectedName: plan.playlistName,
                expectedPersistentID: plan.playlistPersistentID,
                expectedTrackPersistentIDs: plan.orderedTrackPersistentIDs,
                newName: newName
            )
            expectation = .renamed(
                persistentID: plan.playlistPersistentID,
                newName: newName
            )
        }

        // Compile into a fresh temporary directory and execute the exact
        // compiled artifact — the same shape as the private
        // `compileAndExecute` (lines 806-818), duplicated here rather than
        // reused because that path emits ApplyPhase events on the
        // applyProgress seam and a mutation must never masquerade as an
        // apply on any progress surface.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apple-music-consolidator-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifactName = plan.kind == .delete ? "delete-writer.scpt" : "rename-writer.scpt"
        let compiledScript = directory.appendingPathComponent(artifactName)
        progress?(.compiling)
        do {
            try runner.run(.compileAppleScript(script: script, outputPath: compiledScript.path))
            progress?(.executing)
            try runner.run(.executeCompiledScript(path: compiledScript.path))
        } catch {
            return mutationWriterFailureOutcome(
                baseline: baseline,
                expectation: expectation,
                error: error,
                progress: progress
            )
        }

        progress?(.verifyingListing)
        do {
            let after = try listPlaylists()
            let diff = listingMutationDiff(before: baseline, after: after, expectation: expectation)
            return MutationOutcome(
                verified: diff.mismatches.isEmpty,
                mismatches: diff.mismatches,
                informational: diff.informational
            )
        } catch {
            return MutationOutcome(
                verified: false,
                mismatches: ["post-execute verification read failed: \(sanitizedException(error))"],
                informational: []
            )
        }
    }

    /// Inspect, but never change, state left by a failed mutation writer
    /// call — the mutation mirror of `writerFailureResult`
    /// (music_bridge.py:415-464 discipline): `verified` is unconditionally
    /// false, the first mismatch carries the sanitized writer error
    /// verbatim, and the fresh listing is read PURELY for diagnostics.
    private func mutationWriterFailureOutcome(
        baseline: [PlaylistListing],
        expectation: MutationExpectation,
        error: Error,
        progress: ((MutationPhase) -> Void)?
    ) -> MutationOutcome {
        progress?(.verifyingListing)
        var mismatches = ["write failed: \(sanitizedException(error))"]
        var informational: [String] = []
        do {
            let after = try listPlaylists()
            let diff = listingMutationDiff(
                before: baseline, after: after, expectation: expectation
            )
            mismatches.append(contentsOf: diff.mismatches)
            informational.append(contentsOf: diff.informational)
            if diff.mismatches.isEmpty {
                mismatches.append(
                    "listing readback matches the approved mutation despite writer failure"
                )
            }
        } catch {
            mismatches.append(
                "listing readback failed after writer error: \(sanitizedException(error))"
            )
        }
        return MutationOutcome(
            verified: false,
            mismatches: mismatches,
            informational: informational
        )
    }

    /// Direct user-responsible delete (Sergio, 2026-08-06): one compiled
    /// execution, no baseline, no revalidation, no readback. The caller
    /// (the app's confirm dialog) is the only gate.
    public func deletePlaylistDirect(persistentID: String) throws {
        let script = DirectMutationScriptBuilder.buildDirectDeleteScript(
            persistentID: persistentID
        )
        try compileAndExecuteDirect(script: script, artifactName: "direct-delete.scpt")
    }

    /// Direct user-responsible rename (Sergio, 2026-08-06). Duplicate
    /// resulting names are allowed, as in Music.app.
    public func renamePlaylistDirect(persistentID: String, newName: String) throws {
        let script = DirectMutationScriptBuilder.buildDirectRenameScript(
            persistentID: persistentID, newName: newName
        )
        try compileAndExecuteDirect(script: script, artifactName: "direct-rename.scpt")
    }

    private func compileAndExecuteDirect(script: String, artifactName: String) throws {
        // Same compile-into-fresh-temp-dir shape as performMutation, minus
        // progress events, expectations, and readback.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apple-music-consolidator-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let compiledScript = directory.appendingPathComponent(artifactName)
        try runner.run(.compileAppleScript(script: script, outputPath: compiledScript.path))
        try runner.run(.executeCompiledScript(path: compiledScript.path))
    }
}
