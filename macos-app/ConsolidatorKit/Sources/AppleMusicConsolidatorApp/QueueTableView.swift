// QueueTableView.swift
// Wave A (A2) — the shared two-column queue table used by BOTH queue
// surfaces (QueueRailView on screen 1 and the queue list inside
// UnattendedRunScreen): a hand-rolled eager Grid, NOT SwiftUI Table —
// native Table is NSTableView-backed with lazy rows, which can materialize
// zero rows in the offscreen structural harness and blind the geometry
// gate that caught both prior layout-blowout classes. Columns: Playlist |
// Status, header row, divider, alternating row backgrounds. The status
// chip goes live (spinner) for the derived auditing/applying states.

import SwiftUI
import AppKit
import MusicBridge

/// One rendered row: the queue item's name, its per-copy counts (A5), and
/// its DERIVED display state (A1 — live states included).
struct QueueTableRow: Identifiable, Equatable {
    let id: String
    let name: String
    let copyCounts: [Int]
    let state: QueueDisplayState
}

/// The status cell: the style's symbol (or a small live spinner when the
/// state is live) plus the existing Chip capsule in the style's tint.
/// Wave C2: generalized to take a style directly so the Activity sidebar
/// chip and the staged-panel stage chips reuse the same capsule; the
/// QueueDisplayState init is preserved and delegates.
struct StatusChipView: View {
    let style: QueueStatusStyle

    init(state: QueueDisplayState) {
        self.style = QueueStatusStyle.style(for: state)
    }

    init(style: QueueStatusStyle) {
        self.style = style
    }

    var body: some View {
        HStack(spacing: 6) {
            if style.isLive {
                ProgressView()
                    .controlSize(.small)
            } else if let symbolName = style.symbolName {
                Image(systemName: symbolName)
                    .foregroundStyle(style.tint)
            }
            Chip(text: style.label, tint: style.tint)
        }
    }
}

/// The shared two-column queue table (spec A2).
struct QueueTableView: View {
    let rows: [QueueTableRow]

    init(rows: [QueueTableRow]) {
        self.rows = rows
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                headerCell("Playlist")
                headerCell("Status")
            }
            Divider()
                .gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                GridRow {
                    HStack(spacing: 8) {
                        BrowserNameText(name: row.name)
                        Text(trackCountText(copyCounts: row.copyCounts))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    StatusChipView(state: row.state)
                }
                .padding(.vertical, 4)
                .background(rowBackground(index))
                .font(.callout)
            }
        }
    }

    private func headerCell(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .bold()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.vertical, 4)
    }

    /// macOS-native striping: the system's alternating content backgrounds.
    private func rowBackground(_ index: Int) -> Color {
        let colors = NSColor.alternatingContentBackgroundColors
        guard !colors.isEmpty else { return .clear }
        return Color(nsColor: colors[index % colors.count])
    }
}

/// The apply stage total for "applying step k of N" (Wave A fix wave,
/// finding 3): the app-level plan load plus the bridge's guarded phases.
/// Lives beside `queueTableRows` (the only place in this presentation
/// layer that may import `MusicBridge` for `ApplyPhase`) so
/// `QueueStatusPresentation.swift` stays import-free of it.
private let totalApplyStages = 1 + ApplyPhase.allCases.count

/// The live run/apply inputs shared by every current-row derivation
/// (`queueTableRows` and `currentQueueDisplayState`) — factored out so the
/// two can never drift apart (Wave A fix wave, finding 2).
@MainActor
private func liveRunInputs(
    for model: AuditFlowModel
) -> (isAuditRunning: Bool, applyStageCount: Int?) {
    let isAuditRunning: Bool = {
        if case .running = model.runState { return true }
        return false
    }()
    let applyStageCount: Int? = {
        if case .running(let stages) = model.applyState { return stages.count }
        return nil
    }()
    return (isAuditRunning, applyStageCount)
}

/// Map the model's queue onto table rows: display states derive from the
/// stored status plus the CURRENT item's live run/apply state (A1) — the
/// stored AuditQueueStatus five-case machine is untouched. Rows are keyed
/// by queue INDEX, not name (Wave A fix wave, finding 5): the queue never
/// reorders, but two canonically-equivalent-but-scalar-different names
/// (NFC/NFD twins) hash equal under Swift's default String identity and
/// would otherwise collapse to one SwiftUI row identity.
@MainActor
func queueTableRows(for model: AuditFlowModel) -> [QueueTableRow] {
    let live = liveRunInputs(for: model)
    return model.queue.enumerated().map { index, item in
        QueueTableRow(
            id: "row-\(index)",
            name: item.name,
            copyCounts: item.copyCounts,
            state: queueDisplayState(
                status: item.status,
                isCurrent: model.isQueueActive && index == model.queueIndex,
                isAuditRunning: live.isAuditRunning,
                applyStageCount: live.applyStageCount,
                total: totalApplyStages
            )
        )
    }
}

/// The CURRENT queue item's live display state (A1), computed with the
/// EXACT same derivation `queueTableRows` uses for its current row (Wave A
/// fix wave, finding 2) — the single source of truth so the unattended
/// screen's "Current:" header chip can never disagree with the table row
/// beneath it. `nil` when there is no active current item.
@MainActor
func currentQueueDisplayState(for model: AuditFlowModel) -> QueueDisplayState? {
    guard model.isQueueActive, let current = model.currentQueueItem else { return nil }
    let live = liveRunInputs(for: model)
    return queueDisplayState(
        status: current.status,
        isCurrent: true,
        isAuditRunning: live.isAuditRunning,
        applyStageCount: live.applyStageCount,
        total: totalApplyStages
    )
}
