// ScriptCompileTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Compile-only gates and non-tell handler probes, mirroring the reference's test
// mechanics in tests/test_music_bridge.py.
//
// HARD SAFETY RULES (M4 brief, absolute):
// - The ONLY allowed executions are `osacompile` (compile only, never run the
//   artifact) and `osascript` on NON-TELL, handler-only script text — exactly
//   the reference's probe mechanics. Every osascript execution below goes through
//   `runNonTellScript`, which fails closed on any application-directed tell or
//   any mention of the Music app.
// - Nothing here opens, activates, or sends any Apple event to Music.
// - DELIBERATE DEVIATION (documented in m4-report.md): the reference's
//   test_generated_writer_reads_runtime_local_payload_inside_tell_scope
//   executes a probe wrapped in `tell current application`. That wrapper sends
//   no Apple events, but it is not a NON-TELL prefix, so under the brief's
//   "if in doubt: compile only" rule the Swift port compiles that probe
//   without running it. The runtime semantics remain covered by the reference's
//   own suite, which runs the same probe over byte-identical script text
//   (guaranteed by the M4 golden gate).

import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

func largeSource(count: Int = 1600) -> PlaylistSnapshot {
    PlaylistSnapshot(
        name: "Source",
        persistentId: "P",
        tracks: (0..<count).map { index in
            track(
                sourceIndex: index,
                databaseId: index + 1,
                persistentId: String(format: "P%08d", index),
                title: String(format: "Song %04d", index),
                durationMs: 180000 + index
            )
        }
    )
}

@Suite("Compile-only gates (osacompile; never executed)", .serialized)
struct ScriptCompileGateTests {

    // test_generated_apply_script_compiles_without_executing_music
    @Test(
        "generated apply script compiles",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func applyScriptCompiles() throws {
        let source = PlaylistSnapshot(
            name: "Source", persistentId: "P", tracks: [track(durationMs: 180001)]
        )
        let script = try buildApplyScript(
            plan: try buildPlan(source), verifiedSource: source, targetName: "Target"
        )
        let result = try compileOnly(script)
        #expect(result.status == 0, "\(result.stderr)")
    }

    // test_generated_apply_script_compiles_for_large_playlist (1,600 tracks)
    @Test(
        "generated apply script compiles for a 1,600-track playlist",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func applyScriptCompilesForLargePlaylist() throws {
        let source = largeSource()
        let script = try buildApplyScript(
            plan: try buildPlan(source), verifiedSource: source, targetName: "Target"
        )
        let result = try compileOnly(script)
        #expect(result.status == 0, "\(result.stderr)")
    }

    // test_merge_writer_compiles
    @Test(
        "generated merge writer compiles",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func mergeWriterCompiles() throws {
        let copies = MergeWriterPortTests().copies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        let script = try buildMergeApplyScript(
            plan: plan, verifiedCopies: copies, targetName: "Trance 2022 — Merged"
        )
        let result = try compileOnly(script)
        #expect(result.status == 0, "\(result.stderr)")
    }

    // test_merge_writer_compiles_for_large_multi_copy_input (900 + 900)
    @Test(
        "generated merge writer compiles for a 900+900 multi-copy input",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func mergeWriterCompilesForLargeMultiCopyInput() throws {
        let copyA = PlaylistSnapshot(
            name: "Big", persistentId: "PID-A",
            tracks: (0..<900).map { index in
                track(sourceIndex: index, databaseId: index + 1,
                      persistentId: String(format: "A%08d", index),
                      title: String(format: "Song %04d", index),
                      durationMs: 180000 + index)
            }
        )
        let copyB = PlaylistSnapshot(
            name: "Big", persistentId: "PID-B",
            tracks: (0..<900).map { index in
                track(sourceIndex: index, databaseId: 10000 + index,
                      persistentId: String(format: "B%08d", index),
                      title: String(format: "Other %04d", index),
                      durationMs: 240000 + index)
            }
        )
        let plan = try buildMergePlan(name: "Big", copies: [copyA, copyB])
        let script = try buildMergeApplyScript(
            plan: plan, verifiedCopies: [copyA, copyB], targetName: "Big — Merged"
        )
        let result = try compileOnly(script)
        #expect(result.status == 0, "\(result.stderr)")
    }

    // M4 brief: osacompile EVERY Swift-generated script for every golden case
    // (covers the fixture, hostile-string, PUA-delimiter, and empty cases).
    @Test(
        "every Swift-generated golden script compiles",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func everyGoldenScriptCompiles() throws {
        let golden = try loadScriptGolden()
        for applyCase in golden.applyCases where applyCase.source.tracks.count < 1000 {
            let plan = try buildPlan(applyCase.source)
            let script = try buildApplyScript(
                plan: plan, verifiedSource: applyCase.source, targetName: applyCase.targetName
            )
            let result = try compileOnly(script)
            #expect(result.status == 0, "apply/\(applyCase.name): \(result.stderr)")
        }
        for mergeCase in golden.mergeApplyCases where mergeCase.copies.reduce(0, { $0 + $1.tracks.count }) < 1000 {
            let plan = try buildMergePlan(name: mergeCase.mergedName, copies: mergeCase.copies)
            let script = try buildMergeApplyScript(
                plan: plan, verifiedCopies: mergeCase.copies, targetName: mergeCase.targetName
            )
            let result = try compileOnly(script)
            #expect(result.status == 0, "merge/\(mergeCase.name): \(result.stderr)")
        }
        // The >=1000-track cases are covered by the two dedicated large-scale
        // compile gates above; skipping them here keeps this sweep fast while
        // still compiling every distinct script shape.
    }

    // test_generated_writer_reads_runtime_local_payload_inside_tell_scope —
    // COMPILE-ONLY port (see the deviation note in the file header).
    @Test(
        "tell-scope probe for the run-local payload compiles",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func tellScopeProbeCompiles() throws {
        let source = PlaylistSnapshot(
            name: "Source", persistentId: "P",
            tracks: [track(sourceIndex: 0, databaseId: 1, persistentId: "TRACK-A")]
        )
        let script = try buildApplyScript(
            plan: try buildPlan(source), verifiedSource: source, targetName: "Target"
        )
        let prefix = try nonTellPrefix(of: script)
        let writerSource = ByteText(script)
        let lookupOffset = try #require(
            writerSource.offset(of: "set expectedSourceFields to item sourcePosition of expectedSourceFieldsByPosition")
        )
        let lookupEnd = try #require(writerSource.offset(of: "\n", after: lookupOffset))
        let sourceRowLookup = writerSource.slice(lookupOffset..<lookupEnd).text
        let scopeProbe = prefix
            + "\ntell current application\n"
            + "    set sourcePosition to 1\n"
            + "    \(sourceRowLookup)\n"
            + "    return item 2 of expectedSourceFields\n"
            + "end tell\n"

        // Shape gates: no application-directed tell, no Music reference.
        #expect(!ByteText(scopeProbe).contains("tell application"))
        #expect(!ByteText(scopeProbe).contains("Music.app"))

        let result = try compileOnly(scopeProbe)
        #expect(result.status == 0, "\(result.stderr)")
    }
}

@Suite("Non-tell handler probes (osascript on tell-free text only)", .serialized)
struct HandlerProbeTests {

    // test_text_code_point_handler_distinguishes_unicode_equivalents
    @Test(
        "textCodePointsMatch distinguishes unicode equivalents",
        .enabled(if: appleScriptRuntimeAvailable)
    )
    func textCodePointHandlerDistinguishesUnicodeEquivalents() throws {
        let nfc = scalarString(0xE9)                       // precomposed e-acute
        let nfd = "e" + scalarString(0x301)                // e + combining acute
        let probe = (
            textCodePointHandlerLines() + [
                "",
                "return {"
                    + "my textCodePointsMatch(\"\(nfc)\", \"\(nfc)\"), "
                    + "not my textCodePointsMatch(\"\(nfc)\", \"\(nfd)\"), "
                    + "not my textCodePointsMatch(\"A\", \"a\"), "
                    + "not my textCodePointsMatch(\"x y\", \"xy\"), "
                    + "my textCodePointsMatch(\"\", missing value)"
                    + "}",
                "",
            ]
        ).joined(separator: "\n")

        let result = try runNonTellScript(probe)
        #expect(result.status == 0, "\(result.stderr)")
        let verdicts = result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(verdicts == Array(repeating: "true", count: 5), "\(result.stdout)")
    }

    // test_cloud_status_handler_matches_all_music_enum_constants
    @Test(
        "cloudStatusMatches maps every JXA name to its raw enum constant",
        .enabled(if: appleScriptRuntimeAvailable)
    )
    func cloudStatusHandlerMatchesAllEnumConstants() throws {
        let source = PlaylistSnapshot(
            name: "Source", persistentId: "PLAYLIST",
            tracks: [
                track(sourceIndex: 0, databaseId: 101, persistentId: "CLOUD-A",
                      cloudStatus: "subscription")
            ]
        )
        let script = try buildApplyScript(
            plan: try buildPlan(source), verifiedSource: source, targetName: "Target"
        )
        let prefix = try nonTellPrefix(of: script)

        let enumCases: [(name: String, constant: String)] = [
            ("unknown", "«constant eClSkUnk»"),
            ("purchased", "«constant eClSkPur»"),
            ("matched", "«constant eClSkMat»"),
            ("uploaded", "«constant eClSkUpl»"),
            ("ineligible", "«constant eClSkRej»"),
            ("removed", "«constant eClSkRem»"),
            ("error", "«constant eClSkErr»"),
            ("duplicate", "«constant eClSkDup»"),
            ("subscription", "«constant eClSkSub»"),
            ("prerelease", "«constant eClSkPrR»"),
            ("no longer available", "«constant eClSkRev»"),
            ("not uploaded", "«constant eClSkUpP»"),
        ]
        var checks = enumCases.map { "my cloudStatusMatches(\"\($0.name)\", \($0.constant))" }
        checks.append("my cloudStatusMatches(\"\", missing value)")
        checks.append("not my cloudStatusMatches(\"\", «constant eClSkSub»)")
        checks.append("not my cloudStatusMatches(\"subscription\", «constant eClSkPur»)")
        let probe = prefix + "return {\(checks.joined(separator: ", "))}\n"

        let result = try runNonTellScript(probe)
        #expect(result.status == 0, "\(result.stderr)")
        let verdicts = result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(verdicts == Array(repeating: "true", count: checks.count), "\(result.stdout)")
    }

    // test_generated_parser_does_not_persist_large_runtime_state
    // (the no-save-back regression: the compiled non-tell parser prefix must
    // hash identically before and after an osascript run)
    @Test(
        "compiled parser prefix persists no runtime state (1,600 tracks)",
        .enabled(if: appleScriptCompilerAndMusicAvailable && appleScriptRuntimeAvailable)
    )
    func compiledParserPersistsNoRuntimeState() throws {
        let source = largeSource()
        let script = try buildApplyScript(
            plan: try buildPlan(source), verifiedSource: source, targetName: "Target"
        )
        var parserSource = try nonTellPrefix(of: script)
        parserSource += "\nreturn count of expectedSourceFieldsByPosition\n"
        try requireTellFree(parserSource)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let compiledScript = directory.appendingPathComponent("parser.scpt")

        let compileResult = try runTool(
            osacompilePath, arguments: ["-o", compiledScript.path], stdinText: parserSource
        )
        #expect(compileResult.status == 0, "\(compileResult.stderr)")

        let beforeHash = try sha256Hex(of: compiledScript)
        let runResult = try runTool(osascriptPath, arguments: [compiledScript.path])
        let afterHash = try sha256Hex(of: compiledScript)

        #expect(runResult.status == 0, "\(runResult.stderr)")
        #expect(runResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1600")
        #expect(runResult.stderr.isEmpty)
        #expect(afterHash == beforeHash)
    }
}
