// FreeFormMergeFlowTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// 2026-08-06 free-form merge design, Task 2 — model + UI: the merge tab's
// "Merge selected as one…" footer action resolves the CURRENT selection
// (checked groups' copies + checked singletons) into one ascending-
// playlist-ID-ordered source list, computes the automatic target name and
// description, and enqueues ONE queue item that runs the standard audit ->
// plan -> (confirm gate) -> guarded apply pipeline — identical to a
// same-name queue item except the plan variant (engine: Task 1,
// `buildFreeFormMergePlan`/`applyFreeFormMergePlan`). Everything here rides
// scripted ScriptRunner fakes; nothing executes any script or contacts
// Music. The same-name flows (`startQueue`, `toggleCheckedGroup`, etc.) are
// untouched — their own suites keep covering them unmodified.

import AppKit
import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

// MARK: - fixtures

private func ffListingEntry(id: Int, name: String, pid: String, count: Int) -> String {
    """
    {"id": \(id), "name": "\(jsonEscaped(name))", "persistent_id": "\(jsonEscaped(pid))", \
    "track_count": \(count), "smart": false, "special_kind": "none"}
    """
}

private func ffListingWire(_ entries: [String]) -> String {
    "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

/// One group ("Trance 2022", 2 copies, ids 10/20) plus one singleton ("Solo
/// List", id 5 — the LOWEST id). `sections.groups`/`sections.singletons`
/// are each alphabetically ordered on their own (never by playlist id), so
/// this fixture proves the combined free-form selection is re-sorted by
/// ascending playlist id rather than inheriting either section's own order:
/// Solo List(5) must sort BEFORE both group copies.
private func mixedSelectionListingWire() -> String {
    ffListingWire([
        ffListingEntry(id: 10, name: "Trance 2022", pid: "T-LOW", count: 3),
        ffListingEntry(id: 20, name: "Trance 2022", pid: "T-HIGH", count: 4),
        ffListingEntry(id: 5, name: "Solo List", pid: "S-SOLO", count: 2),
    ])
}

private func mixedSelectionAuditWire() -> String {
    wireSnapshot(playlists: [
        wirePlaylist(id: 5, name: "Solo List", persistentId: "S-SOLO", tracks: [
            wireTrack(sourceIndex: 0, databaseId: 1, persistentId: "TRK-SOLO", title: "Solo Song"),
        ]),
        wirePlaylist(id: 10, name: "Trance 2022", persistentId: "T-LOW", tracks: [
            wireTrack(sourceIndex: 0, databaseId: 2, persistentId: "TRK-LOW", title: "Low Song"),
        ]),
        wirePlaylist(id: 20, name: "Trance 2022", persistentId: "T-HIGH", tracks: [
            wireTrack(sourceIndex: 0, databaseId: 3, persistentId: "TRK-HIGH", title: "High Song"),
        ]),
    ])
}

/// Two unrelated singletons — the Task 3 verification-checklist scenario
/// ("select two unrelated singletons -> Merge selected as one").
private func twoSingletonsListingWire() -> String {
    ffListingWire([
        ffListingEntry(id: 1, name: "Alpha", pid: "FF-A", count: 1),
        ffListingEntry(id: 2, name: "Beta", pid: "FF-B", count: 1),
    ])
}

private func twoSingletonsAuditWire() -> String {
    wireSnapshot(playlists: [
        wirePlaylist(id: 1, name: "Alpha", persistentId: "FF-A", tracks: [
            wireTrack(sourceIndex: 0, databaseId: 1, persistentId: "TRK-A", title: "Song A"),
        ]),
        wirePlaylist(id: 2, name: "Beta", persistentId: "FF-B", tracks: [
            wireTrack(sourceIndex: 0, databaseId: 2, persistentId: "TRK-B", title: "Song B"),
        ]),
    ])
}

/// The two-singleton audit's plan has no duplicates, so both tracks survive
/// unchanged, in combined (Alpha then Beta) order.
private func twoSingletonsTargetReadbackWire() -> String {
    wireSnapshot(playlists: [
        wirePlaylist(id: 900, name: "Alpha \u{2014} Merged", persistentId: "TARGET-FF", tracks: [
            wireTrack(sourceIndex: 0, databaseId: 1, persistentId: "TRK-A", title: "Song A"),
            wireTrack(sourceIndex: 1, databaseId: 2, persistentId: "TRK-B", title: "Song B"),
        ]),
    ])
}

// MARK: - model tests

@MainActor
@Suite("Free-form merge — model (2026-08-06 design)")
struct FreeFormMergeFlowTests {

    @Test(
        "resolves a mixed group+singleton selection into ascending-playlist-id order and names the target from the FIRST source"
    )
    func orderingAndNaming() async throws {
        let runner = ScriptedRunner(outputs: [mixedSelectionListingWire(), mixedSelectionAuditWire()])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value

        harness.model.toggleCheckedGroup(name: "Trance 2022")
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "S-SOLO")
        #expect(harness.model.freeFormMergeSelection.map(\.persistentId) == ["S-SOLO", "T-LOW", "T-HIGH"])

        harness.model.startFreeFormMerge()
        #expect(harness.model.queue.map(\.name) == ["Solo List \u{2014} Merged"])
        #expect(harness.model.queue.first?.copyCounts == [2, 3, 4])

        await harness.awaitAudit()
        guard case .merge(let mergePlan) = try #require(harness.model.result).plan else {
            Issue.record("expected a merge plan")
            return
        }
        #expect(mergePlan.isFreeForm)
        #expect(mergePlan.mergedPlaylistSourceName == "Solo List \u{2014} Merged")
        #expect(mergePlan.sourcePersistentIDs == ["S-SOLO", "T-LOW", "T-HIGH"])
        #expect(mergePlan.sourceNames == ["Solo List", "Trance 2022", "Trance 2022"])
        // The confirm-gate target name must be the plan's OWN computed name
        // verbatim — never `defaultTargetName` double-suffixing it.
        #expect(harness.model.targetName == "Solo List \u{2014} Merged")
    }

    @Test("the plan's description is built from the model's injected now() seam")
    func descriptionUsesInjectedClock() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let fixedDate = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 11, hour: 9, minute: 30)
        )!
        let runner = ScriptedRunner(outputs: [mixedSelectionListingWire(), mixedSelectionAuditWire()])
        let harness = try ModelHarness(
            runner: runner, mode: .merge, playlistName: "", now: { fixedDate }
        )
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleCheckedGroup(name: "Trance 2022")
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "S-SOLO")

        harness.model.startFreeFormMerge()
        await harness.awaitAudit()

        guard case .merge(let mergePlan) = try #require(harness.model.result).plan else {
            Issue.record("expected a merge plan")
            return
        }
        // Wiring proof: the model's own now() seam value, formatted the SAME
        // way the pure helper formats it. The helper's exact string format
        // is pinned independently (with a fixed zone) below.
        let expected = freeFormMergeDescription(
            sourceNames: ["Solo List", "Trance 2022", "Trance 2022"], now: fixedDate
        )
        #expect(mergePlan.targetDescription == expected)
    }

    @Test("freeFormMergeDescription formats a pinned exact string against a fixed clock and zone")
    func descriptionExactStringPinned() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let fixedDate = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 11, hour: 9, minute: 30)
        )!
        let text = freeFormMergeDescription(
            sourceNames: ["Solo List", "Trance 2022", "Trance 2022"],
            now: fixedDate,
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(text == "Merged on 2026-08-11 09:30 from: Solo List, Trance 2022, Trance 2022")
    }

    @Test("below the 2-source threshold, startFreeFormMerge is a no-op")
    func belowThresholdIsNoOp() async throws {
        let runner = ScriptedRunner(outputs: [twoSingletonsListingWire()])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value

        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-A")
        #expect(harness.model.freeFormMergeSelection.count == 1)

        harness.model.startFreeFormMerge()
        #expect(!harness.model.isQueueActive)
        #expect(harness.model.queue.isEmpty)
    }

    @Test("two checked singletons meet the threshold and build a one-item free-form queue")
    func twoSingletonsMeetThreshold() async throws {
        let runner = ScriptedRunner(outputs: [twoSingletonsListingWire(), twoSingletonsAuditWire()])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value

        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-A")
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-B")
        harness.model.startFreeFormMerge()
        #expect(harness.model.isQueueActive)
        #expect(harness.model.queue.map(\.name) == ["Alpha \u{2014} Merged"])

        await harness.awaitAudit()
        #expect(harness.model.queue.map(\.status) == [.audited])
    }

    // 2026-08-06 final review, finding M6: a pinned PID that vanished from
    // Music between selection and the free-form read (deleted, say) is
    // live-library drift, not an artifact write failure — it must classify
    // "Library state" like every other live-drift refusal (mirrors
    // `FailureRenderingTests.missingPlaylist` in AuditFlowModelTests.swift).
    @Test("a vanished pinned persistent ID during the free-form read is a library-state failure")
    func vanishedPinnedPersistentIdIsLibraryStateFailure() async throws {
        let runner = ScriptedRunner(outputs: [
            twoSingletonsListingWire(),
            // FF-B vanished from Music between selection and this read.
            wireSnapshot(playlists: [
                wirePlaylist(id: 1, name: "Alpha", persistentId: "FF-A", tracks: [
                    wireTrack(sourceIndex: 0, databaseId: 1, persistentId: "TRK-A", title: "Song A"),
                ]),
            ]),
        ])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-A")
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-B")
        harness.model.startFreeFormMerge()
        await harness.awaitAudit()

        guard case .failed(let failure) = harness.model.runState else {
            Issue.record("expected a failed run state, got \(harness.model.runState)")
            return
        }
        #expect(failure.category == "Library state")
        #expect(failure.message == "a selected playlist is no longer in Music; rescan and try again")
    }

    @Test("an existing live playlist named like the computed target pre-skips, like the same-name courtesy pre-skip")
    func existingTargetPreSkips() async throws {
        let runner = ScriptedRunner(outputs: [
            ffListingWire([
                ffListingEntry(id: 1, name: "Alpha", pid: "FF-A", count: 1),
                ffListingEntry(id: 2, name: "Beta", pid: "FF-B", count: 1),
                ffListingEntry(id: 3, name: "Alpha \u{2014} Merged", pid: "EXISTING", count: 5),
            ])
        ])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value

        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-A")
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-B")
        harness.model.startFreeFormMerge()

        #expect(harness.model.queue.map(\.status) == [.skipped])
        // Courtesy pre-skip only: no audit read was ever dispatched for it.
        #expect(runner.remainingOutputs == 0)
        let report = try #require(harness.model.finishedRunReport)
        #expect(report.items.map(\.outcome) == [.skipped])
        #expect(report.items.first?.note?.contains("already done") == true)
        #expect(report.items.first?.note?.contains("Alpha \u{2014} Merged") == true)
    }

    @Test("a completed free-form audit writes the full plan/detail/summary artifact triple")
    func artifactTripleWritten() async throws {
        let runner = ScriptedRunner(outputs: [twoSingletonsListingWire(), twoSingletonsAuditWire()])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-A")
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-B")
        harness.model.startFreeFormMerge()
        await harness.awaitAudit()

        let paths = try #require(harness.model.result).paths
        for path in [paths.planJson, paths.detailCsv, paths.summaryMarkdown] {
            #expect(FileManager.default.fileExists(atPath: path), "missing \(path)")
        }
    }

    @Test(
        "apply routes through applyFreeFormMergePlan: PID-pinned reread before AND after write, name-based target checks"
    )
    func applyRoutesThroughFreeFormPath() async throws {
        let runner = ScriptedRunner(outputs: [
            twoSingletonsListingWire(),
            twoSingletonsAuditWire(),
            twoSingletonsAuditWire(), // ensureFreeFormCopiesMatch re-read (by PID)
            emptySnapshotWire(), // assertTargetAbsent (by name)
            "", // compile
            "", // execute
            twoSingletonsAuditWire(), // post-write source reread (by PID)
            twoSingletonsTargetReadbackWire(), // target readback (by name)
        ])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-A")
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-B")
        harness.model.startFreeFormMerge()
        await harness.awaitAudit()

        harness.model.reviewedPlanToggle = true
        harness.model.typedTargetName = try #require(harness.model.targetName)
        #expect(harness.model.canApply)
        harness.model.startApply()
        await harness.awaitApply()

        guard case .succeeded(let success) = harness.model.applyState else {
            Issue.record("expected a successful apply, got \(harness.model.applyState)")
            return
        }
        #expect(success.targetName == "Alpha \u{2014} Merged")
        #expect(success.trackCount == 2)

        // PID-pinned reads before AND after the write (proves
        // `applyFreeFormMergePlan`/`ensureFreeFormCopiesMatch` ran, not the
        // same-name `applyMergePlan`/`ensureAllCopiesMatch` path, which would
        // dispatch a by-NAME read for "Alpha — Merged" here instead and fail
        // the copy-count check against an empty live result).
        let commands = runner.commands
        #expect(commands.count == 8)
        let byPidScript = buildReadByPersistentIdsJXA(persistentIds: ["FF-A", "FF-B"])
        #expect(commands[1] == .readJXA(script: byPidScript))
        #expect(commands[2] == .readJXA(script: byPidScript))
        #expect(commands[3] == .readJXA(script: buildReadJXA(name: "Alpha \u{2014} Merged")))
        #expect(commands[6] == .readJXA(script: byPidScript))
        #expect(commands[7] == .readJXA(script: buildReadJXA(name: "Alpha \u{2014} Merged")))
    }

    /// Task 2 review finding F1: the double-suffix fix has TWO call sites —
    /// `targetName` (the confirm gate / apply screen, pinned by
    /// `orderingAndNaming` above) and `recordRunItem`'s `itemTargetName` (the
    /// run record and the persisted run-report artifact). This pins the
    /// second one through a real applied free-form apply: the record must
    /// carry the plan's computed name verbatim, never `"… — Merged — Merged"`.
    @Test("an applied free-form item records the computed target name, not a doubled suffix")
    func runRecordTargetNameIsNotDoubled() async throws {
        let runner = ScriptedRunner(outputs: [
            twoSingletonsListingWire(),
            twoSingletonsAuditWire(),
            twoSingletonsAuditWire(), // ensureFreeFormCopiesMatch re-read (by PID)
            emptySnapshotWire(), // assertTargetAbsent (by name)
            "", // compile
            "", // execute
            twoSingletonsAuditWire(), // post-write source reread (by PID)
            twoSingletonsTargetReadbackWire(), // target readback (by name)
        ])
        // Unattended: the run applies itself and finishes, producing the run
        // report whose item carries the target name.
        let harness = try ModelHarness(
            runner: runner, mode: .merge, playlistName: "", confirmEachApply: false
        )
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-A")
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-B")
        harness.model.startFreeFormMerge()
        #expect(await pollUntil { harness.model.finishedRunReport != nil })

        let report = try #require(harness.model.finishedRunReport)
        let item = try #require(report.items.first)
        #expect(item.outcome.label == "applied")
        #expect(item.targetName == "Alpha \u{2014} Merged")
        #expect(item.targetName != "Alpha \u{2014} Merged \u{2014} Merged")
        // 2026-08-06 final review, finding M5: the record's source names
        // are wired straight from the item's FreeFormMergeSpec, so the
        // persisted run report can render the "- Sources: A, B" line.
        #expect(item.freeFormSourceNames == ["Alpha", "Beta"])
        #expect(renderRunReportText(report).contains("- Sources: Alpha, Beta"))
    }

    /// Task 2 review finding F3: the merge footer's "Queued: N playlists"
    /// counted checked GROUPS only, so a free-form singleton pick was
    /// invisible there even while it enabled "Merge selected as one…".
    @Test("the merge footer count includes checked free-form singletons, not just groups")
    func footerCountIncludesSingletons() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: [mixedSelectionListingWire()]),
            mode: .merge, playlistName: ""
        )
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        #expect(harness.model.mergeCheckedCount == 0)

        harness.model.toggleCheckedFreeFormSingleton(persistentId: "S-SOLO")
        #expect(harness.model.mergeCheckedCount == 1)

        harness.model.toggleCheckedGroup(name: "Trance 2022")
        #expect(harness.model.mergeCheckedCount == 2)

        harness.model.clearSelection()
        #expect(harness.model.mergeCheckedCount == 0)
    }
}

// MARK: - footer structural tests

@MainActor
private func freeFormFooterHarness() async throws -> ModelHarness {
    let harness = try ModelHarness(
        runner: ScriptedRunner(outputs: [twoSingletonsListingWire()]),
        mode: .merge, playlistName: ""
    )
    harness.model.rescanLibrary()
    await harness.model.scanTask?.value
    return harness
}

@MainActor
@Suite("Free-form merge — footer structural pins (2026-08-06 design)", .serialized)
struct FreeFormMergeFooterStructuralTests {

    @Test("disabled below the 2-source threshold")
    func disabledBelowThreshold() async throws {
        let harness = try await freeFormFooterHarness()
        defer { harness.cleanUp() }
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-A")
        let fixture = HostedFixture(
            SourceSelectionView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }

        let button = try #require(
            view(under: fixture.hosting, axIdentifier: M10ControlID.mergeAsOne) as? NSButton
        )
        #expect(!button.isEnabled)
    }

    @Test("enabled at exactly 2 checked sources and drives the model")
    func enabledAtThresholdDrivesModel() async throws {
        let harness = try await freeFormFooterHarness()
        defer { harness.cleanUp() }
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-A")
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-B")
        let fixture = HostedFixture(
            SourceSelectionView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }

        let button = try #require(
            view(under: fixture.hosting, axIdentifier: M10ControlID.mergeAsOne) as? NSButton
        )
        #expect(button.isEnabled)
        button.performClick(nil)
        #expect(harness.model.isQueueActive)
        #expect(harness.model.queue.map(\.name) == ["Alpha \u{2014} Merged"])
    }

    @Test("still enabled when the selection is a single checked group (>= 2 copies)")
    func enabledForGroupOnlySelection() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: [mixedSelectionListingWire()]),
            mode: .merge, playlistName: ""
        )
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleCheckedGroup(name: "Trance 2022")

        let fixture = HostedFixture(
            SourceSelectionView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        let button = try #require(
            view(under: fixture.hosting, axIdentifier: M10ControlID.mergeAsOne) as? NSButton
        )
        #expect(button.isEnabled)
    }
}

// MARK: - SINGLETONS row structural tests (Task 2 review finding F5)
//
// The merge tab's singleton checkbox is the ONLY way to reach the live
// free-form flow Task 3's verification checklist describes ("select two
// unrelated singletons -> Merge selected as one"), and Task 2 flipped it from
// permanently-disabled-with-a-"nothing to merge"-tooltip to a live control.
// Nothing structural covered that flip, so a regression back to
// `.disabled(true)` would have left the model tests green and the feature
// unreachable. `MergeBrowserList` is hosted directly with the SINGLETONS
// disclosure seeded open: SwiftUI never materializes a COLLAPSED
// DisclosureGroup's content, and the app's own default stays collapsed.

@MainActor
@Suite("Free-form merge — SINGLETONS row checkbox structural pins (F5)", .serialized)
struct FreeFormSingletonRowStructuralTests {

    @Test("the singleton row's checkbox exists, is enabled, and drives toggleCheckedFreeFormSingleton")
    func singletonCheckboxIsLiveAndDrivesTheModel() async throws {
        let harness = try await freeFormFooterHarness()
        defer { harness.cleanUp() }
        let sections = try #require(harness.model.loadedSections)
        let fixture = HostedFixture(
            MergeBrowserList(model: harness.model, sections: sections, singletonsShown: true),
            width: 1200, height: 800
        )
        defer { fixture.tearDown() }

        let checkbox = try #require(
            view(under: fixture.hosting, axIdentifier: M10ControlID.singletonCheckbox("FF-A"))
                as? NSButton
        )
        // Enabled — NOT the disabled "blocked row" treatment near matches get.
        #expect(checkbox.isEnabled)
        #expect(checkbox.state == .off)

        checkbox.performClick(nil)
        #expect(harness.model.isFreeFormSingletonChecked(persistentId: "FF-A"))
        #expect(harness.model.checkedFreeFormSingletonPersistentIds == ["FF-A"])
        fixture.pump()
        #expect(checkbox.state == .on)

        checkbox.performClick(nil)
        #expect(!harness.model.isFreeFormSingletonChecked(persistentId: "FF-A"))
        #expect(harness.model.checkedFreeFormSingletonPersistentIds.isEmpty)
    }

    @Test("the singleton row's checkbox is disabled while a queue is active")
    func singletonCheckboxDisabledWhileQueueActive() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: [
                twoSingletonsListingWire(), twoSingletonsAuditWire(),
            ]),
            mode: .merge, playlistName: ""
        )
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-A")
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-B")
        harness.model.startFreeFormMerge()
        await harness.awaitAudit()
        #expect(harness.model.isQueueActive)

        let sections = try #require(harness.model.loadedSections)
        let fixture = HostedFixture(
            MergeBrowserList(model: harness.model, sections: sections, singletonsShown: true),
            width: 1200, height: 800
        )
        defer { fixture.tearDown() }

        let checkbox = try #require(
            view(under: fixture.hosting, axIdentifier: M10ControlID.singletonCheckbox("FF-A"))
                as? NSButton
        )
        #expect(!checkbox.isEnabled)
    }
}

// MARK: - plan review header structural tests (2026-08-06 final review, I2)
//
// The plan review screen (screen 2) is what Sergio reads before approving a
// write, so for a free-form plan it has to name every source beside its PID
// (mirroring the summary artifact's shape) and show the exact description
// text the guarded writer will set — same-name rendering stays untouched.

@MainActor
@Suite("Free-form merge — plan review header structural pins (I2)", .serialized)
struct FreeFormMergeReviewStructuralTests {

    @Test("names each copy beside its PID and shows the target description, free-form only")
    func namesCopiesAndShowsDescription() async throws {
        let runner = ScriptedRunner(outputs: [twoSingletonsListingWire(), twoSingletonsAuditWire()])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-A")
        harness.model.toggleCheckedFreeFormSingleton(persistentId: "FF-B")
        harness.model.startFreeFormMerge()
        await harness.awaitAudit()
        guard case .merge(let mergePlan) = try #require(harness.model.result).plan else {
            Issue.record("expected a merge plan")
            return
        }
        #expect(mergePlan.isFreeForm)

        let fixture = HostedFixture(PlanReviewView(model: harness.model))
        defer { fixture.tearDown() }

        let copy0Name = try #require(
            view(under: fixture.hosting, axIdentifier: M8ControlID.freeFormCopyName(0)) as? NSTextField
        )
        #expect(copy0Name.stringValue == "\u{201C}Alpha\u{201D}")
        let copy1Name = try #require(
            view(under: fixture.hosting, axIdentifier: M8ControlID.freeFormCopyName(1)) as? NSTextField
        )
        #expect(copy1Name.stringValue == "\u{201C}Beta\u{201D}")

        let description = try #require(
            view(under: fixture.hosting, axIdentifier: M8ControlID.freeFormTargetDescription)
                as? NSTextField
        )
        #expect(description.stringValue == mergePlan.targetDescription)
    }

    @Test("a same-name plan's review header renders no free-form rows")
    func sameNamePlanOmitsFreeFormRows() async throws {
        let runner = ScriptedRunner(outputs: [mergeFixtureWire()])
        let harness = try ModelHarness(runner: runner, mode: .merge, playlistName: "Merge List")
        defer { harness.cleanUp() }
        harness.model.startAudit()
        await harness.awaitAudit()
        guard case .merge(let mergePlan) = try #require(harness.model.result).plan else {
            Issue.record("expected a merge plan")
            return
        }
        #expect(!mergePlan.isFreeForm)

        let fixture = HostedFixture(PlanReviewView(model: harness.model))
        defer { fixture.tearDown() }

        #expect(view(under: fixture.hosting, axIdentifier: M8ControlID.freeFormCopyName(0)) == nil)
        #expect(
            view(under: fixture.hosting, axIdentifier: M8ControlID.freeFormTargetDescription) == nil
        )
    }
}
