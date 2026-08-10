// ConfirmGateView.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Screen 3 — the confirm gate. M9: completing the gate reveals the Apply
// button (in-app apply; the M7/M8 CLI hand-off panel is GONE — the python
// CLI remains the development reference only, invisible to users). The gates,
// all required: (a) the "sources are never modified" notice (always
// displayed, and kept adjacent to the Apply button), (b) the "I reviewed
// the plan" toggle, (c) typed target-name re-entry matching SCALAR-exactly,
// (d) the plan freshness note (artifact filename + timestamp). One apply
// per fresh audit: once consumed (success OR failure) the button never
// returns for this plan.
//
// Layout (fix round 4 consistency): the screen carries the SAME pinned
// bottom action bar treatment as screen 2 — Back to plan review / Start
// over live in a safeAreaInset bar, AppKit-backed for the structural tests.

import SwiftUI
import AppKit

@MainActor
struct ConfirmGateView: View {
    @Bindable var model: AuditFlowModel

    var body: some View {
        if let result = model.result, let targetName = model.targetName {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    targetPreview(targetName: targetName)
                    noticePanel
                    freshnessPanel(result: result)
                    gatesPanel(targetName: targetName)
                    if model.isApplyConsumed {
                        consumedPanel
                    } else if model.gateSatisfied {
                        applyPanel(targetName: targetName)
                    }
                    if model.currentQueueItem != nil {
                        queuePanel
                    }
                }
                .padding(20)
                .frame(maxWidth: 880, alignment: .leading)
            }
            // M9 (round-4 concern 1 consistency): pinned bottom action bar,
            // identical treatment to screen 2's — always visible, outside
            // the scroll content, AppKit-backed.
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    AppKitActionButton(
                        identifier: M9ControlID.gateBackToReview,
                        title: "Back to plan review"
                    ) {
                        model.navigate(to: .review)
                    }
                    AppKitActionButton(
                        identifier: M9ControlID.gateStartOver,
                        title: "Start over"
                    ) {
                        model.startOver()
                    }
                    .disabled(model.isUnattendedRunActive)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
        } else {
            ContentUnavailableView(
                "Nothing to confirm",
                systemImage: "checkmark.seal",
                description: Text("Run a read-only check and review its plan first.")
            )
        }
    }

    // MARK: target preview

    private func targetPreview(targetName: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("New playlist the apply will create")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(targetName)
                    .font(.system(.title3, design: .monospaced).bold())
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: gate (a) — the notice, always displayed

    private var noticePanel: some View {
        GroupBox {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sources are never modified.")
                        .bold()
                    Text(
                        "Every apply creates a separate NEW target playlist. Nothing is "
                            + "deleted, renamed, emptied, or reordered. A partial or "
                            + "colliding target is never repaired automatically."
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.blue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: gate (d) — plan freshness

    private func freshnessPanel(result: AuditFlowModel.CompletedAudit) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Plan freshness")
                    .font(.headline)
                LabeledContent("Plan file") {
                    IdentifierText(text: model.planFileName ?? "\u{2014}")
                }
                LabeledContent("Check completed") {
                    Text(
                        result.completedAt.formatted(
                            date: .abbreviated, time: .standard
                        )
                    )
                }
                LabeledContent("Expected counts") {
                    Text("\(result.inputCount) in \u{2192} \(result.outputCount) out")
                        .monospacedDigit()
                }
                LabeledContent("Source tracks") {
                    Text(trackCountText(copyCounts: result.liveCopyCounts))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                LabeledContent("Planned target") {
                    Text(trackCountText(copyCounts: [result.outputCount]))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Text(
                    "Approval is of this exact named plan file \u{2014} the apply reloads "
                        + "and revalidates it from disk. If Music changes after this "
                        + "check, the apply fails closed \u{2014} run a fresh check "
                        + "instead of reusing an old plan."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: gates (b) + (c)

    private func gatesPanel(targetName: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Confirmation")
                    .font(.headline)
                Toggle(
                    "I reviewed the plan (decisions, omissions, and all three artifacts)",
                    isOn: $model.reviewedPlanToggle
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type the exact target name to confirm")
                        .font(.callout)
                    // M8 walkthrough fix: the required name is a caption ABOVE
                    // an EMPTY field — never the field's placeholder (a
                    // placeholder echoing the expected answer reads as
                    // already-filled, the exact trap from the live walkthrough).
                    HStack(spacing: 6) {
                        Text("Required:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(targetName)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        CopyButton(label: "Copy", text: targetName)
                            .controlSize(.mini)
                    }
                    TextField("", text: $model.typedTargetName)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Exact target name confirmation")
                    if let divergence = model.typedNameDivergence {
                        // Near-miss diagnostic: WHICH scalar differs, in the
                        // golden-test diagnostic style.
                        Label {
                            Text(describeDivergence(divergence))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.circle.fill")
                        }
                        .foregroundStyle(.orange)
                    }
                    // Fix round 4, item 3b: an EMPTY field states its state
                    // explicitly — the hollow indicator alone read as broken
                    // in the live walkthrough.
                    if model.typedTargetName.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "pencil.line")
                                .foregroundStyle(Color.secondary)
                            Text("Field is empty \u{2014} type or paste the required name above.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(
                                systemName: model.typedTargetNameMatches
                                    ? "checkmark.circle.fill"
                                    : "circle.dotted"
                            )
                            .foregroundStyle(model.typedTargetNameMatches ? Color.green : Color.secondary)
                            Text(
                                model.typedTargetNameMatches
                                    ? "Exact match."
                                    : "Must match exactly (character for character; the "
                                        + "comparison is Unicode-scalar exact)."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                if !model.gateSatisfied && !model.isApplyConsumed {
                    Text("The Apply button appears once both gates are satisfied.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: the apply panel (M9 — replaces the CLI hand-off panel)

    private func applyPanel(targetName: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Apply \u{2014} one guarded write", systemImage: "play.circle")
                    .font(.headline)
                // The sources-never-modified notice stays ADJACENT to the
                // button (locked design decision 3).
                VStack(alignment: .leading, spacing: 3) {
                    reminder(
                        "Sources are never modified; this creates ONE new playlist "
                            + "(\u{201C}\(targetName)\u{201D}) and verifies it by readback."
                    )
                    reminder(
                        "One apply per fresh check: success or failure consumes this "
                            + "plan \u{2014} afterwards the only paths are Start over or "
                            + "the next queue item."
                    )
                    reminder(
                        "The plan is reloaded and revalidated from the named artifact "
                            + "file at apply time: "
                            + (model.planFileName ?? "\u{2014}")
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                preflightRow
                AppKitActionButton(
                    identifier: M9ControlID.applyNow,
                    title: "Apply now \u{2014} creates \u{201C}\(targetName)\u{201D}",
                    prominent: true
                ) {
                    model.startApply()
                }
                .disabled(!model.canApply)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    /// Preflight surfaced on the gate (grant state; Music running).
    private var preflightRow: some View {
        HStack(spacing: 8) {
            Button("Check Automation access") { model.runPreflight() }
                .controlSize(.small)
                .disabled(model.isPreflightRunning || model.isRunning || model.isApplying)
            if model.isPreflightRunning {
                ProgressView()
                    .controlSize(.small)
            }
            if let preflight = model.preflight {
                Label {
                    Text(preflight.displayText)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(3)
                } icon: {
                    Image(systemName: preflight == .granted
                        ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(preflight == .granted ? Color.green : Color.orange)
                }
            } else {
                Text("Not checked yet \u{2014} Music must be running and Automation granted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    /// Shown once this audit's one apply has been used (success or failure).
    private var consumedPanel: some View {
        GroupBox {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This check's apply has been used.")
                        .bold()
                    Text(
                        "See step 4 for the result. One apply per fresh check: to "
                            + "apply again, start over and run a new check."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: the queue panel (M8 batch consolidations, M9 apply wiring)

    /// Queue context: the apply itself advances the item (screen 5 offers
    /// "Applied — continue"); here only the non-destructive Skip remains.
    private var queuePanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Batch queue \u{2014} item \(min(model.queueIndex + 1, model.queue.count)) "
                        + "of \(model.queue.count)",
                    systemImage: "list.number"
                )
                .font(.headline)
                Text(
                    "Applying this item transitions to the apply screen; after a "
                        + "verified apply, continue to the next item from there. Every "
                        + "item is approved on its own \u{2014} there is no bulk approve."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    // Never skip an APPLIED item (M9 fix round 1, finding 2):
                    // the playlist exists in Music; the record must say so.
                    Button("Skip this item") { model.skipCurrentQueueItem() }
                        .disabled(
                            model.isRunning || model.isScanning || model.isApplying
                                || model.currentQueueItem?.status == .applied
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func reminder(_ text: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
    }
}
