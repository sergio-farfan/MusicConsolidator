// ScriptGoldenTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// Golden gate for M4: the Swift MusicScriptBuilder output must match the
// Python reference implementation's generated script TEXT byte-for-byte, for every case
// exported by macos-app/golden/generate_script_golden.py. Plans are rebuilt
// on the Swift side with the Swift resolver from the same source snapshots;
// winner-index parity is already pinned by plan_golden.json (M2), so any
// divergence surfacing here is a script-generation defect with a diagnosable
// byte offset.

import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

@Suite("Script golden byte parity (reference is ground truth)")
struct ScriptGoldenTests {

    @Test("buildReadJXA matches the reference byte-for-byte for every golden case")
    func readJXAMatchesGolden() throws {
        let cases = try loadScriptGolden().readJxaCases
        #expect(!cases.isEmpty)
        for goldenCase in cases {
            let script = buildReadJXA(name: goldenCase.playlistName)
            expectByteEqual(script, goldenCase.script, context: "read_jxa/\(goldenCase.name)")
        }
    }

    @Test("buildApplyScript matches the reference byte-for-byte for every golden case")
    func applyScriptsMatchGolden() throws {
        let cases = try loadScriptGolden().applyCases
        #expect(!cases.isEmpty)
        #expect(cases.contains { $0.source.tracks.count == 1600 }, "the 1,600-track regression case must be present")
        for goldenCase in cases {
            let plan = try buildPlan(goldenCase.source)
            let script = try buildApplyScript(
                plan: plan,
                verifiedSource: goldenCase.source,
                targetName: goldenCase.targetName
            )
            expectByteEqual(script, goldenCase.script, context: "apply/\(goldenCase.name)")
        }
    }

    @Test("buildMergeApplyScript matches the reference byte-for-byte for every golden case")
    func mergeApplyScriptsMatchGolden() throws {
        let cases = try loadScriptGolden().mergeApplyCases
        #expect(!cases.isEmpty)
        #expect(cases.contains { $0.copies.count == 3 }, "the 3-copy synthetic case must be present")
        for goldenCase in cases {
            let plan = try buildMergePlan(name: goldenCase.mergedName, copies: goldenCase.copies)
            let script = try buildMergeApplyScript(
                plan: plan,
                verifiedCopies: goldenCase.copies,
                targetName: goldenCase.targetName
            )
            expectByteEqual(script, goldenCase.script, context: "merge_apply/\(goldenCase.name)")
        }
    }

    @Test("builders are pure functions: repeated builds are byte-identical")
    func buildersAreDeterministic() throws {
        let golden = try loadScriptGolden()

        let readName = golden.readJxaCases[0].playlistName
        expectByteEqual(
            buildReadJXA(name: readName),
            buildReadJXA(name: readName),
            context: "determinism/read_jxa"
        )

        let applyCase = golden.applyCases[0]
        let plan = try buildPlan(applyCase.source)
        let first = try buildApplyScript(
            plan: plan, verifiedSource: applyCase.source, targetName: applyCase.targetName
        )
        let second = try buildApplyScript(
            plan: plan, verifiedSource: applyCase.source, targetName: applyCase.targetName
        )
        expectByteEqual(first, second, context: "determinism/apply")

        let mergeCase = golden.mergeApplyCases[0]
        let mergePlan = try buildMergePlan(name: mergeCase.mergedName, copies: mergeCase.copies)
        let firstMerge = try buildMergeApplyScript(
            plan: mergePlan, verifiedCopies: mergeCase.copies, targetName: mergeCase.targetName
        )
        let secondMerge = try buildMergeApplyScript(
            plan: mergePlan, verifiedCopies: mergeCase.copies, targetName: mergeCase.targetName
        )
        expectByteEqual(firstMerge, secondMerge, context: "determinism/merge_apply")
    }
}
