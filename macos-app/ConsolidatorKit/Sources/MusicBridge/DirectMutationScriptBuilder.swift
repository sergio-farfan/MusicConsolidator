// Sources/MusicBridge/DirectMutationScriptBuilder.swift
// Direct user-responsible mutations (Sergio, 2026-08-06, superseding the
// 2026-08-03 guarded amendment): PID-pinned lookup + exactly one mutation
// statement. NO revalidation, NO target guard, NO readback — speed is the
// contract now; the confirm dialog is the only gate. The lookup itself
// keeps the AGENTS.md rules (code-point PID comparison, escaped literals,
// absolute app path) because they are correctness, not ceremony.

import Foundation

public enum DirectMutationScriptBuilder {

    static let directLocals: [String] = [
        "expectedPlaylistPersistentID", "newPlaylistName", "matchedPlaylists",
        "candidatePlaylist", "candidatePID", "doomedPlaylist",
    ]

    /// Shared PID lookup: same matching discipline as the guarded writer's
    /// `pinnedPlaylistGuardLines` (code-point comparison over every user
    /// playlist — folders and smart playlists included), minus every
    /// revalidation guard.
    static func directLookupLines() -> [String] {
        [
            "    set matchedPlaylists to {}",
            "    repeat with candidatePlaylist in every user playlist",
            "        set candidatePID to persistent ID of candidatePlaylist",
            "        if candidatePID is missing value then set candidatePID to \"\"",
            "        if (my textCodePointsMatch(expectedPlaylistPersistentID, candidatePID)) is true then",
            "            set end of matchedPlaylists to contents of candidatePlaylist",
            "        end if",
            "    end repeat",
            "    if (count of matchedPlaylists) is 0 then error \"playlist persistent ID is absent — rescan and retry\"",
            "    if (count of matchedPlaylists) is not 1 then error \"playlist persistent ID is duplicated\"",
            "    set doomedPlaylist to item 1 of matchedPlaylists",
        ]
    }

    public static func buildDirectDeleteScript(persistentID: String) -> String {
        var lines: [String] = []
        lines.append(contentsOf: textCodePointHandlerLines())
        lines.append("")
        lines.append(contentsOf: runtimeLocalDeclarationLines(directLocals))
        lines.append("")
        lines.append("set expectedPlaylistPersistentID to \(appleScriptString(persistentID))")
        lines.append("")
        lines.append("tell application \(appleScriptString(musicAppPath))")
        lines.append(contentsOf: directLookupLines())
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

    public static func buildDirectRenameScript(
        persistentID: String, newName: String
    ) -> String {
        var lines: [String] = []
        lines.append(contentsOf: textCodePointHandlerLines())
        lines.append("")
        lines.append(contentsOf: runtimeLocalDeclarationLines(directLocals))
        lines.append("")
        lines.append("set expectedPlaylistPersistentID to \(appleScriptString(persistentID))")
        lines.append("set newPlaylistName to \(appleScriptString(newName))")
        lines.append("")
        lines.append("tell application \(appleScriptString(musicAppPath))")
        lines.append(contentsOf: directLookupLines())
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
