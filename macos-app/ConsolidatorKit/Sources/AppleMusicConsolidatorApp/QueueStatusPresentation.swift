// QueueStatusPresentation.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Wave A (A1 + A5) — pure presentation under the queue tables and the
// steps table: the DERIVED display state (the stored AuditQueueStatus
// keeps exactly its five cases; the two live states exist only here,
// computed per render from current-row + RunState/ApplyState), the single
// symbol/tint/label style map every queue surface shares so colors agree
// app-wide, and the shared track-count wording. Everything here is a
// value-typed pure function — headlessly testable, no Music, no I/O,
// nothing serialized.

import SwiftUI

/// The presentation-layer state of one queue row (spec A1). Five of the
/// seven cases mirror the stored `AuditQueueStatus`; `auditing` and
/// `applying` are LIVE states derived from `queueIndex` plus
/// `RunState`/`ApplyState` — no state-machine change, no persistence.
nonisolated enum QueueDisplayState: Equatable, Sendable {
    case pending
    case auditing
    case awaitingReview
    case applying(step: Int, total: Int)
    case applied
    case skipped
    case failed
}

/// Derive one row's display state.
/// - `isCurrent`: this row's index == `model.queueIndex` while the queue
///   is active.
/// - `isAuditRunning`: the caller passes `if case .running = runState`.
/// - `applyStageCount`: the caller passes `stages.count` when `ApplyState`
///   is `.running(stages)`, else nil.
/// - `total`: the apply stage total for the "applying step k of N" label
///   (Wave A fix wave, finding 3). This file must not import MusicBridge
///   to compute `1 + ApplyPhase.allCases.count` itself, so the caller
///   (`queueTableRows`, which does see `ApplyPhase`) derives and passes it
///   through; the default keeps this function's prior behavior for any
///   caller that omits it.
/// Non-current rows map the stored status directly (`.audited` renders as
/// `awaitingReview`); only the current row can be live.
nonisolated func queueDisplayState(
    status: AuditQueueStatus,
    isCurrent: Bool,
    isAuditRunning: Bool,
    applyStageCount: Int?,
    total: Int = 7
) -> QueueDisplayState {
    switch status {
    case .pending:
        return (isCurrent && isAuditRunning) ? .auditing : .pending
    case .audited:
        if isCurrent, let stageCount = applyStageCount {
            return .applying(step: stageCount, total: total)
        }
        return .awaitingReview
    case .applied:
        return .applied
    case .skipped:
        return .skipped
    case .failed:
        return .failed
    }
}

/// One display state's rendering: SF Symbol name (nil means a live spinner
/// instead of a symbol), tint, and chip label — the single style map of
/// spec A1, shared by both queue surfaces and the steps table.
nonisolated struct QueueStatusStyle: Equatable {
    let symbolName: String?
    let tint: Color
    let label: String

    var isLive: Bool { symbolName == nil }

    static func style(for state: QueueDisplayState) -> QueueStatusStyle {
        switch state {
        case .pending:
            return QueueStatusStyle(
                symbolName: "circle.dotted", tint: .gray, label: "pending"
            )
        case .auditing:
            return QueueStatusStyle(symbolName: nil, tint: .blue, label: "reading\u{2026}")
        case .awaitingReview:
            return QueueStatusStyle(
                symbolName: "doc.text.magnifyingglass",
                tint: .orange,
                label: "awaiting review"
            )
        case .applying(let step, let total):
            return QueueStatusStyle(
                symbolName: nil, tint: .blue, label: "applying step \(step) of \(total)"
            )
        case .applied:
            return QueueStatusStyle(
                symbolName: "checkmark.circle.fill", tint: .green, label: "applied"
            )
        case .skipped:
            return QueueStatusStyle(
                symbolName: "arrow.uturn.forward.circle", tint: .gray, label: "skipped"
            )
        case .failed:
            return QueueStatusStyle(
                symbolName: "xmark.octagon.fill", tint: .red, label: "failed"
            )
        }
    }
}

/// Shared track-count wording (spec A5) so every surface phrases counts
/// identically. Empty -> "" (surface renders nothing). One count -> the
/// playlist's own count, singular "1 track" / plural "N tracks". N counts
/// (a merge group) -> per-copy counts in the group's copy order (ascending
/// playlist id, the merge concatenation order) joined with " + ", suffix
/// always the plural " tracks". Replaces the "N tracks combined" wording.
nonisolated func trackCountText(copyCounts: [Int]) -> String {
    guard !copyCounts.isEmpty else { return "" }
    if copyCounts.count == 1 {
        let count = copyCounts[0]
        return count == 1 ? "1 track" : "\(count) tracks"
    }
    return copyCounts.map(String.init).joined(separator: " + ") + " tracks"
}
