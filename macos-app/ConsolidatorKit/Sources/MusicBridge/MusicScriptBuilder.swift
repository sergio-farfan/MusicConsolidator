// MusicScriptBuilder.swift
// Swift port of the PURE script-generation half of
// apple_music_consolidator/music_bridge.py (M4). Every template, encoder, and
// fail-closed guard below is a verbatim-in-behavior port; comments carry
// music_bridge.py line references. The impure orchestration (OSAKit runner,
// ensure/apply/verify flows) is M5 and deliberately absent here.
//
// Determinism: every builder is a pure function of its inputs — no clocks,
// no randomness — which the golden byte-parity gate relies on.
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

// MARK: - read JXA (music_bridge.py:143-195)

/// Build read-only JXA that serializes every exact-name user playlist.
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
/// listing read (M8). STATIC BY CONTRACT: this builder takes no parameters
/// and performs NO interpolation of any value; the returned text is a
/// compile-time constant (pinned verbatim in PlaylistListingTests). That
/// zero-interpolation property is load-bearing for the surface's safety
/// review — do not parameterize it.
///
/// Enumeration semantics deliberately MIRROR `buildReadJXA`: the same
/// absolute-path `Application(...)` targeting (the literal below must equal
/// `appleScriptString(musicAppPath)`; the pin test ties them) and the same
/// inclusion set — `Music.userPlaylists()`, which contains regular, smart,
/// and folder playlists (subscription playlists inherit `playlist`, not
/// `user playlist`, and are excluded) — so the browser's groups always agree
/// with what a subsequent audit's exact-name filter will find. `smart` and
/// `special kind` are cheap per-playlist properties (com.apple.Music.sdef:
/// `user playlist.smart`, `playlist.special kind`) exposed to annotate those
/// kinds; `tracks().length` counts the same tracks collection the read
/// script serializes. Playlist-level properties are read raw (no coercion),
/// like the read JXA's playlist block: a null/undefined anomaly surfaces as
/// a strict-parse rejection, never a silent default.
public func buildListPlaylistsJXA() -> String {
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
public func buildMergeApplyScript(
    plan: MergePlan,
    verifiedCopies: [PlaylistSnapshot],
    targetName: String
) throws -> String {
    // Fail closed on any mismatch between the plan and the verified copies
    // (music_bridge.py:1198-1200).
    if !scalarEqual(verifiedCopies, plan.copies) {
        throw MusicScriptBuilderError("verified copies do not match the merge plan copies")
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
