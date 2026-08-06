// DirectMutationSessionTests.swift
// MusicBridgeSession direct execution (Sergio, 2026-08-06): deletePlaylistDirect
// and renamePlaylistDirect are deliberately guard-free — one compile, one
// execute, no baseline listing, no readback. These tests pin exactly that
// command shape via FakeRunner (Tests/MusicBridgeTests/OrchestrationTestSupport.swift)
// and confirm a runner error propagates verbatim.

import Testing
import ConsolidatorCore
@testable import MusicBridge

@Suite("Direct mutation session methods")
struct DirectMutationSessionTests {

    @Test("deletePlaylistDirect compiles then executes the direct delete script and nothing else")
    func deleteCompilesAndExecutes() throws {
        let runner = FakeRunner(outputs: ["", "{\"status\":\"ok\",\"mutation\":\"delete\"}"])
        let session = MusicBridgeSession(runner: runner)
        try session.deletePlaylistDirect(persistentID: "SOLO000000000001")
        // Exactly two runner commands: .compileAppleScript then
        // .executeCompiledScript — no listing, no snapshot, no readback.
        #expect(runner.calls.count == 2)
        guard case .compileAppleScript(let script, _) = runner.calls[0] else {
            Issue.record("expected a compile command first"); return
        }
        #expect(script.contains("delete doomedPlaylist"))
        guard case .executeCompiledScript = runner.calls[1] else {
            Issue.record("expected an execute command second"); return
        }
    }

    @Test("renamePlaylistDirect propagates a script error verbatim")
    func renameErrorVerbatim() {
        let runner = FakeRunner(results: [
            .success(""),
            .failure(MusicCommandError("execution error: playlist persistent ID is absent — rescan and retry")),
        ])
        let session = MusicBridgeSession(runner: runner)
        #expect(throws: (any Error).self) {
            try session.renamePlaylistDirect(
                persistentID: "GONE000000000001", newName: "X"
            )
        }
    }
}
