// DirectMutationModelTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Direct mutations (Sergio, 2026-08-06): confirm-then-dispatch, zero
// refusals, display patch per success, first failure stops the batch.
import Foundation
import Testing
import ConsolidatorCore
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

    // Final fix wave, Finding I3: `renameInLoadedListing` (the display-cache
    // patch after a VERIFIED direct rename) had no covering test — the half
    // above only proves the no-op path. This drives a real changed-name
    // rename and pins both the patched row AND the rebuilt browse sections
    // (the row must still resolve through them, under its new name).
    @Test("a changed name patches the display row and rebuilds the browse sections")
    func renameChangedNamePatchesDisplay() async throws {
        let runner = ScriptedRunner(outputs: [
            gateListingWire(),      // browser scan
            "", "ok",               // compile + execute, one rename
        ])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value
        let sectionsBefore = try #require(model.loadedListing?.sections)
        #expect(sectionsBefore.singletons.contains { scalarExact($0.name, "Solo List") })

        model.requestDirectRename(persistentID: "SOLO000000000001", prefilledName: nil)
        model.typedRenameName = "Solo List Renamed"
        model.confirmPendingDirectAction()
        await model.directMutationTask?.value

        #expect(model.directMutationError == nil)
        #expect(runner.remainingOutputs == 0, "exactly one compile + one execute")
        let listings = try #require(model.loadedListing?.listings)
        let patched = try #require(
            listings.first { scalarExact($0.persistentId, "SOLO000000000001") }
        )
        #expect(scalarExact(patched.name, "Solo List Renamed"))
        #expect(!listings.contains { scalarExact($0.name, "Solo List") })
        // Sections rebuilt from the patched listings: the row still resolves,
        // under the new name, in both the flat list and the singleton class.
        let sections = try #require(model.loadedListing?.sections)
        #expect(sections.allPlaylists.contains {
            scalarExact($0.persistentId, "SOLO000000000001")
                && scalarExact($0.name, "Solo List Renamed")
        })
        #expect(sections.singletons.contains { scalarExact($0.name, "Solo List Renamed") })
        #expect(!sections.singletons.contains { scalarExact($0.name, "Solo List") })
        #expect(!model.isMutationBusy)
    }

    // Final fix wave, Finding I2: arbitrary time passes between staging and
    // confirm, so the confirm must RE-check the busy set. Here a rescan
    // claims the OSA slot after the sheet is already open: the confirm must
    // refuse, cancel the stale confirmation, and dispatch nothing.
    @Test("a confirm that arrives after another activity claimed the OSA slot is refused, not queued")
    func confirmRefusedWhenSlotTaken() async throws {
        let runner = StagedBlockingRunner(
            outputs: [gateListingWire(), gateListingWire()], blockAt: [1]
        )
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        model.requestDirectDelete(persistentIDs: ["SOLO000000000001"])
        #expect(model.pendingDirectAction != nil)

        // A second scan takes the slot while the confirm sheet sits open.
        model.rescanLibrary()
        #expect(await pollUntil { runner.runCount == 2 })
        #expect(model.isScanning)

        model.confirmPendingDirectAction()
        #expect(model.pendingDirectAction == nil, "the stale confirmation is cancelled")
        #expect(model.directMutationTask == nil, "nothing may be dispatched")
        #expect(!model.isDirectMutationRunning)
        #expect(runner.runCount == 2, "no compile/execute call was made")

        runner.proceed.signal()
        await model.scanTask?.value
        // The playlist is untouched, and the error channel stayed silent.
        #expect(model.loadedListing?.listings.contains {
            scalarExact($0.persistentId, "SOLO000000000001")
        } == true)
        #expect(model.directMutationError == nil)
    }

    // Final fix wave, Finding I2 (the re-entrancy test the ledger deferred):
    // while a batch is in flight, a second request must no-op and a stale
    // confirm must never double-dispatch.
    @Test("while a batch is in flight, a second request no-ops and a stale confirm never double-dispatches")
    func noReentrancyWhileBatchInFlight() async throws {
        let runner = StagedBlockingRunner(
            outputs: [gateListingWire(), "", "ok", "", "ok"], blockAt: [1]
        )
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        model.requestDirectDelete(persistentIDs: ["SOLO000000000001", "TRAIL00000000001"])
        model.confirmPendingDirectAction()
        // Held inside the first delete's compile call.
        #expect(await pollUntil { runner.runCount == 2 })
        #expect(model.isDirectMutationRunning)
        #expect(model.isMutationBusy)

        model.requestDirectDelete(persistentIDs: ["SAME000000003333"])
        #expect(model.pendingDirectAction == nil, "a second request must no-op mid-batch")
        model.confirmPendingDirectAction()
        #expect(runner.runCount == 2, "no second dispatch may start mid-batch")

        runner.proceed.signal()
        await model.directMutationTask?.value
        #expect(model.directMutationError == nil)
        #expect(!model.isDirectMutationRunning)
        // Exactly the two staged deletes ran: 1 scan + 2 x (compile, execute).
        #expect(runner.runCount == 5)
        let pids = model.loadedListing?.listings.map(\.persistentId) ?? []
        #expect(!pids.contains("SOLO000000000001"))
        #expect(!pids.contains("TRAIL00000000001"))
        #expect(pids.contains("SAME000000003333"))
    }
}
