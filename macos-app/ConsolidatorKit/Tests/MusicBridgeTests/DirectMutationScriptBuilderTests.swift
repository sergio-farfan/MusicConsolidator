// DirectMutationScriptBuilderTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
//
// Tests/MusicBridgeTests/DirectMutationScriptBuilderTests.swift
// Direct mutations (Sergio, 2026-08-06): minimal PID-pinned writers —
// lookup + ONE mutation statement, deliberately NO revalidation guards.
import Testing
@testable import MusicBridge

@Suite("Direct mutation script builder")
struct DirectMutationScriptBuilderTests {

    @Test("direct delete: PID-pinned lookup, one delete, no revalidation guards")
    func directDeleteShape() {
        let script = DirectMutationScriptBuilder.buildDirectDeleteScript(
            persistentID: "D438389587678F55"
        )
        #expect(script.contains("set expectedPlaylistPersistentID to \"D438389587678F55\""))
        #expect(script.contains("repeat with candidatePlaylist in every user playlist"))
        #expect(script.contains("my textCodePointsMatch(expectedPlaylistPersistentID, candidatePID)"))
        #expect(script.contains("tell application \"/System/Applications/Music.app\""))
        // Exactly one mutation statement.
        #expect(script.components(separatedBy: "delete doomedPlaylist").count == 2)
        // The guarded writer's revalidation is deliberately absent.
        #expect(!script.contains("pinned playlist name changed"))
        #expect(!script.contains("expectedTrackCount"))
        #expect(!script.contains("expectedTargetName"))
    }

    @Test("direct delete: hostile PID is escaped, lookup fails closed on 0 or >1 matches")
    func directDeleteEscaping() {
        let script = DirectMutationScriptBuilder.buildDirectDeleteScript(
            persistentID: "A\"B\\C"
        )
        #expect(script.contains("set expectedPlaylistPersistentID to \"A\\\"B\\\\C\""))
        #expect(script.contains("if (count of matchedPlaylists) is 0 then error"))
        #expect(script.contains("if (count of matchedPlaylists) is not 1 then error"))
    }

    @Test("direct rename: sets the escaped new name on the matched playlist")
    func directRenameShape() {
        let script = DirectMutationScriptBuilder.buildDirectRenameScript(
            persistentID: "SOLO000000000001",
            newName: "New \"Name\" \\ done"
        )
        #expect(script.contains("set newPlaylistName to \"New \\\"Name\\\" \\\\ done\""))
        #expect(script.contains("set name of doomedPlaylist to newPlaylistName"))
        #expect(script.components(separatedBy: "set name of doomedPlaylist").count == 2)
        #expect(!script.contains("delete doomedPlaylist"))
    }
}
