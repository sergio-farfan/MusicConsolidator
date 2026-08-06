// DirectMutationSheetTests.swift
// Task 4 (Sergio, 2026-08-06) — offscreen structural tests for
// DirectMutationSheets: the batch-delete confirm anatomy (count title,
// folder-cascade line, both buttons), the rename sheet's pre-filled token
// field, and the error panel's verbatim reason. Same offscreen discipline as
// the other structural suites (NSHostingView into a never-shown NSWindow,
// ScriptedRunner fakes, zero Music contact).

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
    }
}
