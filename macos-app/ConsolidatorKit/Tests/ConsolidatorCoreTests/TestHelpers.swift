// TestHelpers.swift
// Shared fixture builder mirroring tests/helpers.py `track()` — identical
// defaults so ported cases read one-to-one against the Python reference implementation tests.

import Foundation
@testable import ConsolidatorCore

func track(
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
