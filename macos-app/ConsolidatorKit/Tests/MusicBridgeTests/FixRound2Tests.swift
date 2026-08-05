// FixRound2Tests.swift
// Regression pins for the M5 fix round 2 finding: the wire layer accepted
// JSON that json.loads rejects (trailing commas, document-leading BOM) and
// resolved duplicate object keys FIRST-wins where Python resolves LAST-wins
// — an accept-path value divergence on identical wire bytes. The fix is a
// strict syntax pre-pass (ConsolidatorCore's StrictJSONScanner, the M3
// loader precedent) that rejects all of it outright; every rejection is
// classified exactly as the reference classifies wire syntax errors —
// python3-verified: trailing commas and a leading BOM raise
// json.JSONDecodeError, which parse_exact_playlist_snapshot wraps as
// ValueError "Music returned invalid JSON". Duplicate-key rejection is the
// sanctioned fail-closed resolution of the winner flip (the reference accepts
// last-wins; outright rejection matches the plan loader's documented
// deviation), same error class.

import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

private func expectInvalidWireJSON(
    _ raw: String,
    context: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    expectThrowsByteEqualMessage(
        "Music returned invalid JSON",
        context: context,
        sourceLocation: sourceLocation
    ) {
        _ = try parseExactPlaylistSnapshot(raw: raw, name: "Source")
    }
}

@Suite("Fix round 2 — strict wire syntax pre-pass")
struct StrictWireSyntaxTests {

    // The review's repro: Swift kept the FIRST "playlists" (empty) and
    // rejected with "expected exactly one…" where the reference parses the
    // LAST (valid) one. Resolution: outright rejection, reference error class.
    @Test("duplicate top-level playlists keys are rejected outright")
    func duplicateTopLevelKeyRejected() {
        let raw = """
        {"playlists": [], "playlists": [
            {"id": 7, "name": "Source", "persistent_id": "P", "tracks": []}
        ]}
        """
        expectInvalidWireJSON(raw, context: "duplicate playlists key")
    }

    // Nested duplicate inside a playlist object.
    @Test("a duplicate playlist name key is rejected outright")
    func duplicatePlaylistKeyRejected() {
        let raw = """
        {"playlists": [
            {"id": 7, "name": "Other", "name": "Source", "persistent_id": "P", "tracks": []}
        ]}
        """
        expectInvalidWireJSON(raw, context: "duplicate playlist name key")
    }

    // The review's value-flip repro at track depth: Swift parsed
    // title="first" where Python parses "second".
    @Test("a duplicate track title key is rejected outright")
    func duplicateTrackKeyRejected() {
        let raw = """
        {"playlists": [{"id": 7, "name": "Source", "persistent_id": "P", "tracks": [
            {"source_index": 0, "database_id": 1, "persistent_id": "ABC",
             "title": "first", "title": "second", "artist": "A", "album": "B",
             "duration": 183, "kind": "K", "bit_rate": 256,
             "sample_rate": 44100, "cloud_status": "", "is_file_track": false}
        ]}]}
        """
        expectInvalidWireJSON(raw, context: "duplicate track title key")
    }

    // Reference: json.loads raises on trailing commas -> "Music returned
    // invalid JSON" (python3-verified for both shapes).
    @Test("object and array trailing commas are rejected like the reference")
    func trailingCommasRejected() {
        expectInvalidWireJSON("{\"playlists\": [],}", context: "object trailing comma")
        expectInvalidWireJSON("{\"playlists\": [1,]}", context: "array trailing comma")
    }

    // Reference: json.loads raises "Unexpected UTF-8 BOM" -> wrapped as
    // "Music returned invalid JSON" (python3-verified).
    @Test("a document-leading BOM is rejected like the reference")
    func leadingBOMRejected() {
        let raw = "\u{FEFF}{\"playlists\": []}"
        expectInvalidWireJSON(raw, context: "leading BOM")
    }

    // The pre-pass must not itself strip or reject U+FEFF INSIDE strings —
    // the F1 preservation contract survives (raw and escaped forms).
    @Test("the pre-pass preserves U+FEFF inside wire strings")
    func prePassKeepsFEFFInStrings() throws {
        let raw = """
        {"playlists": [{"id": 7, "name": "Source", "persistent_id": "P", "tracks": [
            {"source_index": 0, "database_id": 1, "persistent_id": "\u{FEFF}ABC",
             "title": "\\uFEFFAbc", "artist": "A", "album": "B",
             "duration": 183, "kind": "K", "bit_rate": 256,
             "sample_rate": 44100, "cloud_status": "", "is_file_track": false}
        ]}]}
        """
        let snapshot = try parseExactPlaylistSnapshot(raw: raw, name: "Source")
        expectByteEqual(snapshot.tracks[0].title, "\u{FEFF}Abc", context: "escaped FEFF title")
        expectByteEqual(snapshot.tracks[0].persistentId, "\u{FEFF}ABC", context: "raw FEFF pid")
    }
}
