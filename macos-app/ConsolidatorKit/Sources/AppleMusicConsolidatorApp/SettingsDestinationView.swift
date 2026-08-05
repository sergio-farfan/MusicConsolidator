// SettingsDestinationView.swift
// Wave C2 (spec C2.4) — the Settings destination: the M11 settings panel
// promoted from the browser-footer "Artifacts & Automation" disclosure to
// a destination detail. CONTENT RELOCATED VERBATIM from
// SourceSelectionView.settingsDisclosure — strings, controls, identifiers,
// and the fix-round-4 lineLimit discipline are byte-preserved; only the
// container changed (a ScrollView + GroupBox detail instead of a footer
// DisclosureGroup, so the DisclosureGroup-measurement caveats no longer
// apply). Persistence and the preflight flow are untouched.

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
                        Text("Artifacts & Automation")
                            .font(.headline)
                        LabeledContent("Output directory") {
                            HStack(spacing: 8) {
                                IdentifierText(text: model.outputDirectoryPath)
                                Button("Choose\u{2026}") { chooseOutputDirectory() }
                                    .disabled(model.isRunning)
                            }
                        }
                        // Fix round 4, item 4 discipline retained: every
                        // potentially-multiline Text here carries an
                        // explicit lineLimit.
                        Text(
                            "Each audit writes a new .plan.json / .detail.csv / .summary.md "
                                + "triple. Existing artifacts are never overwritten."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        // M11 batch settings (both default OFF per Sergio).
                        HStack(spacing: 8) {
                            AppKitCheckbox(
                                identifier: M11ControlID.confirmEachApply,
                                isOn: model.confirmEachApply,
                                help: "When on, batch items pause at the M9 per-item "
                                    + "review + typed-name gate before each apply."
                            ) {
                                model.setConfirmEachApply(!model.confirmEachApply)
                            }
                            Text("Confirm each apply (batch runs pause at the per-item gate)")
                                .font(.caption)
                                .lineLimit(2)
                        }
                        HStack(spacing: 8) {
                            AppKitCheckbox(
                                identifier: M11ControlID.pauseOnJudgment,
                                isOn: model.pauseOnJudgmentItems,
                                help: "When on, unattended items with near-identical pairs, "
                                    + "distinct-entry omissions, or count anomalies pause "
                                    + "for review."
                            ) {
                                model.setPauseOnJudgmentItems(!model.pauseOnJudgmentItems)
                            }
                            Text("Pause on judgment items (unattended runs hold them for review)")
                                .font(.caption)
                                .lineLimit(2)
                        }
                        Text(
                            "Unattended batch runs keep every engine guard and end in a "
                                + "mandatory run report; the listing cache serves the browser "
                                + "only \u{2014} audits and applies always re-read Music live."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        HStack(spacing: 8) {
                            Button("Check Automation access") { model.runPreflight() }
                                .disabled(model.isPreflightRunning || model.isRunning)
                            if model.isPreflightRunning {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        if let preflight = model.preflight {
                            Label {
                                Text(preflight.displayText)
                                    .textSelection(.enabled)
                                    .lineLimit(4)
                            } icon: {
                                Image(systemName: preflightSymbol(preflight))
                                    .foregroundStyle(
                                        preflight == .granted ? Color.green : Color.orange
                                    )
                            }
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

    private func preflightSymbol(_ result: AutomationPreflightResult) -> String {
        switch result {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.octagon.fill"
        case .musicNotRunning: return "play.slash"
        default: return "questionmark.circle"
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose the audit output directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: model.outputDirectoryPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setOutputDirectory(path: url.path)
    }
}
