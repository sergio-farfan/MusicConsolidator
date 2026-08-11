// PlaylistListingTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// M8 Part 1 — the playlist-enumeration read surface: the STATIC
// `buildListPlaylistsJXA` script (zero parameters, zero interpolation — the
// full text is pinned verbatim below so ANY interpolation of ANY value would
// break the pin), the strict `parsePlaylistListing` wire gate (same
// StrictJSONScanner pre-pass + fail-closed typed parsing as the other
// reads), and `MusicBridgeSession.listPlaylists()` orchestration over
// FakeRunner.
//
// SAFETY (M4 discipline, first new script text since M4): the enumeration
// script tells Music, so it is COMPILE-ONLY here (osacompile -l JavaScript;
// never executed, no osascript, no Apple events). Parse and session tests
// replay canned wire text through FakeRunner only.

import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

// MARK: - the pinned static script text

/// The COLUMNAR enumeration script (post bulk-read-speedup Task 1), pinned
/// VERBATIM. This is the load-bearing safety property of the surface: the
/// builder takes no parameters, and its output must equal this constant
/// byte-for-byte on every call — no user input, no plan data, nothing can
/// reach the script text.
private let expectedListPlaylistsJXA = """
const Music = Application("/System/Applications/Music.app");

const playlistRefs = Music.userPlaylists;
const expectedCount = playlistRefs.length;

// Live -1728 fix (2026-08-11): a columnar get against an EMPTY
// element collection resolves no object and errors; an empty
// library short-circuits every column to [].
const ids = expectedCount === 0 ? [] : playlistRefs.id();
if (!Array.isArray(ids)) {
    throw new Error("column type mismatch: id");
}
if (ids.length !== expectedCount) {
    throw new Error("column length mismatch: id");
}

const names = expectedCount === 0 ? [] : playlistRefs.name();
if (!Array.isArray(names)) {
    throw new Error("column type mismatch: name");
}
if (names.length !== expectedCount) {
    throw new Error("column length mismatch: name");
}

const persistentIds = expectedCount === 0 ? [] : playlistRefs.persistentID();
if (!Array.isArray(persistentIds)) {
    throw new Error("column type mismatch: persistent_id");
}
if (persistentIds.length !== expectedCount) {
    throw new Error("column length mismatch: persistent_id");
}

const trackCounts = [];
for (let index = 0; index < expectedCount; index++) {
    trackCounts.push(playlistRefs[index].tracks.length);
}
if (!trackCounts.every(function (value) { return typeof value === "number"; })) {
    throw new Error("column type mismatch: track_count");
}

const smartFlags = expectedCount === 0 ? [] : playlistRefs.smart();
if (!Array.isArray(smartFlags)) {
    throw new Error("column type mismatch: smart");
}
if (smartFlags.length !== expectedCount) {
    throw new Error("column length mismatch: smart");
}

const specialKinds = expectedCount === 0 ? [] : playlistRefs.specialKind();
if (!Array.isArray(specialKinds)) {
    throw new Error("column type mismatch: special_kind");
}
if (specialKinds.length !== expectedCount) {
    throw new Error("column length mismatch: special_kind");
}

const records = [];
for (let index = 0; index < expectedCount; index++) {
    records.push({
        id: ids[index],
        name: names[index],
        persistent_id: persistentIds[index],
        track_count: trackCounts[index],
        smart: smartFlags[index],
        special_kind: specialKinds[index]
    });
}

JSON.stringify({playlists: records});

"""

/// The PRE-Task-1 per-playlist-loop enumeration script, pinned VERBATIM.
/// `legacyListPlaylistsScript` must keep emitting exactly this text — Task 3's
/// Diagnostics cross-check reads the same library with this text and the
/// columnar text above and diffs the parsed results, so any drift here would
/// silently invalidate that cross-check.
private let expectedLegacyListPlaylistsJXA = """
const Music = Application("/System/Applications/Music.app");

const playlists = Music.userPlaylists().map(function (playlist) {
    return {
        id: playlist.id(),
        name: playlist.name(),
        persistent_id: playlist.persistentID(),
        track_count: playlist.tracks().length,
        smart: playlist.smart(),
        special_kind: playlist.specialKind()
    };
});

JSON.stringify({playlists: playlists});

"""

@Suite("List-playlists JXA builder (static, zero interpolation)")
struct ListPlaylistsBuilderTests {

    @Test("script text is the pinned constant, byte for byte")
    func scriptTextIsPinned() {
        expectByteEqual(
            buildListPlaylistsJXA(),
            expectedListPlaylistsJXA,
            context: "buildListPlaylistsJXA"
        )
    }

    @Test("builder is deterministic across calls")
    func builderIsDeterministic() {
        expectByteEqual(
            buildListPlaylistsJXA(),
            buildListPlaylistsJXA(),
            context: "two calls"
        )
    }

    @Test("enumeration mirrors the read JXA's inclusion set and app targeting")
    func mirrorsReadJXASemantics() {
        let listing = ByteText(buildListPlaylistsJXA())
        let read = ByteText(buildReadJXA(name: "any"))

        // Same absolute-path Application(...) targeting line as the read JXA
        // (and tied back to the module constant without interpolating it into
        // the production template).
        let applicationLine = "const Music = Application(\(appleScriptString(musicAppPath)));"
        #expect(listing.contains(applicationLine))
        #expect(read.contains(applicationLine))

        // Same enumeration root: every user playlist — smart playlists and
        // folder playlists included, subscription playlists excluded — so the
        // browser's groups always agree with what a subsequent audit reads.
        // The listing script accesses the root as an UN-CALLED specifier
        // collection (`Music.userPlaylists`, no parens — see
        // `usesUncalledPlaylistsSpecifierCollection` below for why), so this
        // check does not require the call-parens the read script still uses.
        #expect(listing.contains("Music.userPlaylists"))
        #expect(read.contains("Music.userPlaylists()"))

        // The listing must NOT filter by name (that is the read script's job).
        #expect(!listing.contains(".filter("))
        #expect(!listing.contains("requestedName"))
    }

    @Test("script is read-only in shape: no writer keywords")
    func scriptHasNoWriterShapes() {
        let listing = ByteText(buildListPlaylistsJXA())
        for forbidden in ["make", "delete", "duplicate", "move", "set ", "add("] {
            #expect(!listing.contains(forbidden), "forbidden shape: \(forbidden)")
        }
    }

    @Test(
        "static enumeration script compiles (osacompile -l JavaScript; never executed)",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func staticScriptCompiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m8-jxa-compile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("listing.scpt")
        let result = try runTool(
            osacompilePath,
            arguments: ["-l", "JavaScript", "-o", output.path],
            stdinText: buildListPlaylistsJXA()
        )
        #expect(result.status == 0, "\(result.stderr)")
    }

    // MARK: - Task 1 (bulk-read speedup): columnar shape pins

    @Test("fetches every scalar column with one array-specifier call each")
    func fetchesColumnsWithArraySpecifiers() {
        let listing = ByteText(buildListPlaylistsJXA())
        for column in [
            "playlistRefs.id()", "playlistRefs.name()", "playlistRefs.persistentID()",
            "playlistRefs.smart()", "playlistRefs.specialKind()",
        ] {
            #expect(listing.contains(column), "missing columnar fetch: \(column)")
        }
    }

    // I1 (review fix, 2026-08-10): the earlier pin suite could not tell a
    // specifier COLLECTION apart from an EVALUATED array — text presence
    // alone can't distinguish `Music.userPlaylists()` (evaluated into a
    // plain Array with no `.id`/`.name`/… methods; every column read after
    // it is a runtime TypeError) from `Music.userPlaylists` (the un-called,
    // still-chainable specifier collection the columnar reads require).
    // This pin locks in the un-called form and rejects the evaluated one.
    @Test("the playlists root is an un-called specifier collection, never an evaluated array")
    func usesUncalledPlaylistsSpecifierCollection() {
        let listing = ByteText(buildListPlaylistsJXA())
        #expect(!listing.contains("Music.userPlaylists();"), "root must not be evaluated with ()")
        #expect(listing.contains("Music.userPlaylists;"), "root must be the un-called specifier")
    }

    // I2 (review fix, 2026-08-10): extended to ALL SIX columns, not just the
    // first three — every column read, including the track_count loop, must
    // follow the count-first read.
    @Test("reads the object count first, before any column fetch")
    func readsCountFirst() {
        let script = buildListPlaylistsJXA()
        guard let countRange = script.range(of: "const expectedCount = playlistRefs.length;") else {
            Issue.record("count-first read is missing")
            return
        }
        for column in [
            "playlistRefs.id()", "playlistRefs.name()", "playlistRefs.persistentID()",
            "playlistRefs[index].tracks.length", "playlistRefs.smart()", "playlistRefs.specialKind()",
        ] {
            guard let columnRange = script.range(of: column) else {
                Issue.record("missing columnar fetch: \(column)")
                continue
            }
            #expect(countRange.upperBound <= columnRange.lowerBound, "\(column) read before count")
        }
    }

    // M2 (review fix, bulk-read-speedup Task 2): the TYPE branch
    // (`!Array.isArray(...)`) and the LENGTH branch (`.length !==
    // expectedCount`) are separate `if` statements with their own accurate,
    // verbatim message per column — closes the deferred Task 1 minor
    // ("type-branch guard message says 'length mismatch' inaccurately").
    //
    // M3 (final review, 2026-08-11): `track_count` is deliberately EXCLUDED
    // from the length-message list. It is a loop-built JS array literal whose
    // bound is `expectedCount`, so an Array.isArray/length guard on it could
    // never fire for any library state; both dead guards were deleted and the
    // column keeps only the per-element `typeof` check, which reports a TYPE
    // mismatch. The next assertion pins that asymmetry so the messages and the
    // script can't silently drift apart again.
    @Test("alignment guard names the mismatched column, verbatim, for every field's type and length")
    func alignmentGuardNamesEveryColumn() {
        let listing = ByteText(buildListPlaylistsJXA())
        let wholeColumnFields = ["id", "name", "persistent_id", "smart", "special_kind"]
        for field in wholeColumnFields {
            #expect(listing.contains("column type mismatch: \(field)"), "missing type mismatch message: \(field)")
            #expect(listing.contains("column length mismatch: \(field)"), "missing length mismatch message: \(field)")
        }
        // The loop-built column: type message only.
        #expect(listing.contains("column type mismatch: track_count"))
    }

    // M3 (final review, 2026-08-11): the two guards that could not fire are
    // gone, and must stay gone — an `Array.isArray(trackCounts)` or a
    // `trackCounts.length !== expectedCount` branch is unreachable by
    // construction and misrepresents the real guard surface.
    @Test("track_count carries no dead array/length guard and no length message")
    func trackCountHasNoDeadGuards() {
        let listing = ByteText(buildListPlaylistsJXA())
        #expect(!listing.contains("!Array.isArray(trackCounts)"))
        #expect(!listing.contains("trackCounts.length !== expectedCount"))
        #expect(!listing.contains("column length mismatch: track_count"))
        // The one guard that CAN fire stays.
        #expect(listing.contains("typeof value === \"number\""))
    }

    // C2 (review fix, 2026-08-10): track_count has no sdef columnar
    // counterpart — it is a per-playlist LEAN count loop, indexed off the
    // SAME `playlistRefs` collection, that never calls `.tracks()` WITH
    // parens (which would materialize every track specifier of that
    // playlist instead of just counting them).
    @Test("track_count is a per-playlist lean count loop, never a materializing tracks() call")
    func trackCountUsesLeanPerPlaylistCountLoop() {
        let listing = ByteText(buildListPlaylistsJXA())
        #expect(listing.contains("playlistRefs[index].tracks.length"))
        #expect(!listing.contains(".tracks()"), "must never materialize track specifiers")
    }

    @Test("the old per-playlist property loop is gone")
    func perPlaylistPropertyLoopIsAbsent() {
        let listing = ByteText(buildListPlaylistsJXA())
        // The disappearing token: the Task-1 per-object record-building loop
        // that called SIX property getters per playlist inside one closure.
        #expect(!listing.contains("Music.userPlaylists().map(function (playlist)"))
        #expect(!listing.contains("playlist.id()"))
        #expect(!listing.contains("playlist.name()"))
        #expect(!listing.contains("playlist.persistentID()"))
        #expect(!listing.contains("playlist.smart()"))
        #expect(!listing.contains("playlist.specialKind()"))
    }
}

@Suite("Legacy list-playlists JXA builder (Task 3 Diagnostics cross-check only)")
struct LegacyListPlaylistsBuilderTests {

    @Test("legacy script text is the pre-Task-1 pinned constant, byte for byte")
    func legacyScriptTextIsPinned() {
        expectByteEqual(
            legacyListingScript(),
            expectedLegacyListPlaylistsJXA,
            context: "legacyListPlaylistsScript"
        )
    }

    @Test("legacy builder is deterministic across calls")
    func legacyBuilderIsDeterministic() {
        expectByteEqual(
            legacyListingScript(),
            legacyListingScript(),
            context: "two calls"
        )
    }

    @Test(
        "legacy enumeration script compiles (osacompile -l JavaScript; never executed)",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func legacyStaticScriptCompiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m8-jxa-compile-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("listing-legacy.scpt")
        let result = try runTool(
            osacompilePath,
            arguments: ["-l", "JavaScript", "-o", output.path],
            stdinText: legacyListingScript()
        )
        #expect(result.status == 0, "\(result.stderr)")
    }
}

// MARK: - wire fixtures

private func listingEntry(
    id: String = "100",
    name: String = "Playlist",
    persistentId: String = "PID0",
    trackCount: String = "10",
    smart: String = "false",
    specialKind: String = "\"none\""
) -> String {
    """
    {"id": \(id), "name": "\(name)", "persistent_id": "\(persistentId)", \
    "track_count": \(trackCount), "smart": \(smart), "special_kind": \(specialKind)}
    """
}

private func listingWire(_ entries: [String]) -> String {
    "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

@Suite("Playlist listing strict parse")
struct PlaylistListingParseTests {

    @Test("parses a complete listing ordered by ascending playlist id")
    func parsesCompleteListing() throws {
        // Wire order deliberately NOT id order; duplicate names are LEGAL
        // (they are the point of the surface).
        let raw = listingWire([
            listingEntry(id: "300", name: "Trance 2022", persistentId: "P-HIGH", trackCount: "10"),
            listingEntry(id: "100", name: "Trance 2022", persistentId: "P-LOW", trackCount: "9"),
            listingEntry(
                id: "200", name: "Mixes", persistentId: "P-FOLDER",
                trackCount: "42", smart: "false", specialKind: "\"folder\""
            ),
            listingEntry(
                id: "250", name: "Top Rated", persistentId: "P-SMART",
                trackCount: "25", smart: "true"
            ),
        ])

        let listings = try parsePlaylistListing(raw: raw)

        #expect(listings.count == 4)
        #expect(listings.map(\.persistentId) == ["P-LOW", "P-FOLDER", "P-SMART", "P-HIGH"])
        #expect(listings.map(\.playlistId) == [100, 200, 250, 300])
        #expect(listings[0].name == "Trance 2022")
        #expect(listings[3].name == "Trance 2022")
        #expect(listings[0].trackCount == 9)
        #expect(listings[1].specialKind == "folder")
        #expect(listings[1].isSmart == false)
        #expect(listings[2].isSmart == true)
    }

    @Test("equal ids keep wire order (stable sort, like parseAllCopies)")
    func equalIdsKeepWireOrder() throws {
        let raw = listingWire([
            listingEntry(id: "7", name: "B", persistentId: "P-B"),
            listingEntry(id: "7", name: "A", persistentId: "P-A"),
        ])
        let listings = try parsePlaylistListing(raw: raw)
        #expect(listings.map(\.persistentId) == ["P-B", "P-A"])
    }

    @Test("duplicate names are legal; duplicate persistent IDs are rejected")
    func duplicatePersistentIdsRejected() throws {
        let legal = listingWire([
            listingEntry(id: "1", name: "Same", persistentId: "P1"),
            listingEntry(id: "2", name: "Same", persistentId: "P2"),
            listingEntry(id: "3", name: "Same", persistentId: "P3"),
        ])
        #expect(try parsePlaylistListing(raw: legal).count == 3)

        let dup = listingWire([
            listingEntry(id: "1", name: "One", persistentId: "P1"),
            listingEntry(id: "2", name: "Two", persistentId: "P1"),
        ])
        expectThrowsByteEqualMessage(
            "playlist listing contains a duplicate persistent ID",
            context: "duplicate pid"
        ) {
            _ = try parsePlaylistListing(raw: dup)
        }
    }

    @Test("canonically-equivalent but scalar-different persistent IDs are distinct")
    func scalarDifferentPidsAreDistinct() throws {
        // NFC vs NFD: String == would call these duplicates; the scalar-exact
        // gate must not.
        let raw = listingWire([
            listingEntry(id: "1", name: "One", persistentId: "Caf\\u00e9"),
            listingEntry(id: "2", name: "Two", persistentId: "Cafe\\u0301"),
        ])
        let listings = try parsePlaylistListing(raw: raw)
        #expect(listings.count == 2)
    }

    @Test("unicode and FEFF names are scalar-preserved")
    func unicodeNamesScalarPreserved() throws {
        let raw = listingWire([
            listingEntry(id: "1", name: "\\ufeffKdrama", persistentId: "P1"),
            listingEntry(id: "2", name: "Cafe\\u0301 \\u2014 Mix\\u200b", persistentId: "P2"),
        ])
        let listings = try parsePlaylistListing(raw: raw)
        let feffName = scalarString(0xFEFF) + "Kdrama"
        #expect(listings[0].name.unicodeScalars.elementsEqual(feffName.unicodeScalars))
        let zwspName = "Cafe" + scalarString(0x301) + " " + scalarString(0x2014) + " Mix" + scalarString(0x200B)
        #expect(listings[1].name.unicodeScalars.elementsEqual(zwspName.unicodeScalars))
    }

    @Test("huge-but-integral track counts parse; out-of-range and fractional fail closed")
    func trackCountBoundaries() throws {
        let huge = listingWire([listingEntry(trackCount: "1099511627776")]) // 2^40
        #expect(try parsePlaylistListing(raw: huge)[0].trackCount == 1_099_511_627_776)

        for hostile in ["1e300", "2.5", "9223372036854775808"] {
            expectThrowsByteEqualMessage(
                "playlist track_count must be an integer",
                context: "track_count \(hostile)"
            ) {
                _ = try parsePlaylistListing(raw: listingWire([listingEntry(trackCount: hostile)]))
            }
        }

        expectThrowsByteEqualMessage(
            "playlist track_count must be a non-negative integer",
            context: "negative track_count"
        ) {
            _ = try parsePlaylistListing(raw: listingWire([listingEntry(trackCount: "-1")]))
        }
    }

    @Test("every missing key fails closed with a typed message")
    func missingKeysFailClosed() {
        let full: [(key: String, fragment: String, message: String)] = [
            ("id", "\"id\": 100, ", "playlist id must be a number"),
            ("name", "\"name\": \"N\", ", "playlist name must be a string"),
            ("persistent_id", "\"persistent_id\": \"P\", ", "playlist persistent_id must be a string"),
            ("track_count", "\"track_count\": 1, ", "playlist track_count must be an integer"),
            ("smart", "\"smart\": false, ", "playlist smart must be a boolean"),
            ("special_kind", "\"special_kind\": \"none\", ", "playlist special_kind must be a string"),
        ]
        for omitted in full {
            let kept = full.filter { $0.key != omitted.key }.map(\.fragment).joined()
            let entry = "{\(kept.dropLast(2))}"
            expectThrowsByteEqualMessage(
                omitted.message, context: "missing \(omitted.key)"
            ) {
                _ = try parsePlaylistListing(raw: listingWire([entry]))
            }
        }
    }

    @Test("every wrong-typed field fails closed with a typed message")
    func wrongTypesFailClosed() {
        let mutations: [(raw: String, message: String, context: String)] = [
            (listingWire([listingEntry(id: "\"100\"")]),
             "playlist id must be a number", "id string"),
            (listingWire([listingEntry(id: "null")]),
             "playlist id must be a number", "id null"),
            (listingWire([listingEntry(trackCount: "null")]),
             "playlist track_count must be an integer", "track_count null"),
            (listingWire([listingEntry(trackCount: "true")]),
             "playlist track_count must be an integer", "track_count boolean"),
            (listingWire([listingEntry(smart: "\"yes\"")]),
             "playlist smart must be a boolean", "smart string"),
            (listingWire([listingEntry(smart: "1")]),
             "playlist smart must be a boolean", "smart integer"),
            (listingWire([listingEntry(specialKind: "null")]),
             "playlist special_kind must be a string", "special_kind null"),
            (listingWire([listingEntry(specialKind: "0")]),
             "playlist special_kind must be a string", "special_kind integer"),
        ]
        for mutation in mutations {
            expectThrowsByteEqualMessage(mutation.message, context: mutation.context) {
                _ = try parsePlaylistListing(raw: mutation.raw)
            }
        }

        // A dedicated wrong-type probe for name and persistent_id built as
        // raw JSON (the fixture helper quotes them).
        expectThrowsByteEqualMessage("playlist name must be a string", context: "name number") {
            _ = try parsePlaylistListing(raw: listingWire([
                "{\"id\": 1, \"name\": 3, \"persistent_id\": \"P\", \"track_count\": 1, \"smart\": false, \"special_kind\": \"none\"}"
            ]))
        }
        expectThrowsByteEqualMessage(
            "playlist persistent_id must be a string", context: "pid null"
        ) {
            _ = try parsePlaylistListing(raw: listingWire([
                "{\"id\": 1, \"name\": \"N\", \"persistent_id\": null, \"track_count\": 1, \"smart\": false, \"special_kind\": \"none\"}"
            ]))
        }
    }

    @Test("structural mutations fail closed")
    func structuralMutations() {
        expectThrowsByteEqualMessage("Music returned invalid JSON", context: "not json") {
            _ = try parsePlaylistListing(raw: "not json")
        }
        expectThrowsByteEqualMessage("Music returned invalid JSON", context: "trailing comma") {
            _ = try parsePlaylistListing(raw: "{\"playlists\": [],}")
        }
        expectThrowsByteEqualMessage("Music returned invalid JSON", context: "leading BOM") {
            _ = try parsePlaylistListing(raw: scalarString(0xFEFF) + "{\"playlists\": []}")
        }
        expectThrowsByteEqualMessage(
            "Music playlist listing must be a JSON object", context: "top-level array"
        ) {
            _ = try parsePlaylistListing(raw: "[]")
        }
        expectThrowsByteEqualMessage(
            "playlists must be a JSON array", context: "playlists not a list"
        ) {
            _ = try parsePlaylistListing(raw: "{\"playlists\": 3}")
        }
        expectThrowsByteEqualMessage(
            "playlists must be a JSON array", context: "playlists missing"
        ) {
            _ = try parsePlaylistListing(raw: "{}")
        }
        expectThrowsByteEqualMessage(
            "playlist listing entry must be a JSON object", context: "entry not an object"
        ) {
            _ = try parsePlaylistListing(raw: "{\"playlists\": [3]}")
        }
    }

    @Test("empty listing parses to an empty array")
    func emptyListingParses() throws {
        #expect(try parsePlaylistListing(raw: "{\"playlists\": []}").isEmpty)
    }
}

@Suite("listPlaylists session orchestration (FakeRunner)")
struct ListPlaylistsSessionTests {

    @Test("dispatches exactly one read command carrying the static script")
    func dispatchesStaticScript() throws {
        let raw = listingWire([listingEntry(id: "1", name: "One", persistentId: "P1")])
        let runner = FakeRunner(outputs: [raw])

        let listings = try MusicBridgeSession(runner: runner).listPlaylists()

        #expect(listings.count == 1)
        #expect(runner.calls == [.readJXA(script: buildListPlaylistsJXA())])
    }

    @Test("runner failures propagate without retries or writes")
    func runnerFailurePropagates() {
        let runner = FakeRunner(results: [.failure(MusicCommandError("automation failed"))])
        #expect(throws: MusicCommandError.self) {
            _ = try MusicBridgeSession(runner: runner).listPlaylists()
        }
        #expect(runner.calls.count == 1)
    }

    @Test("parse failures propagate as MusicBridgeError")
    func parseFailurePropagates() {
        let runner = FakeRunner(outputs: ["not json"])
        expectThrowsByteEqualMessage("Music returned invalid JSON", context: "session parse") {
            _ = try MusicBridgeSession(runner: runner).listPlaylists()
        }
    }
}
