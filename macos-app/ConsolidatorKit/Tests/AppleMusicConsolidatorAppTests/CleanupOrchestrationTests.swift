// CleanupOrchestrationTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Wave B (B3 execution) — the group-gate orchestration in AuditFlowModel:
// refresh -> discovery+candidacy over live fakes, gate-arm re-check, then
// strictly sequential per-copy deletes with baseline chaining, abort on the
// first readback failure, ONE group result report (with the deleted-ok
// accounting lines Task 11 parses), consumption of every group artifact,
// and re-auditability of the partially cleaned group. Offline only:
// ScriptedRunner canned wire text; no script is ever executed.

import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

// MARK: - fixture identities (3-copy group, 1 distinct track per copy)

let cleanupGroupName = "Trance 2022"
let cleanupTargetName = "Trance 2022 \u{2014} Merged"
private let planDate = Date(timeIntervalSince1970: 1_754_000_000)

// MARK: - scan exclusion (cleanup-scan hotfix, 2026-08-05)

@Suite("Cleanup scan OSA exclusion")
@MainActor
struct CleanupScanExclusionTests {

    @Test("an in-flight cleanup scan holds the OSA slot: the mutation gate refuses entry until it finishes")
    func scanBlocksMutationEntry() async throws {
        // The scan's single live read (the listing, command index 0) is held
        // open; no merge plans on disk are needed for the read to occur.
        let runner = StagedBlockingRunner(
            outputs: [cleanupListingWire(copyPIDs: [])], blockAt: [0]
        )
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        model.refreshCleanup()
        #expect(await pollUntil {
            if case .scanning = model.cleanupScanState { return true }
            return false
        })

        // The held scan holds the OSA slot (fail-closed exclusion)...
        #expect(model.isMutationBusy)
        // ...so the mutation gate refuses entry outright: no phase change,
        // no task spawned, no reads attempted.
        model.startMutationAudit(kind: .delete, persistentID: "SOLO000000000001")
        if case .idle = model.mutationGatePhase {} else {
            Issue.record("the gate must stay idle while a cleanup scan runs")
        }
        #expect(model.mutationTask == nil)

        // Release the scan; the slot frees and entry passes the guard again.
        runner.proceed.signal()
        await model.cleanupScanTask?.value
        #expect(!model.isMutationBusy)
        model.startMutationAudit(kind: .delete, persistentID: "SOLO000000000001")
        #expect(model.mutationTask != nil)
        await harness.awaitMutation()
    }

    @Test("an in-flight cleanup scan also holds startAudit() out until it finishes")
    func scanBlocksAuditEntry() async throws {
        // Same shape as scanBlocksMutationEntry, but the entry point under
        // test is the review-flow audit rather than the mutation gate. Only
        // the scan's listing read (index 0) needs to be scripted before the
        // release; the eventual audit's own read (index 1) comes after.
        let runner = StagedBlockingRunner(
            outputs: [cleanupListingWire(copyPIDs: []), consolidateFixtureWire(name: "Some List")],
            blockAt: [0]
        )
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        model.playlistName = "Some List"

        model.refreshCleanup()
        #expect(await pollUntil {
            if case .scanning = model.cleanupScanState { return true }
            return false
        })
        #expect(model.isMutationBusy)

        // startAudit() consults the same `isMutationBusy` guard: refused
        // outright, no phase change, no task spawned.
        model.startAudit()
        #expect(model.runState == .idle)
        #expect(model.auditTask == nil)

        // Release the scan; the slot frees and startAudit() passes the guard.
        runner.proceed.signal()
        await model.cleanupScanTask?.value
        #expect(!model.isMutationBusy)
        model.startAudit()
        #expect(model.auditTask != nil)
        await model.auditTask?.value
        #expect(model.result != nil)
    }

    @Test("executeMutation() refuses while a cleanup scan is in flight, even with a gate already armed")
    func scanBlocksArmedExecute() async throws {
        // executeMutation's FIRST guard is `case .armed = mutationGatePhase`
        // — an unarmed gate would refuse for that reason alone regardless of
        // isMutationBusy, which would prove nothing about the exclusion.
        // So: arm a plain delete gate first (2 reads, unblocked), THEN start
        // a cleanup scan whose single listing read (index 2) is held open,
        // THEN attempt to dispatch the already-armed gate. Once released,
        // the SAME armed gate must still be dispatchable (4 more reads:
        // fresh listing, compile, execute, post-listing — the
        // verifiedDeleteExecution shape).
        let runner = StagedBlockingRunner(
            outputs: [
                gateListingWire(), soloSnapshotWire(),
                cleanupListingWire(copyPIDs: []),
                gateListingWire(), "", "",
                gateListingWire(excludingPersistentID: "SOLO000000000001"),
            ],
            blockAt: [2]
        )
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        // Arm a plain delete gate. Arming itself does not set isMutationBusy.
        model.startMutationAudit(kind: .delete, persistentID: "SOLO000000000001")
        await harness.awaitMutation()
        #expect(model.armedMutation != nil)
        model.typedMutationName = "Solo List"
        #expect(model.mutationGateSatisfied)

        // Start the scan; its listing read blocks at index 2.
        model.refreshCleanup()
        #expect(await pollUntil {
            if case .scanning = model.cleanupScanState { return true }
            return false
        })
        #expect(model.isMutationBusy)

        // The dispatch attempt must NOT proceed: the gate stays armed, no
        // executing phase, no new reads consumed.
        model.executeMutation()
        if case .armed = model.mutationGatePhase {} else {
            Issue.record("expected the gate to remain armed, got \(model.mutationGatePhase)")
        }

        // Release the scan; the slot frees.
        runner.proceed.signal()
        await model.cleanupScanTask?.value
        #expect(!model.isMutationBusy)

        // The SAME armed gate now dispatches for real.
        model.executeMutation()
        await harness.awaitMutation()
        guard case .finished(let display) = model.mutationGatePhase else {
            Issue.record("expected a finished phase, got \(model.mutationGatePhase)")
            return
        }
        #expect(display.verified)
    }

    @Test("refreshCleanup() itself refuses while another mutation-gate audit is in flight")
    func mutationAuditBlocksScanEntry() async throws {
        // Mirror image of scanBlocksMutationEntry: this time the OTHER
        // activity (a mutation-gate audit's own listing read) is held open,
        // and refreshCleanup() is the entry point under test.
        let runner = StagedBlockingRunner(
            outputs: [gateListingWire(), soloSnapshotWire(), cleanupListingWire(copyPIDs: [])],
            blockAt: [0]
        )
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        // mutationGatePhase is set to .auditing synchronously, before the
        // detached read stage is ever entered — no polling needed.
        model.startMutationAudit(kind: .delete, persistentID: "SOLO000000000001")
        if case .auditing = model.mutationGatePhase {} else {
            Issue.record("expected the audit stage in flight, got \(model.mutationGatePhase)")
        }
        #expect(model.isMutationBusy)

        // refreshCleanup()'s entry guard refuses outright: no phase change,
        // no task spawned.
        model.refreshCleanup()
        if case .idle = model.cleanupScanState {} else {
            Issue.record("cleanup scan must stay idle while a mutation audit runs")
        }
        #expect(model.cleanupScanTask == nil)

        // Release the held audit; the slot frees, arming completes normally.
        runner.proceed.signal()
        await harness.awaitMutation()
        #expect(!model.isMutationBusy)
        #expect(model.armedMutation != nil)

        // Cleanup can now start normally and run to completion.
        model.refreshCleanup()
        await model.cleanupScanTask?.value
        guard case .loaded = model.cleanupScanState else {
            Issue.record("expected the scan to complete, got \(model.cleanupScanState)")
            return
        }
    }
}

/// pid -> (listing id, track pid, database id, title)
private let copyFacts: [(pid: String, id: Int, trackPID: String, db: Int, title: String)] = [
    ("CPYAAAA000000001", 10, "T0000001", 1, "Alpha"),
    ("CPYBBBB000000002", 20, "T0000002", 2, "Beta"),
    ("CPYCCCC000000003", 30, "T0000003", 3, "Gamma"),
]

func cleanupOrchestrationCopies() -> [PlaylistSnapshot] {
    copyFacts.map { fact in
        PlaylistSnapshot(
            name: cleanupGroupName,
            persistentId: fact.pid,
            tracks: [presentationTrack(
                sourceIndex: 0, databaseId: fact.db,
                persistentId: fact.trackPID, title: fact.title
            )]
        )
    }
}

/// Listing wire: the named copies plus the merged target (3 tracks).
/// `includeTarget: false` drops the merged target from the listing — the
/// genuinely-absent-name case, which must stay a candidacy refusal and never
/// be mistaken for a failed read (finding I4).
func cleanupListingWire(copyPIDs: [String], includeTarget: Bool = true) -> String {
    var entries = copyFacts
        .filter { copyPIDs.contains($0.pid) }
        .map { gateEntry(id: $0.id, name: cleanupGroupName, pid: $0.pid, count: 1) }
    if includeTarget {
        entries.append(
            gateEntry(id: 100, name: cleanupTargetName, pid: "TARGET0000000001", count: 3)
        )
    }
    return "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

/// Snapshot wire serving BOTH per-name reads (parseAllCopies filters by
/// exact name): the surviving copies and the verified target, whose ordered
/// database IDs + persistent IDs match the merge plan's winners.
/// `extraPlaylists` lets the structural suite append a second group's
/// playlists to the SAME wire (never string-splice wire JSON — playlist
/// objects contain "]}" internally).
func cleanupSnapshotWire(copyPIDs: [String], extraPlaylists: [String] = []) -> String {
    var playlists = copyFacts
        .filter { copyPIDs.contains($0.pid) }
        .map { fact in
            wirePlaylist(id: fact.id, name: cleanupGroupName, persistentId: fact.pid, tracks: [
                wireTrack(sourceIndex: 0, databaseId: fact.db,
                          persistentId: fact.trackPID, title: fact.title)
            ])
        }
    playlists.append(wirePlaylist(
        id: 100, name: cleanupTargetName, persistentId: "TARGET0000000001",
        tracks: copyFacts.enumerated().map { ordinal, fact in
            wireTrack(sourceIndex: ordinal, databaseId: fact.db,
                      persistentId: fact.trackPID, title: fact.title)
        }
    ))
    playlists.append(contentsOf: extraPlaylists)
    return wireSnapshot(playlists: playlists)
}

@Suite("Cleanup group-gate orchestration (B3)")
@MainActor
struct CleanupOrchestrationTests {

    @Test("copy 2 readback failure: copy 3 never dispatched, one report, group re-auditable")
    func groupRunAbortsOnReadbackFailure() async throws {
        let allPIDs = copyFacts.map(\.pid)
        let l0 = cleanupListingWire(copyPIDs: allPIDs)                 // A, B, C live
        let l1 = cleanupListingWire(copyPIDs: [allPIDs[1], allPIDs[2]]) // A deleted
        let s0 = cleanupSnapshotWire(copyPIDs: allPIDs)
        // Scripted transcript (each read/compile/execute consumes one entry):
        //   refresh: ONE listing read (Wave C hotfix #2 — listing-only)
        //   arm:       listing, group snapshot, target snapshot
        //   copy 0:    read l0, compile, execute, read l1 (verified) + CHAIN read l1
        //   copy 1:    read l1, compile, execute, read l1 -> B still present = readback FAILURE
        //   copy 2:    NEVER dispatched (no entries left to consume proves it too)
        //   re-refresh: ONE listing read
        let runner = ScriptedRunner(outputs: [
            l0,
            l0, s0, s0,
            l0, "", "", l1, l1,
            l1, "", "", l1,
            l1,
        ])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        let plan = try buildMergePlan(name: cleanupGroupName, copies: cleanupOrchestrationCopies())
        let auditPaths = try writeMergeAudit(
            outputDir: harness.outputDirectory, plan: plan,
            now: { planDate }, timeZone: TimeZone(identifier: "UTC")!
        )
        let planFileName = artifactBasename(auditPaths.planJson)

        // Refresh: the group is a live 3-copy candidate.
        model.refreshCleanup()
        await model.cleanupScanTask?.value
        guard case .loaded(let before, _) = model.cleanupScanState else {
            Issue.record("expected .loaded, got \(model.cleanupScanState)")
            return
        }
        #expect(before.count == 1)
        #expect(before[0].disqualification == nil)
        #expect(before[0].copies.map(\.disposition) == [.live, .live, .live])

        // Arm: fresh re-check, three per-copy artifacts, ONE name token.
        model.startCleanupAudit(planFileName: planFileName)
        await harness.awaitMutation()
        let armed = try #require(model.armedMutation)
        #expect(armed.requiresCountToken == false)
        #expect(armed.requiresPIDSuffixToken == false)
        #expect(armed.plan.evidence?.mergePlanFileName == planFileName)
        #expect(model.cleanupContext?.plans.count == 3)
        #expect(model.cleanupContext?.targetGuard?.orderedTrackPersistentIDs
            == copyFacts.map(\.trackPID))

        model.typedMutationName = cleanupGroupName
        #expect(model.mutationGateSatisfied)
        model.executeMutation()
        await harness.awaitMutation()

        // Copy 3 was never dispatched: exactly 2 compiles and 2 executions.
        let commands = runner.commands
        #expect(commands.filter {
            if case .executeCompiledScript = $0 { return true }; return false
        }.count == 2)
        #expect(commands.filter {
            if case .compileAppleScript = $0 { return true }; return false
        }.count == 2)

        // Fail-closed finish with copy 2's VERBATIM mismatch.
        guard case .finished(let display) = model.mutationGatePhase else {
            Issue.record("expected .finished, got \(model.mutationGatePhase)")
            return
        }
        #expect(display.verified == false)
        #expect(display.mismatches.contains { $0.contains("CPYBBBB000000002") })
        #expect(model.cleanupContext == nil)

        // Every group artifact is consumed (execution AND abort consume).
        let reportsDir = harness.outputDirectory
        let files = try FileManager.default.contentsOfDirectory(
            at: reportsDir, includingPropertiesForKeys: nil
        )
        let copyPlans = files.filter { $0.lastPathComponent.hasSuffix(".delete.plan.json") }
        #expect(copyPlans.count == 3)
        for url in copyPlans {
            #expect(isMutationPlanConsumed(planURL: url), "\(url.lastPathComponent)")
        }

        // ONE result report: copy 1 machine-readable ok, copy 2 verbatim
        // failure, copy 3 untouched.
        let reports = files.filter { $0.lastPathComponent.contains(".mutationresult") }
        #expect(reports.count == 1)
        let reportText = try String(contentsOf: try #require(reports.first), encoding: .utf8)
        let planA = try #require(try copyPlans.first {
            try loadMutationPlan(url: $0).playlistPersistentID == "CPYAAAA000000001"
        })
        let shaA = try loadMutationPlan(url: planA).sha256Hex()
        #expect(reportText.contains("deleted-ok CPYAAAA000000001 \(shaA)"))
        #expect(reportText.contains("CPYBBBB000000002"))
        #expect(reportText.contains("NOT ATTEMPTED"))
        #expect(!reportText.contains("deleted-ok CPYBBBB000000002"))
        #expect(!reportText.contains("deleted-ok CPYCCCC000000003"))

        // Re-auditable: the report + consumed sidecar account for copy 1;
        // copies 2 and 3 are live again as a surviving candidate.
        model.refreshCleanup()
        await model.cleanupScanTask?.value
        guard case .loaded(let after, _) = model.cleanupScanState else {
            Issue.record("expected .loaded after re-refresh, got \(model.cleanupScanState)")
            return
        }
        #expect(after.count == 1)
        #expect(after[0].disqualification == nil)
        #expect(after[0].copies.map(\.disposition) == [.alreadyDeleted, .live, .live])
    }

    @Test("dismissing an armed group gate consumes every copy artifact")
    func dismissConsumesGroupArtifacts() async throws {
        let allPIDs = copyFacts.map(\.pid)
        let l0 = cleanupListingWire(copyPIDs: allPIDs)
        let s0 = cleanupSnapshotWire(copyPIDs: allPIDs)
        // refresh: ONE listing read; arm: listing + group snapshot + target snapshot.
        let runner = ScriptedRunner(outputs: [l0, l0, s0, s0])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        let plan = try buildMergePlan(name: cleanupGroupName, copies: cleanupOrchestrationCopies())
        let auditPaths = try writeMergeAudit(
            outputDir: harness.outputDirectory, plan: plan,
            now: { planDate }, timeZone: TimeZone(identifier: "UTC")!
        )
        model.refreshCleanup()
        await model.cleanupScanTask?.value
        model.startCleanupAudit(planFileName: artifactBasename(auditPaths.planJson))
        await harness.awaitMutation()
        #expect(model.cleanupContext?.paths.count == 3)

        model.dismissMutationGate()

        #expect(model.cleanupContext == nil)
        let copyPlans = try FileManager.default.contentsOfDirectory(
            at: harness.outputDirectory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".delete.plan.json") }
        #expect(copyPlans.count == 3)
        for url in copyPlans {
            #expect(isMutationPlanConsumed(planURL: url), "\(url.lastPathComponent)")
        }
        // A consumed group can never re-arm: the fresh audit path refuses at
        // the arm re-check (rule 2 finds no accounting for consumed-but-live
        // copies only via artifacts; here nothing was deleted so the group is
        // simply re-auditable from scratch on the next refresh).
        if case .refused = model.mutationGatePhase {
            Issue.record("dismiss from armed must land in .idle, not .refused")
        }
    }

    @Test("arming one group among 100 discovered costs exactly 1 listing + 2 snapshot reads")
    func armSingleGroupAmongManyStaysScoped() async throws {
        let utc = TimeZone(identifier: "UTC")!
        struct SyntheticGroup {
            let name: String
            let copyAPID: String
            let copyBPID: String
            let trackAPID: String
            let trackBPID: String
            let targetPID: String
        }
        let groups = (0..<100).map { i -> SyntheticGroup in
            let stamp = String(format: "%012d", i)
            return SyntheticGroup(
                name: "Group\(String(format: "%04d", i))",
                copyAPID: "CPYA\(stamp)",
                copyBPID: "CPYB\(stamp)",
                trackAPID: "TRKA\(stamp)",
                trackBPID: "TRKB\(stamp)",
                targetPID: "TGT0\(stamp)"
            )
        }

        // ONE big listing wire: every group's 2 copies + 1 target (300 rows).
        var listingEntries: [String] = []
        var nextListingID = 0
        for group in groups {
            listingEntries.append(
                gateEntry(id: nextListingID, name: group.name, pid: group.copyAPID, count: 1)
            )
            nextListingID += 1
            listingEntries.append(
                gateEntry(id: nextListingID, name: group.name, pid: group.copyBPID, count: 1)
            )
            nextListingID += 1
            listingEntries.append(gateEntry(
                id: nextListingID, name: "\(group.name) \u{2014} Merged",
                pid: group.targetPID, count: 2
            ))
            nextListingID += 1
        }
        let bigListing = "{\"playlists\": [\(listingEntries.joined(separator: ", "))]}"

        // ONE snapshot wire covering ONLY the pinned group's names.
        let pinned = groups[42]
        let snapshotWire = wireSnapshot(playlists: [
            wirePlaylist(id: 900, name: pinned.name, persistentId: pinned.copyAPID, tracks: [
                wireTrack(sourceIndex: 0, databaseId: 1, persistentId: pinned.trackAPID, title: "A42"),
            ]),
            wirePlaylist(id: 901, name: pinned.name, persistentId: pinned.copyBPID, tracks: [
                wireTrack(sourceIndex: 0, databaseId: 2, persistentId: pinned.trackBPID, title: "B42"),
            ]),
            wirePlaylist(
                id: 902, name: "\(pinned.name) \u{2014} Merged", persistentId: pinned.targetPID,
                tracks: [
                    wireTrack(sourceIndex: 0, databaseId: 1, persistentId: pinned.trackAPID, title: "A42"),
                    wireTrack(sourceIndex: 1, databaseId: 2, persistentId: pinned.trackBPID, title: "B42"),
                ]
            ),
        ])

        // listing queued twice (refresh + arm); snapshot queued twice (group
        // name + target name reads at arm) — 4 outputs total for 100 groups.
        let runner = ScriptedRunner(outputs: [bigListing, bigListing, snapshotWire, snapshotWire])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model

        var pinnedPlanFileName = ""
        for group in groups {
            let copies = [
                PlaylistSnapshot(name: group.name, persistentId: group.copyAPID, tracks: [
                    presentationTrack(
                        sourceIndex: 0, databaseId: 1, persistentId: group.trackAPID, title: "A42"
                    ),
                ]),
                PlaylistSnapshot(name: group.name, persistentId: group.copyBPID, tracks: [
                    presentationTrack(
                        sourceIndex: 0, databaseId: 2, persistentId: group.trackBPID, title: "B42"
                    ),
                ]),
            ]
            let plan = try buildMergePlan(name: group.name, copies: copies)
            let auditPaths = try writeMergeAudit(
                outputDir: harness.outputDirectory, plan: plan, now: { planDate }, timeZone: utc
            )
            if group.name == pinned.name {
                pinnedPlanFileName = artifactBasename(auditPaths.planJson)
            }
        }
        #expect(!pinnedPlanFileName.isEmpty)

        model.refreshCleanup()
        await model.cleanupScanTask?.value
        guard case .loaded(let candidates, _) = model.cleanupScanState else {
            Issue.record("expected .loaded, got \(model.cleanupScanState)")
            return
        }
        #expect(candidates.count == 100)
        #expect(candidates.allSatisfy { $0.disqualification == nil })

        // Arming ONE group must not scale with the other 99 discovered.
        let before = runner.commands.count
        model.startCleanupAudit(planFileName: pinnedPlanFileName)
        await harness.awaitMutation()

        #expect(runner.commands.count - before == 3)
        #expect(model.armedMutation != nil)
        #expect(model.cleanupContext?.plans.count == 2)
    }
}

// MARK: - read failure vs evidence drift (final review, finding I4, 2026-08-11)

@Suite("Cleanup gate-arm read failures are not evidence drift")
@MainActor
struct CleanupReadFailureTests {

    // Before I4 the gate-arm live sample swallowed EVERY snapshot-read error
    // with `try?`, so the columnar reader's fail-closed column guards
    // ("column length mismatch: title", a mid-scan mutation), an Automation
    // denial, and a strict-parse rejection all arrived as an EMPTY copy list —
    // and armVerification then blamed the library: "merged target ... was not
    // found" / "copy ... no longer bears the group name". Same fail-closed
    // outcome (nothing is deleted either way), but the stated reason was false
    // and pointed the operator at the wrong thing. The read failure is now its
    // own refusal, carrying the verbatim operator message.
    @Test("a column-mismatch error on the group snapshot read refuses as a READ failure")
    func columnMismatchOnSnapshotReadRefusesAsReadFailure() async throws {
        let allPIDs = copyFacts.map(\.pid)
        let listing = cleanupListingWire(copyPIDs: allPIDs)
        let snapshot = cleanupSnapshotWire(copyPIDs: allPIDs)
        // refresh: listing. arm: listing, GROUP snapshot (fails), target snapshot.
        let runner = ScriptedRunner(results: [
            .success(listing),
            .success(listing),
            .failure(MusicCommandError("column length mismatch: title")),
            .success(snapshot),
        ])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        let plan = try buildMergePlan(name: cleanupGroupName, copies: cleanupOrchestrationCopies())
        let auditPaths = try writeMergeAudit(
            outputDir: harness.outputDirectory, plan: plan,
            now: { planDate }, timeZone: TimeZone(identifier: "UTC")!
        )

        model.refreshCleanup()
        await model.cleanupScanTask?.value
        model.startCleanupAudit(planFileName: artifactBasename(auditPaths.planJson))
        await harness.awaitMutation()

        guard case .refused(let reason) = model.mutationGatePhase else {
            Issue.record("expected .refused, got \(model.mutationGatePhase)")
            return
        }
        // The read failure, verbatim, named as a read failure...
        #expect(reason.contains("column length mismatch: title"))
        #expect(reason.contains("live read"))
        #expect(reason.contains("read failure, not drift"))
        // ...and NOT the drifted-evidence verdicts the swallowed error produced.
        #expect(!reason.contains("was not found"))
        #expect(!reason.contains("no longer bears the group name"))
        // Fail-closed: nothing armed, no per-copy delete artifact written.
        #expect(model.armedMutation == nil)
        #expect(model.cleanupContext == nil)
        let deletePlans = try FileManager.default.contentsOfDirectory(
            at: harness.outputDirectory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".delete.plan.json") }
        #expect(deletePlans.isEmpty)
    }

    // The complementary case must keep working: a name that is genuinely
    // ABSENT from the library is not a read failure, so it still flows to the
    // ordinary candidacy/verification refusal wording rather than the new one.
    @Test("a genuinely absent target is still reported as drift, not as a read failure")
    func absentTargetStillReportsDrift() async throws {
        let allPIDs = copyFacts.map(\.pid)
        // A listing WITHOUT the merged target: the target name is absent, so no
        // snapshot read is attempted for it at all.
        let listing = cleanupListingWire(copyPIDs: allPIDs, includeTarget: false)
        let snapshot = cleanupSnapshotWire(copyPIDs: allPIDs)
        let runner = ScriptedRunner(outputs: [listing, listing, snapshot])
        let harness = try MutationGateHarness(runner: runner)
        defer { harness.cleanUp() }
        let model = harness.model
        let plan = try buildMergePlan(name: cleanupGroupName, copies: cleanupOrchestrationCopies())
        let auditPaths = try writeMergeAudit(
            outputDir: harness.outputDirectory, plan: plan,
            now: { planDate }, timeZone: TimeZone(identifier: "UTC")!
        )

        model.refreshCleanup()
        await model.cleanupScanTask?.value
        model.startCleanupAudit(planFileName: artifactBasename(auditPaths.planJson))
        await harness.awaitMutation()

        guard case .refused(let reason) = model.mutationGatePhase else {
            Issue.record("expected .refused, got \(model.mutationGatePhase)")
            return
        }
        #expect(reason.contains("target absent from the live listing"))
        #expect(!reason.contains("read failure, not drift"))
    }
}
