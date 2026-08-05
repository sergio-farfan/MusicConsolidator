// MutationGateStructuralTests.swift
// Wave B — offscreen structural cells for MutationGateView: disarmed and
// armed states, the ambiguity-driven extra token fields, the rename
// collision warning, the unattended-run lockout notice, and the failed
// execution's height-capped mismatch panel — all inside a 1200x800 window
// box. Same offscreen discipline as the M8-M11 suites: never-shown windows,
// fixture-driven models, geometric containment; Music is never contacted.

import AppKit
import SwiftUI
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

private let gateWindowBox = NSRect(x: 0, y: 0, width: 1200, height: 800)

@MainActor
private func expectGateContained(
    _ id: String,
    in hosting: NSView,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    guard let control = view(under: hosting, axIdentifier: id) else {
        Issue.record("control \(id) is missing", sourceLocation: sourceLocation)
        return
    }
    let frame = control.convert(control.bounds, to: hosting)
    #expect(gateWindowBox.contains(frame), "\(id) at \(frame)", sourceLocation: sourceLocation)
}

@MainActor
@Suite("Offscreen structural view tests (Wave B mutation gate)", .serialized)
struct MutationGateStructuralTests {

    @Test("the disarmed gate shows no execute control and no token fields")
    func disarmedGate() async throws {
        let harness = try MutationGateHarness(runner: ScriptedRunner(outputs: []))
        defer { harness.cleanUp() }
        let fixture = HostedFixture(
            MutationGateView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)
        #expect(view(under: fixture.hosting, axIdentifier: WaveBControlID.mutationExecute) == nil)
        #expect(view(under: fixture.hosting, axIdentifier: WaveBControlID.mutationNameField) == nil)
        expectGateContained(WaveBControlID.mutationDismiss, in: fixture.hosting)
    }

    @Test("the armed unambiguous gate shows one token field; execute enables on the exact name")
    func armedUnambiguousGate() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire(), soloSnapshotWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(kind: .delete, persistentID: "SOLO000000000001")
        await harness.awaitMutation()
        #expect(harness.model.armedMutation != nil)

        let fixture = HostedFixture(
            MutationGateView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)
        expectGateContained(WaveBControlID.mutationNameField, in: fixture.hosting)
        #expect(view(under: fixture.hosting, axIdentifier: WaveBControlID.mutationCountField) == nil)
        #expect(view(under: fixture.hosting, axIdentifier: WaveBControlID.mutationPIDField) == nil)

        let execute = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.mutationExecute) as? NSButton
        )
        #expect(!execute.isEnabled, "execute must stay disabled until the tokens match")
        harness.model.typedMutationName = "Solo List"
        fixture.pump()
        #expect(execute.isEnabled)
        expectGateContained(WaveBControlID.mutationExecute, in: fixture.hosting)
        expectGateContained(WaveBControlID.mutationDismiss, in: fixture.hosting)
    }

    @Test("the fully ambiguous gate demands all three token fields before enabling execute")
    func ambiguousGateFields() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire(), twinsameSnapshotWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(kind: .delete, persistentID: "SAME000000003333")
        await harness.awaitMutation()
        #expect(harness.model.armedMutation?.requiresPIDSuffixToken == true)

        let fixture = HostedFixture(
            MutationGateView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)
        expectGateContained(WaveBControlID.mutationNameField, in: fixture.hosting)
        expectGateContained(WaveBControlID.mutationCountField, in: fixture.hosting)
        expectGateContained(WaveBControlID.mutationPIDField, in: fixture.hosting)

        let execute = try #require(
            view(under: fixture.hosting, axIdentifier: WaveBControlID.mutationExecute) as? NSButton
        )
        harness.model.typedMutationName = "Twinsame"
        harness.model.typedMutationCount = "4"
        fixture.pump()
        #expect(!execute.isEnabled, "two of three tokens must not enable execute")
        harness.model.typedMutationPIDSuffix = "3333"
        fixture.pump()
        #expect(execute.isEnabled)
    }

    @Test("the rename collision warning is visible and contained")
    func renameCollisionVisible() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire(), soloSnapshotWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(
            kind: .rename, persistentID: "SOLO000000000001", newName: "Twin"
        )
        await harness.awaitMutation()
        #expect(harness.model.armedMutation?.collisionWarning != nil)

        let fixture = HostedFixture(
            MutationGateView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)
        expectGateContained(WaveBControlID.collisionWarning, in: fixture.hosting)
        expectGateContained(WaveBControlID.mutationExecute, in: fixture.hosting)
    }

    @Test("the gate is replaced by an explicit notice while an unattended run is active")
    func unattendedGateDisabled() async throws {
        let runner = ScriptedRunner(outputs: [
            "{\"playlists\": [" + gateEntry(id: 10, name: "Alpha List", pid: "P-A", count: 4) + "]}",
            consolidateFixtureWire(name: "Alpha List"),
        ])
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false
        )
        defer { harness.cleanUp() }
        harness.model.setPauseOnJudgmentItems(true)
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-A")
        harness.model.startQueue()
        #expect(await pollUntil {
            harness.model.isUnattendedRunActive && !harness.model.isRunning
        })

        let fixture = HostedFixture(
            MutationGateView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)
        expectGateContained(WaveBControlID.unattendedNotice, in: fixture.hosting)
        #expect(view(under: fixture.hosting, axIdentifier: WaveBControlID.mutationExecute) == nil)
        #expect(view(under: fixture.hosting, axIdentifier: WaveBControlID.mutationNameField) == nil)
    }

    @Test("a failed execution renders the height-capped mismatch panel within bounds")
    func failedExecutionMismatchPanel() async throws {
        // The post-mutation listing still contains the doomed PID, so the
        // bijective readback reports verbatim mismatches (verified false).
        let runner = ScriptedRunner(outputs: [
            gateListingWire(),
            soloSnapshotWire(),
            gateListingWire(),
            "",
            "",
            gateListingWire(),
        ])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startMutationAudit(kind: .delete, persistentID: "SOLO000000000001")
        await harness.awaitMutation()
        harness.model.typedMutationName = "Solo List"
        harness.model.executeMutation()
        await harness.awaitMutation()
        guard case .finished(let display) = harness.model.mutationGatePhase else {
            Issue.record("expected a finished phase")
            return
        }
        #expect(!display.verified)
        #expect(!display.mismatches.isEmpty)

        let fixture = HostedFixture(
            MutationGateView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806, "mismatch panel must stay height-capped")
        expectGateContained(WaveBControlID.mutationDismiss, in: fixture.hosting)
        #expect(view(under: fixture.hosting, axIdentifier: WaveBControlID.mutationExecute) == nil)
    }
}
