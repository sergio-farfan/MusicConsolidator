// MutationScriptBuilderTests.swift
// Generated-source shape, injection-defense, and compile-only gates for the
// guarded delete writer (spec B1). Nothing here executes any script text:
// shape asserts run on bytes, and the compile gates go through `compileOnly`
// (osacompile into a temp directory; the artifact is never run).

import Foundation
import Testing
@testable import MusicBridge

private func deleteScript(
    name: String = "Trance 2022",
    persistentID: String = "PID-DOOMED",
    trackPIDs: [String] = ["T0", "T1", "T2"],
    targetGuard: MutationScriptBuilder.TargetGuardPayload? = nil
) -> String {
    MutationScriptBuilder.buildDeleteScript(
        expectedName: name,
        expectedPersistentID: persistentID,
        expectedTrackPersistentIDs: trackPIDs,
        targetGuard: targetGuard
    )
}

private let mergedTargetGuard = MutationScriptBuilder.TargetGuardPayload(
    name: "Trance 2022 — Merged",
    orderedTrackPersistentIDs: ["M0", "M1", "M2"]
)

/// Hostile name: double quote, backslash, a PUA scalar, a non-BMP scalar
/// (musical note, built from its code point — no literal emoji in source),
/// and a trailing space that any normalization would strip.
private let hostileName =
    "Trance \"2022\" \\ mix " + scalarString(0xE001) + scalarString(0x1F3B5) + " "

@Suite("MutationScriptBuilder delete writer (text shape; nothing executed)")
struct MutationScriptBuilderTests {

    @Test("exactly one mutation verb: one delete, no other write pattern")
    func exactlyOneMutationVerb() {
        for script in [deleteScript(), deleteScript(targetGuard: mergedTargetGuard)] {
            let probe = ByteText(script)
            #expect(probe.count(of: " delete ") == 1)
            #expect(probe.contains("\n    delete doomedPlaylist\n"))
            #expect(probe.count(of: "make new") == 0)
            #expect(probe.count(of: " duplicate ") == 0)
            #expect(probe.count(of: " move ") == 0)
            #expect(probe.count(of: " remove ") == 0)
            #expect(probe.count(of: " empty") == 0)
            #expect(probe.count(of: "set name") == 0)
            #expect(probe.count(of: "tell application " + appleScriptString(musicAppPath)) == 1)
        }
    }

    @Test("the lookup is pinned to the persistent ID and every guard precedes the delete")
    func pidPinnedGuardsPrecedeTheDelete() throws {
        let script = deleteScript()
        let probe = ByteText(script)

        // PID-pinned lookup — never name-based for the doomed playlist.
        #expect(probe.contains("repeat with candidatePlaylist in every user playlist"))
        #expect(probe.contains(
            "if (my textCodePointsMatch(expectedPlaylistPersistentID, candidatePID)) is true then"
        ))
        #expect(!probe.contains("set candidateName to"))
        #expect(probe.contains(
            "if (count of matchedPlaylists) is 0 then error \"expected playlist persistent ID is absent\""
        ))
        #expect(probe.contains(
            "if (count of matchedPlaylists) is not 1 then error \"expected playlist persistent ID is duplicated\""
        ))

        let deleteOffset = try #require(probe.offset(of: "\n    delete doomedPlaylist\n"))
        for guardNeedle in [
            "error \"expected playlist persistent ID is absent\"",
            "error \"expected playlist persistent ID is duplicated\"",
            "if (my textCodePointsMatch(expectedPlaylistName, liveTextValue)) is not true then error \"pinned playlist name changed\"",
            "if (count of doomedTracks) is not expectedTrackCount then error \"pinned playlist track count changed\"",
            "error (\"pinned playlist track persistent ID changed at position \" & trackPosition)",
        ] {
            let guardOffset = try #require(probe.offset(of: guardNeedle), "\(guardNeedle)")
            #expect(guardOffset < deleteOffset, "\(guardNeedle) must precede the delete")
        }
    }

    @Test("the ordered track-PID payload is a single PUA-delimited literal")
    func trackPIDPayloadLiterals() {
        let probe = ByteText(deleteScript())
        let delimiter = scalarString(0xE000)
        let payload = ["T0", "T1", "T2"].joined(separator: delimiter)
        #expect(probe.contains("set expectedTrackPIDPayload to " + appleScriptString(payload)))
        #expect(probe.contains("set expectedPIDDelimiter to " + appleScriptString(delimiter)))
        #expect(probe.contains("set expectedTrackCount to 3"))
        #expect(probe.contains("every text item of expectedTrackPIDPayload"))
        #expect(probe.contains("error \"internal expected track persistent ID payload count mismatch\""))
        // text item delimiters restored on both the success and error paths
        #expect(probe.count(
            of: "set AppleScript's text item delimiters to savedTextItemDelimiters") == 2)

        // The delimiter dodges scalars used by the PIDs themselves.
        let dodging = ByteText(deleteScript(trackPIDs: [scalarString(0xE000) + "T0"]))
        #expect(dodging.contains(
            "set expectedPIDDelimiter to " + appleScriptString(scalarString(0xE001))
        ))
    }

    @Test("the cleanup target guard is revalidated in-writer before the delete")
    func targetGuardPrecedesTheDelete() throws {
        let script = deleteScript(targetGuard: mergedTargetGuard)
        let probe = ByteText(script)
        let delimiter = scalarString(0xE000)
        let targetPayload = ["M0", "M1", "M2"].joined(separator: delimiter)

        #expect(probe.contains("set expectedTargetName to " + appleScriptString("Trance 2022 — Merged")))
        #expect(probe.contains("set expectedTargetTrackCount to 3"))
        #expect(probe.contains("set expectedTargetPIDPayload to " + appleScriptString(targetPayload)))
        #expect(probe.contains("set targetPlaylists to {}"))

        let deleteOffset = try #require(probe.offset(of: "\n    delete doomedPlaylist\n"))
        let doomedGuardOffset = try #require(probe.offset(
            of: "error (\"pinned playlist track persistent ID changed at position \" & trackPosition)"
        ))
        for guardNeedle in [
            "if (count of targetPlaylists) is not 1 then error \"expected merged target user playlist is not uniquely present\"",
            "if (count of targetTracks) is not expectedTargetTrackCount then error \"merged target track count changed\"",
            "error (\"merged target track persistent ID changed at position \" & targetPosition)",
        ] {
            let guardOffset = try #require(probe.offset(of: guardNeedle), "\(guardNeedle)")
            #expect(doomedGuardOffset < guardOffset, "target guard follows the doomed-copy guards")
            #expect(guardOffset < deleteOffset, "\(guardNeedle) must precede the delete")
        }

        // Without a guard, no target block is emitted (the `local` declaration
        // of the target variables remains — it is unconditional and inert).
        let bare = ByteText(deleteScript())
        #expect(!bare.contains("set expectedTargetName to"))
        #expect(!bare.contains("set targetPlaylists to {}"))
    }

    @Test("hostile names and persistent IDs are escaped, never interpolated raw")
    func hostileValuesAreEscaped() {
        let script = deleteScript(name: hostileName, persistentID: "PID \"X\" \\")
        let probe = ByteText(script)
        #expect(probe.contains("set expectedPlaylistName to " + appleScriptString(hostileName)))
        #expect(probe.contains(
            "set expectedPlaylistPersistentID to " + appleScriptString("PID \"X\" \\")
        ))
        // Non-tautological pin of the escaping itself: A"B\C must encode to
        // the exact AppleScript literal "A\"B\\C".
        let pinned = ByteText(deleteScript(name: "A\"B\\C"))
        #expect(pinned.contains("set expectedPlaylistName to \"A\\\"B\\\\C\""))
    }

    @Test("delimiter exhaustion fails closed: one error statement, no tell, no delete")
    func delimiterExhaustionFailsClosed() {
        var scalars = String.UnicodeScalarView()
        for codePoint in 0xE000..<0xF900 {
            scalars.append(Unicode.Scalar(UInt32(codePoint))!)
        }
        let script = deleteScript(trackPIDs: [String(scalars)])
        expectByteEqual(
            script,
            "error \"expected track persistent IDs exhaust the guarded payload delimiters\"\n",
            context: "delimiter exhaustion"
        )
        let probe = ByteText(script)
        #expect(probe.count(of: " delete ") == 0)
        #expect(!probe.contains("tell application"))
    }

    @Test("the builder is deterministic: identical inputs, identical bytes")
    func builderIsDeterministic() {
        expectByteEqual(
            deleteScript(targetGuard: mergedTargetGuard),
            deleteScript(targetGuard: mergedTargetGuard),
            context: "delete writer determinism"
        )
    }

    // MARK: - Fix round 1, gap 1: the pidPayloadParseLines count-0 branch
    // (empty track list / empty target-guard track list) was previously
    // untested. These two tests exercise it from both call sites.

    @Test("a zero-track doomed playlist exercises the count-0 payload branch and still guards before the delete")
    func zeroTrackDoomedPlaylistUsesCountZeroBranch() throws {
        let script = deleteScript(trackPIDs: [])
        let probe = ByteText(script)

        #expect(probe.count(of: " delete ") == 1)
        #expect(probe.contains("\n    delete doomedPlaylist\n"))
        #expect(probe.contains("set expectedTrackCount to 0"))
        #expect(probe.contains("set expectedTrackPIDPayload to " + appleScriptString("")))

        let deleteOffset = try #require(probe.offset(of: "\n    delete doomedPlaylist\n"))
        for guardNeedle in [
            "error \"expected playlist persistent ID is absent\"",
            "error \"expected playlist persistent ID is duplicated\"",
            "if (my textCodePointsMatch(expectedPlaylistName, liveTextValue)) is not true then error \"pinned playlist name changed\"",
            "if (count of doomedTracks) is not expectedTrackCount then error \"pinned playlist track count changed\"",
            "repeat with trackPosition from 1 to expectedTrackCount",
            "error \"internal expected track persistent ID payload count mismatch\"",
        ] {
            let guardOffset = try #require(probe.offset(of: guardNeedle), "\(guardNeedle)")
            #expect(guardOffset < deleteOffset, "\(guardNeedle) must precede the delete")
        }
    }

    @Test("a zero-track target guard exercises the count-0 payload branch and still guards before the delete")
    func zeroTrackTargetGuardUsesCountZeroBranch() throws {
        let emptyTargetGuard = MutationScriptBuilder.TargetGuardPayload(
            name: "Empty Target", orderedTrackPersistentIDs: []
        )
        let script = deleteScript(targetGuard: emptyTargetGuard)
        let probe = ByteText(script)

        #expect(probe.count(of: " delete ") == 1)
        #expect(probe.contains("\n    delete doomedPlaylist\n"))
        #expect(probe.contains("set expectedTargetName to " + appleScriptString("Empty Target")))
        #expect(probe.contains("set expectedTargetTrackCount to 0"))
        #expect(probe.contains("set expectedTargetPIDPayload to " + appleScriptString("")))

        let deleteOffset = try #require(probe.offset(of: "\n    delete doomedPlaylist\n"))

        // The payload-parse internal-mismatch guard lives in the top-level
        // `try` block, BEFORE the `tell` (and therefore before every
        // in-tell doomed-copy guard) — it only needs to precede the delete.
        let internalMismatchOffset = try #require(probe.offset(
            of: "error \"internal expected target persistent ID payload count mismatch\""
        ))
        #expect(internalMismatchOffset < deleteOffset)

        let doomedGuardOffset = try #require(probe.offset(
            of: "error (\"pinned playlist track persistent ID changed at position \" & trackPosition)"
        ))
        for guardNeedle in [
            "if (count of targetPlaylists) is not 1 then error \"expected merged target user playlist is not uniquely present\"",
            "if (count of targetTracks) is not expectedTargetTrackCount then error \"merged target track count changed\"",
            "repeat with targetPosition from 1 to expectedTargetTrackCount",
        ] {
            let guardOffset = try #require(probe.offset(of: guardNeedle), "\(guardNeedle)")
            #expect(doomedGuardOffset < guardOffset, "target guard follows the doomed-copy guards")
            #expect(guardOffset < deleteOffset, "\(guardNeedle) must precede the delete")
        }
    }

    // MARK: - Fix round 1, gap 2: the mutation-verb-hygiene counts had never
    // run against a hostile NAME embedding the literal verb substrings. The
    // ByteText helpers have no notion of "inside vs. outside a string
    // literal" — they are raw UTF-8 substring scans — so the strongest proof
    // they support is to locate the exact byte range of the escaped name
    // literal and show every hygiene needle is ABSENT once that range is
    // excised, i.e. the hostile words are confined entirely to the one
    // quoted literal and never surface as real AppleScript statements. This
    // is the exact exploit the hygiene assertions exist to catch: a doomed
    // playlist NAME smuggling what looks like a second mutation verb into
    // the compiled script text.
    @Test("hostile mutation-verb substrings inside an escaped name stay inert outside the literal")
    func hostileMutationVerbNameStaysInert() throws {
        // Contains every needle the hygiene assertions scan for (" delete ",
        // "make new", " duplicate ", " move ", " remove ", " empty",
        // "set name"), plus a literal quote and backslash for extra
        // hostility. `appleScriptString` escapes only `"`, `\`, and C0
        // controls, so the plain ASCII words and the spaces around them
        // survive unchanged inside the quoted literal.
        let hostileVerbName =
            "please \"quoted\" delete make new duplicate move remove empty set name \\ trailing"
        let script = deleteScript(name: hostileVerbName)
        let probe = ByteText(script)

        let literal = appleScriptString(hostileVerbName)
        let literalOffset = try #require(probe.offset(of: literal))
        let before = probe.slice(0..<literalOffset)
        let after = probe.slice((literalOffset + Array(literal.utf8).count)..<probe.bytes.count)
        let outside = ByteText(bytes: before.bytes + after.bytes)

        // " delete " is special: the genuine `    delete doomedPlaylist`
        // statement itself legitimately contains " delete " (its leading
        // indentation supplies the preceding space, "doomedPlaylist"
        // supplies the following one), so exactly ONE outside occurrence is
        // expected and correct — it is the real mutation statement, not a
        // leak from the literal. Every other needle must be fully absent
        // outside the literal: this codebase's writers never emit them.
        #expect(outside.count(of: " delete ") == 1, "only the genuine delete statement, no leak from the literal")
        for needle in ["make new", " duplicate ", " move ", " remove ", " empty", "set name"] {
            #expect(outside.count(of: needle) == 0, "\(needle) must not appear outside the escaped name literal")
        }

        // Whole-script counts equal exactly the literal's one embedded copy
        // of each needle, plus (for " delete " only) the one genuine
        // mutation statement — never a second genuine occurrence of any verb.
        #expect(probe.contains("\n    delete doomedPlaylist\n"))
        #expect(probe.count(of: " delete ") == 2, "one real delete statement + one inside the escaped literal")
        #expect(probe.count(of: "make new") == 1, "confined to the escaped literal")
        #expect(probe.count(of: " duplicate ") == 1, "confined to the escaped literal")
        #expect(probe.count(of: " move ") == 1, "confined to the escaped literal")
        #expect(probe.count(of: " remove ") == 1, "confined to the escaped literal")
        #expect(probe.count(of: " empty") == 1, "confined to the escaped literal")
        #expect(probe.count(of: "set name") == 1, "confined to the escaped literal")
        #expect(probe.count(of: "tell application " + appleScriptString(musicAppPath)) == 1)
    }
}

@Suite("MutationScriptBuilder compile-only gates (osacompile; never executed)", .serialized)
struct MutationScriptBuilderCompileTests {

    @Test(
        "hostile-name delete writer compiles",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func hostileDeleteScriptCompiles() throws {
        let script = deleteScript(name: hostileName, persistentID: "PID \"X\" \\")
        let result = try compileOnly(script)
        #expect(result.status == 0, "\(result.stderr)")
    }

    @Test(
        "target-guarded delete writer compiles",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func targetGuardedDeleteScriptCompiles() throws {
        let result = try compileOnly(deleteScript(targetGuard: mergedTargetGuard))
        #expect(result.status == 0, "\(result.stderr)")
    }

    @Test(
        "delete writer compiles for a 1,600-track pinned playlist",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func largeDeleteScriptCompiles() throws {
        let persistentIDs = (0..<1600).map { String(format: "P%08d", $0) }
        let result = try compileOnly(deleteScript(trackPIDs: persistentIDs))
        #expect(result.status == 0, "\(result.stderr)")
    }

    @Test(
        "the fail-closed degenerate script compiles",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func failClosedScriptCompiles() throws {
        var scalars = String.UnicodeScalarView()
        for codePoint in 0xE000..<0xF900 {
            scalars.append(Unicode.Scalar(UInt32(codePoint))!)
        }
        let result = try compileOnly(deleteScript(trackPIDs: [String(scalars)]))
        #expect(result.status == 0, "\(result.stderr)")
    }

    // Fix round 1, gap 1: compile-only coverage for the count-0 payload
    // branch, both call sites (doomed-track payload and target payload).

    @Test(
        "zero-track doomed-playlist delete writer compiles",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func zeroTrackDoomedPlaylistScriptCompiles() throws {
        let result = try compileOnly(deleteScript(trackPIDs: []))
        #expect(result.status == 0, "\(result.stderr)")
    }

    @Test(
        "zero-track target-guarded delete writer compiles",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func zeroTrackTargetGuardedScriptCompiles() throws {
        let emptyTargetGuard = MutationScriptBuilder.TargetGuardPayload(
            name: "Empty Target", orderedTrackPersistentIDs: []
        )
        let result = try compileOnly(deleteScript(targetGuard: emptyTargetGuard))
        #expect(result.status == 0, "\(result.stderr)")
    }
}

// MARK: - Wave B Task 6: buildRenameScript (spec B1/B5 writer half)
//
// Name reconciliation against the landed Task 5 file (MutationScriptBuilder.swift):
// the brief's restated interface referenced a generic `mutationGuardLocals` and a
// zero-arg `pinnedPlaylistGuardLines()` that Task 5 did not create — Task 5 only
// has the delete-specific `deleteScriptLocals` with the guard block inlined in
// `buildDeleteScript`. To make the "same guards, byte-identical prologue"
// contract true by construction (never by copying lines), Task 6 extracts that
// inlined block into a new shared `pinnedPlaylistGuardLines()` and points
// `buildDeleteScript` at it (output bytes unchanged — proven by every existing
// test above staying green). The pinned-playlist local is `doomedPlaylist`
// (Task 5's spelling, reused rather than introduced as `pinnedPlaylist`, so the
// delete writer's literal output — e.g. `delete doomedPlaylist`, asserted upon
// throughout the suite above — never changes). The rename verb is therefore
// `set name of doomedPlaylist to newPlaylistName`.

private func renameScript(
    name: String = "Trance 2022",
    persistentID: String = "PID-DOOMED",
    trackPIDs: [String] = ["T0", "T1", "T2"],
    newName: String = "Trance 2022 (fixed)"
) -> String {
    MutationScriptBuilder.buildRenameScript(
        expectedName: name,
        expectedPersistentID: persistentID,
        expectedTrackPersistentIDs: trackPIDs,
        newName: newName
    )
}

@Suite("Rename script builder")
struct RenameScriptBuilderTests {

    @Test("emits exactly one set-name verb and no other mutation verb")
    func exactlyOneSetNameVerb() {
        let script = renameScript()
        #expect(ByteText(script).count(of: "set name of doomedPlaylist to newPlaylistName") == 1)
        let lowered = ByteText(script.lowercased())
        #expect(lowered.count(of: "set name") == 1)
        #expect(!lowered.contains("delete "))
        #expect(!lowered.contains("make "))
        #expect(!lowered.contains("duplicate "))
        #expect(!lowered.contains("move "))
        #expect(!lowered.contains("remove "))
        #expect(!lowered.contains("empty "))
    }

    @Test("guard prologue precedes the verb and is byte-identical to the delete writer's")
    func sharedGuardProloguePrecedesVerb() throws {
        let ids = ["T0", "T1", "T2"]
        let deleteScript = MutationScriptBuilder.buildDeleteScript(
            expectedName: "Trance 2022",
            expectedPersistentID: "PID-DOOMED",
            expectedTrackPersistentIDs: ids,
            targetGuard: nil
        )
        let rename = MutationScriptBuilder.buildRenameScript(
            expectedName: "Trance 2022",
            expectedPersistentID: "PID-DOOMED",
            expectedTrackPersistentIDs: ids,
            newName: "Trance 2022 (fixed)"
        )
        let tellLine = "tell application \"/System/Applications/Music.app\""
        let deleteProbe = ByteText(deleteScript)
        let renameProbe = ByteText(rename)
        let deleteTell = try #require(deleteProbe.offset(of: tellLine))
        let renameTell = try #require(renameProbe.offset(of: tellLine))
        let deleteVerb = try #require(
            deleteProbe.offset(of: "delete doomedPlaylist", after: deleteTell)
        )
        let renameVerb = try #require(
            renameProbe.offset(of: "set name of doomedPlaylist to newPlaylistName", after: renameTell)
        )
        // The contract's "same guards": everything inside the tell before the
        // single verb is byte-identical across the two writers.
        expectByteEqual(
            renameProbe.slice(renameTell..<renameVerb).text,
            deleteProbe.slice(deleteTell..<deleteVerb).text,
            context: "shared pinned-guard prologue"
        )
        // And the PID-pinned lookup sits between the tell and the verb.
        let lookup = try #require(
            renameProbe.offset(of: "every user playlist", after: renameTell)
        )
        #expect(lookup < renameVerb)
    }

    @Test("hostile new names are emitted as escaped literals only")
    func hostileNewNameIsEscaped() {
        let hostile = "Bad\"Name \\ mix\nline\ttab\u{07}bell"
        let script = renameScript(newName: hostile)
        let probe = ByteText(script)
        #expect(probe.contains("set newPlaylistName to " + appleScriptString(hostile)))
        // Spot-check the exact escaped byte sequence (json.dumps parity:
        // \" for quote, \\ for backslash, \n, \t, and \u0007 for the C0
        // control BEL — appleScriptString's default branch for scalars
        // below U+0020 that have no short escape). Built by concatenation, not
        // a single literal, so no raw control byte sits in this source file.
        let expectedBellEscape = "set newPlaylistName to "
            + "\"" + "Bad" + "\\\"" + "Name " + "\\\\" + " mix"
            + "\\n" + "line" + "\\t" + "tab" + "\\u0007" + "bell" + "\""
        #expect(probe.contains(expectedBellEscape))
        // Non-tautological pin, mirroring the delete writer's escaping pin.
        let pinned = ByteText(renameScript(newName: "A\"B\\C"))
        #expect(pinned.contains("set newPlaylistName to \"A\\\"B\\\\C\""))
    }

    @Test(
        "rename writer compiles (hostile name, PUA and non-BMP scalars)",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func renameWriterCompiles() throws {
        let script = renameScript(
            newName: "U\u{0308}nicode \u{2014} nam\u{0301}e \"x\\y\"\t\u{E000}\u{1D11E}"
        )
        let result = try compileOnly(script)
        #expect(result.status == 0, "\(result.stderr)")
    }

    // MARK: - mirrors Task 5 fix-round gap 1: the pidPayloadParseLines
    // count-0 branch (an empty pinned-playlist track list) was previously
    // untested for the delete writer's own payload; same gap applies here.

    @Test("a zero-track pinned playlist rename exercises the count-0 payload branch and still guards before the verb")
    func zeroTrackRenameUsesCountZeroBranch() throws {
        let script = renameScript(trackPIDs: [])
        let probe = ByteText(script)

        #expect(probe.count(of: "set name") == 1)
        #expect(probe.contains("set name of doomedPlaylist to newPlaylistName"))
        #expect(probe.contains("set expectedTrackCount to 0"))
        #expect(probe.contains("set expectedTrackPIDPayload to " + appleScriptString("")))

        let verbOffset = try #require(probe.offset(of: "set name of doomedPlaylist to newPlaylistName"))
        for guardNeedle in [
            "error \"expected playlist persistent ID is absent\"",
            "error \"expected playlist persistent ID is duplicated\"",
            "if (my textCodePointsMatch(expectedPlaylistName, liveTextValue)) is not true then error \"pinned playlist name changed\"",
            "if (count of doomedTracks) is not expectedTrackCount then error \"pinned playlist track count changed\"",
            "repeat with trackPosition from 1 to expectedTrackCount",
            "error \"internal expected track persistent ID payload count mismatch\"",
        ] {
            let guardOffset = try #require(probe.offset(of: guardNeedle), "\(guardNeedle)")
            #expect(guardOffset < verbOffset, "\(guardNeedle) must precede the verb")
        }
    }

    // MARK: - mirrors Task 5 fix-round gap 2: mutation-verb hygiene must be
    // proven against a pinned playlist NAME smuggling every mutation verb
    // substring, including "set name" itself — the rename writer's own verb.

    @Test("hostile mutation-verb substrings inside a hostile expected name stay inert outside the literal")
    func hostileMutationVerbNameStaysInert() throws {
        let hostileVerbName =
            "please \"quoted\" delete make new duplicate move remove empty set name \\ trailing"
        let script = renameScript(name: hostileVerbName)
        let probe = ByteText(script)

        let literal = appleScriptString(hostileVerbName)
        let literalOffset = try #require(probe.offset(of: literal))
        let before = probe.slice(0..<literalOffset)
        let after = probe.slice((literalOffset + Array(literal.utf8).count)..<probe.bytes.count)
        let outside = ByteText(bytes: before.bytes + after.bytes)

        // "set name" is special here: the genuine
        // `set name of doomedPlaylist to newPlaylistName` statement itself
        // legitimately contains it, so exactly ONE outside occurrence is
        // expected — the real rename verb, not a leak from the literal.
        // Unlike the delete writer, a rename script has no genuine
        // occurrence of any of the other needles at all.
        #expect(outside.count(of: "set name") == 1, "only the genuine set-name statement, no leak from the literal")
        for needle in [" delete ", "make new", " duplicate ", " move ", " remove ", " empty"] {
            #expect(outside.count(of: needle) == 0, "\(needle) must not appear outside the escaped name literal")
        }

        #expect(probe.contains("set name of doomedPlaylist to newPlaylistName"))
        #expect(probe.count(of: "set name") == 2, "one real set-name statement + one inside the escaped literal")
        #expect(probe.count(of: " delete ") == 1, "confined to the escaped literal (no real delete verb in a rename script)")
        #expect(probe.count(of: "make new") == 1, "confined to the escaped literal")
        #expect(probe.count(of: " duplicate ") == 1, "confined to the escaped literal")
        #expect(probe.count(of: " move ") == 1, "confined to the escaped literal")
        #expect(probe.count(of: " remove ") == 1, "confined to the escaped literal")
        #expect(probe.count(of: " empty") == 1, "confined to the escaped literal")
        #expect(probe.count(of: "tell application " + appleScriptString(musicAppPath)) == 1)
    }

    @Test("delimiter exhaustion fails closed: one error statement, no tell, no verb")
    func delimiterExhaustionFailsClosed() {
        var scalars = String.UnicodeScalarView()
        for codePoint in 0xE000..<0xF900 {
            scalars.append(Unicode.Scalar(UInt32(codePoint))!)
        }
        let script = renameScript(trackPIDs: [String(scalars)])
        expectByteEqual(
            script,
            "error \"expected track persistent IDs exhaust the guarded payload delimiters\"\n",
            context: "rename delimiter exhaustion"
        )
        let probe = ByteText(script)
        #expect(probe.count(of: "set name") == 0)
        #expect(!probe.contains("tell application"))
    }

    @Test("the builder is deterministic: identical inputs, identical bytes")
    func builderIsDeterministic() {
        expectByteEqual(
            renameScript(),
            renameScript(),
            context: "rename writer determinism"
        )
    }
}

@Suite("Rename script builder compile-only gates (osacompile; never executed)", .serialized)
struct RenameScriptBuilderCompileTests {

    @Test(
        "zero-track rename writer compiles",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func zeroTrackRenameScriptCompiles() throws {
        let result = try compileOnly(renameScript(trackPIDs: []))
        #expect(result.status == 0, "\(result.stderr)")
    }

    @Test(
        "rename writer compiles for a 1,600-track pinned playlist",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func largeRenameScriptCompiles() throws {
        let persistentIDs = (0..<1600).map { String(format: "P%08d", $0) }
        let result = try compileOnly(renameScript(trackPIDs: persistentIDs))
        #expect(result.status == 0, "\(result.stderr)")
    }

    @Test(
        "the rename writer's fail-closed degenerate script compiles",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func failClosedRenameScriptCompiles() throws {
        var scalars = String.UnicodeScalarView()
        for codePoint in 0xE000..<0xF900 {
            scalars.append(Unicode.Scalar(UInt32(codePoint))!)
        }
        let result = try compileOnly(renameScript(trackPIDs: [String(scalars)]))
        #expect(result.status == 0, "\(result.stderr)")
    }
}
