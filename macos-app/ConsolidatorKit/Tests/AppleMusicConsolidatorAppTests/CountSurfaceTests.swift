// CountSurfaceTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Wave A (A5) — track counts on the confirm gate, plan review, and apply
// success surfaces. Unit tests pin the per-source count derivation
// (CompletedAudit.liveCopyCounts); structural tests pin that each surface
// fits the 1200x800 fixture window with the count text present and keeps its
// load-bearing controls inside the window box. Same offscreen harness
// discipline as StructuralViewTests: never-shown NSWindow, fixture-driven
// models, zero Music contact.

import AppKit
import SwiftUI
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

@MainActor
@Suite("Wave A — per-source counts (unit)")
struct LiveCopyCountsSurfaceTests {

    @Test("consolidate audit derives one single-source count")
    func consolidateCounts() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: [consolidateFixtureWire()])
        )
        defer { harness.cleanUp() }
        harness.model.startAudit()
        await harness.awaitAudit()
        let result = try #require(harness.model.result)
        #expect(result.liveCopyCounts == [4])
        #expect(result.outputCount == 3)
    }

    @Test("merge audit derives per-copy counts in plan copy order")
    func mergeCounts() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: [mergeFixtureWire()]),
            mode: .merge,
            playlistName: "Merge List"
        )
        defer { harness.cleanUp() }
        harness.model.startAudit()
        await harness.awaitAudit()
        let result = try #require(harness.model.result)
        // Wire order is C-HIGH then C-LOW; the plan sorts copies by
        // ascending playlist id, so counts are C-LOW's then C-HIGH's.
        #expect(result.liveCopyCounts == [2, 2])
        #expect(result.inputCount == 4)
        #expect(result.outputCount == 3)
    }
}

@MainActor
@Suite("Wave A — count surfaces (structural)", .serialized)
struct CountSurfaceStructuralTests {

    private let windowBox = NSRect(x: 0, y: 0, width: 1200, height: 800)

    @Test("confirm gate shows source and planned counts within bounds (merge)")
    func gateFitsWithCounts() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: [mergeFixtureWire()]),
            mode: .merge,
            playlistName: "Merge List"
        )
        defer { harness.cleanUp() }
        try await harness.auditAndSatisfyGate()
        #expect(harness.model.result?.liveCopyCounts == [2, 2])

        let fixture = HostedFixture(
            ConfirmGateView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(
            fixture.hosting.frame.height <= 806,
            "gate height \(fixture.hosting.frame.height)"
        )
        let apply = try #require(
            view(under: fixture.hosting, axIdentifier: M9ControlID.applyNow)
        )
        let applyFrame = apply.convert(apply.bounds, to: fixture.hosting)
        #expect(windowBox.contains(applyFrame), "apply control at \(applyFrame)")
    }

    @Test("plan review shows per-copy counts within bounds (merge)")
    func reviewFitsWithCounts() async throws {
        let harness = try ModelHarness(
            runner: ScriptedRunner(outputs: [mergeFixtureWire()]),
            mode: .merge,
            playlistName: "Merge List"
        )
        defer { harness.cleanUp() }
        harness.model.startAudit()
        await harness.awaitAudit()
        #expect(harness.model.result?.liveCopyCounts == [2, 2])

        let fixture = HostedFixture(
            PlanReviewView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(
            fixture.hosting.frame.height <= 806,
            "review height \(fixture.hosting.frame.height)"
        )
        let continueButton = try #require(
            view(under: fixture.hosting, axIdentifier: "m8.continueToGate")
        )
        let continueFrame = continueButton.convert(continueButton.bounds, to: fixture.hosting)
        #expect(windowBox.contains(continueFrame), "continue control at \(continueFrame)")
    }

    @Test("apply success shows the verified count within bounds")
    func successFitsWithCounts() async throws {
        let runner = ScriptedRunner(
            outputs: [consolidateFixtureWire()] + consolidateApplyOutputs()
        )
        let harness = try ModelHarness(runner: runner)
        defer { harness.cleanUp() }
        try await harness.auditAndSatisfyGate()
        harness.model.startApply()
        await harness.awaitApply()
        guard case .succeeded(let success) = harness.model.applyState else {
            Issue.record("expected success, got \(harness.model.applyState)")
            return
        }
        // The verified readback count trackCountText renders on screen 5.
        #expect(success.trackCount == 3)

        let fixture = HostedFixture(
            ApplyFlowView(model: harness.model), width: 1200, height: 800
        )
        defer { fixture.tearDown() }
        #expect(
            fixture.hosting.frame.height <= 806,
            "success height \(fixture.hosting.frame.height)"
        )
        let startOver = try #require(
            view(under: fixture.hosting, axIdentifier: M9ControlID.applyStartOver)
        )
        let startOverFrame = startOver.convert(startOver.bounds, to: fixture.hosting)
        #expect(windowBox.contains(startOverFrame), "start over at \(startOverFrame)")
    }
}
