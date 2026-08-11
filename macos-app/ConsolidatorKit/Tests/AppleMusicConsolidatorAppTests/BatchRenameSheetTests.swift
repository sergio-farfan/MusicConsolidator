// BatchRenameSheetTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Task 2 (Sergio, 2026-08-06) — offscreen structural tests for the
// batch-rename sheet panel (find/replace helper, per-row editable fields,
// commit gated on the changed-draft count) and the Cleanup footer's "Rename
// selected (N)..." action. Same offscreen discipline as
// DirectMutationSheetTests.swift: NSHostingView into a never-shown
// NSWindow, ScriptedRunner fakes, zero Music contact.

import AppKit
import SwiftUI
import Testing
import MusicBridge
import ConsolidatorCore
@testable import AppleMusicConsolidatorApp

private let batchRenameSheetBox = NSRect(x: 0, y: 0, width: 560, height: 520)

@MainActor
private func expectContained(
    _ id: String,
    in fixture: HostedFixture<some View>,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    guard let control = view(under: fixture.hosting, axIdentifier: id) else {
        Issue.record("control \(id) is missing", sourceLocation: sourceLocation)
        return
    }
    let frame = control.convert(control.bounds, to: fixture.hosting)
    #expect(
        batchRenameSheetBox.contains(frame),
        "\(id) at \(frame)",
        sourceLocation: sourceLocation
    )
}

/// Drives an `AppKitTokenField`'s bound text the same way real typing would:
/// set the NSTextField's `stringValue`, then invoke the delegate callback the
/// field editor would normally fire (there is no key window here, so nothing
/// fires it for us).
@MainActor
private func typeIntoTokenField(_ field: NSTextField, _ text: String) {
    field.stringValue = text
    field.delegate?.controlTextDidChange?(
        Notification(name: NSControl.textDidChangeNotification, object: field)
    )
}

@MainActor
@Suite("Batch rename sheet", .serialized)
struct BatchRenameSheetTests {

    @Test("panel anatomy: find/replace/apply-all present, rows pre-filled, commit gated on changed count")
    func panelAnatomy() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value
        model.requestDirectBatchRename(
            persistentIDs: ["SOLO000000000001", "TRAIL00000000001"]
        )

        let fixture = HostedFixture(
            DirectMutationSheets(model: model), width: 560, height: 520
        )
        defer { fixture.tearDown() }

        expectContained(DirectControlID.batchRenameFind, in: fixture)
        expectContained(DirectControlID.batchRenameReplace, in: fixture)
        expectContained(DirectControlID.batchRenameApplyAll, in: fixture)

        let soloField = try #require(
            view(
                under: fixture.hosting,
                axIdentifier: DirectControlID.batchRenameField("SOLO000000000001")
            ) as? NSTextField
        )
        #expect(soloField.stringValue == "Solo List")
        let trailField = try #require(
            view(
                under: fixture.hosting,
                axIdentifier: DirectControlID.batchRenameField("TRAIL00000000001")
            ) as? NSTextField
        )
        #expect(trailField.stringValue == "Kdrama ")

        let commit = try #require(
            view(under: fixture.hosting, axIdentifier: DirectControlID.confirmExecute)
                as? NSButton
        )
        #expect(!commit.isEnabled, "0 changed drafts -> disabled")

        model.setBatchRenameDraft("Solo Renamed", for: "SOLO000000000001")
        fixture.hosting.layoutSubtreeIfNeeded()

        let commitAfter = try #require(
            view(under: fixture.hosting, axIdentifier: DirectControlID.confirmExecute)
                as? NSButton
        )
        #expect(commitAfter.isEnabled, "one changed draft -> enabled")
        #expect(commitAfter.title == "Rename 1 playlists")
    }

    @Test("Apply to all drives the model: literal find/replace over every current draft")
    func applyToAllDrivesModel() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value
        model.requestDirectBatchRename(
            persistentIDs: ["SOLO000000000001", "TRAIL00000000001"]
        )

        let fixture = HostedFixture(
            DirectMutationSheets(model: model), width: 560, height: 520
        )
        defer { fixture.tearDown() }

        let findField = try #require(
            view(under: fixture.hosting, axIdentifier: DirectControlID.batchRenameFind)
                as? NSTextField
        )
        typeIntoTokenField(findField, "List")
        let replaceField = try #require(
            view(under: fixture.hosting, axIdentifier: DirectControlID.batchRenameReplace)
                as? NSTextField
        )
        typeIntoTokenField(replaceField, "Catalog")

        let applyAll = try #require(
            view(under: fixture.hosting, axIdentifier: DirectControlID.batchRenameApplyAll)
                as? NSButton
        )
        applyAll.performClick(nil)

        #expect(model.batchRenameDrafts["SOLO000000000001"] == "Solo Catalog")
        #expect(model.batchRenameDrafts["TRAIL00000000001"] == "Kdrama ")
    }

    @Test("footer: Rename selected sits between Clear and Delete selected, disabled at zero, drives the model")
    func footerRenameSelectedButton() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: [gateListingWire()]),
            mode: .consolidate, playlistName: ""
        )
        defer { harness.cleanUp() }
        harness.model.setBrowserTab(.cleanup)
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value

        let fixture = HostedFixture(
            SourceSelectionView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        let windowBox = NSRect(x: 0, y: 0, width: 1200, height: 800)

        let renameSelected = try #require(
            view(under: fixture.hosting, axIdentifier: DirectControlID.renameSelected)
                as? NSButton
        )
        #expect(!renameSelected.isEnabled, "no selection -> disabled, like Delete selected")
        let frame = renameSelected.convert(renameSelected.bounds, to: fixture.hosting)
        #expect(windowBox.contains(frame), "Rename selected at \(frame)")

        harness.model.toggleCleanupChecked("SOLO000000000001")
        fixture.hosting.layoutSubtreeIfNeeded()
        let enabled = try #require(
            view(under: fixture.hosting, axIdentifier: DirectControlID.renameSelected)
                as? NSButton
        )
        #expect(enabled.isEnabled)

        enabled.performClick(nil)
        guard case .batchRename(let targets)? = harness.model.pendingDirectAction else {
            Issue.record("expected a pending batch rename after clicking Rename selected")
            return
        }
        #expect(targets.map(\.persistentId) == ["SOLO000000000001"])
    }
}
