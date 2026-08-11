// MusicScriptBuilder.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Swift port of the PURE script-generation half of
// apple_music_consolidator/music_bridge.py (M4). Every template, encoder, and
// fail-closed guard below is a verbatim-in-behavior port; comments carry
// music_bridge.py line references. The impure orchestration (OSAKit runner,
// ensure/apply/verify flows) is M5 and deliberately absent here.
//
// EXCEPTION (bulk-read-speedup, 2026-08-06): `buildListPlaylistsJXA` (M8) has
// no Python counterpart at all, and `buildReadJXA`'s track-reading body was
// deliberately rewritten columnar for this Swift-only native app — its TEXT
// no longer matches `build_read_jxa` byte-for-byte, though the wire JSON
// contract it emits is unchanged. See each builder's doc comment.
//
// Determinism: every builder is a pure function of its inputs — no clocks,
// no randomness — which the golden byte-parity gate relies on (with the
// `buildReadJXA` exception above: still pure/deterministic, just no longer
// pinned against the Python reference).
//
// AppleScript/JXA rules honored (AGENTS.md "AppleScript and JXA
// implementation rules"): absolute Music.app path targeting; every untrusted
// value JSON-escaped; compact delimiter-encoded expected-source payload (no
// per-track guard unrolling); chunked `local` declarations to prevent
// compiled-script save-back; `my` for script handlers inside the tell;
// Unicode code-point text comparison (`id of`); raw «constant eClS…» cloud
// status enums; missing cloud status distinct from the `unknown` enum;
// per-track class checks for file-track status; `contents of` for repeat
// variables; guarded create-and-duplicate as the only write.

import Foundation
import ConsolidatorCore

/// music_bridge.py:14 MUSIC_APP_PATH.
public let musicAppPath = "/System/Applications/Music.app"

/// Thrown where the reference raises ValueError in the pure builder half.
public struct MusicScriptBuilderError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }

    public init(_ message: String) {
        self.message = message
    }
}

// MARK: - json.dumps parity encoder (music_bridge.py:826-827)

/// Python `json.dumps(value, ensure_ascii=False)`: escape `"` `\` and the C0
/// controls (short escapes for backspace, form feed, newline, CR, tab;
/// lowercase four-hex-digit unicode escapes otherwise); every other scalar —
/// including DEL, U+2028/U+2029, PUA, non-BMP — passes through raw.
/// Scalar-wise so no normalization can occur.
func appleScriptString(_ value: String) -> String {
    var encoded = "\""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x22:
            encoded += "\\\""
        case 0x5C:
            encoded += "\\\\"
        case 0x08:
            encoded += "\\" + "b"
        case 0x0C:
            encoded += "\\" + "f"
        case 0x0A:
            encoded += "\\" + "n"
        case 0x0D:
            encoded += "\\" + "r"
        case 0x09:
            encoded += "\\" + "t"
        default:
            if scalar.value < 0x20 {
                encoded += "\\" + "u" + String(format: "%04x", scalar.value)
            } else {
                encoded.unicodeScalars.append(scalar)
            }
        }
    }
    encoded += "\""
    return encoded
}

// MARK: - cloud status enum table (music_bridge.py:17-33)

let cloudStatusEnumCodes: [(name: String, code: String)] = [
    ("unknown", "kUnk"),
    ("purchased", "kPur"),
    ("matched", "kMat"),
    ("uploaded", "kUpl"),
    ("ineligible", "kRej"),
    ("removed", "kRem"),
    ("error", "kErr"),
    ("duplicate", "kDup"),
    ("subscription", "kSub"),
    ("prerelease", "kPrR"),
    ("no longer available", "kRev"),
    ("not uploaded", "kUpP"),
]

// MARK: - writer runtime locals (music_bridge.py:34-91)

let applyScriptLocals: [String] = [
    "sourcePlaylistName",
    "targetPlaylistName",
    "expectedSourcePlaylistPersistentID",
    "expectedSourceTrackCount",
    "expectedSourcePayload",
    "expectedFieldDelimiter",
    "expectedRowDelimiter",
    "selectedSourcePositions",
    "savedTextItemDelimiters",
    "expectedSourceRows",
    "expectedSourceFieldsByPosition",
    "expectedSourceRow",
    "expectedSourceFields",
    "errorMessage",
    "errorNumber",
    "sourcePlaylists",
    "candidatePlaylist",
    "candidateName",
    "sourcePlaylist",
    "liveSourcePlaylistPersistentID",
    "sourceTracks",
    "sourcePosition",
    "sourceIndex",
    "liveSourceTrack",
    "expectedDatabaseID",
    "liveTextValue",
    "expectedTextValue",
    "expectedNumberText",
    "liveDurationSeconds",
    "expectedNumberValue",
    "liveNumberValue",
    "liveCloudStatus",
    "liveTrackClass",
    "liveIsFileTrack",
    "expectedFileTrackText",
    "targetPlaylists",
    "destinationPlaylist",
    "selectedSourcePosition",
    "selectedTrack",
]

let mergeApplyScriptLocals: [String] = [
    "sourcePlaylistName", "targetPlaylistName", "expectedCopyCount",
    "expectedCopyPersistentIDs", "expectedCopyTrackCounts",
    "expectedCombinedTrackCount", "expectedCombinedPayload",
    "expectedFieldDelimiter", "expectedRowDelimiter", "selectedCombinedPositions",
    "savedTextItemDelimiters", "expectedSourceRows", "expectedSourceFieldsByPosition",
    "expectedSourceRow", "expectedSourceFields", "errorMessage", "errorNumber",
    "sourcePlaylists", "candidatePlaylist", "candidateName", "targetPlaylists",
    "copyIndex", "expectedCopyPersistentID", "expectedCopyTrackCount",
    "matchedCopy", "candidateCopy", "candidateCopyPID", "copyTracks",
    "withinPosition", "combinedPosition", "combinedTracks", "sourceIndex",
    "liveSourceTrack", "expectedDatabaseID", "liveTextValue", "expectedTextValue",
    "expectedNumberText", "liveDurationSeconds", "expectedNumberValue",
    "liveNumberValue", "liveCloudStatus", "liveTrackClass", "liveIsFileTrack",
    "expectedFileTrackText", "destinationPlaylist", "selectedCombinedPosition",
    "selectedTrack",
]

/// Free-form merge writer locals (2026-08-06 free-form design, Swift-native
/// — no Python counterpart): `mergeApplyScriptLocals` minus
/// `sourcePlaylistName` (free-form copies do not share one name, so there is
/// no single name to hold) plus the PID-set-scan lookup's own two locals
/// (`candidatePersistentID`, `expectedIdCandidate`), the per-copy source-name
/// check's three (`expectedCopyNames`, `expectedCopyName`,
/// `candidateCopyName` — review finding m2), and the optional description
/// readback's (`liveTargetDescription`, declared unconditionally — an
/// unused `local` is harmless and keeps this list stable regardless of
/// whether a given plan carries a description).
let freeFormMergeApplyScriptLocals: [String] = [
    "targetPlaylistName", "expectedCopyCount",
    "expectedCopyPersistentIDs", "expectedCopyTrackCounts", "expectedCopyNames",
    "expectedCombinedTrackCount", "expectedCombinedPayload",
    "expectedFieldDelimiter", "expectedRowDelimiter", "selectedCombinedPositions",
    "savedTextItemDelimiters", "expectedSourceRows", "expectedSourceFieldsByPosition",
    "expectedSourceRow", "expectedSourceFields", "errorMessage", "errorNumber",
    "sourcePlaylists", "candidatePlaylist", "candidatePersistentID", "expectedIdCandidate",
    "candidateName", "targetPlaylists",
    "copyIndex", "expectedCopyPersistentID", "expectedCopyTrackCount", "expectedCopyName",
    "matchedCopy", "candidateCopy", "candidateCopyPID", "candidateCopyName", "copyTracks",
    "withinPosition", "combinedPosition", "combinedTracks", "sourceIndex",
    "liveSourceTrack", "expectedDatabaseID", "liveTextValue", "expectedTextValue",
    "expectedNumberText", "liveDurationSeconds", "expectedNumberValue",
    "liveNumberValue", "liveCloudStatus", "liveTrackClass", "liveIsFileTrack",
    "expectedFileTrackText", "destinationPlaylist", "selectedCombinedPosition",
    "selectedTrack", "liveTargetDescription",
]

// MARK: - read JXA (music_bridge.py:143-195)

/// Build read-only JXA that serializes every exact-name user playlist.
///
/// The playlist LOOKUP is byte-identical to the pre-columnar script and to
/// the Python reference: `Music.userPlaylists()` is still CALLED (evaluated
/// into a plain Array of per-playlist specifiers) and filtered with a
/// per-playlist `.name()` comparison — this is the exact-name matching
/// discipline pinned across the read/apply/merge surfaces (code-point
/// comparison happens downstream, in `parseWirePlaylist`'s scalar-exact gate)
/// and it is deliberately left untouched here; only the TRACK-reading body
/// inside `matches.map` changed.
///
/// COLUMNAR (2026-08-06, bulk-read-speedup Task 2): for each matched
/// playlist, every track property that used to be one `track.<property>()`
/// call PER TRACK (music_bridge.py's per-track loop; O(tracks) Apple Events
/// per property, ~10 properties per track) is now ONE `get` Apple Event for
/// the WHOLE column, fetched off `playlist.tracks` left UN-CALLED (a
/// chainable specifier collection — calling it, `playlist.tracks()`, would
/// evaluate it into a plain Array with no `.databaseID()`/`.name()`/… column
/// methods, same Task 1 lesson). `.length` on that same un-called specifier
/// is the one property a collection exposes directly and is read FIRST, its
/// own `count` Apple Event, before any column — the count-first read that
/// every column's guard below checks against. File-track database IDs
/// (needed only to derive `is_file_track` in memory) are fetched the same
/// way, off `playlist.fileTracks` left un-called, with their own
/// independent count-first read (a playlist's file-track count need not
/// equal its track count — some tracks are cloud-only). Every column is read
/// off the SAME collection reference (`trackRefs`/`fileTrackRefs`), never a
/// second, freshly re-evaluated specifier, so every column's index lines up
/// with every other column's index by construction. Total Apple Events per
/// MATCHED playlist: 16 — 13 columnar (1 file-track count + 1 file-track
/// column + 1 track count + 10 track columns) PLUS 3 per-object scalar
/// property gets in the return block (`playlist.id()`, `playlist.name()`,
/// `playlist.persistentID()` — one Apple Event each; these are not columnar
/// because there is exactly one playlist object per matched record) —
/// regardless of track count, versus roughly 1 + tracks*11 before (1
/// file-track materializing call plus, per track, 1 materializing
/// `tracks()` call amortized once and 10 per-track property calls). This
/// does NOT count the LOOKUP above it: the unchanged
/// `Music.userPlaylists().filter(...)` calls `.name()` once per playlist in
/// the WHOLE LIBRARY (not just the matches) to find them — roughly one more
/// Apple Event per library playlist, paid once regardless of match count;
/// include it when reasoning about live before/after timing.
///
/// Every column's guard rejects, fail-closed, no retry, no repair, a column
/// that disagrees with its collection's count-first read. The TYPE check
/// (`!Array.isArray(...)`) and the LENGTH check (`.length !== expected...`)
/// are separate `if` statements, each with its own accurate, LITERAL (not
/// concatenated) message: `column type mismatch: <field>` when the column
/// itself came back as something other than an array, and
/// `column length mismatch: <field>` when it IS an array but the wrong
/// length (e.g. `column length mismatch: database_id` — a track added or
/// removed mid-scan skews alignment between the count read and a later
/// column read). Both messages are source-text literals per column, not
/// built via string concatenation, so they stay byte-pinnable. Records are
/// assembled by index afterward in a plain in-memory loop that touches no
/// Music object — only the already-fetched arrays and the file-track ID set
/// — so it sends no further Apple Events. The JSON shape (keys, key order,
/// per-record and per-track field order) is byte-identical to the
/// pre-columnar script.
///
/// DIVERGENCE FROM THE PYTHON REFERENCE (deliberate, expected): unlike every
/// other builder in this file, `buildReadJXA`'s TEXT no longer matches
/// `apple_music_consolidator.music_bridge.build_read_jxa` byte-for-byte — the
/// Python CLI has no columnar mode and does not need one. This is a
/// Swift/native-app-only performance change; the wire JSON contract (what
/// `parseExactPlaylistSnapshot`/`parseAllCopies` consume) is unchanged.
/// `ScriptGoldenTests`'s `read_jxa` byte-parity cases were REMOVED 2026-08-11
/// (Sergio's decision, not forced green) rather than edited to tolerate the
/// divergence — wire-output parity with the reference is instead held by
/// the shared parse fixtures (`parseExactPlaylistSnapshot`/`parseAllCopies`
/// against `tests/fixtures/music_snapshot.json` and the MusicBridge
/// parse/orchestration suites); the writer golden cases (`buildApplyScript`,
/// `buildMergeApplyScript`) keep full byte parity, untouched. See
/// `legacyReadJXAScript` immediately below for the retained pre-columnar
/// text (Diagnostics "Compare readers" cross-check only, Task 3).
public func buildReadJXA(name: String) -> String {
    let encodedAppPath = appleScriptString(musicAppPath)
    let encodedName = appleScriptString(name)
    let lines = [
        "const Music = Application(\(encodedAppPath));",
        "const requestedName = \(encodedName);",
        "",
        "function textOrEmpty(value) {",
        "    return value === null || value === undefined ? \"\" : String(value);",
        "}",
        "",
        "function numberOrNull(value) {",
        "    return value === null || value === undefined || Number.isNaN(value) ? null : value;",
        "}",
        "",
        "const matches = Music.userPlaylists().filter(function (playlist) {",
        "    return playlist.name() === requestedName;",
        "});",
        "",
        "const playlists = matches.map(function (playlist) {",
        "    const fileTrackRefs = playlist.fileTracks;",
        "    const expectedFileTrackCount = fileTrackRefs.length;",
        "",
        "    const fileTrackDatabaseIdColumn = fileTrackRefs.databaseID();",
        "    if (!Array.isArray(fileTrackDatabaseIdColumn)) {",
        "        throw new Error(\"column type mismatch: file_track_database_id\");",
        "    }",
        "    if (fileTrackDatabaseIdColumn.length !== expectedFileTrackCount) {",
        "        throw new Error(\"column length mismatch: file_track_database_id\");",
        "    }",
        "    const fileTrackDatabaseIDs = new Set(fileTrackDatabaseIdColumn);",
        "",
        "    const trackRefs = playlist.tracks;",
        "    const expectedTrackCount = trackRefs.length;",
        "",
        "    const databaseIds = trackRefs.databaseID();",
        "    if (!Array.isArray(databaseIds)) {",
        "        throw new Error(\"column type mismatch: database_id\");",
        "    }",
        "    if (databaseIds.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: database_id\");",
        "    }",
        "",
        "    const persistentIds = trackRefs.persistentID();",
        "    if (!Array.isArray(persistentIds)) {",
        "        throw new Error(\"column type mismatch: persistent_id\");",
        "    }",
        "    if (persistentIds.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: persistent_id\");",
        "    }",
        "",
        "    const titles = trackRefs.name();",
        "    if (!Array.isArray(titles)) {",
        "        throw new Error(\"column type mismatch: title\");",
        "    }",
        "    if (titles.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: title\");",
        "    }",
        "",
        "    const artists = trackRefs.artist();",
        "    if (!Array.isArray(artists)) {",
        "        throw new Error(\"column type mismatch: artist\");",
        "    }",
        "    if (artists.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: artist\");",
        "    }",
        "",
        "    const albums = trackRefs.album();",
        "    if (!Array.isArray(albums)) {",
        "        throw new Error(\"column type mismatch: album\");",
        "    }",
        "    if (albums.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: album\");",
        "    }",
        "",
        "    const durations = trackRefs.duration();",
        "    if (!Array.isArray(durations)) {",
        "        throw new Error(\"column type mismatch: duration\");",
        "    }",
        "    if (durations.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: duration\");",
        "    }",
        "",
        "    const kinds = trackRefs.kind();",
        "    if (!Array.isArray(kinds)) {",
        "        throw new Error(\"column type mismatch: kind\");",
        "    }",
        "    if (kinds.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: kind\");",
        "    }",
        "",
        "    const bitRates = trackRefs.bitRate();",
        "    if (!Array.isArray(bitRates)) {",
        "        throw new Error(\"column type mismatch: bit_rate\");",
        "    }",
        "    if (bitRates.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: bit_rate\");",
        "    }",
        "",
        "    const sampleRates = trackRefs.sampleRate();",
        "    if (!Array.isArray(sampleRates)) {",
        "        throw new Error(\"column type mismatch: sample_rate\");",
        "    }",
        "    if (sampleRates.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: sample_rate\");",
        "    }",
        "",
        "    const cloudStatuses = trackRefs.cloudStatus();",
        "    if (!Array.isArray(cloudStatuses)) {",
        "        throw new Error(\"column type mismatch: cloud_status\");",
        "    }",
        "    if (cloudStatuses.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: cloud_status\");",
        "    }",
        "",
        "    const tracks = [];",
        "    for (let sourceIndex = 0; sourceIndex < expectedTrackCount; sourceIndex++) {",
        "        const databaseID = databaseIds[sourceIndex];",
        "        tracks.push({",
        "            source_index: sourceIndex,",
        "            database_id: databaseID,",
        "            persistent_id: textOrEmpty(persistentIds[sourceIndex]),",
        "            title: textOrEmpty(titles[sourceIndex]),",
        "            artist: textOrEmpty(artists[sourceIndex]),",
        "            album: textOrEmpty(albums[sourceIndex]),",
        "            duration: numberOrNull(durations[sourceIndex]),",
        "            kind: textOrEmpty(kinds[sourceIndex]),",
        "            bit_rate: numberOrNull(bitRates[sourceIndex]),",
        "            sample_rate: numberOrNull(sampleRates[sourceIndex]),",
        "            cloud_status: textOrEmpty(cloudStatuses[sourceIndex]),",
        "            is_file_track: fileTrackDatabaseIDs.has(databaseID)",
        "        });",
        "    }",
        "    return {",
        "        id: playlist.id(),",
        "        name: playlist.name(),",
        "        persistent_id: playlist.persistentID(),",
        "        tracks: tracks",
        "    };",
        "});",
        "",
        "JSON.stringify({playlists: playlists});",
        "",
    ]
    return lines.joined(separator: "\n")
}

/// Build read-only JXA that serializes every live user playlist whose
/// persistent ID is one of `persistentIds` (2026-08-06 free-form design,
/// Swift-native — no Python counterpart, no same-name analogue: a free-form
/// copy set is pinned by persistent ID, not a shared name, so
/// `ensureFreeFormCopiesMatch`'s live re-read needs a filter that does not
/// depend on the copies still sharing a name — a rename is exactly one of
/// the drift conditions it must detect, not something it should follow).
///
/// Otherwise identical to `buildReadJXA`: same absolute-path targeting, same
/// columnar per-matched-playlist track-reading body (byte-for-byte copied,
/// per this file's own established practice for divergent-but-related
/// readers — see `legacyReadJXAScript`'s header), same wire JSON shape
/// (`{playlists: [{id, name, persistent_id, tracks: [...]}]}`) — so the
/// EXISTING wire parser (`parseCopiesByPersistentIds`, itself built on the
/// same strict decode gate as `parseAllCopies`) consumes its output with no
/// new wire contract to review. Only the LOOKUP differs: a `Set` of the
/// requested persistent IDs, tested with JS `===`/`Set.has` (exact code-unit
/// comparison — no Unicode normalization) instead of one name equality;
/// like `buildReadJXA`'s own name filter, this is a coarse selection only —
/// the scalar-exact gate that actually matters is downstream, in
/// `parseWirePlaylist`'s callers.
public func buildReadByPersistentIdsJXA(persistentIds: [String]) -> String {
    let encodedAppPath = appleScriptString(musicAppPath)
    let encodedIds = "[" + persistentIds.map { appleScriptString($0) }.joined(separator: ", ") + "]"
    let lines = [
        "const Music = Application(\(encodedAppPath));",
        "const requestedPersistentIds = \(encodedIds);",
        "const requestedPersistentIdSet = new Set(requestedPersistentIds);",
        "",
        "function textOrEmpty(value) {",
        "    return value === null || value === undefined ? \"\" : String(value);",
        "}",
        "",
        "function numberOrNull(value) {",
        "    return value === null || value === undefined || Number.isNaN(value) ? null : value;",
        "}",
        "",
        "const matches = Music.userPlaylists().filter(function (playlist) {",
        "    return requestedPersistentIdSet.has(playlist.persistentID());",
        "});",
        "",
        "const playlists = matches.map(function (playlist) {",
        "    const fileTrackRefs = playlist.fileTracks;",
        "    const expectedFileTrackCount = fileTrackRefs.length;",
        "",
        "    const fileTrackDatabaseIdColumn = fileTrackRefs.databaseID();",
        "    if (!Array.isArray(fileTrackDatabaseIdColumn)) {",
        "        throw new Error(\"column type mismatch: file_track_database_id\");",
        "    }",
        "    if (fileTrackDatabaseIdColumn.length !== expectedFileTrackCount) {",
        "        throw new Error(\"column length mismatch: file_track_database_id\");",
        "    }",
        "    const fileTrackDatabaseIDs = new Set(fileTrackDatabaseIdColumn);",
        "",
        "    const trackRefs = playlist.tracks;",
        "    const expectedTrackCount = trackRefs.length;",
        "",
        "    const databaseIds = trackRefs.databaseID();",
        "    if (!Array.isArray(databaseIds)) {",
        "        throw new Error(\"column type mismatch: database_id\");",
        "    }",
        "    if (databaseIds.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: database_id\");",
        "    }",
        "",
        "    const persistentIds = trackRefs.persistentID();",
        "    if (!Array.isArray(persistentIds)) {",
        "        throw new Error(\"column type mismatch: persistent_id\");",
        "    }",
        "    if (persistentIds.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: persistent_id\");",
        "    }",
        "",
        "    const titles = trackRefs.name();",
        "    if (!Array.isArray(titles)) {",
        "        throw new Error(\"column type mismatch: title\");",
        "    }",
        "    if (titles.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: title\");",
        "    }",
        "",
        "    const artists = trackRefs.artist();",
        "    if (!Array.isArray(artists)) {",
        "        throw new Error(\"column type mismatch: artist\");",
        "    }",
        "    if (artists.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: artist\");",
        "    }",
        "",
        "    const albums = trackRefs.album();",
        "    if (!Array.isArray(albums)) {",
        "        throw new Error(\"column type mismatch: album\");",
        "    }",
        "    if (albums.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: album\");",
        "    }",
        "",
        "    const durations = trackRefs.duration();",
        "    if (!Array.isArray(durations)) {",
        "        throw new Error(\"column type mismatch: duration\");",
        "    }",
        "    if (durations.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: duration\");",
        "    }",
        "",
        "    const kinds = trackRefs.kind();",
        "    if (!Array.isArray(kinds)) {",
        "        throw new Error(\"column type mismatch: kind\");",
        "    }",
        "    if (kinds.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: kind\");",
        "    }",
        "",
        "    const bitRates = trackRefs.bitRate();",
        "    if (!Array.isArray(bitRates)) {",
        "        throw new Error(\"column type mismatch: bit_rate\");",
        "    }",
        "    if (bitRates.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: bit_rate\");",
        "    }",
        "",
        "    const sampleRates = trackRefs.sampleRate();",
        "    if (!Array.isArray(sampleRates)) {",
        "        throw new Error(\"column type mismatch: sample_rate\");",
        "    }",
        "    if (sampleRates.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: sample_rate\");",
        "    }",
        "",
        "    const cloudStatuses = trackRefs.cloudStatus();",
        "    if (!Array.isArray(cloudStatuses)) {",
        "        throw new Error(\"column type mismatch: cloud_status\");",
        "    }",
        "    if (cloudStatuses.length !== expectedTrackCount) {",
        "        throw new Error(\"column length mismatch: cloud_status\");",
        "    }",
        "",
        "    const tracks = [];",
        "    for (let sourceIndex = 0; sourceIndex < expectedTrackCount; sourceIndex++) {",
        "        const databaseID = databaseIds[sourceIndex];",
        "        tracks.push({",
        "            source_index: sourceIndex,",
        "            database_id: databaseID,",
        "            persistent_id: textOrEmpty(persistentIds[sourceIndex]),",
        "            title: textOrEmpty(titles[sourceIndex]),",
        "            artist: textOrEmpty(artists[sourceIndex]),",
        "            album: textOrEmpty(albums[sourceIndex]),",
        "            duration: numberOrNull(durations[sourceIndex]),",
        "            kind: textOrEmpty(kinds[sourceIndex]),",
        "            bit_rate: numberOrNull(bitRates[sourceIndex]),",
        "            sample_rate: numberOrNull(sampleRates[sourceIndex]),",
        "            cloud_status: textOrEmpty(cloudStatuses[sourceIndex]),",
        "            is_file_track: fileTrackDatabaseIDs.has(databaseID)",
        "        });",
        "    }",
        "    return {",
        "        id: playlist.id(),",
        "        name: playlist.name(),",
        "        persistent_id: playlist.persistentID(),",
        "        tracks: tracks",
        "    };",
        "});",
        "",
        "JSON.stringify({playlists: playlists});",
        "",
    ]
    return lines.joined(separator: "\n")
}

/// The PRE-columnar exact-playlist read JXA (bulk-read-speedup Task 2),
/// kept ONLY for Diagnostics' "Compare readers" cross-check (Task 3,
/// `ReadWorker.compareReaders` in DiagnosticsView.swift): it reads the same
/// library with this legacy per-track-loop script and the new columnar
/// `buildReadJXA(name:)` script back-to-back and diffs the parsed results.
/// This builder exists for that one release and is removed after the
/// columnar reader has been validated against it live — do not add new
/// callers. Body and output are byte-identical to the pre-2026-08-11
/// `buildReadJXA` (pinned verbatim in `LegacyReadJXABuilderTests`) — this is
/// a pure copy under a new name, not a behavior change.
///
/// DEPRECATED ON PURPOSE (M1, 2026-08-11): the attribute is the removal
/// reminder. It is not "do not use" — Diagnostics' cross-check MUST use it —
/// it is "this symbol has a scheduled death, and the compiler will point at
/// every site that has to go with it."
@available(
    *, deprecated,
    message: "Diagnostics reader cross-check only; remove with the legacy builders"
)
public func legacyReadJXAScript(name: String) -> String {
    let encodedAppPath = appleScriptString(musicAppPath)
    let encodedName = appleScriptString(name)
    let lines = [
        "const Music = Application(\(encodedAppPath));",
        "const requestedName = \(encodedName);",
        "",
        "function textOrEmpty(value) {",
        "    return value === null || value === undefined ? \"\" : String(value);",
        "}",
        "",
        "function numberOrNull(value) {",
        "    return value === null || value === undefined || Number.isNaN(value) ? null : value;",
        "}",
        "",
        "const matches = Music.userPlaylists().filter(function (playlist) {",
        "    return playlist.name() === requestedName;",
        "});",
        "",
        "const playlists = matches.map(function (playlist) {",
        "    const fileTrackDatabaseIDs = new Set(",
        "        playlist.fileTracks().map(function (fileTrack) {",
        "            return fileTrack.databaseID();",
        "        })",
        "    );",
        "    const tracks = playlist.tracks().map(function (track, sourceIndex) {",
        "        const databaseID = track.databaseID();",
        "        return {",
        "            source_index: sourceIndex,",
        "            database_id: databaseID,",
        "            persistent_id: textOrEmpty(track.persistentID()),",
        "            title: textOrEmpty(track.name()),",
        "            artist: textOrEmpty(track.artist()),",
        "            album: textOrEmpty(track.album()),",
        "            duration: numberOrNull(track.duration()),",
        "            kind: textOrEmpty(track.kind()),",
        "            bit_rate: numberOrNull(track.bitRate()),",
        "            sample_rate: numberOrNull(track.sampleRate()),",
        "            cloud_status: textOrEmpty(track.cloudStatus()),",
        "            is_file_track: fileTrackDatabaseIDs.has(databaseID)",
        "        };",
        "    });",
        "    return {",
        "        id: playlist.id(),",
        "        name: playlist.name(),",
        "        persistent_id: playlist.persistentID(),",
        "        tracks: tracks",
        "    };",
        "});",
        "",
        "JSON.stringify({playlists: playlists});",
        "",
    ]
    return lines.joined(separator: "\n")
}

// MARK: - list-playlists JXA (M8; no reference counterpart)

/// Build the read-only playlist-enumeration JXA — the source browser's
/// listing read (M8, columnar since the 2026-08-06 bulk-read speedup, Task
/// 1). STATIC BY CONTRACT: this builder takes no parameters and performs NO
/// interpolation of any value; the returned text is a compile-time constant
/// (pinned verbatim in PlaylistListingTests). That zero-interpolation
/// property is load-bearing for the surface's safety review — do not
/// parameterize it.
///
/// Enumeration semantics deliberately MIRROR `buildReadJXA`: the same
/// absolute-path `Application(...)` targeting (the literal below must equal
/// `appleScriptString(musicAppPath)`; the pin test ties them) and the same
/// inclusion SET — every `user playlist`, which contains regular, smart, and
/// folder playlists (subscription playlists inherit `playlist`, not `user
/// playlist`, and are excluded) — so the browser's groups always agree with
/// what a subsequent audit's exact-name filter will find. Only the SPELLING
/// differs (M2, 2026-08-11): this script binds the collection UN-CALLED as
/// `Music.userPlaylists` (see COLUMNAR below), while `buildReadJXA` still
/// evaluates the same collection as `Music.userPlaylists()` because it has to
/// `.filter` it by name. `smart` and `special kind` are cheap per-playlist
/// properties (com.apple.Music.sdef: `user playlist.smart`, `playlist.special
/// kind`) exposed to annotate those kinds; `playlistRefs[index].tracks.length`
/// counts the same tracks collection the read script serializes.
/// Playlist-level properties are read raw (no coercion),
/// like the read JXA's playlist block: a null/undefined anomaly surfaces as
/// a strict-parse rejection, never a silent default.
///
/// COLUMNAR (2026-08-06, corrected in review): `playlistRefs` is bound to
/// `Music.userPlaylists` WITHOUT calling it — calling it (`()`) would
/// immediately EVALUATE the specifier into a plain JavaScript Array, which
/// has no `.id`/`.name`/… methods (every column read after that point would
/// be `TypeError: not a function`). Left un-called, `playlistRefs` stays a
/// chainable specifier COLLECTION: `.length` on it is the one property a
/// specifier collection exposes directly and triggers ONE `count` Apple
/// Event (the scalar count, read FIRST, before any column); property
/// getters called WITH parens on it — `.id()`, `.name()`, `.persistentID()`,
/// `.smart()`, `.specialKind()` — each trigger ONE `get` Apple Event and
/// return the WHOLE column as an array, five events total. Every column is
/// read off this SAME `playlistRefs` reference (never a second, freshly
/// re-filtered `Music.userPlaylists` access), so every column's index lines
/// up with every other column's index by construction.
///
/// `track_count` has no sdef counterpart to chain columnar: `playlist`/`user
/// playlist` (com.apple.Music.sdef) expose no track-COUNT property, only the
/// `tracks` ELEMENT collection, and a two-level "every track of every user
/// playlist" specifier is not a supported idiom outside genuine
/// Cocoa-Scriptable apps (Music is not one) — attempting it is unverified at
/// best. The verified-cheap route is a per-playlist loop over the SAME
/// `playlistRefs` collection: `playlistRefs[index].tracks.length` indexes to
/// ONE playlist's specifier, then accesses `.tracks` WITHOUT calling it (the
/// un-evaluated tracks-of-this-one-playlist specifier) so `.length` triggers
/// ONE lean `count` Apple Event per playlist — no track specifiers are
/// materialized. (Contrast the legacy script below, whose `playlist.tracks()`
/// call, WITH parens, evaluates and materializes every track specifier of
/// that playlist before JS reads its `.length` — one Apple Event, but one
/// that returns O(track count) data, not a lean count.) This loop is the one
/// deliberate per-playlist read in this script — every other column stays a
/// single whole-column fetch. Total Apple Events: 6 (the count-first read
/// plus the five columnar `get`s) + one lean count per playlist — e.g. ~399
/// for 393 playlists, versus ~2,358 for the pre-columnar script's six
/// per-playlist events each.
///
/// Every column's guard — including the loop-built `trackCounts` — rejects,
/// fail-closed, no retry, no repair, a column that disagrees with the
/// count-first read. The TYPE check (`!Array.isArray(...)`) and the LENGTH
/// check (`.length !== expectedCount`) are separate `if` statements, each
/// with its own accurate, LITERAL (not concatenated) message naming that
/// column: `column type mismatch: <field>` when the column itself came back
/// as something other than an array, and `column length mismatch: <field>`
/// when it IS an array but the wrong length (e.g. `column length mismatch:
/// name` — a playlist created or deleted mid-scan skews alignment between
/// the count read and a later column read). Both messages are source-text
/// literals per column, not built via string concatenation, so they stay
/// byte-pinnable. `trackCounts` is the ONE exception, and deliberately so
/// (M3, 2026-08-11): it is a JS array literal built by a loop whose bound IS
/// `expectedCount`, in this same script, so `Array.isArray(trackCounts)` is
/// unconditionally true and `trackCounts.length !== expectedCount` is
/// unconditionally false — both checks were DEAD CODE that could not fire for
/// any library state, and pretending otherwise made the guard set look wider
/// than it is. They are gone; the column keeps the one guard that can
/// actually fire, the per-element `typeof value === "number"` check (a
/// non-numeric `.tracks.length` from Music), which reports `column type
/// mismatch: track_count`. That column therefore has NO length message — the
/// pins reflect this. Records are assembled by index
/// afterward in a plain in-memory loop that touches no Music object — only
/// the six already-fetched arrays — so it sends no further Apple Events.
/// The JSON shape (keys, key order, per-record field order) is
/// byte-identical to the pre-columnar script.
public func buildListPlaylistsJXA() -> String {
    let lines = [
        "const Music = Application(\"/System/Applications/Music.app\");",
        "",
        "const playlistRefs = Music.userPlaylists;",
        "const expectedCount = playlistRefs.length;",
        "",
        "const ids = playlistRefs.id();",
        "if (!Array.isArray(ids)) {",
        "    throw new Error(\"column type mismatch: id\");",
        "}",
        "if (ids.length !== expectedCount) {",
        "    throw new Error(\"column length mismatch: id\");",
        "}",
        "",
        "const names = playlistRefs.name();",
        "if (!Array.isArray(names)) {",
        "    throw new Error(\"column type mismatch: name\");",
        "}",
        "if (names.length !== expectedCount) {",
        "    throw new Error(\"column length mismatch: name\");",
        "}",
        "",
        "const persistentIds = playlistRefs.persistentID();",
        "if (!Array.isArray(persistentIds)) {",
        "    throw new Error(\"column type mismatch: persistent_id\");",
        "}",
        "if (persistentIds.length !== expectedCount) {",
        "    throw new Error(\"column length mismatch: persistent_id\");",
        "}",
        "",
        "const trackCounts = [];",
        "for (let index = 0; index < expectedCount; index++) {",
        "    trackCounts.push(playlistRefs[index].tracks.length);",
        "}",
        "if (!trackCounts.every(function (value) { return typeof value === \"number\"; })) {",
        "    throw new Error(\"column type mismatch: track_count\");",
        "}",
        "",
        "const smartFlags = playlistRefs.smart();",
        "if (!Array.isArray(smartFlags)) {",
        "    throw new Error(\"column type mismatch: smart\");",
        "}",
        "if (smartFlags.length !== expectedCount) {",
        "    throw new Error(\"column length mismatch: smart\");",
        "}",
        "",
        "const specialKinds = playlistRefs.specialKind();",
        "if (!Array.isArray(specialKinds)) {",
        "    throw new Error(\"column type mismatch: special_kind\");",
        "}",
        "if (specialKinds.length !== expectedCount) {",
        "    throw new Error(\"column length mismatch: special_kind\");",
        "}",
        "",
        "const records = [];",
        "for (let index = 0; index < expectedCount; index++) {",
        "    records.push({",
        "        id: ids[index],",
        "        name: names[index],",
        "        persistent_id: persistentIds[index],",
        "        track_count: trackCounts[index],",
        "        smart: smartFlags[index],",
        "        special_kind: specialKinds[index]",
        "    });",
        "}",
        "",
        "JSON.stringify({playlists: records});",
        "",
    ]
    return lines.joined(separator: "\n")
}

/// The PRE-columnar playlist-enumeration JXA (M8), kept ONLY for Diagnostics'
/// "Compare readers" cross-check (Task 3, `ReadWorker.compareReaders` in
/// DiagnosticsView.swift) — it reads the same library with this legacy
/// per-playlist-loop script and the new columnar `buildListPlaylistsJXA()`
/// script back-to-back and diffs the parsed results. This builder exists for
/// that one release and is removed after the columnar reader has been
/// validated against it live; do not add new callers. Body and output are
/// byte-identical to the pre-2026-08-06 script
/// (pinned verbatim in `LegacyListPlaylistsBuilderTests`) — this is a pure
/// rename, not a behavior change.
///
/// DEPRECATED ON PURPOSE (M1, 2026-08-11): see the note on
/// `legacyReadJXAScript` — the attribute marks the scheduled removal, not a
/// prohibition on the one sanctioned caller.
@available(
    *, deprecated,
    message: "Diagnostics reader cross-check only; remove with the legacy builders"
)
public func legacyListPlaylistsScript() -> String {
    let lines = [
        "const Music = Application(\"/System/Applications/Music.app\");",
        "",
        "const playlists = Music.userPlaylists().map(function (playlist) {",
        "    return {",
        "        id: playlist.id(),",
        "        name: playlist.name(),",
        "        persistent_id: playlist.persistentID(),",
        "        track_count: playlist.tracks().length,",
        "        smart: playlist.smart(),",
        "        special_kind: playlist.specialKind()",
        "    };",
        "});",
        "",
        "JSON.stringify({playlists: playlists});",
        "",
    ]
    return lines.joined(separator: "\n")
}

// MARK: - the legacy-builder deprecation seam (M1, 2026-08-11)
//
// The two builders above carry `@available(*, deprecated, …)` so that ANY new
// direct caller, anywhere, is flagged the moment it is written. That reminder is
// the point of M1 — but their SANCTIONED callers (Diagnostics' "Compare
// readers" and the byte pins that keep the retained legacy text from drifting)
// must not sit in a standing warning, and neither of the language's usual outs
// applies here. Both were measured, not assumed:
//
//   - Marking the CALLING declaration deprecated only moves the warning one
//     frame up the chain. For "Compare readers" it walks
//     compareReaders -> startCompareReaders -> the Button inside SwiftUI's
//     `body`, and `body` cannot be deprecated.
//   - swift-testing REJECTS `@available` on `@Test`/`@Suite` declarations
//     outright ("Attribute 'Test' cannot be applied to this function because it
//     has been marked '@available'"), so the byte pins cannot carry it either.
//
// What remains is a non-deprecated protocol requirement satisfied by a
// DEPRECATED witness: the reminder stays bound to the two witnesses below, and
// the two accessors dispatch through the requirement, which the compiler does
// not re-report. The accessors are pure forwarders — a pin calling
// `legacyReadScript(name:)` still pins `legacyReadJXAScript(name:)`'s exact
// output — and protocol, witnesses, accessors and builders are all deleted in
// one sweep when the columnar readers have been validated live.
public protocol LegacyReaderScriptSource {
    static func legacyListingScriptText() -> String
    static func legacyReadScriptText(name: String) -> String
}

public enum LegacyReaderScripts: LegacyReaderScriptSource {
    @available(
        *, deprecated,
        message: "Diagnostics reader cross-check only; remove with the legacy builders"
    )
    public static func legacyListingScriptText() -> String {
        legacyListPlaylistsScript()
    }

    @available(
        *, deprecated,
        message: "Diagnostics reader cross-check only; remove with the legacy builders"
    )
    public static func legacyReadScriptText(name: String) -> String {
        legacyReadJXAScript(name: name)
    }
}

/// The pre-columnar listing script text — `legacyListPlaylistsScript()`
/// verbatim, reached through the seam above.
public func legacyListingScript<T: LegacyReaderScriptSource>(
    _ source: T.Type = LegacyReaderScripts.self
) -> String {
    T.legacyListingScriptText()
}

/// The pre-columnar snapshot script text for one name —
/// `legacyReadJXAScript(name:)` verbatim, reached through the seam above.
public func legacyReadScript<T: LegacyReaderScriptSource>(
    _ source: T.Type = LegacyReaderScripts.self, name: String
) -> String {
    T.legacyReadScriptText(name: name)
}

// MARK: - fail-closed validation (music_bridge.py:599-631)

/// Reject cloud-status values that cannot map to Music's enum
/// (music_bridge.py:599-609). Membership is scalar-exact, like Python `in`
/// over a set of str.
func validateCloudStatusNames(_ tracks: [TrackSnapshot]) throws {
    for track in tracks {
        if track.cloudStatus.isEmpty { continue }
        if !cloudStatusEnumCodes.contains(where: { scalarEqual($0.name, track.cloudStatus) }) {
            // Fix round 1, F4: render the value with Python repr semantics
            // ({track.cloud_status!r}, music_bridge.py:606-609) — quote flip,
            // control-character escapes, backslash escapes — instead of raw
            // interpolation in hard-coded quotes. Error-message path only;
            // no script text changes (M4 goldens byte-identical).
            throw MusicScriptBuilderError(
                "unsupported cloud status \(pythonRepr(track.cloudStatus)) at source index \(track.sourceIndex)"
            )
        }
    }
}

/// music_bridge.py:612-631 _validate_verified_source, check order preserved.
func validateVerifiedSource(
    plan: ConsolidationPlan,
    verifiedSource: PlaylistSnapshot
) throws {
    try validateCloudStatusNames(verifiedSource.tracks)
    if !scalarEqual(verifiedSource.name, plan.sourcePlaylistName) {
        throw MusicScriptBuilderError("verified source name does not match consolidation plan")
    }
    if !scalarEqual(verifiedSource.persistentId, plan.sourcePlaylistPersistentId) {
        throw MusicScriptBuilderError(
            "verified source persistent ID does not match consolidation plan"
        )
    }
    if verifiedSource.tracks.count != plan.sourceTrackCount {
        throw MusicScriptBuilderError(
            "verified source track count does not match consolidation plan"
        )
    }
    if !scalarEqual(sourceFingerprint(verifiedSource.tracks), plan.sourceFingerprint) {
        throw MusicScriptBuilderError(
            "verified source fingerprint does not match consolidation plan"
        )
    }
    if !scalarEqual(verifiedSource.tracks, plan.sourceTracks) {
        throw MusicScriptBuilderError(
            "verified source snapshot does not match the persisted plan snapshot"
        )
    }
    if !scalarEqual(try buildPlan(verifiedSource), plan) {
        throw MusicScriptBuilderError(
            "loaded consolidation plan is not canonical for the verified source"
        )
    }
}

// MARK: - exact playlist lookup (music_bridge.py:830-840)

func exactPlaylistLookup(variable: String, requestedName: String) -> [String] {
    [
        "    set \(variable) to {}",
        "    repeat with candidatePlaylist in every user playlist",
        "        set candidateName to name of candidatePlaylist as text",
        "        if (my textCodePointsMatch(candidateName, \(requestedName))) is true then",
        "            set end of \(variable) to contents of candidatePlaylist",
        "        end if",
        "    end repeat",
    ]
}

/// PID-set membership lookup for the free-form merge writer (2026-08-06
/// free-form design, Swift-native — no Python counterpart): free-form
/// copies do not share one name to filter by, so this collects every live
/// user playlist whose persistent ID scalar-exact-matches ANY entry of
/// `idsVariable` (an AppleScript list literal already `set` earlier in the
/// script — `expectedCopyPersistentIDs`). Mirrors `exactPlaylistLookup`'s
/// shape (one outer scan of `every user playlist`, `my textCodePointsMatch`,
/// accumulate into `variable`) so the rest of the writer — the
/// `(count of \(variable)) is not expectedCopyCount` guard and the nested
/// per-copy PID search that follows — is byte-identical prose to the
/// same-name path regardless of which lookup populated `variable`. Because
/// persistent IDs are unique per live playlist, a matched count can never
/// exceed the number of distinct requested IDs, so the existing
/// count-equals-expected guard still means exactly what it means for the
/// same-name path: every pinned copy, and only pinned copies, were found.
func exactPersistentIdSetLookup(variable: String, idsVariable: String) -> [String] {
    [
        "    set \(variable) to {}",
        "    repeat with candidatePlaylist in every user playlist",
        "        set candidatePersistentID to persistent ID of candidatePlaylist",
        "        if candidatePersistentID is missing value then set candidatePersistentID to \"\"",
        "        repeat with expectedIdCandidate in \(idsVariable)",
        "            if (my textCodePointsMatch(candidatePersistentID, expectedIdCandidate)) is true then",
        "                set end of \(variable) to contents of candidatePlaylist",
        "                exit repeat",
        "            end if",
        "        end repeat",
        "    end repeat",
    ]
}

// MARK: - PUA-delimiter payload encoder (music_bridge.py:843-886)

/// Encode every guarded source field into one compiler-friendly literal.
/// Delimiters are the first two BMP private-use scalars (U+E000..<U+F900)
/// absent from every guarded text field of every track.
func encodeExpectedSourcePayload(
    _ tracks: [TrackSnapshot]
) throws -> (payload: String, fieldDelimiter: String, rowDelimiter: String) {
    try validateCloudStatusNames(tracks)

    var usedScalars = Set<Unicode.Scalar>()
    for track in tracks {
        for value in [
            track.persistentId,
            track.title,
            track.artist,
            track.album,
            track.kind,
            track.cloudStatus,
        ] {
            usedScalars.formUnion(value.unicodeScalars)
        }
    }

    var delimiters: [Unicode.Scalar] = []
    var codePoint: UInt32 = 0xE000
    while codePoint < 0xF900 && delimiters.count < 2 {
        let scalar = Unicode.Scalar(codePoint)!
        if !usedScalars.contains(scalar) {
            delimiters.append(scalar)
        }
        codePoint += 1
    }
    guard delimiters.count >= 2 else {
        throw MusicScriptBuilderError("source text exhausts the guarded payload delimiters")
    }
    let fieldDelimiter = String(Character(delimiters[0]))
    let rowDelimiter = String(Character(delimiters[1]))

    var rows: [String] = []
    for track in tracks {
        let fields = [
            String(track.databaseId),
            track.persistentId,
            track.title,
            track.artist,
            track.album,
            track.durationMs.map(String.init) ?? "",
            track.kind,
            track.bitRateKbps.map(String.init) ?? "",
            track.sampleRateHz.map(String.init) ?? "",
            track.cloudStatus,
            track.isFileTrack ? "1" : "0",
        ]
        rows.append(fields.joined(separator: fieldDelimiter))
    }
    return (rows.joined(separator: rowDelimiter), fieldDelimiter, rowDelimiter)
}

// MARK: - handlers (music_bridge.py:889-929)

/// Exact Unicode code-point comparison handler (music_bridge.py:889-899).
func textCodePointHandlerLines() -> [String] {
    [
        "on textCodePointsMatch(expectedText, liveText)",
        "    if expectedText is missing value then set expectedText to \"\"",
        "    if liveText is missing value then set liveText to \"\"",
        "    set expectedCodePoints to id of (expectedText as text)",
        "    set liveCodePoints to id of (liveText as text)",
        "    return (expectedCodePoints is liveCodePoints)",
        "end textCodePointsMatch",
    ]
}

/// Type-safe JXA-name to AppleScript-enum comparison handler
/// (music_bridge.py:902-929).
func cloudStatusHandlerLines() -> [String] {
    var lines = [
        "on cloudStatusMatches(expectedCloudStatusText, liveCloudStatus)",
        "    if expectedCloudStatusText is \"\" then return (liveCloudStatus is missing value)",
        "    if liveCloudStatus is missing value then return false",
    ]
    for (position, entry) in cloudStatusEnumCodes.enumerated() {
        let keyword = position == 0 ? "if" : "else if"
        lines.append("    \(keyword) expectedCloudStatusText is \(appleScriptString(entry.name)) then")
        lines.append("        set expectedCloudStatus to «constant eClS\(entry.code)»")
    }
    lines.append(contentsOf: [
        "    else",
        "        error \"internal expected cloud status is unsupported\"",
        "    end if",
        "    return (liveCloudStatus is expectedCloudStatus)",
        "end cloudStatusMatches",
    ])
    return lines
}

/// Keep expanded writer state out of the persisted compiled script
/// (music_bridge.py:932-940): `local` declarations in chunks of 5.
func runtimeLocalDeclarationLines(_ localsNames: [String] = applyScriptLocals) -> [String] {
    stride(from: 0, to: localsNames.count, by: 5).map { offset in
        "local " + localsNames[offset..<min(offset + 5, localsNames.count)].joined(separator: ", ")
    }
}

// MARK: - the 11-field per-track guard block (music_bridge.py:943-1038)

/// Byte-identical for both writers. Assumes surrounding scope has set:
/// sourceIndex, expectedSourceFields, liveSourceTrack.
func sourceFieldGuardLines() -> [String] {
    [
        "        set expectedDatabaseID to ((item 1 of expectedSourceFields) as integer)",
        "        if (database ID of liveSourceTrack) is not expectedDatabaseID then error (\"source track database ID changed at index \" & sourceIndex)",
        "        set liveTextValue to persistent ID of liveSourceTrack",
        "        if liveTextValue is missing value then set liveTextValue to \"\"",
        "        set expectedTextValue to item 2 of expectedSourceFields",
        "        if (my textCodePointsMatch(expectedTextValue, liveTextValue)) is not true then error (\"source track persistent ID changed at index \" & sourceIndex)",
        "        set liveTextValue to name of liveSourceTrack",
        "        if liveTextValue is missing value then set liveTextValue to \"\"",
        "        set expectedTextValue to item 3 of expectedSourceFields",
        "        if (my textCodePointsMatch(expectedTextValue, liveTextValue)) is not true then error (\"source track title changed at index \" & sourceIndex)",
        "        set liveTextValue to artist of liveSourceTrack",
        "        if liveTextValue is missing value then set liveTextValue to \"\"",
        "        set expectedTextValue to item 4 of expectedSourceFields",
        "        if (my textCodePointsMatch(expectedTextValue, liveTextValue)) is not true then error (\"source track artist changed at index \" & sourceIndex)",
        "        set liveTextValue to album of liveSourceTrack",
        "        if liveTextValue is missing value then set liveTextValue to \"\"",
        "        set expectedTextValue to item 5 of expectedSourceFields",
        "        if (my textCodePointsMatch(expectedTextValue, liveTextValue)) is not true then error (\"source track album changed at index \" & sourceIndex)",
        "        set expectedNumberText to item 6 of expectedSourceFields",
        "        set liveDurationSeconds to duration of liveSourceTrack",
        "        if expectedNumberText is \"\" then",
        "            if liveDurationSeconds is not missing value then error (\"source track duration changed at index \" & sourceIndex)",
        "        else",
        "            if liveDurationSeconds is missing value then error (\"source track duration changed at index \" & sourceIndex)",
        "            set expectedNumberValue to expectedNumberText as integer",
        "            if ((liveDurationSeconds * 1000) as integer) is not expectedNumberValue then error (\"source track duration changed at index \" & sourceIndex)",
        "        end if",
        "        set liveTextValue to kind of liveSourceTrack",
        "        if liveTextValue is missing value then set liveTextValue to \"\"",
        "        set expectedTextValue to item 7 of expectedSourceFields",
        "        if (my textCodePointsMatch(expectedTextValue, liveTextValue)) is not true then error (\"source track kind changed at index \" & sourceIndex)",
        "        set expectedNumberText to item 8 of expectedSourceFields",
        "        set liveNumberValue to bit rate of liveSourceTrack",
        "        if expectedNumberText is \"\" then",
        "            if liveNumberValue is not missing value then error (\"source track bit rate changed at index \" & sourceIndex)",
        "        else",
        "            if liveNumberValue is missing value then error (\"source track bit rate changed at index \" & sourceIndex)",
        "            set expectedNumberValue to expectedNumberText as integer",
        "            if liveNumberValue is not expectedNumberValue then error (\"source track bit rate changed at index \" & sourceIndex)",
        "        end if",
        "        set expectedNumberText to item 9 of expectedSourceFields",
        "        set liveNumberValue to sample rate of liveSourceTrack",
        "        if expectedNumberText is \"\" then",
        "            if liveNumberValue is not missing value then error (\"source track sample rate changed at index \" & sourceIndex)",
        "        else",
        "            if liveNumberValue is missing value then error (\"source track sample rate changed at index \" & sourceIndex)",
        "            set expectedNumberValue to expectedNumberText as integer",
        "            if liveNumberValue is not expectedNumberValue then error (\"source track sample rate changed at index \" & sourceIndex)",
        "        end if",
        "        set liveCloudStatus to cloud status of liveSourceTrack",
        "        set expectedTextValue to item 10 of expectedSourceFields",
        "        if (my cloudStatusMatches(expectedTextValue, liveCloudStatus)) is not true then error (\"source track cloud status changed at index \" & sourceIndex)",
        "        set liveTrackClass to get class of liveSourceTrack",
        "        set liveIsFileTrack to (liveTrackClass is file track)",
        "        set expectedFileTrackText to item 11 of expectedSourceFields",
        "        if expectedFileTrackText is \"1\" then",
        "            if liveIsFileTrack is not true then error (\"source track file-track status changed at index \" & sourceIndex)",
        "        else if expectedFileTrackText is \"0\" then",
        "            if liveIsFileTrack is not false then error (\"source track file-track status changed at index \" & sourceIndex)",
        "        else",
        "            error \"internal expected source file-track marker is invalid\"",
        "        end if",
    ]
}

// MARK: - single-playlist consolidation writer (music_bridge.py:1041-1176)

/// Generate an AppleScript that validates all live state before writing.
public func buildApplyScript(
    plan: ConsolidationPlan,
    verifiedSource: PlaylistSnapshot,
    targetName: String
) throws -> String {
    try validateVerifiedSource(plan: plan, verifiedSource: verifiedSource)

    var tracksBySourceIndex: [Int: (position: Int, track: TrackSnapshot)] = [:]
    for (position, track) in verifiedSource.tracks.enumerated() {
        if track.sourceIndex != position {
            throw MusicScriptBuilderError(
                "verified source position does not match source index \(track.sourceIndex)"
            )
        }
        if tracksBySourceIndex[track.sourceIndex] != nil {
            throw MusicScriptBuilderError(
                "duplicate source index \(track.sourceIndex) in verified source"
            )
        }
        tracksBySourceIndex[track.sourceIndex] = (position, track)
    }

    var selected: [(position: Int, track: TrackSnapshot)] = []
    for sourceIndex in plan.winnerSourceIndexes {
        guard let entry = tracksBySourceIndex[sourceIndex] else {
            throw MusicScriptBuilderError(
                "winner source index \(sourceIndex) is absent from verified source"
            )
        }
        selected.append(entry)
    }

    let sourceNameLiteral = appleScriptString(plan.sourcePlaylistName)
    let targetNameLiteral = appleScriptString(targetName)
    let sourcePidLiteral = appleScriptString(plan.sourcePlaylistPersistentId)
    let encoded = try encodeExpectedSourcePayload(verifiedSource.tracks)
    let selectedPositionsLiteral =
        "{" + selected.map { String($0.position + 1) }.joined(separator: ", ") + "}"

    var lines: [String] = []
    lines.append(contentsOf: textCodePointHandlerLines())
    lines.append("")
    lines.append(contentsOf: cloudStatusHandlerLines())
    lines.append("")
    lines.append(contentsOf: runtimeLocalDeclarationLines())
    lines.append("")
    lines.append(contentsOf: [
        "set sourcePlaylistName to \(sourceNameLiteral)",
        "set targetPlaylistName to \(targetNameLiteral)",
        "set expectedSourcePlaylistPersistentID to \(sourcePidLiteral)",
        "set expectedSourceTrackCount to \(plan.sourceTrackCount)",
        "set expectedSourcePayload to \(appleScriptString(encoded.payload))",
        "set expectedFieldDelimiter to \(appleScriptString(encoded.fieldDelimiter))",
        "set expectedRowDelimiter to \(appleScriptString(encoded.rowDelimiter))",
        "set selectedSourcePositions to \(selectedPositionsLiteral)",
        "",
        "set savedTextItemDelimiters to AppleScript's text item delimiters",
        "try",
        "    if expectedSourceTrackCount is 0 then",
        "        set expectedSourceRows to {}",
        "    else",
        "        considering case, diacriticals, hyphens, punctuation and white space",
        "            set AppleScript's text item delimiters to {expectedRowDelimiter}",
        "            set expectedSourceRows to every text item of expectedSourcePayload",
        "        end considering",
        "    end if",
        "    if (count of expectedSourceRows) is not expectedSourceTrackCount then error \"internal expected source payload row count mismatch\"",
        "    set expectedSourceFieldsByPosition to {}",
        "    considering case, diacriticals, hyphens, punctuation and white space",
        "        set AppleScript's text item delimiters to {expectedFieldDelimiter}",
        "        repeat with expectedSourceRow in expectedSourceRows",
        "            set expectedSourceFields to every text item of (expectedSourceRow as text)",
        "            if (count of expectedSourceFields) is not 11 then error \"internal expected source payload field count mismatch\"",
        "            copy expectedSourceFields to end of expectedSourceFieldsByPosition",
        "        end repeat",
        "    end considering",
        "    set AppleScript's text item delimiters to savedTextItemDelimiters",
        "on error errorMessage number errorNumber",
        "    set AppleScript's text item delimiters to savedTextItemDelimiters",
        "    error errorMessage number errorNumber",
        "end try",
        "",
        "tell application \(appleScriptString(musicAppPath))",
    ])
    lines.append(contentsOf: exactPlaylistLookup(
        variable: "sourcePlaylists", requestedName: "sourcePlaylistName"
    ))
    lines.append(contentsOf: [
        "    if (count of sourcePlaylists) is not 1 then error \"expected exactly one source user playlist\"",
        "    set sourcePlaylist to item 1 of sourcePlaylists",
        "",
        "    set liveSourcePlaylistPersistentID to persistent ID of sourcePlaylist",
        "    if liveSourcePlaylistPersistentID is missing value then set liveSourcePlaylistPersistentID to \"\"",
        "    if (my textCodePointsMatch(expectedSourcePlaylistPersistentID, liveSourcePlaylistPersistentID)) is not true then error \"source playlist persistent ID changed\"",
        "    set sourceTracks to every track of sourcePlaylist",
        "    if (count of sourceTracks) is not expectedSourceTrackCount then error \"source track count changed\"",
        "    repeat with sourcePosition from 1 to expectedSourceTrackCount",
        "        set sourceIndex to sourcePosition - 1",
        "        set expectedSourceFields to item sourcePosition of expectedSourceFieldsByPosition",
        "        set liveSourceTrack to item sourcePosition of sourceTracks",
    ])
    lines.append(contentsOf: sourceFieldGuardLines())
    lines.append(contentsOf: [
        "    end repeat",
        "",
        "",
    ])
    lines.append(contentsOf: exactPlaylistLookup(
        variable: "targetPlaylists", requestedName: "targetPlaylistName"
    ))
    lines.append(contentsOf: [
        "    if (count of targetPlaylists) is not 0 then error \"target user playlist already exists\"",
        "",
        "    set destinationPlaylist to make new user playlist with properties {name:targetPlaylistName}",
        "    repeat with selectedSourcePosition in selectedSourcePositions",
        "        set selectedTrack to item (selectedSourcePosition as integer) of sourceTracks",
        "        duplicate selectedTrack to destinationPlaylist",
        "    end repeat",
    ])
    let success = "{\"status\":\"ok\",\"duplicated_count\":\(selected.count)}"
    lines.append(contentsOf: [
        "    return \(appleScriptString(success))",
        "end tell",
        "",
    ])
    return lines.joined(separator: "\n")
}

// MARK: - same-name merge writer (music_bridge.py:1179-1318)

/// The inner per-track loop body for a matched live copy
/// (music_bridge.py:1179-1189).
func mergeTrackGuardBlock() -> [String] {
    var lines = [
        "        set combinedPosition to combinedPosition + 1",
        "        set sourceIndex to combinedPosition - 1",
        "        set expectedSourceFields to item combinedPosition of expectedSourceFieldsByPosition",
        "        set liveSourceTrack to item withinPosition of copyTracks",
    ]
    lines.append(contentsOf: sourceFieldGuardLines())
    lines.append("        set end of combinedTracks to contents of liveSourceTrack")
    return lines
}

/// Generate an AppleScript that validates every copy before one guarded write.
///
/// CRITICAL PIN (2026-08-06 free-form design, Task 1): for a same-name plan
/// (`plan.isFreeForm == false`) this function's output is byte-identical to
/// the pre-free-form text — the branch below is the ONLY change, and it is
/// taken BEFORE any same-name-specific line is emitted. The free-form branch
/// is delegated to `buildFreeFormMergeApplyScript`, a separate function, so
/// the same-name body beneath this branch is untouched source text, not
/// merely equivalent output.
public func buildMergeApplyScript(
    plan: MergePlan,
    verifiedCopies: [PlaylistSnapshot],
    targetName: String
) throws -> String {
    // 2026-08-06 review finding m1: assert the all-or-none invariant at
    // this seam too, in the house fail-closed style — a same-name plan
    // with this check satisfied is trivially unaffected (guard passes
    // silently), so this cannot perturb the same-name byte-identity pin.
    guard plan.freeFormFieldsAreConsistent else {
        throw MusicScriptBuilderError(
            "merge plan mixes free-form and same-name fields; refusing"
        )
    }
    // Fail closed on any mismatch between the plan and the verified copies
    // (music_bridge.py:1198-1200).
    if !scalarEqual(verifiedCopies, plan.copies) {
        throw MusicScriptBuilderError("verified copies do not match the merge plan copies")
    }
    if plan.isFreeForm {
        return try buildFreeFormMergeApplyScript(plan: plan, targetName: targetName)
    }
    let combined = plan.combinedTracks
    let encoded = try encodeExpectedSourcePayload(combined)

    let sourceNameLiteral = appleScriptString(plan.mergedPlaylistSourceName)
    let targetNameLiteral = appleScriptString(targetName)
    let copyPidsLiteral =
        "{" + plan.copies.map { appleScriptString($0.persistentId) }.joined(separator: ", ") + "}"
    let copyCountsLiteral =
        "{" + plan.copies.map { String($0.tracks.count) }.joined(separator: ", ") + "}"
    let selectedPositionsLiteral =
        "{" + plan.winnerSourceIndexes.map { String($0 + 1) }.joined(separator: ", ") + "}"

    var lines: [String] = []
    lines.append(contentsOf: textCodePointHandlerLines())
    lines.append("")
    lines.append(contentsOf: cloudStatusHandlerLines())
    lines.append("")
    lines.append(contentsOf: runtimeLocalDeclarationLines(mergeApplyScriptLocals))
    lines.append("")
    lines.append(contentsOf: [
        "set sourcePlaylistName to \(sourceNameLiteral)",
        "set targetPlaylistName to \(targetNameLiteral)",
        "set expectedCopyCount to \(plan.copies.count)",
        "set expectedCopyPersistentIDs to \(copyPidsLiteral)",
        "set expectedCopyTrackCounts to \(copyCountsLiteral)",
        "set expectedCombinedTrackCount to \(plan.combinedTrackCount)",
        "set expectedCombinedPayload to \(appleScriptString(encoded.payload))",
        "set expectedFieldDelimiter to \(appleScriptString(encoded.fieldDelimiter))",
        "set expectedRowDelimiter to \(appleScriptString(encoded.rowDelimiter))",
        "set selectedCombinedPositions to \(selectedPositionsLiteral)",
        "",
        "set savedTextItemDelimiters to AppleScript's text item delimiters",
        "try",
        "    if expectedCombinedTrackCount is 0 then",
        "        set expectedSourceRows to {}",
        "    else",
        "        considering case, diacriticals, hyphens, punctuation and white space",
        "            set AppleScript's text item delimiters to {expectedRowDelimiter}",
        "            set expectedSourceRows to every text item of expectedCombinedPayload",
        "        end considering",
        "    end if",
        "    if (count of expectedSourceRows) is not expectedCombinedTrackCount then error \"internal expected combined payload row count mismatch\"",
        "    set expectedSourceFieldsByPosition to {}",
        "    considering case, diacriticals, hyphens, punctuation and white space",
        "        set AppleScript's text item delimiters to {expectedFieldDelimiter}",
        "        repeat with expectedSourceRow in expectedSourceRows",
        "            set expectedSourceFields to every text item of (expectedSourceRow as text)",
        "            if (count of expectedSourceFields) is not 11 then error \"internal expected combined payload field count mismatch\"",
        "            copy expectedSourceFields to end of expectedSourceFieldsByPosition",
        "        end repeat",
        "    end considering",
        "    set AppleScript's text item delimiters to savedTextItemDelimiters",
        "on error errorMessage number errorNumber",
        "    set AppleScript's text item delimiters to savedTextItemDelimiters",
        "    error errorMessage number errorNumber",
        "end try",
        "",
        "tell application \(appleScriptString(musicAppPath))",
    ])
    lines.append(contentsOf: exactPlaylistLookup(
        variable: "sourcePlaylists", requestedName: "sourcePlaylistName"
    ))
    lines.append(contentsOf: [
        "    if (count of sourcePlaylists) is not expectedCopyCount then error \"live copy count changed\"",
        "    set combinedTracks to {}",
        "    set combinedPosition to 0",
        "    repeat with copyIndex from 1 to expectedCopyCount",
        "        set expectedCopyPersistentID to item copyIndex of expectedCopyPersistentIDs",
        "        set expectedCopyTrackCount to item copyIndex of expectedCopyTrackCounts",
        "        set matchedCopy to missing value",
        "        repeat with candidateCopy in sourcePlaylists",
        "            set candidateCopyPID to persistent ID of candidateCopy",
        "            if candidateCopyPID is missing value then set candidateCopyPID to \"\"",
        "            if (my textCodePointsMatch(expectedCopyPersistentID, candidateCopyPID)) is true then",
        "                set matchedCopy to contents of candidateCopy",
        "                exit repeat",
        "            end if",
        "        end repeat",
        "        if matchedCopy is missing value then error \"expected copy persistent ID is absent\"",
        "        set copyTracks to every track of matchedCopy",
        "        if (count of copyTracks) is not expectedCopyTrackCount then error \"copy track count changed\"",
        "        repeat with withinPosition from 1 to expectedCopyTrackCount",
    ])
    lines.append(contentsOf: mergeTrackGuardBlock())
    lines.append(contentsOf: [
        "        end repeat",
        "    end repeat",
        "    if (count of combinedTracks) is not expectedCombinedTrackCount then error \"combined track count mismatch\"",
        "",
    ])
    lines.append(contentsOf: exactPlaylistLookup(
        variable: "targetPlaylists", requestedName: "targetPlaylistName"
    ))
    lines.append(contentsOf: [
        "    if (count of targetPlaylists) is not 0 then error \"target user playlist already exists\"",
        "    set destinationPlaylist to make new user playlist with properties {name:targetPlaylistName}",
        "    repeat with selectedCombinedPosition in selectedCombinedPositions",
        "        set selectedTrack to item (selectedCombinedPosition as integer) of combinedTracks",
        "        duplicate selectedTrack to destinationPlaylist",
        "    end repeat",
    ])
    let success = "{\"status\":\"ok\",\"duplicated_count\":\(plan.winnerSourceIndexes.count)}"
    lines.append(contentsOf: [
        "    return \(appleScriptString(success))",
        "end tell",
        "",
    ])
    return lines.joined(separator: "\n")
}

// MARK: - free-form merge writer (2026-08-06 free-form design; Swift-native,
// no Python counterpart)

/// The `buildMergeApplyScript` free-form branch: same N-copy guarded
/// create-and-duplicate writer, reusing every per-track guard verbatim
/// (`sourceFieldGuardLines`/`mergeTrackGuardBlock`, `encodeExpectedSourcePayload`,
/// the compact delimiter-encoded payload — no per-track guard unrolling),
/// but:
///   - the initial candidate-playlist scan is `exactPersistentIdSetLookup`
///     (PID-set membership) instead of `exactPlaylistLookup` (one shared
///     name) — free-form copies are not required to share a name, so there
///     is no single name to filter live playlists by. Everything AFTER that
///     scan — the count-equals-expected guard, the nested per-copy PID
///     search, the per-track field guard, the target lookup-and-create — is
///     the same prose as the same-name path, unaffected by which lookup
///     populated `sourcePlaylists`.
///   - review finding m2: the same-name path's `exactPlaylistLookup` only
///     ever admits playlists whose NAME already matched, so its per-copy
///     match re-checks identity by name for free. The PID-set lookup here
///     does not check name at all, so once a copy is matched by
///     persistent ID, one explicit `textCodePointsMatch` against
///     `plan.sourceNames[copyIndex]` catches a copy renamed between
///     `ensureFreeFormCopiesMatch`'s preflight and this compiled execution
///     — the same defense-in-depth relationship every other in-script
///     guard here already has with its Swift-side preflight counterpart.
///   - the target lookup-and-create is unchanged (by name — the target
///     always has exactly one name, computed by the caller and passed as
///     `targetName`; free-form-ness is a property of the SOURCES, not the
///     target).
///   - when `plan.targetDescription` is non-nil (always true for a
///     free-form plan; the parameter is still tested independently so a
///     future same-name-with-description plan would work unmodified), one
///     additional statement sets `description of destinationPlaylist`
///     immediately after the duplicate loop, in the SAME compiled
///     execution, followed by an immediate in-script readback: any mismatch
///     between what was set and what reads back raises an AppleScript
///     error, which — like every other in-script guard here — fails the one
///     compiled execution closed (caught by the caller as a writer failure,
///     never silently downgraded to success).
private func buildFreeFormMergeApplyScript(
    plan: MergePlan,
    targetName: String
) throws -> String {
    let combined = plan.combinedTracks
    let encoded = try encodeExpectedSourcePayload(combined)

    let targetNameLiteral = appleScriptString(targetName)
    let copyPidsLiteral =
        "{" + plan.copies.map { appleScriptString($0.persistentId) }.joined(separator: ", ") + "}"
    let copyCountsLiteral =
        "{" + plan.copies.map { String($0.tracks.count) }.joined(separator: ", ") + "}"
    // 2026-08-06 review finding m2: the same-name writer's per-copy match
    // implicitly re-checks the NAME too, for free — `exactPlaylistLookup`
    // only ever populates `sourcePlaylists` with playlists whose name
    // already matched. This branch's PID-set lookup does not check name at
    // all, so without an explicit check here a copy renamed between
    // `ensureFreeFormCopiesMatch`'s preflight and this compiled execution
    // would go undetected and merge under its old (planned) identity.
    // `plan.sourceNames` is guaranteed non-nil here: `buildMergeApplyScript`
    // asserts `freeFormFieldsAreConsistent` before ever branching into this
    // function (2026-08-06 review finding m1).
    let copyNamesLiteral =
        "{" + plan.sourceNames!.map { appleScriptString($0) }.joined(separator: ", ") + "}"
    let selectedPositionsLiteral =
        "{" + plan.winnerSourceIndexes.map { String($0 + 1) }.joined(separator: ", ") + "}"

    var lines: [String] = []
    lines.append(contentsOf: textCodePointHandlerLines())
    lines.append("")
    lines.append(contentsOf: cloudStatusHandlerLines())
    lines.append("")
    lines.append(contentsOf: runtimeLocalDeclarationLines(freeFormMergeApplyScriptLocals))
    lines.append("")
    lines.append(contentsOf: [
        "set targetPlaylistName to \(targetNameLiteral)",
        "set expectedCopyCount to \(plan.copies.count)",
        "set expectedCopyPersistentIDs to \(copyPidsLiteral)",
        "set expectedCopyTrackCounts to \(copyCountsLiteral)",
        "set expectedCopyNames to \(copyNamesLiteral)",
        "set expectedCombinedTrackCount to \(plan.combinedTrackCount)",
        "set expectedCombinedPayload to \(appleScriptString(encoded.payload))",
        "set expectedFieldDelimiter to \(appleScriptString(encoded.fieldDelimiter))",
        "set expectedRowDelimiter to \(appleScriptString(encoded.rowDelimiter))",
        "set selectedCombinedPositions to \(selectedPositionsLiteral)",
        "",
        "set savedTextItemDelimiters to AppleScript's text item delimiters",
        "try",
        "    if expectedCombinedTrackCount is 0 then",
        "        set expectedSourceRows to {}",
        "    else",
        "        considering case, diacriticals, hyphens, punctuation and white space",
        "            set AppleScript's text item delimiters to {expectedRowDelimiter}",
        "            set expectedSourceRows to every text item of expectedCombinedPayload",
        "        end considering",
        "    end if",
        "    if (count of expectedSourceRows) is not expectedCombinedTrackCount then error \"internal expected combined payload row count mismatch\"",
        "    set expectedSourceFieldsByPosition to {}",
        "    considering case, diacriticals, hyphens, punctuation and white space",
        "        set AppleScript's text item delimiters to {expectedFieldDelimiter}",
        "        repeat with expectedSourceRow in expectedSourceRows",
        "            set expectedSourceFields to every text item of (expectedSourceRow as text)",
        "            if (count of expectedSourceFields) is not 11 then error \"internal expected combined payload field count mismatch\"",
        "            copy expectedSourceFields to end of expectedSourceFieldsByPosition",
        "        end repeat",
        "    end considering",
        "    set AppleScript's text item delimiters to savedTextItemDelimiters",
        "on error errorMessage number errorNumber",
        "    set AppleScript's text item delimiters to savedTextItemDelimiters",
        "    error errorMessage number errorNumber",
        "end try",
        "",
        "tell application \(appleScriptString(musicAppPath))",
    ])
    lines.append(contentsOf: exactPersistentIdSetLookup(
        variable: "sourcePlaylists", idsVariable: "expectedCopyPersistentIDs"
    ))
    lines.append(contentsOf: [
        "    if (count of sourcePlaylists) is not expectedCopyCount then error \"live copy count changed\"",
        "    set combinedTracks to {}",
        "    set combinedPosition to 0",
        "    repeat with copyIndex from 1 to expectedCopyCount",
        "        set expectedCopyPersistentID to item copyIndex of expectedCopyPersistentIDs",
        "        set expectedCopyTrackCount to item copyIndex of expectedCopyTrackCounts",
        "        set expectedCopyName to item copyIndex of expectedCopyNames",
        "        set matchedCopy to missing value",
        "        repeat with candidateCopy in sourcePlaylists",
        "            set candidateCopyPID to persistent ID of candidateCopy",
        "            if candidateCopyPID is missing value then set candidateCopyPID to \"\"",
        "            if (my textCodePointsMatch(expectedCopyPersistentID, candidateCopyPID)) is true then",
        "                set matchedCopy to contents of candidateCopy",
        "                exit repeat",
        "            end if",
        "        end repeat",
        "        if matchedCopy is missing value then error \"expected copy persistent ID is absent\"",
        "        set candidateCopyName to name of matchedCopy",
        "        if candidateCopyName is missing value then set candidateCopyName to \"\"",
        "        if (my textCodePointsMatch(expectedCopyName, candidateCopyName)) is not true then error \"copy name changed\"",
        "        set copyTracks to every track of matchedCopy",
        "        if (count of copyTracks) is not expectedCopyTrackCount then error \"copy track count changed\"",
        "        repeat with withinPosition from 1 to expectedCopyTrackCount",
    ])
    lines.append(contentsOf: mergeTrackGuardBlock())
    lines.append(contentsOf: [
        "        end repeat",
        "    end repeat",
        "    if (count of combinedTracks) is not expectedCombinedTrackCount then error \"combined track count mismatch\"",
        "",
    ])
    lines.append(contentsOf: exactPlaylistLookup(
        variable: "targetPlaylists", requestedName: "targetPlaylistName"
    ))
    lines.append(contentsOf: [
        "    if (count of targetPlaylists) is not 0 then error \"target user playlist already exists\"",
        "    set destinationPlaylist to make new user playlist with properties {name:targetPlaylistName}",
        "    repeat with selectedCombinedPosition in selectedCombinedPositions",
        "        set selectedTrack to item (selectedCombinedPosition as integer) of combinedTracks",
        "        duplicate selectedTrack to destinationPlaylist",
        "    end repeat",
    ])
    if let targetDescription = plan.targetDescription {
        let descriptionLiteral = appleScriptString(targetDescription)
        lines.append(contentsOf: [
            "    set description of destinationPlaylist to \(descriptionLiteral)",
            "    set liveTargetDescription to description of destinationPlaylist",
            "    if liveTargetDescription is missing value then set liveTargetDescription to \"\"",
            "    if (my textCodePointsMatch(\(descriptionLiteral), liveTargetDescription)) is not true then error \"target description readback mismatch\"",
        ])
    }
    let success = "{\"status\":\"ok\",\"duplicated_count\":\(plan.winnerSourceIndexes.count)}"
    lines.append(contentsOf: [
        "    return \(appleScriptString(success))",
        "end tell",
        "",
    ])
    return lines.joined(separator: "\n")
}
