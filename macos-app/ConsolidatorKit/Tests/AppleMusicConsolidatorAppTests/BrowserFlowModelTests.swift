// BrowserFlowModelTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// M8 — headless model tests for the sectioned source browser and the
// consolidate batch queue: listing rescan (single-flight, generation-
// guarded, mutually exclusive with audits), merge batch-queueing from checked groups
// selection (groups only, by construction), the queue state machine
// (pending → audited → applied / skipped / failed; per-item plan review +
// confirm gate + in-app apply since M9, NO bulk approve), and the
// confirm-gate near-miss diagnostics. All Music I/O is scripted through
// fakes; nothing executes any script.

import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

// MARK: - listing wire fixtures

private func listingEntryWire(
    id: Int,
    name: String,
    pid: String,
    trackCount: Int = 10,
    smart: Bool = false,
    specialKind: String = "none"
) -> String {
    """
    {"id": \(id), "name": "\(jsonEscaped(name))", "persistent_id": "\(jsonEscaped(pid))", \
    "track_count": \(trackCount), "smart": \(smart), "special_kind": "\(jsonEscaped(specialKind))"}
    """
}

private func listingWire(_ entries: [String]) -> String {
    "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

/// A listing matching the audit fixtures in AppTestSupport: one mergeable
/// group ("Merge List" x2), two consolidatable singletons ("Fixture List",
/// "Solo List"), and one trailing-space twin pair.
private func browserListingWire() -> String {
    listingWire([
        listingEntryWire(id: 20, name: "Merge List", pid: "C-HIGH", trackCount: 2),
        listingEntryWire(id: 10, name: "Merge List", pid: "C-LOW", trackCount: 2),
        listingEntryWire(id: 30, name: "Fixture List", pid: "P-FIX", trackCount: 4),
        listingEntryWire(id: 40, name: "Solo List", pid: "P-SOLO", trackCount: 4),
        listingEntryWire(id: 50, name: "Kdrama", pid: "P-KD", trackCount: 7),
        listingEntryWire(id: 60, name: "Kdrama ", pid: "P-KD2", trackCount: 9),
    ])
}

@MainActor
private func awaitScan(_ model: AuditFlowModel) async {
    await model.scanTask?.value
}

// MARK: - rescan

@MainActor
@Suite("Library rescan")
struct LibraryRescanTests {

    @Test("rescan loads sections through the static listing script")
    func rescanLoadsSections() async throws {
        let runner = ScriptedRunner(outputs: [browserListingWire()])
        let harness = try ModelHarness(runner: runner, mode: .merge)
        defer { harness.cleanUp() }

        harness.model.rescanLibrary()
        #expect(harness.model.isScanning)
        await awaitScan(harness.model)

        #expect(!harness.model.isScanning)
        let sections = try #require(harness.model.loadedSections)
        #expect(sections.groups.map(\.name) == ["Merge List"])
        #expect(sections.groups[0].copies.map(\.persistentId) == ["C-LOW", "C-HIGH"])
        #expect(sections.singletons.map(\.name) == ["Fixture List", "Kdrama", "Kdrama ", "Solo List"])
        #expect(sections.nearMatches.map(\.normalizedName) == ["Kdrama"])
        #expect(runner.commands == [.readJXA(script: buildListPlaylistsJXA())])
    }

    @Test("rescan failure surfaces the verbatim message under its class")
    func rescanFailure() async throws {
        let runner = ScriptedRunner(results: [.failure(MusicCommandError("Music automation failed: boom"))])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }

        harness.model.rescanLibrary()
        await awaitScan(harness.model)

        guard case .failed(let failure) = harness.model.listingState else {
            Issue.record("expected failed listing state")
            return
        }
        #expect(failure.category == "Automation failed")
        #expect(failure.message == "Music automation failed: boom")
        #expect(harness.model.loadedSections == nil)
    }

    @Test("rescan is single-flight and refuses to overlap an audit")
    func rescanMutualExclusion() async throws {
        let blocking = BlockingRunner(payload: consolidateFixtureWire())
        let harness = try ModelHarness(runner: blocking)
        defer { harness.cleanUp() }

        harness.model.startAudit()
        let started = await pollUntil { blocking.runCount == 1 }
        #expect(started)

        // An audit read is in flight: rescanning must be a no-op.
        harness.model.rescanLibrary()
        #expect(harness.model.scanTask == nil)
        if case .idle = harness.model.listingState {} else {
            Issue.record("listing state must stay idle while an audit runs")
        }

        blocking.proceed.signal()
        await harness.awaitAudit()
    }

    @Test("an audit refuses to start while a scan is in flight")
    func auditRefusesDuringScan() async throws {
        let blocking = BlockingRunner(payload: browserListingWire())
        let harness = try ModelHarness(runner: blocking)
        defer { harness.cleanUp() }

        harness.model.rescanLibrary()
        let started = await pollUntil { blocking.runCount == 1 }
        #expect(started)

        harness.model.startAudit()
        #expect(harness.model.auditTask == nil)
        #expect(!harness.model.isRunning)

        blocking.proceed.signal()
        await awaitScan(harness.model)
        #expect(harness.model.loadedSections != nil)
    }
}

// MARK: - merge batch queue (M10)

/// Two mergeable groups (alphabetical section order: Argentos before Merge
/// List), a trailing-space near-match pair, and a singleton — the M10
/// multi-group fixtures.
private func twoGroupListingWire() -> String {
    listingWire([
        listingEntryWire(id: 20, name: "Merge List", pid: "C-HIGH", trackCount: 2),
        listingEntryWire(id: 10, name: "Merge List", pid: "C-LOW", trackCount: 2),
        listingEntryWire(id: 50, name: "Argentos", pid: "A-LOW", trackCount: 2),
        listingEntryWire(id: 60, name: "Argentos", pid: "A-HIGH", trackCount: 2),
        listingEntryWire(id: 30, name: "Solo List", pid: "P-SOLO", trackCount: 4),
        listingEntryWire(id: 70, name: "Kdrama", pid: "P-KD", trackCount: 7),
        listingEntryWire(id: 80, name: "Kdrama ", pid: "P-KD2", trackCount: 9),
    ])
}

@MainActor
@Suite("Merge batch queue (M10)")
struct MergeBatchQueueTests {

    @Test("only mergeable groups are checkable; checking never disturbs the selection")
    func onlyGroupsCheck() async throws {
        let runner = ScriptedRunner(outputs: [twoGroupListingWire()])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await awaitScan(harness.model)

        // Non-groups are model-level no-ops (near-match variants, singletons,
        // and names absent from the listing).
        harness.model.toggleCheckedGroup(name: "Kdrama")
        harness.model.toggleCheckedGroup(name: "Kdrama ")
        harness.model.toggleCheckedGroup(name: "Solo List")
        harness.model.toggleCheckedGroup(name: "Absent")
        #expect(harness.model.checkedGroupNames.isEmpty)

        // Checking a group is independent of the single-select highlight
        // (selection stays inspection-only).
        harness.model.browserSelection = .singleton("P-SOLO")
        harness.model.toggleCheckedGroup(name: "Argentos")
        #expect(harness.model.checkedGroupNames == ["Argentos"])
        #expect(harness.model.browserSelection == .singleton("P-SOLO"))
        #expect(harness.model.isGroupChecked("Argentos"))
        #expect(!harness.model.isGroupChecked("Merge List"))

        // Toggling off works.
        harness.model.toggleCheckedGroup(name: "Argentos")
        #expect(harness.model.checkedGroupNames.isEmpty)
    }

    @Test("checked groups build the queue in section (alphabetical) order")
    func mergeQueueBuilding() async throws {
        let runner = ScriptedRunner(outputs: [
            twoGroupListingWire(),
            mergeFixtureWire(name: "Argentos"),
        ])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await awaitScan(harness.model)

        // Checked in reverse order; the queue follows the section order.
        harness.model.toggleCheckedGroup(name: "Merge List")
        harness.model.toggleCheckedGroup(name: "Argentos")
        harness.model.startQueue()
        #expect(harness.model.isQueueActive)
        #expect(harness.model.queue.map(\.name) == ["Argentos", "Merge List"])
        #expect(harness.model.queue.map(\.status) == [.pending, .pending])

        await harness.awaitAudit()
        #expect(harness.model.queue.map(\.status) == [.audited, .pending])
        let result = try #require(harness.model.result)
        #expect(result.mode == .merge)
        #expect(result.sourceName == "Argentos")
        #expect(harness.model.targetName == "Argentos \u{2014} Merged")
    }

    @Test("two full merge applies in sequence, each from its own artifact")
    func mergeQueueFullRun() async throws {
        let runner = ScriptedRunner(outputs:
            [twoGroupListingWire(), mergeFixtureWire(name: "Argentos")]
                + mergeApplyOutputs(name: "Argentos")
                + [mergeFixtureWire(name: "Merge List")]
                + mergeApplyOutputs(name: "Merge List")
        )
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await awaitScan(model)
        model.toggleCheckedGroup(name: "Argentos")
        model.toggleCheckedGroup(name: "Merge List")
        model.startQueue()
        await harness.awaitAudit()

        // Item 1: per-item gate (typed target name), per-item apply from
        // its OWN persisted artifact.
        let firstPlanPath = try #require(model.result?.paths.planJson)
        model.reviewedPlanToggle = true
        model.typedTargetName = try #require(model.targetName)
        model.startApply()
        await harness.awaitApply()
        #expect(model.queue.map(\.status) == [.applied, .pending])
        if case .succeeded(let success) = model.applyState {
            #expect(success.mode == .merge)
            #expect(success.targetName == "Argentos \u{2014} Merged")
            #expect(success.paths.planJson == firstPlanPath)
        } else {
            Issue.record("item 1 apply did not succeed: \(model.applyState)")
        }
        // The item-1 apply re-read ITS group by exact name.
        #expect(runner.commands[2] == .readJXA(script: buildReadJXA(name: "Argentos")))

        model.continueQueueAfterApply()
        await harness.awaitAudit()
        #expect(model.queue.map(\.status) == [.applied, .audited])
        #expect(model.result?.sourceName == "Merge List")
        let secondPlanPath = try #require(model.result?.paths.planJson)
        #expect(secondPlanPath != firstPlanPath)
        // The next item's gate and apply start clean.
        #expect(model.reviewedPlanToggle == false)
        if case .idle = model.applyState {} else {
            Issue.record("item 2 must start with an idle apply state")
        }

        // Item 2: its own gate + apply; the queue completes.
        model.reviewedPlanToggle = true
        model.typedTargetName = try #require(model.targetName)
        model.startApply()
        await harness.awaitApply()
        #expect(model.queue.map(\.status) == [.applied, .applied])
        model.continueQueueAfterApply()
        #expect(model.isQueueComplete)

        // Transcript shape: listing + 2 x (audit read + 6 apply commands).
        #expect(runner.commands.count == 15)
        #expect(runner.commands[8] == .readJXA(script: buildReadJXA(name: "Merge List")))
    }

    @Test("a mid-queue merge apply failure marks the item failed; retry is a fresh audit")
    func mergeQueueMidFailureRetry() async throws {
        let runner = ScriptedRunner(results: [
            .success(twoGroupListingWire()),
            .success(mergeFixtureWire(name: "Argentos")),
            .failure(MusicCommandError("merge apply blew up")),
            .success(mergeFixtureWire(name: "Argentos")),
        ])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await awaitScan(model)
        model.toggleCheckedGroup(name: "Argentos")
        model.startQueue()
        await harness.awaitAudit()
        #expect(model.queue.map(\.status) == [.audited])

        model.reviewedPlanToggle = true
        model.typedTargetName = try #require(model.targetName)
        model.startApply()
        await harness.awaitApply()
        #expect(model.queue.map(\.status) == [.failed])
        if case .failed(let failure) = model.applyState {
            #expect(failure.failureClass == .automationFailed)
            #expect(failure.message == "merge apply blew up")
        } else {
            Issue.record("expected a failed apply state")
        }

        model.retryCurrentQueueItem()
        await harness.awaitAudit()
        #expect(model.queue.map(\.status) == [.audited])
        #expect(model.result?.sourceName == "Argentos")
    }

    @Test("skip works pre-apply and is refused over an applied merge item")
    func mergeQueueSkipGuards() async throws {
        let runner = ScriptedRunner(outputs:
            [twoGroupListingWire(), mergeFixtureWire(name: "Argentos")]
                + mergeApplyOutputs(name: "Argentos")
        )
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await awaitScan(model)
        model.toggleCheckedGroup(name: "Merge List")
        model.toggleCheckedGroup(name: "Argentos")
        model.startQueue()
        await harness.awaitAudit()

        // Apply item 1, then Skip must refuse (the write happened).
        model.reviewedPlanToggle = true
        model.typedTargetName = try #require(model.targetName)
        model.startApply()
        await harness.awaitApply()
        #expect(model.queue.map(\.status) == [.applied, .pending])
        model.skipCurrentQueueItem()
        #expect(model.queue.map(\.status) == [.applied, .pending])

        // Continue advances; skipping the (pending -> audited-less) second
        // item works: no more outputs, so its audit fails; skip from failed
        // is legal via the rail's Skip.
        model.continueQueueAfterApply()
        await harness.awaitAudit()
        #expect(model.queue[1].status == .failed) // no scripted output left
        model.skipCurrentQueueItem()
        #expect(model.queue.map(\.status) == [.applied, .skipped])
        #expect(model.isQueueComplete)
    }

    @Test("queue guards: empty checks, wrong mode, and busy states all refuse")
    func mergeQueueStartGuards() async throws {
        let blocking = BlockingRunner(payload: twoGroupListingWire())
        let harness = try ModelHarness(runner: blocking, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        let model = harness.model

        // Nothing loaded yet: refused.
        model.startQueue()
        #expect(!model.isQueueActive)

        // While the scan is in flight: refused even with checks (none yet).
        model.rescanLibrary()
        #expect(await pollUntil { blocking.runCount == 1 })
        model.startQueue()
        #expect(!model.isQueueActive)
        blocking.proceed.signal()
        await awaitScan(model)

        // Empty checks: refused.
        model.startQueue()
        #expect(!model.isQueueActive)

        // Consolidate mode ignores GROUP checks entirely (mixed-mode queues
        // are out: each mode's queue builds only from its own checks).
        model.toggleCheckedGroup(name: "Argentos")
        model.setMode(.consolidate)
        model.startQueue()
        #expect(!model.isQueueActive)

        // The group checks survived the mode switch; back in merge mode the
        // queue starts. The blocking runner replays the LISTING payload for
        // the item's audit read — release it; the strict parse fails closed
        // (no tracks key), which is fine: this test pins the START gates.
        model.setMode(.merge)
        #expect(model.checkedGroupNames == ["Argentos"])
        model.startQueue()
        #expect(model.isQueueActive)
        blocking.proceed.signal()
        await harness.awaitAudit()
        #expect(model.queue.map(\.status) == [.failed])
    }

    @Test("a rescan prunes checked groups that no longer resolve")
    func rescanPrunesCheckedGroups() async throws {
        // Second scan: Argentos lost a copy (now a singleton) — its check
        // must be pruned; Merge List survives.
        let secondListing = listingWire([
            listingEntryWire(id: 20, name: "Merge List", pid: "C-HIGH", trackCount: 2),
            listingEntryWire(id: 10, name: "Merge List", pid: "C-LOW", trackCount: 2),
            listingEntryWire(id: 50, name: "Argentos", pid: "A-LOW", trackCount: 2),
        ])
        let runner = ScriptedRunner(outputs: [twoGroupListingWire(), secondListing])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        let model = harness.model
        model.rescanLibrary()
        await awaitScan(model)
        model.toggleCheckedGroup(name: "Argentos")
        model.toggleCheckedGroup(name: "Merge List")

        model.rescanLibrary()
        await awaitScan(model)
        #expect(model.checkedGroupNames == ["Merge List"])
    }
}

// MARK: - consolidate queue

@MainActor
@Suite("Consolidate batch queue")
struct ConsolidateQueueTests {

    private func loadedHarness(outputs: [String]) async throws -> (ModelHarness, ScriptedRunner) {
        let runner = ScriptedRunner(outputs: outputs)
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        harness.model.rescanLibrary()
        await awaitScan(harness.model)
        return (harness, runner)
    }

    @Test("checked singletons build the queue in alphabetical order; group members are ineligible")
    func queueBuilding() async throws {
        let (harness, _) = try await loadedHarness(outputs: [
            browserListingWire(),
            consolidateFixtureWire(name: "Fixture List"),
        ])
        defer { harness.cleanUp() }

        harness.model.toggleChecked(persistentId: "P-SOLO")
        harness.model.toggleChecked(persistentId: "P-FIX")
        // Group members and unknown ids are model-level no-ops (consolidate
        // fails closed on ambiguous names; the engine's own guard).
        harness.model.toggleChecked(persistentId: "C-LOW")
        harness.model.toggleChecked(persistentId: "P-NONE")
        #expect(harness.model.checkedPersistentIds == ["P-SOLO", "P-FIX"])

        harness.model.startQueue()
        #expect(harness.model.isQueueActive)
        #expect(harness.model.queue.map(\.name) == ["Fixture List", "Solo List"])
        #expect(harness.model.queue.map(\.status) == [.pending, .pending])

        await harness.awaitAudit()
        #expect(harness.model.queue.map(\.status) == [.audited, .pending])
        #expect(harness.model.result?.sourceName == "Fixture List")
    }

    @Test("a verified apply completes an item; continue auto-starts the next audit")
    func applyAdvances() async throws {
        let (harness, _) = try await loadedHarness(outputs:
            [browserListingWire(), consolidateFixtureWire(name: "Fixture List")]
                + consolidateApplyOutputs(name: "Fixture List")
                + [consolidateFixtureWire(name: "Solo List")]
                + consolidateApplyOutputs(name: "Solo List")
        )
        defer { harness.cleanUp() }

        harness.model.toggleChecked(persistentId: "P-FIX")
        harness.model.toggleChecked(persistentId: "P-SOLO")
        harness.model.startQueue()
        await harness.awaitAudit()

        // Item 1: satisfy the per-plan confirm gate (no bulk approve),
        // then run ITS OWN apply (M9 — no hand-off state anymore).
        harness.model.reviewedPlanToggle = true
        harness.model.typedTargetName = try #require(harness.model.targetName)
        #expect(harness.model.canApply)
        harness.model.startApply()
        await harness.awaitApply()
        #expect(harness.model.queue[0].status == .applied)

        harness.model.continueQueueAfterApply()
        await harness.awaitAudit()

        #expect(harness.model.queue[1].status == .audited)
        #expect(harness.model.result?.sourceName == "Solo List")
        // The new item's gate starts clean.
        #expect(harness.model.reviewedPlanToggle == false)
        #expect(harness.model.typedTargetName.isEmpty)

        // Item 2: apply as well; the queue completes.
        harness.model.reviewedPlanToggle = true
        harness.model.typedTargetName = try #require(harness.model.targetName)
        harness.model.startApply()
        await harness.awaitApply()
        harness.model.continueQueueAfterApply()
        #expect(harness.model.queue.map(\.status) == [.applied, .applied])
        #expect(harness.model.isQueueComplete)
    }

    @Test("continue is refused until the item's apply actually succeeded")
    func continueRequiresApply() async throws {
        let (harness, _) = try await loadedHarness(outputs: [
            browserListingWire(),
            consolidateFixtureWire(name: "Fixture List"),
        ])
        defer { harness.cleanUp() }

        harness.model.toggleChecked(persistentId: "P-FIX")
        harness.model.startQueue()
        await harness.awaitAudit()

        // Audited but not applied: continue is a no-op — even with the
        // gate satisfied.
        harness.model.continueQueueAfterApply()
        #expect(harness.model.queue[0].status == .audited)
        harness.model.reviewedPlanToggle = true
        harness.model.typedTargetName = try #require(harness.model.targetName)
        harness.model.continueQueueAfterApply()
        #expect(harness.model.queue[0].status == .audited)
        #expect(!harness.model.isQueueComplete)
    }

    @Test("skip marks the item and starts the next audit")
    func skipAdvances() async throws {
        let (harness, _) = try await loadedHarness(outputs: [
            browserListingWire(),
            consolidateFixtureWire(name: "Fixture List"),
            consolidateFixtureWire(name: "Solo List"),
        ])
        defer { harness.cleanUp() }

        harness.model.toggleChecked(persistentId: "P-FIX")
        harness.model.toggleChecked(persistentId: "P-SOLO")
        harness.model.startQueue()
        await harness.awaitAudit()

        harness.model.skipCurrentQueueItem()
        #expect(harness.model.queue[0].status == .skipped)
        await harness.awaitAudit()
        #expect(harness.model.queue[1].status == .audited)
        #expect(harness.model.result?.sourceName == "Solo List")
    }

    @Test("a failed audit marks the item failed; retry re-audits it")
    func failureAndRetry() async throws {
        let runner = ScriptedRunner(results: [
            .success(browserListingWire()),
            .failure(MusicCommandError("Music automation failed: read error")),
            .success(consolidateFixtureWire(name: "Fixture List")),
        ])
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await awaitScan(harness.model)

        harness.model.toggleChecked(persistentId: "P-FIX")
        harness.model.startQueue()
        await harness.awaitAudit()
        #expect(harness.model.queue[0].status == .failed)

        harness.model.retryCurrentQueueItem()
        await harness.awaitAudit()
        #expect(harness.model.queue[0].status == .audited)
        #expect(harness.model.result?.sourceName == "Fixture List")
    }

    @Test("start over resets the queue but keeps the checkbox picks")
    func startOverResetsQueue() async throws {
        let (harness, _) = try await loadedHarness(outputs: [
            browserListingWire(),
            consolidateFixtureWire(name: "Fixture List"),
        ])
        defer { harness.cleanUp() }

        harness.model.toggleChecked(persistentId: "P-FIX")
        harness.model.startQueue()
        await harness.awaitAudit()

        harness.model.startOver()
        #expect(!harness.model.isQueueActive)
        #expect(harness.model.queue.isEmpty)
        #expect(harness.model.checkedPersistentIds == ["P-FIX"])
        #expect(harness.model.result == nil)
    }

    @Test("a mode change resets the queue and clears the browser selection")
    func modeChangeResets() async throws {
        let (harness, _) = try await loadedHarness(outputs: [
            browserListingWire(),
            consolidateFixtureWire(name: "Fixture List"),
        ])
        defer { harness.cleanUp() }

        harness.model.toggleChecked(persistentId: "P-FIX")
        harness.model.startQueue()
        await harness.awaitAudit()
        harness.model.browserSelection = .singleton("P-KD")

        harness.model.setMode(.merge)
        #expect(!harness.model.isQueueActive)
        #expect(harness.model.queue.isEmpty)
        #expect(harness.model.browserSelection == nil)
        // The listing itself survives (it is mode-independent).
        #expect(harness.model.loadedSections != nil)
    }
}

// MARK: - queue guard hardening (fix round 1)

/// Replays canned results in order like ScriptedRunner, but BLOCKS inside
/// `run` (on the detached stage's own thread) at the given 0-based call
/// indexes until the test signals `proceed` — the seam for holding a scan
/// or read in flight while queue actions are attempted.
private final class SequencedBlockingRunner: ScriptRunner, @unchecked Sendable {
    let proceed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var results: [Result<String, Error>]
    private let blockAt: Set<Int>
    private var callCount = 0

    init(outputs: [String], blockAt: Set<Int>) {
        self.results = outputs.map { .success($0) }
        self.blockAt = blockAt
    }

    var runCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    @discardableResult
    func run(_ command: ScriptCommand) throws -> String {
        lock.lock()
        let index = callCount
        callCount += 1
        let next = results.isEmpty ? nil : results.removeFirst()
        lock.unlock()
        if blockAt.contains(index) { proceed.wait() }
        guard let next else {
            throw AppTestError("SequencedBlockingRunner has no scripted output left")
        }
        return try next.get()
    }
}

@MainActor
@Suite("Queue guard hardening (fix round 1)")
struct QueueGuardHardeningTests {

    /// Finding 2 repro (rewired to M9's apply-based continue): during an
    /// in-flight rescan, Skip/Continue used to advance the queue index
    /// while startAudit's guard refused to start — stranding the next item
    /// as .pending with the finished item's stale plan still displayed.
    /// Both actions must be no-ops while a scan holds the OSA slot, and
    /// must work normally afterwards.
    @Test("skip and continue are refused during an in-flight rescan; no stranding")
    func skipAndContinueRefusedDuringScan() async throws {
        let runner = SequencedBlockingRunner(
            outputs: [browserListingWire(),                        // 0: initial scan
                      consolidateFixtureWire(name: "Fixture List")] // 1: item 1 audit
                + consolidateApplyOutputs(name: "Fixture List")    // 2-7: item 1 apply
                + [browserListingWire(),                           // 8: mid-queue rescan (BLOCKED)
                   consolidateFixtureWire(name: "Solo List")],     // 9: item 2 audit
            blockAt: [8]
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }

        harness.model.rescanLibrary()
        await awaitScan(harness.model)
        harness.model.toggleChecked(persistentId: "P-FIX")
        harness.model.toggleChecked(persistentId: "P-SOLO")
        harness.model.startQueue()
        await harness.awaitAudit()
        #expect(harness.model.queue.map(\.status) == [.audited, .pending])

        // Item 1: gate + verified apply — the item is .applied, continue
        // is legitimately available.
        harness.model.reviewedPlanToggle = true
        harness.model.typedTargetName = try #require(harness.model.targetName)
        harness.model.startApply()
        await harness.awaitApply()
        #expect(harness.model.queue.map(\.status) == [.applied, .pending])

        // Hold a rescan in flight.
        harness.model.rescanLibrary()
        let scanning = await pollUntil { runner.runCount == 9 }
        #expect(scanning)
        #expect(harness.model.isScanning)

        // Continue must be a NO-OP: no index advance, no stale-state stall.
        harness.model.continueQueueAfterApply()
        #expect(harness.model.queue.map(\.status) == [.applied, .pending])
        #expect(harness.model.currentQueueItem?.name == "Fixture List")

        // Skip must be a NO-OP too (same guard set as Retry).
        harness.model.skipCurrentQueueItem()
        #expect(harness.model.queue.map(\.status) == [.applied, .pending])
        #expect(harness.model.currentQueueItem?.name == "Fixture List")

        // Release the scan; afterwards Continue works end to end.
        runner.proceed.signal()
        await awaitScan(harness.model)
        #expect(!harness.model.isScanning)

        harness.model.continueQueueAfterApply()
        await harness.awaitAudit()
        #expect(harness.model.queue.map(\.status) == [.applied, .audited])
        #expect(harness.model.result?.sourceName == "Solo List")
    }

    /// Folded minor: cancelling a queue item's read must not strand it as
    /// .pending (Retry only exists for .failed). The cancelled item is
    /// marked .failed and the existing Retry path recovers it.
    @Test("cancel mid-queue marks the item failed; retry recovers it")
    func cancelMidQueueMarksItemFailed() async throws {
        let runner = SequencedBlockingRunner(
            outputs: [
                browserListingWire(),                         // 0: scan
                consolidateFixtureWire(name: "Fixture List"), // 1: item read (BLOCKED)
                consolidateFixtureWire(name: "Fixture List"), // 2: retry read
            ],
            blockAt: [1]
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }

        harness.model.rescanLibrary()
        await awaitScan(harness.model)
        harness.model.toggleChecked(persistentId: "P-FIX")
        harness.model.startQueue()
        let reading = await pollUntil { runner.runCount == 2 }
        #expect(reading)

        // Cancel while the (uncancellable) read is in flight; the pipeline
        // honors it at the next phase boundary once the read returns.
        harness.model.cancelAudit()
        runner.proceed.signal()
        await harness.awaitAudit()

        if case .cancelled = harness.model.runState {} else {
            Issue.record("expected cancelled run state, got \(harness.model.runState)")
        }
        #expect(harness.model.queue.map(\.status) == [.failed])
        #expect(harness.model.isQueueActive)

        harness.model.retryCurrentQueueItem()
        await harness.awaitAudit()
        #expect(harness.model.queue.map(\.status) == [.audited])
        #expect(harness.model.result?.sourceName == "Fixture List")
    }
}

// MARK: - step navigation legality (fix round 4)

@MainActor
@Suite("Step navigation legality")
struct StepNavigationTests {

    @Test("steps 2 and 3 are unreachable without a completed audit")
    func unreachableWithoutAudit() throws {
        let harness = try ModelHarness(runner: ScriptedRunner(outputs: []))
        defer { harness.cleanUp() }
        let model = harness.model

        #expect(model.canNavigate(to: .source))
        #expect(!model.canNavigate(to: .review))
        #expect(!model.canNavigate(to: .confirm))
        #expect(model.stepBlockedReason(for: .review) == "Run a read-only check first.")
        #expect(model.stepBlockedReason(for: .confirm) == "Run a read-only check first.")

        model.navigate(to: .confirm)
        #expect(model.step == .source)
    }

    @Test("a completed audit opens step 2; step 3 requires step 2 visited")
    func auditOpensSteps() async throws {
        let harness = try ModelHarness(runner: ScriptedRunner(outputs: [consolidateFixtureWire()]))
        defer { harness.cleanUp() }
        let model = harness.model

        model.startAudit()
        await harness.awaitAudit()

        // applySuccess lands on .review, so step 2 counts as visited.
        #expect(model.step == .review)
        #expect(model.hasVisitedReview)
        #expect(model.canNavigate(to: .review))
        #expect(model.canNavigate(to: .confirm))
        #expect(model.stepBlockedReason(for: .confirm) == nil)

        model.navigate(to: .confirm)
        #expect(model.step == .confirm)
        model.navigate(to: .source)
        #expect(model.step == .source)
        model.navigate(to: .confirm)
        #expect(model.step == .confirm)

        // Start over clears the visited flag with the audit.
        model.startOver()
        #expect(!model.hasVisitedReview)
        #expect(!model.canNavigate(to: .confirm))
        #expect(model.step == .source)
    }
}

// MARK: - confirm-gate near-miss diagnostics

@MainActor
@Suite("Confirm-gate near-miss diagnostics")
struct ConfirmGateDiagnosticsTests {

    @Test("a near-miss reports the exact first divergence; empty and exact report nothing")
    func nearMissDivergence() async throws {
        let runner = ScriptedRunner(outputs: [consolidateFixtureWire()])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }

        harness.model.startAudit()
        await harness.awaitAudit()
        let target = try #require(harness.model.targetName)
        #expect(target == "Fixture List \u{2014} Consolidated")

        // Empty field: no diagnostic (and no match).
        #expect(harness.model.typedTargetName.isEmpty)
        #expect(harness.model.typedNameDivergence == nil)
        #expect(!harness.model.typedTargetNameMatches)

        // The live trap: hyphen typed for the em dash.
        harness.model.typedTargetName = "Fixture List - Consolidated"
        let divergence = try #require(harness.model.typedNameDivergence)
        #expect(divergence == ScalarDivergence(index: 13, expected: "\u{2014}", actual: "-"))
        #expect(describeDivergence(divergence)
            == "First difference at scalar index 13: expected U+2014 (EM DASH), typed U+002D (HYPHEN-MINUS).")

        // Trailing-space near-miss.
        harness.model.typedTargetName = target + " "
        let trailing = try #require(harness.model.typedNameDivergence)
        #expect(trailing.index == target.unicodeScalars.count)
        #expect(trailing.expected == nil)
        #expect(trailing.actual == " ")

        // Exact match: gate satisfied, no diagnostic.
        harness.model.typedTargetName = target
        #expect(harness.model.typedNameDivergence == nil)
        #expect(harness.model.typedTargetNameMatches)
    }
}
