// QueueStatusPresentationTests.swift
// Wave A (A1 + A5) — the pure queue-status presentation layer: display-
// state derivation (the five stored AuditQueueStatus cases plus the two
// live states derived from current-row + RunState/ApplyState) and the
// shared symbol/tint/label style map every queue surface and the steps
// table share. Pure functions only; no Music, no scripts, no I/O.

import SwiftUI
import Testing
@testable import AppleMusicConsolidatorApp

@Suite("Queue status presentation (A1 + A5)")
struct QueueStatusPresentationTests {

    // MARK: - display-state derivation

    @Test("non-current rows map every stored status directly")
    func nonCurrentRowsMapDirectly() {
        #expect(
            queueDisplayState(
                status: .pending, isCurrent: false, isAuditRunning: false, applyStageCount: nil
            ) == .pending
        )
        #expect(
            queueDisplayState(
                status: .audited, isCurrent: false, isAuditRunning: false, applyStageCount: nil
            ) == .awaitingReview
        )
        #expect(
            queueDisplayState(
                status: .applied, isCurrent: false, isAuditRunning: false, applyStageCount: nil
            ) == .applied
        )
        #expect(
            queueDisplayState(
                status: .skipped, isCurrent: false, isAuditRunning: false, applyStageCount: nil
            ) == .skipped
        )
        #expect(
            queueDisplayState(
                status: .failed, isCurrent: false, isAuditRunning: false, applyStageCount: nil
            ) == .failed
        )
    }

    @Test("a non-current row never goes live, even while the model is busy")
    func nonCurrentRowsIgnoreLiveActivity() {
        // The audit/apply in flight belongs to the CURRENT row only; other
        // rows keep their stored mapping.
        #expect(
            queueDisplayState(
                status: .pending, isCurrent: false, isAuditRunning: true, applyStageCount: nil
            ) == .pending
        )
        #expect(
            queueDisplayState(
                status: .audited, isCurrent: false, isAuditRunning: false, applyStageCount: 3
            ) == .awaitingReview
        )
    }

    @Test("the current pending row is live while its audit runs")
    func currentAuditing() {
        #expect(
            queueDisplayState(
                status: .pending, isCurrent: true, isAuditRunning: true, applyStageCount: nil
            ) == .auditing
        )
        // Current but idle (e.g. the judgment pause landed elsewhere):
        // stored mapping.
        #expect(
            queueDisplayState(
                status: .pending, isCurrent: true, isAuditRunning: false, applyStageCount: nil
            ) == .pending
        )
    }

    @Test("the current audited row applies live, otherwise awaits review")
    func currentApplyingOrAwaitingReview() {
        #expect(
            queueDisplayState(
                status: .audited, isCurrent: true, isAuditRunning: false, applyStageCount: 3
            ) == .applying(step: 3, total: 7)
        )
        // The paused-for-review current case (spec A1 "audited - paused
        // for review").
        #expect(
            queueDisplayState(
                status: .audited, isCurrent: true, isAuditRunning: false, applyStageCount: nil
            ) == .awaitingReview
        )
    }

    @Test("terminal statuses map directly even on the current row")
    func currentTerminalStatuses() {
        #expect(
            queueDisplayState(
                status: .applied, isCurrent: true, isAuditRunning: false, applyStageCount: nil
            ) == .applied
        )
        #expect(
            queueDisplayState(
                status: .skipped, isCurrent: true, isAuditRunning: false, applyStageCount: nil
            ) == .skipped
        )
        #expect(
            queueDisplayState(
                status: .failed, isCurrent: true, isAuditRunning: false, applyStageCount: nil
            ) == .failed
        )
    }

    // MARK: - the applying total is pluggable (Wave A fix wave, finding 3)

    @Test("total defaults to the six-phase apply total for callers that omit it")
    func totalDefaultsWhenOmitted() {
        #expect(
            queueDisplayState(
                status: .audited, isCurrent: true, isAuditRunning: false, applyStageCount: 3
            ) == .applying(step: 3, total: 7)
        )
    }

    @Test("an explicit total overrides the default")
    func totalIsPluggable() {
        #expect(
            queueDisplayState(
                status: .audited, isCurrent: true, isAuditRunning: false,
                applyStageCount: 3, total: 9
            ) == .applying(step: 3, total: 9)
        )
    }

    // MARK: - the style map (spec A1, full table)

    @Test("the style map matches the A1 table exactly")
    func styleMap() {
        let pending = QueueStatusStyle.style(for: .pending)
        #expect(
            pending == QueueStatusStyle(
                symbolName: "circle.dotted", tint: .gray, label: "pending"
            )
        )
        #expect(!pending.isLive)

        let auditing = QueueStatusStyle.style(for: .auditing)
        #expect(
            auditing == QueueStatusStyle(symbolName: nil, tint: .blue, label: "reading\u{2026}")
        )
        #expect(auditing.isLive)

        let awaiting = QueueStatusStyle.style(for: .awaitingReview)
        #expect(
            awaiting == QueueStatusStyle(
                symbolName: "doc.text.magnifyingglass", tint: .orange, label: "awaiting review"
            )
        )
        #expect(!awaiting.isLive)

        let applying = QueueStatusStyle.style(for: .applying(step: 2, total: 7))
        #expect(
            applying == QueueStatusStyle(
                symbolName: nil, tint: .blue, label: "applying step 2 of 7"
            )
        )
        #expect(applying.isLive)

        let applied = QueueStatusStyle.style(for: .applied)
        #expect(
            applied == QueueStatusStyle(
                symbolName: "checkmark.circle.fill", tint: .green, label: "applied"
            )
        )
        #expect(!applied.isLive)

        let skipped = QueueStatusStyle.style(for: .skipped)
        #expect(
            skipped == QueueStatusStyle(
                symbolName: "arrow.uturn.forward.circle", tint: .gray, label: "skipped"
            )
        )
        #expect(!skipped.isLive)

        let failed = QueueStatusStyle.style(for: .failed)
        #expect(
            failed == QueueStatusStyle(
                symbolName: "xmark.octagon.fill", tint: .red, label: "failed"
            )
        )
        #expect(!failed.isLive)
    }

    // MARK: - shared track-count wording (spec A5)

    @Test("no counts renders as the empty string")
    func emptyCounts() {
        #expect(trackCountText(copyCounts: []) == "")
    }

    @Test("a single count renders singular or plural")
    func singleCount() {
        #expect(trackCountText(copyCounts: [1]) == "1 track")
        #expect(trackCountText(copyCounts: [551]) == "551 tracks")
    }

    @Test("group counts join with plus in copy order and stay plural")
    func groupCounts() {
        #expect(trackCountText(copyCounts: [9, 10]) == "9 + 10 tracks")
        #expect(trackCountText(copyCounts: [12, 8, 31]) == "12 + 8 + 31 tracks")
    }
}
