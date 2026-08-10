// AuditQueueCountsTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Wave A (A5) — AuditQueueItem.copyCounts: captured from the scan-time
// listing when the queue is built (per-copy for merge groups in ascending
// playlist-id order, a single count for consolidate items), refreshed with
// the audit's live per-copy counts when the item's audit completes, and
// NEVER written back into the cached listing or the browser listing state
// (count divergence is display-only, spec A5). All Music I/O is scripted
// through fakes; nothing executes any script.

import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

// MARK: - listing wire fixtures with STALE counts
// The scan-time counts here deliberately differ from the audit fixtures'
// live counts (mergeFixtureWire: 2 tracks per copy; consolidateFixtureWire:
// 4 tracks) so the refresh is observable.

private func countsListingEntryWire(
    id: Int, name: String, pid: String, trackCount: Int
) -> String {
    """
    {"id": \(id), "name": "\(jsonEscaped(name))", "persistent_id": "\(jsonEscaped(pid))", \
    "track_count": \(trackCount), "smart": false, "special_kind": "none"}
    """
}

private func countsListingWire(_ entries: [String]) -> String {
    "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

/// Two mergeable groups, entries listed OUT of playlist-id order so the
/// capture assertion proves the ascending-id (concatenation) copy order.
private func staleMergeListingWire() -> String {
    countsListingWire([
        countsListingEntryWire(id: 60, name: "Argentos", pid: "A-HIGH", trackCount: 4),
        countsListingEntryWire(id: 50, name: "Argentos", pid: "A-LOW", trackCount: 3),
        countsListingEntryWire(id: 20, name: "Merge List", pid: "C-HIGH", trackCount: 6),
        countsListingEntryWire(id: 10, name: "Merge List", pid: "C-LOW", trackCount: 5),
    ])
}

/// One consolidatable singleton with a stale count of 9 (live audit: 4).
private func staleConsolidateListingWire() -> String {
    countsListingWire([
        countsListingEntryWire(id: 30, name: "Fixture List", pid: "P-FIX", trackCount: 9)
    ])
}

@MainActor
@Suite("Audit queue copy counts (A5)")
struct AuditQueueCountsTests {

    @Test("merge items capture per-copy listing counts ascending by playlist id, then refresh to the audit's live counts")
    func mergeCaptureAndRefresh() async throws {
        let runner = ScriptedRunner(outputs: [
            staleMergeListingWire(),
            mergeFixtureWire(name: "Argentos"),
        ])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value

        harness.model.toggleCheckedGroup(name: "Argentos")
        harness.model.toggleCheckedGroup(name: "Merge List")
        harness.model.startQueue()

        // Capture (asserted synchronously right after startQueue, before
        // the item-1 audit lands): scan-time counts, per copy, ascending
        // playlist id — Argentos [3, 4], Merge List [5, 6].
        #expect(harness.model.queue.map(\.name) == ["Argentos", "Merge List"])
        #expect(harness.model.queue.map(\.copyCounts) == [[3, 4], [5, 6]])

        await harness.awaitAudit()

        // Refresh: item 1's counts become the audit's LIVE per-copy counts
        // (mergeFixtureWire has 2 tracks per copy). The still-pending item
        // keeps its scan-time capture.
        #expect(harness.model.queue.map(\.status) == [.audited, .pending])
        #expect(harness.model.queue.map(\.copyCounts) == [[2, 2], [5, 6]])
    }

    @Test("a consolidate item captures the single listing count and refreshes to the live source count")
    func consolidateCaptureAndRefresh() async throws {
        let runner = ScriptedRunner(outputs: [
            staleConsolidateListingWire(),
            consolidateFixtureWire(),
        ])
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value

        harness.model.toggleChecked(persistentId: "P-FIX")
        harness.model.startQueue()
        #expect(harness.model.queue.map(\.copyCounts) == [[9]])

        await harness.awaitAudit()
        #expect(harness.model.queue.map(\.status) == [.audited])
        // consolidateFixtureWire's live source has 4 tracks (including the
        // non-eligible one — the plan's sourceTrackCount).
        #expect(harness.model.queue.map(\.copyCounts) == [[4]])
    }

    @Test("the refresh never mutates the cached listing or the browser listing state")
    func refreshNeverMutatesListing() async throws {
        let runner = ScriptedRunner(outputs: [
            staleMergeListingWire(),
            mergeFixtureWire(name: "Argentos"),
        ])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value

        harness.model.toggleCheckedGroup(name: "Argentos")
        harness.model.startQueue()
        await harness.awaitAudit()
        // Precondition: the refresh happened on the queue item.
        #expect(harness.model.queue.map(\.copyCounts) == [[2, 2]])

        // Browser listing state: STILL the scan-time counts.
        let sections = try #require(harness.model.loadedSections)
        let group = try #require(sections.groups.first { $0.name == "Argentos" })
        #expect(group.copies.map(\.trackCount) == [3, 4])

        // Persisted listing cache on disk: STILL the scan-time counts (the
        // cache file name matches AuditFlowModel.listingCacheURL).
        let cacheURL = harness.cacheDirectory.appendingPathComponent("listing-cache.json")
        let cache = try #require(loadListingCache(at: cacheURL))
        let cachedCounts = cache.entries
            .filter { $0.name == "Argentos" }
            .sorted { $0.playlistId < $1.playlistId }
            .map(\.trackCount)
        #expect(cachedCounts == [3, 4])
    }
}
