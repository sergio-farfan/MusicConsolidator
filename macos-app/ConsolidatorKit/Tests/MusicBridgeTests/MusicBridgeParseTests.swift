// MusicBridgeParseTests.swift
// Ported orchestration read/parse cases from tests/test_music_bridge.py
// (MusicBridgeTests' snapshot cases and AllCopiesReadTests). Every expected
// error message below was verified against the reference in python3 first
// (see the M5 report). No script is ever executed: the FakeRunner replays
// canned payloads.

import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

@Suite("Snapshot parsing and read orchestration (ported)")
struct SnapshotParseTests {

    // test_snapshot_parses_complete_wire_payload_and_uses_read_only_jxa
    @Test("snapshot parses complete wire payload and uses read-only JXA")
    func parsesCompleteWirePayload() throws {
        let raw = try musicSnapshotFixtureText()
        let runner = FakeRunner(outputs: [raw])

        let snapshot = try MusicBridgeSession(runner: runner).snapshotPlaylist(name: "#Musica xTotal")

        #expect(snapshot.name == "#Musica xTotal")
        #expect(snapshot.persistentId == "PLAYLIST-123")
        #expect(snapshot.tracks.count == 2)
        #expect(snapshot.tracks[0].durationMs == 183456)
        #expect(snapshot.tracks[0].databaseId == 101)
        #expect(snapshot.tracks[0].cloudStatus == "matched")
        #expect(snapshot.tracks[0].isFileTrack == false)
        #expect(snapshot.tracks[1].durationMs == nil)
        #expect(snapshot.tracks[1].bitRateKbps == nil)
        #expect(snapshot.tracks[1].sampleRateHz == nil)
        #expect(snapshot.tracks[1].isFileTrack == true)
        #expect(runner.calls == [.readJXA(script: buildReadJXA(name: "#Musica xTotal"))])
    }

    // test_snapshot_rejects_zero_or_multiple_exact_name_matches
    @Test("snapshot rejects zero or multiple exact-name matches")
    func rejectsZeroOrMultipleMatches() {
        let payloads = [
            "{\"playlists\": []}",
            """
            {"playlists": [
                {"name": "#Musica xTotal", "persistent_id": "A", "tracks": []},
                {"name": "#Musica xTotal", "persistent_id": "B", "tracks": []}
            ]}
            """,
        ]
        for raw in payloads {
            expectThrowsByteEqualMessage(
                "expected exactly one user playlist named '#Musica xTotal'",
                context: "payload \(raw.prefix(30))"
            ) {
                _ = try MusicBridgeSession(runner: FakeRunner(outputs: [raw]))
                    .snapshotPlaylist(name: "#Musica xTotal")
            }
        }
    }

    // test_snapshot_does_not_accept_a_non_exact_name_from_runner
    @Test("snapshot does not accept a non-exact name from the runner")
    func rejectsNonExactName() {
        let raw = """
        {"playlists": [{"name": "#musica xtotal", "persistent_id": "A", "tracks": []}]}
        """
        expectThrowsByteEqualMessage(
            "expected exactly one user playlist named '#Musica xTotal'",
            context: "non-exact name"
        ) {
            _ = try MusicBridgeSession(runner: FakeRunner(outputs: [raw]))
                .snapshotPlaylist(name: "#Musica xTotal")
        }
    }

    // Strict parse failure messages (reference-verified in python3:
    // json.JSONDecodeError -> "Music returned invalid JSON", _require_mapping,
    // _require_list, and the duration type check).
    @Test("strict parse failures carry the reference's exact messages")
    func strictParseFailureMessages() {
        expectThrowsByteEqualMessage(
            "Music returned invalid JSON", context: "invalid JSON"
        ) {
            _ = try parseExactPlaylistSnapshot(raw: "not json", name: "X")
        }
        expectThrowsByteEqualMessage(
            "Music snapshot must be a JSON object", context: "top-level array"
        ) {
            _ = try parseExactPlaylistSnapshot(raw: "[]", name: "X")
        }
        expectThrowsByteEqualMessage(
            "playlists must be a JSON array", context: "playlists not a list"
        ) {
            _ = try parseExactPlaylistSnapshot(raw: "{\"playlists\": 3}", name: "X")
        }
        expectThrowsByteEqualMessage(
            "playlist tracks must be a JSON array", context: "tracks not a list"
        ) {
            _ = try parseExactPlaylistSnapshot(
                raw: "{\"playlists\": [{\"name\": \"X\", \"persistent_id\": \"P\", \"tracks\": 5}]}",
                name: "X"
            )
        }
        expectThrowsByteEqualMessage(
            "track duration must be a number or null", context: "duration typed wrong"
        ) {
            let raw = """
            {"playlists": [{"name": "X", "persistent_id": "P", "tracks": [
                {"source_index": 0, "database_id": 1, "persistent_id": "A",
                 "title": "T", "artist": "A", "album": "B", "duration": "x",
                 "kind": "K", "bit_rate": null, "sample_rate": null,
                 "cloud_status": "", "is_file_track": false}
            ]}]}
            """
            _ = try parseExactPlaylistSnapshot(raw: raw, name: "X")
        }
    }

    // The reference's parse_exact tolerates a playlist object without an "id"
    // key (the fixture payload in test_ensure_source_matches_rejects_track_drift
    // has none); verified in python3.
    @Test("exact-snapshot parse tolerates a missing playlist id key")
    func exactParseToleratesMissingId() throws {
        let raw = """
        {"playlists": [{"name": "Source", "persistent_id": "P", "tracks": []}]}
        """
        let snapshot = try parseExactPlaylistSnapshot(raw: raw, name: "Source")
        #expect(snapshot.persistentId == "P")
        #expect(snapshot.tracks.isEmpty)
    }
}

/// tests/test_music_bridge.py::AllCopiesReadTests._payload
func allCopiesPayload() -> String {
    """
    {"playlists": [
        {"id": 337666, "name": "Trance 2022", "persistent_id": "PID-B",
         "tracks": [
            {"source_index": 0, "database_id": 3, "persistent_id": "B0",
             "title": "Two", "artist": "Artist", "album": "Alb",
             "duration": 200.0, "kind": "Apple Music AAC audio file",
             "bit_rate": 256, "sample_rate": 44100,
             "cloud_status": "matched", "is_file_track": false}
         ]},
        {"id": 93534, "name": "Trance 2022", "persistent_id": "PID-A",
         "tracks": [
            {"source_index": 0, "database_id": 1, "persistent_id": "A0",
             "title": "One", "artist": "Artist", "album": "Alb",
             "duration": 180.0, "kind": "Apple Music AAC audio file",
             "bit_rate": 256, "sample_rate": 44100,
             "cloud_status": "matched", "is_file_track": false}
         ]}
    ]}
    """
}

@Suite("All-copies read orchestration (ported AllCopiesReadTests)")
struct AllCopiesReadPortTests {

    // test_parse_all_copies_orders_ascending_by_playlist_id
    @Test("parse_all_copies orders ascending by numeric playlist id")
    func ordersAscendingByPlaylistId() throws {
        let copies = try parseAllCopies(raw: allCopiesPayload(), name: "Trance 2022")
        #expect(copies.map(\.persistentId) == ["PID-A", "PID-B"])
        #expect(copies[0].tracks[0].persistentId == "A0")
    }

    // test_snapshot_all_copies_uses_read_only_jxa
    @Test("snapshot_all_copies uses the read-only JXA")
    func snapshotAllCopiesUsesReadOnlyJXA() throws {
        let runner = FakeRunner(outputs: [allCopiesPayload()])
        let copies = try MusicBridgeSession(runner: runner).snapshotAllCopies(name: "Trance 2022")
        #expect(copies.count == 2)
        #expect(runner.calls == [.readJXA(script: buildReadJXA(name: "Trance 2022"))])
    }

    // test_parse_all_copies_rejects_zero_matches
    @Test("parse_all_copies rejects zero matches")
    func rejectsZeroMatches() {
        expectThrowsByteEqualMessage(
            "expected at least one user playlist named 'Trance 2022'",
            context: "zero copies"
        ) {
            _ = try parseAllCopies(raw: "{\"playlists\": []}", name: "Trance 2022")
        }
    }
}
