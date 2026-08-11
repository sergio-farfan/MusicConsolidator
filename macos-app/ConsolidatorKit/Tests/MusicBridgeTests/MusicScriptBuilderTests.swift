// MusicScriptBuilderTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Ported string-shape and injection-defense tests for the pure script
// builders, mirroring tests/test_music_bridge.py (WriterBoundaryTests,
// MusicBridgeTests' pure builder cases, MergeWriterTests). Ordering asserts
// use byte offsets (Python str.index semantics); nothing here talks to Music.

import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

/// tests/test_music_bridge.py::WriterBoundaryTests._guard_source
func guardSource() -> PlaylistSnapshot {
    PlaylistSnapshot(
        name: "Source \"Exact\"",
        persistentId: "PLAYLIST",
        tracks: [
            track(
                sourceIndex: 0,
                databaseId: 101,
                persistentId: "OMITTED-A",
                title: "Same \"Song\"",
                artist: "Artist A",
                album: "Old Album",
                durationMs: 181001,
                kind: "Apple Music AAC audio file",
                bitRateKbps: 128,
                sampleRateHz: 44100,
                cloudStatus: "no longer available",
                isFileTrack: false
            ),
            track(
                sourceIndex: 1,
                databaseId: 202,
                persistentId: "WINNER-B",
                title: "Same \"Song\"",
                artist: "Artist A",
                album: "Master Album",
                durationMs: 181001,
                kind: "AIFF audio file",
                bitRateKbps: 1411,
                sampleRateHz: 96000,
                cloudStatus: "matched",
                isFileTrack: true
            ),
            track(
                sourceIndex: 2,
                databaseId: 303,
                persistentId: "UNIQUE-C",
                title: "Unique Song",
                artist: "Artist C",
                album: "Album C",
                durationMs: nil,
                kind: "MPEG audio file",
                bitRateKbps: nil,
                sampleRateHz: nil,
                cloudStatus: "uploaded",
                isFileTrack: true
            ),
        ]
    )
}

@Suite("Writer boundary (ported WriterBoundaryTests)")
struct WriterBoundaryPortTests {

    // test_writer_preflight_guards_every_field_of_every_source_occurrence
    @Test("preflight guards every field of every source occurrence")
    func preflightGuardsEveryField() throws {
        let source = guardSource()
        let plan = try buildPlan(source)
        let script = try buildApplyScript(
            plan: plan, verifiedSource: source, targetName: "Target \"Safe\""
        )
        let encoded = try encodeExpectedSourcePayload(source.tracks)

        let fieldDelimiter = encoded.fieldDelimiter.unicodeScalars.first!
        let rowDelimiter = encoded.rowDelimiter.unicodeScalars.first!
        let decodedRows = splitScalars(encoded.payload, separator: rowDelimiter)
            .map { splitScalars($0, separator: fieldDelimiter) }
        #expect(decodedRows == [
            [
                "101", "OMITTED-A", "Same \"Song\"", "Artist A", "Old Album",
                "181001", "Apple Music AAC audio file", "128", "44100",
                "no longer available", "0",
            ],
            [
                "202", "WINNER-B", "Same \"Song\"", "Artist A", "Master Album",
                "181001", "AIFF audio file", "1411", "96000", "matched", "1",
            ],
            [
                "303", "UNIQUE-C", "Unique Song", "Artist C", "Album C",
                "", "MPEG audio file", "", "", "uploaded", "1",
            ],
        ])

        let probe = ByteText(script)
        #expect(probe.contains("set expectedSourcePayload to " + appleScriptString(encoded.payload)))
        #expect(probe.contains("set expectedFieldDelimiter to " + appleScriptString(encoded.fieldDelimiter)))
        #expect(probe.contains("set expectedRowDelimiter to " + appleScriptString(encoded.rowDelimiter)))
        #expect(probe.contains("set selectedSourcePositions to {2, 3}"))

        let fullGuard = try #require(
            probe.offset(of: "repeat with sourcePosition from 1 to expectedSourceTrackCount")
        )
        let fullGuardEnd = try #require(probe.offset(of: "    end repeat", after: fullGuard))
        let targetGuard = try #require(probe.offset(of: "if (count of targetPlaylists) is not 0 then error"))
        let create = try #require(probe.offset(of: "make new user playlist"))
        let guardBlock = probe.slice(fullGuard..<fullGuardEnd)

        for propertyExpression in [
            "database ID of liveSourceTrack",
            "persistent ID of liveSourceTrack",
            "name of liveSourceTrack",
            "artist of liveSourceTrack",
            "album of liveSourceTrack",
            "duration of liveSourceTrack",
            "kind of liveSourceTrack",
            "bit rate of liveSourceTrack",
            "sample rate of liveSourceTrack",
            "cloud status of liveSourceTrack",
            "liveIsFileTrack",
        ] {
            #expect(guardBlock.contains(propertyExpression), "\(propertyExpression)")
        }
        for label in [
            "database ID", "persistent ID", "title", "artist", "album",
            "duration", "kind", "bit rate", "sample rate", "cloud status",
            "file-track status",
        ] {
            #expect(
                guardBlock.contains("\"source track \(label) changed at index \" & sourceIndex"),
                "\(label)"
            )
        }

        #expect(fullGuard < fullGuardEnd)
        #expect(fullGuardEnd < targetGuard)
        #expect(targetGuard < create)
        #expect(probe.count(of: "make new user playlist") == 1)
        let lowered = ByteText(script.lowercased())
        #expect(!lowered.contains("delete "))
        #expect(!lowered.contains("set name of sourceplaylist"))
        #expect(!lowered.contains("move sourceplaylist"))
        #expect(!lowered.contains("remove sourceplaylist"))
    }

    // test_writer_handles_source_with_no_file_tracks_before_target_lookup
    @Test("handles a source with no file tracks before target lookup")
    func handlesSourceWithNoFileTracks() throws {
        let source = PlaylistSnapshot(
            name: "Source",
            persistentId: "PLAYLIST",
            tracks: [
                track(sourceIndex: 0, databaseId: 101, persistentId: "CLOUD-A", isFileTrack: false)
            ]
        )
        let script = try buildApplyScript(
            plan: try buildPlan(source), verifiedSource: source, targetName: "Target"
        )
        let probe = ByteText(script)

        let classReadStatement = "set liveTrackClass to get class of liveSourceTrack"
        let classTestStatement = "set liveIsFileTrack to (liveTrackClass is file track)"
        #expect(probe.contains(classReadStatement))
        #expect(probe.contains(classTestStatement))

        let fullGuard = try #require(
            probe.offset(of: "repeat with sourcePosition from 1 to expectedSourceTrackCount")
        )
        let fullGuardEnd = try #require(probe.offset(of: "    end repeat", after: fullGuard))
        let classRead = try #require(probe.offset(of: classReadStatement, after: fullGuard))
        let classTest = try #require(probe.offset(of: classTestStatement, after: classRead))
        let targetLookup = try #require(probe.offset(of: "set targetPlaylists to {}"))

        #expect(fullGuard < classRead)
        #expect(classRead < classTest)
        #expect(classTest < fullGuardEnd)
        #expect(fullGuardEnd < targetLookup)
        #expect(!probe.contains("database ID of every file track of sourcePlaylist"))
    }

    // test_writer_uses_code_point_exact_text_guards
    @Test("uses code-point-exact text guards for every source text identity")
    func usesCodePointExactTextGuards() throws {
        let source = guardSource()
        let script = try buildApplyScript(
            plan: try buildPlan(source), verifiedSource: source, targetName: "Target"
        )
        let probe = ByteText(script)
        let sourceLookup = try #require(probe.offset(of: "set sourcePlaylists to {}"))
        let targetLookup = try #require(probe.offset(of: "set targetPlaylists to {}"))
        let sourceGuard = probe.slice(sourceLookup..<targetLookup)

        #expect(probe.contains("my textCodePointsMatch(candidateName, sourcePlaylistName)"))
        #expect(probe.contains("my textCodePointsMatch(candidateName, targetPlaylistName)"))
        #expect(sourceGuard.contains(
            "my textCodePointsMatch(expectedSourcePlaylistPersistentID, liveSourcePlaylistPersistentID)"
        ))
        #expect(sourceGuard.count(of: "my textCodePointsMatch(expectedTextValue, liveTextValue)") == 5)
        #expect(!sourceGuard.contains("if (liveTextValue as text) is not expectedTextValue"))
    }

    // test_writer_compares_cloud_status_as_an_enum_inside_source_guard
    @Test("compares cloud status as an enum inside the source guard")
    func comparesCloudStatusAsEnum() throws {
        let source = PlaylistSnapshot(
            name: "Source",
            persistentId: "PLAYLIST",
            tracks: [
                track(sourceIndex: 0, databaseId: 101, persistentId: "CLOUD-A", cloudStatus: "subscription")
            ]
        )
        let script = try buildApplyScript(
            plan: try buildPlan(source), verifiedSource: source, targetName: "Target"
        )
        let probe = ByteText(script)
        let fullGuard = try #require(
            probe.offset(of: "repeat with sourcePosition from 1 to expectedSourceTrackCount")
        )
        let fullGuardEnd = try #require(probe.offset(of: "    end repeat", after: fullGuard))
        let guardBlock = probe.slice(fullGuard..<fullGuardEnd)

        #expect(guardBlock.contains("set liveCloudStatus to cloud status of liveSourceTrack"))
        #expect(guardBlock.contains("my cloudStatusMatches(expectedTextValue, liveCloudStatus)"))
        #expect(!guardBlock.contains("set liveTextValue to cloud status of liveSourceTrack"))
    }

    // test_writer_rejects_unknown_expected_cloud_status
    @Test("rejects an unknown expected cloud status before compilation")
    func rejectsUnknownExpectedCloudStatus() throws {
        let source = PlaylistSnapshot(
            name: "Source",
            persistentId: "PLAYLIST",
            tracks: [
                track(sourceIndex: 0, databaseId: 101, persistentId: "CLOUD-A", cloudStatus: "future status")
            ]
        )
        let plan = try buildPlan(source)
        #expect {
            _ = try buildApplyScript(plan: plan, verifiedSource: source, targetName: "Target")
        } throws: { error in
            String(describing: error).contains("unsupported cloud status")
        }
    }

    // PlanIntegrityBridgeTests.test_noncanonical_cloud_status_is_rejected...
    // (payload-encoder surface): JXA display-cased names must be rejected.
    @Test("payload encoder rejects a non-canonical cloud status casing")
    func payloadEncoderRejectsNonCanonicalCloudStatus() throws {
        let tracks = [
            track(sourceIndex: 0, databaseId: 10, persistentId: "CLOUD-A", cloudStatus: "Subscription")
        ]
        #expect {
            _ = try encodeExpectedSourcePayload(tracks)
        } throws: { error in
            String(describing: error).contains("unsupported cloud status")
        }
    }

    // test_writer_resolves_playlist_repeat_references
    @Test("resolves playlist repeat references via contents of")
    func resolvesPlaylistRepeatReferences() throws {
        let source = guardSource()
        let script = try buildApplyScript(
            plan: try buildPlan(source), verifiedSource: source, targetName: "Target"
        )
        let probe = ByteText(script)
        #expect(probe.contains("set end of sourcePlaylists to contents of candidatePlaylist"))
        #expect(probe.contains("set end of targetPlaylists to contents of candidatePlaylist"))
        #expect(!probe.contains("set end of sourcePlaylists to candidatePlaylist"))
        #expect(!probe.contains("set end of targetPlaylists to candidatePlaylist"))
    }

    // test_every_selected_source_track_has_both_identity_guards
    @Test("every selected source track keeps both identity guards")
    func everySelectedTrackHasBothIdentityGuards() throws {
        let source = guardSource()
        let plan = try buildPlan(source)
        let script = try buildApplyScript(plan: plan, verifiedSource: source, targetName: "Target")
        let probe = ByteText(script)

        let expectedPositions = plan.winnerSourceIndexes.map { String($0 + 1) }.joined(separator: ", ")
        #expect(probe.contains("set selectedSourcePositions to {\(expectedPositions)}"))

        let fullGuard = try #require(
            probe.offset(of: "repeat with sourcePosition from 1 to expectedSourceTrackCount")
        )
        let fullGuardEnd = try #require(probe.offset(of: "    end repeat", after: fullGuard))
        let guardBlock = probe.slice(fullGuard..<fullGuardEnd)
        #expect(guardBlock.contains("database ID of liveSourceTrack"))
        #expect(guardBlock.contains("persistent ID of liveSourceTrack"))
        let create = try #require(probe.offset(of: "make new user playlist"))
        #expect(fullGuardEnd < create)
    }
}

@Suite("Apply script structure and injection defenses (ported MusicBridgeTests)")
struct ApplyScriptPortTests {

    // test_apply_script_validates_every_identity_before_create_then_duplicates
    @Test("validates every identity before create, then duplicates")
    func validatesEveryIdentityBeforeCreateThenDuplicates() throws {
        let source = PlaylistSnapshot(
            name: "Source \"Exact\"",
            persistentId: "PLAYLIST",
            tracks: [
                track(sourceIndex: 0, databaseId: 101, persistentId: "TRACK-A", title: "First"),
                track(sourceIndex: 1, databaseId: 202, persistentId: "TRACK-B", title: "Second"),
            ]
        )
        let plan = try buildPlan(source)
        let script = try buildApplyScript(
            plan: plan, verifiedSource: source, targetName: "Target \"Safe\""
        )
        let probe = ByteText(script)

        let sourceLookup = try #require(probe.offset(of: "set sourcePlaylists to {}"))
        let sourceCountGuard = try #require(
            probe.offset(of: "if (count of sourcePlaylists) is not 1 then error")
        )
        let targetLookup = try #require(probe.offset(of: "set targetPlaylists to {}"))
        let targetCountGuard = try #require(
            probe.offset(of: "if (count of targetPlaylists) is not 0 then error")
        )
        let trackCountGuard = try #require(
            probe.offset(of: "if (count of sourceTracks) is not expectedSourceTrackCount then error")
        )
        let firstIdentityGuard = try #require(
            probe.offset(of: "if (database ID of liveSourceTrack) is not expectedDatabaseID then error")
        )
        let secondIdentityGuard = try #require(
            probe.offset(of: "\"source track persistent ID changed at index \" & sourceIndex")
        )
        let create = try #require(probe.offset(of: "make new user playlist"))
        let duplicate = try #require(probe.offset(of: "duplicate selectedTrack to destinationPlaylist"))

        #expect(sourceLookup < sourceCountGuard)
        #expect(sourceCountGuard < trackCountGuard)
        #expect(trackCountGuard < firstIdentityGuard)
        #expect(firstIdentityGuard < secondIdentityGuard)
        #expect(secondIdentityGuard < targetLookup)
        #expect(targetLookup < targetCountGuard)
        #expect(targetCountGuard < create)
        #expect(create < duplicate)
        #expect(probe.count(of: "make new user playlist") == 1)
        #expect(probe.count(of: "duplicate selectedTrack to destinationPlaylist") == 1)
        #expect(probe.contains("set selectedSourcePositions to {1, 2}"))
        #expect(probe.contains("repeat with selectedSourcePosition in selectedSourcePositions"))
        #expect(probe.contains("set sourcePlaylistName to \"Source \\\"Exact\\\"\""))
        #expect(probe.contains("set targetPlaylistName to \"Target \\\"Safe\\\"\""))
        #expect(probe.contains("return \"{\\\"status\\\":\\\"ok\\\",\\\"duplicated_count\\\":2}\""))
    }

    // test_apply_script_rejects_target_name_script_injection
    @Test("rejects target-name script injection")
    func rejectsTargetNameScriptInjection() throws {
        let source = PlaylistSnapshot(name: "Source", persistentId: "P", tracks: [track()])
        let targetName = "Target\"\nerror \"injected"

        let script = try buildApplyScript(
            plan: try buildPlan(source), verifiedSource: source, targetName: targetName
        )
        let probe = ByteText(script)
        #expect(probe.contains("set targetPlaylistName to " + appleScriptString(targetName)))
        #expect(!probe.contains("\nerror \"injected"))
    }

    // test_apply_script_targets_verified_absolute_music_app_path
    @Test("targets the verified absolute Music app path")
    func targetsVerifiedAbsoluteMusicAppPath() throws {
        let source = PlaylistSnapshot(name: "Source", persistentId: "P", tracks: [track()])
        let script = try buildApplyScript(
            plan: try buildPlan(source), verifiedSource: source, targetName: "Target"
        )
        let probe = ByteText(script)
        #expect(probe.contains("tell application \"/System/Applications/Music.app\""))
        #expect(!probe.contains("tell application \"Music\""))
        #expect(!probe.contains("tell application \"com.apple.Music\""))
    }

    // test_apply_generator_rejects_verified_source_metadata_or_track_drift
    @Test("rejects verified-source metadata or track drift")
    func rejectsVerifiedSourceDrift() throws {
        let source = PlaylistSnapshot(name: "Source", persistentId: "PLAYLIST", tracks: [track()])
        let plan = try buildPlan(source)

        var changedTrack = source.tracks[0]
        changedTrack.title = "Changed"
        let mutations: [(reason: String, changed: PlaylistSnapshot)] = [
            ("name", PlaylistSnapshot(name: "Other", persistentId: "PLAYLIST", tracks: source.tracks)),
            ("persistent ID", PlaylistSnapshot(name: "Source", persistentId: "OTHER", tracks: source.tracks)),
            ("track count", PlaylistSnapshot(name: "Source", persistentId: "PLAYLIST", tracks: [])),
            ("fingerprint", PlaylistSnapshot(name: "Source", persistentId: "PLAYLIST", tracks: [changedTrack])),
        ]
        for mutation in mutations {
            #expect {
                _ = try buildApplyScript(plan: plan, verifiedSource: mutation.changed, targetName: "Target")
            } throws: { error in
                String(describing: error).contains(mutation.reason)
            }
        }
    }

    // Canonical-plan re-assertion: a locally altered winner selection must be
    // rejected before any script text is produced (the pure-builder half of
    // PlanIntegrityBridgeTests.test_altered_winner_indexes_are_rejected...).
    @Test("rejects a non-canonical winner selection")
    func rejectsNonCanonicalWinnerSelection() throws {
        let source = PlaylistSnapshot(
            name: "Source",
            persistentId: "P",
            tracks: [
                track(sourceIndex: 0, databaseId: 10, persistentId: "LOW", sampleRateHz: 44100),
                track(sourceIndex: 1, databaseId: 20, persistentId: "HIGH", sampleRateHz: 48000),
            ]
        )
        let canonical = try buildPlan(source)
        let altered = ConsolidationPlan(
            sourcePlaylistName: canonical.sourcePlaylistName,
            sourcePlaylistPersistentId: canonical.sourcePlaylistPersistentId,
            sourceFingerprint: canonical.sourceFingerprint,
            sourceTrackCount: canonical.sourceTrackCount,
            sourceTracks: canonical.sourceTracks,
            winnerSourceIndexes: [0],
            decisions: canonical.decisions,
            nonEligibleSourceIndexes: canonical.nonEligibleSourceIndexes
        )
        #expect {
            _ = try buildApplyScript(plan: altered, verifiedSource: source, targetName: "Target")
        } throws: { error in
            String(describing: error).contains("canonical")
        }
    }
}

@Suite("Read JXA (ported pure read-builder cases)")
struct ReadJXAPortTests {

    // test_read_jxa_json_encodes_untrusted_playlist_name
    @Test("JSON-encodes an untrusted playlist name")
    func jsonEncodesUntrustedPlaylistName() throws {
        let name = "Source\";\\\nthrow new Error(\"injected\")"
        let script = buildReadJXA(name: name)
        let probe = ByteText(script)
        #expect(probe.contains("const requestedName = " + appleScriptString(name) + ";"))
        #expect(!probe.contains("const requestedName = Source\""))
        #expect(probe.contains("Music.userPlaylists()"))
        #expect(probe.contains("playlist.name() === requestedName"))
        #expect(probe.contains("playlist.fileTracks;"))
    }

    // bulk-read-speedup Task 2: playlist lookup/matching discipline stays
    // byte-identical (columnar rewrite touches only the per-playlist track
    // and file-track reads inside the map body).
    @Test("playlist lookup keeps the exact-name filter over the called specifiers array")
    func playlistLookupDisciplineUnchanged() throws {
        let script = buildReadJXA(name: "any")
        let probe = ByteText(script)
        let matchesBlock =
            "const matches = Music.userPlaylists().filter(function (playlist) {\n" +
            "    return playlist.name() === requestedName;\n" +
            "});"
        #expect(probe.contains(matchesBlock))
    }

    // bulk-read-speedup Task 2: every track column is fetched ONCE off the
    // SAME un-called `playlist.tracks` specifier (never the called,
    // materializing `playlist.tracks()` form).
    @Test("fetches every track column off the un-called tracks specifier")
    func fetchesTrackColumnsOffUncalledSpecifier() throws {
        let script = buildReadJXA(name: "any")
        let probe = ByteText(script)
        #expect(probe.contains("const trackRefs = playlist.tracks;"))
        for column in [
            "trackRefs.databaseID()", "trackRefs.persistentID()", "trackRefs.name()",
            "trackRefs.artist()", "trackRefs.album()", "trackRefs.duration()",
            "trackRefs.kind()", "trackRefs.bitRate()", "trackRefs.sampleRate()",
            "trackRefs.cloudStatus()",
        ] {
            #expect(probe.contains(column), "\(column)")
        }
        // Negative pin (Task 1 idiom): the CALLED form, without a trailing
        // semicolon, so a chained `.tracks().map(...)` would also be caught.
        #expect(!probe.contains("playlist.tracks()"))
    }

    // bulk-read-speedup Task 2: file-track database IDs are likewise a
    // single columnar fetch off the un-called `fileTracks` specifier, never
    // a per-file-track loop.
    @Test("fetches file-track database IDs off the un-called file-tracks specifier")
    func fetchesFileTrackColumnOffUncalledSpecifier() throws {
        let script = buildReadJXA(name: "any")
        let probe = ByteText(script)
        #expect(probe.contains("const fileTrackRefs = playlist.fileTracks;"))
        #expect(probe.contains("fileTrackRefs.databaseID()"))
        #expect(!probe.contains("playlist.fileTracks()"))
    }

    // bulk-read-speedup Task 2 (I2, review fix): count-first, narrowest
    // drift window — each collection's `.length` count read precedes EVERY
    // columnar get taken off that SAME collection, not just the first one.
    // Mirrors PlaylistListingTests.readsCountFirst's fixed form (String
    // .range(of:) offsets, looped over every column).
    @Test("counts each collection before fetching any of its columns")
    func countsBeforeColumns() throws {
        let script = buildReadJXA(name: "any")

        guard let fileTrackCountRange = script.range(
            of: "const expectedFileTrackCount = fileTrackRefs.length;"
        ) else {
            Issue.record("file-track count-first read is missing")
            return
        }
        for column in ["fileTrackRefs.databaseID()"] {
            guard let columnRange = script.range(of: column) else {
                Issue.record("missing columnar fetch: \(column)")
                continue
            }
            #expect(
                fileTrackCountRange.upperBound <= columnRange.lowerBound,
                "\(column) read before the file-track count"
            )
        }

        guard let trackCountRange = script.range(
            of: "const expectedTrackCount = trackRefs.length;"
        ) else {
            Issue.record("track count-first read is missing")
            return
        }
        for column in [
            "trackRefs.databaseID()", "trackRefs.persistentID()", "trackRefs.name()",
            "trackRefs.artist()", "trackRefs.album()", "trackRefs.duration()",
            "trackRefs.kind()", "trackRefs.bitRate()", "trackRefs.sampleRate()",
            "trackRefs.cloudStatus()",
        ] {
            guard let columnRange = script.range(of: column) else {
                Issue.record("missing columnar fetch: \(column)")
                continue
            }
            #expect(
                trackCountRange.upperBound <= columnRange.lowerBound,
                "\(column) read before the track count"
            )
        }
    }

    // bulk-read-speedup Task 2 (M2, review fix): the TYPE branch
    // (`!Array.isArray(...)`) and the LENGTH branch (`.length !==
    // expected...`) are separate `if` statements with their own accurate,
    // verbatim message per column — closes Task 1's deferred minor
    // ("type-branch guard message says 'length mismatch' inaccurately")
    // uniformly across both columnar scripts.
    @Test("guards every track column's type and length against the count-first read")
    func guardsEveryTrackColumnLength() throws {
        let script = buildReadJXA(name: "any")
        let probe = ByteText(script)
        for field in [
            "database_id", "persistent_id", "title", "artist", "album", "duration",
            "kind", "bit_rate", "sample_rate", "cloud_status", "file_track_database_id",
        ] {
            #expect(probe.contains("column type mismatch: \(field)"), "type: \(field)")
            #expect(probe.contains("column length mismatch: \(field)"), "length: \(field)")
        }
    }

    // bulk-read-speedup Task 2: the per-track loop construct (one callback
    // invoked per track, each reading ten properties) disappears entirely.
    @Test("no per-track loop construct remains")
    func noPerTrackLoopConstructRemains() throws {
        let script = buildReadJXA(name: "any")
        let probe = ByteText(script)
        #expect(!probe.contains("function (track, sourceIndex)"))
        #expect(!probe.contains("function (fileTrack)"))
    }

    // test_read_jxa_targets_verified_absolute_music_app_path
    @Test("targets the verified absolute Music app path")
    func targetsVerifiedAbsoluteMusicAppPath() throws {
        let script = buildReadJXA(name: "#Musica xTotal")
        let probe = ByteText(script)
        #expect(probe.contains("const Music = Application(\"/System/Applications/Music.app\");"))
        #expect(!probe.contains("Application(\"Music\")"))
        #expect(!probe.contains("Application(\"com.apple.Music\")"))
    }

    // AllCopiesReadTests.test_build_read_jxa_emits_numeric_playlist_id
    @Test("emits the numeric playlist id")
    func emitsNumericPlaylistId() throws {
        let script = buildReadJXA(name: "Trance 2022")
        #expect(ByteText(script).contains("id: playlist.id()"))
    }

    // Task 3 (bulk-read-speedup): a permanent osacompile pin for the LIVE
    // columnar reader — ScriptCompileTests.swift covers only the writers
    // (buildApplyScript, buildMergeApplyScript); this is the read-side
    // counterpart, cloned from LegacyReadJXABuilderTests.legacyStaticScriptCompiles
    // immediately below in this file. Compile-only, never executed: same M4
    // discipline as every other osacompile gate in this suite.
    @Test(
        "columnar read script compiles (osacompile -l JavaScript; never executed)",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func columnarStaticScriptCompiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-read-live-read-compile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("read-live.scpt")
        let result = try runTool(
            osacompilePath,
            arguments: ["-l", "JavaScript", "-o", output.path],
            stdinText: buildReadJXA(name: "any")
        )
        #expect(result.status == 0, "\(result.stderr)")
    }
}

// bulk-read-speedup Task 2 (I3, controller decision): the pre-columnar
// `buildReadJXA` body, restored under a new name from git history (commit
// ebd8854, the last commit before the columnar rewrite) — pinned VERBATIM so
// it cannot drift. Task 3's Diagnostics "Compare readers" action
// (`ReadWorker.compareReaders`) is the one and only caller.
private let expectedLegacyReadJXA = """
const Music = Application("/System/Applications/Music.app");
const requestedName = "any";

function textOrEmpty(value) {
    return value === null || value === undefined ? "" : String(value);
}

function numberOrNull(value) {
    return value === null || value === undefined || Number.isNaN(value) ? null : value;
}

const matches = Music.userPlaylists().filter(function (playlist) {
    return playlist.name() === requestedName;
});

const playlists = matches.map(function (playlist) {
    const fileTrackDatabaseIDs = new Set(
        playlist.fileTracks().map(function (fileTrack) {
            return fileTrack.databaseID();
        })
    );
    const tracks = playlist.tracks().map(function (track, sourceIndex) {
        const databaseID = track.databaseID();
        return {
            source_index: sourceIndex,
            database_id: databaseID,
            persistent_id: textOrEmpty(track.persistentID()),
            title: textOrEmpty(track.name()),
            artist: textOrEmpty(track.artist()),
            album: textOrEmpty(track.album()),
            duration: numberOrNull(track.duration()),
            kind: textOrEmpty(track.kind()),
            bit_rate: numberOrNull(track.bitRate()),
            sample_rate: numberOrNull(track.sampleRate()),
            cloud_status: textOrEmpty(track.cloudStatus()),
            is_file_track: fileTrackDatabaseIDs.has(databaseID)
        };
    });
    return {
        id: playlist.id(),
        name: playlist.name(),
        persistent_id: playlist.persistentID(),
        tracks: tracks
    };
});

JSON.stringify({playlists: playlists});

"""

@Suite("Legacy read JXA builder (Task 3 Diagnostics cross-check only)")
struct LegacyReadJXABuilderTests {

    @Test("legacy script text is the pre-Task-2 pinned constant, byte for byte")
    func legacyScriptTextIsPinned() {
        expectByteEqual(
            legacyReadJXAScript(name: "any"),
            expectedLegacyReadJXA,
            context: "legacyReadJXAScript"
        )
    }

    @Test("legacy builder is deterministic across calls")
    func legacyBuilderIsDeterministic() {
        expectByteEqual(
            legacyReadJXAScript(name: "any"),
            legacyReadJXAScript(name: "any"),
            context: "two calls"
        )
    }

    @Test(
        "legacy read script compiles (osacompile -l JavaScript; never executed)",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func legacyStaticScriptCompiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-read-legacy-read-compile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("read-legacy.scpt")
        let result = try runTool(
            osacompilePath,
            arguments: ["-l", "JavaScript", "-o", output.path],
            stdinText: legacyReadJXAScript(name: "any")
        )
        #expect(result.status == 0, "\(result.stderr)")
    }
}

@Suite("Payload encoder (PUA delimiter selection)")
struct PayloadEncoderTests {

    @Test("skips delimiter candidates that appear in track data and round-trips 11 fields")
    func skipsUsedDelimiterCandidates() throws {
        let pua0 = scalarString(0xE000)
        let pua1 = scalarString(0xE001)
        let pua3 = scalarString(0xE003)
        let tracks = [
            track(
                sourceIndex: 0,
                databaseId: 1,
                persistentId: "PUA-A",
                title: "Title \(pua0) uses first candidate",
                artist: "Artist \(pua1) uses second",
                album: "Album \(pua3)\(scalarString(0xF8FF))"
            ),
            track(sourceIndex: 1, databaseId: 2, persistentId: "PUA-B", title: "Plain Title"),
        ]
        let encoded = try encodeExpectedSourcePayload(tracks)
        #expect(encoded.fieldDelimiter == scalarString(0xE002))
        #expect(encoded.rowDelimiter == scalarString(0xE004))

        let rows = splitScalars(encoded.payload, separator: Unicode.Scalar(0xE004)!)
            .map { splitScalars($0, separator: Unicode.Scalar(0xE002)!) }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.count == 11 })
        #expect(rows[0][2] == "Title \(pua0) uses first candidate")
        #expect(rows[1][1] == "PUA-B")
    }

    @Test("empty source encodes an empty payload with the first two PUA delimiters")
    func emptySourceEncodesEmptyPayload() throws {
        let encoded = try encodeExpectedSourcePayload([])
        #expect(encoded.payload.isEmpty)
        #expect(encoded.fieldDelimiter == scalarString(0xE000))
        #expect(encoded.rowDelimiter == scalarString(0xE001))
    }
}

@Suite("appleScriptString (json.dumps ensure_ascii=False parity)")
struct AppleScriptStringTests {

    @Test("escapes exactly the json.dumps set and passes everything else raw")
    func matchesPythonJsonDumps() throws {
        #expect(appleScriptString("plain") == "\"plain\"")
        #expect(appleScriptString("quote \" backslash \\") == "\"quote \\\" backslash \\\\\"")
        #expect(appleScriptString("nl\ntab\tcr\r") == "\"nl\\ntab\\tcr\\r\"")
        // backspace and form feed use the short escapes
        #expect(appleScriptString(scalarString(0x08) + scalarString(0x0C)) == "\"" + "\\" + "b" + "\\" + "f" + "\"")
        // other C0 controls use lowercase four-digit unicode escapes
        #expect(appleScriptString(scalarString(0x01)) == "\"" + "\\" + "u0001" + "\"")
        #expect(appleScriptString(scalarString(0x1F)) == "\"" + "\\" + "u001f" + "\"")
        // DEL, line/paragraph separators, PUA, non-ASCII, and non-BMP pass raw
        for codePoint: UInt32 in [0x7F, 0x2028, 0x2029, 0xE000, 0xF8FF, 0xE9, 0x1F3B5] {
            let raw = scalarString(codePoint)
            #expect(appleScriptString(raw) == "\"" + raw + "\"", "U+\(String(codePoint, radix: 16))")
        }
    }
}

@Suite("Merge writer (ported MergeWriterTests)")
struct MergeWriterPortTests {

    func copies() -> [PlaylistSnapshot] {
        [
            PlaylistSnapshot(
                name: "Trance 2022",
                persistentId: "PID-A",
                tracks: [
                    track(sourceIndex: 0, databaseId: 1, persistentId: "LOSSY",
                          title: "One", durationMs: 180001, sampleRateHz: 44100),
                    track(sourceIndex: 1, databaseId: 2, persistentId: "UNIQUE-A",
                          title: "Two", durationMs: 200002),
                ]
            ),
            PlaylistSnapshot(
                name: "Trance 2022",
                persistentId: "PID-B",
                tracks: [
                    track(sourceIndex: 0, databaseId: 3, persistentId: "LOSSLESS",
                          title: "One", durationMs: 180001, kind: "AIFF audio file",
                          sampleRateHz: 96000),
                ]
            ),
        ]
    }

    // test_writer_emits_per_copy_identity_and_combined_selection
    @Test("emits per-copy identity and the combined selection")
    func emitsPerCopyIdentityAndCombinedSelection() throws {
        let copies = copies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        let script = try buildMergeApplyScript(
            plan: plan, verifiedCopies: copies, targetName: "Trance 2022 — Merged"
        )
        let probe = ByteText(script)

        #expect(probe.contains("set expectedCopyCount to 2"))
        #expect(probe.contains("set targetPlaylistName to \"Trance 2022 — Merged\""))
        #expect(probe.contains("expectedCopyPersistentIDs"))
        #expect(probe.contains("expectedCopyTrackCounts"))
        #expect(probe.contains("set expectedCombinedTrackCount to 3"))
        let winners = plan.winnerSourceIndexes.map { String($0 + 1) }.joined(separator: ", ")
        #expect(probe.contains("set selectedCombinedPositions to {\(winners)}"))
        #expect(probe.contains("my textCodePointsMatch(expectedCopyPersistentID, candidateCopyPID)"))
        #expect(probe.contains("duplicate selectedTrack to destinationPlaylist"))
    }

    // test_writer_orders_guards_before_target_lookup_and_create
    @Test("orders guards before target lookup and create")
    func ordersGuardsBeforeTargetLookupAndCreate() throws {
        let copies = copies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        let script = try buildMergeApplyScript(
            plan: plan, verifiedCopies: copies, targetName: "Trance 2022 — Merged"
        )
        let probe = ByteText(script)
        let copyCountGuard = try #require(
            probe.offset(of: "if (count of sourcePlaylists) is not expectedCopyCount")
        )
        let combinedGuard = try #require(
            probe.offset(of: "if (count of combinedTracks) is not expectedCombinedTrackCount")
        )
        let targetGuard = try #require(
            probe.offset(of: "if (count of targetPlaylists) is not 0 then error")
        )
        let create = try #require(probe.offset(of: "make new user playlist"))
        let duplicate = try #require(probe.offset(of: "duplicate selectedTrack to destinationPlaylist"))
        #expect(copyCountGuard < combinedGuard)
        #expect(combinedGuard < targetGuard)
        #expect(targetGuard < create)
        #expect(create < duplicate)
        #expect(probe.count(of: "make new user playlist") == 1)
    }

    // test_writer_targets_absolute_music_path_and_no_destructive_verbs
    @Test("targets the absolute Music path and contains no destructive verbs")
    func targetsAbsolutePathAndNoDestructiveVerbs() throws {
        let copies = copies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        let script = try buildMergeApplyScript(
            plan: plan, verifiedCopies: copies, targetName: "Trance 2022 — Merged"
        )
        #expect(ByteText(script).contains("tell application \"/System/Applications/Music.app\""))
        let lowered = ByteText(script.lowercased())
        for verb in ["delete ", "set name of", "move ", "remove "] {
            #expect(!lowered.contains(verb), "\(verb)")
        }
    }

    // build_merge_apply_script's fail-closed first guard
    @Test("rejects verified copies that do not match the plan copies")
    func rejectsMismatchedVerifiedCopies() throws {
        let copies = copies()
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        #expect {
            _ = try buildMergeApplyScript(
                plan: plan, verifiedCopies: copies.reversed(), targetName: "Trance 2022 — Merged"
            )
        } throws: { error in
            String(describing: error).contains("verified copies do not match the merge plan copies")
        }
    }
}
