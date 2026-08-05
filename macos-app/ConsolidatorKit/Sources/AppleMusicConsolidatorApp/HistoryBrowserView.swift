// HistoryBrowserView.swift
// M11 — the in-app history browser: past audits and run reports, scanned
// straight off the reports directory. PRESENTATION ONLY over the canonical
// artifact files, which remain the durable record (the plan-file chain —
// named approval, SHA trail, loader path, CLI interop — is load-bearing and
// untouched). Searchable; Reveal in Finder; Export copies the file via a
// save panel.

import SwiftUI
import AppKit

@MainActor
struct HistoryBrowserView: View {
    /// Explicit directory for tests; nil = read the LIVE output directory
    /// from the model's own defaults key on every refresh (fix round 1,
    /// minor e — never a value captured at window creation).
    private let directoryOverride: String?
    @State private var entries: [HistoryEntry] = []
    @State private var query: String = ""

    init(directoryPath: String? = nil) {
        self.directoryOverride = directoryPath
        let initial = directoryPath ?? AuditFlowModel.currentOutputDirectoryPath()
        self._entries = State(initialValue: historyEntries(inDirectoryPath: initial))
    }

    private var directoryPath: String {
        directoryOverride ?? AuditFlowModel.currentOutputDirectoryPath()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            list
        }
        .frame(minWidth: 640, minHeight: 400)
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppKitFilterField(
                identifier: M11ControlID.historyFilter,
                placeholder: "Filter artifacts",
                text: $query
            )
            .frame(width: 240)
            Button("Refresh") {
                entries = historyEntries(inDirectoryPath: directoryPath)
            }
            Spacer()
            Text("\(entries.count) artifacts in \(directoryPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var list: some View {
        List {
            ForEach(filteredHistoryEntries(entries, query: query)) { entry in
                HStack(spacing: 8) {
                    Chip(text: entry.kindLabel, tint: tint(for: entry.kind))
                    Text(entry.fileName)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let counts = entry.planCounts {
                        Text(
                            trackCountText(copyCounts: counts.inputCopyCounts)
                                + " \u{2192} "
                                + trackCountText(copyCounts: [counts.outputCount])
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                    }
                    Spacer()
                    if let modified = entry.modifiedAt {
                        Text(modified.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: entry.path)]
                        )
                    }
                    .controlSize(.small)
                    Button("Export\u{2026}") { export(entry) }
                        .controlSize(.small)
                }
            }
        }
        .listStyle(.inset)
    }

    private func tint(for kind: HistoryEntry.Kind) -> Color {
        switch kind {
        case .auditPlan: return .blue
        case .runReport: return .green
        case .other: return .gray
        }
    }

    /// Copy the artifact to a user-chosen location (the original is never
    /// moved or modified). The save panel already asked about replacement,
    /// so a confirmed replace really replaces (fix round 1, minor c — no
    /// silent no-op on an existing destination).
    private func export(_ entry: HistoryEntry) {
        let panel = NSSavePanel()
        panel.title = "Export a copy of \(entry.fileName)"
        panel.nameFieldStringValue = entry.fileName
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try? FileManager.default.copyItem(
            at: URL(fileURLWithPath: entry.path), to: destination
        )
    }
}
