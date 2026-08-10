// MutationScriptBuilder.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// The second write class (spec B1): guarded playlist-mutation writers,
// beside — never inside — the create+duplicate writers in
// MusicScriptBuilder.swift. Every emitted script revalidates the pinned
// playlist in the same compiled execution immediately before EXACTLY ONE
// mutation statement and fails closed on any drift. Pinning is by persistent
// ID only — never name, never index (names are non-unique by design in this
// library; playlist `id` is session-scoped).
//
// Reused from MusicScriptBuilder.swift (same module, internal — no
// visibility changes): `appleScriptString`, `textCodePointHandlerLines`,
// `runtimeLocalDeclarationLines`, `exactPlaylistLookup`, `musicAppPath`.
// All AGENTS.md AppleScript rules apply: absolute Music path, every
// untrusted value escaped, compact PUA-delimited payload (no per-track
// unrolling), code-point comparison, chunked `local` declarations.

import Foundation

public enum MutationScriptBuilder {

    /// Cleanup-only in-writer re-verification of the merged target: exact
    /// name (code-point), track count, ordered track persistent IDs — all
    /// re-proven in the same compiled execution as the delete (spec B3).
    public struct TargetGuardPayload: Equatable, Sendable {
        public let name: String
        public let orderedTrackPersistentIDs: [String]

        public init(name: String, orderedTrackPersistentIDs: [String]) {
            self.name = name
            self.orderedTrackPersistentIDs = orderedTrackPersistentIDs
        }
    }

    /// Runtime variables of the delete writer, declared `local` in chunks of
    /// 5 (same no-save-back rationale as `applyScriptLocals`). Target-guard
    /// names are declared unconditionally — an unused `local` is inert and
    /// keeps the emission deterministic.
    static let deleteScriptLocals: [String] = [
        "expectedPlaylistName", "expectedPlaylistPersistentID", "expectedTrackCount",
        "expectedTrackPIDPayload", "expectedPIDDelimiter", "expectedTargetName",
        "expectedTargetTrackCount", "expectedTargetPIDPayload", "savedTextItemDelimiters",
        "expectedTrackPIDs", "expectedTargetPIDs", "errorMessage", "errorNumber",
        "matchedPlaylists", "candidatePlaylist", "candidatePID", "doomedPlaylist",
        "liveTextValue", "expectedTextValue", "doomedTracks", "trackPosition",
        "targetPlaylists", "candidateName", "targetPlaylist", "targetTracks",
        "targetPosition",
    ]

    /// First BMP private-use scalar (U+E000..<U+F900) absent from every
    /// guarded persistent ID — `encodeExpectedSourcePayload`'s delimiter
    /// policy, needing one delimiter (flat PID lists), not two.
    static func firstFreePUAScalar(excluding values: [String]) -> Unicode.Scalar? {
        var usedScalars = Set<Unicode.Scalar>()
        for value in values {
            usedScalars.formUnion(value.unicodeScalars)
        }
        var codePoint: UInt32 = 0xE000
        while codePoint < 0xF900 {
            let scalar = Unicode.Scalar(codePoint)!
            if !usedScalars.contains(scalar) {
                return scalar
            }
            codePoint += 1
        }
        return nil
    }

    /// Fail-closed degenerate script: exactly one top-level `error`
    /// statement — no tell, no mutation verb — so a pathological input can
    /// never reach Music. The builder is contract-fixed as non-throwing;
    /// this is how it still refuses.
    static func failClosedScript(_ message: String) -> String {
        "error " + appleScriptString(message) + "\n"
    }

    /// Non-tell payload parse: split a PUA-delimited PID payload into a
    /// list under the same try/considering/text-item-delimiters discipline
    /// as the apply writers. The CALLER wraps all parses in one
    /// save/restore-on-error block.
    static func pidPayloadParseLines(
        payloadVariable: String,
        countVariable: String,
        listVariable: String,
        mismatchMessage: String
    ) -> [String] {
        [
            "    if \(countVariable) is 0 then",
            "        set \(listVariable) to {}",
            "    else",
            "        considering case, diacriticals, hyphens, punctuation and white space",
            "            set AppleScript's text item delimiters to {expectedPIDDelimiter}",
            "            set \(listVariable) to every text item of \(payloadVariable)",
            "        end considering",
            "    end if",
            "    if (count of \(listVariable)) is not \(countVariable) then error \(appleScriptString(mismatchMessage))",
        ]
    }

    /// Ordered-PID guard: walk a live track list already fetched into
    /// `tracksVariable` and compare each persistent ID (code-point,
    /// missing value coerced to "") against the parsed payload list.
    static func orderedPIDGuardLines(
        tracksVariable: String,
        expectedListVariable: String,
        countVariable: String,
        positionVariable: String,
        errorLabel: String
    ) -> [String] {
        [
            "    repeat with \(positionVariable) from 1 to \(countVariable)",
            "        set liveTextValue to persistent ID of (item \(positionVariable) of \(tracksVariable))",
            "        if liveTextValue is missing value then set liveTextValue to \"\"",
            "        set expectedTextValue to item \(positionVariable) of \(expectedListVariable)",
            "        if (my textCodePointsMatch(expectedTextValue, liveTextValue)) is not true then error (\"\(errorLabel) track persistent ID changed at position \" & \(positionVariable))",
            "    end repeat",
        ]
    }

    /// The PID-pinned lookup + in-writer revalidation block shared verbatim
    /// by every guarded mutation writer (spec B1/B5): absent/duplicate
    /// persistent ID refusal, exact-name code-point revalidation, track-count
    /// check, then the ordered track persistent ID loop. Emitted immediately
    /// after the writer's `tell application` line and immediately before its
    /// single mutation verb. The pinned playlist local is `doomedPlaylist`
    /// for every writer that uses this block — including rename — so this
    /// function's output (and therefore `buildDeleteScript`'s, which now
    /// calls it) never changes regardless of which writer calls it.
    static func pinnedPlaylistGuardLines() -> [String] {
        [
            "    set matchedPlaylists to {}",
            "    repeat with candidatePlaylist in every user playlist",
            "        set candidatePID to persistent ID of candidatePlaylist",
            "        if candidatePID is missing value then set candidatePID to \"\"",
            "        if (my textCodePointsMatch(expectedPlaylistPersistentID, candidatePID)) is true then",
            "            set end of matchedPlaylists to contents of candidatePlaylist",
            "        end if",
            "    end repeat",
            "    if (count of matchedPlaylists) is 0 then error \"expected playlist persistent ID is absent\"",
            "    if (count of matchedPlaylists) is not 1 then error \"expected playlist persistent ID is duplicated\"",
            "    set doomedPlaylist to item 1 of matchedPlaylists",
            "",
            "    set liveTextValue to name of doomedPlaylist",
            "    if liveTextValue is missing value then set liveTextValue to \"\"",
            "    if (my textCodePointsMatch(expectedPlaylistName, liveTextValue)) is not true then error \"pinned playlist name changed\"",
            "    set doomedTracks to every track of doomedPlaylist",
            "    if (count of doomedTracks) is not expectedTrackCount then error \"pinned playlist track count changed\"",
        ] + orderedPIDGuardLines(
            tracksVariable: "doomedTracks",
            expectedListVariable: "expectedTrackPIDs",
            countVariable: "expectedTrackCount",
            positionVariable: "trackPosition",
            errorLabel: "pinned playlist"
        )
    }

    /// AppleScript delete writer: PID-pinned lookup, in-writer revalidation
    /// of name, count, and ordered track persistent IDs (plus the optional
    /// cleanup target guard) — all BEFORE the single `delete` statement.
    public static func buildDeleteScript(
        expectedName: String,
        expectedPersistentID: String,
        expectedTrackPersistentIDs: [String],
        targetGuard: TargetGuardPayload?
    ) -> String {
        var guardedPIDs = expectedTrackPersistentIDs
        if let targetGuard {
            guardedPIDs += targetGuard.orderedTrackPersistentIDs
        }
        guard let delimiterScalar = firstFreePUAScalar(excluding: guardedPIDs) else {
            return failClosedScript(
                "expected track persistent IDs exhaust the guarded payload delimiters"
            )
        }
        let delimiter = String(Character(delimiterScalar))
        let payload = expectedTrackPersistentIDs.joined(separator: delimiter)

        var lines: [String] = []
        lines.append(contentsOf: textCodePointHandlerLines())
        lines.append("")
        lines.append(contentsOf: runtimeLocalDeclarationLines(deleteScriptLocals))
        lines.append("")
        lines.append(contentsOf: [
            "set expectedPlaylistName to \(appleScriptString(expectedName))",
            "set expectedPlaylistPersistentID to \(appleScriptString(expectedPersistentID))",
            "set expectedTrackCount to \(expectedTrackPersistentIDs.count)",
            "set expectedTrackPIDPayload to \(appleScriptString(payload))",
            "set expectedPIDDelimiter to \(appleScriptString(delimiter))",
        ])
        if let targetGuard {
            let targetPayload = targetGuard.orderedTrackPersistentIDs.joined(separator: delimiter)
            lines.append(contentsOf: [
                "set expectedTargetName to \(appleScriptString(targetGuard.name))",
                "set expectedTargetTrackCount to \(targetGuard.orderedTrackPersistentIDs.count)",
                "set expectedTargetPIDPayload to \(appleScriptString(targetPayload))",
            ])
        }
        lines.append(contentsOf: [
            "",
            "set savedTextItemDelimiters to AppleScript's text item delimiters",
            "try",
        ])
        lines.append(contentsOf: pidPayloadParseLines(
            payloadVariable: "expectedTrackPIDPayload",
            countVariable: "expectedTrackCount",
            listVariable: "expectedTrackPIDs",
            mismatchMessage: "internal expected track persistent ID payload count mismatch"
        ))
        if targetGuard != nil {
            lines.append(contentsOf: pidPayloadParseLines(
                payloadVariable: "expectedTargetPIDPayload",
                countVariable: "expectedTargetTrackCount",
                listVariable: "expectedTargetPIDs",
                mismatchMessage: "internal expected target persistent ID payload count mismatch"
            ))
        }
        lines.append(contentsOf: [
            "    set AppleScript's text item delimiters to savedTextItemDelimiters",
            "on error errorMessage number errorNumber",
            "    set AppleScript's text item delimiters to savedTextItemDelimiters",
            "    error errorMessage number errorNumber",
            "end try",
            "",
            "tell application \(appleScriptString(musicAppPath))",
        ])
        lines.append(contentsOf: pinnedPlaylistGuardLines())
        if targetGuard != nil {
            lines.append("")
            lines.append(contentsOf: exactPlaylistLookup(
                variable: "targetPlaylists", requestedName: "expectedTargetName"
            ))
            lines.append(contentsOf: [
                "    if (count of targetPlaylists) is not 1 then error \"expected merged target user playlist is not uniquely present\"",
                "    set targetPlaylist to item 1 of targetPlaylists",
                "    set targetTracks to every track of targetPlaylist",
                "    if (count of targetTracks) is not expectedTargetTrackCount then error \"merged target track count changed\"",
            ])
            lines.append(contentsOf: orderedPIDGuardLines(
                tracksVariable: "targetTracks",
                expectedListVariable: "expectedTargetPIDs",
                countVariable: "expectedTargetTrackCount",
                positionVariable: "targetPosition",
                errorLabel: "merged target"
            ))
        }
        let success = "{\"status\":\"ok\",\"mutation\":\"delete\"}"
        lines.append(contentsOf: [
            "",
            "    delete doomedPlaylist",
            "    return \(appleScriptString(success))",
            "end tell",
            "",
        ])
        return lines.joined(separator: "\n")
    }

    // MARK: - rename writer (spec B1/B5)

    /// Runtime variables of the rename writer, declared `local` in chunks of
    /// 5 (same discipline as `deleteScriptLocals`). No target-guard concept
    /// exists for rename (spec B5: collision checking and any target refusal
    /// are gate-level, not builder concerns) — one extra local,
    /// `newPlaylistName`, replaces the delete writer's target-specific set.
    static let renameScriptLocals: [String] = [
        "expectedPlaylistName", "expectedPlaylistPersistentID", "expectedTrackCount",
        "expectedTrackPIDPayload", "expectedPIDDelimiter", "newPlaylistName",
        "savedTextItemDelimiters", "expectedTrackPIDs", "errorMessage", "errorNumber",
        "matchedPlaylists", "candidatePlaylist", "candidatePID", "doomedPlaylist",
        "liveTextValue", "expectedTextValue", "doomedTracks", "trackPosition",
    ]

    /// AppleScript rename writer: the exact same PID-pinned lookup and
    /// in-writer revalidation as `buildDeleteScript` — via the same
    /// `pinnedPlaylistGuardLines()` call, never a copy of its lines — then
    /// exactly one `set name of doomedPlaylist to newPlaylistName` statement.
    /// Pure text function: no clocks, no randomness, every untrusted value
    /// (including `newName`) passes through `appleScriptString`.
    public static func buildRenameScript(
        expectedName: String,
        expectedPersistentID: String,
        expectedTrackPersistentIDs: [String],
        newName: String
    ) -> String {
        guard let delimiterScalar = firstFreePUAScalar(excluding: expectedTrackPersistentIDs) else {
            return failClosedScript(
                "expected track persistent IDs exhaust the guarded payload delimiters"
            )
        }
        let delimiter = String(Character(delimiterScalar))
        let payload = expectedTrackPersistentIDs.joined(separator: delimiter)

        var lines: [String] = []
        lines.append(contentsOf: textCodePointHandlerLines())
        lines.append("")
        lines.append(contentsOf: runtimeLocalDeclarationLines(renameScriptLocals))
        lines.append("")
        lines.append(contentsOf: [
            "set expectedPlaylistName to \(appleScriptString(expectedName))",
            "set expectedPlaylistPersistentID to \(appleScriptString(expectedPersistentID))",
            "set expectedTrackCount to \(expectedTrackPersistentIDs.count)",
            "set expectedTrackPIDPayload to \(appleScriptString(payload))",
            "set expectedPIDDelimiter to \(appleScriptString(delimiter))",
            "set newPlaylistName to \(appleScriptString(newName))",
        ])
        lines.append(contentsOf: [
            "",
            "set savedTextItemDelimiters to AppleScript's text item delimiters",
            "try",
        ])
        lines.append(contentsOf: pidPayloadParseLines(
            payloadVariable: "expectedTrackPIDPayload",
            countVariable: "expectedTrackCount",
            listVariable: "expectedTrackPIDs",
            mismatchMessage: "internal expected track persistent ID payload count mismatch"
        ))
        lines.append(contentsOf: [
            "    set AppleScript's text item delimiters to savedTextItemDelimiters",
            "on error errorMessage number errorNumber",
            "    set AppleScript's text item delimiters to savedTextItemDelimiters",
            "    error errorMessage number errorNumber",
            "end try",
            "",
            "tell application \(appleScriptString(musicAppPath))",
        ])
        lines.append(contentsOf: pinnedPlaylistGuardLines())
        let success = "{\"status\":\"ok\",\"mutation\":\"rename\"}"
        lines.append(contentsOf: [
            "",
            "    set name of doomedPlaylist to newPlaylistName",
            "    return \(appleScriptString(success))",
            "end tell",
            "",
        ])
        return lines.joined(separator: "\n")
    }
}
