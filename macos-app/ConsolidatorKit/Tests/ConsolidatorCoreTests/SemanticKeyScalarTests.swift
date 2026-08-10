// SemanticKeyScalarTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Regression for the BINDING finding carried from the M1 review (deferred
// minor 3, docs/superpowers/sdd/2026-07-31-macos-app/m1-review-findings.md):
// Python dicts group semantic keys by CODE-POINT equality, while Swift String
// ==/hash use canonical equivalence and would merge canonically-equivalent-
// but-scalar-different keys. SemanticKey must therefore compare and hash at
// Unicode-scalar level.
//
// Verified against the reference (python3, 2026-07-31): inputs "\u{0390}" and
// "\u{03AA}\u{0301}" normalize to "\u{03B9}\u{0308}\u{0301}" vs
// "\u{03CA}\u{0301}" — canonically equivalent, code-point different — and
// build_plan keeps them as TWO distinct tracks (winners (0, 1), no decisions).

import Foundation
import Testing
@testable import ConsolidatorCore

private func makeTrack(sourceIndex: Int, title: String, persistentId: String) -> TrackSnapshot {
    TrackSnapshot(
        sourceIndex: sourceIndex,
        databaseId: 1,
        persistentId: persistentId,
        title: title,
        artist: "Artist",
        album: "Album",
        durationMs: 183000,
        kind: "Apple Music AAC audio file",
        bitRateKbps: 256,
        sampleRateHz: 44100,
        cloudStatus: "",
        isFileTrack: false
    )
}

@Suite("SemanticKey scalar-level equality (binding M1 finding)")
struct SemanticKeyScalarTests {

    // "ΐ" precomposed vs "Ϊ" + combining acute: normalized outputs are
    // canonically equivalent but scalar-different; the reference keeps them apart.
    private let titleA = "\u{0390}"
    private let titleB = "\u{03AA}\u{0301}"

    @Test("keys with canonically-equivalent but scalar-different text stay distinct")
    func scalarDifferentKeysAreDistinct() throws {
        let keyA = try #require(semanticKey(makeTrack(sourceIndex: 0, title: titleA, persistentId: "P0")))
        let keyB = try #require(semanticKey(makeTrack(sourceIndex: 1, title: titleB, persistentId: "P1")))

        // Precondition of the regression: the normalized titles really are
        // scalar-different (else this test is vacuous).
        #expect(Array(keyA.title.unicodeScalars) == [Unicode.Scalar(0x03B9)!, Unicode.Scalar(0x0308)!, Unicode.Scalar(0x0301)!])
        #expect(Array(keyB.title.unicodeScalars) == [Unicode.Scalar(0x03CA)!, Unicode.Scalar(0x0301)!])

        #expect(keyA != keyB, "SemanticKey == must use scalar equality, not canonical equivalence")
        #expect(Set([keyA, keyB]).count == 2, "SemanticKey hashing must not merge scalar-different keys")

        // The reference's grouping structure: a dict keyed by the semantic key
        // must produce TWO groups for this pair.
        var groups: [SemanticKey: [TrackSnapshot]] = [:]
        groups[keyA, default: []].append(makeTrack(sourceIndex: 0, title: titleA, persistentId: "P0"))
        groups[keyB, default: []].append(makeTrack(sourceIndex: 1, title: titleB, persistentId: "P1"))
        #expect(groups.count == 2)
    }
}
