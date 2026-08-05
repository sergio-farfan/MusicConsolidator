// StructuralViewTests.swift
// M8 fix round 2 — OFFSCREEN STRUCTURAL VIEW TESTS. Views are instantiated
// via NSHostingView into an NSWindow object that is NEVER ordered onto the
// screen (no makeKeyAndOrderFront/orderFront anywhere): nothing is shown,
// no app is launched, and the models are fixture-driven (canned wire text
// through ScriptedRunner) so Music is never contacted.
//
// Assertions walk the materialized NSVIEW tree: AppKit-backed elements
// (NSTableView-backed List rows/headers, NSTextField, NSSegmentedControl,
// and the app's AppKit-backed action buttons) carry accessibility
// identifiers, so the checks are structural rather than string-fragile.
// (The SwiftUI in-process accessibility-element tree does NOT materialize
// without a shown window — verified empirically during fix round 2 — so
// the load-bearing footer/inspector actions are deliberately AppKit-backed
// NSButtons; see AppKitActionButton.)
//
// These tests were written against the BROKEN M8 composition first and
// observed RED (the blind-spot closure demanded by fix round 2); the RED
// evidence per test is recorded in m8-report.md "Fix round 2".

import AppKit
import SwiftUI
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

// MARK: - offscreen hosting harness

@MainActor
struct HostedFixture<V: View> {
    let hosting: NSHostingView<V>
    let window: NSWindow

    init(_ view: V, width: CGFloat = 1280, height: CGFloat = 860) {
        hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // NEVER ordered in: the window object exists purely as a layout
        // context; nothing is displayed.
        window.contentView = hosting
        window.layoutIfNeeded()
        pump()
    }

    /// Run scheduled SwiftUI/AppKit update passes (RunLoop.run is
    /// unavailable in async contexts; this synchronous helper is the
    /// standard workaround).
    func pump(times: Int = 15, interval: TimeInterval = 0.02) {
        for _ in 0..<times {
            RunLoop.main.run(until: Date().addingTimeInterval(interval))
            window.layoutIfNeeded()
        }
    }

    func tearDown() {
        window.contentView = nil
    }
}

/// Synchronous main-runloop drain (RunLoop.run is unavailable in async
/// contexts; this sync helper is the standard workaround).
@MainActor
func drainMainRunLoop(times: Int = 10, interval: TimeInterval = 0.02) {
    for _ in 0..<times {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }
}

// MARK: - NSView-tree walking

@MainActor
func allViews(under root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + allViews(under: $0) }
}

@MainActor
func views(under root: NSView, classNameContains needle: String) -> [NSView] {
    allViews(under: root).filter { String(describing: type(of: $0)).contains(needle) }
}

@MainActor
func view(under root: NSView, axIdentifier: String) -> NSView? {
    allViews(under: root).first { $0.accessibilityIdentifier() == axIdentifier }
}

/// Content rows of NSTableView-backed SwiftUI Lists (cells never float).
@MainActor
func listContentCellCount(under root: NSView) -> Int {
    views(under: root, classNameContains: "ListTableCellView").count
}

/// Section headers (including the pinned floating header).
@MainActor
func listHeaderCount(under root: NSView) -> Int {
    views(under: root, classNameContains: "ListTableHeaderView").count
}

/// Diagnostic dump (kept for future composition debugging).
@MainActor
func dumpViewTree(_ view: NSView, depth: Int = 0) -> String {
    var text = String(repeating: "  ", count: depth)
    text += "<\(type(of: view))> id='\(view.accessibilityIdentifier())' "
    text += "frame=\(Int(view.frame.width))x\(Int(view.frame.height))\n"
    for sub in view.subviews {
        text += dumpViewTree(sub, depth: depth + 1)
    }
    return text
}

// MARK: - fixture model

private func structuralEntry(id: Int, name: String, pid: String, count: Int) -> String {
    """
    {"id": \(id), "name": "\(name)", "persistent_id": "\(pid)", \
    "track_count": \(count), "smart": false, "special_kind": "none"}
    """
}

/// 6 playlists: one 2-copy group, one trailing-space near-match pair, two
/// plain singletons -> groups=1, nearMatches=1, singletons=4, all=6.
private func structuralListingWire() -> String {
    let entries = [
        structuralEntry(id: 10, name: "Trance 2022", pid: "S-A", count: 9),
        structuralEntry(id: 20, name: "Trance 2022", pid: "S-B", count: 10),
        structuralEntry(id: 30, name: "Kdrama", pid: "S-C", count: 7),
        structuralEntry(id: 40, name: "Kdrama ", pid: "S-D", count: 9),
        structuralEntry(id: 50, name: "Solo List", pid: "S-E", count: 4),
        structuralEntry(id: 60, name: "Another List", pid: "S-F", count: 5),
    ]
    return "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

/// A tall single-playlist snapshot: 30 duplicate pairs (distinct library
/// entries, bit-rate decisions) -> a long screen-2 decision list.
private func tallConsolidateWire() -> String {
    var tracks: [String] = []
    for pair in 0..<30 {
        tracks.append(wireTrack(
            sourceIndex: pair * 2, databaseId: 1000 + pair * 2,
            persistentId: String(format: "TALL%04d", pair * 2),
            title: "Tall Song \(pair)", bitRate: 128
        ))
        tracks.append(wireTrack(
            sourceIndex: pair * 2 + 1, databaseId: 1000 + pair * 2 + 1,
            persistentId: String(format: "TALL%04d", pair * 2 + 1),
            title: "Tall Song \(pair)", bitRate: 256
        ))
    }
    return wireSnapshot(playlists: [
        wirePlaylist(id: 900, name: "Tall List", persistentId: "TALL-PL", tracks: tracks)
    ])
}

@MainActor
private func loadedFixtureHarness(mode: ConsolidatorMode) async throws -> ModelHarness {
    let runner = ScriptedRunner(outputs: [structuralListingWire()])
    let harness = try ModelHarness(runner: runner, mode: mode, playlistName: "")
    harness.model.rescanLibrary()
    await harness.model.scanTask?.value
    return harness
}

// MARK: - the structural suite

@MainActor
@Suite("Offscreen structural view tests (fix round 2)", .serialized)
struct StructuralViewTests {

    // (a) + (e): merge mode exposes the mode control, the filter field, the
    // scan control, the three sections with the fixture's row counts, the
    // M10 group checkboxes, and the queue footer control.
    @Test("merge browser exposes mode control, filter, sections, checkboxes, and footer")
    func mergeBrowserStructure() async throws {
        let harness = try await loadedFixtureHarness(mode: .merge)
        defer { harness.cleanUp() }
        let fixture = HostedFixture(SourceSelectionView(model: harness.model))
        defer { fixture.tearDown() }

        // Mode control (tab pill selector) is present: one pill per tab.
        for tab in BrowserTab.allCases {
            #expect(view(under: fixture.hosting, axIdentifier: WaveBControlID.tabPill(tab)) != nil)
        }

        // Filter field and scan control are present, by identifier.
        #expect(view(under: fixture.hosting, axIdentifier: "m8.filterField") != nil)
        #expect(view(under: fixture.hosting, axIdentifier: "m8.scanLibrary") != nil)

        // Three sections: MERGEABLE GROUPS / NEAR MATCHES / SINGLETONS.
        #expect(listHeaderCount(under: fixture.hosting) == 3)
        // Three content rows: 1 group + 1 near-match cluster + the collapsed
        // singletons disclosure row.
        #expect(listContentCellCount(under: fixture.hosting) == 3)

        // M10: the GROUP row carries an ENABLED checkbox; the near-match
        // cluster row carries a DISABLED one (non-checkable, like
        // consolidate's blocked rows).
        let groupCheckbox = try #require(
            view(under: fixture.hosting, axIdentifier: M10ControlID.groupCheckbox("Trance 2022"))
                as? NSButton
        )
        #expect(groupCheckbox.isEnabled)
        let blocked = try #require(
            view(under: fixture.hosting, axIdentifier: M10ControlID.blockedCheckbox("Kdrama"))
                as? NSButton
        )
        #expect(!blocked.isEnabled)

        // The footer's queue control exists (shared id with consolidate:
        // exactly one footer renders at a time).
        #expect(view(under: fixture.hosting, axIdentifier: "m8.startQueue") != nil)
    }

    // (a, M10): [Start Queue] is disabled until a group is checked, and the
    // merge checkbox click plumbing drives the model end to end.
    @Test("merge start queue enables on a checked group; checkbox clicks drive the model")
    func mergeStartQueueDisabledUntilChecked() async throws {
        let runner = ScriptedRunner(outputs: [
            structuralListingWire(),
            mergeFixtureWire(name: "Trance 2022"),
        ])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value

        let fixture = HostedFixture(SourceSelectionView(model: harness.model))
        defer { fixture.tearDown() }

        let start = try #require(
            view(under: fixture.hosting, axIdentifier: "m8.startQueue") as? NSButton
        )
        #expect(!start.isEnabled)

        // Selection alone must NOT enable the queue (inspection only).
        harness.model.browserSelection = .group("Trance 2022")
        fixture.pump()
        #expect(!start.isEnabled)

        let checkbox = try #require(
            view(under: fixture.hosting, axIdentifier: M10ControlID.groupCheckbox("Trance 2022"))
                as? NSButton
        )
        checkbox.performClick(nil)
        #expect(harness.model.checkedGroupNames == ["Trance 2022"])
        fixture.pump()
        #expect(start.isEnabled)

        start.performClick(nil)
        #expect(harness.model.isQueueActive)
        #expect(harness.model.queue.map(\.name) == ["Trance 2022"])
        await harness.awaitAudit()
        #expect(harness.model.queue.map(\.status) == [.audited])
        #expect(harness.model.result?.mode == .merge)
    }

    // M10: with the merge queue active, the rail replaces the queue footer
    // and the screen stays bounded.
    @Test("merge queue rail renders in place of the footer and fits the window")
    func mergeQueueRailFits() async throws {
        let runner = ScriptedRunner(outputs: [
            structuralListingWire(),
            mergeFixtureWire(name: "Trance 2022"),
        ])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleCheckedGroup(name: "Trance 2022")
        harness.model.startQueue()
        await harness.awaitAudit()
        #expect(harness.model.queue.map(\.status) == [.audited])

        let fixture = HostedFixture(SourceSelectionView(model: harness.model))
        defer { fixture.tearDown() }
        #expect(
            fixture.hosting.frame.height <= 866,
            "merge mid-queue height \(fixture.hosting.frame.height)"
        )
        // The rail replaced the footer's start control.
        #expect(view(under: fixture.hosting, axIdentifier: "m8.startQueue") == nil)
    }

    // (b): consolidate mode exposes one row per playlist with checkboxes
    // and the queue footer, whose start control enables with a checked pick.
    @Test("consolidate browser exposes checkbox rows and the queue footer")
    func consolidateBrowserStructure() async throws {
        let harness = try await loadedFixtureHarness(mode: .consolidate)
        defer { harness.cleanUp() }
        let fixture = HostedFixture(SourceSelectionView(model: harness.model))
        defer { fixture.tearDown() }

        // One flat section, one row per playlist.
        #expect(listHeaderCount(under: fixture.hosting) == 1)
        #expect(listContentCellCount(under: fixture.hosting) == 6)

        // Checkboxes are AppKit-backed switch buttons inside the rows.
        let checkboxes = allViews(under: fixture.hosting).compactMap { $0 as? NSButton }
            .filter { $0.accessibilityIdentifier().hasPrefix("m8.check.") }
        #expect(checkboxes.count == 6)
        // Group members are disabled (the engine fails closed on ambiguous
        // names); the four singletons are enabled.
        #expect(checkboxes.filter { !$0.isEnabled }.count == 2)

        let start = try #require(
            view(under: fixture.hosting, axIdentifier: "m8.startQueue") as? NSButton
        )
        #expect(!start.isEnabled)
        harness.model.toggleChecked(persistentId: "S-E")
        fixture.pump()
        #expect(start.isEnabled)
    }

    // (c): selecting rows (driving the model) populates the inspector.
    @Test("selection populates the inspector content view")
    func selectionPopulatesInspector() async throws {
        let harness = try await loadedFixtureHarness(mode: .merge)
        defer { harness.cleanUp() }
        let fixture = HostedFixture(SourceSelectionView(model: harness.model))
        defer { fixture.tearDown() }

        func inspectorContentHeight() throws -> CGFloat {
            let scroll = try #require(
                views(under: fixture.hosting, classNameContains: "HostingScrollView").first
                    as? NSScrollView
            )
            let document = try #require(scroll.documentView)
            return document.frame.height
        }

        let emptyHeight = try inspectorContentHeight()

        // Group selection: per-copy identity table appears (content grows).
        harness.model.browserSelection = .group("Trance 2022")
        fixture.pump()
        let groupHeight = try inspectorContentHeight()
        #expect(groupHeight > emptyHeight + 40)

        // Near-match selection: the rename hint appears, including the
        // AppKit-backed rescan control.
        harness.model.browserSelection = .nearMatch("Kdrama")
        fixture.pump()
        #expect(view(under: fixture.hosting, axIdentifier: "m8.inspectorRescan") != nil)
    }

    // The AppKit-backed controls REALLY drive the model: performClick on the
    // materialized NSButtons exercises the representable target/action
    // plumbing end to end (checkbox -> checked set; Start Queue -> queue +
    // audit over canned wire text). No window is shown; no Music contact.
    @Test("AppKit controls drive the model (click plumbing)")
    func controlClickPlumbing() async throws {
        let runner = ScriptedRunner(outputs: [
            structuralListingWire(),
            consolidateFixtureWire(name: "Solo List"),
        ])
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value

        let fixture = HostedFixture(SourceSelectionView(model: harness.model))
        defer { fixture.tearDown() }

        let checkbox = try #require(
            view(under: fixture.hosting, axIdentifier: "m8.check.S-E") as? NSButton
        )
        checkbox.performClick(nil)
        #expect(harness.model.checkedPersistentIds == ["S-E"])
        fixture.pump()

        let start = try #require(
            view(under: fixture.hosting, axIdentifier: "m8.startQueue") as? NSButton
        )
        #expect(start.isEnabled)
        start.performClick(nil)
        #expect(harness.model.isQueueActive)
        #expect(harness.model.queue.map(\.name) == ["Solo List"])
        await harness.awaitAudit()
        #expect(harness.model.queue.map(\.status) == [.audited])
        #expect(harness.model.result?.sourceName == "Solo List")
    }

    // Geometric containment (coordinator addition, fix round 2): hosting at
    // a fixture window size, the mode control's and the footer control's
    // frames must fall WITHIN the hosting bounds — existence in the
    // hierarchy is not enough, because the live failure rendered existing
    // controls OFF-CANVAS (content laid out taller than the window, header
    // above the visible top, footer below the bottom, scrollbar out of
    // bounds).
    @Test("header and footer controls lie within the hosting bounds")
    func controlsLieWithinBounds() async throws {
        let harness = try await loadedFixtureHarness(mode: .merge)
        defer { harness.cleanUp() }
        let fixture = HostedFixture(
            SourceSelectionView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        let windowBox = NSRect(x: 0, y: 0, width: 1200, height: 800)

        // The hosting view itself must not outgrow the window.
        #expect(
            fixture.hosting.frame.size.height <= 806,
            "hosting grew to \(fixture.hosting.frame.size)"
        )

        for tab in BrowserTab.allCases {
            let pill = try #require(
                view(under: fixture.hosting, axIdentifier: WaveBControlID.tabPill(tab))
            )
            let pillFrame = pill.convert(pill.bounds, to: fixture.hosting)
            #expect(windowBox.contains(pillFrame), "mode pill \(tab) at \(pillFrame)")
        }

        let runButton = try #require(
            view(under: fixture.hosting, axIdentifier: "m8.startQueue")
        )
        let runFrame = runButton.convert(runButton.bounds, to: fixture.hosting)
        #expect(windowBox.contains(runFrame), "footer control at \(runFrame)")
    }

    // Fix round 3 (reviewer finding, probe adapted from
    // /tmp/m8-red-check ReviewProbesTests): screen 1 during an IN-FLIGHT
    // read renders ProgressPhaseView in the footer. Its reading caption
    // carried the last screen-1-reachable
    // `.fixedSize(horizontal: false, vertical: true)` — the same blowout
    // class, live during exactly the multi-minute window the user watches,
    // cropping away the footer's Cancel control. Pins: bounded height AND
    // the Cancel control's frame INSIDE the window box.
    @Test("screen 1 fits the window during the reading phase, Cancel visible")
    func screenOneFitsDuringReadingPhase() async throws {
        let blocking = BlockingRunner(payload: structuralListingWire())
        let harness = try ModelHarness(runner: blocking, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }

        harness.model.rescanLibrary()
        blocking.proceed.signal()
        #expect(await pollUntil { harness.model.loadedSections != nil })

        harness.model.toggleChecked(persistentId: "S-E")
        harness.model.startQueue()
        #expect(await pollUntil { harness.model.isRunning })

        let fixture = HostedFixture(SourceSelectionView(model: harness.model))
        let height = fixture.hosting.frame.height
        let windowBox = NSRect(x: 0, y: 0, width: 1280, height: 860)
        let cancel = view(under: fixture.hosting, axIdentifier: "m8.cancelAudit")
        let cancelFrame = cancel.map { $0.convert($0.bounds, to: fixture.hosting) }
        fixture.tearDown()

        // Release the held read before asserting, so a failure cannot
        // strand the detached read task.
        blocking.proceed.signal()
        await harness.awaitAudit()

        #expect(height <= 866, "reading-phase height \(height)")
        let frame = try #require(cancelFrame, "Cancel control missing during the read")
        #expect(windowBox.contains(frame), "Cancel control at \(frame)")
    }

    // Fix round 3 sweep: the WORST-CASE remaining runStatus composition —
    // an active queue rail plus a failed run with a long verbatim error
    // message — must also fit the window.
    @Test("screen 1 fits the window in the failed + queue-rail state")
    func screenOneFitsInFailedQueueState() async throws {
        let longMessage = "Music automation failed: "
            + String(repeating: "the automation layer reported a long diagnostic sentence ", count: 8)
        let runner = ScriptedRunner(results: [
            .success(structuralListingWire()),
            .failure(MusicCommandError(longMessage)),
        ])
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "S-E")
        harness.model.startQueue()
        await harness.awaitAudit()
        #expect(harness.model.queue.map(\.status) == [.failed])

        let fixture = HostedFixture(SourceSelectionView(model: harness.model))
        defer { fixture.tearDown() }
        #expect(
            fixture.hosting.frame.height <= 866,
            "failed+rail height \(fixture.hosting.frame.height)"
        )
    }

    // Fix round 4, item 2: screen 2's actions must be ALWAYS VISIBLE — with
    // a TALL plan (long decision list) the Continue control's frame must be
    // inside the window box WITHOUT scrolling.
    @Test("plan review pins its actions visible for a tall plan")
    func planReviewActionsPinned() async throws {
        let runner = ScriptedRunner(outputs: [tallConsolidateWire()])
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "Tall List")
        defer { harness.cleanUp() }
        harness.model.startAudit()
        await harness.awaitAudit()
        #expect((harness.model.result?.decisions.count ?? 0) >= 30)

        let fixture = HostedFixture(PlanReviewView(model: harness.model))
        defer { fixture.tearDown() }
        let windowBox = NSRect(x: 0, y: 0, width: 1280, height: 860)
        #expect(fixture.hosting.frame.height <= 866)

        let continueButton = try #require(
            view(under: fixture.hosting, axIdentifier: "m8.continueToGate")
        )
        let continueFrame = continueButton.convert(continueButton.bounds, to: fixture.hosting)
        #expect(windowBox.contains(continueFrame), "Continue control at \(continueFrame)")

        let startOver = try #require(
            view(under: fixture.hosting, axIdentifier: "m8.startOver")
        )
        let startOverFrame = startOver.convert(startOver.bounds, to: fixture.hosting)
        #expect(windowBox.contains(startOverFrame), "Start over control at \(startOverFrame)")
    }

    // Fix round 3 (adopted reviewer probe): screens 2/3 keep their
    // fixedSize texts by design (ScrollView/GroupBox context) — pin that
    // the context really does keep them bounded.
    @Test("screens 2 and 3 fit the window with their fixedSize texts")
    func laterScreensFitWindow() async throws {
        let runner = ScriptedRunner(outputs: [consolidateFixtureWire()])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startAudit()
        await harness.awaitAudit()
        #expect(harness.model.result != nil)

        let review = HostedFixture(PlanReviewView(model: harness.model))
        let reviewHeight = review.hosting.frame.height
        review.tearDown()
        #expect(reviewHeight <= 866, "plan review height \(reviewHeight)")

        let gate = HostedFixture(ConfirmGateView(model: harness.model))
        let gateHeight = gate.hosting.frame.height
        gate.tearDown()
        #expect(gateHeight <= 866, "confirm gate height \(gateHeight)")
    }

    // Fix round 3 (adopted reviewer probe): the AppKit representable's
    // button and coordinator are released once the hosting view is torn
    // down (no retain cycles).
    @Test("AppKit control coordinator does not outlive the host")
    func coordinatorReleased() async throws {
        let runner = ScriptedRunner(outputs: [structuralListingWire()])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value

        weak var weakButton: NSButton?
        weak var weakTarget: AnyObject?
        try autoreleasepool {
            var fixture: HostedFixture? = HostedFixture(SourceSelectionView(model: harness.model))
            let button = try #require(
                view(under: fixture!.hosting, axIdentifier: "m8.scanLibrary") as? NSButton
            )
            weakButton = button
            weakTarget = button.target
            fixture?.tearDown()
            fixture = nil
        }
        drainMainRunLoop()
        #expect(weakButton == nil, "NSButton retained after teardown")
        #expect(weakTarget == nil, "coordinator retained after teardown")
    }

    // Umbrella regression for the root cause: the screen-1 content must fit
    // the window height — a minimum-height blowout (the fixedSize-on-long-
    // text class) center-crops the header above the toolbar and the footer
    // below the window, which is exactly the live failure.
    @Test("screen 1 fits the window height in every listing state")
    func screenOneFitsWindow() async throws {
        // Loaded, both modes.
        for mode in ConsolidatorMode.allCases {
            let harness = try await loadedFixtureHarness(mode: mode)
            defer { harness.cleanUp() }
            let fixture = HostedFixture(SourceSelectionView(model: harness.model))
            defer { fixture.tearDown() }
            #expect(
                fixture.hosting.frame.height <= 866,
                "\(mode) loaded height \(fixture.hosting.frame.height)"
            )
        }
        // Idle (pre-scan) state.
        let idle = try ModelHarness(
            runner: ScriptedRunner(outputs: []), mode: .merge, playlistName: ""
        )
        defer { idle.cleanUp() }
        let fixture = HostedFixture(SourceSelectionView(model: idle.model))
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 866, "idle height \(fixture.hosting.frame.height)")
    }
}

// MARK: - Wave A (A2): the shared queue table

/// SwiftUI's indeterminate ProgressView materializes as an AppKit
/// NSProgressIndicator even offscreen (verified empirically), so live-state
/// spinners are countable structurally.
@MainActor
private func liveSpinnerCount(under root: NSView) -> Int {
    views(under: root, classNameContains: "ProgressIndicator").count
}

/// Task 5: a 6-item listing wire for the unattended-screen adoption pin.
private func sixItemListingWire() -> String {
    let names = [
        "Alpha List", "Beta List", "Gamma List",
        "Delta List", "Epsilon List", "Zeta List",
    ]
    let entries = names.enumerated().map { index, name in
        structuralEntry(id: (index + 1) * 10, name: name, pid: "Q-\(index)", count: 4 + index)
    }
    return "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

@MainActor
@Suite("Offscreen structural view tests (Wave A queue table)", .serialized)
struct QueueTableStructuralTests {

    // A 5-item queue covering both live states and three stored states.
    // The Grid must materialize every row EAGERLY (the Grid-not-Table
    // rationale): the fitting height proves a header plus five rows exist,
    // and the two live rows (auditing + applying) each surface a spinner.
    @Test("the queue table renders a 5-item mixed-state queue within bounds")
    func queueTableFitsMixedStates() throws {
        let rows = [
            QueueTableRow(id: "Alpha List", name: "Alpha List",
                          copyCounts: [9, 10], state: .applied),
            QueueTableRow(id: "Beta List", name: "Beta List",
                          copyCounts: [551], state: .failed),
            QueueTableRow(id: "Gamma List", name: "Gamma List",
                          copyCounts: [12, 8, 31], state: .applying(step: 3, total: 7)),
            QueueTableRow(id: "Delta List", name: "Delta List",
                          copyCounts: [], state: .skipped),
            QueueTableRow(id: "Epsilon List", name: "Epsilon List",
                          copyCounts: [1], state: .auditing),
        ]
        let fixture = HostedFixture(QueueTableView(rows: rows), width: 1200, height: 800)
        defer { fixture.tearDown() }

        #expect(
            fixture.hosting.frame.height <= 806,
            "queue table height \(fixture.hosting.frame.height)"
        )
        #expect(
            fixture.hosting.fittingSize.height >= 110,
            "fitting height \(fixture.hosting.fittingSize.height) — rows not materialized"
        )
        #expect(fixture.hosting.fittingSize.height <= 800)
        #expect(liveSpinnerCount(under: fixture.hosting) == 2)
    }

    // The adapter derives display states from the stored status plus the
    // current item's live run/apply state, and carries Task 3's counts.
    @Test("queueTableRows derives the awaiting-review state and the item counts")
    func queueTableRowMapping() async throws {
        let runner = ScriptedRunner(outputs: [
            structuralListingWire(),
            consolidateFixtureWire(name: "Solo List"),
        ])
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "S-E")
        harness.model.startQueue()
        await harness.awaitAudit()
        #expect(harness.model.queue.map(\.status) == [.audited])

        let rows = queueTableRows(for: harness.model)
        #expect(rows.map(\.name) == ["Solo List"])
        #expect(rows.map(\.state) == [.awaitingReview])
        // The audit's live count (the fixture has 4 tracks) — a consolidate
        // item always carries exactly one count.
        #expect(rows.map(\.copyCounts) == [[4]])
    }

    // Adoption pin: the rail hosts the table mid-queue at the 1200x800
    // fixture size and stays bounded (the 1280x860 rail pins already exist
    // in the fix-round-2 suite above).
    @Test("the merge queue rail hosts the table and stays bounded mid-queue")
    func mergeRailWithTableFits() async throws {
        let runner = ScriptedRunner(outputs: [
            structuralListingWire(),
            mergeFixtureWire(name: "Trance 2022"),
        ])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleCheckedGroup(name: "Trance 2022")
        harness.model.startQueue()
        await harness.awaitAudit()
        #expect(harness.model.queue.map(\.status) == [.audited])

        let fixture = HostedFixture(
            SourceSelectionView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(
            fixture.hosting.frame.height <= 806,
            "rail height \(fixture.hosting.frame.height)"
        )
    }

    // Task 5: the unattended surface hosts the SAME table. While item 1's
    // audit read is held in flight, the screen shows exactly three spinners
    // — ProgressPhaseView (current activity), the "Current:" header chip
    // (Wave A fix wave, finding 2: it now shares queueTableRows' exact
    // derivation via StatusChipView instead of a static Chip, so it goes
    // live too), and the table's live auditing row — and stays bounded
    // with 6 queue rows.
    @Test("the unattended run surface fits with a 6-item queue and a live table row")
    func unattendedScreenFitsWithSixItems() async throws {
        let runner = StagedBlockingRunner(
            outputs: [sixItemListingWire(), consolidateFixtureWire(name: "Alpha List")],
            blockAt: [1]
        )
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false
        )
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        for pid in ["Q-0", "Q-1", "Q-2", "Q-3", "Q-4", "Q-5"] {
            harness.model.toggleChecked(persistentId: pid)
        }
        harness.model.startQueue()
        #expect(await pollUntil { runner.runCount == 2 })
        #expect(harness.model.isRunUnattended)
        #expect(harness.model.queue.count == 6)

        let fixture = HostedFixture(ApplyFlowView(model: harness.model), width: 1200, height: 800)
        let height = fixture.hosting.frame.height
        let spinners = liveSpinnerCount(under: fixture.hosting)
        let stop = view(under: fixture.hosting, axIdentifier: M11ControlID.stopRun)
        let stopFrame = stop.map { $0.convert($0.bounds, to: fixture.hosting) }
        fixture.tearDown()

        // Release the held read BEFORE asserting so a failure cannot strand
        // the detached pipeline; the exhausted runner fails the remaining
        // items closed and the run report finishes.
        runner.proceed.signal()
        #expect(await pollUntil { harness.model.finishedRunReport != nil })

        #expect(height <= 806, "unattended 6-item height \(height)")
        #expect(spinners == 3, "spinner count \(spinners)")
        let frame = try #require(stopFrame, "stop control missing during the run")
        #expect(
            NSRect(x: 0, y: 0, width: 1200, height: 800).contains(frame),
            "stop control at \(frame)"
        )
    }

    // Wave A fix wave, finding 2: the header chip must be driven by the
    // SAME derivation as the table's current row — not just "some chip
    // spins", but the identical QueueDisplayState. Pinned directly at the
    // row-model level (currentQueueDisplayState vs. queueTableRows) so a
    // future edit that reintroduces divergence fails here even if the
    // spinner count above coincidentally still matches.
    @Test("the header's derived state matches queueTableRows' current row exactly")
    func currentStateMirrorsTableRow() async throws {
        let runner = StagedBlockingRunner(
            outputs: [structuralListingWire(), consolidateFixtureWire(name: "Solo List")],
            blockAt: [1]
        )
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false
        )
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "S-E")
        harness.model.startQueue()
        #expect(await pollUntil { runner.runCount == 2 })

        let rows = queueTableRows(for: harness.model)
        let currentRow = try #require(rows.first { $0.id == "row-\(harness.model.queueIndex)" })
        #expect(currentQueueDisplayState(for: harness.model) == currentRow.state)
        #expect(currentRow.state == .auditing)

        runner.proceed.signal()
        #expect(await pollUntil { harness.model.finishedRunReport != nil })
    }

    // Wave A fix wave, finding 5: queue rows are keyed by index, not name.
    // NFC/NFD twin names are canonically equal under Swift's default
    // String ==/hashing (Unicode canonical equivalence) but scalar-
    // different; before the fix, `id: item.name` would have collapsed both
    // rows onto one SwiftUI identity.
    @Test("canonically-equivalent-but-scalar-different names produce distinct row ids")
    func rowIdsSurviveCanonicalTwins() async throws {
        let nfc = "Caf\u{00E9} List" // precomposed e-acute
        let nfd = "Cafe\u{0301} List" // "e" + combining acute
        #expect(nfc == nfd, "fixture sanity: the two names must be canonically equal")

        let wire = "{\"playlists\": [\(structuralEntry(id: 10, name: nfc, pid: "NFC-1", count: 3)), "
            + "\(structuralEntry(id: 20, name: nfd, pid: "NFD-1", count: 5))]}"
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: [wire]), mode: .consolidate, playlistName: ""
        )
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "NFC-1")
        harness.model.toggleChecked(persistentId: "NFD-1")
        harness.model.startQueue()

        let rows = queueTableRows(for: harness.model)
        #expect(rows.count == 2)
        #expect(rows[0].id != rows[1].id, "canonical twins must not collapse to one row id")
    }
}

// MARK: - Wave A (A3): the steps table, structurally

@MainActor
@Suite("Offscreen structural view tests (Wave A steps table)", .serialized)
struct ApplyStageTableStructuralTests {

    private let stageSequence = [ApplyStage.loadingPlan] + ApplyPhase.allCases.map(ApplyStage.bridge)

    private func entries(started count: Int) -> [ApplyStageEntry] {
        stageSequence.prefix(count).enumerated().map { offset, stage in
            ApplyStageEntry(
                stage: stage,
                started: Date(timeIntervalSinceNow: Double(offset) * 5 - 60)
            )
        }
    }

    // 0 started: ALL 7 rows render up front as pending (the pre-A3 view
    // rendered zero rows here), no spinner, bounded.
    @Test("stage table with 0 started renders all 7 pending rows within bounds")
    func stageTableAllPending() throws {
        let fixture = HostedFixture(ApplyStageListView(stages: []), width: 1200, height: 800)
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)
        #expect(
            fixture.hosting.fittingSize.height >= 120,
            "fitting \(fixture.hosting.fittingSize.height) — pending rows not materialized"
        )
        #expect(liveSpinnerCount(under: fixture.hosting) == 0)
    }

    // 3 started: 2 frozen + 1 live + 4 pending — still all 7 rows.
    @Test("stage table with 3 started renders 2 done + 1 live + 4 pending within bounds")
    func stageTableThreeStarted() throws {
        let fixture = HostedFixture(
            ApplyStageListView(stages: entries(started: 3)), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)
        #expect(
            fixture.hosting.fittingSize.height >= 150,
            "fitting \(fixture.hosting.fittingSize.height)"
        )
        #expect(liveSpinnerCount(under: fixture.hosting) == 1)
    }

    // All 7 started (the maximal renderable state — success replaces the
    // list): 6 frozen + the final verifyingReadback row live.
    @Test("stage table with all 7 started renders 6 done + 1 live within bounds")
    func stageTableAllStarted() throws {
        let fixture = HostedFixture(
            ApplyStageListView(stages: entries(started: 7)), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 806)
        #expect(
            fixture.hosting.fittingSize.height >= 150,
            "fitting \(fixture.hosting.fittingSize.height)"
        )
        #expect(liveSpinnerCount(under: fixture.hosting) == 1)
    }
}
