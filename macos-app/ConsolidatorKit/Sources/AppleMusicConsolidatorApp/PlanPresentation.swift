// PlanPresentation.swift
// The pure presentation layer under the M7 review→approve screens: omission
// classification, merge per-copy provenance, target-name suffixes, the
// cli.py-parity hand-off command text, and display formatting. Everything
// here is a value-typed pure function over CANONICAL plans (the objects
// returned by buildPlan/buildMergePlan — the binding M7 data-flow rule), so
// the whole layer is headlessly testable.
//
// Semantic reference: apple_music_consolidator/cli.py — the audit command's
// counts, target-name suffixes ("<Name> — Consolidated" / "<Name> — Merged"),
// preamble text, and shlex-quoted copyable apply command are reproduced
// byte-for-byte (shlexQuote pinned against python3 shlex.quote, 2026-08-01).

import Foundation
import ConsolidatorCore

// MARK: - modes

/// The two audit capabilities (plan: mode toggle Consolidate | Merge).
nonisolated enum ConsolidatorMode: String, CaseIterable, Identifiable, Sendable {
    case consolidate
    case merge

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .consolidate: return "Consolidate"
        case .merge: return "Merge"
        }
    }
}

/// The three browser tabs (Wave B): the two audit modes plus Cleanup, which
/// is NOT an audit mode — it never joins ConsolidatorMode (whose exhaustive
/// switches over audit/apply semantics stay two-armed).
nonisolated enum BrowserTab: String, CaseIterable, Identifiable, Sendable {
    case merge
    case consolidate
    case cleanup

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .merge: return "Merge"
        case .consolidate: return "Consolidate"
        case .cleanup: return "Cleanup"
        }
    }
}

// MARK: - scalar-exact comparison (display-side mirror)

/// Unicode-scalar-exact string equality — the display-side mirror of the
/// package's internal scalar discipline. Never `String ==` on gate
/// comparisons: canonical equivalence would accept NFC/NFD-drifted text.
nonisolated func scalarExact(_ lhs: String, _ rhs: String) -> Bool {
    lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
}

// MARK: - omission classification

/// The two omission classes the live merges surfaced (progress.md, Soka
/// Varios / SGI Artists / Trance 2022):
/// - `identicalLibraryTrack`: the omitted occurrence is field-identical to
///   the winner in every field except its position (`sourceIndex`) — the
///   same library track appearing again, the safe bulk of merge omissions.
/// - `distinctLibraryEntries`: ANY other field differs (persistent ID,
///   database ID, or any metadata/quality field) — the Gamemaster /
///   Lotus-Sutra / Howard-Jones class where a genuinely distinct library
///   entry is being dropped from the output and a human should look.
nonisolated enum OmissionClass: Equatable, Sendable {
    case identicalLibraryTrack
    case distinctLibraryEntries
}

/// Classify one omitted occurrence against its winner. Field-identity is
/// scalar-exact on every field except `sourceIndex` (which necessarily
/// differs between two occurrences). Note the SGI Artists precedent: two
/// catalog-duplicate entries with identical quality fields but different
/// persistent IDs are DISTINCT entries — identity fields participate.
nonisolated func omissionClass(winner: TrackSnapshot, omitted: TrackSnapshot) -> OmissionClass {
    let identical = winner.databaseId == omitted.databaseId
        && scalarExact(winner.persistentId, omitted.persistentId)
        && scalarExact(winner.title, omitted.title)
        && scalarExact(winner.artist, omitted.artist)
        && scalarExact(winner.album, omitted.album)
        && winner.durationMs == omitted.durationMs
        && scalarExact(winner.kind, omitted.kind)
        && winner.bitRateKbps == omitted.bitRateKbps
        && winner.sampleRateHz == omitted.sampleRateHz
        && scalarExact(winner.cloudStatus, omitted.cloudStatus)
        && winner.isFileTrack == omitted.isFileTrack
    return identical ? .identicalLibraryTrack : .distinctLibraryEntries
}

/// One omitted occurrence with its decisive reason and classification.
nonisolated struct OmittedDisplay: Identifiable, Sendable {
    let track: TrackSnapshot
    let reason: String
    let classification: OmissionClass

    var id: Int { track.sourceIndex }
}

/// One duplicate decision prepared for rendering: the winner plus every
/// omitted occurrence with reason and class.
nonisolated struct DecisionDisplay: Identifiable, Sendable {
    let decision: DuplicateDecision
    let omitted: [OmittedDisplay]

    var id: Int { decision.firstSourceIndex }
    var winner: TrackSnapshot { decision.winner }
    var hasDistinctEntries: Bool {
        omitted.contains { $0.classification == .distinctLibraryEntries }
    }
}

/// Prepare decision displays from a canonical plan's decisions. The reason
/// mapping mirrors the reference's `dict(reason_by_omitted_index)` (later
/// duplicate keys win); canonical plans always carry a total mapping, and the
/// defensive fallback never crashes the renderer.
nonisolated func decisionDisplays(_ decisions: [DuplicateDecision]) -> [DecisionDisplay] {
    decisions.map { decision in
        let reasons = Dictionary(
            decision.reasonByOmittedIndex.map { ($0.sourceIndex, $0.reason) },
            uniquingKeysWith: { _, last in last }
        )
        return DecisionDisplay(
            decision: decision,
            omitted: decision.omitted.map { track in
                OmittedDisplay(
                    track: track,
                    reason: reasons[track.sourceIndex] ?? "(reason missing)",
                    classification: omissionClass(winner: decision.winner, omitted: track)
                )
            }
        )
    }
}

/// The flattened distinct-library-entries subset — the part of the plan the
/// human is actually reviewing for, surfaced at the top of screen 2.
nonisolated func distinctOmissions(_ displays: [DecisionDisplay]) -> [OmittedDisplay] {
    displays.flatMap { display in
        display.omitted.filter { $0.classification == .distinctLibraryEntries }
    }
}

// MARK: - merge per-copy provenance

/// Review data per source copy, modeled on the controller reviews of the
/// live merges: how many output tracks originate in the copy, and how many
/// output tracks would be LOST without it (their whole duplicate group lives
/// in this one copy).
nonisolated struct CopyProvenanceSummary: Identifiable, Equatable, Sendable {
    /// 0-based, matching the artifacts' copy ordinals (summary.md "Copy 0",
    /// detail.csv `source_copy_ordinal`).
    let ordinal: Int
    let persistentId: String
    let trackCount: Int
    let outputTrackCount: Int
    let uniqueContributionCount: Int

    var id: Int { ordinal }
}

/// Map a combined source index to the ordinal of the copy containing it,
/// using `MergePlan.copyBoundaries` (cumulative counts).
nonisolated func copyOrdinal(forCombinedIndex index: Int, boundaries: [Int]) -> Int {
    for (ordinal, boundary) in boundaries.enumerated() where index < boundary {
        return ordinal
    }
    return max(boundaries.count - 1, 0)
}

/// Derive the per-copy provenance summary from a canonical merge plan.
nonisolated func copyProvenance(_ plan: MergePlan) -> [CopyProvenanceSummary] {
    let boundaries = plan.copyBoundaries
    var decisionByWinnerIndex: [Int: DuplicateDecision] = [:]
    for decision in plan.decisions {
        decisionByWinnerIndex[decision.winner.sourceIndex] = decision
    }

    var outputCounts = Array(repeating: 0, count: plan.copies.count)
    var uniqueCounts = Array(repeating: 0, count: plan.copies.count)
    for winnerIndex in plan.winnerSourceIndexes {
        let origin = copyOrdinal(forCombinedIndex: winnerIndex, boundaries: boundaries)
        if outputCounts.indices.contains(origin) {
            outputCounts[origin] += 1
        }
        // The whole group's member indexes: the winner plus every omitted
        // occurrence; a winner with no decision is a singleton group.
        var memberIndexes = [winnerIndex]
        if let decision = decisionByWinnerIndex[winnerIndex] {
            memberIndexes.append(contentsOf: decision.omitted.map(\.sourceIndex))
        }
        let memberCopies = Set(
            memberIndexes.map { copyOrdinal(forCombinedIndex: $0, boundaries: boundaries) }
        )
        if memberCopies.count == 1, let only = memberCopies.first,
           uniqueCounts.indices.contains(only) {
            uniqueCounts[only] += 1
        }
    }

    return plan.copies.enumerated().map { ordinal, copy in
        CopyProvenanceSummary(
            ordinal: ordinal,
            persistentId: copy.persistentId,
            trackCount: copy.tracks.count,
            outputTrackCount: outputCounts[ordinal],
            uniqueContributionCount: uniqueCounts[ordinal]
        )
    }
}

// MARK: - target names and the hand-off command (cli.py parity)

/// The exact CLI target-name conventions (cli.py:76 and cli.py:138):
/// `f"{name} — Consolidated"` / `f"{name} — Merged"` (em dash, spaces).
nonisolated func defaultTargetName(mode: ConsolidatorMode, sourceName: String) -> String {
    switch mode {
    case .consolidate: return "\(sourceName) \u{2014} Consolidated"
    case .merge: return "\(sourceName) \u{2014} Merged"
    }
}

/// Python `shlex.quote` ported at the Unicode-scalar level: unchanged when
/// every scalar is in the ASCII-safe set `[A-Za-z0-9_@%+=:,./-]` (shlex's
/// `_find_unsafe` under `re.ASCII` — any non-ASCII scalar is unsafe), else
/// single-quoted with embedded single quotes rendered as `'"'"'`; the empty
/// string quotes to `''`. Pinned against python3 shlex.quote (2026-08-01).
nonisolated func shlexQuote(_ value: String) -> String {
    if value.isEmpty { return "''" }
    let allSafe = value.unicodeScalars.allSatisfy { scalar in
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9",
             "_", "@", "%", "+", "=", ":", ",", ".", "/", "-":
            return true
        default:
            return false
        }
    }
    if allSafe { return value }
    var quoted = "'"
    for scalar in value.unicodeScalars {
        if scalar == "'" {
            quoted += "'\"'\"'"
        } else {
            quoted.unicodeScalars.append(scalar)
        }
    }
    return quoted + "'"
}

/// The exact copyable command the CLI audit prints (cli.py:77-82 and
/// cli.py:139-144). Runnable from the project root, like the CLI's own
/// output.
nonisolated func applyCommandText(
    mode: ConsolidatorMode,
    planJsonPath: String,
    targetName: String
) -> String {
    let subcommand = mode == .consolidate ? "apply" : "merge-apply"
    return "python3 scripts/apple_music_consolidate.py \(subcommand) "
        + "--plan \(shlexQuote(planJsonPath)) "
        + "--target-name \(shlexQuote(targetName)) "
        + "--confirm-create"
}

/// The CLI's expected-count preamble above the copyable command (cli.py:83-87
/// and cli.py:145-149) — the guarantees the operator re-checks at apply time.
nonisolated func handoffPreamble(mode: ConsolidatorMode, inputCount: Int, outputCount: Int) -> String {
    switch mode {
    case .consolidate:
        return "Copyable apply command "
            + "(expected input count: \(inputCount); expected output count: \(outputCount)):"
    case .merge:
        return "Copyable merge-apply command "
            + "(expected combined input count: \(inputCount); expected output count: \(outputCount)):"
    }
}

// MARK: - display formatting

/// "m:ss.mmm (N ms)" for a plan duration; an em dash when absent. The exact
/// millisecond value is always visible because the strict duplicate key uses
/// EXACT rounded milliseconds (the Gamemaster 1-second delta was decisive).
nonisolated func formattedDuration(ms: Int?) -> String {
    guard let ms else { return "\u{2014}" }
    let totalSeconds = ms / 1000
    let millis = ms % 1000
    return String(format: "%d:%02d.%03d (%d ms)", totalSeconds / 60, totalSeconds % 60, millis, ms)
}

/// Quality badges for one track: Unavailable / Lossless per the resolver's
/// own public predicates, plus the sample-rate and bit-rate values the
/// winner preference ranks on.
nonisolated func qualityBadges(_ track: TrackSnapshot) -> [String] {
    var badges: [String] = []
    if !isAvailable(track) { badges.append("Unavailable") }
    if isLossless(track) { badges.append("Lossless") }
    if let sampleRate = track.sampleRateHz { badges.append("\(sampleRate) Hz") }
    if let bitRate = track.bitRateKbps { badges.append("\(bitRate) kbps") }
    return badges
}

/// Basename of an artifact path without URL path APIs (which NFD-decompose;
/// see Persistence.swift's joinedPath note).
nonisolated func artifactBasename(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
}
