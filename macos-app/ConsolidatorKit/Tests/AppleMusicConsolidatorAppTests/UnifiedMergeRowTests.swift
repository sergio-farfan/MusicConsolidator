// UnifiedMergeRowTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// 2026-08-11 unified merge list, Task 1 — the pure row builder (`mergeRows`)
// that interleaves same-name groups and singletons into ONE alphabetical
// ALL PLAYLISTS checklist (mirrors `cleanupRows`' shape: pure, display-only,
// needle-filtered, sortable), plus the selection plumbing it feeds:
// `selectAllEligible`'s merge branch now also checks eligible singletons
// (skipping already-processed sources of either kind), and
// `mergeSelectedSourceCount` reports the total SOURCE playlist count (group
// copies + singletons) the unified footer needs. Offline only — no Music.
//
// Task 2 additions (view recomposition over Task 1's rows): the pure
// `mergeSingletonRowSelection` routing test (a near-match twin row selects
// its CLUSTER, keeping the inspector's rename hint + Align names… reachable
// without a standalone NEAR MATCHES row — combines with
// BrowserMutationStructuralTests' unchanged `.nearMatch` inspector pin to
// prove the whole path), plus the spec's structural list: unified-list
// anatomy at 900x620, the footer's enable matrix, and Select all driving
// both selection sets through the real `SourceSelectionView` composition.

import AppKit
import Foundation
import SwiftUI
import Testing
import ConsolidatorCore
@testable import AppleMusicConsolidatorApp

// MARK: - listing fixtures (pure `mergeRows` tests)

private func rowListing(
    id: Double, name: String, pid: String, count: Int = 5
) -> PlaylistListing {
    PlaylistListing(
        playlistId: id, name: name, persistentId: pid,
        trackCount: count, isSmart: false, specialKind: "none"
    )
}

@Suite("mergeRows (pure, display-only)")
struct MergeRowsTests {

    @Test("groups and singletons interleave in one alphabetical order")
    func interleaveOrder() {
        // "M-Group" must land BETWEEN the two singletons alphabetically —
        // proving the interleave is a real merge, not groups-then-singletons.
        let sections = buildPlaylistBrowseSections(from: [
            rowListing(id: 20, name: "M-Group", pid: "M-1"),
            rowListing(id: 21, name: "M-Group", pid: "M-2"),
            rowListing(id: 10, name: "L-Solo", pid: "L-1"),
            rowListing(id: 40, name: "N-Solo", pid: "N-1"),
        ])

        let rows = mergeRows(sections: sections, needle: "", key: .name, ascending: true)
        #expect(rows.map(\.id) == ["L-1", "M-Group", "N-1"])
        guard case .group(let group, _) = rows[1] else {
            Issue.record("expected the middle row to be the M-Group group row")
            return
        }
        #expect(group.copies.map(\.persistentId) == ["M-1", "M-2"])

        // Descending is the exact reversal (applyBrowserSort's `.name`
        // contract over pre-sorted input, reused here).
        let descending = mergeRows(sections: sections, needle: "", key: .name, ascending: false)
        #expect(descending.map(\.id) == ["N-1", "M-Group", "L-1"])
    }

    @Test("needle filters both row kinds by a case-insensitive name substring")
    func needleFiltering() {
        let sections = buildPlaylistBrowseSections(from: [
            rowListing(id: 10, name: "Trance 2022", pid: "T-1"),
            rowListing(id: 11, name: "Trance 2022", pid: "T-2"),
            rowListing(id: 20, name: "Trance Extras", pid: "E-1"),
            rowListing(id: 30, name: "House Anthems", pid: "H-1"),
        ])

        let rows = mergeRows(sections: sections, needle: "trance", key: .name, ascending: true)
        #expect(rows.map(\.id) == ["Trance 2022", "E-1"])
    }

    @Test("a near-match singleton carries the OTHER variant's name as its twin; a plain singleton carries nil")
    func nearMatchTwin() {
        let sections = buildPlaylistBrowseSections(from: [
            rowListing(id: 10, name: "Kdrama", pid: "K-A"),
            rowListing(id: 20, name: "Kdrama ", pid: "K-B"),
            rowListing(id: 30, name: "Foxtrot", pid: "F-1"),
        ])
        #expect(sections.nearMatches.map(\.normalizedName) == ["Kdrama"])
        let rows = mergeRows(sections: sections, needle: "", key: .name, ascending: true)

        func singletonRow(id: String) -> MergeBrowserRow? {
            rows.first { $0.id == id }
        }

        if case .singleton(_, let twin) = singletonRow(id: "K-A") {
            #expect(twin == "Kdrama ")
        } else {
            Issue.record("expected K-A to be a singleton row")
        }
        if case .singleton(_, let twin) = singletonRow(id: "K-B") {
            #expect(twin == "Kdrama")
        } else {
            Issue.record("expected K-B to be a singleton row")
        }
        if case .singleton(_, let twin) = singletonRow(id: "F-1") {
            #expect(twin == nil, "a singleton outside every near-match cluster has no twin")
        } else {
            Issue.record("expected F-1 to be a singleton row")
        }
    }

    // Finding I2: near-match clusters bucket exact-name CLASSES, and a class
    // with >= 2 copies is a GROUP — so an all-group cluster exists, and its
    // rows carried no twin (hence no badge, and no route to the near-match
    // inspector's rename hint / Align names…) until the group case gained
    // `nearMatchTwin`.
    @Test("an ALL-GROUP near-match cluster puts the twin on both GROUP rows")
    func nearMatchTwinOnGroupRows() {
        let sections = buildPlaylistBrowseSections(from: [
            rowListing(id: 10, name: "Trance 2022", pid: "T-A"),
            rowListing(id: 11, name: "Trance 2022", pid: "T-B"),
            rowListing(id: 20, name: "Trance 2022 ", pid: "T-C"),
            rowListing(id: 21, name: "Trance 2022 ", pid: "T-D"),
            rowListing(id: 30, name: "Foxtrot", pid: "F-1"),
        ])
        #expect(sections.singletons.map(\.persistentId) == ["F-1"], "both variants are GROUPS here")
        #expect(sections.nearMatches.map(\.normalizedName) == ["Trance 2022"])

        let rows = mergeRows(sections: sections, needle: "", key: .name, ascending: true)
        guard let plainRow = rows.first(where: { $0.id == "Trance 2022" }),
              case .group(let plain, let plainTwin) = plainRow else {
            Issue.record("expected a group row for \u{201C}Trance 2022\u{201D}")
            return
        }
        #expect(plain.copies.map(\.persistentId) == ["T-A", "T-B"])
        #expect(plainTwin == "Trance 2022 ")
        guard let spacedRow = rows.first(where: { $0.id == "Trance 2022 " }),
              case .group(_, let spacedTwin) = spacedRow else {
            Issue.record("expected a group row for the trailing-space twin")
            return
        }
        #expect(spacedTwin == "Trance 2022")
        // A group outside every cluster still carries nil, and the row's
        // kind-agnostic accessor agrees with the payload.
        #expect(rows.first { $0.id == "F-1" }?.nearMatchTwin == nil)
        #expect(rows.first { $0.id == "Trance 2022" }?.nearMatchTwin == "Trance 2022 ")
    }

    // Final review minor (b): the header counts SOURCE playlists — group
    // copies plus singletons — the same noun as the footer and as the
    // consolidate tab's own header, not rows.
    @Test("the header count is the row set's SOURCE playlist count, not its row count")
    func headerCountsSourcePlaylists() {
        let sections = buildPlaylistBrowseSections(from: [
            rowListing(id: 10, name: "Trance 2022", pid: "T-LOW"),
            rowListing(id: 20, name: "Trance 2022", pid: "T-HIGH"),
            rowListing(id: 30, name: "Solo List", pid: "S-SOLO"),
        ])
        let rows = mergeRows(sections: sections, needle: "", key: .name, ascending: true)
        #expect(rows.count == 2, "one group row plus one singleton row")
        #expect(mergeSourceCount(rows: rows) == 3, "2 group copies + 1 singleton")
        #expect(
            MergeSurfaceCopy.allPlaylistsHeader(sourceCount: mergeSourceCount(rows: rows))
                == "ALL PLAYLISTS (3)"
        )
    }

    @Test("count-sort uses a group's SUMMED copy counts, not its number of copies")
    func countSortUsesSummedCopies() {
        // Alpha's summed copies (5 + 6 = 11) exceed Beta's single count (8);
        // a copy-COUNT bug (2) would sort Alpha first ascending instead.
        let sections = buildPlaylistBrowseSections(from: [
            rowListing(id: 10, name: "Alpha", pid: "A-1", count: 5),
            rowListing(id: 11, name: "Alpha", pid: "A-2", count: 6),
            rowListing(id: 20, name: "Beta", pid: "B-1", count: 8),
        ])

        let ascending = mergeRows(sections: sections, needle: "", key: .count, ascending: true)
        #expect(ascending.map(\.id) == ["B-1", "Alpha"])
        let descending = mergeRows(sections: sections, needle: "", key: .count, ascending: false)
        #expect(descending.map(\.id) == ["Alpha", "B-1"])
    }
}

// MARK: - model plumbing fixtures (selectAllEligible + mergeSelectedSourceCount)

private func plumbingEntry(id: Int, name: String, pid: String, count: Int) -> String {
    """
    {"id": \(id), "name": "\(jsonEscaped(name))", "persistent_id": "\(jsonEscaped(pid))", \
    "track_count": \(count), "smart": false, "special_kind": "none"}
    """
}

private func plumbingListingWire(_ entries: [String]) -> String {
    "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

/// One already-processed group (Alpha, target "Alpha \u{2014} Merged"
/// already exists), one already-processed singleton (Beta, target
/// "Beta \u{2014} Merged" already exists), and one plain unprocessed
/// singleton (Gamma) — exercises the already-processed skip for BOTH row
/// kinds in a single fixture. The two "\u{2014} Merged" listings are
/// themselves eligible singletons (their own targets do not exist).
private func selectAllPlumbingListingWire() -> String {
    plumbingListingWire([
        plumbingEntry(id: 10, name: "Alpha", pid: "A-1", count: 3),
        plumbingEntry(id: 11, name: "Alpha", pid: "A-2", count: 4),
        plumbingEntry(id: 12, name: "Alpha \u{2014} Merged", pid: "A-DONE", count: 7),
        plumbingEntry(id: 20, name: "Beta", pid: "B-SRC", count: 2),
        plumbingEntry(id: 21, name: "Beta \u{2014} Merged", pid: "B-DONE", count: 2),
        plumbingEntry(id: 30, name: "Gamma", pid: "G-1", count: 5),
    ])
}

@MainActor
@Suite("selectAllEligible merge branch gains singletons (2026-08-11)")
struct SelectAllEligibleMergeSingletonsTests {

    @Test("select-all checks every eligible group AND singleton, skipping already-processed sources of both kinds")
    func selectsGroupsAndSingletonsSkippingProcessed() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: [selectAllPlumbingListingWire()]),
            mode: .merge, playlistName: ""
        )
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        // Alpha's target already exists: the group itself is skipped.
        #expect(model.isAlreadyProcessed(name: "Alpha"))
        // Beta's target already exists: the singleton itself is skipped.
        #expect(model.isAlreadyProcessed(name: "Beta"))

        model.selectAllEligible()

        #expect(model.checkedGroupNames.isEmpty, "Alpha is already processed")
        #expect(
            model.checkedFreeFormSingletonPersistentIds
                == Set(["A-DONE", "B-DONE", "G-1"])
        )
        #expect(!model.checkedFreeFormSingletonPersistentIds.contains("B-SRC"),
                 "Beta is already processed")
        // The consolidate tab's own selection set is untouched.
        #expect(model.checkedPersistentIds.isEmpty)
    }
}

/// One 2-copy group ("Trance 2022") plus one singleton ("Solo List") — the
/// spec's own footer example.
private func sourceCountListingWire() -> String {
    plumbingListingWire([
        plumbingEntry(id: 10, name: "Trance 2022", pid: "T-LOW", count: 3),
        plumbingEntry(id: 20, name: "Trance 2022", pid: "T-HIGH", count: 4),
        plumbingEntry(id: 5, name: "Solo List", pid: "S-SOLO", count: 2),
    ])
}

@MainActor
@Suite("mergeSelectedSourceCount (unified footer's total source count)")
struct MergeSelectedSourceCountTests {

    @Test("2-copy group + 1 singleton = 3 total source playlists")
    func footerArithmetic() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: [sourceCountListingWire()]),
            mode: .merge, playlistName: ""
        )
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value
        #expect(model.mergeSelectedSourceCount == 0)

        model.toggleCheckedGroup(name: "Trance 2022")
        #expect(model.mergeSelectedSourceCount == 2, "the group alone contributes both its copies")

        model.toggleCheckedFreeFormSingleton(persistentId: "S-SOLO")
        #expect(model.mergeSelectedSourceCount == 3)

        model.clearSelection()
        #expect(model.mergeSelectedSourceCount == 0)
    }
}

// MARK: - mergeSingletonRowSelection (pure, display-only; Task 2)

/// The row-tap selection routing a near-match twin's row now uses instead of
/// a standalone NEAR MATCHES cluster row. `BrowserMutationStructuralTests`
/// (unchanged) already pins that a `.nearMatch(name)` selection renders the
/// inspector's rename hint and the Align names… entry point; this suite
/// pins the OTHER half of that path — that the twin's own row targets
/// exactly that selection — closing the loop without needing to simulate a
/// tap on a plain (non-NSButton) SwiftUI row offscreen.
@Suite("mergeSingletonRowSelection (pure, display-only)")
struct MergeSingletonRowSelectionTests {

    @Test("a near-match twin's row selects its CLUSTER, not itself")
    func nearMatchTwinSelectsCluster() throws {
        let sections = buildPlaylistBrowseSections(from: [
            rowListing(id: 10, name: "Kdrama", pid: "K-A"),
            rowListing(id: 20, name: "Kdrama ", pid: "K-B"),
            rowListing(id: 30, name: "Foxtrot", pid: "F-1"),
        ])
        let kdramaA = try #require(sections.singletons.first { $0.persistentId == "K-A" })
        #expect(
            mergeSingletonRowSelection(for: kdramaA, nearMatchTwin: "Kdrama ", in: sections)
                == .nearMatch("Kdrama")
        )
        let kdramaB = try #require(sections.singletons.first { $0.persistentId == "K-B" })
        #expect(
            mergeSingletonRowSelection(for: kdramaB, nearMatchTwin: "Kdrama", in: sections)
                == .nearMatch("Kdrama"),
            "either twin's row resolves to the SAME cluster selection"
        )
    }

    @Test("a plain singleton (no twin) selects itself")
    func plainSingletonSelectsItself() throws {
        let sections = buildPlaylistBrowseSections(from: [
            rowListing(id: 30, name: "Foxtrot", pid: "F-1"),
        ])
        let foxtrot = try #require(sections.singletons.first { $0.persistentId == "F-1" })
        #expect(
            mergeSingletonRowSelection(for: foxtrot, nearMatchTwin: nil, in: sections)
                == .singleton("F-1")
        )
    }
}

// MARK: - mergeGroupRowSelection (pure, display-only; finding I2)

/// A 2-copy group vs its trailing-space 2-copy twin plus one plain group —
/// the ALL-GROUP near-match cluster the singleton-only routing could not
/// reach.
private func allGroupClusterSections() -> PlaylistBrowseSections {
    buildPlaylistBrowseSections(from: [
        rowListing(id: 10, name: "Trance 2022", pid: "T-A"),
        rowListing(id: 11, name: "Trance 2022", pid: "T-B"),
        rowListing(id: 20, name: "Trance 2022 ", pid: "T-C"),
        rowListing(id: 21, name: "Trance 2022 ", pid: "T-D"),
        rowListing(id: 30, name: "House Anthems", pid: "H-1"),
        rowListing(id: 31, name: "House Anthems", pid: "H-2"),
    ])
}

@Suite("mergeGroupRowSelection (pure, display-only)")
struct MergeGroupRowSelectionTests {

    @Test("a badged GROUP row selects its CLUSTER, not itself")
    func badgedGroupSelectsCluster() throws {
        let sections = allGroupClusterSections()
        let plain = try #require(sections.groups.first { $0.name == "Trance 2022" })
        #expect(
            mergeGroupRowSelection(for: plain, nearMatchTwin: "Trance 2022 ", in: sections)
                == .nearMatch("Trance 2022")
        )
        let spaced = try #require(sections.groups.first { scalarExact($0.name, "Trance 2022 ") })
        #expect(
            mergeGroupRowSelection(for: spaced, nearMatchTwin: "Trance 2022", in: sections)
                == .nearMatch("Trance 2022"),
            "either twin group's row resolves to the SAME cluster selection"
        )
    }

    @Test("an unbadged GROUP row still selects the group")
    func unbadgedGroupSelectsGroup() throws {
        let sections = allGroupClusterSections()
        let house = try #require(sections.groups.first { $0.name == "House Anthems" })
        #expect(
            mergeGroupRowSelection(for: house, nearMatchTwin: nil, in: sections)
                == .group("House Anthems")
        )
    }
}

// MARK: - unified merge surface copy (final review minor d)

/// The verbatim footer/caption strings of the unified merge surface. Pinning
/// them here is the point of `MergeSurfaceCopy`: several are quoted verbatim
/// in the 2026-08-11 spec and in `docs/apple-music-consolidator.md`, and the
/// singleton advisory was WRONG for one whole release (it told Sergio to
/// delete a playlist to reuse a row that never needed it — finding C1), which
/// no test would have caught.
@Suite("Unified merge surface copy (verbatim)")
struct MergeSurfaceCopyTests {

    @Test("every footer/caption string is exactly as designed")
    func copyIsPinned() {
        #expect(MergeSurfaceCopy.allPlaylistsHeader(sourceCount: 333) == "ALL PLAYLISTS (333)")
        #expect(MergeSurfaceCopy.selectedSources(count: 3) == "Selected: 3 playlists")
        #expect(MergeSurfaceCopy.mergeAsOneTitle == "Merge selected as one\u{2026}")
        #expect(
            MergeSurfaceCopy.mergeAsOneHelp
                == "Combine every checked group and singleton into ONE new playlist, "
                    + "named \u{201C}<first source> \u{2014} Merged\u{201D}."
        )
        #expect(MergeSurfaceCopy.mergeEachGroupTitle == "Merge each group separately")
        #expect(
            MergeSurfaceCopy.mergeEachGroupHelp
                == "Runs one merge per checked group. Uncheck singletons to use this, "
                    + "or use Merge selected as one."
        )
        #expect(
            MergeSurfaceCopy.nearMatchChipHelp(twin: "Kdrama ")
                == "Near match: differs from \u{201C}Kdrama \u{201D} only by invisible "
                    + "characters or edge whitespace \u{2014} select the row for the "
                    + "rename hint."
        )
        // Finding C1: informational, NOT imperative — nothing has to be
        // deleted for this row to serve as a free-form merge source again.
        #expect(
            MergeSurfaceCopy.alreadyMergedSingletonAdvisory(sourceName: "Beta")
                == "A \u{201C}Beta \u{2014} Merged\u{201D} playlist exists \u{2014} "
                    + "created by an earlier merge."
        )
        // A GROUP's own merge target IS "<name> — Merged", so that one keeps
        // the imperative wording it always had.
        #expect(
            MergeSurfaceCopy.alreadyMergedGroupHelp(sourceName: "Alpha")
                == "Already merged: \u{201C}Alpha \u{2014} Merged\u{201D} exists. Review "
                    + "it, then clean up the sources; delete it first to reprocess."
        )
    }
}

// MARK: - unified list structural pins (Task 2, spec Testing list)

/// One 2-copy group ("Trance 2022") plus TWO singletons ("Alpha", "Beta") —
/// enough to drive every cell of the footer's enable matrix: a 2-copy group
/// alone, or two singletons alone, each clear the free-form ">= 2 source
/// playlists" threshold on their own.
private func unifiedFooterMatrixListingWire() -> String {
    plumbingListingWire([
        plumbingEntry(id: 10, name: "Trance 2022", pid: "T-LOW", count: 3),
        plumbingEntry(id: 20, name: "Trance 2022", pid: "T-HIGH", count: 4),
        plumbingEntry(id: 30, name: "Alpha", pid: "FM-A", count: 1),
        plumbingEntry(id: 40, name: "Beta", pid: "FM-B", count: 1),
    ])
}

@MainActor
private func loadedUnifiedMergeHarness(wire: String = unifiedFooterMatrixListingWire()) async throws -> ModelHarness {
    let harness = try ModelHarness(
        runner: ScriptedRunner(outputs: [wire]), mode: .merge, playlistName: ""
    )
    harness.model.rescanLibrary()
    await harness.model.scanTask?.value
    return harness
}

@MainActor
@Suite("Unified merge list — anatomy structural pin (2026-08-11)", .serialized)
struct UnifiedMergeListAnatomyStructuralTests {

    @Test("at 900x620 the group row's and a singleton row's checkboxes are contained and live")
    func anatomyAt900x620() async throws {
        let harness = try await loadedUnifiedMergeHarness(wire: sourceCountListingWire())
        defer { harness.cleanUp() }

        let fixture = HostedFixture(
            SourceSelectionView(model: harness.model), width: 900, height: 620
        )
        defer { fixture.tearDown() }
        let windowBox = NSRect(x: 0, y: 0, width: 900, height: 620)

        // One list, one header — no MERGEABLE GROUPS/NEAR MATCHES/SINGLETONS
        // sections survive.
        #expect(listHeaderCount(under: fixture.hosting) == 1)

        let groupCheckbox = try #require(
            view(under: fixture.hosting, axIdentifier: M10ControlID.groupCheckbox("Trance 2022"))
                as? NSButton
        )
        #expect(groupCheckbox.isEnabled)
        let groupFrame = groupCheckbox.convert(groupCheckbox.bounds, to: fixture.hosting)
        #expect(windowBox.contains(groupFrame), "group checkbox at \(groupFrame)")

        let singletonCheckbox = try #require(
            view(under: fixture.hosting, axIdentifier: M10ControlID.singletonCheckbox("S-SOLO"))
                as? NSButton
        )
        #expect(singletonCheckbox.isEnabled)
        let singletonFrame = singletonCheckbox.convert(singletonCheckbox.bounds, to: fixture.hosting)
        #expect(windowBox.contains(singletonFrame), "singleton checkbox at \(singletonFrame)")
    }
}

@MainActor
@Suite("Unified merge footer — enable matrix (2026-08-11)", .serialized)
struct UnifiedMergeFooterEnableMatrixTests {

    private func footerButtons(
        _ harness: ModelHarness
    ) throws -> (mergeEachGroup: NSButton, mergeAsOne: NSButton, fixture: HostedFixture<SourceSelectionView>) {
        let fixture = HostedFixture(
            SourceSelectionView(model: harness.model), width: 1200, height: 800
        )
        let mergeEachGroup = try #require(
            view(under: fixture.hosting, axIdentifier: M8ControlID.startQueue) as? NSButton
        )
        let mergeAsOne = try #require(
            view(under: fixture.hosting, axIdentifier: M10ControlID.mergeAsOne) as? NSButton
        )
        return (mergeEachGroup, mergeAsOne, fixture)
    }

    @Test("groups-only selection: both actions enabled")
    func groupsOnly() async throws {
        let harness = try await loadedUnifiedMergeHarness()
        defer { harness.cleanUp() }
        harness.model.toggleCheckedGroup(name: "Trance 2022")
        let (mergeEachGroup, mergeAsOne, fixture) = try footerButtons(harness)
        defer { fixture.tearDown() }
        #expect(mergeEachGroup.isEnabled)
        #expect(mergeAsOne.isEnabled)
    }

    @Test("mixed selection (a group plus a singleton): only Merge selected as one enables")
    func mixed() async throws {
        let harness = try await loadedUnifiedMergeHarness()
        defer { harness.cleanUp() }
        harness.model.toggleCheckedGroup(name: "Trance 2022")
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FM-A")
        let (mergeEachGroup, mergeAsOne, fixture) = try footerButtons(harness)
        defer { fixture.tearDown() }
        #expect(!mergeEachGroup.isEnabled, "a checked singleton disables the groups-only action")
        #expect(mergeAsOne.isEnabled)
    }

    @Test("singletons-only selection: only Merge selected as one enables")
    func singletonsOnly() async throws {
        let harness = try await loadedUnifiedMergeHarness()
        defer { harness.cleanUp() }
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FM-A")
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FM-B")
        let (mergeEachGroup, mergeAsOne, fixture) = try footerButtons(harness)
        defer { fixture.tearDown() }
        #expect(!mergeEachGroup.isEnabled, "no group is checked")
        #expect(mergeAsOne.isEnabled)
    }

    @Test("empty selection: both actions disabled")
    func empty() async throws {
        let harness = try await loadedUnifiedMergeHarness()
        defer { harness.cleanUp() }
        let (mergeEachGroup, mergeAsOne, fixture) = try footerButtons(harness)
        defer { fixture.tearDown() }
        #expect(!mergeEachGroup.isEnabled)
        #expect(!mergeAsOne.isEnabled)
    }

    /// Final review minor (a): Return drives the action that accepts ANY
    /// selection ("Merge selected as one…", the de facto primary), not the
    /// groups-only one it was pinned to.
    @Test("Return (the prominent key equivalent) belongs to Merge selected as one")
    func returnDrivesMergeAsOne() async throws {
        let harness = try await loadedUnifiedMergeHarness()
        defer { harness.cleanUp() }
        harness.model.toggleCheckedGroup(name: "Trance 2022")
        let (mergeEachGroup, mergeAsOne, fixture) = try footerButtons(harness)
        defer { fixture.tearDown() }
        #expect(mergeAsOne.keyEquivalent == "\r")
        #expect(
            mergeEachGroup.keyEquivalent.isEmpty,
            "the groups-only action must not answer Return"
        )
    }
}

@MainActor
@Suite("Unified merge list — already-merged singletons stay usable (C1)", .serialized)
struct AlreadyMergedSingletonUsableTests {

    /// Finding C1: an "<own name> — Merged" sibling disabled the singleton's
    /// checkbox by false analogy with group rows. A singleton's checkbox
    /// contributes a SOURCE to "Merge selected as one…", whose target is named
    /// after the FIRST source in playlist-ID order — so that sibling is not a
    /// target collision, and disabling the row permanently poisoned every
    /// free-form merge's first source for all future merges.
    @Test("an already-processed singleton's checkbox is ENABLED and toggles the free-form set")
    func alreadyProcessedSingletonStaysCheckable() async throws {
        let harness = try await loadedUnifiedMergeHarness(wire: selectAllPlumbingListingWire())
        defer { harness.cleanUp() }
        let model = harness.model
        #expect(model.isAlreadyProcessed(name: "Beta"), "\u{201C}Beta \u{2014} Merged\u{201D} exists")

        let fixture = HostedFixture(
            SourceSelectionView(model: model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }

        let singletonCheckbox = try #require(
            view(under: fixture.hosting, axIdentifier: M10ControlID.singletonCheckbox("B-SRC"))
                as? NSButton
        )
        #expect(singletonCheckbox.isEnabled)
        singletonCheckbox.performClick(nil)
        #expect(model.checkedFreeFormSingletonPersistentIds == Set(["B-SRC"]))
        singletonCheckbox.performClick(nil)
        #expect(model.checkedFreeFormSingletonPersistentIds.isEmpty)

        // The GROUP row's checkbox keeps its disable: a group's per-group
        // merge target IS "<name> — Merged", so an existing one blocks it.
        let groupCheckbox = try #require(
            view(under: fixture.hosting, axIdentifier: M10ControlID.groupCheckbox("Alpha"))
                as? NSButton
        )
        #expect(!groupCheckbox.isEnabled)
    }
}

@MainActor
@Suite("Unified merge list — GROUP near-match parity (I2)", .serialized)
struct GroupRowNearMatchParityStructuralTests {

    private func allGroupClusterWire() -> String {
        plumbingListingWire([
            plumbingEntry(id: 10, name: "Trance 2022", pid: "T-A", count: 9),
            plumbingEntry(id: 11, name: "Trance 2022", pid: "T-B", count: 10),
            plumbingEntry(id: 20, name: "Trance 2022 ", pid: "T-C", count: 4),
            plumbingEntry(id: 21, name: "Trance 2022 ", pid: "T-D", count: 5),
        ])
    }

    /// Finding I2: an all-group cluster's rows are badged and route to the
    /// near-match inspector, so Align names… — the ONLY in-app fix for a
    /// twin — is reachable. Before this, `mergeSingletonRowSelection` was the
    /// only near-match route and no singleton existed in this library shape.
    @Test("an all-group cluster's rows carry the twin and reach the near-match inspector")
    func allGroupClusterReachesAlignNames() async throws {
        let harness = try await loadedUnifiedMergeHarness(wire: allGroupClusterWire())
        defer { harness.cleanUp() }
        let model = harness.model
        let sections = try #require(model.loadedSections)
        #expect(sections.singletons.isEmpty, "every row here is a GROUP row")

        let rows = mergeRows(sections: sections, needle: "", key: .name, ascending: true)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.nearMatchTwin != nil }, "both group rows are badged")

        // Route the badged row's tap exactly as `groupRow` does...
        guard let row = rows.first, case .group(let group, let twin) = row else {
            Issue.record("expected a group row")
            return
        }
        let selection = mergeGroupRowSelection(for: group, nearMatchTwin: twin, in: sections)
        #expect(selection == .nearMatch("Trance 2022"))

        // ...and confirm that selection renders the near-match inspector with
        // its Align names… entry point contained in the real composition.
        model.browserSelection = selection
        let fixture = HostedFixture(
            SourceSelectionView(model: model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        let open = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.alignOpen) as? NSButton
        )
        let frame = open.convert(open.bounds, to: fixture.hosting)
        #expect(NSRect(x: 0, y: 0, width: 1200, height: 800).contains(frame), "Align names… at \(frame)")
    }
}

@MainActor
@Suite("Unified merge list — Select all drives both sets (2026-08-11)", .serialized)
struct UnifiedMergeSelectAllStructuralTests {

    @Test("Select all checks every eligible group AND every eligible singleton")
    func selectAllChecksBothSets() async throws {
        let harness = try await loadedUnifiedMergeHarness()
        defer { harness.cleanUp() }

        let fixture = HostedFixture(
            SourceSelectionView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }

        let selectAll = try #require(
            view(under: fixture.hosting, axIdentifier: WaveAControlID.selectAll) as? NSButton
        )
        selectAll.performClick(nil)

        #expect(harness.model.checkedGroupNames == ["Trance 2022"])
        #expect(harness.model.checkedFreeFormSingletonPersistentIds == Set(["FM-A", "FM-B"]))
    }
}
