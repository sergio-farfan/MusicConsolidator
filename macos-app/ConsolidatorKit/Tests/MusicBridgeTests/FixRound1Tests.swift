// FixRound1Tests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Regression pins for the M5 fix round 1 findings. Every expected behavior
// and message below was verified against the python3 reference first
// (/tmp/m5/fix1_reference.py; outputs recorded in the M5 report, "Fix round 1"):
//
//   F1  JSONSerialization silently strips a leading U+FEFF from wire string
//       values and keys (json.loads preserves it), bypassing every
//       scalar-exact ensure/assert/verify comparison downstream.
//   F2  bit_rate/sample_rate are REQUIRED wire keys in the reference
//       (_parse_track indexes them; only `duration` uses .get()) — a missing
//       key must fail closed, null must parse as nil.
//   F3  A hostile wire duration (>= ~9.22e15 s) trapped the process inside
//       Int(Double); the wire path must throw a catchable error instead.
//   F4  The unsupported-cloud-status message must render the value with
//       Python repr semantics ({track.cloud_status!r}), not raw text in
//       hard-coded quotes.
//   F5  After a writer failure, the recorded runner transcript must contain
//       ONLY read commands — the never-mutate diagnostics contract at the
//       seam level.

import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

private let feff = "\u{FEFF}"

/// A complete wire payload for one "Source" playlist with one track whose
/// text fields are caller-controlled (JSON-escaped here as needed).
private func sourceWirePayload(
    name: String = "Source",
    persistentId: String = "P",
    title: String = "Abc",
    bitRateField: String = "\"bit_rate\": 256",
    sampleRateField: String = "\"sample_rate\": 44100",
    durationField: String = "\"duration\": 183"
) -> String {
    """
    {"playlists": [{"id": 7, "name": "\(name)", "persistent_id": "\(persistentId)", "tracks": [
        {"source_index": 0, "database_id": 1, "persistent_id": "ABC",
         "title": "\(title)", "artist": "Björk", "album": "Album",
         \(durationField), "kind": "Apple Music AAC audio file",
         \(bitRateField), \(sampleRateField), "cloud_status": "",
         "is_file_track": false}
    ]}]}
    """
}

private func auditedSourceSnapshot(title: String = "Abc") -> PlaylistSnapshot {
    PlaylistSnapshot(
        name: "Source",
        persistentId: "P",
        tracks: [track(persistentId: "ABC", title: title, durationMs: 183000)]
    )
}

@Suite("F1 — wire strings preserve every scalar (leading U+FEFF included)")
struct WireScalarPreservationTests {

    // Reference: json.loads keeps U+FEFF in values, keys, and FEFF-only strings.
    @Test("parse preserves a leading U+FEFF in wire string values")
    func parsePreservesLeadingFEFF() throws {
        let raw = sourceWirePayload(title: "\\uFEFFAbc")
        let snapshot = try parseExactPlaylistSnapshot(raw: raw, name: "Source")
        expectByteEqual(snapshot.tracks[0].title, feff + "Abc", context: "FEFF title scalars")
    }

    @Test("parse preserves a FEFF-only wire string value")
    func parsePreservesFEFFOnlyValue() throws {
        let raw = sourceWirePayload(title: "\\uFEFF")
        let snapshot = try parseExactPlaylistSnapshot(raw: raw, name: "Source")
        expectByteEqual(snapshot.tracks[0].title, feff, context: "FEFF-only title")
    }

    // Reference: ValueError "…; verified source fingerprint does not match
    // consolidation plan; create a fresh audit" for the FEFF-drifted title.
    @Test("ensure rejects a live title drifted by a leading U+FEFF")
    func ensureRejectsFEFFTitleDrift() throws {
        let plan = try buildPlan(auditedSourceSnapshot())
        let runner = FakeRunner(outputs: [sourceWirePayload(title: "\\uFEFFAbc")])

        expectThrowsByteEqualMessage(
            "source playlist changed after audit or plan is non-canonical; "
                + "verified source fingerprint does not match consolidation plan; "
                + "create a fresh audit",
            context: "F1 FEFF title drift"
        ) {
            _ = try MusicBridgeSession(runner: runner).ensureSourceMatches(plan: plan)
        }
    }

    // Reference: "…; verified source persistent ID does not match…".
    @Test("ensure rejects a live playlist persistent ID drifted by U+FEFF")
    func ensureRejectsFEFFPersistentIdDrift() throws {
        let plan = try buildPlan(auditedSourceSnapshot())
        let runner = FakeRunner(outputs: [sourceWirePayload(persistentId: "\\uFEFFP")])

        expectThrowsByteEqualMessage(
            "source playlist changed after audit or plan is non-canonical; "
                + "verified source persistent ID does not match consolidation plan; "
                + "create a fresh audit",
            context: "F1 FEFF pid drift"
        ) {
            _ = try MusicBridgeSession(runner: runner).ensureSourceMatches(plan: plan)
        }
    }

    // Reference: a FEFF-prefixed live name is NOT an exact match for the plain
    // requested name — "expected exactly one user playlist named 'Source'".
    @Test("parse does not match a FEFF-prefixed playlist name")
    func parseRejectsFEFFPrefixedName() {
        let raw = sourceWirePayload(name: "\\uFEFFSource")
        expectThrowsByteEqualMessage(
            "expected exactly one user playlist named 'Source'",
            context: "F1 FEFF name"
        ) {
            _ = try parseExactPlaylistSnapshot(raw: raw, name: "Source")
        }
    }

    // Reference: assert_target_absent returns normally — a FEFF-prefixed name is
    // a DIFFERENT playlist, not a collision (false-rejection direction).
    @Test("target absence check does not collide with a FEFF-prefixed name")
    func targetAbsenceIgnoresFEFFPrefixedName() throws {
        let raw = """
        {"playlists": [{"id": 1, "name": "\\uFEFFTarget", "persistent_id": "T", "tracks": []}]}
        """
        try MusicBridgeSession(runner: FakeRunner(outputs: [raw]))
            .assertTargetAbsent(targetName: "Target")
    }
}

@Suite("F2/F3 — strict wire numeric fields")
struct StrictWireFieldTests {

    // Reference: KeyError('bit_rate') / KeyError('sample_rate') — fail closed.
    @Test("a missing bit_rate key is rejected, null bit_rate parses as nil")
    func missingBitRateRejectedNullAccepted() throws {
        expectThrowsByteEqualMessage(
            "track bit_rate must be an integer or null",
            context: "F2 missing bit_rate"
        ) {
            _ = try parseExactPlaylistSnapshot(
                raw: sourceWirePayload(bitRateField: "\"comment\": \"no bit_rate\""),
                name: "Source"
            )
        }
        let snapshot = try parseExactPlaylistSnapshot(
            raw: sourceWirePayload(bitRateField: "\"bit_rate\": null"), name: "Source"
        )
        #expect(snapshot.tracks[0].bitRateKbps == nil)
    }

    @Test("a missing sample_rate key is rejected, null sample_rate parses as nil")
    func missingSampleRateRejectedNullAccepted() throws {
        expectThrowsByteEqualMessage(
            "track sample_rate must be an integer or null",
            context: "F2 missing sample_rate"
        ) {
            _ = try parseExactPlaylistSnapshot(
                raw: sourceWirePayload(sampleRateField: "\"comment\": \"no sample_rate\""),
                name: "Source"
            )
        }
        let snapshot = try parseExactPlaylistSnapshot(
            raw: sourceWirePayload(sampleRateField: "\"sample_rate\": null"), name: "Source"
        )
        #expect(snapshot.tracks[0].sampleRateHz == nil)
    }

    // Reference: track.get("duration") — the ONLY optional wire key.
    @Test("a missing duration key parses as nil (reference .get semantics)")
    func missingDurationParsesAsNil() throws {
        let snapshot = try parseExactPlaylistSnapshot(
            raw: sourceWirePayload(durationField: "\"comment\": \"no duration\""),
            name: "Source"
        )
        #expect(snapshot.tracks[0].durationMs == nil)
    }

    // Reference parses 9.2e15 s to 9_200_000_000_000_000_000 ms (bignum).
    @Test("a duration near the Int millisecond boundary parses")
    func nearBoundaryDurationParses() throws {
        let snapshot = try parseExactPlaylistSnapshot(
            raw: sourceWirePayload(durationField: "\"duration\": 9.2e15"), name: "Source"
        )
        #expect(snapshot.tracks[0].durationMs == durationToMs(9.2e15))
    }

    // Reference (bignum) parses 1e300 fine; Swift Int cannot represent it, so
    // the wire path must throw a CATCHABLE fail-closed error — never trap
    // (documented reject-direction deviation).
    @Test("an out-of-range duration throws a catchable error instead of trapping")
    func hugeDurationThrowsCatchably() {
        for durationLiteral in ["1e300", "-1e300", "9.3e15"] {
            expectThrowsByteEqualMessage(
                "track duration milliseconds exceed the supported integer range",
                context: "F3 duration \(durationLiteral)"
            ) {
                _ = try parseExactPlaylistSnapshot(
                    raw: sourceWirePayload(durationField: "\"duration\": \(durationLiteral)"),
                    name: "Source"
                )
            }
        }
    }
}

@Suite("F4 — unsupported-cloud-status message renders Python repr")
struct CloudStatusMessageReprTests {

    private func applyMessage(cloudStatus: String) throws -> String {
        let source = PlaylistSnapshot(
            name: "Source",
            persistentId: "P",
            tracks: [track(persistentId: "CLOUD-A", cloudStatus: cloudStatus)]
        )
        let bridge = BoundaryRecordingBridge(
            source: source,
            readback: PlaylistSnapshot(name: "Target", persistentId: "T", tracks: [])
        )
        let plan = try buildPlan(source)
        do {
            _ = try bridge.applyPlan(plan: plan, targetName: "Target")
            return "<no error>"
        } catch {
            return String(describing: error)
        }
    }

    // Reference (python3): repr flips to double quotes for a value containing '.
    @Test("a single-quoted status renders with Python's quote flip")
    func quoteFlipStatus() throws {
        expectByteEqual(
            try applyMessage(cloudStatus: "Sub'status"),
            "source playlist changed after audit or plan is non-canonical; "
                + "unsupported cloud status \"Sub'status\" at source index 0; "
                + "create a fresh audit",
            context: "F4 quote flip"
        )
    }

    // Reference: repr('\x07') escapes the BEL — no raw control byte in the
    // operator-facing message.
    @Test("a control-character status renders as an \\x escape")
    func controlCharacterStatus() throws {
        expectByteEqual(
            try applyMessage(cloudStatus: "\u{07}"),
            "source playlist changed after audit or plan is non-canonical; "
                + "unsupported cloud status '\\x07' at source index 0; "
                + "create a fresh audit",
            context: "F4 BEL escape"
        )
    }

    // Reference: repr backslash-escapes the backslash.
    @Test("a backslash status renders with an escaped backslash")
    func backslashStatus() throws {
        expectByteEqual(
            try applyMessage(cloudStatus: "Back\\slash"),
            "source playlist changed after audit or plan is non-canonical; "
                + "unsupported cloud status 'Back\\\\slash' at source index 0; "
                + "create a fresh audit",
            context: "F4 backslash escape"
        )
    }
}

@Suite("F5 — post-writer-failure transcript is read-only")
struct WriterFailureTranscriptTests {

    private func expectReadOnlyTail(
        _ calls: [ScriptCommand],
        afterWriteIndex writeIndex: Int,
        context: String
    ) {
        for (offset, command) in calls.enumerated() where offset > writeIndex {
            if case .readJXA = command { continue }
            Issue.record(
                "\(context): non-read command after the failed write at call \(offset): \(command)"
            )
        }
    }

    @Test("consolidate writer failure is followed only by read commands")
    func consolidateFailureTranscriptIsReadOnly() throws {
        let fixture = try musicSnapshotFixtureText()
        let source = try parseExactPlaylistSnapshot(raw: fixture, name: "#Musica xTotal")
        let plan = try buildPlan(source)
        let empty = "{\"playlists\": []}"
        let runner = FakeRunner(results: [
            .success(fixture),                              // ensure: source read
            .success(empty),                                // target absence read
            .success(""),                                   // compile
            .failure(MusicCommandError("execute boom")),    // execute FAILS
            .success(fixture),                              // post-failure source read
            .success(empty),                                // post-failure target read
        ])

        let result = try MusicBridgeSession(runner: runner)
            .applyPlan(plan: plan, targetName: "Target")

        #expect(result.verificationOk == false)
        #expect(result.mismatches.contains("write failed: execute boom"))
        #expect(result.mismatches.contains {
            ByteText($0).contains("no exact-name target exists")
        })
        #expect(runner.calls.count == 6)
        guard case .executeCompiledScript = runner.calls[3] else {
            Issue.record("call 3 must be the failed execute: \(runner.calls)")
            return
        }
        expectReadOnlyTail(runner.calls, afterWriteIndex: 3, context: "consolidate")
    }

    @Test("merge writer failure is followed only by read commands")
    func mergeFailureTranscriptIsReadOnly() throws {
        let payload = allCopiesPayload()
        let copies = try parseAllCopies(raw: payload, name: "Trance 2022")
        let plan = try buildMergePlan(name: "Trance 2022", copies: copies)
        let empty = "{\"playlists\": []}"
        let runner = FakeRunner(results: [
            .success(payload),                              // ensure: copies read
            .success(empty),                                // target absence read
            .success(""),                                   // compile
            .failure(MusicCommandError("merge execute boom")),
            .success(payload),                              // post-failure copies read
            .success(empty),                                // post-failure target read
        ])

        let result = try MusicBridgeSession(runner: runner)
            .applyMergePlan(plan: plan, targetName: "Trance 2022 — Merged")

        #expect(result.verificationOk == false)
        #expect(result.mismatches.contains("write failed: merge execute boom"))
        #expect(runner.calls.count == 6)
        guard case .executeCompiledScript = runner.calls[3] else {
            Issue.record("call 3 must be the failed execute: \(runner.calls)")
            return
        }
        expectReadOnlyTail(runner.calls, afterWriteIndex: 3, context: "merge")
    }
}
