// NarrowWindowStructuralTests.swift
// Wave C hotfix (2026-08-04) — the M8 defect class: FIXED WIDTHS that cannot
// compress. At a real window narrower than ~1150pt the aggregate MINIMUM
// width of the root split (the sidebar plus SourceSelectionView's header
// controls, its fixed-width inspector, and CleanupTabView's fixed 480pt gate
// pane and 460pt candidate-column minimum) exceeds the window width, so BOTH
// edges clip: sidebar destination rows truncate from the LEFT (their frame's
// left edge goes negative), and the detail content — including the Cleanup
// tab's gate pane — runs off the RIGHT edge. This suite hosts the root
// shell (in its default state AND with the Cleanup tab selected, the exact
// live-walkthrough scenario) and the Cleanup tab standalone at 900x620 —
// the hotfix's target functional minimum — and pins FULL geometric
// containment (frame inside the window box on both edges, not just
// presence in the view tree). RED against the pre-fix fixed widths; same
// offscreen discipline as the other structural suites: never-shown windows,
// fixture-driven models, Music never contacted.

import AppKit
import SwiftUI
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

private let narrowWindowBox = NSRect(x: 0, y: 0, width: 900, height: 620)

/// Root-embedded content sits inside a NavigationSplitView, which reserves
/// a ~32pt unified-toolbar band even though no toolbar is ever shown (the
/// same calibrated allowance RootNavigationStructuralTests already accepts
/// via its own "height <= 840 for an 800pt window" sanity check). This
/// suite's concern is horizontal compression (the M8 fixed-width defect
/// class), so root-embedded vertical containment reuses that established
/// tolerance instead of inventing a stricter one this hotfix isn't about.
private let narrowRootWindowBox = NSRect(x: 0, y: 0, width: 900, height: 660)

@MainActor
private func expectContained(
    _ id: String,
    in hosting: NSView,
    box: NSRect = narrowWindowBox,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    guard let control = view(under: hosting, axIdentifier: id) else {
        Issue.record("control \(id) is missing", sourceLocation: sourceLocation)
        return
    }
    let frame = control.convert(control.bounds, to: hosting)
    #expect(box.contains(frame), "\(id) at \(frame)", sourceLocation: sourceLocation)
}

/// Sweep every AppKit-backed control (anything carrying an accessibility
/// identifier) and pin BOTH horizontal edges — left edge never negative
/// (the sidebar-truncation symptom) and right edge never past the window's
/// width (the detail overrun symptom). Existence checks alone miss this
/// class of bug entirely (the controls are all still IN the tree; they are
/// simply laid out outside the visible box).
@MainActor
private func expectAllControlsWithinHorizontalBounds(
    in hosting: NSView,
    maxX: CGFloat,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    let identified = allViews(under: hosting).filter { !$0.accessibilityIdentifier().isEmpty }
    #expect(!identified.isEmpty, "no identified controls found to check", sourceLocation: sourceLocation)
    for control in identified {
        let frame = control.convert(control.bounds, to: hosting)
        #expect(
            frame.minX >= -0.5,
            "\(control.accessibilityIdentifier()) left edge at \(frame)",
            sourceLocation: sourceLocation
        )
        #expect(
            frame.maxX <= maxX + 0.5,
            "\(control.accessibilityIdentifier()) right edge at \(frame)",
            sourceLocation: sourceLocation
        )
    }
}

@MainActor
@Suite("Narrow-window structural view tests (Wave C hotfix)", .serialized)
struct NarrowWindowStructuralTests {

    @Test("the root destination shell fits 900x620 (default Library tab), every destination row contained")
    func rootFitsNarrowWindowDefault() throws {
        let harness = try ModelHarness(runner: ScriptedRunner(outputs: []))
        defer { harness.cleanUp() }
        let fixture = HostedFixture(
            ConsolidatorFlowView(model: harness.model), width: 900, height: 620
        )
        defer { fixture.tearDown() }

        for destination in AppDestination.allCases {
            expectContained(
                WaveC2ControlID.destinationRow(destination), in: fixture.hosting,
                box: narrowRootWindowBox
            )
        }
        expectAllControlsWithinHorizontalBounds(in: fixture.hosting, maxX: 900)
    }

    // The exact live-walkthrough scenario: the Cleanup tab selected inside
    // the full root shell. Its fixed-width gate pane pulls the detail's
    // minimum well past the window width, compressing the sidebar and
    // pushing its destination rows' left edge negative — the reported
    // "brary" / "ctivity" / "eports" / "ettings" truncation.
    @Test("the root destination shell fits 900x620 with the Cleanup tab selected")
    func rootFitsNarrowWindowOnCleanupTab() async throws {
        let harness = try ModelHarness(runner: ScriptedRunner(outputs: [gateListingWire()]))
        defer { harness.cleanUp() }
        harness.model.setBrowserTab(.cleanup)
        // UI rework Part 2: ConsolidatorFlowView's one-shot launch effect
        // applies `defaultBrowserTabOnLaunch` (default .merge) once the
        // view appears; without this, it would silently override the
        // Cleanup selection this test just made. Declaring the launch
        // preference to match keeps the one-shot application a no-op here,
        // mirroring how `confirmEachApply` is declared to match the queue
        // mode under test elsewhere in this suite.
        harness.model.setDefaultBrowserTabOnLaunch(.cleanup)
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        // Task 5: the gate pane is retired from this composition — pin the
        // direct row/batch controls instead (a selection is required for
        // the batch control to render at all).
        harness.model.toggleCleanupChecked("SOLO000000000001")
        let fixture = HostedFixture(
            ConsolidatorFlowView(model: harness.model), width: 900, height: 620
        )
        defer { fixture.tearDown() }

        for destination in AppDestination.allCases {
            expectContained(
                WaveC2ControlID.destinationRow(destination), in: fixture.hosting,
                box: narrowRootWindowBox
            )
        }
        expectContained(
            WaveBControlID.sortByName, in: fixture.hosting, box: narrowRootWindowBox
        )
        expectContained(
            WaveBControlID.cleanupDeleteSelected, in: fixture.hosting, box: narrowRootWindowBox
        )
        expectContained(
            DirectControlID.rowRename("SOLO000000000001"), in: fixture.hosting,
            box: narrowRootWindowBox
        )
        expectAllControlsWithinHorizontalBounds(in: fixture.hosting, maxX: 900)
    }

    @Test("the cleanup tab's candidate column and its direct row/batch controls fit 900x620 standalone")
    func cleanupTabFitsNarrowWindow() async throws {
        let harness = try ModelHarness(runner: ScriptedRunner(outputs: [gateListingWire()]))
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        // Task 5: the fixed-width gate pane this suite used to pin is
        // retired from this composition — CleanupTabView is now the
        // candidate column alone. Pin the direct controls instead: the
        // sort header (always present), the batch delete control (present
        // once a row is checked), and one row's Rename... control.
        harness.model.toggleCleanupChecked("SOLO000000000001")
        let fixture = HostedFixture(
            CleanupTabView(model: harness.model), width: 900, height: 620
        )
        defer { fixture.tearDown() }

        expectContained(WaveBControlID.sortByName, in: fixture.hosting)
        // Sergio, 2026-08-06: the batch controls moved to SourceSelectionView's
        // shared footer bar — pinned there by the root-window test above and
        // by cleanupFooterMirrorsOtherModes. Standalone, the tab is the list.
        expectContained(DirectControlID.rowRename("SOLO000000000001"), in: fixture.hosting)
        expectAllControlsWithinHorizontalBounds(in: fixture.hosting, maxX: 900)
    }
}
