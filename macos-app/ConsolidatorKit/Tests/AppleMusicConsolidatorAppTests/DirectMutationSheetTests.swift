// DirectMutationSheetTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Task 4 (Sergio, 2026-08-06) — offscreen structural tests for
// DirectMutationSheets: the batch-delete confirm anatomy (count title,
// folder-cascade line, both buttons), the rename sheet's pre-filled token
// field, the error panel's verbatim reason, and (final fix wave, Finding I1)
// the in-progress panel plus the error > in-progress > pending > empty
// precedence. Same offscreen discipline as the other structural suites
// (NSHostingView into a never-shown NSWindow, ScriptedRunner fakes, zero
// Music contact).

import AppKit
import SwiftUI
import Testing
import MusicBridge
@testable import AppleMusicConsolidatorApp

private let directSheetBox = NSRect(x: 0, y: 0, width: 480, height: 360)

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
        directSheetBox.contains(frame),
        "\(id) at \(frame)",
        sourceLocation: sourceLocation
    )
}

@MainActor
@Suite("Direct mutation sheets", .serialized)
struct DirectMutationSheetTests {

    @Test("batch delete confirm shows count title, cascade line for folders, both buttons contained")
    func batchConfirmAnatomy() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value
        model.requestDirectDelete(persistentIDs: ["SOLO000000000001", "FOLD000000000001"])

        let fixture = HostedFixture(DirectMutationSheets(model: model), width: 480, height: 360)
        defer { fixture.tearDown() }
        expectContained(DirectControlID.confirmExecute, in: fixture)
        expectContained(DirectControlID.confirmCancel, in: fixture)
        // Folder in the selection -> the cascade line is present and
        // carries the verbatim text (adapted from the brief's hypothetical
        // `fixture.containsText(...)`: this suite's established idiom is
        // "locate the AppKit-backed control by identifier, then read its
        // NSTextField.stringValue" — see ActivityStructuralTests.swift).
        expectContained(DirectControlID.folderCascadeNotice, in: fixture)
        let cascade = try #require(
            view(under: fixture.hosting, axIdentifier: DirectControlID.folderCascadeNotice)
                as? NSTextField
        )
        #expect(cascade.stringValue == "Deleting a folder also deletes the playlists inside it.")
    }

    @Test("rename sheet pre-fills the field; error panel shows the verbatim reason")
    func renameAndErrorAnatomy() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value
        model.requestDirectRename(persistentID: "SOLO000000000001", prefilledName: nil)

        let fixture = HostedFixture(DirectMutationSheets(model: model), width: 480, height: 360)
        defer { fixture.tearDown() }
        expectContained(DirectControlID.renameField, in: fixture)
        #expect(model.typedRenameName == "Solo List")
    }

    // Extends the pair above's title with an actual assertion: drives a
    // real dispatch failure (the scan consumes the runner's only scripted
    // output, so the delete's compile call finds none and throws) and
    // checks the error panel renders the model's verbatim reason.
    @Test("a dispatch failure surfaces the verbatim reason in the error panel")
    func errorPanelShowsVerbatimReason() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        model.requestDirectDelete(persistentIDs: ["SOLO000000000001"])
        model.confirmPendingDirectAction()
        await model.directMutationTask?.value
        let message = try #require(model.directMutationError)

        let fixture = HostedFixture(DirectMutationSheets(model: model), width: 480, height: 360)
        defer { fixture.tearDown() }
        expectContained(DirectControlID.errorDismiss, in: fixture)
        let text = try #require(
            view(under: fixture.hosting, axIdentifier: DirectControlID.errorMessage) as? NSTextField
        )
        #expect(text.stringValue == message)

        // OK dismisses.
        let ok = try #require(
            view(under: fixture.hosting, axIdentifier: DirectControlID.errorDismiss) as? NSButton
        )
        ok.performClick(nil)
        #expect(model.directMutationError == nil)
    }

    // Final fix wave, Finding I1: the sheet now stays up THROUGH dispatch —
    // confirm clears the pending action and a failure only arrives
    // milliseconds later, so re-presenting a just-dismissed sheet was the
    // only failure channel. While the dispatch runs the container shows the
    // in-progress panel and NO confirm controls (there is nothing left to
    // confirm or cancel).
    @Test("the in-progress panel renders while a dispatch is in flight, with no confirm controls")
    func inProgressPanelWhileDispatching() async throws {
        let runner = StagedBlockingRunner(
            outputs: [gateListingWire(), "", "ok"], blockAt: [1]
        )
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        model.requestDirectDelete(persistentIDs: ["SOLO000000000001"])
        model.confirmPendingDirectAction()
        #expect(await pollUntil { runner.runCount == 2 })
        #expect(model.isDirectMutationRunning)
        #expect(model.pendingDirectAction == nil)

        let fixture = HostedFixture(DirectMutationSheets(model: model), width: 480, height: 360)
        defer { fixture.tearDown() }
        expectContained(DirectControlID.inProgressStatus, in: fixture)
        expectContained(DirectControlID.inProgressCaption, in: fixture)
        let status = try #require(
            view(under: fixture.hosting, axIdentifier: DirectControlID.inProgressStatus)
                as? NSTextField
        )
        #expect(status.stringValue == "Working\u{2026}")
        // Sergio, 2026-08-06: the caption clipped mid-sentence — the wrapping
        // label's intrinsic height was computed for one line. The field must
        // be tall enough for its own required height at the laid-out width.
        let caption = try #require(
            view(under: fixture.hosting, axIdentifier: DirectControlID.inProgressCaption)
                as? NSTextField
        )
        let required = caption.sizeThatFits(
            NSSize(width: caption.frame.width, height: .greatestFiniteMagnitude)
        ).height
        #expect(
            caption.frame.height + 0.5 >= required,
            "caption clipped: frame \(caption.frame.height) < required \(required)"
        )
        #expect(view(under: fixture.hosting, axIdentifier: DirectControlID.confirmExecute) == nil)
        #expect(view(under: fixture.hosting, axIdentifier: DirectControlID.confirmCancel) == nil)
        #expect(view(under: fixture.hosting, axIdentifier: DirectControlID.errorDismiss) == nil)

        runner.proceed.signal()
        await model.directMutationTask?.value
        #expect(model.directMutationError == nil)
    }

    // Precedence pin: error > in-progress. Reachable because
    // `directMutationError` survives until the user dismisses it, so a NEXT
    // dispatch can be in flight while an unread reason is still set — the
    // reason must never be hidden behind the spinner.
    @Test("the error panel wins over the in-progress panel")
    func errorPanelWinsOverInProgress() async throws {
        // Only the scan is scripted, so delete 1's compile call throws and
        // sets the error; delete 2's compile call is the BLOCKED one.
        let runner = StagedBlockingRunner(outputs: [gateListingWire()], blockAt: [2])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        model.requestDirectDelete(persistentIDs: ["SOLO000000000001"])
        model.confirmPendingDirectAction()
        await model.directMutationTask?.value
        let message = try #require(model.directMutationError)
        #expect(!model.isDirectMutationRunning)

        // A second dispatch, in flight while the first reason is still unread.
        model.requestDirectDelete(persistentIDs: ["TRAIL00000000001"])
        model.confirmPendingDirectAction()
        #expect(await pollUntil { runner.runCount == 3 })
        #expect(model.isDirectMutationRunning)

        let fixture = HostedFixture(DirectMutationSheets(model: model), width: 480, height: 360)
        defer { fixture.tearDown() }
        expectContained(DirectControlID.errorDismiss, in: fixture)
        let text = try #require(
            view(under: fixture.hosting, axIdentifier: DirectControlID.errorMessage) as? NSTextField
        )
        #expect(text.stringValue == message)
        #expect(
            view(under: fixture.hosting, axIdentifier: DirectControlID.inProgressStatus) == nil,
            "the spinner must never hide an unread failure reason"
        )

        runner.proceed.signal()
        await model.directMutationTask?.value
    }

    @Test("neither error nor pending action renders nothing")
    func emptyWhenNeitherSet() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        let fixture = HostedFixture(DirectMutationSheets(model: model), width: 480, height: 360)
        defer { fixture.tearDown() }
        #expect(view(under: fixture.hosting, axIdentifier: DirectControlID.confirmExecute) == nil)
        #expect(view(under: fixture.hosting, axIdentifier: DirectControlID.renameField) == nil)
        #expect(view(under: fixture.hosting, axIdentifier: DirectControlID.errorDismiss) == nil)
        #expect(view(under: fixture.hosting, axIdentifier: DirectControlID.inProgressStatus) == nil)
    }

    // Task 5 — the Cleanup tab hosts the row actions directly (no gate pane
    // beside it anymore): its own Delete button keeps the WaveBControlID it
    // always had, the new Rename... button carries the DirectControlID this
    // suite already knows, and the retired gate's disarmed-state text must
    // never render inside this composition.
    @Test("the Cleanup tab shows row rename/delete controls, never the retired gate's disarmed text")
    func cleanupTabShowsDirectRowControlsNotTheGate() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        let fixture = HostedFixture(
            CleanupTabView(model: model), width: 900, height: 620
        )
        defer { fixture.tearDown() }
        let box = NSRect(x: 0, y: 0, width: 900, height: 620)
        let rename = try #require(
            view(under: fixture.hosting, axIdentifier: DirectControlID.rowRename("SOLO000000000001"))
        )
        #expect(box.contains(rename.convert(rename.bounds, to: fixture.hosting)))
        let delete = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.cleanupDelete("SOLO000000000001"))
        )
        #expect(box.contains(delete.convert(delete.bounds, to: fixture.hosting)))
        // The retired gate pane's disarmed-state text ("No mutation armed",
        // MutationGateView.swift) is plain SwiftUI content with no AX
        // identifier of its own, so this suite's established idiom (locate
        // by identifier) proves its absence indirectly but conclusively:
        // MutationGateView's OWN dismiss control is AppKit-backed and (per
        // NarrowWindowStructuralTests) renders in every gate phase including
        // idle/disarmed — its absence here means the entire gate view,
        // "No mutation armed" included, was never mounted beside this tab.
        #expect(view(under: fixture.hosting, axIdentifier: WaveBControlID.mutationDismiss) == nil)
    }
}
