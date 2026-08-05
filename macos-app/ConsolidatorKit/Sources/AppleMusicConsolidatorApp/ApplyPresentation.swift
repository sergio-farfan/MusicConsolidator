// ApplyPresentation.swift
// M9 — the pure presentation layer under the apply screens (4-6): stage
// labels for the progress list, the cli.py post-apply output ported
// byte-for-byte (the success sentence contract the CLI prints), and the
// failure classifier that maps the M5 error taxonomy + the loader's
// PlanLoadError cases onto distinct operator-facing rendering. Everything
// here is a value-typed pure function — headlessly testable, no Music, no
// I/O.
//
// Semantic reference: apple_music_consolidator/cli.py `_apply` /
// `_merge_apply` (lines 107-118 and 169-180) for the success texts;
// Sources/ConsolidatorCore/Persistence.swift PlanLoadError for the loader
// cases; Sources/MusicBridge for MusicCommandError / MusicBridgeError.

import Foundation
import ConsolidatorCore
import MusicBridge

// MARK: - apply stages (screen 4)

/// One row of the apply progress list: the app-level artifact load followed
/// by the six bridge phases (`MusicBridge.ApplyPhase`) in guarded order.
nonisolated enum ApplyStage: Hashable, Sendable {
    case loadingPlan
    case bridge(ApplyPhase)
}

/// The streaming-progress label per stage (elapsed ticking is the view's
/// job; a bare spinner is forbidden).
nonisolated func applyStageLabel(_ stage: ApplyStage) -> String {
    switch stage {
    case .loadingPlan:
        return "Loading the approved plan artifact\u{2026}"
    case .bridge(.rereadingSources):
        return "Re-reading the source playlist(s)\u{2026}"
    case .bridge(.revalidating):
        return "Revalidating the live library against the plan\u{2026}"
    case .bridge(.assertingTargetAbsent):
        return "Confirming no playlist already has the target name\u{2026}"
    case .bridge(.compilingWriter):
        return "Compiling the guarded writer\u{2026}"
    case .bridge(.executingGuardedWrite):
        return "Executing the guarded write\u{2026}"
    case .bridge(.verifyingReadback):
        return "Verifying readback against the plan\u{2026}"
    }
}

/// One stage with its start instant, for the elapsed ticker.
nonisolated struct ApplyStageEntry: Equatable, Sendable, Identifiable {
    let stage: ApplyStage
    let started: Date

    var id: ApplyStage { stage }
}

// MARK: - stage table rows (A3: all rows up front)

/// The render status of one stage-table row. Elapsed FORMATTING stays in
/// the view (ProgressPhaseView.elapsedText is MainActor with the View
/// protocol); this pure layer carries the instants only.
nonisolated enum ApplyStageRowStatus: Equatable, Sendable {
    case pending
    case completed(started: Date, finishedAt: Date)
    case current(started: Date)
}

/// One row of the three-column steps table (Step | Status | Elapsed).
nonisolated struct ApplyStageRowModel: Equatable, Sendable, Identifiable {
    let stage: ApplyStage
    let label: String
    let status: ApplyStageRowStatus

    var id: ApplyStage { stage }
}

/// ALL `1 + ApplyPhase.allCases.count` rows, up front (A3): entries beyond
/// `stages` are pending; the last started entry is current (live); every
/// earlier entry is completed, frozen at the next entry's start (exactly
/// the pre-A3 elapsed rule). An empty `stages` yields 7 pending rows.
nonisolated func applyStageRows(stages: [ApplyStageEntry]) -> [ApplyStageRowModel] {
    let sequence = [ApplyStage.loadingPlan] + ApplyPhase.allCases.map(ApplyStage.bridge)
    return sequence.enumerated().map { index, stage in
        let status: ApplyStageRowStatus
        if index + 1 < stages.count {
            status = .completed(
                started: stages[index].started, finishedAt: stages[index + 1].started
            )
        } else if index + 1 == stages.count {
            status = .current(started: stages[index].started)
        } else {
            status = .pending
        }
        return ApplyStageRowModel(stage: stage, label: applyStageLabel(stage), status: status)
    }
}

// MARK: - success rendering (screen 5; cli.py post-apply output, verbatim)

/// The verification sentence the CLI prints on a verified apply
/// (cli.py:107-110 consolidate, cli.py:169-172 merge) — the same sentence
/// contract, byte for byte.
nonisolated func applyVerifiedText(mode: ConsolidatorMode) -> String {
    switch mode {
    case .consolidate:
        return "Verified: source playlist unchanged; consolidated playlist "
            + "readback matches plan."
    case .merge:
        return "Verified: source copies unchanged; merged playlist "
            + "readback matches plan."
    }
}

/// The next-gate guidance (cli.py:111-114 / 173-176), verbatim.
nonisolated func applyNextGateText(mode: ConsolidatorMode) -> String {
    switch mode {
    case .consolidate:
        return "Next gate: inspect the playlist in Music, including unavailable-item "
            + "flags and several quality decisions."
    case .merge:
        return "Next gate: inspect the merged playlist in Music, including unavailable-item "
            + "flags and several quality decisions."
    }
}

/// The deletion reminder. DELIBERATE DEVIATION from the verbatim cli.py port
/// (fix round 1, minor e): the CLI's line names its one-time pilot
/// ("…until Sergio explicitly approves the pilot"), which would read stale
/// in the app after that pilot. The substance is kept, self-contained and
/// time-proof: do not delete sources until the result is inspected and
/// approved in Music; deletion is always a separate, manual decision.
nonisolated func applyDeletionReminderText(mode: ConsolidatorMode) -> String {
    switch mode {
    case .consolidate:
        return "Do not delete the source or the new playlist until you have "
            + "inspected and approved the result in Music; deletion is always a "
            + "separate, manual decision \u{2014} never part of an apply."
    case .merge:
        return "Do not delete any source copy until you have inspected and "
            + "approved the merged playlist in Music; deletion is always a "
            + "separate, manual decision \u{2014} never part of an apply."
    }
}

/// The rendered success state: everything screen 5 shows, captured at
/// verification time from the ApplyResult + the consumed audit.
nonisolated struct ApplySuccessDisplay: Equatable, Sendable {
    let mode: ConsolidatorMode
    let targetName: String
    /// The verified readback's track count (ApplyResult.actualCount).
    let trackCount: Int
    let plannedCount: Int
    let fingerprint: String
    let paths: AuditPaths
}

// MARK: - failure rendering (screen 6)

/// Distinct presentation classes: the four fail-closed loader cases
/// (decision 1 — the deferred PlanLoadError-UI-copy item), the M5 error
/// taxonomy (MusicCommandError = automation, MusicBridgeError = library
/// drift), and a verification failure carrying verbatim mismatches.
/// RENAMED from ApplyFailureClass in Wave C1: the spec-pinned name now
/// belongs to the five-class library-state taxonomy
/// (ApplyFailureTaxonomy.swift). This enum still picks the failure
/// SCREEN's rendering (headline/guidance/panels) — display only.
nonisolated enum ApplyFailureDisplayClass: Equatable, Sendable {
    case planFileUnreadable
    case planMalformedJSON
    case planDecodeRejected
    case planIntegrityRejected
    case automationFailed
    case libraryDrift
    case verificationFailed
    case unexpected
}

/// Everything screen 6 renders for one failed apply. `message` is the
/// VERBATIM thrown-error text (empty for a verification failure, whose
/// diagnostics live in `mismatches` — also verbatim, never paraphrased).
nonisolated struct ApplyFailureDisplay: Equatable, Sendable {
    let failureClass: ApplyFailureDisplayClass
    let headline: String
    let guidance: String
    let message: String
    let mismatches: [String]
    let plannedCount: Int?
    let actualCount: Int?
}

private nonisolated func failureDisplay(
    _ failureClass: ApplyFailureDisplayClass,
    headline: String,
    guidance: String,
    message: String
) -> ApplyFailureDisplay {
    ApplyFailureDisplay(
        failureClass: failureClass,
        headline: headline,
        guidance: guidance,
        message: message,
        mismatches: [],
        plannedCount: nil,
        actualCount: nil
    )
}

/// Classify a THROWN apply error (the loader or the orchestration rejected
/// fail-closed before returning a verification result). The error message
/// is preserved verbatim.
nonisolated func classifyApplyFailure(_ error: Error) -> ApplyFailureDisplay {
    let message = String(describing: error)
    if let loadError = error as? PlanLoadError {
        switch loadError {
        case .fileUnreadable:
            return failureDisplay(
                .planFileUnreadable,
                headline: "Plan file unreadable",
                guidance: "The approved plan artifact could not be read from disk, so the "
                    + "apply never started and nothing was written. Start over and run a "
                    + "fresh audit \u{2014} approval names an exact plan file, and this one "
                    + "is gone or inaccessible.",
                message: message
            )
        case .malformedJSON:
            return failureDisplay(
                .planMalformedJSON,
                headline: "Plan file rejected \u{2014} not valid JSON",
                guidance: "The plan artifact on disk is not the strict JSON this tool "
                    + "writes \u{2014} it was modified or corrupted after the audit. The "
                    + "apply never started and nothing was written. Never repair a plan "
                    + "file by hand; run a fresh audit.",
                message: message
            )
        case .decodeRejected:
            return failureDisplay(
                .planDecodeRejected,
                headline: "Plan file rejected \u{2014} strict decode failed",
                guidance: "The plan artifact does not decode as a canonical plan (missing, "
                    + "unknown, or wrongly-typed fields). The apply never started and "
                    + "nothing was written. Run a fresh audit and apply its own artifact.",
                message: message
            )
        case .integrityRejected:
            return failureDisplay(
                .planIntegrityRejected,
                headline: "Plan file rejected \u{2014} integrity check failed",
                guidance: "The plan's content does not verify against its own fingerprint "
                    + "and canonical recompute, so it is NOT the reviewed plan. The apply "
                    + "never started and nothing was written. Run a fresh audit.",
                message: message
            )
        }
    }
    switch error {
    case is MusicCommandError:
        return failureDisplay(
            .automationFailed,
            headline: "Automation failed",
            guidance: "Music automation did not complete. Check that Music is running "
                + "and that Automation access is granted (the preflight below shows the "
                + "current state). This audit is consumed either way \u{2014} once the "
                + "problem is fixed, run a fresh audit.",
            message: message
        )
    case is MusicBridgeError:
        return failureDisplay(
            .libraryDrift,
            headline: "Library changed since the audit",
            guidance: "The live library no longer matches the reviewed plan (or Music "
                + "returned data the strict parser rejects), so the apply failed closed "
                + "at that boundary. Run a fresh audit \u{2014} this plan is consumed "
                + "and is never reused.",
            message: message
        )
    default:
        return failureDisplay(
            .unexpected,
            headline: "Unexpected error",
            guidance: "The apply stopped on an error outside the known taxonomy. "
                + "Nothing is retried automatically. Inspect the verbatim message "
                + "below, then run a fresh audit.",
            message: message
        )
    }
}

/// Render a returned-but-unverified ApplyResult (writer failure or readback
/// mismatch): the mismatches are carried VERBATIM.
nonisolated func applyVerificationFailureDisplay(_ result: ApplyResult) -> ApplyFailureDisplay {
    ApplyFailureDisplay(
        failureClass: .verificationFailed,
        headline: "Apply failed closed \u{2014} verification did not pass",
        guidance: "The guarded write did not verify: the diagnostics below are "
            + "verbatim readback evidence. Nothing is retried automatically and no "
            + "partial state is ever repaired \u{2014} inspect Music, then run a "
            + "fresh audit.",
        message: "",
        mismatches: result.mismatches,
        plannedCount: result.plannedCount,
        actualCount: result.actualCount
    )
}
