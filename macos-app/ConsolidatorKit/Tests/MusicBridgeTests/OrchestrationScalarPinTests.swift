// OrchestrationScalarPinTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// BINDING (M5 brief): mutation-sensitive NFC/NFD regression pins for every
// NEW comparison surface the fail-closed orchestration adds — snapshot-parse
// name matching, target-absence matching, readback verification (consolidate
// and merge), post-write source revalidation, and the merge copy-PID lookup.
//
// Every pinned behavior was verified against the python3 reference FIRST
// (/tmp/m5/reference_pins.py; outputs recorded in the M5 report):
//   P1 verify_output rejects an NFD-drifted target persistent ID
//   P2 _source_mismatches reports an NFD-drifted post-write title (+fingerprint)
//   P3 ensure_all_copies_match rejects an NFD-drifted copy track title
//   P4 assert_target_absent does NOT collide with an NFD-named playlist
//   P5 parse_exact_playlist_snapshot rejects an NFD-named exact match
//   P6 verify_merge_output rejects an NFD-drifted target persistent ID
//   P7 ensure_all_copies_match treats an NFD-drifted copy PID as absent
//
// Message assertions use BYTE equality: Swift String == is canonical
// equivalence and would call "planned 'Café'(NFC), actual 'Café'(NFD)" equal
// to its swapped counterpart — exactly the masking these pins exist to catch.

import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

@Suite("Orchestration scalar-exactness pins (NFC/NFD, mutation-sensitive)")
struct OrchestrationScalarPinTests {

    // Guards the corpus itself: canonically equivalent, scalar-different.
    @Test("fixture precondition: NFC and NFD forms are == but scalar-different")
    func fixturePrecondition() {
        #expect(nfcCafe == nfdCafe)
        #expect(!nfcCafe.unicodeScalars.elementsEqual(nfdCafe.unicodeScalars))
    }

    // P5 — reference: ValueError "expected exactly one user playlist named 'Café'"
    @Test("parse rejects an NFD-named playlist when the NFC name is requested")
    func parseRejectsNFDName() {
        let raw = """
        {"playlists": [{"id": 1, "name": "\(nfdCafe)", "persistent_id": "P", "tracks": []}]}
        """
        expectThrowsByteEqualMessage(
            "expected exactly one user playlist named '\(nfcCafe)'",
            context: "P5 NFC-requested vs NFD-present"
        ) {
            _ = try parseExactPlaylistSnapshot(raw: raw, name: nfcCafe)
        }
    }

    // P4 — reference: assert_target_absent returns normally (no collision).
    @Test("target absence check does not collide with an NFD-named playlist")
    func targetAbsenceIgnoresNFDName() throws {
        let raw = """
        {"playlists": [{"id": 1, "name": "\(nfdCafe)", "persistent_id": "P", "tracks": []}]}
        """
        // Reference-verified: no error. A canonical-equivalence comparison here
        // would raise a false "target user playlist already exists".
        try MusicBridgeSession(runner: FakeRunner(outputs: [raw]))
            .assertTargetAbsent(targetName: nfcCafe)
    }

    // P1 — reference mismatch: "track 1 persistent ID mismatch: planned 'Café', actual 'Café'"
    @Test("readback verify rejects an NFD-drifted target persistent ID")
    func verifyOutputRejectsNFDPersistentId() throws {
        let source = PlaylistSnapshot(
            name: "Source",
            persistentId: "P",
            tracks: [
                track(sourceIndex: 0, databaseId: 1, persistentId: nfcCafe),
                track(
                    sourceIndex: 1, databaseId: 2, persistentId: "B",
                    title: "Second Song", sampleRateHz: 48000
                ),
            ]
        )
        let plan = try buildPlan(source)
        var drifted = source.tracks[0]
        drifted.persistentId = nfdCafe
        let actual = PlaylistSnapshot(
            name: "Target", persistentId: "T", tracks: [drifted, source.tracks[1]]
        )

        let result = try verifyOutput(plan: plan, source: source, actual: actual)

        #expect(result.verificationOk == false)
        #expect(result.mismatches.count == 1)
        expectByteEqual(
            result.mismatches.first ?? "",
            "track 1 persistent ID mismatch: planned '\(nfcCafe)', actual '\(nfdCafe)'",
            context: "P1 NFD target persistent ID"
        )
    }

    // P2 — reference mismatches: NFD title line plus the fingerprint line.
    @Test("post-write source revalidation rejects an NFD-drifted title")
    func postWriteSourceRejectsNFDTitle() throws {
        let nfcTitle = "\(nfcCafe) Song"
        let nfdTitle = "\(nfdCafe) Song"
        let source = PlaylistSnapshot(
            name: "Source",
            persistentId: "P",
            tracks: [track(sourceIndex: 0, databaseId: 1, persistentId: "A", title: nfcTitle)]
        )
        var driftedTrack = source.tracks[0]
        driftedTrack.title = nfdTitle
        let drifted = PlaylistSnapshot(name: "Source", persistentId: "P", tracks: [driftedTrack])
        let plan = try buildPlan(source)
        let target = PlaylistSnapshot(name: "Target", persistentId: "T", tracks: source.tracks)

        let result = try SourceAfterWriteBridge(
            initialSource: source, changedSource: drifted, target: target
        ).applyPlan(plan: plan, targetName: "Target")

        #expect(result.verificationOk == false)
        #expect(result.mismatches.count == 2)
        expectByteEqual(
            result.mismatches.first ?? "",
            "source track 1 title mismatch after write: "
                + "planned '\(nfcTitle)', actual '\(nfdTitle)'",
            context: "P2 NFD post-write title"
        )
        // The fingerprint hex is Swift-canonical (locked M2 decision), so only
        // the reference-verbatim prefix is pinned here.
        #expect(
            result.mismatches.count > 1
                && result.mismatches[1].hasPrefix("source fingerprint mismatch after write: planned ")
        )
    }

    // P3 — reference: "copy 'PID-B' changed after audit: source track 1 title
    // mismatch after write: planned '…', actual '…'; create a fresh audit"
    @Test("merge preflight rejects an NFD-drifted track title inside a copy")
    func ensureAllCopiesRejectsNFDTitle() throws {
        let nfcTitle = "\(nfcCafe) Song"
        let nfdTitle = "\(nfdCafe) Song"
        let copies = [
            PlaylistSnapshot(
                name: "G", persistentId: "PID-A",
                tracks: [track(sourceIndex: 0, databaseId: 1, persistentId: "A0")]
            ),
            PlaylistSnapshot(
                name: "G", persistentId: "PID-B",
                tracks: [track(sourceIndex: 0, databaseId: 2, persistentId: "B0", title: nfcTitle)]
            ),
        ]
        let plan = try buildMergePlan(name: "G", copies: copies)
        var driftedTrack = copies[1].tracks[0]
        driftedTrack.title = nfdTitle
        let live = [
            copies[0],
            PlaylistSnapshot(name: "G", persistentId: "PID-B", tracks: [driftedTrack]),
        ]

        expectThrowsByteEqualMessage(
            "copy 'PID-B' changed after audit: source track 1 title mismatch after write: "
                + "planned '\(nfcTitle)', actual '\(nfdTitle)'; create a fresh audit",
            context: "P3 NFD copy title"
        ) {
            _ = try FakeCopiesBridge(copies: live).ensureAllCopiesMatch(plan: plan)
        }
    }

    // P7 — reference: "expected copy 'Café' is absent; create a fresh audit"
    @Test("merge preflight treats an NFD-drifted copy persistent ID as absent")
    func ensureAllCopiesRejectsNFDPersistentId() throws {
        let copies = [
            PlaylistSnapshot(
                name: "G", persistentId: "PID-A",
                tracks: [track(sourceIndex: 0, databaseId: 1, persistentId: "A0")]
            ),
            PlaylistSnapshot(
                name: "G", persistentId: nfcCafe,
                tracks: [track(sourceIndex: 0, databaseId: 2, persistentId: "B0", title: "Two")]
            ),
        ]
        let plan = try buildMergePlan(name: "G", copies: copies)
        let live = [
            copies[0],
            PlaylistSnapshot(name: "G", persistentId: nfdCafe, tracks: copies[1].tracks),
        ]

        expectThrowsByteEqualMessage(
            "expected copy '\(nfcCafe)' is absent; create a fresh audit",
            context: "P7 NFD copy persistent ID"
        ) {
            _ = try FakeCopiesBridge(copies: live).ensureAllCopiesMatch(plan: plan)
        }
    }

    // P6 — reference mismatch identical to P1 through verify_merge_output.
    @Test("merge readback verify rejects an NFD-drifted target persistent ID")
    func verifyMergeOutputRejectsNFDPersistentId() throws {
        let copies = [
            PlaylistSnapshot(
                name: "G", persistentId: "PID-A",
                tracks: [track(sourceIndex: 0, databaseId: 1, persistentId: nfcCafe)]
            ),
            PlaylistSnapshot(
                name: "G", persistentId: "PID-B",
                tracks: [track(sourceIndex: 0, databaseId: 2, persistentId: "B0", title: "Two")]
            ),
        ]
        let plan = try buildMergePlan(name: "G", copies: copies)
        let combined = plan.combinedTracks
        let winners = plan.winnerSourceIndexes.map { combined[$0] }
        let driftedTracks = winners.map { winner -> TrackSnapshot in
            var copy = winner
            if copy.persistentId.unicodeScalars.elementsEqual(nfcCafe.unicodeScalars) {
                copy.persistentId = nfdCafe
            }
            return copy
        }
        let actual = PlaylistSnapshot(
            name: "G — Merged", persistentId: "T", tracks: driftedTracks
        )

        let result = try verifyMergeOutput(plan: plan, actual: actual)

        #expect(result.verificationOk == false)
        #expect(result.mismatches.count == 1)
        expectByteEqual(
            result.mismatches.first ?? "",
            "track 1 persistent ID mismatch: planned '\(nfcCafe)', actual '\(nfdCafe)'",
            context: "P6 NFD merge target persistent ID"
        )
    }
}

// Every expected value below was produced by the python3 reference first
// (repr(...) and music_bridge._sanitized_stderr(...); outputs recorded in the
// M5 report). These shims feed every operator-facing mismatch message, so a
// divergence here would silently change apply diagnostics.
@Suite("Python text-shim parity pins (repr and sanitized stderr)")
struct PythonTextShimPinTests {

    @Test("pythonRepr matches Python repr on quoting and escape classes")
    func pythonReprParity() {
        // C0 control and tab short-escape.
        expectByteEqual(
            pythonRepr("\u{07}tab\there"), "'\\x07tab\\there'", context: "C0 + tab"
        )
        // Non-printable format character above 0xFF -> \uXXXX.
        expectByteEqual(
            pythonRepr("zero\u{200B}width"), "'zero\\u200bwidth'", context: "ZWSP"
        )
        // Printable non-BMP scalar passes raw.
        expectByteEqual(
            pythonRepr("emoji \u{1F600} ok"), "'emoji \u{1F600} ok'", context: "emoji raw"
        )
        // Both quote kinds present -> single quotes win, ' escaped.
        expectByteEqual(
            pythonRepr("both ' and \" quotes"),
            "'both \\' and \" quotes'",
            context: "mixed quotes"
        )
        // Single quote only -> double quotes (pinned via parity S5 too).
        expectByteEqual(
            pythonRepr("O'Brien—B"), "\"O'Brien—B\"", context: "quote flip"
        )
        // Non-printable Latin-1 separator -> \xXX.
        expectByteEqual(
            pythonRepr("nb\u{A0}space"), "'nb\\xa0space'", context: "NBSP"
        )
    }

    @Test("sanitizedStderr collapses noise and truncates at 500 code points")
    func sanitizedStderrParity() {
        expectByteEqual(
            sanitizedStderr("line1\nline2\t\u{07}  spaced end"),
            "line1 line2 spaced end",
            context: "noise collapse"
        )
        expectByteEqual(sanitizedStderr(""), "", context: "empty")
        expectByteEqual(sanitizedStderr(nil), "", context: "nil")

        // 120 words of "alpha " (719 code points after strip) -> exactly 500,
        // ending "pha alpha a…" (reference-verified).
        let long = String(repeating: "alpha ", count: 120)
            .trimmingCharacters(in: .whitespaces)
        let sanitized = sanitizedStderr(long)
        #expect(sanitized.unicodeScalars.count == 500)
        #expect(sanitized.hasPrefix("alpha alpha alpha alpha "))
        #expect(sanitized.hasSuffix("pha alpha a…"))
    }
}
