// ResolverTests.swift
// Port of tests/test_resolver.py (ResolverTests + MergeResolverTests) against
// the Swift resolver. Fingerprint tests compare Swift-side RESULTS only —
// fingerprint bytes are Swift-canonical, never Python-byte-identical.

import Foundation
import Testing
@testable import ConsolidatorCore

@Suite("Resolver — ported cases from tests/test_resolver.py")
struct ResolverPortedTests {

    @Test func prefersAvailableThenHigherSampleRate() throws {
        let first = track(sourceIndex: 0, persistentId: "FIRST", sampleRateHz: 44100)
        let unavailableLossless = track(
            sourceIndex: 1,
            persistentId: "OLD",
            kind: "AIFF audio file",
            sampleRateHz: 96000,
            cloudStatus: "No Longer Available",
            isFileTrack: true
        )
        let best = track(sourceIndex: 2, persistentId: "BEST", sampleRateHz: 48000)
        let source = PlaylistSnapshot(
            name: "Source", persistentId: "PLAYLIST",
            tracks: [first, unavailableLossless, best]
        )

        let plan = try buildPlan(source)

        #expect(plan.winnerSourceIndexes == [2])
        #expect(plan.decisions[0].winner.persistentId == "BEST")
        #expect(plan.decisions[0].firstSourceIndex == 0)
    }

    @Test func neverCollapsesArtistSpellingOrDurationVariation() throws {
        let source = PlaylistSnapshot(
            name: "Source", persistentId: "PLAYLIST",
            tracks: [
                track(sourceIndex: 0, artist: "Jordan Léser", durationMs: 192000),
                track(sourceIndex: 1, artist: "Jordan Laser", durationMs: 192000),
                track(sourceIndex: 2, artist: "Jordan Léser", durationMs: 192001),
            ]
        )

        #expect(try buildPlan(source).winnerSourceIndexes == [0, 1, 2])
    }

    @Test func preservesNonEligibleTracksAtTheirSourcePosition() throws {
        let source = PlaylistSnapshot(
            name: "Source", persistentId: "PLAYLIST",
            tracks: [
                track(sourceIndex: 0, title: ""),
                track(sourceIndex: 1, persistentId: "LOW", bitRateKbps: 128),
                track(sourceIndex: 2, persistentId: "HIGH", bitRateKbps: 320),
                track(sourceIndex: 3, persistentId: "NO_ARTIST", artist: ""),
            ]
        )

        let plan = try buildPlan(source)

        #expect(plan.winnerSourceIndexes == [0, 2, 3])
        #expect(plan.nonEligibleSourceIndexes == [0, 3])
    }

    @Test func recordsTheFirstDecisiveQualityDifference() throws {
        let winner = track(sourceIndex: 4, persistentId: "WIN", sampleRateHz: 48000)
        let unavailable = track(sourceIndex: 0, persistentId: "UNAVAILABLE", cloudStatus: "no longer available")
        let lowerRate = track(sourceIndex: 2, persistentId: "LOW_RATE", sampleRateHz: 44100)
        let source = PlaylistSnapshot(
            name: "Source", persistentId: "PLAYLIST",
            tracks: [unavailable, lowerRate, winner]
        )

        let reasonPairs = try buildPlan(source).decisions[0].reasonByOmittedIndex
        let reasons = Dictionary(uniqueKeysWithValues: reasonPairs.map { ($0.sourceIndex, $0.reason) })

        #expect(reasons == [0: "available", 2: "sample rate"])
    }

    @Test func prefersLosslessKindBeforeSampleRate() throws {
        let lossless = track(sourceIndex: 2, persistentId: "LOSSLESS", kind: "AIFF audio file", sampleRateHz: 44100)
        let lossy = track(sourceIndex: 0, persistentId: "LOSSY", sampleRateHz: 96000)
        let source = PlaylistSnapshot(name: "Source", persistentId: "PLAYLIST", tracks: [lossy, lossless])

        let decision = try buildPlan(source).decisions[0]

        #expect(decision.winner.persistentId == "LOSSLESS")
        #expect(decision.reasonByOmittedIndex == [.init(sourceIndex: 0, reason: "lossless kind")])
    }

    @Test func prefersHigherBitRateAfterPriorCriteriaTie() throws {
        let lower = track(sourceIndex: 0, persistentId: "LOW", bitRateKbps: 128)
        let higher = track(sourceIndex: 2, persistentId: "HIGH", bitRateKbps: 320)
        let source = PlaylistSnapshot(name: "Source", persistentId: "PLAYLIST", tracks: [lower, higher])

        let decision = try buildPlan(source).decisions[0]

        #expect(decision.winner.persistentId == "HIGH")
        #expect(decision.reasonByOmittedIndex == [.init(sourceIndex: 0, reason: "bit rate")])
    }

    @Test func prefersLowerSourceIndexAfterQualityTies() throws {
        let later = track(sourceIndex: 8, persistentId: "LATER")
        let earlier = track(sourceIndex: 3, persistentId: "EARLIER")
        let source = PlaylistSnapshot(name: "Source", persistentId: "PLAYLIST", tracks: [later, earlier])

        let decision = try buildPlan(source).decisions[0]

        #expect(decision.winner.persistentId == "EARLIER")
        #expect(decision.reasonByOmittedIndex == [.init(sourceIndex: 8, reason: "source order")])
    }

    @Test func prefersPersistentIdAfterSourceOrderTies() throws {
        let laterId = track(sourceIndex: 0, persistentId: "ZZZ")
        let earlierId = track(sourceIndex: 0, persistentId: "AAA")
        let source = PlaylistSnapshot(name: "Source", persistentId: "PLAYLIST", tracks: [laterId, earlierId])

        let decision = try buildPlan(source).decisions[0]

        #expect(decision.winner.persistentId == "AAA")
        #expect(decision.reasonByOmittedIndex == [.init(sourceIndex: 0, reason: "persistent ID")])
    }

    @Test func sourceFingerprintChangesWhenAnyTrackFieldChanges() {
        let originalFingerprint = sourceFingerprint([track()])
        let changed: [TrackSnapshot] = [
            track(sourceIndex: 1),
            track(databaseId: 2),
            track(persistentId: "DEF"),
            track(title: "Changed Title"),
            track(artist: "Changed Artist"),
            track(album: "Changed Album"),
            track(durationMs: nil),
            track(kind: "AIFF audio file"),
            track(bitRateKbps: 320),
            track(sampleRateHz: 48000),
            track(cloudStatus: "No Longer Available"),
            track(isFileTrack: true),
        ]
        for variant in changed {
            #expect(
                sourceFingerprint([variant]) != originalFingerprint,
                "fingerprint must change when a field changes: \(variant)"
            )
        }
    }

    // Binding M1 finding, resolver-level regression: canonically-equivalent
    // but scalar-different normalized titles must stay TWO tracks, exactly as
    // the reference keeps them (verified via python3: winners (0, 1), no
    // decisions, for titles U+0390 and U+03AA U+0301).
    @Test func scalarDifferentCanonicallyEquivalentTitlesStayDistinctThroughBuildPlan() throws {
        let source = PlaylistSnapshot(
            name: "Source", persistentId: "PLAYLIST",
            tracks: [
                track(sourceIndex: 0, persistentId: "P0", title: "\u{0390}"),
                track(sourceIndex: 1, persistentId: "P1", title: "\u{03AA}\u{0301}"),
            ]
        )

        let plan = try buildPlan(source)

        #expect(plan.winnerSourceIndexes == [0, 1])
        #expect(plan.decisions.isEmpty)
        #expect(plan.nonEligibleSourceIndexes.isEmpty)
    }
}

@Suite("Merge resolver — ported cases from tests/test_resolver.py")
struct MergeResolverPortedTests {

    private func copies() -> [PlaylistSnapshot] {
        let copyA = PlaylistSnapshot(
            name: "90s Techno", persistentId: "PID-A",
            tracks: [
                track(sourceIndex: 0, databaseId: 1, persistentId: "LOSSY",
                      title: "Firestarter", artist: "The Prodigy",
                      durationMs: 280000, sampleRateHz: 44100),
                track(sourceIndex: 1, databaseId: 2, persistentId: "ONLY-A",
                      title: "Around the World", artist: "Daft Punk",
                      durationMs: 430000),
            ]
        )
        let copyB = PlaylistSnapshot(
            name: "90s Techno", persistentId: "PID-B",
            tracks: [
                track(sourceIndex: 0, databaseId: 3, persistentId: "LOSSLESS",
                      title: "Firestarter", artist: "The Prodigy",
                      durationMs: 280000, kind: "AIFF audio file",
                      sampleRateHz: 96000),
                track(sourceIndex: 1, databaseId: 4, persistentId: "ONLY-B",
                      title: "Enjoy the Silence", artist: "Depeche Mode",
                      durationMs: 370000),
            ]
        )
        return [copyA, copyB]
    }

    @Test func crossCopyDuplicateKeepsTheHigherQualityLaterOccurrence() throws {
        let plan = try buildMergePlan(name: "90s Techno", copies: copies())
        let combined = plan.combinedTracks
        let winners = plan.winnerSourceIndexes.map { combined[$0].persistentId }

        #expect(winners == ["LOSSLESS", "ONLY-A", "ONLY-B"])
        #expect(plan.mergedPlaylistSourceName == "90s Techno")
    }

    @Test func buildMergePlanMatchesBuildPlanOverTheHandCombinedSnapshot() throws {
        let sourceCopies = copies()
        let plan = try buildMergePlan(name: "90s Techno", copies: sourceCopies)
        let combined = PlaylistSnapshot(
            name: "90s Techno", persistentId: "",
            tracks: combineSourceTracks(sourceCopies)
        )
        let expected = try buildPlan(combined)

        #expect(plan.winnerSourceIndexes == expected.winnerSourceIndexes)
        #expect(plan.decisions == expected.decisions)
        #expect(plan.nonEligibleSourceIndexes == expected.nonEligibleSourceIndexes)
    }

    @Test func handlesThreeCopies() throws {
        let allCopies = copies() + [
            PlaylistSnapshot(
                name: "90s Techno", persistentId: "PID-C",
                tracks: [track(sourceIndex: 0, databaseId: 5, persistentId: "ONLY-C",
                               title: "Sandstorm", artist: "Darude", durationMs: 350000)]
            )
        ]
        let plan = try buildMergePlan(name: "90s Techno", copies: allCopies)

        #expect(plan.combinedTrackCount == 5)
        #expect(plan.copyBoundaries == [2, 4, 5])
    }

    @Test func fingerprintChangesWhenAnyCopyFieldChanges() {
        let sourceCopies = copies()
        let base = mergeFingerprint(sourceCopies)

        var renamedCopy = sourceCopies[0]
        renamedCopy.persistentId = "PID-A2"
        #expect(mergeFingerprint([renamedCopy, sourceCopies[1]]) != base)

        var retitledCopy = sourceCopies[0]
        retitledCopy.tracks[0].title = "X"
        #expect(mergeFingerprint([retitledCopy, sourceCopies[1]]) != base)
    }
}
