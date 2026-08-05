// ApplyFailureCaptureTests.swift
// Wave C1 Task 3 — the model captures the failed stage race-free and
// classifies every failed apply (spec C1.3): the attended state gains
// applyFailureClass, RunItemRecord gains failureClass on the batch path,
// and renderRunReportText emits the two additive lines. Three end-to-end
// replays: Goddesses (existing-target refusal), a writer failure, and
// Daechir ESP ORIG (source drift after a verified write — which also pins
// plan-header finding 1: the target readback command is dispatched even
// though source mismatches exist).

import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

/// The audited source re-read back with ONE drifted field (track 1 bit rate
/// 128 -> 96): sourceMismatches reports it and the fingerprint, and both
/// lines begin "source ".
private func driftedSourceReadbackWire() -> String {
    wireSnapshot(playlists: [
        wirePlaylist(
            id: 100, name: "Fixture List", persistentId: "PLAYLIST0",
            tracks: [
                wireTrack(
                    sourceIndex: 0, databaseId: 11, persistentId: "AAAA0001",
                    title: "Shared Song", bitRate: 96
                ),
                wireTrack(
                    sourceIndex: 1, databaseId: 12, persistentId: "AAAA0002",
                    title: "Shared Song", bitRate: 256
                ),
                wireTrack(
                    sourceIndex: 2, databaseId: 13, persistentId: "AAAA0003",
                    title: "Only Once"
                ),
                wireTrack(
                    sourceIndex: 3, databaseId: 14, persistentId: "AAAA0004",
                    title: "No Duration", duration: nil
                ),
            ]
        )
    ])
}

@MainActor
@Suite("Wave C1 — failed-stage capture and classification (model)")
struct ApplyFailureCaptureTests {

    @Test("Goddesses replay: the existing-target refusal classifies refusedBeforeWrite")
    func goddessesExistingTargetRefusal() async throws {
        // Audit read, ensure re-read (match), then the target-absent read
        // finds an exact-name target -> MusicBridgeError thrown at
        // assertingTargetAbsent, before any write.
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

        guard case .failed(let failure) = harness.model.applyState else {
            Issue.record("expected a failed apply, got \(harness.model.applyState)")
            return
        }
        #expect(failure.message.contains("target user playlist already exists"))
        #expect(harness.model.applyFailureClass == .refusedBeforeWrite)
        #expect(runner.commands.count == 3)
    }

    @Test("writer failure: returned result with 'write failed:' first classifies writerFailed")
    func writerFailureClassifiesWriterFailed() async throws {
        let runner = ScriptedRunner(results: [
            .success(consolidateFixtureWire()),
            .success(consolidateFixtureWire()),
            .success(emptySnapshotWire()),
            .success(""),
            .failure(MusicCommandError(
                "osascript exited 1: execution error: Guarded write refused (-2700)"
            )),
            .success(consolidateFixtureWire()),
            .success(emptySnapshotWire()),
        ])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        try await harness.auditAndSatisfyGate()
        harness.model.startApply()
        await harness.awaitApply()

        guard case .failed(let failure) = harness.model.applyState else {
            Issue.record("expected a failed apply, got \(harness.model.applyState)")
            return
        }
        // The bridge contract rule 2 rides on: "write failed: …" is FIRST.
        let first = try #require(failure.mismatches.first)
        #expect(scalarHasPrefix(first, "write failed: "))
        #expect(harness.model.applyFailureClass == .writerFailed)
    }

    @Test("Daechir replay: all-source mismatches classify sourceDrifted; target readback still ran")
    func daechirSourceDrift() async throws {
        let runner = ScriptedRunner(outputs: [
            consolidateFixtureWire(),          // audit
            consolidateFixtureWire(),          // ensure re-read (matches)
            emptySnapshotWire(),               // target absent
            "",                                // compile
            "",                                // execute (clean)
            driftedSourceReadbackWire(),       // source readback DRIFTED
            consolidateTargetReadbackWire(),   // target readback verifies clean
        ])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        try await harness.auditAndSatisfyGate()
        harness.model.startApply()
        await harness.awaitApply()

        guard case .failed(let failure) = harness.model.applyState else {
            Issue.record("expected a failed apply, got \(harness.model.applyState)")
            return
        }
        #expect(!failure.mismatches.isEmpty)
        for line in failure.mismatches {
            #expect(scalarHasPrefix(line, "source "), "non-source line: \(line)")
        }
        #expect(harness.model.applyFailureClass == .sourceDrifted)
        // Plan-header finding 1 pinned at the app layer: the 7th command IS
        // the target readback — it ran despite the source mismatches.
        #expect(runner.commands.count == 7)
    }

    @Test("success and a fresh apply clear the class; batch records carry it")
    func classLifecycleAndBatchRecord() async throws {
        // Unattended single-item run whose apply is a writer failure: the
        // finished report's record must carry the class and the target name.
        let listing = "{\"playlists\": ["
            + gateEntry(id: 10, name: "Fixture List", pid: "P-FX", count: 4) + "]}"
        let runner = ScriptedRunner(results: [
            .success(listing),
            .success(consolidateFixtureWire()),
            .success(consolidateFixtureWire()),
            .success(emptySnapshotWire()),
            .success(""),
            .failure(MusicCommandError("osascript exited 1: writer blew up")),
            .success(consolidateFixtureWire()),
            .success(emptySnapshotWire()),
        ])
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "",
            confirmEachApply: false
        )
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-FX")
        harness.model.startQueue()
        #expect(await pollUntil { harness.model.finishedRunReport != nil })

        let report = try #require(harness.model.finishedRunReport)
        #expect(report.items.count == 1)
        let item = try #require(report.items.first)
        #expect(item.outcome.label == "failed")
        #expect(item.failureClass == .writerFailed)
        #expect(item.targetName == "Fixture List \u{2014} Consolidated")
        // The report screen replaced the apply state; the paired attended
        // class was cleared with it (discardCompletedAudit).
        #expect(harness.model.applyFailureClass == nil)
    }

    @Test("a verified apply leaves applyFailureClass nil")
    func successLeavesClassNil() async throws {
        let runner = ScriptedRunner(
            outputs: [consolidateFixtureWire()] + consolidateApplyOutputs()
        )
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        try await harness.auditAndSatisfyGate()
        harness.model.startApply()
        await harness.awaitApply()
        guard case .succeeded = harness.model.applyState else {
            Issue.record("expected a verified apply")
            return
        }
        #expect(harness.model.applyFailureClass == nil)
    }
}

@Suite("Wave C1 — run report renderer lines")
struct RunReportFailureClassRenderingTests {

    private func record(
        outcome: RunItemOutcome,
        failureClass: ApplyFailureClass?,
        targetName: String?
    ) -> RunItemRecord {
        RunItemRecord(
            name: "Daechir ESP ORIG",
            outcome: outcome,
            failureClass: failureClass,
            inputCount: 143, outputCount: 143,
            nearIdenticalPairLines: [], distinctOmissionLines: [],
            countAnomalyLines: [],
            targetName: targetName,
            planFileName: "Daechir-ESP-ORIG-20260804-1.plan.json",
            elapsedSeconds: 12
        )
    }

    private func render(_ item: RunItemRecord) -> String {
        renderRunReportText(BatchRunReport(
            mode: .consolidate,
            unattended: true,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_000_060),
            stoppedEarly: false,
            items: [item]
        ))
    }

    @Test("a classified failure emits both lines, after the verbatim line, never Created")
    func failedItemLines() throws {
        let text = render(record(
            outcome: .failed(reason: "source track count mismatch after write: "
                + "planned 143, actual 141"),
            failureClass: .sourceDrifted,
            targetName: "Daechir ESP ORIG \u{2014} Consolidated"
        ))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let index = try #require(lines.firstIndex {
            $0.hasPrefix("- Failure (verbatim): ")
        })
        #expect(lines[index + 1] == "- Failure class: "
            + "Source drifted after a verified write \u{2014} the created target "
            + "matches the plan, but the source changed after the audit.")
        #expect(lines[index + 2]
            == "- Leftover target: Daechir ESP ORIG \u{2014} Consolidated")
        #expect(!text.contains("- Created:"))
    }

    @Test("refusedBeforeWrite emits the class line but never a leftover line")
    func refusedBeforeWriteNoLeftover() {
        let text = render(record(
            outcome: .failed(reason: "target user playlist already exists"),
            failureClass: .refusedBeforeWrite,
            targetName: "Goddesses \u{2014} Consolidated"
        ))
        #expect(text.contains(
            "- Failure class: Refused before write \u{2014} nothing was created."))
        #expect(!text.contains("- Leftover target:"))
    }

    @Test("a nil class (pre-C1 record) renders neither new line")
    func nilClassRendersNothingNew() {
        let text = render(record(
            outcome: .failed(reason: "live copy count changed after audit"),
            failureClass: nil,
            targetName: nil
        ))
        #expect(!text.contains("- Failure class:"))
        #expect(!text.contains("- Leftover target:"))
    }

    @Test("a leftover line needs a target name even for leftover-capable classes")
    func leftoverNeedsTargetName() {
        let text = render(record(
            outcome: .failed(reason: "write failed: boom"),
            failureClass: .writerFailed,
            targetName: nil
        ))
        #expect(text.contains("- Failure class: Writer failed during the guarded "
            + "write \u{2014} a partial target may exist."))
        #expect(!text.contains("- Leftover target:"))
    }
}
