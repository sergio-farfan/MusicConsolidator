// DirectMutationSheets.swift
// Task 4 (Sergio, 2026-08-06) — the presentation layer for direct playlist
// mutations dispatched straight from the browser/cleanup UI (Task 3's
// `AuditFlowModel.pendingDirectAction` / `directMutationError`). Renders the
// delete confirm panel, the rename panel, or the error panel; the error
// panel wins over a pending action when both are set, and the view is empty
// when neither is set. Task 5 hosts this container in a `.sheet`.
//
// Composition rules (M8 lesson, non-negotiable): every load-bearing control
// is AppKit-backed (AppKitActionButton / AppKitTokenField / AppKitStaticText)
// so the offscreen structural tests can locate it by accessibility
// identifier; every multiline SwiftUI Text carries an explicit `lineLimit`
// and `.fixedSize` is never applied to long text; content is bounded to
// `maxWidth: 460`.

import AppKit
import SwiftUI
import ConsolidatorCore

@MainActor
struct DirectMutationSheets: View {
    @Bindable var model: AuditFlowModel

    var body: some View {
        Group {
            // Error wins over a pending action when both happen to be set.
            if let error = model.directMutationError {
                errorPanel(error)
            } else if let action = model.pendingDirectAction {
                switch action {
                case .delete(let targets):
                    deleteConfirmPanel(targets: targets)
                case .rename(let target):
                    renamePanel(target: target)
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
