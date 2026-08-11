// FreeFormMergeEngineTests.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// New coverage for the free-form merge engine's MusicBridge half (2026-08-06
// free-form design, Task 1 — Swift-native, no Python counterpart, no CLI
// surface): the CRITICAL same-name byte-identity pin, the free-form writer's
// script text (PID-set lookup, description set + in-script readback,
// hostile-description escaping), `ensureFreeFormCopiesMatch`'s revalidation
// (missing/renamed/drifted, all pinned by PID rather than name), and
// `applyFreeFormMergePlan`'s orchestration. The engine/model half (MergePlan,
// buildFreeFormMergePlan, validateMergePlanIntegrity) is covered separately
// in Tests/ConsolidatorCoreTests/FreeFormMergeEngineTests.swift.

import Foundation
import Testing
import ConsolidatorCore
@testable import MusicBridge

private func freeFormCopies() -> [PlaylistSnapshot] {
    [
        PlaylistSnapshot(
            name: "DJ Set A",
            persistentId: "PID-A",
            tracks: [
                track(
                    sourceIndex: 0, databaseId: 1, persistentId: "LOSSY",
                    title: "One", durationMs: 180001, sampleRateHz: 44100
                ),
                track(
                    sourceIndex: 1, databaseId: 2, persistentId: "UNIQUE-A",
                    title: "Two", durationMs: 200002
                ),
            ]
        ),
        PlaylistSnapshot(
            name: "DJ Set B",
            persistentId: "PID-B",
            tracks: [
                track(
                    sourceIndex: 0, databaseId: 3, persistentId: "LOSSLESS",
                    title: "One", durationMs: 180001, kind: "AIFF audio file",
                    sampleRateHz: 96000
                ),
            ]
        ),
    ]
}

private let freeFormSourceNames = ["DJ Set A", "DJ Set B"]
private let freeFormTargetName = "DJ Set A — Merged"
private let freeFormDescription = "Merged on 2026-08-06 12:00 from: DJ Set A, DJ Set B"

private func freeFormPlan() throws -> MergePlan {
    try buildFreeFormMergePlan(
        copies: freeFormCopies(),
        targetName: freeFormTargetName,
        targetDescription: freeFormDescription,
        sourceNames: freeFormSourceNames
    )
}

/// A wire-JSON `buildReadByPersistentIdsJXA`/`buildReadJXA`-shaped snapshot
/// for one playlist, used to script `FakeRunner` responses without
/// executing anything.
private func wirePlaylistJSON(_ snapshot: PlaylistSnapshot, id: Int) -> String {
    let tracks = snapshot.tracks.map { track -> String in
        // The wire "duration" field is SECONDS (Music's `duration` property);
        // Swift converts to milliseconds downstream — see
        // ApplyProgressSeamTests.swift's `seamWireTrack` for the same
        // convention this mirrors.
        let duration = track.durationMs.map { String(Double($0) / 1000.0) } ?? "null"
        return """
        {"source_index": \(track.sourceIndex), "database_id": \(track.databaseId), \
        "persistent_id": \(jsonString(track.persistentId)), "title": \(jsonString(track.title)), \
        "artist": \(jsonString(track.artist)), "album": \(jsonString(track.album)), \
        "duration": \(duration), "kind": \(jsonString(track.kind)), \
        "bit_rate": \(track.bitRateKbps.map(String.init) ?? "null"), \
        "sample_rate": \(track.sampleRateHz.map(String.init) ?? "null"), \
        "cloud_status": \(jsonString(track.cloudStatus)), "is_file_track": \(track.isFileTrack)}
        """
    }.joined(separator: ", ")
    return """
    {"id": \(id), "name": \(jsonString(snapshot.name)), \
    "persistent_id": \(jsonString(snapshot.persistentId)), "tracks": [\(tracks)]}
    """
}

private func jsonString(_ value: String) -> String {
    String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
}

private func wireSnapshotsJSON(_ snapshots: [PlaylistSnapshot]) -> String {
    let entries = snapshots.enumerated().map { wirePlaylistJSON($0.element, id: $0.offset + 1) }
    return "{\"playlists\": [\(entries.joined(separator: ", "))]}"
}

// MARK: - CRITICAL PIN (Task 1 brief): same-name byte identity

@Suite("Free-form writer: same-name byte-identity pin (Task 1, CRITICAL)")
struct SameNameByteIdentityPinTests {

    // Reuses the SAME Python-reference-verified golden fixture
    // (script_golden.json's merge_apply_cases) that ScriptGoldenTests already
    // pins — this suite exists so a regression in the free-form branch is
    // caught under the free-form task's own name, not only incidentally by
    // an unrelated suite. A failure here is ALWAYS a same-name regression:
    // this suite touches no free-form code path.
    @Test("every same-name golden merge-apply case stays byte-identical")
    func sameNameGoldenCasesStayByteIdentical() throws {
        let golden = try loadScriptGolden()
        #expect(!golden.mergeApplyCases.isEmpty)
        for goldenCase in golden.mergeApplyCases {
            let plan = try buildMergePlan(name: goldenCase.mergedName, copies: goldenCase.copies)
            #expect(!plan.isFreeForm, "same-name plan must not carry free-form fields")
            let script = try buildMergeApplyScript(
                plan: plan, verifiedCopies: goldenCase.copies, targetName: goldenCase.targetName
            )
            expectByteEqual(script, goldenCase.script, context: "free_form_pin/\(goldenCase.name)")
        }
    }
}

// MARK: - free-form writer script pins

@Suite("Free-form merge writer script (Task 1)")
struct FreeFormMergeWriterScriptTests {

    @Test("uses a PID-set scan instead of a shared-name lookup for the source copies")
    func usesPersistentIdSetScan() throws {
        let copies = freeFormCopies()
        let plan = try freeFormPlan()
        let script = try buildMergeApplyScript(
            plan: plan, verifiedCopies: copies, targetName: freeFormTargetName
        )
        let probe = ByteText(script)

        // No shared-name filter: free-form copies do not share one name, so
        // there is no `sourcePlaylistName` variable at all in this branch.
        #expect(!probe.contains("set sourcePlaylistName to"))
        // The PID-set scan: every user playlist checked against the
        // expected persistent ID list, not one name equality.
        #expect(probe.contains("repeat with candidatePlaylist in every user playlist"))
        #expect(probe.contains("set candidatePersistentID to persistent ID of candidatePlaylist"))
        #expect(probe.contains(
            "if (my textCodePointsMatch(candidatePersistentID, expectedIdCandidate)) is true then"
        ))
        // Everything downstream is unchanged prose, shared with the
        // same-name path: the count guard and the per-copy nested search.
        #expect(probe.contains("if (count of sourcePlaylists) is not expectedCopyCount then error \"live copy count changed\""))
        #expect(probe.contains("my textCodePointsMatch(expectedCopyPersistentID, candidateCopyPID)"))
        // The target is still looked up BY NAME (only the sources are PID-pinned).
        #expect(probe.contains("set targetPlaylistName to \(appleScriptString(freeFormTargetName))"))
    }

    @Test("sets the target description in the same execution, with an immediate readback guard")
    func setsDescriptionWithReadback() throws {
        let plan = try freeFormPlan()
        let script = try buildMergeApplyScript(
            plan: plan, verifiedCopies: freeFormCopies(), targetName: freeFormTargetName
        )
        let probe = ByteText(script)
        let descriptionLiteral = appleScriptString(freeFormDescription)

        let create = try #require(probe.offset(of: "make new user playlist"))
        let duplicate = try #require(probe.offset(of: "duplicate selectedTrack to destinationPlaylist"))
        let setDescription = try #require(
            probe.offset(of: "set description of destinationPlaylist to \(descriptionLiteral)")
        )
        let readback = try #require(
            probe.offset(of: "set liveTargetDescription to description of destinationPlaylist")
        )
        let readbackGuard = try #require(probe.offset(of: "error \"target description readback mismatch\""))
        let successLiteral = appleScriptString(
            "{\"status\":\"ok\",\"duplicated_count\":\(plan.winnerSourceIndexes.count)}"
        )
        let returnStatement = try #require(probe.offset(of: "return \(successLiteral)"))

        // Ordering: create, duplicate every winner, THEN set + verify the
        // description, THEN return — all inside the one compiled execution
        // (there is exactly one `tell application` block; this is a single
        // ordering assertion within it, not a second execution).
        #expect(create < duplicate)
        #expect(duplicate < setDescription)
        #expect(setDescription < readback)
        #expect(readback < readbackGuard)
        #expect(readbackGuard < returnStatement)
    }

    @Test("escapes a hostile description (quotes, backslash, control characters)")
    func escapesHostileDescription() throws {
        let hostileDescription = "Merged on 2026-08-06 from: \"A\" \\ B\nC\tD"
        let plan = try buildFreeFormMergePlan(
            copies: freeFormCopies(),
            targetName: freeFormTargetName,
            targetDescription: hostileDescription,
            sourceNames: freeFormSourceNames
        )
        let script = try buildMergeApplyScript(
            plan: plan, verifiedCopies: freeFormCopies(), targetName: freeFormTargetName
        )
        let expectedLiteral = appleScriptString(hostileDescription)
        let probe = ByteText(script)
        #expect(probe.contains("set description of destinationPlaylist to \(expectedLiteral)"))
        // The raw hostile text (unescaped) never appears verbatim: every
        // occurrence went through appleScriptString's escaping.
        #expect(!probe.contains("to \"Merged on 2026-08-06 from: \"A\""))
    }

    @Test("omits the description block entirely when the plan carries no description")
    func omitsDescriptionBlockWhenAbsent() throws {
        // A same-name plan (no free-form fields) must not gain the
        // description statements at all — this is the same-name branch's
        // OWN text, unaffected by the free-form addition.
        let copies: [PlaylistSnapshot] = [
            PlaylistSnapshot(name: "G", persistentId: "PID-A", tracks: [track()]),
            PlaylistSnapshot(
                name: "G", persistentId: "PID-B",
                tracks: [track(persistentId: "OTHER", title: "Two")]
            ),
        ]
        let plan = try buildMergePlan(name: "G", copies: copies)
        let script = try buildMergeApplyScript(plan: plan, verifiedCopies: copies, targetName: "G — Merged")
        #expect(!ByteText(script).contains("description of destinationPlaylist"))
    }

    @Test(
        "free-form writer compiles",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func freeFormWriterCompiles() throws {
        let plan = try freeFormPlan()
        let script = try buildMergeApplyScript(
            plan: plan, verifiedCopies: freeFormCopies(), targetName: freeFormTargetName
        )
        let result = try compileOnly(script)
        #expect(result.status == 0, "\(result.stderr)")
    }

    @Test(
        "free-form writer with a hostile description compiles",
        .enabled(if: appleScriptCompilerAndMusicAvailable)
    )
    func freeFormWriterWithHostileDescriptionCompiles() throws {
        let hostileDescription = "Merged \"quoted\" \\ backslash \u{2014} dash from: A, B"
        let plan = try buildFreeFormMergePlan(
            copies: freeFormCopies(),
            targetName: freeFormTargetName,
            targetDescription: hostileDescription,
            sourceNames: freeFormSourceNames
        )
        let script = try buildMergeApplyScript(
            plan: plan, verifiedCopies: freeFormCopies(), targetName: freeFormTargetName
        )
        let result = try compileOnly(script)
        #expect(result.status == 0, "\(result.stderr)")
    }

    @Test("targets the absolute Music path and contains no destructive verbs")
    func targetsAbsolutePathAndNoDestructiveVerbs() throws {
        let plan = try freeFormPlan()
        let script = try buildMergeApplyScript(
            plan: plan, verifiedCopies: freeFormCopies(), targetName: freeFormTargetName
        )
        #expect(ByteText(script).contains("tell application \"/System/Applications/Music.app\""))
        let lowered = ByteText(script.lowercased())
        for verb in ["delete ", "set name of", "move ", "remove "] {
            #expect(!lowered.contains(verb), "\(verb)")
        }
    }

    @Test("builder is a pure function: repeated builds are byte-identical")
    func builderIsDeterministic() throws {
        let plan = try freeFormPlan()
        let first = try buildMergeApplyScript(
            plan: plan, verifiedCopies: freeFormCopies(), targetName: freeFormTargetName
        )
        let second = try buildMergeApplyScript(
            plan: plan, verifiedCopies: freeFormCopies(), targetName: freeFormTargetName
        )
        expectByteEqual(first, second, context: "determinism/free_form_merge_apply")
    }
}

// MARK: - buildReadByPersistentIdsJXA / parseCopiesByPersistentIds

@Suite("buildReadByPersistentIdsJXA (Task 1)")
struct ReadByPersistentIdsJXATests {

    @Test("filters by a persistent-ID set, not by name")
    func filtersByPersistentIdSet() {
        let script = buildReadByPersistentIdsJXA(persistentIds: ["PID-A", "PID-B"])
        let probe = ByteText(script)
        #expect(probe.contains("requestedPersistentIdSet.has(playlist.persistentID())"))
        #expect(probe.contains("\"PID-A\""))
        #expect(probe.contains("\"PID-B\""))
        #expect(!probe.contains("playlist.name() === requestedName"))
    }

    @Test("parses only the requested playlists, from a mixed-library wire result")
    func parsesOnlyRequestedPlaylists() throws {
        let raw = wireSnapshotsJSON([
            PlaylistSnapshot(name: "Unrelated", persistentId: "PID-Z", tracks: []),
            PlaylistSnapshot(name: "DJ Set A", persistentId: "PID-A", tracks: [track()]),
        ])
        let parsed = try parseCopiesByPersistentIds(raw: raw, persistentIds: ["PID-A", "PID-B"])
        #expect(parsed.count == 1)
        #expect(parsed[0].persistentId == "PID-A")
    }
}

// MARK: - ensureFreeFormCopiesMatch

@Suite("ensureFreeFormCopiesMatch (Task 1)")
struct EnsureFreeFormCopiesMatchTests {

    @Test("returns live copies in plan order, regardless of live scan order")
    func returnsLiveCopiesInPlanOrder() throws {
        let copies = freeFormCopies()
        let plan = try freeFormPlan()
        let raw = wireSnapshotsJSON(Array(copies.reversed()))

        let result = try MusicBridgeSession(runner: FakeRunner(outputs: [raw]))
            .ensureFreeFormCopiesMatch(plan: plan)

        #expect(result.map(\.persistentId) == ["PID-A", "PID-B"])
    }

    @Test("rejects a missing pinned copy")
    func rejectsMissingCopy() throws {
        let copies = freeFormCopies()
        let plan = try freeFormPlan()
        let raw = wireSnapshotsJSON([copies[0]])

        expectThrowsByteEqualMessage(
            "live copy count changed after audit: planned 2, actual 1; create a fresh audit",
            context: "missing pinned copy"
        ) {
            _ = try MusicBridgeSession(runner: FakeRunner(outputs: [raw]))
                .ensureFreeFormCopiesMatch(plan: plan)
        }
    }

    @Test("rejects a renamed pinned copy (same PID, different live name)")
    func rejectsRenamedCopy() throws {
        let copies = freeFormCopies()
        let plan = try freeFormPlan()
        var renamed = copies
        renamed[1].name = "DJ Set B (renamed)"
        let raw = wireSnapshotsJSON(renamed)

        expectThrowsByteEqualMessage(
            "copy 'PID-B' changed after audit: source name mismatch after write: "
                + "planned 'DJ Set B', actual 'DJ Set B (renamed)'; create a fresh audit",
            context: "renamed pinned copy"
        ) {
            _ = try MusicBridgeSession(runner: FakeRunner(outputs: [raw]))
                .ensureFreeFormCopiesMatch(plan: plan)
        }
    }

    @Test("rejects track drift in a pinned copy")
    func rejectsTrackDrift() throws {
        let copies = freeFormCopies()
        let plan = try freeFormPlan()
        var drifted = copies
        drifted[1].tracks[0].title = "Changed"
        let raw = wireSnapshotsJSON(drifted)

        expectThrowsByteEqualMessage(
            "copy 'PID-B' changed after audit: source track 1 title mismatch after write: "
                + "planned 'One', actual 'Changed'; create a fresh audit",
            context: "drifted pinned copy"
        ) {
            _ = try MusicBridgeSession(runner: FakeRunner(outputs: [raw]))
                .ensureFreeFormCopiesMatch(plan: plan)
        }
    }

    @Test("refuses a same-name plan (variant guard)")
    func refusesSameNamePlan() throws {
        let copies: [PlaylistSnapshot] = [
            PlaylistSnapshot(name: "G", persistentId: "PID-A", tracks: [track()]),
        ]
        let plan = try buildMergePlan(name: "G", copies: copies)

        expectThrowsByteEqualMessage(
            "ensureFreeFormCopiesMatch requires a free-form merge plan; use ensureAllCopiesMatch",
            context: "same-name plan passed to the free-form revalidator"
        ) {
            _ = try MusicBridgeSession(runner: UnusedRunner())
                .ensureFreeFormCopiesMatch(plan: plan)
        }
    }
}

@Suite("ensureAllCopiesMatch refuses a free-form plan (Task 1, mutual variant guard)")
struct EnsureAllCopiesMatchVariantGuardTests {

    @Test("refuses a free-form plan")
    func refusesFreeFormPlan() throws {
        let plan = try freeFormPlan()

        expectThrowsByteEqualMessage(
            "ensureAllCopiesMatch requires a same-name merge plan; use ensureFreeFormCopiesMatch",
            context: "free-form plan passed to the same-name revalidator"
        ) {
            _ = try MusicBridgeSession(runner: UnusedRunner())
                .ensureAllCopiesMatch(plan: plan)
        }
    }
}

// MARK: - applyFreeFormMergePlan orchestration

/// The free-form sibling of `MergeApplyBridge` (OrchestrationTestSupport.swift):
/// in-memory apply boundary, no Music automation runs.
private class FreeFormMergeApplyBridge: MusicBridgeSession {
    let copies: [PlaylistSnapshot]
    let targetReadback: PlaylistSnapshot
    let targetAbsent: Bool
    var writeCalls = 0
    var raiseOnWrite: Error?

    init(
        copies: [PlaylistSnapshot],
        targetReadback: PlaylistSnapshot,
        targetAbsent: Bool = true
    ) {
        self.copies = copies
        self.targetReadback = targetReadback
        self.targetAbsent = targetAbsent
        super.init(runner: UnusedRunner())
    }

    override func ensureFreeFormCopiesMatch(plan: MergePlan) throws -> [PlaylistSnapshot] {
        copies
    }

    override func assertTargetAbsent(targetName: String) throws {
        if !targetAbsent {
            throw MusicBridgeError("target user playlist already exists")
        }
    }

    override func snapshotCopiesByPersistentIds(_ persistentIds: [String]) throws -> [PlaylistSnapshot] {
        copies
    }

    override func snapshotPlaylist(name: String) throws -> PlaylistSnapshot {
        targetReadback
    }

    override func snapshotPlaylistIfPresent(name: String) throws -> PlaylistSnapshot? {
        targetReadback
    }

    override func runMergeApplyScript(
        plan: MergePlan,
        verifiedCopies: [PlaylistSnapshot],
        targetName: String
    ) throws {
        writeCalls += 1
        if let raiseOnWrite {
            throw raiseOnWrite
        }
    }
}

@Suite("applyFreeFormMergePlan orchestration (Task 1)")
struct ApplyFreeFormMergePlanTests {

    private func winnerTracks(_ plan: MergePlan) -> [TrackSnapshot] {
        let combined = plan.combinedTracks
        return plan.winnerSourceIndexes.map { combined[$0] }
    }

    @Test("verified success when the target matches winner order")
    func verifiedSuccess() throws {
        let plan = try freeFormPlan()
        let target = PlaylistSnapshot(
            name: freeFormTargetName, persistentId: "T", tracks: winnerTracks(plan)
        )
        let bridge = FreeFormMergeApplyBridge(copies: freeFormCopies(), targetReadback: target)

        let result = try bridge.applyFreeFormMergePlan(plan: plan, targetName: freeFormTargetName)

        #expect(result.verificationOk == true)
        #expect(result.plannedCount == plan.winnerSourceIndexes.count)
        #expect(result.actualCount == plan.winnerSourceIndexes.count)
        #expect(result.mismatches.isEmpty)
        #expect(bridge.writeCalls == 1)
    }

    @Test("writer failure returns inspected diagnostics without raising")
    func writerFailureReturnsDiagnostics() throws {
        let plan = try freeFormPlan()
        let target = PlaylistSnapshot(
            name: freeFormTargetName, persistentId: "T", tracks: [winnerTracks(plan)[0]]
        )
        let bridge = FreeFormMergeApplyBridge(copies: freeFormCopies(), targetReadback: target)
        bridge.raiseOnWrite = MusicCommandError("simulated free-form merge writer failure")

        let result = try bridge.applyFreeFormMergePlan(plan: plan, targetName: freeFormTargetName)

        #expect(result.verificationOk == false)
        #expect(result.mismatches.first == "write failed: simulated free-form merge writer failure")
    }

    @Test("refuses a same-name plan (variant guard, transitively via ensureFreeFormCopiesMatch)")
    func refusesSameNamePlan() throws {
        // A plain session (no override of ensureFreeFormCopiesMatch): the
        // real guard must fire before any runner call, so UnusedRunner never
        // gets invoked.
        let copies: [PlaylistSnapshot] = [
            PlaylistSnapshot(name: "G", persistentId: "PID-A", tracks: [track()]),
        ]
        let plan = try buildMergePlan(name: "G", copies: copies)

        expectThrowsByteEqualMessage(
            "ensureFreeFormCopiesMatch requires a free-form merge plan; use ensureAllCopiesMatch",
            context: "same-name plan passed to applyFreeFormMergePlan"
        ) {
            _ = try MusicBridgeSession(runner: UnusedRunner())
                .applyFreeFormMergePlan(plan: plan, targetName: "G — Merged")
        }
    }
}

// MARK: - differential structural tests (2026-08-06 review finding I3)
//
// Controller ruling: a differential test NOW (structural extraction into a
// shared builder deferred to the cleanup wave). These prove the free-form
// writer/reader diverge from their same-name/name-based siblings ONLY in
// the known, reviewed blocks — any FUTURE unreviewed divergence (a stray
// line changed while editing something else, a forgotten pin update) fails
// with the exact diverging lines in the message, not a vague "scripts
// differ" complaint.

@Suite("Free-form vs same-name: differential structural pin (Task 1 hardening, I3)")
struct DifferentialStructuralPinTests {

    /// One line-diff hunk classified against the known-difference buckets.
    /// Returns the bucket's label, or nil for an UNRECOGNIZED divergence
    /// (the caller fails with the hunk's own content in that case).
    private func classifyWriterHunk(_ hunk: DiffHunk) -> String? {
        let all = hunk.removed + hunk.added

        if all.allSatisfy({ $0.hasPrefix("local ") }) {
            return "locals list delta"
        }
        if all.allSatisfy({
            $0.hasPrefix("set sourcePlaylistName to ") || $0.hasPrefix("set targetPlaylistName to ")
        }) {
            return "dropped sourcePlaylistName / target-name literal"
        }
        if all.allSatisfy({ line in
            line.contains("expectedCopyNames") || line.contains("expectedCopyName")
                || line.contains("candidateCopyName") || line.contains("copy name changed")
        }) {
            return "per-copy source-name check (review finding m2)"
        }
        // The lookup swap: matched EXACTLY against what the two lookup
        // builders themselves emit (minus the two boilerplate lines and
        // the trailing "end repeat" shared verbatim by both variants), so
        // this bucket tracks those builders automatically rather than
        // hardcoding their text a second time.
        let sourceLookupInner = Array(
            exactPlaylistLookup(variable: "sourcePlaylists", requestedName: "sourcePlaylistName")
                .dropFirst(2).dropLast(1)
        )
        let pidLookupInner = Array(
            exactPersistentIdSetLookup(variable: "sourcePlaylists", idsVariable: "expectedCopyPersistentIDs")
                .dropFirst(2).dropLast(1)
        )
        if hunk.removed == sourceLookupInner && hunk.added == pidLookupInner {
            return "lookup swap (shared name -> PID-set membership)"
        }
        if hunk.removed.isEmpty && hunk.added.allSatisfy({ line in
            line.contains("destinationPlaylist to") || line.contains("liveTargetDescription")
                || line.contains("target description readback mismatch")
        }) {
            return "description block (present only when the plan carries a description)"
        }
        return nil
    }

    // test_writer_scripts_differ_only_in_known_blocks
    @Test("free-form writer script differs from the same-name writer script only in known blocks")
    func writerScriptsDifferOnlyInKnownBlocks() throws {
        // Parallel fixtures: identical track data on both sides (so payload/
        // per-track-guard text is byte-identical) — only the STRUCTURAL
        // shape differs (shared name vs. distinct names + description).
        let copies = freeFormCopies()
        let sameNameCopies: [PlaylistSnapshot] = [
            PlaylistSnapshot(name: "G", persistentId: "PID-A", tracks: copies[0].tracks),
            PlaylistSnapshot(name: "G", persistentId: "PID-B", tracks: copies[1].tracks),
        ]
        let sameNamePlan = try buildMergePlan(name: "G", copies: sameNameCopies)
        let sameNameScript = try buildMergeApplyScript(
            plan: sameNamePlan, verifiedCopies: sameNameCopies, targetName: "G — Merged"
        )
        let freeForm = try freeFormPlan()
        let freeFormScript = try buildMergeApplyScript(
            plan: freeForm, verifiedCopies: copies, targetName: freeFormTargetName
        )

        let hunkList = hunks(from: lineDiff(
            sameNameScript.components(separatedBy: "\n"),
            freeFormScript.components(separatedBy: "\n")
        ))
        #expect(!hunkList.isEmpty, "the two scripts must actually differ")

        var seenBuckets: Set<String> = []
        for hunk in hunkList {
            guard let bucket = classifyWriterHunk(hunk) else {
                Issue.record("""
                unrecognized divergence between the same-name and free-form writer \
                scripts (not one of the reviewed known blocks) — \
                removed: \(hunk.removed); added: \(hunk.added)
                """)
                continue
            }
            seenBuckets.insert(bucket)
        }
        // Every expected bucket actually fired at least once — if the
        // description block (say) silently vanished, this catches THAT
        // too, not just unexpected additions.
        #expect(seenBuckets == [
            "locals list delta",
            "dropped sourcePlaylistName / target-name literal",
            "per-copy source-name check (review finding m2)",
            "lookup swap (shared name -> PID-set membership)",
            "description block (present only when the plan carries a description)",
        ])
    }

    /// One reader-hunk classified against the one known-difference bucket:
    /// the requestedName/requestedPersistentIds(+Set) lookup-identifier
    /// swap. (Controller framing: "3 known lines" — the 3 ADDED lines;
    /// there are also 2 removed lines swapped out, for 2 hunks total. Both
    /// numbers are asserted below rather than picking just one.)
    private func classifyReaderHunk(_ hunk: DiffHunk) -> String? {
        let all = hunk.removed + hunk.added
        if all.allSatisfy({
            $0.contains("requestedName") || $0.contains("requestedPersistentIds")
                || $0.contains("requestedPersistentIdSet")
        }) {
            return "lookup identifier swap (name -> PID set)"
        }
        return nil
    }

    // test_readers_differ_only_in_known_lines
    @Test("free-form reader JXA differs from the name-based reader JXA only in known lines")
    func readersDifferOnlyInKnownLines() throws {
        let nameReader = buildReadJXA(name: "any")
        let pidReader = buildReadByPersistentIdsJXA(persistentIds: ["PID-A", "PID-B"])

        let hunkList = hunks(from: lineDiff(
            nameReader.components(separatedBy: "\n"),
            pidReader.components(separatedBy: "\n")
        ))
        #expect(!hunkList.isEmpty, "the two readers must actually differ")

        var totalRemoved = 0
        var totalAdded = 0
        for hunk in hunkList {
            guard let bucket = classifyReaderHunk(hunk) else {
                Issue.record("""
                unrecognized divergence between the name-based and PID-set read JXA \
                (not the known lookup-identifier swap) — \
                removed: \(hunk.removed); added: \(hunk.added)
                """)
                continue
            }
            #expect(bucket == "lookup identifier swap (name -> PID set)")
            totalRemoved += hunk.removed.count
            totalAdded += hunk.added.count
        }
        // The exact, reviewed shape: the const declaration swap (1 removed,
        // 2 added: requestedPersistentIds + requestedPersistentIdSet) plus
        // the filter's return-statement swap (1 removed, 1 added) — 2
        // hunks, 2 removed lines, 3 added lines total.
        #expect(hunkList.count == 2)
        #expect(totalRemoved == 2)
        #expect(totalAdded == 3)
    }
}

// MARK: - minimal line diff (2026-08-06 review finding I3)

enum DiffOp: Equatable {
    case same(String)
    case removed(String)
    case added(String)
}

func lineDiff(_ a: [String], _ b: [String]) -> [DiffOp] {
    let n = a.count, m = b.count
    var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
            if a[i] == b[j] {
                lcs[i][j] = lcs[i + 1][j + 1] + 1
            } else {
                lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
    }
    var ops: [DiffOp] = []
    var i = 0, j = 0
    while i < n && j < m {
        if a[i] == b[j] {
            ops.append(.same(a[i]))
            i += 1; j += 1
        } else if lcs[i + 1][j] >= lcs[i][j + 1] {
            ops.append(.removed(a[i]))
            i += 1
        } else {
            ops.append(.added(b[j]))
            j += 1
        }
    }
    while i < n { ops.append(.removed(a[i])); i += 1 }
    while j < m { ops.append(.added(b[j])); j += 1 }
    return ops
}

struct DiffHunk {
    let removed: [String]
    let added: [String]
}

func hunks(from ops: [DiffOp]) -> [DiffHunk] {
    var result: [DiffHunk] = []
    var removed: [String] = []
    var added: [String] = []
    func flush() {
        if !removed.isEmpty || !added.isEmpty {
            result.append(DiffHunk(removed: removed, added: added))
        }
        removed = []
        added = []
    }
    for op in ops {
        switch op {
        case .same:
            flush()
        case .removed(let line):
            removed.append(line)
        case .added(let line):
            added.append(line)
        }
    }
    flush()
    return result
}
