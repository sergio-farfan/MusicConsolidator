// NormalizeGoldenTests.swift
// Golden-fixture parity tests: assert the Swift port matches the Python reference implementation
// (apple_music_consolidator.normalize) exactly, using fixtures exported by
// macos-app/golden/generate_golden.py straight from the Python implementation.

import Foundation
import Testing
@testable import ConsolidatorCore

/// Resolves a path under macos-app/golden/ relative to this source file's
/// location on disk (macos-app/ConsolidatorKit/Tests/ConsolidatorCoreTests/…),
/// so the golden fixtures can be loaded without a SwiftPM `resources:` bundle.
private func goldenFileURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // -> .../Tests/ConsolidatorCoreTests/ (drops the .swift filename)
        .deletingLastPathComponent() // -> .../Tests/
        .deletingLastPathComponent() // -> .../ConsolidatorKit/
        .deletingLastPathComponent() // -> .../macos-app/
        .appendingPathComponent("golden")
        .appendingPathComponent(name)
}

private struct NormalizeCase: Decodable {
    let input: String
    let expected: String
}

private struct DurationCase: Decodable {
    let seconds: Double?
    let ms: Int?
}

private func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(T.self, from: data)
}

/// Render a string as its Unicode scalar sequence ("U+0043 U+0061 …") so any
/// golden mismatch reports the exact code points on both sides.
private func codePoints(_ value: String) -> String {
    value.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
}

@Suite("Normalize golden fixture parity")
struct NormalizeGoldenTests {

    @Test("normalizeText matches the Python reference implementation scalar-for-scalar for every golden case")
    func normalizeTextMatchesGolden() throws {
        let cases = try loadJSON([NormalizeCase].self, from: goldenFileURL("normalize.json"))
        #expect(!cases.isEmpty)
        for testCase in cases {
            let actual = normalizeText(testCase.input)
            // Compare Unicode scalars, NOT Swift String `==`: String equality
            // uses canonical equivalence and would mask NFC-vs-NFD divergences,
            // but the ported contract is byte-for-byte parity with the reference.
            #expect(
                Array(actual.unicodeScalars) == Array(testCase.expected.unicodeScalars),
                """
                normalizeText diverged from the Python reference implementation
                  input:    \(codePoints(testCase.input)) (\(String(reflecting: testCase.input)))
                  actual:   \(codePoints(actual))
                  expected: \(codePoints(testCase.expected))
                """
            )
        }
    }

    @Test("durationToMs matches the Python reference implementation for every golden case, including half-to-even ties")
    func durationToMsMatchesGolden() throws {
        let cases = try loadJSON([DurationCase].self, from: goldenFileURL("duration.json"))
        #expect(!cases.isEmpty)
        for testCase in cases {
            #expect(
                durationToMs(testCase.seconds) == testCase.ms,
                "durationToMs(\(String(describing: testCase.seconds))) diverged from the Python reference implementation"
            )
        }
    }
}

/// Specific cases ported from tests/test_normalize.py (the Python reference implementation's own
/// unit tests), kept alongside the golden-fixture sweep for readability.
@Suite("Normalize — ported cases from tests/test_normalize.py")
struct NormalizePythonPortedTests {

    @Test
    func preservesAccentsButNormalizesCaseSpaceAndDash() {
        #expect(normalizeText("  Björk—Song  ") == "björk-song")
        #expect(normalizeText("Bjork—Song") == "bjork-song")
    }

    @Test
    func treatsCurlyAndStraightDoubleQuotesAsEquivalent() {
        #expect(normalizeText("\u{201C}Björk\u{201D} — Song") == normalizeText("\"Björk\" — Song"))
    }

    @Test
    func durationToMsRoundsSecondsToNearestMillisecond() {
        #expect(durationToMs(nil) == nil)
        #expect(durationToMs(183.0004) == 183000)
        #expect(durationToMs(183.0006) == 183001)
    }

    @Test
    func semanticKeyRequiresTitleArtistAndExactDuration() {
        let base = TrackSnapshot(
            sourceIndex: 0,
            databaseId: 1,
            persistentId: "ABC",
            title: "Rock—Song",
            artist: "Björk",
            album: "Album",
            durationMs: 183000,
            kind: "Apple Music AAC audio file",
            bitRateKbps: 256,
            sampleRateHz: 44100,
            cloudStatus: "",
            isFileTrack: false
        )

        let key = semanticKey(base)
        #expect(key?.title == "rock-song")
        #expect(key?.artist == "björk")
        #expect(key?.durationMs == 183000)

        var missingArtist = base
        missingArtist.artist = ""
        #expect(semanticKey(missingArtist) == nil)

        var missingDuration = base
        missingDuration.durationMs = nil
        #expect(semanticKey(missingDuration) == nil)

        var missingTitle = base
        missingTitle.title = "   "
        #expect(semanticKey(missingTitle) == nil)
    }
}
