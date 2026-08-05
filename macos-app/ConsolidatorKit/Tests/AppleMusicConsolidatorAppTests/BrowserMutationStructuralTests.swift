// BrowserMutationStructuralTests.swift
// Wave B (B4/B5) — offscreen structural cells for the browser inspector's
// Delete.../Rename... actions (refusals surfaced BEFORE any gate as a
// disabled action plus the verbatim reason), the rename editor, the
// NEAR MATCHES "Align names..." entry point, and the AlignNamesSheet
// content (pick list + N-1 rename rows). Same offscreen discipline as the
// M8-M11 suites; Music is never contacted (ScriptedRunner only).

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

@MainActor
private func inspectorFixture(
    selecting selection: BrowserSelection
) throws -> (harness: MutationGateHarness, fixture: HostedFixture<BrowserInspector>) {
    let harness = try MutationGateHarness(runner: ScriptedRunner(outputs: []))
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

    @Test("a plain singleton exposes enabled Delete/Rename actions and no refusal note")
    func singletonActionsEnabled() async throws {
        let (harness, fixture) = try inspectorFixture(selecting: .singleton("S-E"))
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

    @Test("refused rows surface the reason BEFORE any gate: disabled actions + verbatim note")
    func refusedRowsAreDisabledWithReason() async throws {
        for pid in ["S-SMART", "S-XT"] {
            let (harness, fixture) = try inspectorFixture(selecting: .singleton(pid))
            defer { harness.cleanUp(); fixture.tearDown() }
            let deleteButton = try #require(
                view(under: fixture.hosting, axIdentifier: WaveBControlID.rowDelete(pid)) as? NSButton
            )
            let renameButton = try #require(
                view(under: fixture.hosting, axIdentifier: WaveBControlID.rowRename(pid)) as? NSButton
            )
            #expect(!deleteButton.isEnabled, "\(pid)")
            #expect(!renameButton.isEnabled, "\(pid)")
            let note = try #require(
                view(under: fixture.hosting, axIdentifier: WaveBControlID.browserRefusal)
            )
            let frame = note.convert(note.bounds, to: fixture.hosting)
            #expect(browserBox.contains(frame), "\(pid)")
            // Refusal is pre-gate: nothing was audited, armed, or written.
            guard case .idle = harness.model.mutationGatePhase else {
                Issue.record("the gate must stay idle for a refused row (\(pid))")
                continue
            }
        }
    }

    @Test("a same-name group exposes per-copy Delete/Rename actions pinned by persistent ID")
    func groupPerCopyActions() async throws {
        let (harness, fixture) = try inspectorFixture(selecting: .group("Trance 2022"))
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

    @Test("Rename... opens the editor: empty destination field, audit disabled until non-empty")
    func renameEditor() async throws {
        let (harness, fixture) = try inspectorFixture(selecting: .singleton("S-E"))
        defer { harness.cleanUp(); fixture.tearDown() }
        harness.model.browserRenamePID = "S-E"
        fixture.pump()
        let field = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.browserRenameField)
        )
        let audit = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.browserRenameAudit) as? NSButton
        )
        let frame = field.convert(field.bounds, to: fixture.hosting)
        #expect(browserBox.contains(frame))
        #expect(!audit.isEnabled, "an empty destination must not be auditable")
        harness.model.browserRenameDraft = "Solo Listing"
        fixture.pump()
        #expect(audit.isEnabled)
    }

    @Test("clicking Delete... starts the mutation audit (click plumbing)")
    func deleteClickPlumbing() async throws {
        let (harness, fixture) = try inspectorFixture(selecting: .singleton("S-E"))
        defer { harness.cleanUp(); fixture.tearDown() }
        let deleteButton = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.rowDelete("S-E")) as? NSButton
        )
        deleteButton.performClick(nil)
        await harness.model.mutationTask?.value
        // The empty ScriptedRunner makes the audit read fail -> refused;
        // what this test pins is that the click REACHED startMutationAudit.
        if case .idle = harness.model.mutationGatePhase {
            Issue.record("the Delete... click never reached startMutationAudit")
        }
    }

    @Test("a near-match cluster exposes the Align names... entry point")
    func alignEntryPoint() async throws {
        let (harness, fixture) = try inspectorFixture(selecting: .nearMatch("Kdrama"))
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
