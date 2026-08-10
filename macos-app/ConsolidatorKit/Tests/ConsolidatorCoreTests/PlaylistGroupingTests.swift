// PlaylistGroupingTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// M8 Part 1.4 — eligibility grouping for the sectioned source browser:
// exact-scalar name classes into {groups (N>=2), singletons, nearMatches},
// where a near match is a set of names that COLLIDE after the sweep
// normalization (strip Cf format scalars, then collapse python-whitespace
// runs and trim — " ".join(name.split()); fix round 1, finding 1) but
// DIFFER exactly. The fixtures reproduce the real 2026-08-02 library sweep:
// 7 one-trailing-space twin pairs (progress.md "7 pairs" entry), plus the
// synthetic ZWSP / NBSP / double-space-interior shapes from the brief.
//
// The merge contract stays intact by construction: only `groups` (N>=2
// copies of ONE exact name) are ever selectable for merge; near matches and
// singletons are advisory.

import Foundation
import Testing
@testable import ConsolidatorCore

private func listing(
    id: Double,
    name: String,
    pid: String,
    count: Int = 10,
    smart: Bool = false,
    specialKind: String = "none"
) -> PlaylistListing {
    PlaylistListing(
        playlistId: id,
        name: name,
        persistentId: pid,
        trackCount: count,
        isSmart: smart,
        specialKind: specialKind
    )
}

/// The 7 real trailing-space twin base names from the library sweep.
private let realTwinBaseNames = [
    "3- China/Korea/Japan",
    "DJ Mamabear",
    "From Motown to Momentum: Built on Soul",
    "Kdrama",
    "Lyli's Month of Mixes",
    "OST Game",
    "Positive",
]

@Suite("Near-match normalization (sweep semantics)")
struct NearMatchNormalizationTests {

    @Test("trailing python whitespace is trimmed")
    func trailingWhitespaceTrimmed() {
        #expect(nearMatchNormalizedName("Kdrama ") == "Kdrama")
        #expect(nearMatchNormalizedName("Kdrama\u{00A0}") == "Kdrama")   // NBSP
        #expect(nearMatchNormalizedName(" Kdrama") == "Kdrama")
        #expect(nearMatchNormalizedName("Kdrama\t") == "Kdrama")
    }

    @Test("Cf format scalars are stripped anywhere in the name")
    func formatScalarsStripped() {
        #expect(nearMatchNormalizedName("Kdrama\u{200B}") == "Kdrama")   // trailing ZWSP
        #expect(nearMatchNormalizedName("Kd\u{200B}rama") == "Kdrama")   // interior ZWSP
        #expect(nearMatchNormalizedName("\u{FEFF}Kdrama") == "Kdrama")   // leading FEFF
        #expect(nearMatchNormalizedName("Kdrama\u{00AD}") == "Kdrama")   // soft hyphen
    }

    @Test("Cf-strip runs BEFORE the trim (a Cf scalar cannot shield trailing whitespace)")
    func stripBeforeTrim() {
        // Trailing "space + ZWSP": trim-first would keep the space (ZWSP is
        // not python whitespace); strip-first removes the ZWSP and then trims.
        #expect(nearMatchNormalizedName("Kdrama \u{200B}") == "Kdrama")
    }

    @Test("interior python-whitespace runs collapse to a single space (fix round 1, finding 1)")
    func interiorWhitespaceCollapsed() {
        // The governing sweep semantics are " ".join(name.split()) — Python
        // str.split() splits on the FULL python whitespace set, so interior
        // runs of ANY of the 29 scalars collapse to one U+0020.
        #expect(nearMatchNormalizedName("Mix  Tape") == "Mix Tape")
        #expect(nearMatchNormalizedName("Mix   Tape") == "Mix Tape")
        #expect(nearMatchNormalizedName("Mix\u{00A0}Tape") == "Mix Tape")
        #expect(nearMatchNormalizedName("Mix\tTape") == "Mix Tape")
        #expect(nearMatchNormalizedName("Mix \u{00A0}\tTape") == "Mix Tape")
        // A Cf scalar inside a whitespace run cannot split it (Cf-strip runs
        // first): space + ZWSP + space is ONE run.
        #expect(nearMatchNormalizedName("Mix \u{200B} Tape") == "Mix Tape")
        // Single interior spaces are already canonical.
        #expect(nearMatchNormalizedName("Mix Tape") == "Mix Tape")
    }

    @Test("canonical equivalence does not apply (scalar identity preserved)")
    func noCanonicalNormalization() {
        let nfc = "Caf\u{E9}"
        let nfd = "Cafe\u{301}"
        #expect(!nearMatchNormalizedName(nfc).unicodeScalars.elementsEqual(
            nearMatchNormalizedName(nfd).unicodeScalars
        ))
    }
}

@Suite("Browse section grouping")
struct PlaylistGroupingTests {

    @Test("the real 7 trailing-space pairs surface as near matches, all singletons")
    func realSevenPairSweep() {
        var listings: [PlaylistListing] = []
        var id = 100.0
        for base in realTwinBaseNames {
            listings.append(listing(id: id, name: base, pid: "P-\(Int(id))"))
            id += 1
            listings.append(listing(id: id, name: base + " ", pid: "P-\(Int(id))"))
            id += 1
        }

        let sections = buildPlaylistBrowseSections(from: listings)

        #expect(sections.groups.isEmpty)
        #expect(sections.singletons.count == 14)
        #expect(sections.nearMatches.count == 7)
        for cluster in sections.nearMatches {
            #expect(cluster.variants.count == 2)
            let names = cluster.variants.map(\.name)
            // One variant is the base, the other the trailing-space twin.
            #expect(names.contains(cluster.normalizedName))
            #expect(names.contains(cluster.normalizedName + " "))
            for variant in cluster.variants {
                #expect(variant.listings.count == 1)
            }
        }
        // Every base name is represented.
        let normalized = Set(sections.nearMatches.map(\.normalizedName))
        #expect(normalized == Set(realTwinBaseNames))
    }

    @Test("exact-name copies form mergeable groups in ascending input order")
    func exactNameGroups() {
        let listings = [
            listing(id: 10, name: "Trance 2022", pid: "P-A", count: 9),
            listing(id: 20, name: "Trance 2022", pid: "P-B", count: 10),
            listing(id: 30, name: "Solo", pid: "P-C", count: 5),
            listing(id: 40, name: "SGI Artists", pid: "P-D", count: 21),
            listing(id: 50, name: "SGI Artists", pid: "P-E", count: 14),
            listing(id: 60, name: "SGI Artists", pid: "P-F", count: 20),
        ]

        let sections = buildPlaylistBrowseSections(from: listings)

        #expect(sections.groups.count == 2)
        #expect(sections.groups.map(\.name) == ["SGI Artists", "Trance 2022"])
        let sgi = sections.groups[0]
        #expect(sgi.copies.map(\.persistentId) == ["P-D", "P-E", "P-F"])
        #expect(sgi.combinedTrackCount == 55)
        let trance = sections.groups[1]
        #expect(trance.copies.map(\.persistentId) == ["P-A", "P-B"])
        #expect(trance.combinedTrackCount == 19)
        #expect(sections.singletons.map(\.name) == ["Solo"])
        #expect(sections.nearMatches.isEmpty)
    }

    @Test("a group can also participate in a near-match cluster")
    func groupWithNearTwin() {
        let listings = [
            listing(id: 1, name: "Kdrama", pid: "P-1"),
            listing(id: 2, name: "Kdrama", pid: "P-2"),
            listing(id: 3, name: "Kdrama ", pid: "P-3"),
        ]

        let sections = buildPlaylistBrowseSections(from: listings)

        #expect(sections.groups.count == 1)
        #expect(sections.groups[0].name == "Kdrama")
        #expect(sections.groups[0].copies.count == 2)
        #expect(sections.singletons.map(\.name) == ["Kdrama "])
        #expect(sections.nearMatches.count == 1)
        let cluster = sections.nearMatches[0]
        #expect(cluster.variants.map(\.name) == ["Kdrama", "Kdrama "])
        #expect(cluster.variants[0].listings.count == 2)
        #expect(cluster.variants[1].listings.count == 1)
    }

    @Test("synthetic invisible twins: ZWSP, NBSP, interior whitespace runs, and tabs all collide")
    func syntheticShapes() {
        let listings = [
            listing(id: 1, name: "OST Game", pid: "P-1"),
            listing(id: 2, name: "OST Game\u{200B}", pid: "P-2"),      // trailing ZWSP
            listing(id: 3, name: "Positive", pid: "P-3"),
            listing(id: 4, name: "Positive\u{00A0}", pid: "P-4"),      // trailing NBSP
            listing(id: 5, name: "Mix Tape", pid: "P-5"),
            listing(id: 6, name: "Mix  Tape", pid: "P-6"),             // interior double space
            listing(id: 7, name: "DJ Mamabear", pid: "P-7"),
            listing(id: 8, name: "DJ\u{00A0}Mamabear", pid: "P-8"),    // interior NBSP
            listing(id: 9, name: "Kdrama", pid: "P-9"),
            listing(id: 10, name: "Kdrama\tExtra   Space", pid: "P-10"), // tab + triple space
            listing(id: 11, name: "Kdrama Extra Space", pid: "P-11"),
        ]

        let sections = buildPlaylistBrowseSections(from: listings)

        #expect(sections.groups.isEmpty)
        #expect(sections.singletons.count == 11)
        // Fix round 1, finding 1: the sweep semantics are
        // " ".join(name.split()) — interior runs of ANY python whitespace
        // (double space, NBSP, TAB, triple space) collapse, so these are all
        // rename-to-merge near matches now. The lone "Kdrama" (no partner
        // after normalization) stays out of the clusters.
        #expect(sections.nearMatches.count == 5)
        #expect(Set(sections.nearMatches.map(\.normalizedName))
            == ["OST Game", "Positive", "Mix Tape", "DJ Mamabear", "Kdrama Extra Space"])
    }

    @Test("a cluster can hold more than two variants")
    func tripleVariantCluster() {
        let listings = [
            listing(id: 1, name: "Kdrama", pid: "P-1"),
            listing(id: 2, name: "Kdrama ", pid: "P-2"),
            listing(id: 3, name: "Kdrama  ", pid: "P-3"),
        ]
        let sections = buildPlaylistBrowseSections(from: listings)
        #expect(sections.nearMatches.count == 1)
        #expect(sections.nearMatches[0].variants.map(\.name) == ["Kdrama", "Kdrama ", "Kdrama  "])
    }

    @Test("NFC/NFD names stay distinct exact classes and do NOT near-match")
    func nfcNfdSeparation() {
        let listings = [
            listing(id: 1, name: "Caf\u{E9}", pid: "P-1"),
            listing(id: 2, name: "Cafe\u{301}", pid: "P-2"),
        ]
        let sections = buildPlaylistBrowseSections(from: listings)
        // Two classes (scalar-exact keys, never String ==) and no cluster
        // (the sweep formula performs no canonical normalization).
        #expect(sections.groups.isEmpty)
        #expect(sections.singletons.count == 2)
        #expect(sections.nearMatches.isEmpty)
    }

    @Test("allPlaylists is alphabetical (casefold, then scalar tie-break) and complete")
    func allPlaylistsAlphabetical() {
        let listings = [
            listing(id: 4, name: "beta", pid: "P-4"),
            listing(id: 1, name: "Alpha", pid: "P-1"),
            listing(id: 3, name: "Beta", pid: "P-3"),
            listing(id: 2, name: "alpha", pid: "P-2"),
            listing(id: 5, name: "#Numbers", pid: "P-5"),
        ]
        let sections = buildPlaylistBrowseSections(from: listings)
        #expect(sections.allPlaylists.count == 5)
        // Casefold-insensitive alphabetical; equal folds break by exact
        // scalar order (uppercase first: "A" < "a").
        #expect(sections.allPlaylists.map(\.name) == ["#Numbers", "Alpha", "alpha", "Beta", "beta"])
    }

    @Test("groups and singletons are sorted alphabetically; clusters by normalized name")
    func sectionOrdering() {
        let listings = [
            listing(id: 1, name: "zeta", pid: "P-1"),
            listing(id: 2, name: "zeta", pid: "P-2"),
            listing(id: 3, name: "Alpha", pid: "P-3"),
            listing(id: 4, name: "Alpha", pid: "P-4"),
            listing(id: 5, name: "mid", pid: "P-5"),
            listing(id: 6, name: "beta ", pid: "P-6"),
            listing(id: 7, name: "beta", pid: "P-7"),
            listing(id: 8, name: "Alpha ", pid: "P-8"),
        ]
        let sections = buildPlaylistBrowseSections(from: listings)
        #expect(sections.groups.map(\.name) == ["Alpha", "zeta"])
        #expect(sections.singletons.map(\.name) == ["Alpha ", "beta", "beta ", "mid"])
        // No casefolding in the sweep formula: only exact-case twins cluster.
        #expect(sections.nearMatches.map(\.normalizedName) == ["Alpha", "beta"])
    }

    @Test("empty input yields empty sections")
    func emptyInput() {
        let sections = buildPlaylistBrowseSections(from: [])
        #expect(sections.allPlaylists.isEmpty)
        #expect(sections.groups.isEmpty)
        #expect(sections.singletons.isEmpty)
        #expect(sections.nearMatches.isEmpty)
    }
}
