// DestinationPresentation.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Wave C2 (spec C2.1/C2.3) — the destination shell's value layer: the three
// app destinations the sidebar navigates between. Pure value types only —
// headlessly testable, no Music, no I/O. The selection STATE lives on
// AuditFlowModel (it must veto changes while the write path is hot); this
// file holds what the state machine and the views share.

import SwiftUI

/// The app's three places (spec C2.1). The sidebar holds destinations, not
/// wizard steps; `FlowStep` survives as the Activity staged panel's
/// internal sequencer only.
nonisolated enum AppDestination: String, CaseIterable, Identifiable, Sendable {
    case library
    case activity
    case settings

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .library: return "Library"
        case .activity: return "Activity"
        case .settings: return "Settings"
        }
    }

    /// Sidebar row icons, reusing the app's established SF Symbol
    /// vocabulary (the browser, the run surface, settings).
    var systemImage: String {
        switch self {
        case .library: return "music.note.list"
        case .activity: return "play.circle"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - the Activity status chip (spec C2.3) and the last-run summary

/// The session's last finished batch run, retained AFTER the report is
/// acknowledged so the Activity idle screen can summarize it (spec
/// C2.2 state 4, "when one exists this session"). Set by `finishRun` only;
/// never cleared within a session.
nonisolated struct LastRunSummary: Equatable, Sendable {
    let appliedCount: Int
    let failedCount: Int

    /// The idle caption — exact spec wording.
    var caption: String {
        "Last run: \(appliedCount) applied, \(failedCount) failed."
    }
}

/// The Activity sidebar row's live state (spec C2.3: running / paused /
/// finished / idle), derived from the same predicates the lock and the
/// Activity state machine use.
nonisolated enum ActivityChipState: Equatable, Sendable {
    case running
    case paused
    case finished
    case idle
}

/// Pure derivation, precedence-ordered: live OSA run activity wins; an
/// owned-but-waiting run (the judgment pause, or an attended flow parked
/// at review/confirm/outcome) is paused; a pending mandatory report is
/// finished; otherwise idle. Scanning is deliberately NOT a run.
nonisolated func activityChipState(
    isRunning: Bool,
    isApplying: Bool,
    isUnattendedRunActive: Bool,
    hasAttendedResult: Bool,
    hasFinishedReport: Bool
) -> ActivityChipState {
    if isRunning || isApplying { return .running }
    if isUnattendedRunActive || hasAttendedResult { return .paused }
    if hasFinishedReport { return .finished }
    return .idle
}

/// The chip's rendering through the shared A1 style type — the same
/// StatusChipView capsule every queue surface uses. `running` is live
/// (symbolName nil -> spinner), like auditing/applying.
nonisolated func activityChipStyle(for state: ActivityChipState) -> QueueStatusStyle {
    switch state {
    case .running:
        return QueueStatusStyle(symbolName: nil, tint: .blue, label: "running\u{2026}")
    case .paused:
        return QueueStatusStyle(symbolName: "pause.circle", tint: .orange, label: "paused")
    case .finished:
        return QueueStatusStyle(
            symbolName: "checkmark.circle.fill", tint: .green, label: "finished"
        )
    case .idle:
        return QueueStatusStyle(symbolName: "circle.dotted", tint: .gray, label: "idle")
    }
}
