// WaveCFailureSurfaceTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Wave C1 Task 4 — the "Delete leftover target…" shortcut (spec C1.5) and
// the attended failure screen's class banner (spec C1.4): fresh-listing
// resolution (scalar-exact, exactly-1 stages the SAME direct delete
// confirmation as every other delete — final fix wave, Finding C1; 0/N
// surface the pinned notice), the OSA mutual-exclusion fold, and offscreen
// structural cells at 1200x800. All offline: ScriptedRunner only.

import AppKit
import SwiftUI
import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

private let waveCWindowBox = NSRect(x: 0, y: 0, width: 1200, height: 800)

@MainActor
private func expectWaveCContained(
    _ id: String,
    in hosting: NSView,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    guard let control = view(under: hosting, axIdentifier: id) else {
        Issue.record("control \(id) is missing", sourceLocation: sourceLocation)
        return
    }
    let frame = control.convert(control.bounds, to: hosting)
    #expect(waveCWindowBox.contains(frame), "\(id) at \(frame)", sourceLocation: sourceLocation)
}

/// The consolidate target name the fixture audit derives.
private let fixtureTargetName = "Fixture List \u{2014} Consolidated"

/// A listing containing exactly `count` playlists whose name is the fixture
/// target name (plus one unrelated entry), for the resolve step.
private func leftoverListingWire(matchCount: Int) -> String {
    var entries = [gateEntry(id: 10, name: "Fixture List", pid: "P-FX0000000000AA", count: 4)]
    for index in 0..<matchCount {
        entries.append(gateEntry(
            id: 900 + index, name: fixtureTargetName,
            pid: "LEFTOVER0000000\(index)", count: 3
        ))
    }
    return "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

/// The leftover's track snapshot for the mutation gate's own audit read.
private func leftoverSnapshotWire() -> String {
    wireSnapshot(playlists: [
        wirePlaylist(
            id: 900, name: fixtureTargetName, persistentId: "LEFTOVER00000000",
            tracks: [
                wireTrack(sourceIndex: 0, databaseId: 12, persistentId: "AAAA0002",
                          title: "Shared Song", bitRate: 256),
                wireTrack(sourceIndex: 1, databaseId: 13, persistentId: "AAAA0003",
                          title: "Only Once"),
                wireTrack(sourceIndex: 2, databaseId: 14, persistentId: "AAAA0004",
                          title: "No Duration", duration: nil),
            ]
        )
    ])
}

/// Drive one attended writer-failure apply (class writerFailed, leftover
/// possible) with `extraOutputs` scripted AFTER the apply sequence.
@MainActor
private func writerFailedHarness(
    extraOutputs: [Result<String, Error>] = []
) async throws -> (ModelHarness, ScriptedRunner) {
    let runner = ScriptedRunner(results: [
        .success(consolidateFixtureWire()),
        .success(consolidateFixtureWire()),
        .success(emptySnapshotWire()),
        .success(""),
        .failure(MusicCommandError("osascript exited 1: writer blew up")),
        .success(consolidateFixtureWire()),
        .success(emptySnapshotWire()),
    ] + extraOutputs)
    let harness = try ModelHarness(runner: runner)
    try await harness.auditAndSatisfyGate()
    harness.model.startApply()
    await harness.awaitApply()
    #expect(harness.model.applyFailureClass == .writerFailed)
    return (harness, runner)
}

@MainActor
@Suite("Wave C1 — leftover-resolve model machinery")
struct LeftoverResolveModelTests {

    @Test("exactly one live match stages the SAME direct delete confirmation as every other delete")
    func exactlyOneMatchStagesTheDirectDelete() async throws {
        // Final review, Finding C1: the shortcut used to arm the retired Wave
        // B gate (a 6-8 s read, a silently written .delete.plan.json, and an
        // armed artifact no view can present or consume). It now stages the
        // direct confirmation off the FRESH listing it just resolved — one
        // read, no artifact, and the same sheet every other delete uses.
        let (harness, runner) = try await writerFailedHarness(extraOutputs: [
            .success(leftoverListingWire(matchCount: 1)),  // resolve read
        ])
        defer { harness.cleanUp() }
        let artifactsBefore = try harness.artifactFileCount()

        harness.model.startDeleteLeftoverTarget(named: fixtureTargetName)
        await harness.model.leftoverResolveTask?.value

        #expect(harness.model.leftoverResolveNotice == nil)
        guard case .delete(let targets)? = harness.model.pendingDirectAction else {
            Issue.record("expected a staged direct delete, got \(String(describing: harness.model.pendingDirectAction))")
            return
        }
        #expect(targets.count == 1)
        #expect(scalarExact(targets[0].persistentId, "LEFTOVER00000000"))
        #expect(scalarExact(targets[0].name, fixtureTargetName))
        // The retired gate stays untouched, and NOTHING is written to disk.
        #expect(harness.model.armedMutation == nil)
        guard case .idle = harness.model.mutationGatePhase else {
            Issue.record("the shortcut must never arm the retired gate")
            return
        }
        #expect(runner.commands.count == 8, "one resolve read; no gate audit")
        #expect(try harness.artifactFileCount() == artifactsBefore)
        let deletePlans = try FileManager.default.contentsOfDirectory(
            atPath: harness.outputDirectory.path
        ).filter { $0.hasSuffix(".delete.plan.json") }
        #expect(deletePlans.isEmpty, "no delete plan artifact may be written by this path")
    }

    @Test("zero matches surface the pinned notice and stage nothing")
    func zeroMatchesNotice() async throws {
        let (harness, runner) = try await writerFailedHarness(extraOutputs: [
            .success(leftoverListingWire(matchCount: 0)),
        ])
        defer { harness.cleanUp() }

        harness.model.startDeleteLeftoverTarget(named: fixtureTargetName)
        await harness.model.leftoverResolveTask?.value

        #expect(harness.model.leftoverResolveNotice
            == "Could not pin the leftover uniquely (0 live matches) \u{2014} "
                + "delete it from the Library browser instead.")
        #expect(harness.model.pendingDirectAction == nil,
                "an ambiguous resolve must stage no confirmation")
        guard case .idle = harness.model.mutationGatePhase else {
            Issue.record("no gate may open on an ambiguous resolve")
            return
        }
        #expect(runner.commands.count == 8)
    }

    @Test("two matches surface the pinned notice with N = 2")
    func twoMatchesNotice() async throws {
        let (harness, _) = try await writerFailedHarness(extraOutputs: [
            .success(leftoverListingWire(matchCount: 2)),
        ])
        defer { harness.cleanUp() }

        harness.model.startDeleteLeftoverTarget(named: fixtureTargetName)
        await harness.model.leftoverResolveTask?.value

        #expect(harness.model.leftoverResolveNotice
            == "Could not pin the leftover uniquely (2 live matches) \u{2014} "
                + "delete it from the Library browser instead.")
    }

    @Test("a failed resolve read surfaces its verbatim error; no gate opens")
    func resolveReadFailureNotice() async throws {
        let (harness, _) = try await writerFailedHarness(extraOutputs: [
            .failure(MusicCommandError("JXA execution failed: error -1743")),
        ])
        defer { harness.cleanUp() }

        harness.model.startDeleteLeftoverTarget(named: fixtureTargetName)
        await harness.model.leftoverResolveTask?.value

        let notice = try #require(harness.model.leftoverResolveNotice)
        #expect(scalarHasPrefix(
            notice, "Could not read the live library to pin the leftover: "))
        #expect(notice.contains("error -1743"))
        #expect(harness.model.pendingDirectAction == nil,
                "a failed resolve must stage no confirmation")
        guard case .idle = harness.model.mutationGatePhase else {
            Issue.record("no gate may open on a failed resolve")
            return
        }
    }

    @Test("the resolve read holds the OSA slot: isMutationBusy while in flight")
    func resolveJoinsTheExclusionSet() async throws {
        // Block the resolve read (command index 7, 0-based) and observe the
        // busy flag. The apply itself finishes unblocked: its target
        // readback of an EMPTY snapshot fails closed (caught, "target
        // readback failed after write" line -> rule 3b: unverifiable),
        // which is a perfectly good failed apply to hang the shortcut off —
        // the resolve machinery is class-agnostic at the model level.
        let runner = StagedBlockingRunner(
            outputs: [
                consolidateFixtureWire(), consolidateFixtureWire(),
                emptySnapshotWire(), "", "",
                consolidateFixtureWire(), emptySnapshotWire(),
                leftoverListingWire(matchCount: 0),
            ],
            blockAt: [7]
        )
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        try await harness.auditAndSatisfyGate()
        harness.model.startApply()
        await harness.awaitApply()
        #expect(harness.model.applyFailureClass == .unverifiable)

        harness.model.startDeleteLeftoverTarget(named: fixtureTargetName)
        #expect(await pollUntil { runner.runCount == 8 })
        #expect(harness.model.isResolvingLeftoverTarget)
        #expect(harness.model.isMutationBusy)
        runner.proceed.signal()
        await harness.model.leftoverResolveTask?.value
        #expect(!harness.model.isResolvingLeftoverTarget)
        #expect(!harness.model.isMutationBusy)
    }

    @Test("the shortcut is refused while an unattended run is active")
    func refusedDuringUnattendedRun() async throws {
        // A one-item unattended run held at its audit read: the queue is
        // active, so the mutation-entry guard must refuse silently.
        let listing = "{\"playlists\": ["
            + gateEntry(id: 10, name: "Alpha List", pid: "P-A0000000000001", count: 4) + "]}"
        let runner = StagedBlockingRunner(
            outputs: [listing, consolidateFixtureWire(name: "Alpha List")],
            blockAt: [1]
        )
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "",
            confirmEachApply: false
        )
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-A0000000000001")
        harness.model.startQueue()
        #expect(await pollUntil { harness.model.isUnattendedRunActive })

        let countBefore = runner.runCount
        harness.model.startDeleteLeftoverTarget(named: "Alpha List \u{2014} Consolidated")
        #expect(harness.model.leftoverResolveTask == nil)
        #expect(runner.runCount == countBefore)

        runner.proceed.signal()   // let the run finish; no dangling task
        #expect(await pollUntil { harness.model.finishedRunReport != nil })
    }

    @Test("startOver is refused while a leftover resolve is in flight, and succeeds once it settles")
    func startOverRefusedDuringResolve() async throws {
        // Fix round 1 (combined Task 4+5 review, Important finding): click
        // the attended failure screen's shortcut, then immediately click
        // "Start over" — the resolve must never be orphaned against a
        // discarded audit. Same blocked-resolve setup as
        // resolveJoinsTheExclusionSet above.
        let runner = StagedBlockingRunner(
            outputs: [
                consolidateFixtureWire(), consolidateFixtureWire(),
                emptySnapshotWire(), "", "",
                consolidateFixtureWire(), emptySnapshotWire(),
                leftoverListingWire(matchCount: 0),
            ],
            blockAt: [7]
        )
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        try await harness.auditAndSatisfyGate()
        harness.model.startApply()
        await harness.awaitApply()
        #expect(harness.model.applyFailureClass == .unverifiable)

        harness.model.startDeleteLeftoverTarget(named: fixtureTargetName)
        #expect(await pollUntil { runner.runCount == 8 })
        #expect(harness.model.isResolvingLeftoverTarget)

        harness.model.startOver()
        #expect(harness.model.applyFailureClass == .unverifiable)
        #expect(harness.model.isResolvingLeftoverTarget)
        #expect(harness.model.step != .source)

        runner.proceed.signal()
        await harness.model.leftoverResolveTask?.value
        #expect(!harness.model.isResolvingLeftoverTarget)
        #expect(!harness.model.isMutationBusy)

        // Now that the resolve has settled, the SAME call succeeds.
        harness.model.startOver()
        #expect(harness.model.applyFailureClass == nil)
        #expect(harness.model.step == .source)
    }

    @Test("a stale leftover resolve after a mode reset stages nothing and sets no notice")
    func staleResolveAfterModeResetArmsNothing() async throws {
        // Fix round 1 (combined Task 4+5 review, Important finding): unlike
        // startOver()/acknowledgeRunReport(), setMode() does NOT check
        // isMutationBusy (a real defense-in-depth vector), so it can bump
        // discardCompletedAudit()/resetQueue() while a resolve is in
        // flight. The blocked call is scripted to an EXACTLY-ONE-MATCH
        // listing: without the generation guard, this would stage a delete
        // confirmation (pre-C1: arm the Wave B gate) on a context the reset
        // already discarded.
        let runner = StagedBlockingRunner(
            outputs: [
                consolidateFixtureWire(), consolidateFixtureWire(),
                emptySnapshotWire(), "", "",
                consolidateFixtureWire(), emptySnapshotWire(),
                leftoverListingWire(matchCount: 1),
            ],
            blockAt: [7]
        )
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        try await harness.auditAndSatisfyGate()
        harness.model.startApply()
        await harness.awaitApply()
        #expect(harness.model.applyFailureClass == .unverifiable)

        harness.model.startDeleteLeftoverTarget(named: fixtureTargetName)
        #expect(await pollUntil { runner.runCount == 8 })
        #expect(harness.model.isResolvingLeftoverTarget)

        harness.model.setMode(.merge)

        runner.proceed.signal()
        await harness.model.leftoverResolveTask?.value
        #expect(!harness.model.isResolvingLeftoverTarget)
        #expect(harness.model.pendingDirectAction == nil,
                "a stale resolve completion must never stage a confirmation")
        #expect(harness.model.armedMutation == nil)
        #expect(harness.model.leftoverResolveNotice == nil)
        guard case .idle = harness.model.mutationGatePhase else {
            Issue.record("a stale resolve completion must never arm the gate")
            return
        }
    }

    @Test("executeMutation is refused while a leftover resolve is in flight, and succeeds once it settles")
    func executeMutationRefusedDuringSecondResolve() async throws {
        // Final review, Finding I-1: `.armed` never sets isMutationBusy, and
        // the shortcut stays enabled while a gate sits armed. A resolve
        // started before the user dispatches must still block dispatch —
        // otherwise the guarded writer could run concurrently with the
        // resolve's listPlaylists() read. (Final fix wave, Finding C1: the
        // shortcut no longer arms the gate at all, so the gate is armed here
        // through its own entry point, `startMutationAudit`.)
        let runner = StagedBlockingRunner(
            outputs: [
                consolidateFixtureWire(), consolidateFixtureWire(),
                emptySnapshotWire(), "", "",
                consolidateFixtureWire(), emptySnapshotWire(),
                leftoverListingWire(matchCount: 1),   // gate audit listing
                leftoverSnapshotWire(),               // gate audit snapshot
                leftoverListingWire(matchCount: 0),   // resolve -> BLOCKED, then 0 matches
            ],
            blockAt: [9]
        )
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        try await harness.auditAndSatisfyGate()
        harness.model.startApply()
        await harness.awaitApply()
        #expect(harness.model.applyFailureClass == .unverifiable)

        harness.model.startMutationAudit(kind: .delete, persistentID: "LEFTOVER00000000")
        await harness.model.mutationTask?.value
        let armed = try #require(harness.model.armedMutation)
        #expect(armed.plan.kind == .delete)
        harness.model.typedMutationName = fixtureTargetName
        #expect(harness.model.mutationGateSatisfied)

        // The resolve, in flight while the gate sits armed.
        harness.model.startDeleteLeftoverTarget(named: fixtureTargetName)
        #expect(await pollUntil { runner.runCount == 10 })
        #expect(harness.model.isResolvingLeftoverTarget)
        #expect(harness.model.isMutationBusy)

        harness.model.executeMutation()
        guard case .armed = harness.model.mutationGatePhase else {
            Issue.record("executeMutation must refuse while a resolve is in flight")
            return
        }
        #expect(runner.runCount == 10, "no compile/execute call must be dispatched while refused")

        runner.proceed.signal()
        await harness.model.leftoverResolveTask?.value
        #expect(!harness.model.isMutationBusy)
        guard case .armed = harness.model.mutationGatePhase else {
            Issue.record("the armed gate must survive an ambiguous second resolve")
            return
        }

        // Now that the second resolve has settled, the SAME call succeeds:
        // the guard passes and dispatch begins (synchronous phase flip).
        harness.model.executeMutation()
        guard case .executing = harness.model.mutationGatePhase else {
            Issue.record("executeMutation must now be accepted once the resolve settled")
            return
        }
        await harness.model.mutationTask?.value
    }

    @Test("retryCurrentQueueItem is refused mid-resolve; the failed record and status survive")
    func retryRefusedDuringResolve() async throws {
        // Final review, Finding I-2: same screen, same race as startOver()/
        // acknowledgeRunReport() in fix round 1. Without the guard, Retry
        // deletes the failed record and marks the item .pending, then
        // silently fails to start the fresh audit (startAudit refuses on
        // isMutationBusy) — stranding the item and falsifying the
        // mandatory report as .notRun.
        let listing = "{\"playlists\": ["
            + gateEntry(id: 10, name: "Fixture List", pid: "P-FX0000000000AA", count: 4) + "]}"
        let runner = StagedBlockingRunner(
            outputs: [
                listing,
                consolidateFixtureWire(),
                consolidateFixtureWire(), emptySnapshotWire(), "", "",
                consolidateFixtureWire(), emptySnapshotWire(),
                leftoverListingWire(matchCount: 0),
                consolidateFixtureWire(),   // the retry's fresh audit read
            ],
            blockAt: [8]
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        let model = harness.model

        model.rescanLibrary()
        await model.scanTask?.value
        model.toggleChecked(persistentId: "P-FX0000000000AA")
        model.startQueue()
        await harness.awaitAudit()
        #expect(model.queue.map(\.status) == [.audited])
        model.reviewedPlanToggle = true
        model.typedTargetName = try #require(model.targetName)
        model.startApply()
        await harness.awaitApply()
        #expect(model.queue.map(\.status) == [.failed])
        let recordsBefore = model.runRecords

        model.startDeleteLeftoverTarget(named: "Fixture List \u{2014} Consolidated")
        #expect(await pollUntil { runner.runCount == 9 })
        #expect(model.isResolvingLeftoverTarget)

        model.retryCurrentQueueItem()
        #expect(model.queue.map(\.status) == [.failed], "retry must not strand the item .pending")
        #expect(model.runRecords == recordsBefore, "the failed record must survive a refused retry")

        runner.proceed.signal()
        await model.leftoverResolveTask?.value
        #expect(!model.isMutationBusy)

        model.retryCurrentQueueItem()
        await harness.awaitAudit()
        #expect(model.queue.map(\.status) == [.audited])
    }

    @Test("skipCurrentQueueItem is refused mid-resolve; the next item never strands pending")
    func skipRefusedDuringResolve() async throws {
        // Final review, Finding I-2 (skip, non-final item): without the
        // guard, Skip records .skipped and advanceQueue -> startAudit is
        // silently refused, stranding the NEXT item .pending.
        let listing = "{\"playlists\": ["
            + gateEntry(id: 10, name: "Fixture List", pid: "P-FX0000000000AA", count: 4) + ", "
            + gateEntry(id: 20, name: "Second List", pid: "P-SEC000000000BB", count: 4) + "]}"
        let runner = StagedBlockingRunner(
            outputs: [
                listing,
                consolidateFixtureWire(),
                consolidateFixtureWire(), emptySnapshotWire(), "", "",
                consolidateFixtureWire(), emptySnapshotWire(),
                leftoverListingWire(matchCount: 0),
                consolidateFixtureWire(name: "Second List"),   // next item's fresh audit read
            ],
            blockAt: [8]
        )
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        let model = harness.model

        model.rescanLibrary()
        await model.scanTask?.value
        model.toggleChecked(persistentId: "P-FX0000000000AA")
        model.toggleChecked(persistentId: "P-SEC000000000BB")
        model.startQueue()
        await harness.awaitAudit()
        #expect(model.queue.map(\.status) == [.audited, .pending])
        model.reviewedPlanToggle = true
        model.typedTargetName = try #require(model.targetName)
        model.startApply()
        await harness.awaitApply()
        #expect(model.queue.map(\.status) == [.failed, .pending])

        model.startDeleteLeftoverTarget(named: "Fixture List \u{2014} Consolidated")
        #expect(await pollUntil { runner.runCount == 9 })
        #expect(model.isResolvingLeftoverTarget)

        model.skipCurrentQueueItem()
        #expect(model.queue.map(\.status) == [.failed, .pending],
                "skip must never advance the queue while the resolve is in flight")

        runner.proceed.signal()
        await model.leftoverResolveTask?.value
        #expect(!model.isMutationBusy)

        model.skipCurrentQueueItem()
        await harness.awaitAudit()
        #expect(model.queue.map(\.status) == [.skipped, .audited])
    }
}

@MainActor
@Suite("Offscreen structural view tests (Wave C1 attended failure surface)", .serialized)
struct WaveCAttendedStructuralTests {

    @Test("writerFailed: banner text is the exact label; shortcut present and contained")
    func writerFailedBannerAndShortcut() async throws {
        let (harness, _) = try await writerFailedHarness()
        defer { harness.cleanUp() }

        let fixture = HostedFixture(
            ApplyFlowView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)
        expectWaveCContained(WaveCControlID.failureClassBanner, in: fixture.hosting)
        expectWaveCContained(WaveCControlID.deleteLeftoverTarget, in: fixture.hosting)
        let banner = try #require(
            view(under: fixture.hosting, axIdentifier: WaveCControlID.failureClassBanner)
                as? NSTextField
        )
        #expect(banner.stringValue == applyFailureClassLabel(.writerFailed))
    }

    @Test("refusedBeforeWrite: banner present, shortcut and notice absent")
    func refusedBeforeWriteHidesShortcut() async throws {
        // Goddesses replay: the target-absent read finds an exact-name
        // target; the class can never leave a leftover behind.
        let runner = ScriptedRunner(outputs: [
            consolidateFixtureWire(),
            consolidateFixtureWire(),
            consolidateTargetReadbackWire(),
        ])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        try await harness.auditAndSatisfyGate()
        harness.model.startApply()
        await harness.awaitApply()
        #expect(harness.model.applyFailureClass == .refusedBeforeWrite)

        let fixture = HostedFixture(
            ApplyFlowView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)
        expectWaveCContained(WaveCControlID.failureClassBanner, in: fixture.hosting)
        #expect(view(
            under: fixture.hosting, axIdentifier: WaveCControlID.deleteLeftoverTarget
        ) == nil)
        #expect(view(
            under: fixture.hosting, axIdentifier: WaveCControlID.leftoverResolveNotice
        ) == nil)
    }

    @Test("shortcut click plumbing stages the direct delete confirmation")
    func shortcutClickStagesDirectDelete() async throws {
        let (harness, _) = try await writerFailedHarness(extraOutputs: [
            .success(leftoverListingWire(matchCount: 1)),
        ])
        defer { harness.cleanUp() }

        let fixture = HostedFixture(
            ApplyFlowView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        let button = try #require(
            view(under: fixture.hosting, axIdentifier: WaveCControlID.deleteLeftoverTarget)
                as? NSButton
        )
        #expect(button.isEnabled)
        button.performClick(nil)
        await harness.model.leftoverResolveTask?.value

        guard case .delete(let targets)? = harness.model.pendingDirectAction else {
            Issue.record("expected a staged direct delete")
            return
        }
        #expect(scalarExact(targets[0].persistentId, "LEFTOVER00000000"))
        #expect(harness.model.armedMutation == nil)
    }

    @Test("an ambiguous resolve renders the notice, contained, with the exact copy")
    func ambiguousResolveNoticeVisible() async throws {
        let (harness, _) = try await writerFailedHarness(extraOutputs: [
            .success(leftoverListingWire(matchCount: 2)),
        ])
        defer { harness.cleanUp() }
        harness.model.startDeleteLeftoverTarget(named: fixtureTargetName)
        await harness.model.leftoverResolveTask?.value

        let fixture = HostedFixture(
            ApplyFlowView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        expectWaveCContained(WaveCControlID.leftoverResolveNotice, in: fixture.hosting)
        let notice = try #require(
            view(under: fixture.hosting, axIdentifier: WaveCControlID.leftoverResolveNotice)
                as? NSTextField
        )
        #expect(notice.stringValue
            == "Could not pin the leftover uniquely (2 live matches) \u{2014} "
                + "delete it from the Library browser instead.")
    }
}
