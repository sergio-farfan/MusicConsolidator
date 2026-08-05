// ApplyFailureTaxonomy.swift
// Wave C1 (spec C1.1/C1.2) — the five-class apply failure taxonomy: pure
// classification over the failed stage plus the returned (unverified)
// ApplyResult, and the pinned operator-facing label/guidance copy. This is
// presentation-layer vocabulary, NOT a contract model: ApplyResult, the
// writer scripts, and every bridge message stay byte-identical.
//
// Naming: the M9 loader/error display classes were renamed
// ApplyFailureDisplayClass (ApplyPresentation.swift) so this enum can carry
// the spec-pinned name. The two coexist deliberately —
// ApplyFailureDisplayClass picks the failure screen's rendering;
// ApplyFailureClass states what the LIBRARY looks like after the failure.
//
// Rule 2 refinement (plan-header finding 2): the bridge catches writer
// errors and returns them through writerFailureResult /
// mergeWriterFailureResult, which emit .verifyingReadback and put the
// pinned "write failed: " message FIRST in the mismatches
// (MusicBridge.swift:822-873, :959-1010). A returned result whose first
// line carries that scalar-exact prefix is therefore a writer failure
// regardless of the recorded stage.
//
// Rule 3b (spec C1.2 rule 3b, controller amendment 2026-08-04; plan-header
// finding 5): the bridge also catches its post-write readback READ errors
// and surfaces them as LINES ("source readback failed after write: ",
// "source copies readback failed after write: ", "target readback failed
// after write: " — MusicBridge.swift:890/:931/:898/:940). A read failure
// means comparison never happened for that side — never drift, never
// mismatch — so any such line classifies unverifiable, dominating even
// mixed lists. SourcePrefixPinTests pins the "source " prefix set;
// ReadbackFailurePrefixPinTests pins the three read-failure prefixes;
// ApplyFailureCaptureTests pins the "write failed: " first position end to
// end.

import Foundation
import ConsolidatorCore
import MusicBridge

/// Wave C1 (spec C1.1): what the library looks like after a failed apply.
nonisolated enum ApplyFailureClass: String, Equatable, Sendable {
    case refusedBeforeWrite
    case writerFailed
    case unverifiable
    case sourceDrifted
    case targetMismatch
}

/// Unicode-scalar-exact prefix test. String.hasPrefix compares under
/// canonical equivalence and would accept NFC/NFD-drifted prefixes; every
/// guard-adjacent string check in this project is scalar-exact.
nonisolated func scalarHasPrefix(_ string: String, _ prefix: String) -> Bool {
    string.unicodeScalars.starts(with: prefix.unicodeScalars)
}

/// Wave C1 (spec C1.2): classify one failed apply. `result` is non-nil only
/// when the verifyingReadback stage RAN and returned an unverified
/// ApplyResult; a thrown error passes nil.
nonisolated func classifyApplyFailure(
    failedStage: ApplyStage,
    result: ApplyResult?
) -> ApplyFailureClass {
    switch failedStage {
    case .loadingPlan,
         .bridge(.rereadingSources),
         .bridge(.revalidating),
         .bridge(.assertingTargetAbsent),
         .bridge(.compilingWriter):
        // Rule 1 — stage alone decides; no message parsing. The
        // existing-target refusal (Goddesses) fails at
        // assertingTargetAbsent, before any write.
        return .refusedBeforeWrite
    case .bridge(.executingGuardedWrite):
        // Rule 2, stage shape — defensive: with the current bridge a writer
        // failure returns THROUGH verifyingReadback (file header); this arm
        // covers any future path that fails while the write stage is last.
        return .writerFailed
    case .bridge(.verifyingReadback):
        // Rule 3 — the readback itself threw: target state unknown
        // (New Age Favs, -1728).
        guard let result else { return .unverifiable }
        // Rule 5 — degenerate: an unverified result carrying no evidence is
        // "state unknown", never sourceDrifted by vacuity.
        guard let first = result.mismatches.first else { return .unverifiable }
        // Rule 2, returned shape — the writer-failure inspection's pinned
        // first mismatch.
        if scalarHasPrefix(first, "write failed: ") { return .writerFailed }
        // Rule 3b (spec C1.2 rule 3b, controller amendment 2026-08-04) —
        // the bridge CATCHES its post-write readback READ errors and
        // surfaces them as lines (verifyAfterWrite :890/:898,
        // verifyMergeAfterWrite :931/:940). A read failure means comparison
        // never happened for that side — never drift, never mismatch; state
        // unknown dominates even in mixed lists. The writer-error variants
        // ("…after writer error: " at :838/:975 and "target readback
        // failed: " at :849/:986) never reach this check: rule 2's
        // first-line "write failed: " test fires first.
        let readFailurePrefixes = [
            "source readback failed after write: ",
            "source copies readback failed after write: ",
            "target readback failed after write: ",
        ]
        if result.mismatches.contains(where: { line in
            readFailurePrefixes.contains { scalarHasPrefix(line, $0) }
        }) {
            return .unverifiable
        }
        // Rule 4 — any non-"source " line condemns the target (dominates);
        // an all-"source " list means the target readback verified clean
        // and only the source drifted (Daechir ESP ORIG). Sound because the
        // bridge reads the target back even when source mismatches exist
        // (plan-header finding 1: MusicBridge.swift:877-913 and :917-955 —
        // no short-circuit), and rule 3b has already peeled off every
        // read-failure line.
        if result.mismatches.contains(where: { !scalarHasPrefix($0, "source ") }) {
            return .targetMismatch
        }
        return .sourceDrifted
    }
}

/// The class banner (spec C1.1 table, exact copy).
nonisolated func applyFailureClassLabel(_ failureClass: ApplyFailureClass) -> String {
    switch failureClass {
    case .refusedBeforeWrite:
        return "Refused before write \u{2014} nothing was created."
    case .writerFailed:
        return "Writer failed during the guarded write \u{2014} a partial target may exist."
    case .unverifiable:
        return "Unverifiable \u{2014} the write may have completed, but verification "
            + "could not read the library back."
    case .sourceDrifted:
        return "Source drifted after a verified write \u{2014} the created target "
            + "matches the plan, but the source changed after the audit."
    case .targetMismatch:
        return "Target mismatch \u{2014} the created target does not match the plan."
    }
}

/// The per-class guidance line (spec C1.1, exact copy).
nonisolated func applyFailureClassGuidance(_ failureClass: ApplyFailureClass) -> String {
    switch failureClass {
    case .refusedBeforeWrite:
        return "Nothing changed in Music. Re-audit when the refusal cause is resolved."
    case .writerFailed:
        return "Inspect the target in Music; delete the leftover with the guarded "
            + "gate, then re-audit."
    case .unverifiable:
        return "Compare the target against the plan artifact manually, or delete "
            + "the leftover with the guarded gate and re-audit."
    case .sourceDrifted:
        return "The target is internally sound but was built from a source state "
            + "that no longer exists. Keep it or delete it, then re-audit the "
            + "changed source."
    case .targetMismatch:
        return "Delete the leftover with the guarded gate and re-audit; never keep "
            + "an unverified target."
    }
}

/// The four classes that can leave a target behind (spec C1.4/C1.5): the
/// "- Leftover target:" report line and the delete shortcut render only for
/// these.
nonisolated func applyFailureClassMayLeaveTarget(_ failureClass: ApplyFailureClass) -> Bool {
    failureClass != .refusedBeforeWrite
}
