// LaunchPreferencesTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// UI rework Part 2 — the four new Settings preferences (Appearance,
// Startup: reload-library-on-start and default-tab-on-launch, and
// Notifications: play-sound-on-run-finish): the pure `nsAppearance`
// mapping, persistence round-trips, the one-shot launch-effects wiring in
// `ConsolidatorFlowView`, and the finish-run sound hook. Same offscreen/
// hermetic discipline as the rest of this target: no live Music, no real
// UserDefaults, no real Application Support cache writes beyond the
// per-test temp directories `ModelHarness` already provides.

import AppKit
import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

/// A thread-safe call counter for the finish-run sound hook tests — the
/// hook closure must be `@Sendable`, so the captured reference type needs
/// its own thread-safety, mirroring `ScriptedRunner`'s lock discipline.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// A single-playlist listing wire matching `consolidateFixtureWire`'s
/// default name — the pairing `M11StructuralTests.swift`'s own fixtures use
/// (the listing scan and the audit read are two independent OSA calls with
/// two different wire shapes; only the NAME needs to line up).
private func launchPrefsListingWire() -> String {
    """
    {"playlists": [{"id": 10, "name": "Alpha List", "persistent_id": "P-A", \
    "track_count": 4, "smart": false, "special_kind": "none"}]}
    """
}

// MARK: - pure nsAppearance mapping

@Suite("nsAppearance(for:) mapping")
struct AppearanceMappingTests {
    @Test("system maps to nil (follow the OS)")
    func systemIsNil() {
        #expect(nsAppearance(for: .system) == nil)
    }

    @Test("light maps to NSAppearance(named: .aqua)")
    func lightIsAqua() {
        #expect(nsAppearance(for: .light)?.name == NSAppearance(named: .aqua)?.name)
    }

    @Test("dark maps to NSAppearance(named: .darkAqua)")
    func darkIsDarkAqua() {
        #expect(nsAppearance(for: .dark)?.name == NSAppearance(named: .darkAqua)?.name)
    }
}

// MARK: - persistence round-trips

@Suite("preference persistence round-trips")
@MainActor
struct PreferencePersistenceTests {
    @Test("appearanceMode persists across model instances sharing one defaults suite")
    func appearanceModePersists() {
        let defaults = InMemoryDefaults()
        let first = AuditFlowModel(makeRunner: { ScriptedRunner(outputs: []) }, defaults: defaults)
        #expect(first.appearanceMode == .system) // documented default
        first.setAppearanceMode(.dark)
        let second = AuditFlowModel(makeRunner: { ScriptedRunner(outputs: []) }, defaults: defaults)
        #expect(second.appearanceMode == .dark)
    }

    @Test("reloadLibraryOnStart persists across model instances sharing one defaults suite")
    func reloadLibraryOnStartPersists() {
        let defaults = InMemoryDefaults()
        let first = AuditFlowModel(makeRunner: { ScriptedRunner(outputs: []) }, defaults: defaults)
        #expect(first.reloadLibraryOnStart == false) // documented default
        first.setReloadLibraryOnStart(true)
        let second = AuditFlowModel(makeRunner: { ScriptedRunner(outputs: []) }, defaults: defaults)
        #expect(second.reloadLibraryOnStart == true)
    }

    @Test("defaultBrowserTabOnLaunch persists across model instances sharing one defaults suite")
    func defaultBrowserTabOnLaunchPersists() {
        let defaults = InMemoryDefaults()
        let first = AuditFlowModel(makeRunner: { ScriptedRunner(outputs: []) }, defaults: defaults)
        #expect(first.defaultBrowserTabOnLaunch == .merge) // documented default
        first.setDefaultBrowserTabOnLaunch(.cleanup)
        let second = AuditFlowModel(makeRunner: { ScriptedRunner(outputs: []) }, defaults: defaults)
        #expect(second.defaultBrowserTabOnLaunch == .cleanup)
    }

    @Test("playSoundOnRunFinish persists across model instances sharing one defaults suite")
    func playSoundOnRunFinishPersists() {
        let defaults = InMemoryDefaults()
        let first = AuditFlowModel(makeRunner: { ScriptedRunner(outputs: []) }, defaults: defaults)
        #expect(first.playSoundOnRunFinish == false) // documented default
        first.setPlaySoundOnRunFinish(true)
        let second = AuditFlowModel(makeRunner: { ScriptedRunner(outputs: []) }, defaults: defaults)
        #expect(second.playSoundOnRunFinish == true)
    }
}

// MARK: - one-shot launch effects (ConsolidatorFlowView)

@MainActor
@Suite("one-shot launch effects", .serialized)
struct LaunchEffectsTests {
    @Test("reloadLibraryOnStart triggers exactly one rescan at launch")
    func reloadLibraryOnStartTriggersRescan() async throws {
        let runner = ScriptedRunner(outputs: [launchPrefsListingWire()])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.setReloadLibraryOnStart(true)

        let fixture = HostedFixture(ConsolidatorFlowView(model: harness.model))
        defer { fixture.tearDown() }
        fixture.pump()
        #expect(await pollUntil { harness.model.loadedListing != nil })
        #expect(runner.commands.count == 1)
    }

    @Test("reloadLibraryOnStart off (default) never triggers a launch rescan")
    func reloadLibraryOnStartOffDoesNotRescan() async throws {
        let runner = ScriptedRunner(outputs: [])
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        // default is false — no explicit set.

        let fixture = HostedFixture(ConsolidatorFlowView(model: harness.model))
        defer { fixture.tearDown() }
        fixture.pump()
        #expect(harness.model.scanTask == nil)
        #expect(runner.commands.isEmpty)
    }

    @Test("defaultBrowserTabOnLaunch applies to the live browser tab exactly once, at launch")
    func defaultBrowserTabOnLaunchApplies() async throws {
        let harness = try ModelHarness(runner: ScriptedRunner(outputs: []))
        defer { harness.cleanUp() }
        harness.model.setDefaultBrowserTabOnLaunch(.cleanup)

        let fixture = HostedFixture(ConsolidatorFlowView(model: harness.model))
        defer { fixture.tearDown() }
        fixture.pump()
        #expect(harness.model.browserTab == .cleanup)
    }
}

// MARK: - finish-run sound hook

@MainActor
@Suite("play sound on run finish", .serialized)
struct PlaySoundOnRunFinishTests {
    @Test("fires exactly once when the preference is on and a run finishes")
    func firesWhenOn() async throws {
        let runner = ScriptedRunner(results:
            [.success(launchPrefsListingWire()), .success(consolidateFixtureWire(name: "Alpha List"))]
                + consolidateApplyOutputs(name: "Alpha List").map { .success($0) }
        )
        let counter = CallCounter()
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false,
            playFinishSound: { counter.increment() }
        )
        defer { harness.cleanUp() }
        harness.model.setPlaySoundOnRunFinish(true)
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-A")
        harness.model.startQueue()
        #expect(await pollUntil { harness.model.finishedRunReport != nil })
        #expect(counter.count == 1)
    }

    @Test("never fires when the preference is off (default)")
    func doesNotFireWhenOff() async throws {
        let runner = ScriptedRunner(results:
            [.success(launchPrefsListingWire()), .success(consolidateFixtureWire(name: "Alpha List"))]
                + consolidateApplyOutputs(name: "Alpha List").map { .success($0) }
        )
        let counter = CallCounter()
        let harness = try ModelHarness(
            runner: runner, mode: .consolidate, playlistName: "", confirmEachApply: false,
            playFinishSound: { counter.increment() }
        )
        defer { harness.cleanUp() }
        // default off — no explicit set.
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-A")
        harness.model.startQueue()
        #expect(await pollUntil { harness.model.finishedRunReport != nil })
        #expect(counter.count == 0)
    }
}
