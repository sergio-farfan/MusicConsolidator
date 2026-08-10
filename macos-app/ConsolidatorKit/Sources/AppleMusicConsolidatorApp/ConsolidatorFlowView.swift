// ConsolidatorFlowView.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// The Wave C2 root: NavigationSplitView with DESTINATIONS in the
// sidebar (Library / Activity / Settings — places, not
// wizard steps; spec C2.1) and the selected destination in the detail
// column. The five-step rail is gone; the attended step machinery
// survives verbatim inside the Activity staged panel. The Status
// section is retained beneath the destination rows.

import AppKit
import SwiftUI

@MainActor
struct ConsolidatorFlowView: View {
    @State private var model: AuditFlowModel
    /// UI rework Part 2 — the one-shot launch-effects guard: SwiftUI can
    /// fire `.onAppear` more than once (e.g. relayout), so the flag itself
    /// is what keeps appearance/tab/rescan application to exactly once per
    /// view lifetime.
    @State private var hasAppliedLaunchPreferences = false

    /// Injectable model (M11 fix round 1, minor b): the structural tests
    /// pass a fixture-driven model so hosting this view never reads the
    /// real UserDefaults or Application Support cache; the app uses the
    /// default.
    init(model: AuditFlowModel? = nil) {
        self._model = State(initialValue: model ?? AuditFlowModel())
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                // Wave C hotfix (2026-08-04): was min 210/ideal 235/max 290
                // — narrowed so the sidebar leaves the detail column enough
                // room at the app's enforced functional minimum (900pt,
                // AppleMusicConsolidatorApp.swift). The window's actual
                // floor is enforced there now, not here: a hard
                // `.frame(minWidth: 960, minHeight: 640)` on this view
                // would have overridden every width fix below it.
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            detail
        }
        .navigationTitle("Apple Music Consolidator")
        .onAppear { applyLaunchPreferencesOnce() }
    }

    /// UI rework Part 2 — applied once per view lifetime, in order:
    /// appearance, then the default-tab-on-launch preference, then (if on)
    /// the reload-library-on-start rescan.
    private func applyLaunchPreferencesOnce() {
        guard !hasAppliedLaunchPreferences else { return }
        hasAppliedLaunchPreferences = true
        NSApp.appearance = nsAppearance(for: model.appearanceMode)
        model.setBrowserTab(model.defaultBrowserTabOnLaunch)
        if model.reloadLibraryOnStart {
            model.rescanLibrary()
        }
    }

    // MARK: sidebar

    // Destination rows are AppKit-backed (the M8 discipline for
    // load-bearing controls): NSButton enablement renders the C2.3 lock
    // introspectably, and performClick exercises the selection plumbing
    // offscreen. Blocked rows keep the existing reason strings via
    // AppKitActionButton's `help:` parameter (SwiftUI's `.help(_:)` never
    // reaches this NSViewRepresentable's NSButton — fix-before-close, final
    // review); the row tap routes through the model's own guarded
    // `selectDestination(_:)` (a no-op while locked), like the old rows'
    // `navigate(to:)`.
    private var sidebar: some View {
        List {
            Section("Destinations") {
                ForEach(AppDestination.allCases) { destination in
                    destinationRow(destination)
                }
            }
            Section("Status") {
                statusRow("Mode", value: model.mode.displayName)
                if let result = model.result {
                    statusRow("Checked", value: result.sourceName)
                    statusRow(
                        "Output", value: trackCountText(copyCounts: [result.outputCount])
                    )
                }
                if model.isRunning {
                    statusRow("Check", value: "running\u{2026}")
                }
                if model.isApplying {
                    statusRow("Apply", value: "running\u{2026}")
                }
                if model.isScanning {
                    statusRow("Library", value: "scanning\u{2026}")
                }
                if model.isQueueActive {
                    statusRow(
                        "Queue",
                        value: model.isQueueComplete
                            ? "complete"
                            : "item \(min(model.queueIndex + 1, model.queue.count)) of \(model.queue.count)"
                    )
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Wave C hotfix (2026-08-04): a narrow sidebar column must never grow
    /// past its column width to fit a long value (the "floating
    /// Consolidate with its Mode label clipped" symptom) — every value
    /// truncates its tail with an explicit single-line limit instead.
    private func statusRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func destinationRow(_ destination: AppDestination) -> some View {
        HStack(spacing: 8) {
            Image(systemName: destination.systemImage)
                .frame(width: 18)
            AppKitActionButton(
                identifier: WaveC2ControlID.destinationRow(destination),
                title: destination.displayName,
                help: model.destinationBlockedReason(for: destination)
                    ?? "Go to \(destination.displayName).",
                compressible: true
            ) {
                model.selectDestination(destination)
            }
            .disabled(!model.canSelect(destination))
            Spacer()
            if destination == .activity {
                // Live run state, visible from every destination (C2.3).
                StatusChipView(style: activityChipStyle(for: model.activityChip))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectDestination(destination) }
        .listRowBackground(
            model.selectedDestination == destination
                ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22)
                : nil
        )
    }

    // MARK: detail

    @ViewBuilder
    private var detail: some View {
        switch model.selectedDestination {
        case .library:
            SourceSelectionView(model: model)
        case .activity:
            ActivityView(model: model)
        case .settings:
            SettingsDestinationView(model: model)
        }
    }
}

// MARK: - shared flow widgets

/// A small tinted label chip (quality badges, omission classes).
struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.16)))
            .foregroundStyle(tint)
    }
}

/// Monospaced, selectable identifier text (persistent IDs, fingerprints,
/// paths) — the app's convention for anything compared byte-exactly.
struct IdentifierText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// One-click copy button with transient feedback.
struct CopyButton: View {
    let label: String
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }
}

/// The streaming progress row: phase label plus a ticking elapsed clock —
/// never a bare spinner (reads cost ~8-9 s + ~0.16 s/track; a 1,600-track
/// playlist is 4-5 minutes).
struct ProgressPhaseView: View {
    let phase: AuditFlowModel.Phase

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(phase.label)
                        .bold()
                    Text("elapsed \(Self.elapsedText(from: phase.started, to: context.date))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if case .reading = phase {
                // No fixedSize(vertical) here: this caption composes into
                // screen 1's bare-VStack footer during the reading phase,
                // where a fixedSize long text blows the minimum height up
                // (2,458 pt measured) and center-crops the footer's Cancel
                // control — the M8 fix-round-2 pathology (fix round 3,
                // reviewer finding; pinned by
                // StructuralViewTests.screenOneFitsDuringReadingPhase).
                Text(
                    "Reads cost about 8\u{2013}9 s plus ~0.16 s per track; a 1,600-track "
                        + "playlist takes 4\u{2013}5 minutes. Cancel takes effect once the "
                        + "in-flight read finishes (the read itself cannot be interrupted)."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    static func elapsedText(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
