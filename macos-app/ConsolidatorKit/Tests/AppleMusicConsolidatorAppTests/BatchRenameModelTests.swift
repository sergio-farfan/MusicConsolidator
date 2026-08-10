// BatchRenameModelTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Batch rename (Sergio, 2026-08-06): the model layer for a multi-playlist
// rename dispatched straight from the cleanup UI — a `.batchRename` pending
// action, per-row drafts seeded from the live listing, a literal find/replace
// fill helper, and the same confirm-then-dispatch shape as `.delete`: skip
// unchanged/empty drafts (no runner call), sequential otherwise, first
// failure stops the batch and surfaces the verbatim error.
import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

/// A wire fixture the standing `gateListingWire()` doesn't carry: two rows
/// whose names end in the " \u{2014} Merged" suffix the fill-helper test
/// needs, plus one untouched row. Built inline from `gateEntry` per the task
/// brief — the shared fixture is never modified.
private func mergedSuffixWire() -> String {
    let entries = [
        gateEntry(id: 1, name: "Dark OST \u{2014} Merged", pid: "MERGE0000000001", count: 3),
        gateEntry(id: 2, name: "GO \u{2014} Merged", pid: "MERGE0000000002", count: 4),
        gateEntry(id: 3, name: "Untouched", pid: "MERGE0000000003", count: 1),
    ]
    return "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

@MainActor
@Suite("Batch rename model", .serialized)
struct BatchRenameModelTests {

    @Test("requestDirectBatchRename seeds drafts with current names in selection order; busy state no-ops")
    func requestSeedsDraftsAndBusyNoOps() async throws {
        let runner = StagedBlockingRunner(
            outputs: [gateListingWire(), gateListingWire()], blockAt: [1]
        )
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        // Selection order deliberately reversed vs. the listing's own order.
        model.requestDirectBatchRename(persistentIDs: ["TWIN00000000BBBB", "SOLO000000000001"])
        guard case .batchRename(let targets)? = model.pendingDirectAction else {
            Issue.record("expected pending batch rename"); return
        }
        #expect(targets.map(\.persistentId) == ["TWIN00000000BBBB", "SOLO000000000001"])
        #expect(model.batchRenameDrafts["TWIN00000000BBBB"] == "Twin")
        #expect(model.batchRenameDrafts["SOLO000000000001"] == "Solo List")
        model.cancelPendingDirectAction()
        #expect(model.pendingDirectAction == nil)
        #expect(model.batchRenameDrafts.isEmpty)

        // Busy: a second scan holds the OSA slot -> the request no-ops
        // entirely, mirroring `requestDirectDelete`'s busy guard.
        model.rescanLibrary()
        #expect(await pollUntil { runner.runCount == 2 })
        #expect(model.isScanning)
        model.requestDirectBatchRename(persistentIDs: ["SOLO000000000001"])
        #expect(model.pendingDirectAction == nil)
        #expect(model.batchRenameDrafts.isEmpty)

        runner.proceed.signal()
        await model.scanTask?.value
    }

    @Test("applyBatchRenameReplacement is literal and composes on the result; empty find is a no-op")
    func fillHelperIsLiteralAndComposes() async throws {
        let runner = ScriptedRunner(outputs: [mergedSuffixWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        model.requestDirectBatchRename(persistentIDs: [
            "MERGE0000000001", "MERGE0000000002", "MERGE0000000003",
        ])
        model.applyBatchRenameReplacement(find: " \u{2014} Merged", replaceWith: "")
        #expect(model.batchRenameDrafts["MERGE0000000001"] == "Dark OST")
        #expect(model.batchRenameDrafts["MERGE0000000002"] == "GO")
        #expect(model.batchRenameDrafts["MERGE0000000003"] == "Untouched")

        // A second replacement composes on the RESULT of the first.
        model.applyBatchRenameReplacement(
            find: "Dark OST", replaceWith: "Dark Original Soundtrack"
        )
        #expect(model.batchRenameDrafts["MERGE0000000001"] == "Dark Original Soundtrack")

        // Empty find is a no-op.
        let before = model.batchRenameDrafts
        model.applyBatchRenameReplacement(find: "", replaceWith: "whatever")
        #expect(model.batchRenameDrafts == before)
        #expect(runner.remainingOutputs == 0)
    }

    @Test("confirm with all drafts unchanged dispatches nothing and finishes idle")
    func confirmAllUnchangedDispatchesNothing() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        model.requestDirectBatchRename(persistentIDs: ["SOLO000000000001", "TRAIL00000000001"])
        #expect(model.batchRenameChangedCount == 0)
        model.confirmPendingDirectAction()
        await model.directMutationTask?.value

        #expect(runner.remainingOutputs == 0)
        #expect(model.directMutationError == nil)
        #expect(!model.isDirectMutationRunning)
        #expect(!model.isMutationBusy)
        #expect(model.batchRenameDrafts.isEmpty)
    }

    @Test("confirm dispatches exactly the changed drafts, patches display by PID, skips the rest")
    func confirmDispatchesChangedOnly() async throws {
        let runner = ScriptedRunner(outputs: [
            gateListingWire(),
            "", "ok", // compile + execute, rename 1
            "", "ok", // compile + execute, rename 2
        ])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        model.requestDirectBatchRename(persistentIDs: [
            "SOLO000000000001", "TWIN00000000AAAA", "TWIN00000000BBBB", "SAME000000003333",
        ])
        model.setBatchRenameDraft("Solo List Renamed", for: "SOLO000000000001")
        model.setBatchRenameDraft("Twin A Renamed", for: "TWIN00000000AAAA")
        // TWIN00000000BBBB left unchanged (still "Twin").
        model.setBatchRenameDraft("", for: "SAME000000003333")
        #expect(model.batchRenameChangedCount == 2)

        model.confirmPendingDirectAction()
        await model.directMutationTask?.value

        #expect(runner.remainingOutputs == 0)
        #expect(model.directMutationError == nil)
        let listings = try #require(model.loadedListing?.listings)
        #expect(listings.contains {
            scalarExact($0.persistentId, "SOLO000000000001") && scalarExact($0.name, "Solo List Renamed")
        })
        #expect(listings.contains {
            scalarExact($0.persistentId, "TWIN00000000AAAA") && scalarExact($0.name, "Twin A Renamed")
        })
        #expect(listings.contains {
            scalarExact($0.persistentId, "TWIN00000000BBBB") && scalarExact($0.name, "Twin")
        })
        #expect(listings.contains {
            scalarExact($0.persistentId, "SAME000000003333") && scalarExact($0.name, "Twinsame")
        })
        #expect(model.batchRenameDrafts.isEmpty)
        #expect(!model.isDirectMutationRunning)
    }

    @Test("first failure stops the batch, surfaces the verbatim error, later targets' names untouched")
    func confirmStopsOnFirstFailure() async throws {
        let runner = ScriptedRunner(outputs: [
            gateListingWire(),
            "", "ok", // rename 1 succeeds
        ]) // rename 2's compile call finds no scripted output -> throws
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        model.requestDirectBatchRename(persistentIDs: ["SOLO000000000001", "TWIN00000000AAAA"])
        model.setBatchRenameDraft("Solo List Renamed", for: "SOLO000000000001")
        model.setBatchRenameDraft("Twin A Renamed", for: "TWIN00000000AAAA")

        model.confirmPendingDirectAction()
        await model.directMutationTask?.value

        #expect(model.directMutationError != nil)
        let listings = try #require(model.loadedListing?.listings)
        #expect(listings.contains {
            scalarExact($0.persistentId, "SOLO000000000001") && scalarExact($0.name, "Solo List Renamed")
        })
        #expect(listings.contains {
            scalarExact($0.persistentId, "TWIN00000000AAAA") && scalarExact($0.name, "Twin")
        })
        #expect(!model.isDirectMutationRunning)
    }
}
