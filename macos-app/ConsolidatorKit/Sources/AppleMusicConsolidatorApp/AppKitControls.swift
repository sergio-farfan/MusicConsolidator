// AppKitControls.swift
// M8 fix round 2 — AppKit-backed load-bearing controls. SwiftUI-drawn
// buttons and toggles publish NO in-process-introspectable representation
// on macOS (no NSView, and the SwiftUI accessibility-element tree does not
// materialize without a shown window — verified empirically). The offscreen
// structural view tests therefore need the LOAD-BEARING controls to be
// genuine AppKit views carrying accessibility identifiers: NSButton for the
// primary actions, NSButton(checkbox) for the queue checkboxes, and
// NSSearchField for the browser filter. These are the native AppKit
// controls, so the rendered UI is at least as native as the SwiftUI
// equivalents; `.disabled(_:)` propagates through the SwiftUI environment.

import AppKit
import SwiftUI

// MARK: - action button

/// A native NSButton with a stable accessibility identifier. Respects the
/// SwiftUI `.disabled(_:)` environment; `prominent` makes it the default
/// (Return-key) button.
struct AppKitActionButton: NSViewRepresentable {
    let identifier: String
    let title: String
    var prominent: Bool = false
    /// Optional key equivalent (Wave A, spec A4: Cmd+A / Cmd+D on the
    /// browser's header buttons). Ignored when `prominent` (Return stays
    /// the prominent equivalent). NSButton key equivalents participate in
    /// the key window's performKeyEquivalent chain and — unlike SwiftUI
    /// .keyboardShortcut, which materializes no introspectable NSView —
    /// they are assertable by the offscreen structural tests.
    var keyEquivalent: String = ""
    var keyEquivalentModifiers: NSEvent.ModifierFlags = []
    /// Fix round (Wave C2 final review, fix-before-close): SwiftUI's
    /// `.help(_:)` never reaches this NSViewRepresentable's NSButton, so
    /// blocked-reason strings applied that way are silently invisible. Set
    /// the tooltip through this parameter instead; `nil` clears it.
    var help: String? = nil
    /// Wave C hotfix (2026-08-04): opt-in, defaults false so every existing
    /// call site keeps its current required-compression-resistance
    /// behavior. A `true` row (the sidebar destination rows) can shrink
    /// below its natural title width and truncates the tail instead of
    /// forcing the row past a narrow window's edge — the graceful-
    /// truncation half of the M8 fixed-width defect class.
    var compressible: Bool = false
    /// Optional SF Symbol shown leading the title (UI polish pass: the
    /// header's tab pill selector). `nil` renders a text-only button,
    /// unchanged from every prior call site.
    var systemImage: String? = nil
    let action: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void = {}

        // NEVER name this `perform(_:)`: that collides with
        // NSObject.perform(_ selector:), and AppKit's sendAction would then
        // treat the sender pointer as a selector (unrecognized-selector
        // crash, caught by the click-plumbing structural test).
        @objc func runAction(_ sender: NSButton) {
            action()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.runAction(_:))
        )
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(
            compressible ? .defaultLow : .required, for: .horizontal
        )
        if compressible {
            (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        }
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.keyEquivalent = prominent ? "\r" : keyEquivalent
        button.keyEquivalentModifierMask = prominent ? [] : keyEquivalentModifiers
        button.isEnabled = context.environment.isEnabled
        button.controlSize = nsControlSize(context.environment.controlSize)
        button.toolTip = help
        if let systemImage {
            button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        } else {
            button.image = nil
            button.imagePosition = .noImage
        }
        button.setAccessibilityIdentifier(identifier)
    }
}

/// Map the SwiftUI `.controlSize` environment onto AppKit.
private func nsControlSize(_ size: ControlSize) -> NSControl.ControlSize {
    switch size {
    case .mini: return .mini
    case .small: return .small
    case .large, .extraLarge: return .large
    default: return .regular
    }
}

// MARK: - checkbox

/// A native checkbox (NSButton, `.switch`) with a stable accessibility
/// identifier. State is owned by the model: the checkbox reports taps via
/// `onToggle` and renders `isOn`.
struct AppKitCheckbox: NSViewRepresentable {
    let identifier: String
    let isOn: Bool
    var help: String?
    let onToggle: () -> Void

    final class Coordinator: NSObject {
        var onToggle: () -> Void = {}

        @objc func toggled(_ sender: NSButton) {
            onToggle()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: "",
            target: context.coordinator,
            action: #selector(Coordinator.toggled(_:))
        )
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onToggle = onToggle
        button.state = isOn ? .on : .off
        button.isEnabled = context.environment.isEnabled
        button.toolTip = help
        button.setAccessibilityIdentifier(identifier)
    }
}

// MARK: - filter field

/// A native NSSearchField bound to the model's filter text, with a stable
/// accessibility identifier.
struct AppKitFilterField: NSViewRepresentable {
    let identifier: String
    let placeholder: String
    @Binding var text: String

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        field.placeholderString = placeholder
        if field.stringValue != text {
            field.stringValue = text
        }
        field.setAccessibilityIdentifier(identifier)
    }
}

// MARK: - identifiers

/// Stable accessibility identifiers for the load-bearing M8 controls (used
/// by the offscreen structural tests and any future UI automation).
enum M8ControlID {
    static let scanLibrary = "m8.scanLibrary"
    static let filterField = "m8.filterField"
    /// One id for the Start Queue control: exactly one of its two hosts
    /// (consolidate footer, merge footer — M10) renders at a time, like
    /// `cancelAudit`.
    static let startQueue = "m8.startQueue"
    static let inspectorRescan = "m8.inspectorRescan"
    /// One id for the screen-1 Cancel affordance: exactly one of its three
    /// hosts (merge footer, consolidate footer, queue rail) renders at a
    /// time.
    static let cancelAudit = "m8.cancelAudit"
    static let continueToGate = "m8.continueToGate"
    static let startOver = "m8.startOver"
    static func checkbox(_ persistentId: String) -> String { "m8.check.\(persistentId)" }
}

/// Stable accessibility identifiers for the M9 in-app-apply controls
/// (confirm-gate apply button + pinned bar, and the apply-screen actions),
/// used by the offscreen structural tests and any future UI automation.
enum M9ControlID {
    /// Screen 3: the apply button that replaced the CLI hand-off panel.
    static let applyNow = "m9.applyNow"
    /// Screen 3's pinned bottom action bar (same treatment as screen 2).
    static let gateBackToReview = "m9.gateBackToReview"
    static let gateStartOver = "m9.gateStartOver"
    /// Screens 5/6: non-destructive actions only.
    static let applyStartOver = "m9.applyStartOver"
    static let applyBackToReview = "m9.applyBackToReview"
    static let applyRevealPlan = "m9.applyRevealPlan"
    /// Queue context: continue after a verified apply; retry/skip a failure.
    static let applyContinue = "m9.applyContinue"
    static let applyRetry = "m9.applyRetry"
    static let applySkip = "m9.applySkip"
}

/// Stable accessibility identifiers for the M11 unattended-run, report,
/// settings, and history controls.
enum M11ControlID {
    /// The unattended run's only interruption affordance.
    static let stopRun = "m11.stopRun"
    /// The judgment-pause screen's skip affordance (fix round 1).
    static let pauseSkipItem = "m11.pauseSkipItem"
    /// The post-run report screen.
    static let reportDone = "m11.reportDone"
    static let revealRunReport = "m11.revealRunReport"
    /// The settings panel's batch toggles.
    static let confirmEachApply = "m11.confirmEachApply"
    static let pauseOnJudgment = "m11.pauseOnJudgment"
    /// The history browser.
    static let historyFilter = "m11.historyFilter"
}

/// Stable accessibility identifiers for the M10 merge-batch controls.
enum M10ControlID {
    /// A mergeable group row's checkbox, by the group's exact name.
    static func groupCheckbox(_ name: String) -> String { "m10.checkGroup.\(name)" }
    /// A non-checkable merge-tab row's DISABLED checkbox (near-match
    /// clusters by normalized name; singletons by persistent ID).
    static func blockedCheckbox(_ key: String) -> String { "m10.checkBlocked.\(key)" }
}

/// Stable accessibility identifiers for the Wave A selection controls. One
/// id per control: the two hosts (merge MERGEABLE GROUPS header,
/// consolidate ALL PLAYLISTS header) never render at the same time, like
/// `m8.startQueue`.
enum WaveAControlID {
    static let selectAll = "wavea.selectAll"
    static let clearChecks = "wavea.clearChecks"
}

/// Stable accessibility identifiers for the Wave B mutation-gate controls.
enum WaveBControlID {
    /// The header's mode/tab pill selector (UI polish pass): one id per
    /// `BrowserTab` case.
    static func tabPill(_ tab: BrowserTab) -> String { "wb.tabPill.\(tab.rawValue)" }
    static let mutationExecute = "wb.mutationExecute"
    static let mutationDismiss = "wb.mutationDismiss"
    static let mutationNameField = "wb.mutationNameField"
    static let mutationCountField = "wb.mutationCountField"
    static let mutationPIDField = "wb.mutationPIDField"
    static let collisionWarning = "wb.collisionWarning"
    static let unattendedNotice = "wb.unattendedNotice"
    static let cleanupRefresh = "wb.cleanupRefresh"
    static let sortByName = "wb.sortByName"
    static let cleanupDeleteSelected = "wb.cleanupDeleteSelected"
    static let cleanupClearSelection = "wb.cleanupClearSelection"
    static func cleanupCheckbox(_ persistentId: String) -> String {
        "wb.cleanupCheck.\(persistentId)"
    }
    static let sortByCount = "wb.sortByCount"
    static func cleanupDelete(_ persistentId: String) -> String {
        "wb.cleanupDelete.\(persistentId)"
    }
    static func cleanupOpenGate(_ planFileName: String) -> String {
        "wb.cleanupGate.\(planFileName)"
    }
    /// Task 15 — browser row actions, the rename editor, and the align sheet.
    static let browserRefusal = "wb.browserRefusal"
    static let browserRenameField = "wb.browserRenameField"
    static let browserRenameAudit = "wb.browserRenameAudit"
    static let alignOpen = "wb.alignOpen"
    static func rowDelete(_ persistentId: String) -> String { "wb.rowDelete.\(persistentId)" }
    static func rowRename(_ persistentId: String) -> String { "wb.rowRename.\(persistentId)" }
    static func alignPick(_ name: String) -> String { "wb.alignPick.\(name)" }
    static func alignRename(_ persistentId: String) -> String { "wb.alignRename.\(persistentId)" }
}

/// Stable accessibility identifiers for the direct-mutation confirm/rename/
/// error sheets (Task 4, Sergio 2026-08-06). `folderCascadeNotice` and
/// `errorMessage` are Task 4 additions beyond the interface's required set
/// — the same one-off-notice-id pattern as `WaveBControlID.collisionWarning`
/// — so the offscreen structural tests can locate and verify their text.
enum DirectControlID {
    static let confirmExecute = "direct.confirmExecute"   // Delete N / Rename commit
    static let confirmCancel = "direct.confirmCancel"
    static let renameField = "direct.renameField"
    static let errorDismiss = "direct.errorDismiss"
    static func rowRename(_ persistentId: String) -> String { "direct.rowRename.\(persistentId)" }
    static let folderCascadeNotice = "direct.folderCascadeNotice"
    static let errorMessage = "direct.errorMessage"
    /// Final fix wave, Finding I1: the in-progress panel that keeps the sheet
    /// up through dispatch (so a failure never has to re-present a sheet that
    /// is mid-dismissal).
    static let inProgressStatus = "direct.inProgressStatus"
    static let inProgressCaption = "direct.inProgressCaption"
}

/// Stable accessibility identifiers for the Wave C1 failure-taxonomy
/// surfaces (spec C1.4/C1.5). These three are the ATTENDED failure screen's
/// ids — it renders exactly one outcome, so static ids carry no duplication
/// risk. The run-report screen renders one outcome PER ROW instead; its
/// controls (including its own "- Leftover target:" line) are the per-row
/// `report*` functions below, keyed by `RunItemRecord.name` (fix round 1,
/// combined Task 4+5 review, Critical finding).
enum WaveCControlID {
    static let failureClassBanner = "wc.failureClassBanner"
    static let deleteLeftoverTarget = "wc.deleteLeftoverTarget"
    static let leftoverResolveNotice = "wc.leftoverResolveNotice"

    /// Fix round 1 (combined Task 4+5 review, Critical finding): the
    /// run-report screen renders MULTIPLE failed rows (unlike the attended
    /// failure screen above, which renders exactly one outcome and so keeps
    /// the static ids), so its failure-class controls must be per-row,
    /// keyed by the row's `RunItemRecord.name` — the report's own dedupe
    /// key (`RunItemRecord.id`).
    static func reportFailureBanner(_ itemName: String) -> String {
        "wc.report.failureBanner.\(itemName)"
    }
    static func reportLeftoverLine(_ itemName: String) -> String {
        "wc.report.leftoverLine.\(itemName)"
    }
    static func reportDeleteLeftover(_ itemName: String) -> String {
        "wc.report.deleteLeftover.\(itemName)"
    }
    static func reportResolveNotice(_ itemName: String) -> String {
        "wc.report.resolveNotice.\(itemName)"
    }
}

/// Stable accessibility identifiers for the Wave C2 destination shell
/// (sidebar rows, the staged panel's stage chips, the Activity idle
/// caption). Tasks 5-6 consume the stage and destination members.
enum WaveC2ControlID {
    /// Sidebar destination rows (Task 6).
    static func destinationRow(_ destination: AppDestination) -> String {
        "wc2.dest.\(destination.rawValue)"
    }
    /// The attended staged panel's stage chips (Task 5).
    static let stageReview = "wc2.stage.review"
    static let stageConfirm = "wc2.stage.confirm"
    static let stageApply = "wc2.stage.apply"
    /// The Activity idle screen's last-outcome caption (Task 4).
    static let activityIdleCaption = "wc2.activityIdleCaption"
    /// Final review, Finding I-2: the failed/cancelled idle branches' verbatim
    /// failure text and shared "back to Library" affordance.
    static let activityAuditFailure = "wc2.activityAuditFailure"
    static let activityBackToLibrary = "wc2.activityBackToLibrary"
    /// Final review, Finding I-1: the pinned banner that keeps an
    /// unacknowledged report reachable when a higher ActivityView precedence
    /// (the unattended surface or the staged panel) is rendering over it, and
    /// the report screen's own way back to that precedence.
    static let pendingReportBanner = "wc2.pendingReportBanner"
    static let pendingReportBack = "wc2.pendingReportBack"
    /// The browser area's scan-in-flight status line — shared by all three
    /// tabs (Sergio, 2026-08-06: Cleanup previously bypassed it).
    static let browserScanningStatus = "wc2.browserScanningStatus"
}

/// Stable accessibility identifiers for the UI-rework-Part-2 Settings
/// preferences (Appearance / Startup / Notifications) — the genuine
/// user-preferences screen that replaced the "Artifacts & Automation"
/// plumbing panel.
enum SettingsControlID {
    /// The Appearance pill selector (one id per `AppearanceMode` case).
    static func appearance(_ mode: AppearanceMode) -> String {
        "settings.appearance.\(mode.rawValue)"
    }
    static let reloadLibraryOnStart = "settings.reloadLibraryOnStart"
    /// The "Default tab on launch" pill selector (one id per `BrowserTab`
    /// case).
    static func defaultTabOnLaunch(_ tab: BrowserTab) -> String {
        "settings.defaultTabOnLaunch.\(tab.rawValue)"
    }
    static let playSoundOnRunFinish = "settings.playSoundOnRunFinish"
}

// MARK: - typed-token field (Wave B)

/// A native NSTextField bound to a typed-confirm token, with a stable
/// accessibility identifier. The placeholder is ALWAYS empty — the required
/// value is rendered as selectable text ABOVE the field, never inside it.
/// NSTextField reports typed input verbatim; the binding writes it to the
/// model raw (no trim, no folding — the never-normalize rule).
struct AppKitTokenField: NSViewRepresentable {
    let identifier: String
    @Binding var text: String
    /// Fires when Return is pressed in the field (Task 4, direct-mutation
    /// rename sheet: Enter commits the pending action). Defaults to a
    /// no-op so every existing call site is unaffected.
    var onSubmit: () -> Void = {}

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void = {}

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl, textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            onSubmit()
            return true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: "")
        field.delegate = context.coordinator
        field.placeholderString = ""
        field.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        if field.stringValue != text {
            field.stringValue = text
        }
        field.isEnabled = context.environment.isEnabled
        field.setAccessibilityIdentifier(identifier)
    }
}

// MARK: - static text marker (Wave B)

/// A native NSTextField LABEL with a stable accessibility identifier — for
/// load-bearing TEXT the offscreen structural tests must locate (SwiftUI
/// Text publishes no NSView; see this file's header). `maximumLines` is the
/// AppKit analogue of the lineLimit discipline: the label can never grow a
/// screen unbounded.
struct AppKitStaticText: NSViewRepresentable {
    let identifier: String
    let text: String
    var maximumLines: Int = 3

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.isSelectable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = text
        field.maximumNumberOfLines = maximumLines
        field.setAccessibilityIdentifier(identifier)
    }
}
