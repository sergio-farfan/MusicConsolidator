// ApplyPresentationTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// M9 — pure presentation layer under screens 4-6: the cli.py post-apply
// output ported byte-for-byte (the success sentence contract), the apply
// stage labels, and the failure classifier (distinct rendering per
// PlanLoadError case, MusicCommandError = automation, MusicBridgeError =
// library drift, verification failure carrying verbatim mismatches).

import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

@Suite("Apply success text (cli.py post-apply output, ported verbatim)")
struct ApplySuccessTextTests {

    // cli.py:107-110 / 169-172
    @Test("the verification sentences match cli.py byte for byte")
    func verificationSentences() {
        #expect(
            applyVerifiedText(mode: .consolidate)
                == "Verified: source playlist unchanged; consolidated playlist "
                + "readback matches plan."
        )
        #expect(
            applyVerifiedText(mode: .merge)
                == "Verified: source copies unchanged; merged playlist "
                + "readback matches plan."
        )
    }

    // cli.py:111-114 / 173-176
    @Test("the next-gate guidance matches cli.py byte for byte")
    func nextGateText() {
        #expect(
            applyNextGateText(mode: .consolidate)
                == "Next gate: inspect the playlist in Music, including unavailable-item "
                + "flags and several quality decisions."
        )
        #expect(
            applyNextGateText(mode: .merge)
                == "Next gate: inspect the merged playlist in Music, including unavailable-item "
                + "flags and several quality decisions."
        )
    }

    // Deliberate deviation from the verbatim cli.py port (fix round 1,
    // minor e): the CLI's pilot-specific phrasing is replaced by a
    // self-contained, time-proof reminder with the same substance.
    @Test("the deletion reminder is self-contained and keeps the substance")
    func deletionReminder() {
        #expect(
            applyDeletionReminderText(mode: .consolidate)
                == "Do not delete the source or the new playlist until you have "
                + "inspected and approved the result in Music; deletion is always a "
                + "separate, manual decision \u{2014} never part of an apply."
        )
        #expect(
            applyDeletionReminderText(mode: .merge)
                == "Do not delete any source copy until you have inspected and "
                + "approved the merged playlist in Music; deletion is always a "
                + "separate, manual decision \u{2014} never part of an apply."
        )
    }
}

@Suite("Apply stage labels")
struct ApplyStageLabelTests {

    @Test("every stage has a distinct, non-empty label; no bare spinner text")
    func distinctLabels() {
        let stages: [ApplyStage] = [.loadingPlan] + ApplyPhase.allCases.map { .bridge($0) }
        let labels = stages.map(applyStageLabel)
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == labels.count)
        #expect(applyStageLabel(.bridge(.executingGuardedWrite))
            == "Executing the guarded write\u{2026}")
        #expect(applyStageLabel(.loadingPlan)
            == "Loading the approved plan artifact\u{2026}")
    }
}

@Suite("Apply failure classification")
struct ApplyFailureClassificationTests {

    @Test("the four PlanLoadError cases classify distinctly with distinct copy")
    func planLoadCases() {
        let cases: [(PlanLoadError, ApplyFailureDisplayClass, String)] = [
            (
                .fileUnreadable(path: "/x/p.plan.json", detail: "gone"),
                .planFileUnreadable,
                "Plan file unreadable"
            ),
            (
                .malformedJSON(path: "/x/p.plan.json", detail: "bad token"),
                .planMalformedJSON,
                "Plan file rejected \u{2014} not valid JSON"
            ),
            (
                .decodeRejected(detail: "plan missing field(s): decisions"),
                .planDecodeRejected,
                "Plan file rejected \u{2014} strict decode failed"
            ),
            (
                .integrityRejected(detail: "fingerprint mismatch"),
                .planIntegrityRejected,
                "Plan file rejected \u{2014} integrity check failed"
            ),
        ]
        var headlines: Set<String> = []
        var guidances: Set<String> = []
        for (error, expectedClass, expectedHeadline) in cases {
            let display = classifyApplyFailure(error)
            #expect(display.failureClass == expectedClass)
            #expect(display.headline == expectedHeadline)
            // The verbatim loader message is preserved.
            #expect(display.message == String(describing: error))
            #expect(display.mismatches.isEmpty)
            headlines.insert(display.headline)
            guidances.insert(display.guidance)
        }
        #expect(headlines.count == 4)
        #expect(guidances.count == 4)
    }

    @Test("MusicCommandError is the automation class; the message is verbatim")
    func automationClass() {
        let display = classifyApplyFailure(
            MusicCommandError("JXA execution failed: error -600")
        )
        #expect(display.failureClass == .automationFailed)
        #expect(display.headline == "Automation failed")
        #expect(display.message == "JXA execution failed: error -600")
        #expect(display.guidance.contains("Music"))
    }

    @Test("MusicBridgeError is the library-drift class with fresh-audit guidance")
    func libraryDriftClass() {
        let display = classifyApplyFailure(
            MusicBridgeError("live copy count changed after audit: planned 2, actual 1; create a fresh audit")
        )
        #expect(display.failureClass == .libraryDrift)
        #expect(display.headline == "Library changed since the check")
        #expect(display.message
            == "live copy count changed after audit: planned 2, actual 1; create a fresh audit")
        #expect(display.guidance.contains("fresh check"))
    }

    @Test("an unknown error class falls into unexpected, message verbatim")
    func unexpectedClass() {
        let display = classifyApplyFailure(AppTestError("bizarre"))
        #expect(display.failureClass == .unexpected)
        #expect(display.message == "bizarre")
    }

    @Test("a verification failure carries the mismatches verbatim and both counts")
    func verificationFailureDisplay() {
        let result = ApplyResult(
            sourceFingerprint: String(repeating: "a", count: 64),
            plannedCount: 10,
            actualCount: 7,
            verificationOk: false,
            mismatches: [
                "write failed: simulated writer failure",
                "track count mismatch: planned 10, actual 7",
                "track 8 missing: planned database ID 8, persistent ID 'H'",
            ]
        )
        let display = applyVerificationFailureDisplay(result)
        #expect(display.failureClass == .verificationFailed)
        #expect(display.headline == "Apply failed closed \u{2014} verification did not pass")
        #expect(display.mismatches == result.mismatches)
        #expect(display.plannedCount == 10)
        #expect(display.actualCount == 7)
        #expect(display.guidance.contains("fresh check"))
    }
}

// MARK: - Wave A (A3): the steps table rows — all 7 up front

@Suite("Apply stage table rows (A3: all rows up front)")
struct ApplyStageRowTests {

    private let sequence = [ApplyStage.loadingPlan] + ApplyPhase.allCases.map(ApplyStage.bridge)

    @Test("an empty stage list yields 7 pending rows in guarded order")
    func allPending() {
        let rows = applyStageRows(stages: [])
        #expect(rows.count == 7)
        #expect(rows.map(\.stage) == sequence)
        #expect(rows.allSatisfy { $0.status == .pending })
        #expect(rows.map(\.label) == sequence.map(applyStageLabel))
    }

    @Test("three started stages yield 2 completed + 1 current + 4 pending")
    func threeStarted() {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let entries = sequence.prefix(3).enumerated().map { offset, stage in
            ApplyStageEntry(stage: stage, started: base.addingTimeInterval(Double(offset) * 10))
        }
        let rows = applyStageRows(stages: Array(entries))
        // Frozen elapsed rule kept exactly: next entry's start minus own start.
        #expect(rows[0].status == .completed(
            started: base, finishedAt: base.addingTimeInterval(10)
        ))
        #expect(rows[1].status == .completed(
            started: base.addingTimeInterval(10), finishedAt: base.addingTimeInterval(20)
        ))
        #expect(rows[2].status == .current(started: base.addingTimeInterval(20)))
        #expect(rows[3...].allSatisfy { $0.status == .pending })
    }

    @Test("all seven started stages yield 6 completed + a final current row")
    func allStarted() {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let entries = sequence.enumerated().map { offset, stage in
            ApplyStageEntry(stage: stage, started: base.addingTimeInterval(Double(offset) * 5))
        }
        let rows = applyStageRows(stages: entries)
        #expect(rows.prefix(6).allSatisfy {
            if case .completed = $0.status { return true }
            return false
        })
        #expect(rows[6].status == .current(started: base.addingTimeInterval(30)))
    }
}
