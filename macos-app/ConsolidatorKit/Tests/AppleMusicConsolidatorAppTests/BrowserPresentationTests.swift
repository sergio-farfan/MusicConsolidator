// BrowserPresentationTests.swift
// M8 — pure presentation layer under the sectioned source browser and the
// confirm-gate diagnostics: visible rendering of invisible scalars, the
// first-divergence scalar diff (golden-test diagnostic style), the
// near-identical WINNER pairs classifier (driven against the three REAL
// merge plans in reports/ — the live Trance 2022 / Soka Varios / SGI
// Artists operations), and section search filtering. Everything here is a
// pure function; no Music, no scripts, no I/O beyond loading the checked-in
// plan artifacts read-only.

import Foundation
import Testing
import ConsolidatorCore
@testable import AppleMusicConsolidatorApp

// MARK: - visible rendering

@Suite("Visible rendering of invisible scalars")
struct VisibleRenderingTests {

    @Test("trailing spaces render as middle dots")
    func trailingSpaces() {
        #expect(renderNameWithVisibleScalars("Kdrama ") == "Kdrama\u{B7}")
        #expect(renderNameWithVisibleScalars("Kdrama  ") == "Kdrama\u{B7}\u{B7}")
        #expect(renderNameWithVisibleScalars("A B ") == "A B\u{B7}")
    }

    @Test("interior spaces and visible text pass through unchanged")
    func visibleTextUnchanged() {
        #expect(renderNameWithVisibleScalars("3- China/Korea/Japan") == "3- China/Korea/Japan")
        #expect(renderNameWithVisibleScalars("A \u{2014} B") == "A \u{2014} B")
        #expect(renderNameWithVisibleScalars("Caf\u{E9}") == "Caf\u{E9}")
    }

    @Test("invisible non-space scalars render as U+XXXX")
    func invisibleScalars() {
        #expect(renderNameWithVisibleScalars("Kdrama\u{200B}") == "KdramaU+200B")
        #expect(renderNameWithVisibleScalars("\u{FEFF}Kdrama") == "U+FEFFKdrama")
        #expect(renderNameWithVisibleScalars("OST\u{A0}Game") == "OSTU+00A0Game")
        #expect(renderNameWithVisibleScalars("A\t") == "AU+0009")
        #expect(renderNameWithVisibleScalars("A\u{7}B") == "AU+0007B")
    }

    @Test("a trailing run mixes dots and U+XXXX correctly")
    func mixedTrailingRun() {
        #expect(renderNameWithVisibleScalars("A \u{200B}") == "A\u{B7}U+200B")
    }
}

// MARK: - scalar divergence

@Suite("First-divergence scalar diff")
struct ScalarDivergenceTests {

    @Test("equal strings have no divergence")
    func equalStrings() {
        #expect(firstScalarDivergence(expected: "Name", actual: "Name") == nil)
        #expect(firstScalarDivergence(expected: "", actual: "") == nil)
    }

    @Test("a trailing-space typo diverges past the expected end")
    func trailingSpaceTypo() {
        let divergence = firstScalarDivergence(expected: "Kdrama", actual: "Kdrama ")
        #expect(divergence == ScalarDivergence(index: 6, expected: nil, actual: " "))
    }

    @Test("an em-dash/hyphen swap diverges at the exact scalar")
    func emDashHyphen() {
        let divergence = firstScalarDivergence(expected: "A\u{2014}B", actual: "A-B")
        #expect(divergence == ScalarDivergence(index: 1, expected: "\u{2014}", actual: "-"))
    }

    @Test("a short typed name diverges at its end")
    func shortTyped() {
        let divergence = firstScalarDivergence(expected: "Name", actual: "Na")
        #expect(divergence == ScalarDivergence(index: 2, expected: "m", actual: nil))
        let empty = firstScalarDivergence(expected: "Name", actual: "")
        #expect(empty == ScalarDivergence(index: 0, expected: "N", actual: nil))
    }

    @Test("NFC vs NFD diverges at the scalar level")
    func nfcNfd() {
        let divergence = firstScalarDivergence(expected: "Caf\u{E9}", actual: "Cafe\u{301}")
        #expect(divergence == ScalarDivergence(index: 3, expected: "\u{E9}", actual: "e"))
    }

    @Test("descriptions carry index and U+XXXX of both sides")
    func descriptions() {
        #expect(
            describeDivergence(ScalarDivergence(index: 1, expected: "\u{2014}", actual: "-"))
                == "First difference at scalar index 1: expected U+2014 (EM DASH), typed U+002D (HYPHEN-MINUS)."
        )
        #expect(
            describeDivergence(ScalarDivergence(index: 6, expected: nil, actual: " "))
                == "Typed name continues past the expected name: extra U+0020 (SPACE) at scalar index 6."
        )
        #expect(
            describeDivergence(ScalarDivergence(index: 2, expected: "m", actual: nil))
                == "Typed name ends at scalar index 2; expected U+006D (LATIN SMALL LETTER M) next."
        )
    }

    @Test("name difference description for near-match variants")
    func nameDifference() {
        let text = describeNameDifference(reference: "Kdrama", other: "Kdrama ")
        #expect(text == "\u{201C}Kdrama\u{B7}\u{201D} differs from \u{201C}Kdrama\u{201D}: extra U+0020 (SPACE) at scalar index 6.")
    }
}

// MARK: - near-identical winner pairs

@Suite("Near-identical winner pairs")
struct NearIdenticalWinnerPairTests {

    private func winner(
        _ index: Int,
        title: String,
        artist: String = "Artist",
        durationMs: Int?,
        pid: String
    ) -> TrackSnapshot {
        presentationTrack(
            sourceIndex: index,
            databaseId: index + 1,
            persistentId: pid,
            title: title,
            artist: artist,
            durationMs: durationMs
        )
    }

    @Test("winners sharing normalized title+artist with different durations pair up")
    func basicPair() {
        let tracks = [
            winner(0, title: "Gamemaster", durationMs: 482_013, pid: "PID-A"),
            winner(1, title: "Other Song", durationMs: 100_000, pid: "PID-B"),
            winner(2, title: "GAMEMASTER", durationMs: 481_013, pid: "PID-C"),
        ]
        let pairs = nearIdenticalWinnerPairs(in: tracks)
        #expect(pairs.count == 1)
        #expect(pairs[0].first.persistentId == "PID-A")
        #expect(pairs[0].second.persistentId == "PID-C")
    }

    @Test("distinct titles or artists never pair")
    func distinctNeverPair() {
        let tracks = [
            winner(0, title: "Song A", durationMs: 100_000, pid: "PID-A"),
            winner(1, title: "Song B", durationMs: 100_000, pid: "PID-B"),
            winner(2, title: "Song A", artist: "Different", durationMs: 90_000, pid: "PID-C"),
        ]
        #expect(nearIdenticalWinnerPairs(in: tracks).isEmpty)
    }

    @Test("tracks without normalized title or artist are skipped")
    func nonEligibleSkipped() {
        let tracks = [
            winner(0, title: "", durationMs: 100_000, pid: "PID-A"),
            winner(1, title: "", durationMs: 90_000, pid: "PID-B"),
            winner(2, title: "X", artist: " ", durationMs: 100_000, pid: "PID-C"),
            winner(3, title: "X", artist: " ", durationMs: 90_000, pid: "PID-D"),
        ]
        #expect(nearIdenticalWinnerPairs(in: tracks).isEmpty)
    }

    @Test("equal durations never pair (same-key tracks cannot both be winners)")
    func equalDurationsNeverPair() {
        let tracks = [
            winner(0, title: "X", durationMs: nil, pid: "PID-A"),
            winner(1, title: "X", durationMs: nil, pid: "PID-B"),
        ]
        #expect(nearIdenticalWinnerPairs(in: tracks).isEmpty)
    }

    @Test("a nil-duration winner pairs against a timed twin (fail-toward-attention)")
    func nilDurationPairs() {
        let tracks = [
            winner(0, title: "X", durationMs: 100_000, pid: "PID-A"),
            winner(1, title: "X", durationMs: nil, pid: "PID-B"),
        ]
        #expect(nearIdenticalWinnerPairs(in: tracks).count == 1)
    }

    @Test("three variants yield every unordered pair in output order")
    func threeVariants() {
        let tracks = [
            winner(0, title: "X", durationMs: 1000, pid: "PID-A"),
            winner(1, title: "X", durationMs: 2000, pid: "PID-B"),
            winner(2, title: "X", durationMs: 3000, pid: "PID-C"),
        ]
        let pairs = nearIdenticalWinnerPairs(in: tracks)
        #expect(pairs.map { "\($0.first.persistentId)/\($0.second.persistentId)" }
            == ["PID-A/PID-B", "PID-A/PID-C", "PID-B/PID-C"])
    }
}

// MARK: - the three real merge plans (ground truth)

private func reportsURL(_ basename: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("reports")
        .appendingPathComponent(basename)
}

@Suite("Near-identical winner pairs — real plan fixtures")
struct RealPlanNearIdenticalTests {

    private func pairs(for basename: String) throws -> [NearIdenticalWinnerPair] {
        let plan = try loadMergePlan(from: reportsURL(basename))
        let output = planOutputTracks(
            winnerSourceIndexes: plan.winnerSourceIndexes,
            from: plan.combinedTracks
        )
        #expect(output.count == plan.winnerSourceIndexes.count)
        return nearIdenticalWinnerPairs(in: output)
    }

    @Test("Trance 2022: exactly the Gamemaster pair")
    func trance() throws {
        let found = try pairs(for: "Trance-2022-20260801-225539-0600.plan.json")
        #expect(found.count == 1)
        let pids = Set([found[0].first.persistentId, found[0].second.persistentId])
        #expect(pids == ["6FDC9C6E5E713E50", "59956C9C3E4F609F"])
        #expect(found[0].first.durationMs != found[0].second.durationMs)
    }

    @Test("Soka Varios: exactly the Lotus Sutra pair")
    func soka() throws {
        let found = try pairs(for: "Soka-Varios-20260801-230842-0600.plan.json")
        #expect(found.count == 1)
        let pids = Set([found[0].first.persistentId, found[0].second.persistentId])
        #expect(pids == ["3C99CFC8FFC39860", "326164DC51221921"])
    }

    @Test("SGI Artists: zero pairs")
    func sgi() throws {
        let found = try pairs(for: "SGI-Artists-20260801-230900-0600.plan.json")
        #expect(found.isEmpty)
    }
}

// MARK: - section search filtering

@Suite("Browser search filtering")
struct SectionFilterTests {

    private func listing(_ id: Double, _ name: String, _ pid: String) -> PlaylistListing {
        PlaylistListing(
            playlistId: id, name: name, persistentId: pid,
            trackCount: 5, isSmart: false, specialKind: "none"
        )
    }

    private var sections: PlaylistBrowseSections {
        buildPlaylistBrowseSections(from: [
            listing(1, "Trance 2022", "P-1"),
            listing(2, "Trance 2022", "P-2"),
            listing(3, "Kdrama", "P-3"),
            listing(4, "Kdrama ", "P-4"),
            listing(5, "Soka Varios", "P-5"),
        ])
    }

    @Test("an empty query is the identity")
    func emptyQuery() {
        let filtered = filteredSections(sections, query: "")
        #expect(filtered == sections)
    }

    @Test("queries filter every section case-insensitively")
    func filtering() {
        let trance = filteredSections(sections, query: "trance")
        #expect(trance.groups.map(\.name) == ["Trance 2022"])
        #expect(trance.singletons.isEmpty)
        #expect(trance.nearMatches.isEmpty)
        #expect(trance.allPlaylists.count == 2)

        let kdrama = filteredSections(sections, query: "KDRAMA")
        #expect(kdrama.groups.isEmpty)
        #expect(kdrama.singletons.map(\.name) == ["Kdrama", "Kdrama "])
        #expect(kdrama.nearMatches.count == 1)
        #expect(kdrama.allPlaylists.count == 2)

        let none = filteredSections(sections, query: "zzz")
        #expect(none.groups.isEmpty && none.singletons.isEmpty
            && none.nearMatches.isEmpty && none.allPlaylists.isEmpty)
    }
}
