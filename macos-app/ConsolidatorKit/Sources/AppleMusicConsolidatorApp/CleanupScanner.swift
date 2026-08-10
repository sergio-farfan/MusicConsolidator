// CleanupScanner.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// B3 post-merge cleanup discovery: candidate groups come from EVIDENCE
// (reports/ merge-plan artifacts loaded through the same fail-closed
// loadMergePlan gate as apply), never guesswork. scan() applies candidacy
// rules 1-4 against ONE listing read (listing-only, no per-track live data);
// the full ordered-track re-verification lives in armVerification, run only
// at gate-arm for one group at a time. All live Music access is injected as
// closures (one listPlaylists closure here) so tests run on fixtures and
// this file never talks to OSA.

import Foundation
import ConsolidatorCore
import MusicBridge

// MARK: - contract types (Wave B contract, fixed)

struct CleanupCopyStatus: Equatable {
    let persistentID: String
    let name: String
    let trackCount: Int
    let disposition: Disposition
    enum Disposition: Equatable { case live, alreadyDeleted, drifted(String) }
}

struct CleanupCandidate: Equatable, Identifiable {
    let groupName: String
    let planFileName: String       // basename
    let targetName: String
    /// True when the target name exists exactly once in the live listing
    /// (scalar-exact name match); this is NOT the ordered-database-ID/
    /// persistent-ID verification — that happens only at gate-arm, via
    /// `armVerification` (called from `AuditFlowModel.armCleanupGroup`).
    let targetPresent: Bool
    let copies: [CleanupCopyStatus]
    let disqualification: String?  // nil == candidate; else shown reason
    var id: String { planFileName }
}

/// One discovered merge-plan group, pre-candidacy: the newest strict-loaded
/// MergePlan per copies'-persistent-ID set plus the resolved target name.
struct DiscoveredMergeGroup: Equatable {
    let groupName: String
    let planFileName: String
    let planFileNames: [String]
    let plan: MergePlan
    let targetName: String
}

// MARK: - basename helpers (pure; the Persistence naming scheme)

/// Scalar-lexicographic ordering (never String < on evidence-bearing names;
/// canonical equivalence must not reorder or merge distinct basenames).
private nonisolated func cleanupScalarLess(_ lhs: String, _ rhs: String) -> Bool {
    lhs.unicodeScalars.map(\.value)
        .lexicographicallyPrecedes(rhs.unicodeScalars.map(\.value))
}

/// Parse the writeMergeAudit basename stamp:
/// "<slug>-<yyyyMMdd-HHmmssZ>[-N].plan.json" (Persistence.swift
/// timestampStamp + reservePaths; "Z" is "+HHMM"/"-HHMM", "-N" the
/// same-second rerun suffix). Unparseable -> (.distantPast, -1): such a file
/// can never outrank a properly stamped artifact.
private nonisolated func planArtifactStamp(_ fileName: String) -> (date: Date, rerun: Int) {
    let pattern = "-([0-9]{8}-[0-9]{6}[+-][0-9]{4})(?:-([0-9]+))?\\.plan\\.json$"
    let regex = try! NSRegularExpression(pattern: pattern)
    let fullRange = NSRange(fileName.startIndex..., in: fileName)
    guard let match = regex.firstMatch(in: fileName, range: fullRange),
          let stampRange = Range(match.range(at: 1), in: fileName) else {
        return (.distantPast, -1)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyyMMdd-HHmmssZ"
    guard let date = formatter.date(from: String(fileName[stampRange])) else {
        return (.distantPast, -1)
    }
    var rerun = 0
    if let rerunRange = Range(match.range(at: 2), in: fileName),
       let parsed = Int(fileName[rerunRange]) {
        rerun = parsed
    }
    return (date, rerun)
}

/// Strict "older than" over plan basenames: stamp date, then rerun suffix,
/// then scalar-lexicographic basename (total and deterministic).
private nonisolated func planArtifactPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    let left = planArtifactStamp(lhs)
    let right = planArtifactStamp(rhs)
    if left.date != right.date { return left.date < right.date }
    if left.rerun != right.rerun { return left.rerun < right.rerun }
    return cleanupScalarLess(lhs, rhs)
}

/// Join a basename onto the reports directory WITHOUT URL path APIs (which
/// NFD-decompose precomposed characters; see Persistence.swift joinedPath).
private nonisolated func joinedReportPath(_ directoryPath: String, _ name: String) -> String {
    directoryPath.hasSuffix("/") ? directoryPath + name : directoryPath + "/" + name
}

// MARK: - run-report record parsing (RunReport.swift renderRunReportText shape)

/// "- Created: <targetName> (<n> tracks)" -> targetName. Parsed from the END
/// so target names containing " (" survive; the count segment must be all
/// digits or the line is not a Created record.
private nonisolated func parseCreatedTargetName(_ line: String) -> String? {
    let prefix = "- Created: "
    let suffix = " tracks)"
    guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
    let body = line.dropFirst(prefix.count)
    guard let open = body.range(of: " (", options: .backwards) else { return nil }
    let countPart = body[open.upperBound...].dropLast(suffix.count)
    guard !countPart.isEmpty,
          countPart.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else {
        return nil
    }
    return String(body[..<open.lowerBound])
}

/// Find the first applied record in one run-report text whose
/// "- Plan artifact:" basename scalar-equals any of the group's plan
/// basenames; return its Created target name.
private nonisolated func recordTargetName(
    in reportText: String,
    planFileNames: [String]
) -> String? {
    var created: String?
    var matchesPlan = false
    for rawLine in reportText.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        if line.hasPrefix("## ") {
            if matchesPlan, let created { return created }
            created = nil
            matchesPlan = false
        } else if let name = parseCreatedTargetName(line) {
            created = name
        } else if line.hasPrefix("- Plan artifact: ") {
            let basename = String(line.dropFirst("- Plan artifact: ".count))
            if planFileNames.contains(where: { scalarExact($0, basename) }) {
                matchesPlan = true
            }
        }
    }
    if matchesPlan, let created { return created }
    return nil
}

// MARK: - candidacy helpers (pure)

/// B4 refusal list, fixed by contract: the pilot source and its verified
/// target are retained as contract evidence and are never cleanup material.
private nonisolated let protectedPilotNames = [
    "#Musica xTotal",
    "#Musica xTotal \u{2014} Consolidated",
]
private nonisolated let protectedPilotPersistentIDs = [
    "E02030832FD20B07",
    "61EC0FC6E0F1C250",
]

/// Rule 2 copy revalidation — track IDENTITY only (name, count, ordered
/// track persistent IDs), deliberately NOT the full 11-field payload:
/// databaseId, cloudStatus, bit rate, sample rate drift on their own and do
/// not change membership. Returns nil on a match; else the drift reason.
private nonisolated func copyDriftReason(
    planCopy: PlaylistSnapshot,
    live: PlaylistSnapshot
) -> String? {
    if !scalarExact(live.name, planCopy.name) {
        return "name changed from \"\(planCopy.name)\" to \"\(live.name)\""
    }
    if live.tracks.count != planCopy.tracks.count {
        return "track count changed from \(planCopy.tracks.count) to \(live.tracks.count)"
    }
    for (index, planTrack) in planCopy.tracks.enumerated() {
        let livePID = live.tracks[index].persistentId
        if !scalarExact(planTrack.persistentId, livePID) {
            return "track \(index + 1) persistent ID changed from "
                + "\(planTrack.persistentId) to \(livePID)"
        }
    }
    return nil
}

/// One machine-readable result line: exactly "deleted-ok <persistentID>
/// <sha>" (three space-separated tokens). Returns (persistentID, sha) when
/// the line matches the format.
private nonisolated func parseDeletedOkLine(_ line: Substring) -> (persistentID: String, sha: String)? {
    let tokens = line.split(separator: " ")
    guard tokens.count == 3, scalarExact(String(tokens[0]), "deleted-ok") else {
        return nil
    }
    return (String(tokens[1]), String(tokens[2]))
}

// MARK: - the scanner

@MainActor
final class CleanupScanner {
    private let reportsDir: URL
    private let listPlaylists: () throws -> [PlaylistListing]

    init(
        reportsDir: URL,
        listPlaylists: @escaping () throws -> [PlaylistListing]
    ) {
        self.reportsDir = reportsDir
        self.listPlaylists = listPlaylists
    }

    /// Every basename in reports/, sorted ascending. Unreadable directory ->
    /// no evidence -> [] (the historyEntries posture, RunReport.swift).
    private var reportFileNames: [String] {
        let names = (try? FileManager.default
            .contentsOfDirectory(atPath: reportsDir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted(by: cleanupScalarLess)
    }

    private func reportText(_ fileName: String) -> String? {
        let path = joinedReportPath(reportsDir.path, fileName)
        return try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }

    /// B3 discovery: strict-loaded merge plans, grouped by their copies'
    /// persistent-ID set, newest plan per group, resolved target name.
    /// Disk-only — the live closures are never invoked here.
    func discoverGroups() -> [DiscoveredMergeGroup] {
        var decoded: [(fileName: String, plan: MergePlan)] = []
        for fileName in reportFileNames where fileName.hasSuffix(".plan.json") {
            let path = joinedReportPath(reportsDir.path, fileName)
            // loadMergePlan is the full fail-closed gate: StrictJSONScanner
            // pre-pass, exact-key decode, integrity recompute. ANY failure
            // means "not usable merge evidence" -> skipped silently.
            guard let plan = try? loadMergePlan(from: URL(fileURLWithPath: path)) else {
                continue
            }
            decoded.append((fileName, plan))
        }

        var keyOrder: [String] = []
        var groupsByKey: [String: [(fileName: String, plan: MergePlan)]] = [:]
        for entry in decoded {
            // Persistent IDs are the stable identity; the sorted set is the
            // group key (U+001F join, the house fingerprint separator).
            let key = entry.plan.copies.map(\.persistentId)
                .sorted(by: cleanupScalarLess)
                .joined(separator: "\u{1F}")
            if groupsByKey[key] == nil {
                keyOrder.append(key)
                groupsByKey[key] = [entry]
            } else {
                groupsByKey[key]!.append(entry)
            }
        }

        var groups: [DiscoveredMergeGroup] = []
        for key in keyOrder {
            let entries = groupsByKey[key]!
            let newest = entries.max { planArtifactPrecedes($0.fileName, $1.fileName) }!
            let planFileNames = entries.map(\.fileName)
            let groupName = newest.plan.mergedPlaylistSourceName
            groups.append(
                DiscoveredMergeGroup(
                    groupName: groupName,
                    planFileName: newest.fileName,
                    planFileNames: planFileNames,
                    plan: newest.plan,
                    targetName: resolvedTargetName(
                        groupName: groupName, planFileNames: planFileNames
                    )
                )
            )
        }
        return groups.sorted { cleanupScalarLess($0.planFileName, $1.planFileName) }
    }

    /// Newest run report first (the Run-yyyyMMdd-HHmmss prefix is
    /// lexicographically chronological); first matching applied record wins;
    /// no record -> the CLI "<Name> — Merged" convention.
    private func resolvedTargetName(groupName: String, planFileNames: [String]) -> String {
        let reportNames = reportFileNames
            .filter { $0.hasSuffix(".runreport.md") }
            .sorted { cleanupScalarLess($1, $0) }
        for reportName in reportNames {
            guard let text = reportText(reportName) else { continue }
            if let name = recordTargetName(in: text, planFileNames: planFileNames) {
                return name
            }
        }
        return defaultTargetName(mode: .merge, sourceName: groupName)
    }

    // MARK: - candidacy (B3 rules 1-4)

    /// Discovery + candidacy: one CleanupCandidate per discovered group,
    /// disqualified groups included (shown grayed with the reason), groups
    /// with zero remaining live copies dropped. Exactly ONE listing read
    /// total, regardless of group count — no per-track live reads happen
    /// here at all (that ordered-track re-verification moved to
    /// armVerification, run only at gate-arm for one group at a time).
    /// Live-closure failures propagate verbatim (fail-closed).
    func scan() throws -> [CleanupCandidate] {
        let listing = try listPlaylists()
        var candidates: [CleanupCandidate] = []
        for group in discoverGroups() {
            if let candidate = candidacy(for: group, listing: listing) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    private func candidacy(
        for group: DiscoveredMergeGroup,
        listing: [PlaylistListing]
    ) -> CleanupCandidate? {
        // Rule 4 first: hard exclusion, decided from the plan alone — no
        // live read is ever performed for the protected pilot group.
        if let reason = pilotExclusionReason(group) {
            let copies = group.plan.copies.map { copy in
                CleanupCopyStatus(
                    persistentID: copy.persistentId,
                    name: copy.name,
                    trackCount: copy.tracks.count,
                    disposition: .live
                )
            }
            return CleanupCandidate(
                groupName: group.groupName,
                planFileName: group.planFileName,
                targetName: group.targetName,
                targetPresent: false,
                copies: copies,
                disqualification: reason
            )
        }

        // Rule 1 (listing-level): the merged target exists exactly once in
        // the live listing by scalar-exact name. This is presence only, not
        // the ordered database-ID/persistent-ID trust standard — that fresh
        // re-verification happens only at gate-arm (armVerification below).
        var targetPresent = false
        var rule1Reason: String?
        let targets = listing.filter { scalarExact($0.name, group.targetName) }
        if targets.isEmpty {
            rule1Reason = "target absent from the live listing: \"\(group.targetName)\""
        } else if targets.count > 1 {
            rule1Reason = "multiple live playlists named "
                + "\"\(group.targetName)\" (\(targets.count))"
        } else {
            targetPresent = true
        }

        let planPIDs = group.plan.copies.map(\.persistentId)

        // Rule 3: an unknown live playlist bearing the group's exact name
        // means the evidence no longer describes reality. The LISTING is the
        // widest net (it includes smart and special-kind playlists).
        var rule3Reason: String?
        for entry in listing {
            guard scalarExact(entry.name, group.groupName) else { continue }
            if !planPIDs.contains(where: { scalarExact($0, entry.persistentId) }) {
                rule3Reason = "live playlist with persistent ID "
                    + "\(entry.persistentId) bears the group name but is "
                    + "not in the plan"
                break
            }
        }

        // Rule 2 (listing-level): every plan copy accounted for by
        // persistent ID — present in the listing (live, full stop; the
        // per-track ordered-identity check moved to armVerification, which
        // structurally cannot run here since a listing has no per-track
        // data), or recorded deleted; anything else disqualifies.
        var rule2Reason: String?
        var statuses: [CleanupCopyStatus] = []
        var remainingLiveCount = 0
        for planCopy in group.plan.copies {
            let live = listing.first {
                scalarExact($0.persistentId, planCopy.persistentId)
            }
            let disposition: CleanupCopyStatus.Disposition
            let displayName: String
            let displayTrackCount: Int
            if let live {
                remainingLiveCount += 1
                disposition = .live
                displayName = live.name
                displayTrackCount = live.trackCount
            } else if hasRecordedDelete(persistentID: planCopy.persistentId) {
                disposition = .alreadyDeleted
                displayName = planCopy.name
                displayTrackCount = planCopy.tracks.count
            } else {
                let drift = "absent from the live library without a recorded delete"
                disposition = .drifted(drift)
                displayName = planCopy.name
                displayTrackCount = planCopy.tracks.count
                if rule2Reason == nil {
                    rule2Reason = "copy \(planCopy.persistentId) is "
                        + "absent without a recorded delete"
                }
            }
            statuses.append(
                CleanupCopyStatus(
                    persistentID: planCopy.persistentId,
                    name: displayName,
                    trackCount: displayTrackCount,
                    disposition: disposition
                )
            )
        }

        // Zero remaining live copies -> the group leaves the Cleanup tab.
        if remainingLiveCount == 0 { return nil }

        return CleanupCandidate(
            groupName: group.groupName,
            planFileName: group.planFileName,
            targetName: group.targetName,
            targetPresent: targetPresent,
            copies: statuses,
            disqualification: rule1Reason ?? rule2Reason ?? rule3Reason
        )
    }

    /// Full ordered-track re-verification for gate-arm, run against a live
    /// sample scoped to exactly this group's two names (groupName,
    /// targetName) plus a fresh full listing. This is the load-bearing check
    /// the old scan()-time candidacy used to do; scan() itself can no longer
    /// do it (no live-track reads at listing level). Returns the
    /// disqualification reason, or nil when the group is still armable.
    func armVerification(
        group: DiscoveredMergeGroup,
        listing: [PlaylistListing],
        groupLiveCopies: [PlaylistSnapshot],
        targetLiveCopies: [PlaylistSnapshot]
    ) throws -> String? {
        // Rule 1: exactly one target, ordered database IDs + persistent IDs + count, fresh.
        if targetLiveCopies.isEmpty {
            return "merged target \"\(group.targetName)\" was not found"
        }
        if targetLiveCopies.count > 1 {
            return "\(targetLiveCopies.count) playlists are named "
                + "\"\(group.targetName)\"; the merged target is ambiguous"
        }
        let result = try verifyMergeOutput(plan: group.plan, actual: targetLiveCopies[0])
        if !result.verificationOk {
            let first = result.mismatches.first ?? "no mismatch detail"
            return "merged target failed fresh verification: \(first)"
        }

        // Rule 3: unknown same-name PID, over the FULL fresh listing (unchanged wording).
        let planPIDs = group.plan.copies.map(\.persistentId)
        for entry in listing where scalarExact(entry.name, group.groupName) {
            if !planPIDs.contains(where: { scalarExact($0, entry.persistentId) }) {
                return "live playlist with persistent ID \(entry.persistentId) bears the "
                    + "group name but is not in the plan"
            }
        }

        // Rule 2: per-copy identity drift (name/count/ordered track PIDs) for copies still live.
        for planCopy in group.plan.copies {
            guard let live = groupLiveCopies.first(
                where: { scalarExact($0.persistentId, planCopy.persistentId) }
            ) else {
                // Present in the listing (by PID) but absent from the
                // name-scoped snapshot means it's still live, just no longer
                // named the group's exact name -- a rename, not a vanish.
                // Absent-from-the-listing entirely is a DIFFERENT case
                // already caught by the listing-level scan()'s Rule 2, so
                // this copy reaching armVerification at all already implies
                // listing presence.
                if listing.contains(where: { scalarExact($0.persistentId, planCopy.persistentId) }) {
                    return "copy \(planCopy.persistentId) no longer bears the group "
                        + "name \"\(group.groupName)\""
                }
                continue
            }
            if let drift = copyDriftReason(planCopy: planCopy, live: live) {
                return "copy \(planCopy.persistentId) drifted: \(drift)"
            }
        }
        return nil
    }

    private func pilotExclusionReason(_ group: DiscoveredMergeGroup) -> String? {
        for name in protectedPilotNames {
            if scalarExact(group.groupName, name) || scalarExact(group.targetName, name) {
                return "excluded by contract: #Musica xTotal pilot evidence "
                    + "(protected name \"\(name)\")"
            }
        }
        for copy in group.plan.copies {
            for pid in protectedPilotPersistentIDs
            where scalarExact(copy.persistentId, pid) {
                return "excluded by contract: #Musica xTotal pilot evidence "
                    + "(protected persistent ID \(pid))"
            }
        }
        return nil
    }

    /// Recorded-delete accounting for an absent copy (fix round 1, CRITICAL
    /// fail-open closed): a "deleted-ok <PID> <sha>" line in any
    /// .mutationresult.md is never trusted on its own. The claimed sha must
    /// be the RECOMPUTED SHA-256 of an actual *.delete.plan.json artifact in
    /// reports/ whose decoded `kind` is `.delete` and whose
    /// `playlistPersistentID` scalar-equals the SAME persistent ID being
    /// accounted, and that exact artifact must itself be consumed. This
    /// mirrors the codebase's recompute-never-trust discipline (see
    /// `validateMergePlanIntegrity`): the sha is never read from a sidecar
    /// and trusted as-is, only ever recomputed from the plan bytes and
    /// compared. Without this, a deleted-ok line could cite ANY other
    /// consumed plan's sha (even a rename's) and wrongly classify a
    /// genuinely-unaccounted absent copy as `.alreadyDeleted`.
    private func hasRecordedDelete(persistentID: String) -> Bool {
        for fileName in reportFileNames where fileName.hasSuffix(".mutationresult.md") {
            guard let text = reportText(fileName) else { continue }
            for line in text.split(separator: "\n") {
                guard let record = parseDeletedOkLine(line),
                      scalarExact(record.persistentID, persistentID) else {
                    continue
                }
                if backingConsumedDeletePlanExists(persistentID: persistentID, sha: record.sha) {
                    return true
                }
            }
        }
        return false
    }

    /// A *.delete.plan.json artifact, strictly loaded via `loadMutationPlan`,
    /// whose decoded `kind` is `.delete`, whose `playlistPersistentID`
    /// scalar-equals `persistentID`, whose RECOMPUTED `sha256Hex()`
    /// scalar-equals `sha` (never the sha claimed by the result line, never
    /// read from any sidecar), and which is itself marked consumed at that
    /// same artifact path.
    private func backingConsumedDeletePlanExists(persistentID: String, sha: String) -> Bool {
        for fileName in reportFileNames where fileName.hasSuffix(".delete.plan.json") {
            let planURL = URL(fileURLWithPath: joinedReportPath(reportsDir.path, fileName))
            guard let plan = try? loadMutationPlan(url: planURL) else { continue }
            guard case .delete = plan.kind,
                  scalarExact(plan.playlistPersistentID, persistentID),
                  scalarExact(plan.sha256Hex(), sha) else {
                continue
            }
            if isMutationPlanConsumed(planURL: planURL) { return true }
        }
        return false
    }
}
