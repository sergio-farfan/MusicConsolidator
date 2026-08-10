// ModelsTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Codable round-trip and strict-decode (reject unknown/missing keys) tests for
// TrackSnapshot / PlaylistSnapshot, mirroring the guarantees Python's
// `_require_exact_fields` enforces in apple_music_consolidator/models.py.

import Foundation
import Testing
@testable import ConsolidatorCore

private func makeTrack(
    sourceIndex: Int = 0,
    databaseId: Int = 1,
    persistentId: String = "ABC",
    title: String = "Rock\u{2014}Song",
    artist: String = "Björk",
    album: String = "Album",
    durationMs: Int? = 183000,
    kind: String = "Apple Music AAC audio file",
    bitRateKbps: Int? = 256,
    sampleRateHz: Int? = 44100,
    cloudStatus: String = "",
    isFileTrack: Bool = false
) -> TrackSnapshot {
    TrackSnapshot(
        sourceIndex: sourceIndex,
        databaseId: databaseId,
        persistentId: persistentId,
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        kind: kind,
        bitRateKbps: bitRateKbps,
        sampleRateHz: sampleRateHz,
        cloudStatus: cloudStatus,
        isFileTrack: isFileTrack
    )
}

private let trackJSONKeys = [
    "source_index", "database_id", "persistent_id", "title", "artist", "album",
    "duration_ms", "kind", "bit_rate_kbps", "sample_rate_hz", "cloud_status", "is_file_track",
]

private func trackJSONObject(overrides: [String: Any] = [:], omitting: Set<String> = []) -> [String: Any] {
    var object: [String: Any] = [
        "source_index": 0,
        "database_id": 1,
        "persistent_id": "ABC",
        "title": "Rock Song",
        "artist": "Björk",
        "album": "Album",
        "duration_ms": 183000,
        "kind": "Apple Music AAC audio file",
        "bit_rate_kbps": 256,
        "sample_rate_hz": 44100,
        "cloud_status": "",
        "is_file_track": false,
    ]
    for (key, value) in overrides { object[key] = value }
    for key in omitting { object.removeValue(forKey: key) }
    return object
}

@Suite("TrackSnapshot / PlaylistSnapshot Codable round-trip")
struct ModelsCodableRoundTripTests {

    @Test("TrackSnapshot round-trips through JSON with Python-shaped keys")
    func trackSnapshotRoundTrips() throws {
        let track = makeTrack()
        let encoder = JSONEncoder()
        let data = try encoder.encode(track)

        // Confirm the wire format uses the exact Python-reference key names.
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let objectKeys: Set<String> = Set(object?.keys.map { $0 } ?? [])
        #expect(objectKeys == Set(trackJSONKeys))

        let decoded = try JSONDecoder().decode(TrackSnapshot.self, from: data)
        #expect(decoded == track)
    }

    @Test("TrackSnapshot round-trips with nil optional fields")
    func trackSnapshotRoundTripsWithNils() throws {
        let track = makeTrack(durationMs: nil, bitRateKbps: nil, sampleRateHz: nil)
        let data = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(TrackSnapshot.self, from: data)
        #expect(decoded == track)
    }

    @Test("PlaylistSnapshot round-trips with nested tracks")
    func playlistSnapshotRoundTrips() throws {
        let playlist = PlaylistSnapshot(
            name: "Trance 2022",
            persistentId: "PID-A",
            tracks: [makeTrack(sourceIndex: 0), makeTrack(sourceIndex: 1, persistentId: "DEF")]
        )
        let data = try JSONEncoder().encode(playlist)
        let decoded = try JSONDecoder().decode(PlaylistSnapshot.self, from: data)
        #expect(decoded == playlist)
    }

    @Test("Equatable/Hashable are derived correctly for equal and unequal tracks")
    func equatableAndHashable() {
        let a = makeTrack()
        let b = makeTrack()
        var c = makeTrack()
        c.title = "Different"

        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }
}

@Suite("TrackSnapshot strict decode (reject unknown/missing keys)")
struct ModelsStrictDecodeTests {

    @Test("decoding succeeds with exactly the expected fields")
    func decodesWithExactFields() throws {
        let data = try JSONSerialization.data(withJSONObject: trackJSONObject())
        let decoded = try JSONDecoder().decode(TrackSnapshot.self, from: data)
        #expect(decoded.persistentId == "ABC")
    }

    @Test("decoding throws when the payload has an unexpected extra field")
    func decodingThrowsOnUnknownField() throws {
        let data = try JSONSerialization.data(
            withJSONObject: trackJSONObject(overrides: ["surprise": 1])
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TrackSnapshot.self, from: data)
        }
    }

    @Test("decoding throws when the payload is missing a required field")
    func decodingThrowsOnMissingField() throws {
        let data = try JSONSerialization.data(
            withJSONObject: trackJSONObject(omitting: ["cloud_status"])
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TrackSnapshot.self, from: data)
        }
    }

    @Test("decoding throws when the payload has both a missing and an unknown field")
    func decodingThrowsOnMissingAndUnknownField() throws {
        let data = try JSONSerialization.data(
            withJSONObject: trackJSONObject(overrides: ["surprise": 1], omitting: ["kind"])
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TrackSnapshot.self, from: data)
        }
    }

    @Test("PlaylistSnapshot decode also rejects an unknown top-level field")
    func playlistDecodeRejectsUnknownField() throws {
        let object: [String: Any] = [
            "name": "Trance 2022",
            "persistent_id": "PID-A",
            "tracks": [trackJSONObject()],
            "surprise": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PlaylistSnapshot.self, from: data)
        }
    }

    @Test("PlaylistSnapshot decode also rejects a missing top-level field")
    func playlistDecodeRejectsMissingField() throws {
        let object: [String: Any] = [
            "name": "Trance 2022",
            "tracks": [trackJSONObject()],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PlaylistSnapshot.self, from: data)
        }
    }
}
