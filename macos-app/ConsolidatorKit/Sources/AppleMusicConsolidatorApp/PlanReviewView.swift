// PlanReviewView.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Screen 2 — plan review. Renders EXCLUSIVELY from the canonical plan object
// returned by the build (the binding M7 data-flow rule; no plan is ever
// decoded here). Header counts + fingerprint, the persisted artifact triple
// with reveal-in-Finder, the distinct-library-entries subset surfaced first
// (the part a human actually reviews), the full decision list with quality
// badges and omission classes, the non-eligible section, and — in merge
// mode — per-copy provenance with unique-contribution counts plus the
// output-track origin list (the review data the controller produced for the
// live Trance 2022 / Soka Varios / SGI Artists merges).

import SwiftUI
import AppKit
import ConsolidatorCore

@MainActor
struct PlanReviewView: View {
    @Bindable var model: AuditFlowModel
    @State private var distinctExpanded = true
    @State private var nearIdenticalExpanded = true
    @State private var outputTracksExpanded = false

    var body: some View {
        if let result = model.result {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let displays = decisionDisplays(result.decisions)
                    ReviewHeader(result: result)
                    DistinctEntriesPanel(
                        result: result,
                        displays: displays,
                        expanded: $distinctExpanded
                    )
                    NearIdenticalWinnersPanel(
                        result: result,
                        expanded: $nearIdenticalExpanded
                    )
                    if case .merge(let plan) = result.plan {
                        MergeProvenanceSection(
                            plan: plan,
                            outputTracksExpanded: $outputTracksExpanded
                        )
                    }
                    DecisionsSection(displays: displays)
                    NonEligibleSection(tracks: result.nonEligibleTracks)
                    ArtifactsSection(paths: result.paths)
                }
                .padding(20)
                .frame(maxWidth: 880, alignment: .leading)
            }
            // Fix round 4, item 2: the actions are ALWAYS VISIBLE — a pinned
            // bottom bar outside the scroll content (with a tall plan the
            // buttons used to live at the end of the scroll), consistent
            // with screen 1's persistent footer. AppKit-backed so the
            // structural test can assert containment without scrolling.
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    AppKitActionButton(
                        identifier: M8ControlID.continueToGate,
                        title: model.isUnattendedRunActive
                            ? "Resume \u{2014} continue to confirm gate"
                            : "Continue to confirm gate",
                        prominent: true
                    ) {
                        model.navigate(to: .confirm)
                    }
                    // M11 fix round 1, finding 1: during an ACTIVE unattended
                    // run (the judgment pause) a silent wipe is impossible —
                    // Start over disables; Skip item and Stop run (which
                    // builds + persists the mandatory report) take its place.
                    AppKitActionButton(
                        identifier: M8ControlID.startOver,
                        title: "Start over"
                    ) {
                        model.startOver()
                    }
                    .disabled(model.isUnattendedRunActive)
                    if model.isUnattendedRunActive {
                        AppKitActionButton(
                            identifier: M11ControlID.pauseSkipItem,
                            title: "Skip item \u{2014} resume run"
                        ) {
                            model.skipCurrentQueueItem()
                        }
                        AppKitActionButton(
                            identifier: M11ControlID.stopRun,
                            title: "Stop run (report now)"
                        ) {
                            model.requestStopAfterCurrentItem()
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
        } else {
            ContentUnavailableView(
                "No plan to review",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Run a read-only check from the Source step first.")
            )
        }
    }
}

// MARK: - header

private struct ReviewHeader: View {
    let result: AuditFlowModel.CompletedAudit

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(result.sourceName)
                        .font(.title2.bold())
                        .textSelection(.enabled)
                    Chip(text: result.mode.displayName, tint: .blue)
                    Text(trackCountText(copyCounts: result.liveCopyCounts))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer()
                }
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 2) {
                    GridRow {
                        statLabel(result.mode == .merge ? "Combined input" : "Input")
                        statLabel("Output")
                        statLabel("Omitted")
                        statLabel("Non-eligible")
                        if result.copies != nil { statLabel("Copies") }
                    }
                    GridRow {
                        statValue(result.inputCount)
                        statValue(result.outputCount)
                        statValue(result.omittedCount)
                        statValue(result.nonEligibleCount)
                        if let copies = result.copies { statValue(copies.count) }
                    }
                }
                if let copies = result.copies {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(copies.enumerated()), id: \.offset) { ordinal, copy in
                            HStack(spacing: 8) {
                                Text("Copy \(ordinal)")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 60, alignment: .leading)
                                IdentifierText(text: copy.persistentId)
                                Text(trackCountText(copyCounts: [copy.tracks.count]))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                            .font(.callout)
                        }
                        Text("Copies are in ascending playlist-id order (the plan's copy order).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text("Fingerprint")
                        .foregroundStyle(.secondary)
                    IdentifierText(text: result.fingerprint)
                    CopyButton(label: "Copy", text: result.fingerprint)
                        .controlSize(.small)
                }
                .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func statLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func statValue(_ value: Int) -> some View {
        Text(String(value))
            .font(.title3.monospacedDigit().bold())
    }
}

// MARK: - the distinct-entries panel (what the human is reviewing for)

private struct DistinctEntriesPanel: View {
    let result: AuditFlowModel.CompletedAudit
    let displays: [DecisionDisplay]
    @Binding var expanded: Bool

    var body: some View {
        let distinct = distinctOmissions(displays)
        if !distinct.isEmpty {
            GroupBox {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(
                            "These omitted occurrences are NOT field-identical to their "
                                + "winners (different persistent ID, database ID, or "
                                + "metadata/quality field) — a genuinely distinct library "
                                + "entry is being dropped in favor of its winner. Review "
                                + "each pair (the SGI Artists Howard-Jones class). Note: "
                                + "near-identical tracks whose durations differ keep BOTH "
                                + "entries as winners (the Gamemaster / Lotus-Sutra class) "
                                + "and do not appear here — see the \u{201C}Near-identical "
                                + "tracks kept\u{201D} panel for those."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        ForEach(displays.filter(\.hasDistinctEntries)) { display in
                            DecisionRow(display: display, onlyDistinct: true)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label(
                        "Needs attention: \(distinct.count) omitted "
                            + (distinct.count == 1
                                ? "track is a distinct library entry"
                                : "tracks are distinct library entries"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .bold()
                }
                .padding(4)
            }
        } else if result.omittedCount > 0 {
            Label(
                "All \(result.omittedCount) omissions are identical-library-track "
                    + "occurrences (field-identical to their winners) — the safe bulk.",
                systemImage: "checkmark.circle"
            )
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - near-identical winners (the Gamemaster / Lotus-Sutra class, M8)

/// Winners whose normalized title+artist match another winner but whose
/// exact durations differ: the strict key keeps BOTH (proven correct live —
/// the Trance 2022 Gamemasters are two genuinely different releases), and a
/// human should look at each pair once.
private struct NearIdenticalWinnersPanel: View {
    let result: AuditFlowModel.CompletedAudit
    @Binding var expanded: Bool

    var body: some View {
        let pairs = nearIdenticalWinnerPairs(in: result.outputTracks)
        if !pairs.isEmpty {
            GroupBox {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(
                            "These OUTPUT tracks share a normalized title + artist but "
                                + "differ in exact duration, so the strict key keeps both. "
                                + "On the first live merge this correctly preserved two "
                                + "different releases (compilation mix vs single). Review "
                                + "each pair once; removing one is a manual decision in "
                                + "Music \u{2014} never the tool's."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        ForEach(pairs) { pair in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(pair.first.title) \u{2014} \(pair.first.artist)")
                                    .bold()
                                    .textSelection(.enabled)
                                pairMemberLine(pair.first)
                                pairMemberLine(pair.second)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label(
                        "Near-identical tracks kept \u{2014} review these pairs (\(pairs.count))",
                        systemImage: "waveform.badge.exclamationmark"
                    )
                    .foregroundStyle(.orange)
                    .bold()
                }
                .padding(4)
            }
        }
    }

    private func pairMemberLine(_ track: ConsolidatorCore.TrackSnapshot) -> some View {
        HStack(spacing: 10) {
            IdentifierText(text: track.persistentId)
            Text(formattedDuration(ms: track.durationMs))
                .monospacedDigit()
            Text(track.album)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.leading, 18)
    }
}

// MARK: - merge provenance

private struct MergeProvenanceSection: View {
    let plan: MergePlan
    @Binding var outputTracksExpanded: Bool

    var body: some View {
        let provenance = copyProvenance(plan)
        let boundaries = plan.copyBoundaries
        let combined = plan.combinedTracks
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Per-copy provenance")
                    .font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 3) {
                    GridRow {
                        headerCell("Copy")
                        headerCell("Persistent ID")
                        headerCell("Tracks")
                        headerCell("In output")
                        headerCell("Unique contribution")
                    }
                    Divider()
                    ForEach(provenance) { summary in
                        GridRow {
                            Text("Copy \(summary.ordinal)")
                            IdentifierText(text: summary.persistentId)
                            Text(String(summary.trackCount)).monospacedDigit()
                            Text(String(summary.outputTrackCount)).monospacedDigit()
                            Text(String(summary.uniqueContributionCount))
                                .monospacedDigit()
                                .bold(summary.uniqueContributionCount > 0)
                        }
                    }
                }
                Text(
                    "\u{201C}Unique contribution\u{201D} counts output tracks whose whole "
                        + "duplicate group lives in that one copy — the tracks that would "
                        + "be lost without it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup(isExpanded: $outputTracksExpanded) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(
                            Array(plan.winnerSourceIndexes.enumerated()),
                            id: \.offset
                        ) { position, winnerIndex in
                            if combined.indices.contains(winnerIndex) {
                                let track = combined[winnerIndex]
                                HStack(spacing: 8) {
                                    Text(String(position + 1))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .frame(width: 40, alignment: .trailing)
                                    Text("\(track.title) \u{2014} \(track.artist)")
                                        .lineLimit(1)
                                    Spacer()
                                    IdentifierText(text: track.persistentId)
                                    Text(
                                        "Copy \(copyOrdinal(forCombinedIndex: winnerIndex, boundaries: boundaries))"
                                    )
                                    .foregroundStyle(.secondary)
                                    .frame(width: 60, alignment: .trailing)
                                }
                                .font(.callout)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Output tracks with copy of origin (\(plan.winnerSourceIndexes.count))")
                        .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func headerCell(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - decisions

private struct DecisionsSection: View {
    let displays: [DecisionDisplay]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Duplicate decisions (\(displays.count))")
                    .font(.headline)
                if displays.isEmpty {
                    Text("No duplicate decisions were required.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(displays) { display in
                            DecisionRow(display: display, onlyDistinct: false)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

/// One winner with its omitted occurrences (optionally only the distinct
/// class, for the needs-attention panel).
private struct DecisionRow: View {
    let display: DecisionDisplay
    let onlyDistinct: Bool

    var body: some View {
        let omitted = onlyDistinct
            ? display.omitted.filter { $0.classification == .distinctLibraryEntries }
            : display.omitted
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Chip(text: "winner", tint: .green)
                Text("\(display.winner.title) \u{2014} \(display.winner.artist)")
                    .bold()
                    .textSelection(.enabled)
                ForEach(qualityBadges(display.winner), id: \.self) { badge in
                    Chip(text: badge, tint: badge == "Unavailable" ? .red : .gray)
                }
            }
            trackDetailLine(display.winner)
            ForEach(omitted) { omission in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Chip(
                            text: omission.classification == .distinctLibraryEntries
                                ? "distinct entry"
                                : "identical track",
                            tint: omission.classification == .distinctLibraryEntries
                                ? .orange
                                : .gray
                        )
                        Text("omitted: \(omission.track.title) \u{2014} \(omission.track.artist)")
                            .textSelection(.enabled)
                        Chip(text: omission.reason, tint: .purple)
                        ForEach(qualityBadges(omission.track), id: \.self) { badge in
                            Chip(text: badge, tint: badge == "Unavailable" ? .red : .gray)
                        }
                    }
                    trackDetailLine(omission.track)
                }
                .padding(.leading, 18)
            }
        }
    }

    private func trackDetailLine(_ track: TrackSnapshot) -> some View {
        HStack(spacing: 10) {
            IdentifierText(text: track.persistentId)
            Text(formattedDuration(ms: track.durationMs))
                .monospacedDigit()
            Text(track.kind)
                .lineLimit(1)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - non-eligible

private struct NonEligibleSection: View {
    let tracks: [TrackSnapshot]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Non-eligible tracks (\(tracks.count))")
                    .font(.headline)
                if tracks.isEmpty {
                    Text("None — every track has a semantic key.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        "No semantic key (missing title, artist, or duration). These are "
                            + "retained in place, unchanged."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    ForEach(tracks, id: \.sourceIndex) { track in
                        HStack(spacing: 10) {
                            Text("\(track.title) \u{2014} \(track.artist)")
                                .textSelection(.enabled)
                            IdentifierText(text: track.persistentId)
                            Text(formattedDuration(ms: track.durationMs))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

// MARK: - artifacts

private struct ArtifactsSection: View {
    let paths: ConsolidatorCore.AuditPaths

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Records")
                    .font(.headline)
                artifactRow(label: "Plan JSON", path: paths.planJson)
                artifactRow(label: "Detail CSV", path: paths.detailCsv)
                artifactRow(label: "Summary Markdown", path: paths.summaryMarkdown)
                Text("Review all three. The CSV accounts for every source occurrence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func artifactRow(label: String, path: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)
            IdentifierText(text: path)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .controlSize(.small)
        }
        .font(.callout)
    }
}
