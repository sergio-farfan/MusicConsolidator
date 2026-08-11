// DirectMutationSheets.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Task 4 (Sergio, 2026-08-06) — the presentation layer for direct playlist
// mutations dispatched straight from the browser/cleanup UI (Task 3's
// `AuditFlowModel.pendingDirectAction` / `directMutationError`). Renders the
// delete confirm panel, the in-progress panel, the rename panel, or the
// error panel, in that precedence: error > in-progress > pending > empty;
// the view is empty when none of the three states is set.
//
// Final fix wave, Finding I1: the sheet stays up THROUGH dispatch. Confirm
// clears `pendingDirectAction` and a failure only arrives milliseconds
// later, so a presentation condition without `isDirectMutationRunning` asks
// SwiftUI to re-present a sheet that is still animating out — a known
// dropped-presentation class, and this sheet is the only failure channel.
// Every anchor is therefore built by the shared `directMutationSheet(model:)`
// modifier at the bottom of this file, so all four (Cleanup tab, browser
// inspector, attended failure screen, run report) carry the same condition
// and the same interactive-dismiss rule.
//
// Composition rules (M8 lesson, non-negotiable): every load-bearing control
// is AppKit-backed (AppKitActionButton / AppKitTokenField / AppKitStaticText)
// so the offscreen structural tests can locate it by accessibility
// identifier; every multiline SwiftUI Text carries an explicit `lineLimit`
// and `.fixedSize` is never applied to long text; content is bounded to
// `maxWidth: 460`, except the batch-rename panel's spec-mandated 560 (see
// `BatchRenamePanel` below).

import AppKit
import SwiftUI
import ConsolidatorCore

@MainActor
struct DirectMutationSheets: View {
    @Bindable var model: AuditFlowModel

    var body: some View {
        Group {
            // Precedence: error > in-progress > pending > empty. The error
            // wins even while `isDirectMutationRunning` is still true (a
            // batch's first failure surfaces before the task's last hop
            // clears the flag) — the reason must never be hidden behind a
            // spinner.
            if let error = model.directMutationError {
                errorPanel(error)
            } else if model.isDirectMutationRunning {
                inProgressPanel
            } else if let action = model.pendingDirectAction {
                switch action {
                case .delete(let targets):
                    deleteConfirmPanel(targets: targets)
                case .rename(let target):
                    renamePanel(target: target)
                case .batchRename(let targets):
                    BatchRenamePanel(model: model, targets: targets)
                }
            } else {
                EmptyView()
            }
        }
    }

    // MARK: delete confirm

    private func deleteConfirmPanel(targets: [PlaylistListing]) -> some View {
        let hasFolder = targets.contains { $0.specialKind == "folder" }
        let title = targets.count == 1
            ? "Delete \u{201C}\(targets[0].name)\u{201D}?"
            : "Delete \(targets.count) playlists?"
        let confirmTitle = targets.count == 1 ? "Delete" : "Delete \(targets.count) playlists"
        return VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .lineLimit(2)
            Text("Songs stay in your library.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if hasFolder {
                AppKitStaticText(
                    identifier: DirectControlID.folderCascadeNotice,
                    text: "Deleting a folder also deletes the playlists inside it.",
                    maximumLines: 2
                )
                .foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Spacer()
                AppKitActionButton(
                    identifier: DirectControlID.confirmCancel,
                    title: "Cancel"
                ) {
                    model.cancelPendingDirectAction()
                }
                AppKitActionButton(
                    identifier: DirectControlID.confirmExecute,
                    title: confirmTitle,
                    prominent: true
                ) {
                    model.confirmPendingDirectAction()
                }
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(20)
    }

    // MARK: in progress (Finding I1)

    /// Shown while a dispatch is in flight and no error has arrived yet. No
    /// buttons: the sheet is deliberately not dismissable here (the anchors
    /// apply `.interactiveDismissDisabled`), so the failure panel replaces
    /// this content in place instead of re-presenting a dismissed sheet.
    /// Deliberately stateless — the model gains no per-item progress state.
    private var inProgressPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                AppKitStaticText(
                    identifier: DirectControlID.inProgressStatus,
                    text: "Working\u{2026}",
                    maximumLines: 1
                )
            }
            AppKitStaticText(
                identifier: DirectControlID.inProgressCaption,
                text: "Deleting or renaming in Music. A batch runs one playlist "
                    + "at a time, so several can take a few seconds.",
                maximumLines: 3
            )
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(20)
    }

    // MARK: rename

    private func renamePanel(target: PlaylistListing) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \u{201C}\(target.name)\u{201D}")
                .font(.headline)
                .lineLimit(2)
            AppKitTokenField(
                identifier: DirectControlID.renameField,
                text: $model.typedRenameName,
                onSubmit: { model.confirmPendingDirectAction() }
            )
            Text("Duplicate names are allowed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 12) {
                Spacer()
                AppKitActionButton(
                    identifier: DirectControlID.confirmCancel,
                    title: "Cancel"
                ) {
                    model.cancelPendingDirectAction()
                }
                AppKitActionButton(
                    identifier: DirectControlID.confirmExecute,
                    title: "Rename",
                    prominent: true
                ) {
                    model.confirmPendingDirectAction()
                }
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(20)
    }

    // MARK: error

    private func errorPanel(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Action failed")
                .font(.headline)
            // AppKitStaticText's NSTextField is already `.isSelectable`
            // (the component's own selectable-text-not-placeholder rule).
            AppKitStaticText(
                identifier: DirectControlID.errorMessage,
                text: message,
                maximumLines: 6
            )
            HStack {
                Spacer()
                AppKitActionButton(
                    identifier: DirectControlID.errorDismiss,
                    title: "OK",
                    prominent: true
                ) {
                    model.dismissDirectMutationError()
                }
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(20)
    }
}

// MARK: - batch rename (Task 2, Sergio 2026-08-06)

/// The batch-rename sheet: a find/replace fill helper up top (literal,
/// applied to every row's CURRENT draft), one scrolling row per selected
/// playlist (current name -> editable draft, pre-filled), a caption, and
/// Cancel / commit. Its own `View` (rather than a `DirectMutationSheets`
/// method like the other panels) because the find/replace text lives ONLY
/// in this sheet's UI — the model never sees it, only the drafts it
/// produces via `applyBatchRenameReplacement`.
///
/// Copy is verbatim from the plan's Global Constraints: title
/// `Rename <N> playlists`; caption `Unchanged names are skipped. Duplicates
/// allowed.`; commit `Rename <N> playlists` where N is
/// `batchRenameChangedCount`, disabled at 0. Content is bounded to
/// `maxWidth: 560`; rows scroll inside `maxHeight: 420` (M8 rules: this
/// panel is wider than the other 460pt sheets because it carries a
/// find/replace row plus per-row editable fields).
@MainActor
private struct BatchRenamePanel: View {
    @Bindable var model: AuditFlowModel
    let targets: [PlaylistListing]

    @State private var findText = ""
    @State private var replaceText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(targets.count) playlists")
                .font(.headline)
                .lineLimit(1)
            helperRow
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(targets, id: \.persistentId) { target in
                        row(for: target)
                    }
                }
            }
            .frame(maxHeight: 420)
            Text("Unchanged names are skipped. Duplicates allowed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 12) {
                Spacer()
                AppKitActionButton(
                    identifier: DirectControlID.confirmCancel,
                    title: "Cancel"
                ) {
                    model.cancelPendingDirectAction()
                }
                AppKitActionButton(
                    identifier: DirectControlID.confirmExecute,
                    title: "Rename \(model.batchRenameChangedCount) playlists",
                    prominent: true
                ) {
                    model.confirmPendingDirectAction()
                }
                .disabled(model.batchRenameChangedCount == 0)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(20)
    }

    private var helperRow: some View {
        HStack(spacing: 8) {
            Text("Find")
                .font(.callout)
            AppKitTokenField(identifier: DirectControlID.batchRenameFind, text: $findText)
                .frame(minWidth: 80, idealWidth: 120, maxWidth: 160)
            Text("Replace with")
                .font(.callout)
            AppKitTokenField(identifier: DirectControlID.batchRenameReplace, text: $replaceText)
                .frame(minWidth: 80, idealWidth: 120, maxWidth: 160)
            AppKitActionButton(
                identifier: DirectControlID.batchRenameApplyAll,
                title: "Apply to all"
            ) {
                model.applyBatchRenameReplacement(find: findText, replaceWith: replaceText)
            }
        }
    }

    private func row(for target: PlaylistListing) -> some View {
        let persistentId = target.persistentId
        let draft = Binding<String>(
            get: { model.batchRenameDrafts[persistentId] ?? "" },
            set: { model.setBatchRenameDraft($0, for: persistentId) }
        )
        return HStack(spacing: 8) {
            BrowserNameText(name: target.name)
                .frame(minWidth: 120, maxWidth: 200, alignment: .leading)
            AppKitTokenField(
                identifier: DirectControlID.batchRenameField(persistentId),
                text: draft
            )
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - the one shared sheet anchor (Finding I1)

extension View {
    /// Host `DirectMutationSheets` at this view. Every screen that can stage a
    /// direct mutation mounts this ONE modifier, so the presentation
    /// condition, the dismiss routing, and the interactive-dismiss rule can
    /// never drift apart between anchors (Finding I1): presented while a
    /// pending action, a dispatch in flight, or an unread error exists;
    /// dismissal (Escape, sheet-swipe) clears the error or cancels the
    /// pending action, and is disabled outright while a dispatch runs.
    @MainActor
    func directMutationSheet(model: AuditFlowModel) -> some View {
        sheet(
            isPresented: Binding(
                get: {
                    model.pendingDirectAction != nil
                        || model.directMutationError != nil
                        || model.isDirectMutationRunning
                },
                set: { shown in
                    guard !shown else { return }
                    if model.directMutationError != nil {
                        model.dismissDirectMutationError()
                    } else {
                        model.cancelPendingDirectAction()
                    }
                }
            )
        ) {
            DirectMutationSheets(model: model)
                .interactiveDismissDisabled(model.isDirectMutationRunning)
        }
    }
}
