// CleanupTestSupport.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Shared fixtures for the B3 cleanup scanner suites: a temp reports/
// directory harness that writes REAL merge-plan artifacts through
// writeMergeAudit (so loadMergePlan's integrity gate passes), plus builders
// for live-snapshot and listing fakes. No script is ever executed and Music
// is never contacted: the scanner's live closures are injected per test.

import Foundation
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

/// Temp reports/ directory plus scanner construction with injectable fakes.
@MainActor
struct CleanupFixture {
    let reportsDir: URL

    init() throws {
        reportsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: reportsDir)
    }

    func scanner(
        listPlaylists: @escaping () throws -> [PlaylistListing] = { [] }
    ) -> CleanupScanner {
        CleanupScanner(
            reportsDir: reportsDir,
            listPlaylists: listPlaylists
        )
    }

    /// Write a REAL artifact triple via writeMergeAudit at a pinned instant
    /// (UTC so the basename stamp is deterministic); return the plan basename.
    @discardableResult
    func writePlan(_ plan: MergePlan, at date: Date) throws -> String {
        let paths = try writeMergeAudit(
            outputDir: reportsDir,
            plan: plan,
            now: { date },
            timeZone: TimeZone(identifier: "UTC")!
        )
        return artifactBasename(paths.planJson)
    }

    func writeText(_ text: String, fileName: String) throws {
        try Data(text.utf8).write(to: reportsDir.appendingPathComponent(fileName))
    }
}

/// Two same-name copies with disjoint, all-distinct tracks (no duplicate
/// decisions): winners == the combined order [T0000001, T0000002, T0000003].
func cleanupFixtureCopies(name: String = "Trance 2022") -> [PlaylistSnapshot] {
    [
        PlaylistSnapshot(
            name: name,
            persistentId: "CPYAAAA000000001",
            tracks: [
                presentationTrack(
                    sourceIndex: 0, databaseId: 1, persistentId: "T0000001", title: "Alpha"
                ),
                presentationTrack(
                    sourceIndex: 1, databaseId: 2, persistentId: "T0000002", title: "Beta"
                ),
            ]
        ),
        PlaylistSnapshot(
            name: name,
            persistentId: "CPYBBBB000000002",
            tracks: [
                presentationTrack(
                    sourceIndex: 0, databaseId: 3, persistentId: "T0000003", title: "Gamma"
                ),
            ]
        ),
    ]
}

/// A live merged-target snapshot whose ordered database IDs + persistent IDs
/// match the plan winners exactly (verifyMergeOutput's trust standard).
func verifiedCleanupTarget(for plan: MergePlan, name: String) -> PlaylistSnapshot {
    let combined = plan.combinedTracks
    let winners = plan.winnerSourceIndexes.map { combined[$0] }
    return PlaylistSnapshot(name: name, persistentId: "TARGET0000000001", tracks: winners)
}

/// A plain user-playlist listing row for one snapshot.
func cleanupLiveListing(_ snapshot: PlaylistSnapshot, id: Double) -> PlaylistListing {
    PlaylistListing(
        playlistId: id,
        name: snapshot.name,
        persistentId: snapshot.persistentId,
        trackCount: snapshot.tracks.count,
        isSmart: false,
        specialKind: "none"
    )
}
