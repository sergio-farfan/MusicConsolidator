// AppleMusicConsolidatorApp.swift
// The app shell: the @main SwiftUI entry point. ONE main window hosts the
// destination shell (Library / Activity / Reports / Settings — Wave C2);
// history lives in the Reports destination, so the standalone History
// window (and its Cmd-Shift-H shortcut) is gone. The M6 read harness is
// retained as a separate Diagnostics window (Window menu, or Cmd-Shift-D)
// — the fidelity-probe surface (preflight, raw all-copies read, raw
// wire-JSON export).

import SwiftUI

@main
struct AppleMusicConsolidatorApp: App {
    var body: some Scene {
        WindowGroup {
            // Wave C hotfix (2026-08-04): the enforced functional minimum
            // lives HERE, not on ConsolidatorFlowView itself — a hard
            // `.frame(minWidth:minHeight:)` on the root view would override
            // every internal fixed-width fix underneath it. `.contentSize`
            // was reduced elsewhere so 900x620 is genuinely reachable
            // (candidate column + gate pane, sidebar, browser header/list/
            // inspector all now compress under it); `.windowResizability(
            // .contentMinSize)` then refuses to let the user resize below
            // whatever the content's own minimum turns out to be (Apple
            // docs: "prevents the user from changing the window size to
            // less than its content" — developer.apple.com/documentation/
            // SwiftUI/WindowResizability/contentMinSize), so the window can
            // never again be dragged into an overflow it can't render.
            ConsolidatorFlowView()
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowResizability(.contentMinSize)

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView()
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}
