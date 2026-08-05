// ApplyStructuralViewTests.swift
// M9 — offscreen structural tests for the rewired confirm gate (screen 3)
// and the new apply screens (4-6), extending the per-state matrix to:
// apply-in-flight, success, and failure (with a TALL mismatch fixture), each
// in normal + queue contexts. Same harness discipline as the M8 structural
// suite: NSHostingView into a NEVER-shown NSWindow, fixture-driven models,
// geometry containment (existence alone passed on off-canvas controls), and
// zero Music contact.

import AppKit
import SwiftUI
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

// MARK: - fixtures

/// A tall single-playlist snapshot: 30 duplicate pairs (bit-rate decisions).
/// Winners are the 30 odd (256 kbps) indexes.
private func tallApplyWire() -> String {
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

/// The tall plan's target readback in REVERSED winner order: 60+ verbatim
/// mismatch lines — the tall fixture for screen 6's mismatch rendering.
private func tallReversedTargetWire() -> String {
    var tracks: [String] = []
    for (offset, pair) in (0..<30).reversed().enumerated() {
        tracks.append(wireTrack(
            sourceIndex: offset, databaseId: 1000 + pair * 2 + 1,
            persistentId: String(format: "TALL%04d", pair * 2 + 1),
            title: "Tall Song \(pair)", bitRate: 256
        ))
    }
    return wireSnapshot(playlists: [
        wirePlaylist(
            id: 901, name: "Tall List \u{2014} Consolidated",
            persistentId: "TALL-T", tracks: tracks
        )
    ])
}

private func queueListingWire() -> String {
    let entries = [
        """
        {"id": 30, "name": "Fixture List", "persistent_id": "P-FIX", \
        "track_count": 4, "smart": false, "special_kind": "none"}
        """,
        """
        {"id": 40, "name": "Solo List", "persistent_id": "P-SOLO", \
        "track_count": 4, "smart": false, "special_kind": "none"}
        """,
    ]
    return "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

private let applyWindowBox = NSRect(x: 0, y: 0, width: 1280, height: 860)

@MainActor
private func expectContained(
    _ id: String,
    in fixture: HostedFixture<some View>,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    guard let control = view(under: fixture.hosting, axIdentifier: id) else {
        Issue.record("control \(id) is missing", sourceLocation: sourceLocation)
        return
    }
    let frame = control.convert(control.bounds, to: fixture.hosting)
    #expect(
        applyWindowBox.contains(frame),
        "\(id) at \(frame)",
        sourceLocation: sourceLocation
    )
}

/// Audit + satisfied gate over the given runner (consolidate, single item).
@MainActor
private func satisfiedGateHarness(
    runner: any ScriptRunner & Sendable,
    playlistName: String = "Fixture List"
) async throws -> ModelHarness {
    let harness = try ModelHarness(runner: runner, playlistName: playlistName)
    try await harness.auditAndSatisfyGate()
    return harness
}

/// Queue harness: scan + one-item queue audited + gate satisfied.
@MainActor
private func satisfiedQueueGateHarness(
    runner: any ScriptRunner & Sendable
) async throws -> ModelHarness {
    let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
    harness.model.rescanLibrary()
    await harness.model.scanTask?.value
    harness.model.toggleChecked(persistentId: "P-FIX")
    harness.model.startQueue()
    await harness.awaitAudit()
    harness.model.reviewedPlanToggle = true
    guard let target = harness.model.targetName else {
        throw AppTestError("queue item audit did not complete")
    }
    harness.model.typedTargetName = target
    return harness
}

// MARK: - the M9 structural suite

@MainActor
@Suite("Offscreen structural view tests (M9 apply screens)", .serialized)
struct ApplyStructuralViewTests {

    // Screen 3 rewired: the AppKit-backed Apply button appears once the
    // gate is satisfied, inside the window box, and the screen carries the
    // same pinned bottom action bar treatment as screen 2.
    @Test("confirm gate exposes the apply button and pinned actions within bounds")
    func gateExposesApplyButton() async throws {
        let runner = ScriptedRunner(outputs: [consolidateFixtureWire()])
        let harness = try await satisfiedGateHarness(runner: runner)
        defer { harness.cleanUp() }

        let fixture = HostedFixture(ConfirmGateView(model: harness.model))
        defer { fixture.tearDown() }

        #expect(fixture.hosting.frame.height <= 866)
        let apply = try #require(
            view(under: fixture.hosting, axIdentifier: M9ControlID.applyNow) as? NSButton
        )
        #expect(apply.isEnabled)
        expectContained(M9ControlID.applyNow, in: fixture)
        expectContained(M9ControlID.gateBackToReview, in: fixture)
        expectContained(M9ControlID.gateStartOver, in: fixture)
    }

    // The apply button really drives the model (click plumbing) and is
    // single-flight-disabled while the apply runs.
    @Test("clicking apply starts the apply exactly once")
    func applyClickPlumbing() async throws {
        let runner = StagedBlockingRunner(
            outputs: [consolidateFixtureWire()] + consolidateApplyOutputs(),
            blockAt: [1]
        )
        let harness = try await satisfiedGateHarness(runner: runner)
        defer { harness.cleanUp() }

        let fixture = HostedFixture(ConfirmGateView(model: harness.model))
        let apply = try #require(
            view(under: fixture.hosting, axIdentifier: M9ControlID.applyNow) as? NSButton
        )
        apply.performClick(nil)
        #expect(harness.model.isApplying)
        #expect(await pollUntil { runner.runCount == 2 })
        // A second click cannot double-dispatch.
        apply.performClick(nil)
        #expect(runner.runCount == 2)
        fixture.tearDown()

        runner.proceed.signal()
        await harness.awaitApply()
    }

    // Apply-in-flight, normal context: bounded, and NO cancel affordance is
    // offered anywhere on the screen (the guarded write is atomic from the
    // app's view).
    @Test("apply screen fits during the apply, with no cancel affordance")
    func applyInFlightFits() async throws {
        let runner = StagedBlockingRunner(
            outputs: [consolidateFixtureWire()] + consolidateApplyOutputs(),
            blockAt: [1]
        )
        let harness = try await satisfiedGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startApply()
        #expect(await pollUntil { runner.runCount == 2 })

        let fixture = HostedFixture(ApplyFlowView(model: harness.model))
        let height = fixture.hosting.frame.height
        let cancel = view(under: fixture.hosting, axIdentifier: M8ControlID.cancelAudit)
        fixture.tearDown()

        runner.proceed.signal()
        await harness.awaitApply()

        #expect(height <= 866, "apply-in-flight height \(height)")
        #expect(cancel == nil, "no cancel affordance may exist during an apply")
    }

    // Apply-in-flight, queue context.
    @Test("apply screen fits during a queue item's apply")
    func applyInFlightFitsInQueue() async throws {
        let runner = StagedBlockingRunner(
            outputs: [queueListingWire(), consolidateFixtureWire(name: "Fixture List")]
                + consolidateApplyOutputs(name: "Fixture List"),
            blockAt: [2]
        )
        let harness = try await satisfiedQueueGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startApply()
        #expect(await pollUntil { runner.runCount == 3 })

        let fixture = HostedFixture(ApplyFlowView(model: harness.model))
        let height = fixture.hosting.frame.height
        fixture.tearDown()

        runner.proceed.signal()
        await harness.awaitApply()
        #expect(height <= 866, "queue apply-in-flight height \(height)")
    }

    // Success, normal context: verification statement rendered, start-over
    // contained; the queue continue control does NOT exist.
    @Test("success screen fits; start over contained; no queue continue")
    func successFitsNormal() async throws {
        let runner = ScriptedRunner(outputs: [consolidateFixtureWire()] + consolidateApplyOutputs())
        let harness = try await satisfiedGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startApply()
        await harness.awaitApply()
        if case .succeeded = harness.model.applyState {} else {
            Issue.record("expected success, got \(harness.model.applyState)")
            return
        }

        let fixture = HostedFixture(ApplyFlowView(model: harness.model))
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 866)
        expectContained(M9ControlID.applyStartOver, in: fixture)
        #expect(view(under: fixture.hosting, axIdentifier: M9ControlID.applyContinue) == nil)
    }

    // Success, queue context: the continue control exists and is contained.
    @Test("success screen offers the queue continue control within bounds")
    func successFitsInQueue() async throws {
        let runner = ScriptedRunner(
            outputs: [queueListingWire(), consolidateFixtureWire(name: "Fixture List")]
                + consolidateApplyOutputs(name: "Fixture List")
        )
        let harness = try await satisfiedQueueGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startApply()
        await harness.awaitApply()
        #expect(harness.model.queue.map(\.status) == [.applied])

        let fixture = HostedFixture(ApplyFlowView(model: harness.model))
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 866)
        expectContained(M9ControlID.applyContinue, in: fixture)
    }

    // Failure with the TALL mismatch fixture (60+ verbatim lines), normal
    // context: the mismatch rendering must stay bounded and the
    // non-destructive actions must stay inside the window.
    @Test("failure screen fits with a tall mismatch fixture; actions contained")
    func failureFitsWithTallMismatches() async throws {
        let runner = ScriptedRunner(outputs: [
            tallApplyWire(),
            tallApplyWire(),
            emptySnapshotWire(),
            "",
            "",
            tallApplyWire(),
            tallReversedTargetWire(),
        ])
        let harness = try await satisfiedGateHarness(runner: runner, playlistName: "Tall List")
        defer { harness.cleanUp() }
        harness.model.startApply()
        await harness.awaitApply()
        guard case .failed(let failure) = harness.model.applyState else {
            Issue.record("expected a failed apply, got \(harness.model.applyState)")
            return
        }
        #expect(failure.failureClass == .verificationFailed)
        #expect(failure.mismatches.count >= 60)

        let fixture = HostedFixture(ApplyFlowView(model: harness.model))
        defer { fixture.tearDown() }
        #expect(
            fixture.hosting.frame.height <= 866,
            "tall-failure height \(fixture.hosting.frame.height)"
        )
        expectContained(M9ControlID.applyStartOver, in: fixture)
        expectContained(M9ControlID.applyBackToReview, in: fixture)
    }

    // Fix round 1, finding 1 (UI layer): the mode picker is disabled while
    // an apply is in flight — a mid-apply mode flip would orphan the
    // guarded write's outcome (model-refused too; this pins the affordance).
    @Test("the mode picker is disabled while an apply is in flight")
    func modePickerDisabledDuringApply() async throws {
        let runner = StagedBlockingRunner(
            outputs: [consolidateFixtureWire()] + consolidateApplyOutputs(),
            blockAt: [1]
        )
        let harness = try await satisfiedGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startApply()
        #expect(await pollUntil { runner.runCount == 2 })

        let fixture = HostedFixture(SourceSelectionView(model: harness.model))
        let segmented = views(under: fixture.hosting, classNameContains: "SegmentedControl")
            .compactMap { $0 as? NSControl }
            .first
        let isEnabled = segmented?.isEnabled
        fixture.tearDown()

        runner.proceed.signal()
        await harness.awaitApply()

        #expect(segmented != nil, "mode picker segmented control missing")
        #expect(isEnabled == false, "the mode picker must be disabled during an apply")
    }

    // Fix round 1, folded minor f: the tall-mismatch failure cell in QUEUE
    // context (the missing cell of the per-state matrix).
    @Test("queue failure screen fits with a tall mismatch fixture")
    func queueFailureFitsWithTallMismatches() async throws {
        let entries = [
            """
            {"id": 30, "name": "Tall List", "persistent_id": "P-TALL", \
            "track_count": 60, "smart": false, "special_kind": "none"}
            """
        ]
        let listing = "{\"playlists\": [\(entries.joined(separator: ", "))]}"
        let runner = ScriptedRunner(outputs: [
            listing,
            tallApplyWire(),
            tallApplyWire(),
            emptySnapshotWire(),
            "",
            "",
            tallApplyWire(),
            tallReversedTargetWire(),
        ])
        let harness = try ModelHarness(runner: runner, mode: .consolidate, playlistName: "")
        defer { harness.cleanUp() }
        harness.model.rescanLibrary()
        await harness.model.scanTask?.value
        harness.model.toggleChecked(persistentId: "P-TALL")
        harness.model.startQueue()
        await harness.awaitAudit()
        harness.model.reviewedPlanToggle = true
        harness.model.typedTargetName = try #require(harness.model.targetName)
        harness.model.startApply()
        await harness.awaitApply()
        guard case .failed(let failure) = harness.model.applyState else {
            Issue.record("expected a failed apply, got \(harness.model.applyState)")
            return
        }
        #expect(failure.mismatches.count >= 60)
        #expect(harness.model.queue.map(\.status) == [.failed])

        let fixture = HostedFixture(ApplyFlowView(model: harness.model))
        defer { fixture.tearDown() }
        #expect(
            fixture.hosting.frame.height <= 866,
            "queue tall-failure height \(fixture.hosting.frame.height)"
        )
        expectContained(M9ControlID.applyRetry, in: fixture)
        expectContained(M9ControlID.applySkip, in: fixture)
        expectContained(M9ControlID.applyStartOver, in: fixture)
    }

    // Failure, queue context: retry + skip contained.
    @Test("queue failure screen offers retry and skip within bounds")
    func failureFitsInQueue() async throws {
        let runner = ScriptedRunner(results: [
            .success(queueListingWire()),
            .success(consolidateFixtureWire(name: "Fixture List")),
            .failure(MusicCommandError("apply blew up")),
        ])
        let harness = try await satisfiedQueueGateHarness(runner: runner)
        defer { harness.cleanUp() }
        harness.model.startApply()
        await harness.awaitApply()
        #expect(harness.model.queue.map(\.status) == [.failed])

        let fixture = HostedFixture(ApplyFlowView(model: harness.model))
        defer { fixture.tearDown() }
        #expect(fixture.hosting.frame.height <= 866)
        expectContained(M9ControlID.applyRetry, in: fixture)
        expectContained(M9ControlID.applySkip, in: fixture)
    }
}
