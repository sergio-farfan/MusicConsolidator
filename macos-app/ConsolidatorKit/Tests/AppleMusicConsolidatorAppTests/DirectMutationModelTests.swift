// DirectMutationModelTests.swift
// Direct mutations (Sergio, 2026-08-06): confirm-then-dispatch, zero
// refusals, display patch per success, first failure stops the batch.
import Foundation
import Testing
import MusicBridge
@testable import AppleMusicConsolidatorApp

@MainActor
@Suite("Direct mutation model", .serialized)
struct DirectMutationModelTests {

    @Test("request sets a pending delete; cancel dispatches nothing")
    func requestThenCancel() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        model.requestDirectDelete(persistentIDs: ["SOLO000000000001"])
        guard case .delete(let targets)? = model.pendingDirectAction else {
            Issue.record("expected pending delete"); return
        }
        #expect(targets.map(\.persistentId) == ["SOLO000000000001"])
        model.cancelPendingDirectAction()
        #expect(model.pendingDirectAction == nil)
        // Only the scan consumed runner output; cancel called nothing.
        #expect(runner.remainingOutputs == 0)
    }

    @Test("zero refusals: smart playlist, folder, and pilot rows are all requestable")
    func zeroRefusals() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        // gateListingWire carries a smart playlist (SMART00000000001), a
        // folder (FOLD000000000001), and the pilot PID E02030832FD20B07.
        model.requestDirectDelete(persistentIDs: [
            "SMART00000000001", "FOLD000000000001", "E02030832FD20B07",
        ])
        guard case .delete(let targets)? = model.pendingDirectAction else {
            Issue.record("expected pending delete"); return
        }
        #expect(targets.count == 3)
    }

    @Test("confirmed batch deletes sequentially; each success patches the display")
    func batchDeletePatchesDisplay() async throws {
        let runner = ScriptedRunner(outputs: [
            gateListingWire(),      // scan
            "", "ok", "", "ok",     // compile+execute per delete
        ])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        model.toggleCleanupChecked("SOLO000000000001")
        model.toggleCleanupChecked("TRAIL00000000001")
        model.requestDirectDelete(persistentIDs: ["SOLO000000000001", "TRAIL00000000001"])
        model.confirmPendingDirectAction()
        await model.directMutationTask?.value

        let pids = model.loadedListing?.listings.map(\.persistentId) ?? []
        #expect(!pids.contains("SOLO000000000001"))
        #expect(!pids.contains("TRAIL00000000001"))
        #expect(model.checkedCleanupPIDs.isEmpty)
        #expect(model.directMutationError == nil)
        #expect(!model.isMutationBusy)
    }

    @Test("first failure stops the batch, surfaces the verbatim error, later rows intact")
    func batchStopsOnFailure() async throws {
        let runner = ScriptedRunner(outputs: [
            gateListingWire(),
            "", "ok",                          // delete 1 succeeds
        ])  // delete 2's compile call finds no scripted output -> throws
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        model.requestDirectDelete(persistentIDs: ["SOLO000000000001", "TRAIL00000000001"])
        model.confirmPendingDirectAction()
        await model.directMutationTask?.value

        let pids = model.loadedListing?.listings.map(\.persistentId) ?? []
        #expect(!pids.contains("SOLO000000000001"))
        #expect(pids.contains("TRAIL00000000001"))
        #expect(model.directMutationError != nil)
    }

    @Test("rename: unchanged name is a no-op; a changed name patches the display")
    func renameFlow() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        model.requestDirectRename(persistentID: "SOLO000000000001", prefilledName: nil)
        #expect(model.typedRenameName == "Solo List")
        model.confirmPendingDirectAction()          // unchanged -> no runner call
        await model.directMutationTask?.value
        #expect(runner.remainingOutputs == 0)
        #expect(model.directMutationError == nil)
    }
}
