// SettingsDestinationView.swift
// UI rework Part 2 — the Settings destination reworked from the M11
// "Artifacts & Automation" plumbing panel (output-directory chooser, batch
// toggles, Automation preflight) into a genuine USER PREFERENCES screen:
// Appearance, Startup, and Notifications. The removed plumbing's model
// state (confirmEachApply, pauseOnJudgmentItems, outputDirectoryPath) and
// the Automation preflight are untouched — only this view's surface
// changed. The preflight stays reachable through the Diagnostics window's
// existing "Preflight Automation" button (Window menu / Cmd-Shift-D).

import SwiftUI
import AppKit

@MainActor
struct SettingsDestinationView: View {
    @Bindable var model: AuditFlowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Appearance")
                            .font(.headline)
                        appearancePicker
                        Text(
                            "Controls the app's light/dark appearance. System follows the "
                                + "current macOS appearance."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Startup")
                            .font(.headline)
                        HStack(spacing: 8) {
                            AppKitCheckbox(
                                identifier: SettingsControlID.reloadLibraryOnStart,
                                isOn: model.reloadLibraryOnStart,
                                help: "When on, the library rescans automatically once, "
                                    + "each time the app launches."
                            ) {
                                model.setReloadLibraryOnStart(!model.reloadLibraryOnStart)
                            }
                            Text("Reload library on app start")
                                .font(.caption)
                                .lineLimit(2)
                        }
                        Text("Default tab on launch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        defaultTabPicker
                        Text(
                            "Chooses which browser tab is selected the next time the app "
                                + "opens; it does not change the tab right now."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notifications")
                            .font(.headline)
                        HStack(spacing: 8) {
                            AppKitCheckbox(
                                identifier: SettingsControlID.playSoundOnRunFinish,
                                isOn: model.playSoundOnRunFinish,
                                help: "When on, a sound plays once a batch run finishes."
                            ) {
                                model.setPlaySoundOnRunFinish(!model.playSoundOnRunFinish)
                            }
                            Text("Play sound when a run finishes")
                                .font(.caption)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
            .padding(20)
            .frame(maxWidth: 880, alignment: .leading)
        }
    }

    // MARK: Appearance picker

    /// The same tab-pill pattern as `SourceSelectionView.tabPillSelector`:
    /// one `AppKitActionButton` per case with a `Capsule` selection
    /// highlight. Changing the pick applies immediately (unlike "Default
    /// tab on launch" below, which only takes effect at the next launch).
    private var appearancePicker: some View {
        HStack(spacing: 4) {
            ForEach(AppearanceMode.allCases) { candidate in
                ZStack {
                    if model.appearanceMode == candidate {
                        Capsule().fill(Color.accentColor.opacity(0.22))
                    }
                    AppKitActionButton(
                        identifier: SettingsControlID.appearance(candidate),
                        title: candidate.displayName,
                        compressible: true
                    ) {
                        model.setAppearanceMode(candidate)
                        NSApp.appearance = nsAppearance(for: candidate)
                    }
                    .padding(2)
                }
            }
        }
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 280)
    }

    // MARK: default-tab-on-launch picker

    /// Same pill pattern, over `BrowserTab.allCases`. Deliberately does NOT
    /// call `model.setBrowserTab(_:)` — this preference only edits
    /// `defaultBrowserTabOnLaunch`, applied to the live tab once, at launch.
    private var defaultTabPicker: some View {
        HStack(spacing: 4) {
            ForEach(BrowserTab.allCases) { tab in
                ZStack {
                    if model.defaultBrowserTabOnLaunch == tab {
                        Capsule().fill(Color.accentColor.opacity(0.22))
                    }
                    AppKitActionButton(
                        identifier: SettingsControlID.defaultTabOnLaunch(tab),
                        title: tab.displayName,
                        compressible: true
                    ) {
                        model.setDefaultBrowserTabOnLaunch(tab)
                    }
                    .padding(2)
                }
            }
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
    }
}
