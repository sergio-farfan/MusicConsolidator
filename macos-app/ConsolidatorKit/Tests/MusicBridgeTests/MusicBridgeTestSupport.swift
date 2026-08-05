// MusicBridgeTestSupport.swift
// Shared helpers for the M4 MusicBridge suites: the tests/helpers.py `track()`
// fixture builder, golden-file loading, UTF-8 byte-diff diagnostics, scalar
// utilities, a subprocess runner for /usr/bin/osacompile and /usr/bin/osascript,
// and the HARD SAFETY gate that refuses to execute any script text containing
// an application-directed `tell` (mirroring the reference's own test mechanics in
// tests/test_music_bridge.py: compile-only gates plus non-tell handler probes).
//
// Tests write only under FileManager.temporaryDirectory.

import CryptoKit
import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

// MARK: - fixture builder (tests/helpers.py `track()`, identical defaults)

func track(
    sourceIndex: Int = 0,
    databaseId: Int = 1,
    persistentId: String = "ABC",
    title: String = "Rock—Song",
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

/// A single-scalar string built from a code point, so invisible characters
/// never appear literally in this source file.
func scalarString(_ codePoint: UInt32) -> String {
    String(String.UnicodeScalarView([Unicode.Scalar(codePoint)!]))
}

// MARK: - golden loading (same #filePath convention as ConsolidatorCoreTests)

func goldenFileURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("golden")
        .appendingPathComponent(name)
}

struct ScriptGolden: Decodable {
    let readJxaCases: [ReadJXACase]
    let applyCases: [ApplyCase]
    let mergeApplyCases: [MergeApplyCase]

    enum CodingKeys: String, CodingKey {
        case readJxaCases = "read_jxa_cases"
        case applyCases = "apply_cases"
        case mergeApplyCases = "merge_apply_cases"
    }
}

struct ReadJXACase: Decodable {
    let name: String
    let playlistName: String
    let script: String

    enum CodingKeys: String, CodingKey {
        case name
        case playlistName = "playlist_name"
        case script
    }
}

struct ApplyCase: Decodable {
    let name: String
    let source: PlaylistSnapshot
    let targetName: String
    let script: String

    enum CodingKeys: String, CodingKey {
        case name
        case source
        case targetName = "target_name"
        case script
    }
}

struct MergeApplyCase: Decodable {
    let name: String
    let mergedName: String
    let copies: [PlaylistSnapshot]
    let targetName: String
    let script: String

    enum CodingKeys: String, CodingKey {
        case name
        case mergedName = "merged_name"
        case copies
        case targetName = "target_name"
        case script
    }
}

func loadScriptGolden() throws -> ScriptGolden {
    let data = try Data(contentsOf: goldenFileURL("script_golden.json"))
    return try JSONDecoder().decode(ScriptGolden.self, from: data)
}

// MARK: - byte-level text search (Python str.index / in semantics for the
// ASCII needles the ported asserts use)

struct ByteText {
    let bytes: [UInt8]

    init(_ text: String) {
        self.bytes = Array(text.utf8)
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    func offset(of needle: String, after start: Int = 0) -> Int? {
        let needleBytes = Array(needle.utf8)
        guard !needleBytes.isEmpty, bytes.count >= needleBytes.count else { return nil }
        guard start <= bytes.count - needleBytes.count else { return nil }
        for index in start...(bytes.count - needleBytes.count) {
            if Array(bytes[index..<(index + needleBytes.count)]) == needleBytes {
                return index
            }
        }
        return nil
    }

    func contains(_ needle: String) -> Bool {
        offset(of: needle) != nil
    }

    func count(of needle: String) -> Int {
        var total = 0
        var position = 0
        let needleLength = Array(needle.utf8).count
        while let found = offset(of: needle, after: position) {
            total += 1
            position = found + needleLength
        }
        return total
    }

    func slice(_ range: Range<Int>) -> ByteText {
        ByteText(bytes: Array(bytes[range]))
    }

    var text: String {
        String(decoding: bytes, as: UTF8.self)
    }
}

/// UTF-8 byte-for-byte comparison with a diagnosable first-divergence message
/// (offset, surrounding context, code points), per the M4 golden-gate brief.
func expectByteEqual(
    _ actual: String,
    _ expected: String,
    context: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    let actualBytes = Array(actual.utf8)
    let expectedBytes = Array(expected.utf8)
    if actualBytes == expectedBytes { return }

    var divergence = 0
    let shared = min(actualBytes.count, expectedBytes.count)
    while divergence < shared && actualBytes[divergence] == expectedBytes[divergence] {
        divergence += 1
    }
    let windowStart = max(0, divergence - 40)
    func window(_ bytes: [UInt8]) -> String {
        let end = min(bytes.count, divergence + 40)
        guard windowStart < end else { return "<past end>" }
        return String(decoding: bytes[windowStart..<end], as: UTF8.self)
    }
    func codePoints(_ bytes: [UInt8]) -> String {
        let end = min(bytes.count, divergence + 12)
        guard windowStart < end else { return "<past end>" }
        return String(decoding: bytes[windowStart..<end], as: UTF8.self)
            .unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }
    Issue.record(
        """
        \(context): script text diverged from the Python reference implementation
          actual length:   \(actualBytes.count) bytes
          expected length: \(expectedBytes.count) bytes
          first divergent byte offset: \(divergence)
          actual   ...\(window(actualBytes))...
          expected ...\(window(expectedBytes))...
          actual code points near divergence:   \(codePoints(actualBytes))
          expected code points near divergence: \(codePoints(expectedBytes))
        """,
        sourceLocation: sourceLocation
    )
}

/// Scalar-level split (PUA delimiters must not merge with neighbouring
/// combining marks the way grapheme-based `components(separatedBy:)` can).
func splitScalars(_ text: String, separator: Unicode.Scalar) -> [String] {
    var parts: [String] = []
    var current = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        if scalar == separator {
            parts.append(String(current))
            current = String.UnicodeScalarView()
        } else {
            current.append(scalar)
        }
    }
    parts.append(String(current))
    return parts
}

// MARK: - subprocess runner and the hard safety gate

let osascriptPath = "/usr/bin/osascript"
let osacompilePath = "/usr/bin/osacompile"

let appleScriptRuntimeAvailable = FileManager.default.isExecutableFile(atPath: osascriptPath)
let appleScriptCompilerAndMusicAvailable: Bool = {
    var isDirectory: ObjCBool = false
    let musicPresent = FileManager.default.fileExists(atPath: musicAppPath, isDirectory: &isDirectory)
        && isDirectory.boolValue
    return FileManager.default.isExecutableFile(atPath: osacompilePath) && musicPresent
}()

struct ToolResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Run a tool with optional stdin text (spooled through a temp file so large
/// scripts cannot deadlock a pipe). Never invokes a shell.
func runTool(_ path: String, arguments: [String], stdinText: String? = nil) throws -> ToolResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    var spoolURL: URL?
    if let stdinText {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4-stdin-\(UUID().uuidString).applescript")
        try Data(stdinText.utf8).write(to: url)
        process.standardInput = try FileHandle(forReadingFrom: url)
        spoolURL = url
    } else {
        process.standardInput = FileHandle.nullDevice
    }
    defer {
        if let spoolURL { try? FileManager.default.removeItem(at: spoolURL) }
    }

    try process.run()
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ToolResult(
        status: process.terminationStatus,
        stdout: String(decoding: stdoutData, as: UTF8.self),
        stderr: String(decoding: stderrData, as: UTF8.self)
    )
}

/// HARD SAFETY GATE (M4 brief): nothing that could send an Apple event to any
/// application may ever run. Every osascript execution in this suite must pass
/// through this check first. `osacompile` is exempt (compile only, per the
/// reference's own test mechanics).
func requireTellFree(_ script: String) throws {
    struct UnsafeScriptError: Error, CustomStringConvertible {
        let description: String
    }
    let probe = ByteText(script)
    if probe.contains("tell application") {
        throw UnsafeScriptError(
            description: "refusing to execute script text containing an application tell"
        )
    }
    if probe.contains("Music.app") || probe.contains("com.apple.Music") {
        throw UnsafeScriptError(
            description: "refusing to execute script text that references the Music app"
        )
    }
}

/// Compile-only gate: osacompile into a fresh temp directory, never execute.
func compileOnly(_ script: String) throws -> ToolResult {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("m4-compile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("writer.scpt")
    return try runTool(osacompilePath, arguments: ["-o", output.path], stdinText: script)
}

/// Execute a NON-TELL, handler-only script via osascript stdin, exactly the
/// reference's probe mechanics. The safety gate runs first and fails closed.
func runNonTellScript(_ script: String) throws -> ToolResult {
    try requireTellFree(script)
    return try runTool(osascriptPath, arguments: [], stdinText: script)
}

/// Partition a generated writer on the single Music tell marker, mirroring
/// `script.partition(music_marker)` in the reference tests. Returns the non-tell
/// prefix and asserts the marker appears exactly once.
func nonTellPrefix(
    of script: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) throws -> String {
    let marker = "tell application " + appleScriptString(musicAppPath)
    let probe = ByteText(script)
    #expect(probe.count(of: marker) == 1, "exactly one Music tell marker", sourceLocation: sourceLocation)
    guard let markerOffset = probe.offset(of: marker) else {
        throw TestSupportError("generated script is missing the Music tell marker")
    }
    let prefix = probe.slice(0..<markerOffset).text
    #expect(!ByteText(prefix).contains("tell application"), "prefix must be tell-free", sourceLocation: sourceLocation)
    return prefix
}

struct TestSupportError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

func sha256Hex(of url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
