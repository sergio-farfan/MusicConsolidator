// BrowserMutationStructuralTests.swift
// Wave B (B4/B5) — offscreen structural cells for the browser inspector's
// Delete/Rename... actions. Task 5 (Sergio, 2026-08-06) retired the audited
// mutation gate from this composition: every row action now stages a direct
// pending action with ZERO refusal filtering (smart playlists, folders, the
// contract-excluded pilot all included) — the confirm/rename sheet
// (`DirectMutationSheets`, pinned separately) is the only thing standing
// between a click and the guarded AppleScript writer. This suite pins the
// NEAR MATCHES "Align names..." entry point and the AlignNamesSheet content
// (pick list + N-1 rename rows), which are unchanged. Same offscreen
// discipline as the M8-M11 suites; Music is never contacted (ScriptedRunner
// only).

import AppKit
import SwiftUI
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

private let browserBox = NSRect(x: 0, y: 0, width: 1200, height: 800)

private func fixtureListing(
    id: Double, name: String, pid: String, count: Int,
    smart: Bool = false, specialKind: String = "none"
) -> PlaylistListing {
    PlaylistListing(
        playlistId: id, name: name, persistentId: pid,
        trackCount: count, isSmart: smart, specialKind: specialKind
    )
}

/// A normal singleton, a smart singleton, a contract-excluded singleton, a
/// 2-copy group, and one trailing-space near-match pair.
private func browserFixtureSections() -> PlaylistBrowseSections {
    buildPlaylistBrowseSections(from: [
        fixtureListing(id: 10, name: "Solo List", pid: "S-E", count: 4),
        fixtureListing(id: 20, name: "Smarty", pid: "S-SMART", count: 6, smart: true),
        fixtureListing(id: 30, name: "#Musica xTotal", pid: "S-XT", count: 100),
        fixtureListing(id: 40, name: "Trance 2022", pid: "G-A", count: 9),
        fixtureListing(id: 50, name: "Trance 2022", pid: "G-B", count: 10),
        fixtureListing(id: 60, name: "Kdrama", pid: "S-C", count: 7),
        fixtureListing(id: 70, name: "Kdrama ", pid: "S-D", count: 9),
    ])
}

/// The same rows as `browserFixtureSections`, as scan wire text: the direct
/// mutation entry points (`requestDirectDelete`/`requestDirectRename`)
/// resolve against `model.loadedListing` — the CACHED scan result — not the
/// `sections:` parameter handed to `BrowserInspector` directly, so a real
/// scan is required for those click-plumbing tests to find anything.
private func browserFixtureListingWire() -> String {
    let entries = [
        gateEntry(id: 10, name: "Solo List", pid: "S-E", count: 4),
        gateEntry(id: 20, name: "Smarty", pid: "S-SMART", count: 6, smart: true),
        gateEntry(id: 30, name: "#Musica xTotal", pid: "S-XT", count: 100),
        gateEntry(id: 40, name: "Trance 2022", pid: "G-A", count: 9),
        gateEntry(id: 50, name: "Trance 2022", pid: "G-B", count: 10),
        gateEntry(id: 60, name: "Kdrama", pid: "S-C", count: 7),
        gateEntry(id: 70, name: "Kdrama ", pid: "S-D", count: 9),
    ]
    return "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

@MainActor
private func inspectorFixture(
    selecting selection: BrowserSelection
) async throws -> (harness: MutationGateHarness, fixture: HostedFixture<BrowserInspector>) {
    let harness = try MutationGateHarness(runner: ScriptedRunner(outputs: [browserFixtureListingWire()]))
    harness.model.rescanLibrary()
    await harness.model.scanTask?.value
    harness.model.browserSelection = selection
    let fixture = HostedFixture(
        BrowserInspector(model: harness.model, sections: browserFixtureSections()),
        width: 1200, height: 800
    )
    return (harness, fixture)
}

@MainActor
@Suite("Offscreen structural view tests (Wave B browser mutations)", .serialized)
struct BrowserMutationStructuralTests {

    @Test("a group's copy rows stay compact and contained at the inspector's real pane width")
    func groupCopyRowsCompactAtPaneWidth() async throws {
        // Sergio, 2026-08-06: with Delete + Rename… beside the PID and the
        // count, the ~300pt inspector squeezed the count text to one
        // character per line — an M8-class vertical explosion.
        let harness = try MutationGateHarness(
            runner: ScriptedRunner(outputs: [browserFixtureListingWire()])
        )
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.browserSelection = .group("Trance 2022")
        let fixture = HostedFixture(
            BrowserInspector(model: harness.model, sections: browserFixtureSections()),
            width: 220, height: 800
        )
        defer { fixture.tearDown() }
        let paneBox = NSRect(x: 0, y: 0, width: 220, height: 800)
        let d0 = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.rowDelete("G-A")) as? NSButton
        )
        let d1 = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.rowDelete("G-B")) as? NSButton
        )
        let f0 = d0.convert(d0.bounds, to: fixture.hosting)
        let f1 = d1.convert(d1.bounds, to: fixture.hosting)
        #expect(paneBox.contains(f0), "copy 0 Delete at \(f0)")
        #expect(paneBox.contains(f1), "copy 1 Delete at \(f1)")
        #expect(
            abs(f0.midY - f1.midY) <= 64,
            "copy rows exploded vertically: \(f0.midY) vs \(f1.midY)"
        )
    }

    @Test("a plain singleton exposes enabled Delete/Rename actions and no refusal note")
    func singletonActionsEnabled() async throws {
        let (harness, fixture) = try await inspectorFixture(selecting: .singleton("S-E"))
        defer { harness.cleanUp(); fixture.tearDown() }
        let deleteButton = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.rowDelete("S-E")) as? NSButton
        )
        let renameButton = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.rowRename("S-E")) as? NSButton
        )
        #expect(deleteButton.isEnabled)
        #expect(renameButton.isEnabled)
        #expect(view(under: fixture.hosting, axIdentifier: WaveBControlID.browserRefusal) == nil)
        let frame = deleteButton.convert(deleteButton.bounds, to: fixture.hosting)
        #expect(browserBox.contains(frame))
    }

    // Task 5 (Sergio, 2026-08-06): direct mutations apply ZERO refusal
    // filtering — smart playlists and the contract-excluded pilot are just
    // as directly deletable/renamable as a plain singleton. This replaces
    // the retired pre-gate refusal-disabling pin with the new anatomy.
    @Test("smart and contract-excluded rows are directly actionable too (no refusal filtering)")
    func allRowsAreDirectlyActionable() async throws {
        for pid in ["S-SMART", "S-XT"] {
            let (harness, fixture) = try await inspectorFixture(selecting: .singleton(pid))
            defer { harness.cleanUp(); fixture.tearDown() }
            let deleteButton = try #require(
                view(under: fixture.hosting, axIdentifier: WaveBControlID.rowDelete(pid)) as? NSButton
            )
            let renameButton = try #require(
                view(under: fixture.hosting, axIdentifier: WaveBControlID.rowRename(pid)) as? NSButton
            )
            #expect(deleteButton.isEnabled, "\(pid)")
            #expect(renameButton.isEnabled, "\(pid)")
            #expect(
                view(under: fixture.hosting, axIdentifier: WaveBControlID.browserRefusal) == nil,
                "\(pid)"
            )
        }
    }

    @Test("a same-name group exposes per-copy Delete/Rename actions pinned by persistent ID")
    func groupPerCopyActions() async throws {
        let (harness, fixture) = try await inspectorFixture(selecting: .group("Trance 2022"))
        defer { harness.cleanUp(); fixture.tearDown() }
        for pid in ["G-A", "G-B"] {
            #expect(
                view(under: fixture.hosting, axIdentifier: WaveBControlID.rowDelete(pid)) != nil, "\(pid)"
            )
            #expect(
                view(under: fixture.hosting, axIdentifier: WaveBControlID.rowRename(pid)) != nil, "\(pid)"
            )
        }
    }

    // Task 5: the old inline rename editor (browserRenamePID/
    // browserRenameDraft, model-level state, stays dormant) is retired from
    // this view — Rename... now stages a pending direct rename pre-filled
    // with the row's current name, same as the Cleanup tab and the Align
    // sheet.
    @Test("clicking Rename... stages a pending direct rename pre-filled with the current name")
    func renameClickPlumbing() async throws {
        let (harness, fixture) = try await inspectorFixture(selecting: .singleton("S-E"))
        defer { harness.cleanUp(); fixture.tearDown() }
        let renameButton = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.rowRename("S-E")) as? NSButton
        )
        renameButton.performClick(nil)
        guard case .rename(let target) = harness.model.pendingDirectAction else {
            Issue.record("the Rename... click never reached requestDirectRename")
            return
        }
        #expect(target.persistentId == "S-E")
        #expect(harness.model.typedRenameName == "Solo List")
    }

    @Test("clicking Delete stages the pending direct delete confirmation (click plumbing)")
    func deleteClickPlumbing() async throws {
        let (harness, fixture) = try await inspectorFixture(selecting: .singleton("S-E"))
        defer { harness.cleanUp(); fixture.tearDown() }
        let deleteButton = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.rowDelete("S-E")) as? NSButton
        )
        deleteButton.performClick(nil)
        guard case .delete(let targets) = harness.model.pendingDirectAction else {
            Issue.record("the Delete click never reached requestDirectDelete")
            return
        }
        #expect(targets.map(\.persistentId) == ["S-E"])
    }

    @Test("a near-match cluster exposes the Align names... entry point")
    func alignEntryPoint() async throws {
        let (harness, fixture) = try await inspectorFixture(selecting: .nearMatch("Kdrama"))
        defer { harness.cleanUp(); fixture.tearDown() }
        let open = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.alignOpen) as? NSButton
        )
        let frame = open.convert(open.bounds, to: fixture.hosting)
        #expect(browserBox.contains(frame))
    }

    @Test("the align sheet auto-selects a clear winner and lists the N-1 rename rows")
    func alignSheetClearWinner() async throws {
        let cluster = try #require(browserFixtureSections().nearMatches.first)
        let recorder = AlignRecorder()
        let fixture = HostedFixture(
            AlignNamesSheet(cluster: cluster) { pid, canonical in
                recorder.record(pid: pid, canonical: canonical)
            },
            width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        // Both variants are pickable; the qualifying "Kdrama" is preselected.
        #expect(view(under: fixture.hosting, axIdentifier: WaveBControlID.alignPick("Kdrama")) != nil)
        #expect(view(under: fixture.hosting, axIdentifier: WaveBControlID.alignPick("Kdrama ")) != nil)
        let rename = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.alignRename("S-D")) as? NSButton
        )
        let frame = rename.convert(rename.bounds, to: fixture.hosting)
        #expect(browserBox.contains(frame))
        rename.performClick(nil)
        #expect(recorder.pids == ["S-D"])
        #expect(recorder.canonicals == ["Kdrama"])
    }

    @Test("with no qualifying variant the sheet demands a pick and shows no rename rows")
    func alignSheetNoWinner() async throws {
        let cluster = PlaylistNearMatchCluster(
            normalizedName: "Kdrama",
            variants: [
                PlaylistNearMatchVariant(
                    name: "Kdrama ",
                    listings: [fixtureListing(id: 10, name: "Kdrama ", pid: "N-1", count: 3)]
                ),
                PlaylistNearMatchVariant(
                    name: "Kdrama\u{A0}",
                    listings: [fixtureListing(id: 20, name: "Kdrama\u{A0}", pid: "N-2", count: 3)]
                ),
            ]
        )
        let fixture = HostedFixture(
            AlignNamesSheet(cluster: cluster) { _, _ in },
            width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(view(under: fixture.hosting, axIdentifier: WaveBControlID.alignPick("Kdrama ")) != nil)
        #expect(view(under: fixture.hosting, axIdentifier: WaveBControlID.alignRename("N-1")) == nil)
        #expect(view(under: fixture.hosting, axIdentifier: WaveBControlID.alignRename("N-2")) == nil)
    }
}

/// Main-actor recorder for the sheet's onRename callback.
@MainActor
private final class AlignRecorder {
    private(set) var pids: [String] = []
    private(set) var canonicals: [String] = []

    func record(pid: String, canonical: String) {
        pids.append(pid)
        canonicals.append(canonical)
    }
}
