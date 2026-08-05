// ApplyFailureTaxonomyTests.swift
// Wave C1 Task 1 — the five-class apply failure taxonomy (spec C1.1/C1.2,
// incl. rule 3b per the controller amendment 2026-08-04): pure
// classification over (failedStage, result), the pinned label and guidance
// copy, and the leftover-possible predicate. The three live batch failures
// are replayed as unit vectors: Goddesses (existing-target guard,
// pre-write), New Age Favs (the readback READ failed — both the thrown
// shape and the caught-line shape the bridge actually produces), Daechir
// ESP ORIG (source drifted after a verified write).

import Foundation
import Testing
import ConsolidatorCore
import MusicBridge
@testable import AppleMusicConsolidatorApp

private func unverifiedResult(mismatches: [String]) -> ApplyResult {
    ApplyResult(
        sourceFingerprint: String(repeating: "a", count: 64),
        plannedCount: 143,
        actualCount: 143,
        verificationOk: false,
        mismatches: mismatches
    )
}

@Suite("Wave C1 — apply failure classification (pure)")
struct ApplyFailureClassTests {

    @Test("rule 1: every pre-write stage classifies refusedBeforeWrite, result or not")
    func preWriteStages() {
        let preWrite: [ApplyStage] = [
            .loadingPlan,
            .bridge(.rereadingSources),
            .bridge(.revalidating),
            .bridge(.assertingTargetAbsent),   // Goddesses: the existing-target guard
            .bridge(.compilingWriter),
        ]
        for stage in preWrite {
            #expect(classifyApplyFailure(failedStage: stage, result: nil)
                == .refusedBeforeWrite)
        }
    }

    @Test("rule 2 (stage shape): a failure recorded at executingGuardedWrite is writerFailed")
    func executeStage() {
        #expect(classifyApplyFailure(
            failedStage: .bridge(.executingGuardedWrite), result: nil
        ) == .writerFailed)
    }

    @Test("rule 2 (returned shape): the writer-failure inspection's pinned first mismatch")
    func writerFailureReturnedThroughReadback() {
        // The bridge catches writer errors and returns them through
        // writerFailureResult, which emits .verifyingReadback and puts
        // "write failed: …" FIRST (MusicBridge.swift:822-873) — the later
        // source/target diagnostic lines must not flip the class.
        let result = unverifiedResult(mismatches: [
            "write failed: osascript exited 1: execution error: "
                + "Guarded write refused: source drifted (-2700)",
            "source track count mismatch after write: planned 143, actual 141",
            "target readback confirmed no exact-name target exists",
        ])
        #expect(classifyApplyFailure(
            failedStage: .bridge(.verifyingReadback), result: result
        ) == .writerFailed)
    }

    @Test("rule 3: verifyingReadback THREW (no result) — New Age Favs, -1728")
    func readbackThrew() {
        #expect(classifyApplyFailure(
            failedStage: .bridge(.verifyingReadback), result: nil
        ) == .unverifiable)
    }

    @Test("rule 4: an all-'source ' mismatch list is sourceDrifted — Daechir ESP ORIG")
    func sourceOnlyMismatches() {
        let result = unverifiedResult(mismatches: [
            "source track count mismatch after write: planned 143, actual 141",
            "source fingerprint mismatch after write: "
                + "planned aaaa1111, actual bbbb2222",
        ])
        #expect(classifyApplyFailure(
            failedStage: .bridge(.verifyingReadback), result: result
        ) == .sourceDrifted)
    }

    @Test("rule 4: any non-'source ' line dominates as targetMismatch")
    func mixedMismatches() {
        let result = unverifiedResult(mismatches: [
            "source track count mismatch after write: planned 143, actual 141",
            "track 3 persistent ID mismatch: planned 'AAAA', actual 'BBBB'",
        ])
        #expect(classifyApplyFailure(
            failedStage: .bridge(.verifyingReadback), result: result
        ) == .targetMismatch)
    }

    @Test("rule 3b: a caught target-readback READ failure line is unverifiable")
    func targetReadbackFailureLine() {
        // The target was never compared — "does not match the plan" is not
        // established (spec C1.2 rule 3b, controller amendment 2026-08-04).
        let result = unverifiedResult(mismatches: [
            "target readback failed after write: JXA execution failed: error -1728",
        ])
        #expect(classifyApplyFailure(
            failedStage: .bridge(.verifyingReadback), result: result
        ) == .unverifiable)
    }

    @Test("rule 3b: the verbatim New Age Favs line (copies read failed) is unverifiable")
    func newAgeFavsCopiesReadFailure() {
        // The REAL New Age Favs shape: the bridge CAUGHT the merge copies
        // re-read error and surfaced it as a line beginning "source " —
        // a bare rule 4 would have claimed sourceDrifted ("the source
        // changed after the audit") when nothing was ever compared.
        let result = unverifiedResult(mismatches: [
            "source copies readback failed after write: JXA execution failed: "
                + "error -1728: Error: Error: Can't get object.",
        ])
        #expect(classifyApplyFailure(
            failedStage: .bridge(.verifyingReadback), result: result
        ) == .unverifiable)
    }

    @Test("rule 3b: a caught source-readback READ failure line is unverifiable")
    func sourceReadbackFailureLine() {
        let result = unverifiedResult(mismatches: [
            "source readback failed after write: JXA execution failed: error -1728",
        ])
        #expect(classifyApplyFailure(
            failedStage: .bridge(.verifyingReadback), result: result
        ) == .unverifiable)
    }

    @Test("rule 3b dominates mixed lists: genuine drift plus a read failure is unverifiable")
    func mixedDriftAndReadFailure() {
        // One REAL source-drift comparison line plus one target-read
        // failure: state unknown dominates — never sourceDrifted, never
        // targetMismatch.
        let result = unverifiedResult(mismatches: [
            "source track 2 title mismatch after write: planned 'A', actual 'B'",
            "target readback failed after write: JXA execution failed: error -1728",
        ])
        #expect(classifyApplyFailure(
            failedStage: .bridge(.verifyingReadback), result: result
        ) == .unverifiable)
    }

    @Test("rule 4 prefix checks are scalar-exact, never canonical")
    func prefixIsScalarExact() {
        // Capital S and NBSP-separated lookalikes must NOT count as
        // "source " lines: they condemn the target (fail-closed direction).
        for line in [
            "Source track count mismatch after write: planned 2, actual 1",
            "source\u{00A0}track count mismatch after write: planned 2, actual 1",
        ] {
            #expect(classifyApplyFailure(
                failedStage: .bridge(.verifyingReadback),
                result: unverifiedResult(mismatches: [line])
            ) == .targetMismatch)
        }
    }

    @Test("rule 5: a returned result with NO mismatch lines is unverifiable, not vacuously drifted")
    func degenerateEmptyMismatches() {
        #expect(classifyApplyFailure(
            failedStage: .bridge(.verifyingReadback),
            result: unverifiedResult(mismatches: [])
        ) == .unverifiable)
    }

    @Test("scalarHasPrefix rejects canonically-equivalent drift String.hasPrefix accepts")
    func scalarPrefixHelper() {
        #expect(scalarHasPrefix("source x", "source "))
        #expect(!scalarHasPrefix("Source x", "source "))
        #expect(!scalarHasPrefix("sourc", "source "))
        // NFC prefix vs NFD text: canonical equivalence would accept this.
        let nfdText = "e\u{301}crit"
        #expect(nfdText.hasPrefix("\u{E9}"))
        #expect(!scalarHasPrefix(nfdText, "\u{E9}"))
    }
}

@Suite("Wave C1 — pinned label and guidance copy")
struct ApplyFailureCopyTests {

    @Test("the five UI labels are byte-exact (spec C1.1 table)")
    func labels() {
        #expect(applyFailureClassLabel(.refusedBeforeWrite)
            == "Refused before write \u{2014} nothing was created.")
        #expect(applyFailureClassLabel(.writerFailed)
            == "Writer failed during the guarded write \u{2014} a partial target may exist.")
        #expect(applyFailureClassLabel(.unverifiable)
            == "Unverifiable \u{2014} the write may have completed, but verification "
                + "could not read the library back.")
        #expect(applyFailureClassLabel(.sourceDrifted)
            == "Source drifted after a verified write \u{2014} the created target "
                + "matches the plan, but the source changed after the check.")
        #expect(applyFailureClassLabel(.targetMismatch)
            == "Target mismatch \u{2014} the created target does not match the plan.")
    }

    @Test("the five guidance lines are byte-exact (spec C1.1)")
    func guidance() {
        #expect(applyFailureClassGuidance(.refusedBeforeWrite)
            == "Nothing changed in Music. Re-check when the refusal cause is resolved.")
        #expect(applyFailureClassGuidance(.writerFailed)
            == "Inspect the target in Music; delete the leftover with the guarded "
                + "gate, then re-check.")
        #expect(applyFailureClassGuidance(.unverifiable)
            == "Compare the target against the plan artifact manually, or delete "
                + "the leftover with the guarded gate and re-check.")
        #expect(applyFailureClassGuidance(.sourceDrifted)
            == "The target is internally sound but was built from a source state "
                + "that no longer exists. Keep it or delete it, then re-check the "
                + "changed source.")
        #expect(applyFailureClassGuidance(.targetMismatch)
            == "Delete the leftover with the guarded gate and re-check; never keep "
                + "an unverified target.")
    }

    @Test("only refusedBeforeWrite can never leave a target behind")
    func mayLeaveTarget() {
        #expect(!applyFailureClassMayLeaveTarget(.refusedBeforeWrite))
        for failureClass: ApplyFailureClass in [
            .writerFailed, .unverifiable, .sourceDrifted, .targetMismatch,
        ] {
            #expect(applyFailureClassMayLeaveTarget(failureClass))
        }
    }
}
