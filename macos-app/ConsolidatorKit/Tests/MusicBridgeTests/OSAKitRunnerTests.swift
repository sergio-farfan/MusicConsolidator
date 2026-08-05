// OSAKitRunnerTests.swift
// M6a gate tests for the real in-process ScriptRunner over OSAKit.
//
// ABSOLUTE SAFETY RULES (m6a-brief.md, unchanged from M4/M5):
// - Every script text compiled or executed here is TELL-FREE and passes the
//   existing `requireTellFree` gate BEFORE the runner may see it (`gatedRun`).
// - Nothing targets any application; no Apple event is sent; Music is never
//   contacted. The real read JXA (`buildReadJXA`, which targets Music) is
//   NEVER run — the integration smoke feeds the runner a tell-free JXA that
//   returns a canned fixture payload literal instead.
// - `.executeCompiledScript` carries no script text; it can only reach
//   scripts that already passed the compile-side gate in this file.
//
// Empirical OSAKit facts these pins rest on (verified 2026-08-01 in the
// standalone /tmp spike, recorded in m6a-report.md):
// - `NSAppleEventDescriptor.stringValue` STRIPS a leading U+FEFF from a
//   'utxt' result (misreads the first content scalar as a byte-order mark) —
//   the exact R3 hazard; the runner must decode the raw UTF-16 data instead.
// - A no-result script returns a NON-nil 'null' descriptor with no error
//   dictionary; a JXA throw returns an actually-nil descriptor (despite the
//   non-optional annotation) WITH an error dictionary.
// - AppleScript `property` state persists across executions of the SAME
//   OSAScript instance — the observable evidence for compile→execute pairing.

import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

private let osacompileAvailable = FileManager.default.isExecutableFile(atPath: osacompilePath)

/// Safety-gated dispatch: the ONLY way any test in this file reaches the
/// runner. Script-carrying commands are requireTellFree-checked first and
/// fail closed on any application-directed tell or Music reference.
@discardableResult
private func gatedRun(_ runner: OSAKitRunner, _ command: ScriptCommand) throws -> String {
    switch command {
    case .readJXA(let script):
        try requireTellFree(script)
    case .compileAppleScript(let script, _):
        try requireTellFree(script)
    case .executeCompiledScript:
        break
    }
    return try runner.run(command)
}

/// A fresh scratch directory for artifact pairing keys; every test removes
/// it via `defer { scratch.remove() }` (the M4 `compileOnly` cleanup
/// pattern). Most paths never exist on disk — the runner's pairing is
/// in-memory — but the unknown-path tests write real files here.
private struct ScratchDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6a-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func path(_ name: String) -> String {
        url.appendingPathComponent(name).path
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private func scalarValues(_ text: String) -> [UInt32] {
    text.unicodeScalars.map(\.value)
}

/// The R3 probe payload, built from explicit code points so no invisible
/// scalar appears literally in this source file (FixRound1Tests discipline):
/// leading U+FEFF, ASCII, interior U+FEFF, NFD e + U+0301, PUA U+E000,
/// ZWSP U+200B, non-BMP U+1F600.
private let fidelityPayload = scalarString(0xFEFF) + "A" + scalarString(0xFEFF)
    + "e" + scalarString(0x301) + scalarString(0xE000) + scalarString(0x200B)
    + scalarString(0x1F600)
private let fidelityPayloadScalars: [UInt32] = [
    0xFEFF, 0x41, 0xFEFF, 0x65, 0x301, 0xE000, 0x200B, 0x1F600,
]
/// The same payload as JS escape sequences (source-visible, reference-checkable).
private let fidelityPayloadJS = "\\uFEFFA\\uFEFFe\\u0301\\uE000\\u200B\\uD83D\\uDE00"

/// Encode text as a JavaScript string literal (JSON-style escapes; also
/// escapes U+2028/U+2029 for pre-ES2019 parser safety).
private func jsStringLiteral(_ text: String) -> String {
    var encoded = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"", "\\":
            encoded.unicodeScalars.append("\\")
            encoded.unicodeScalars.append(scalar)
        default:
            if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                encoded += String(format: "\\u%04X", scalar.value)
            } else {
                encoded.unicodeScalars.append(scalar)
            }
        }
    }
    return encoded + "\""
}

@Suite("OSAKitRunner (in-process, tell-free only)", .serialized)
struct OSAKitRunnerTests {

    // MARK: 1 — descriptor→String scalar fidelity (the R3 gate probe)

    @Test("JXA direct string result preserves FEFF/NFD/PUA/ZWSP/non-BMP scalars exactly")
    func jxaDirectStringScalarFidelity() throws {
        let script = "(function(){ return '\(fidelityPayloadJS)'; })()"
        let result = try gatedRun(OSAKitRunner(), .readJXA(script: script))
        #expect(scalarValues(result) == fidelityPayloadScalars)
        expectByteEqual(result, fidelityPayload, context: "R3 direct string fidelity")
    }

    @Test("JXA FEFF-only string result survives (never stripped as a BOM)")
    func jxaFEFFOnlyResultSurvives() throws {
        let script = "(function(){ return '\\uFEFF'; })()"
        let result = try gatedRun(OSAKitRunner(), .readJXA(script: script))
        #expect(scalarValues(result) == [0xFEFF])
    }

    @Test("JXA JSON.stringify result preserves the probe scalars exactly")
    func jxaJSONStringifyScalarFidelity() throws {
        let script = "(function(){ return JSON.stringify({title: '\(fidelityPayloadJS)'}); })()"
        let result = try gatedRun(OSAKitRunner(), .readJXA(script: script))
        let expected = "{\"title\":\"" + fidelityPayload + "\"}"
        #expect(scalarValues(result) == scalarValues(expected))
        expectByteEqual(result, expected, context: "R3 JSON.stringify fidelity")
    }

    @Test("compiled AppleScript text result preserves the probe scalars exactly")
    func appleScriptExecuteScalarFidelity() throws {
        // The same payload built in-language via `string id`, so the compile→
        // execute (writer-side) path is fidelity-pinned too.
        let script = """
        on run
            return (string id 65279) & "A" & (string id 65279) & "e" & \
        (string id 769) & (string id 57344) & (string id 8203) & (string id 128512)
        end run
        """
        let runner = OSAKitRunner()
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let path = scratch.path("fidelity.scpt")
        #expect(try gatedRun(runner, .compileAppleScript(script: script, outputPath: path)).isEmpty)
        let result = try gatedRun(runner, .executeCompiledScript(path: path))
        #expect(scalarValues(result) == fidelityPayloadScalars)
        expectByteEqual(result, fidelityPayload, context: "R3 AppleScript execute fidelity")
    }

    // MARK: 2 — compile gate

    @Test("an AppleScript compile error fails closed and retains nothing for the path")
    func compileErrorRetainsNothing() throws {
        let runner = OSAKitRunner()
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let path = scratch.path("writer.scpt")
        do {
            _ = try gatedRun(runner, .compileAppleScript(script: "set x to (", outputPath: path))
            Issue.record("an invalid AppleScript must not compile")
        } catch {
            #expect(error is MusicCommandError)
            let message = String(describing: error)
            #expect(message.hasPrefix("AppleScript compilation failed: error "), "\(message)")
            #expect(!message.unicodeScalars.contains { $0.value < 0x20 }, "single-line: \(message)")
        }
        expectThrowsByteEqualMessage(
            "refusing to execute: this runner has no compiled script for path \(path)",
            context: "execute after failed compile"
        ) {
            _ = try gatedRun(runner, .executeCompiledScript(path: path))
        }
    }

    @Test("a failed recompile evicts a previously compiled script at the same path")
    func failedRecompileEvictsStaleInstance() throws {
        let runner = OSAKitRunner()
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let path = scratch.path("writer.scpt")
        try gatedRun(runner, .compileAppleScript(script: "return \"first\"", outputPath: path))
        expectByteEqual(
            try gatedRun(runner, .executeCompiledScript(path: path)),
            "first",
            context: "pre-recompile execute"
        )
        #expect(throws: MusicCommandError.self) {
            try gatedRun(runner, .compileAppleScript(script: "set x to (", outputPath: path))
        }
        expectThrowsByteEqualMessage(
            "refusing to execute: this runner has no compiled script for path \(path)",
            context: "stale instance must not survive a failed recompile"
        ) {
            _ = try gatedRun(runner, .executeCompiledScript(path: path))
        }
    }

    @Test("a JXA compile error surfaces as a sanitized MusicCommandError")
    func jxaCompileErrorFailsClosed() throws {
        do {
            _ = try gatedRun(OSAKitRunner(), .readJXA(script: "function {{{"))
            Issue.record("invalid JXA must not compile")
        } catch {
            #expect(error is MusicCommandError)
            let message = String(describing: error)
            #expect(message.hasPrefix("JXA compilation failed: error "), "\(message)")
            #expect(ByteText(message).contains("SyntaxError"), "\(message)")
            #expect(!message.unicodeScalars.contains { $0.value < 0x20 }, "single-line: \(message)")
        }
    }

    // MARK: 3 — execute-unknown-path fails closed (never load from disk)

    @Test("executing a never-compiled path is refused even when a source file exists there")
    func unknownPathWithSourceFileRefused() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let path = scratch.path("on-disk.applescript")
        try Data("return \"MARKER-RAN\"".utf8).write(to: URL(fileURLWithPath: path))
        expectThrowsByteEqualMessage(
            "refusing to execute: this runner has no compiled script for path \(path)",
            context: "unknown path with on-disk source"
        ) {
            _ = try gatedRun(OSAKitRunner(), .executeCompiledScript(path: path))
        }
    }

    @Test(
        "executing a never-compiled path is refused even for a real compiled artifact",
        .enabled(if: osacompileAvailable)
    )
    func unknownPathWithCompiledArtifactRefused() throws {
        // A genuine .scpt on disk whose execution would be detectable — the
        // runner must refuse without reading it (no compile-on-demand, no
        // OSAScript(contentsOf:) load).
        let script = "return \"MARKER-RAN\""
        try requireTellFree(script)
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let path = scratch.path("compiled.scpt")
        let compile = try runTool(osacompilePath, arguments: ["-o", path], stdinText: script)
        #expect(compile.status == 0, "\(compile.stderr)")
        #expect(FileManager.default.fileExists(atPath: path))

        do {
            let output = try gatedRun(OSAKitRunner(), .executeCompiledScript(path: path))
            Issue.record("refusal expected; the artifact ran and returned \(output)")
        } catch {
            #expect(error is MusicCommandError)
            expectByteEqual(
                String(describing: error),
                "refusing to execute: this runner has no compiled script for path \(path)",
                context: "unknown path with compiled artifact"
            )
        }
    }

    // MARK: 4 — stateful compile→execute pairing

    @Test("compile→execute pairs by outputPath and re-executes the SAME compiled instance")
    func compileExecutePairingReusesInstance() throws {
        // AppleScript `property` state persists on the in-memory OSAScript
        // instance (spike-verified): a second execute of the same path must
        // continue the counter. A recompiled or loaded-from-disk instance
        // would restart at 1 — the observable identity evidence.
        let script = """
        property runCounter : 0
        on run
            set runCounter to runCounter + 1
            return "count:" & runCounter
        end run
        """
        let runner = OSAKitRunner()
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let path = scratch.path("counter.scpt")
        expectByteEqual(
            try gatedRun(runner, .compileAppleScript(script: script, outputPath: path)),
            "",
            context: "compile output is empty (osacompile stdout analog)"
        )
        expectByteEqual(
            try gatedRun(runner, .executeCompiledScript(path: path)),
            "count:1",
            context: "first execute"
        )
        expectByteEqual(
            try gatedRun(runner, .executeCompiledScript(path: path)),
            "count:2",
            context: "second execute reuses the same compiled instance"
        )
        // No artifact is written to disk: the pairing is in-memory only.
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("two paths retain two independent compiled instances")
    func distinctPathsRetainDistinctInstances() throws {
        let counterScript = """
        property runCounter : 0
        on run
            set runCounter to runCounter + 1
            return "count:" & runCounter
        end run
        """
        let runner = OSAKitRunner()
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let pathA = scratch.path("a.scpt")
        let pathB = scratch.path("b.scpt")
        try gatedRun(runner, .compileAppleScript(script: counterScript, outputPath: pathA))
        try gatedRun(runner, .compileAppleScript(script: counterScript, outputPath: pathB))
        expectByteEqual(try gatedRun(runner, .executeCompiledScript(path: pathA)), "count:1", context: "A first")
        expectByteEqual(try gatedRun(runner, .executeCompiledScript(path: pathA)), "count:2", context: "A second")
        expectByteEqual(try gatedRun(runner, .executeCompiledScript(path: pathB)), "count:1", context: "B is a separate instance")
    }

    @Test("the reference's handler-prefix probe runs through compile→execute")
    func handlerPrefixProbeRunsInProcess() throws {
        // M4 mechanics (ScriptCompileTests): the tell-free code-point handler
        // exercised over NFC/NFD — here through the real runner seam.
        let nfc = scalarString(0xE9)
        let nfd = "e" + scalarString(0x301)
        let probe = (
            textCodePointHandlerLines() + [
                "",
                "on run",
                "    if my textCodePointsMatch(\"\(nfc)\", \"\(nfc)\") and "
                    + "not my textCodePointsMatch(\"\(nfc)\", \"\(nfd)\") and "
                    + "not my textCodePointsMatch(\"A\", \"a\") and "
                    + "my textCodePointsMatch(\"\", missing value) then",
                "        return \"handler-ok\"",
                "    end if",
                "    return \"handler-broken\"",
                "end run",
                "",
            ]
        ).joined(separator: "\n")
        let runner = OSAKitRunner()
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let path = scratch.path("handler-probe.scpt")
        try gatedRun(runner, .compileAppleScript(script: probe, outputPath: path))
        expectByteEqual(
            try gatedRun(runner, .executeCompiledScript(path: path)),
            "handler-ok",
            context: "code-point handler probe via OSAKitRunner"
        )
    }

    // MARK: 5 — JXA error path (nil-descriptor hazard exercised)

    @Test("a JXA throw fails closed with a sanitized single-line message")
    func jxaThrowFailsClosedSanitized() throws {
        // Spike-verified: this is the case where executeAndReturnError
        // actually returns nil (mis-annotated non-optional) WITH an error
        // dictionary whose message spans lines — both the hazard branch and
        // the sanitizer are exercised.
        let script = "(function(){ throw new Error('boom\\n\\tmulti  line'); })()"
        do {
            _ = try gatedRun(OSAKitRunner(), .readJXA(script: script))
            Issue.record("a throwing JXA must not succeed")
        } catch {
            #expect(error is MusicCommandError)
            let message = String(describing: error)
            #expect(message.hasPrefix("JXA execution failed: error "), "\(message)")
            #expect(ByteText(message).contains("boom"), "\(message)")
            // _sanitized_stderr semantics: non-printables to spaces, runs
            // collapsed — the newline/tab/double-space become single spaces.
            #expect(ByteText(message).contains("boom multi line"), "\(message)")
            #expect(!message.unicodeScalars.contains { $0.value < 0x20 }, "single-line: \(message)")
        }
    }

    @Test("a compiled AppleScript runtime error fails closed with a sanitized message")
    func appleScriptRuntimeErrorFailsClosed() throws {
        let script = "error \"writer  guard\\nfailed\" number 9001"
        let runner = OSAKitRunner()
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let path = scratch.path("failing.scpt")
        try gatedRun(runner, .compileAppleScript(script: script, outputPath: path))
        do {
            _ = try gatedRun(runner, .executeCompiledScript(path: path))
            Issue.record("a raising script must not succeed")
        } catch {
            #expect(error is MusicCommandError)
            let message = String(describing: error)
            #expect(message.hasPrefix("compiled script execution failed: error 9001: "), "\(message)")
            #expect(ByteText(message).contains("writer guard failed"), "\(message)")
            #expect(!message.unicodeScalars.contains { $0.value < 0x20 }, "single-line: \(message)")
        }
    }

    // MARK: 6 — optional-result classification (seam contract)

    @Test("a no-result AppleScript executes successfully with empty output")
    func noResultAppleScriptIsEmptySuccess() throws {
        // The 'null' descriptor (non-nil, no error) is a SUCCESS with empty
        // output — matching the seam the M5 orchestration assumes (execute
        // output is discarded; FakeRunner scripts model it as .success("")).
        // An actually-nil descriptor remains a failure (hazard 3; the nil
        // branch is exercised by jxaThrowFailsClosedSanitized above).
        let runner = OSAKitRunner()
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let path = scratch.path("void.scpt")
        try gatedRun(runner, .compileAppleScript(script: "on run\nend run", outputPath: path))
        expectByteEqual(
            try gatedRun(runner, .executeCompiledScript(path: path)),
            "",
            context: "no-result AppleScript classification"
        )
    }

    @Test("a JXA undefined result is an empty-output success")
    func jxaUndefinedIsEmptySuccess() throws {
        let result = try gatedRun(
            OSAKitRunner(), .readJXA(script: "(function(){ return undefined; })()")
        )
        expectByteEqual(result, "", context: "JXA undefined classification")
    }

    @Test("a JXA empty-string result round-trips as an empty string")
    func jxaEmptyStringRoundTrips() throws {
        let result = try gatedRun(
            OSAKitRunner(), .readJXA(script: "(function(){ return ''; })()")
        )
        expectByteEqual(result, "", context: "JXA empty string")
    }

    @Test("a 'long' integer result renders as its exact decimal digits")
    func nonTextResultFallsBackToDisplayString() throws {
        // 'long' (SInt32) is the ONLY non-text descriptor type the runner
        // converts, rendered from int32Value directly (exact decimal digits,
        // no AE text coercion, no stringValue). Every other non-'utxt',
        // non-'null' type fails closed — see the fidelity-refusal pins below.
        let result = try gatedRun(OSAKitRunner(), .readJXA(script: "(function(){ return 42; })()"))
        expectByteEqual(result, "42", context: "'long' result")
    }

    @Test("a raw-data descriptor result fails closed instead of normalizing (fix round 1, finding 1)")
    func rawDataResultFailsClosedNotNormalized() throws {
        // «data utf8EFBBBF41» executes to a 'utf8' descriptor whose
        // stringValue is "A" — NSAppleEventDescriptor silently strips the
        // UTF-8 BOM (spike-verified). Contract item 4: a conversion path
        // that cannot guarantee scalar fidelity must FAIL CLOSED, never
        // normalize. Unreachable with legitimate seam data (JS strings and
        // AppleScript text returns are 'utxt'), but the refusal must hold.
        let script = "return «data utf8EFBBBF41»"
        let runner = OSAKitRunner()
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let path = scratch.path("raw-data.scpt")
        try gatedRun(runner, .compileAppleScript(script: script, outputPath: path))
        do {
            let output = try gatedRun(runner, .executeCompiledScript(path: path))
            Issue.record("fidelity refusal expected; the 'utf8' descriptor converted to \(pythonRepr(output))")
        } catch {
            #expect(error is MusicCommandError)
            expectByteEqual(
                String(describing: error),
                "script result type 'utf8' has no fidelity-safe text conversion",
                context: "raw-data refusal"
            )
        }
    }

    @Test("an AppleScript `missing value` result fails closed (brief gate test 6: missing)")
    func missingValueResultFailsClosed() throws {
        // `missing value` executes to a 'type' descriptor (data 'msng',
        // stringValue nil; spike-verified). The osascript CLI would PRINT
        // "missing value" and exit 0 — a documented reject-direction
        // divergence: the seam only ever needs JSON text (readJXA) or a
        // discarded text return (writers), so a type-constant result is
        // refused rather than rendered through AE display coercion.
        let runner = OSAKitRunner()
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let path = scratch.path("missing.scpt")
        try gatedRun(runner, .compileAppleScript(script: "return missing value", outputPath: path))
        expectThrowsByteEqualMessage(
            "script result type 'type' has no fidelity-safe text conversion",
            context: "missing value classification"
        ) {
            _ = try gatedRun(runner, .executeCompiledScript(path: path))
        }
    }

    @Test("a JXA null result fails closed like `missing value`")
    func jxaNullResultFailsClosed() throws {
        // JXA `return null` bridges to the same 'type'/'msng' descriptor as
        // AppleScript `missing value` (spike-verified) — unlike `undefined`,
        // which is a 'null' no-result descriptor and an empty-output success
        // (pinned above).
        expectThrowsByteEqualMessage(
            "script result type 'type' has no fidelity-safe text conversion",
            context: "JXA null classification"
        ) {
            _ = try gatedRun(OSAKitRunner(), .readJXA(script: "(function(){ return null; })()"))
        }
    }

    // MARK: 7 — integration smoke (runner → parser seam, zero Apple events)

    @Test("a tell-free JXA returning the canned fixture payload feeds parseExactPlaylistSnapshot")
    func fixturePayloadDrivesParserSeam() throws {
        // NEVER buildReadJXA here: the real read script targets Music. The
        // fixture literal stands in for the wire payload instead.
        let fixture = try musicSnapshotFixtureText()
        let script = "(function(){ return \(jsStringLiteral(fixture)); })()"
        let raw = try gatedRun(OSAKitRunner(), .readJXA(script: script))

        // The wire text survives the in-process round trip byte-for-byte.
        expectByteEqual(raw, fixture, context: "fixture wire round trip")

        let snapshot = try parseExactPlaylistSnapshot(raw: raw, name: "#Musica xTotal")
        #expect(snapshot.name == "#Musica xTotal")
        #expect(snapshot.persistentId == "PLAYLIST-123")
        #expect(snapshot.tracks.count == 2)
        #expect(snapshot.tracks[0].persistentId == "TRACK-A")
        #expect(snapshot.tracks[0].title == "Rock—Song")
        #expect(snapshot.tracks[0].artist == "Björk")
        #expect(snapshot.tracks[0].durationMs == 183456)
        #expect(snapshot.tracks[0].cloudStatus == "matched")
        #expect(snapshot.tracks[0].isFileTrack == false)
    }
}
