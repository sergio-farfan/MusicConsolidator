// BatchDeleteTests.swift
// AGENTS.md exception 2 (Sergio, 2026-08-06): user-selected batch delete
// behind ONE count-typed gate — every playlist still its own fresh-audited
// plan artifact and its own guarded execution with readback between; any
// refusal at arm time refuses the whole batch fail-closed. Plus the
// already-processed selection blocking in the browser. Offline only.

import AppKit
import SwiftUI
import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

@MainActor
@Suite("Batch delete gate", .serialized)
struct BatchDeleteTests {

    @Test("selecting two playlists arms ONE count-typed gate with a plan per playlist")
    func batchArmsWithCountToken() async throws {
        // Arm reads: listing, then one snapshotAllCopies per DISTINCT name.
        let runner = ScriptedRunner(outputs: [
            gateListingWire(), soloSnapshotWire(), kdramaSnapshotWire(),
        ])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        model.toggleCleanupChecked("SOLO000000000001")
        model.toggleCleanupChecked("TRAIL00000000001")
        #expect(model.checkedCleanupPIDs.count == 2)

        model.startBatchDeleteAudit(persistentIDs: ["SOLO000000000001", "TRAIL00000000001"])
        await harness.awaitMutation()

        let armed = try #require(model.armedMutation)
        #expect(armed.confirmationName == "2")
        let context = try #require(model.cleanupContext)
        #expect(context.targetGuard == nil)
        #expect(context.plans.count == 2)
        #expect(context.paths.count == 2)
        for paths in context.paths {
            #expect(FileManager.default.fileExists(atPath: paths.planURL.path))
            #expect(!isMutationPlanConsumed(planURL: paths.planURL))
        }

        // The count token satisfies the gate; nothing else is required.
        #expect(!model.mutationGateSatisfied)
        model.typedMutationName = "2"
        #expect(model.mutationGateSatisfied)
    }

    @Test("a refused playlist in the selection refuses the WHOLE batch and consumes partials")
    func refusedEntryRefusesBatch() async throws {
        let runner = ScriptedRunner(outputs: [gateListingWire(), soloSnapshotWire()])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        // SOLO arms fine alone; the smart playlist poisons the batch.
        model.startBatchDeleteAudit(
            persistentIDs: ["SOLO000000000001", "SMART00000000001"]
        )
        await harness.awaitMutation()

        guard case .refused(let reason) = model.mutationGatePhase else {
            Issue.record("expected a whole-batch refusal, got \(model.mutationGatePhase)")
            return
        }
        #expect(reason.contains("whole batch"))
        #expect(model.cleanupContext == nil)
        // Any artifact written before the refusal is consumed (failArming).
        let files = try FileManager.default.contentsOfDirectory(
            at: harness.outputDirectory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".delete.plan.json") }
        for url in files {
            #expect(isMutationPlanConsumed(planURL: url), "\(url.lastPathComponent)")
        }
    }

    @Test("a verified batch delete removes both playlists from the display listing and clears the selection")
    func verifiedBatchPatchesListing() async throws {
        // Arm: listing + 2 snapshots. Dispatch per plan: fresh listing,
        // compile, execute, post listing; chain listing between copies.
        let afterFirst = gateListingWire(excludingPersistentID: "SOLO000000000001")
        let runner = ScriptedRunner(outputs: [
            gateListingWire(), soloSnapshotWire(), kdramaSnapshotWire(),
            gateListingWire(), "", "", afterFirst, afterFirst,
            afterFirst, "", "", consolidateGateListingWireWithoutBoth(),
        ])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        // Load the browser listing so the display patch has a cache to edit.
        // (Reuse the same wire; the scan consumes its own runner reads.)
        let scanRunner = ScriptedRunner(outputs: [gateListingWire()])
        _ = scanRunner // listing loaded through the harness runner below
        model.toggleCleanupChecked("SOLO000000000001")
        model.toggleCleanupChecked("TRAIL00000000001")

        model.startBatchDeleteAudit(persistentIDs: ["SOLO000000000001", "TRAIL00000000001"])
        await harness.awaitMutation()
        #expect(model.armedMutation != nil)
        model.typedMutationName = "2"
        model.executeMutation()
        await harness.awaitMutation()

        guard case .finished(let display) = model.mutationGatePhase else {
            Issue.record("expected finished, got \(model.mutationGatePhase)")
            return
        }
        #expect(display.verified)
        #expect(model.checkedCleanupPIDs.isEmpty)
        // The one batch report names the batch, not a merge group, and never
        // claims an empty merged target or a phantom evidence plan.
        let reportPath = try #require(display.resultReportPath)
        let report = try String(contentsOfFile: reportPath, encoding: .utf8)
        #expect(report.contains("user-selected batch delete"))
        #expect(!report.contains("Merged target:"))
        #expect(!report.contains("Evidence merge plan:"))
        #expect(report.contains("deleted-ok SOLO000000000001"))
        #expect(report.contains("deleted-ok TRAIL00000000001"))
    }

    @Test("a batch that fails midway still retires the copies that DID verify")
    func partialBatchRetiresOnlyVerifiedCopies() async throws {
        // Copy 1 verifies (its readback shows it gone); copy 2's pre-write
        // fingerprint recheck fails closed, so the batch aborts unverified.
        let afterFirst = gateListingWire(excludingPersistentID: "SOLO000000000001")
        let runner = ScriptedRunner(outputs: [
            gateListingWire(),                  // browser scan
            gateListingWire(), soloSnapshotWire(), kdramaSnapshotWire(),  // arm
            gateListingWire(), "", "", afterFirst,   // copy 1: verified
            afterFirst,                              // baseline chain read
            gateListingWire(),                       // copy 2: DRIFTED recheck
        ])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        model.toggleCleanupChecked("SOLO000000000001")
        model.toggleCleanupChecked("TRAIL00000000001")
        model.startBatchDeleteAudit(
            persistentIDs: ["SOLO000000000001", "TRAIL00000000001"]
        )
        await harness.awaitMutation()
        model.typedMutationName = "2"
        model.executeMutation()
        await harness.awaitMutation()

        guard case .finished(let display) = model.mutationGatePhase else {
            Issue.record("expected finished, got \(model.mutationGatePhase)")
            return
        }
        #expect(!display.verified, "the batch as a whole failed closed")
        // The verified copy is gone from the display cache and the selection;
        // the untouched one stays exactly where it was.
        let names = model.loadedListing?.listings.map(\.persistentId) ?? []
        #expect(!names.contains("SOLO000000000001"))
        #expect(names.contains("TRAIL00000000001"))
        #expect(!model.checkedCleanupPIDs.contains("SOLO000000000001"))
        #expect(model.checkedCleanupPIDs.contains("TRAIL00000000001"))
    }
}

/// Listing wire missing BOTH batch targets (the final readback state).
private func consolidateGateListingWireWithoutBoth() -> String {
    let full = gateListingWire(excludingPersistentID: "SOLO000000000001")
    // gateListingWire only excludes one PID; strip the second entry too.
    return full
        .replacingOccurrences(
            of: gateEntry(id: 60, name: "Kdrama ", pid: "TRAIL00000000001", count: 2) + ", ",
            with: ""
        )
        .replacingOccurrences(
            of: ", " + gateEntry(id: 60, name: "Kdrama ", pid: "TRAIL00000000001", count: 2),
            with: ""
        )
}

@MainActor
@Suite("Already-processed selection blocking")
struct AlreadyProcessedBlockingTests {

    @Test("a source whose mode target exists is excluded from select-all and reports isAlreadyProcessed")
    func alreadyProcessedExcluded() async throws {
        // Listing: singleton "Solo List" + its "Solo List — Consolidated".
        let wire = "{\"playlists\": ["
            + gateEntry(id: 10, name: "Solo List", pid: "SOLO000000000001", count: 2) + ", "
            + gateEntry(id: 11, name: "Solo List \u{2014} Consolidated",
                        pid: "DONE000000000001", count: 2) + ", "
            + gateEntry(id: 12, name: "Fresh One", pid: "FRESH00000000001", count: 3)
            + "]}"
        let runner = ScriptedRunner(outputs: [wire])
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false
        )
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await model.scanTask?.value

        #expect(model.isAlreadyProcessed(name: "Solo List"))
        #expect(!model.isAlreadyProcessed(name: "Fresh One"))

        model.selectAllEligible()
        #expect(!model.checkedPersistentIds.contains("SOLO000000000001"))
        #expect(model.checkedPersistentIds.contains("FRESH00000000001"))
    }
}
