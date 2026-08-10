// RangeToggleTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Wave A (spec A4) — the pure shift-click range toggle. No UI, no model,
// no Music: applyRangeToggle is a value-level function over row ids.

import Testing
@testable import AppleMusicConsolidatorApp

@Suite("Shift-click range toggle (A4)")
struct RangeToggleTests {

    private let ordered = ["r1", "r2", "r3", "r4", "r5"]

    @Test("nil anchor is a plain toggle and establishes the anchor")
    func nilAnchorPlainToggle() {
        let checked = applyRangeToggle(
            anchor: nil, clicked: "r3", orderedIDs: ordered, current: []
        )
        #expect(checked.selection == ["r3"])
        #expect(checked.newAnchor == "r3")

        let unchecked = applyRangeToggle(
            anchor: nil, clicked: "r3", orderedIDs: ordered, current: ["r3", "r5"]
        )
        #expect(unchecked.selection == ["r5"])
        #expect(unchecked.newAnchor == "r3")
    }

    @Test("forward range applies to every row from anchor to clicked, inclusive")
    func forwardRange() {
        let outcome = applyRangeToggle(
            anchor: "r2", clicked: "r4", orderedIDs: ordered, current: ["r2"]
        )
        #expect(outcome.selection == ["r2", "r3", "r4"])
        #expect(outcome.newAnchor == "r4")
    }

    @Test("backward range covers the same inclusive range")
    func backwardRange() {
        let outcome = applyRangeToggle(
            anchor: "r4", clicked: "r2", orderedIDs: ordered, current: ["r4"]
        )
        #expect(outcome.selection == ["r2", "r3", "r4"])
        #expect(outcome.newAnchor == "r2")
    }

    @Test("the range takes the clicked row's NEW state in both directions")
    func rangeTakesClickedNewState() {
        // Clicked r4 is currently checked -> newState is UNCHECK: the whole
        // range unchecks; r5 (outside the range) survives.
        let uncheck = applyRangeToggle(
            anchor: "r1", clicked: "r4", orderedIDs: ordered,
            current: ["r1", "r3", "r4", "r5"]
        )
        #expect(uncheck.selection == ["r5"])
        #expect(uncheck.newAnchor == "r4")

        // Clicked r4 is currently unchecked -> newState is CHECK: the whole
        // range checks, including rows that were already checked.
        let check = applyRangeToggle(
            anchor: "r1", clicked: "r4", orderedIDs: ordered, current: ["r2"]
        )
        #expect(check.selection == ["r1", "r2", "r3", "r4"])
        #expect(check.newAnchor == "r4")
    }

    @Test("an anchor missing from orderedIDs degrades to a plain toggle")
    func anchorMissingFromOrder() {
        let outcome = applyRangeToggle(
            anchor: "gone", clicked: "r2", orderedIDs: ordered, current: []
        )
        #expect(outcome.selection == ["r2"])
        #expect(outcome.newAnchor == "r2")
    }

    @Test("a clicked id missing from orderedIDs degrades to a plain toggle")
    func clickedMissingFromOrder() {
        let outcome = applyRangeToggle(
            anchor: "r1", clicked: "ghost", orderedIDs: ordered, current: ["r1"]
        )
        #expect(outcome.selection == ["r1", "ghost"])
        #expect(outcome.newAnchor == "ghost")
    }

    @Test("anchor equal to clicked toggles exactly that one row")
    func anchorEqualsClicked() {
        let outcome = applyRangeToggle(
            anchor: "r3", clicked: "r3", orderedIDs: ordered, current: []
        )
        #expect(outcome.selection == ["r3"])
        #expect(outcome.newAnchor == "r3")
    }

    @Test("the returned anchor is ALWAYS the clicked id")
    func newAnchorAlwaysClicked() {
        for (anchor, clicked) in [(nil, "r1"), ("r1", "r5"), ("r5", "r1"), ("zz", "r2")]
            as [(String?, String)] {
            let outcome = applyRangeToggle(
                anchor: anchor, clicked: clicked, orderedIDs: ordered, current: []
            )
            #expect(outcome.newAnchor == clicked)
        }
    }
}
