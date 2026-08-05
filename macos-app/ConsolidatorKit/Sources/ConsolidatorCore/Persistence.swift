// Persistence.swift
// Swift port of the PERSISTENCE half of apple_music_consolidator/audit.py:
// artifact renderers (write_json / write_csv / write_markdown and the merge
// variants), the atomic no-overwrite path reservation (_reserve_paths), the
// artifact writers (write_audit / write_merge_audit), and the fail-closed
// loaders (load_plan / load_merge_plan). The validation half lives in
// PlanIntegrity.swift (M2) and is REUSED here, not duplicated.
//
// Every behavioral detail is ported from audit.py (line references below).
// Three deliberate, pinned deviations:
//
// 1. Artifact naming for dot-containing slugs. The reference derives artifact
//    paths with Path.with_suffix (audit.py:36-41), which REPLACES the last
//    dot-suffix of the prefix. For a slug containing a dot (slugify keeps
//    interior dots, audit.py:30-33) this truncates the stem — e.g. playlist
//    "Mix.2022" yields "Mix.plan.json", dropping slug remainder AND timestamp
//    — and because every "-N" suffixed candidate collapses to the same
//    truncated name, the reference's reservation loop (audit.py:44-66) LIVELOCKS
//    on the second write_audit for such names (verified empirically against
//    the reference, 2026-07-31). That breaks the AGENTS.md contract that new
//    runs always create newly named files. The Swift port APPENDS the
//    artifact suffixes to the full prefix instead; artifact BASENAMES are
//    scalar-identical to the reference's for every dot-free slug (all realistic
//    names and every reference test), and dotted slugs keep the full stem and
//    never overwrite. Basenames are joined onto the directory path with
//    plain string concatenation — URL path APIs convert precomposed
//    characters to NFD ("Café" -> "Cafe" + U+0301), which would change the
//    persisted names (fix round 1, finding 2). The DIRECTORY component
//    follows the caller's (standardized) URL and is not re-normalized.
//    SIGNED OFF by Sergio Farfan 2026-08-01: keep the Swift behavior.
//    REFERENCE FIXED 2026-08-01 per Sergio's direction: audit.py _paths_for now
//    also APPENDS the artifact suffixes (the Swift behavior, which originated
//    here as a deviation, was upstreamed into the reference). Artifact naming is
//    now byte-identical across the two implementations for ALL slugs — the
//    dotted-slug divergence is zero (naming parity probe 2026-08-01: 15
//    hostile names incl. dotted/unicode/rerun-collision cases, audit + merge
//    writers, byte-identical). This block is retained as accurate history.
//
// 2. Loader error typing. The reference raises ValueError for both decode and
//    integrity failures; the Swift loaders surface four DISTINCT
//    message-bearing classes (file unreadable / malformed JSON / decode
//    rejected / integrity rejected) via PlanLoadError, per the M3 brief.
//
// 3. Duplicate JSON object keys are rejected OUTRIGHT at any nesting level
//    (fix round 1, finding 1). Python's json.loads silently keeps the LAST
//    duplicate, so the reference accepts a document whose tampered FIRST value
//    is shadowed by a canonical second; JSONSerialization keeps the FIRST,
//    which inverted the tampering direction into a fail-open. Outright
//    rejection is the sanctioned strict direction and removes the ambiguity
//    entirely. The same strict gate rejects NaN/Infinity tokens and lone
//    surrogate escapes at the syntax level, where the reference parses them and
//    rejects (or crashes on) the resulting float/unencodable value later —
//    same accept/reject outcome, earlier and cleaner failure.
//
// BINDING item closed here: Python's `type(value) is int` (models.py:40-43)
// rejects integral JSON floats such as 183000.0 wherever an integer is
// required; Swift's JSONDecoder would silently accept them. The loaders run a
// raw-token-level pre-pass (JSONSerialization + float-type inspection) that
// rejects ANY float-typed number token in a plan document. Every number
// position in both plan schemas is integer-typed (or a string/bool position,
// where the reference rejects numbers outright), so the accept/reject set
// matches the reference's exactly for 64-bit-representable integers.

import Darwin
import Foundation

// MARK: - Errors

/// Thrown when creating or writing an artifact file fails (the reference lets
/// the underlying OSError escape from `write_audit`).
public struct PersistenceWriteError: Error, Equatable, CustomStringConvertible {
    public let path: String
    public let detail: String

    public init(path: String, detail: String) {
        self.path = path
        self.detail = detail
    }

    public var description: String { "audit artifact write failed at \(path): \(detail)" }
}

/// The distinct fail-closed failure classes of `loadPlan` / `loadMergePlan`.
/// Reference equivalents: FileNotFoundError/OSError, json.JSONDecodeError,
/// ValueError from `from_dict`, ValueError from the integrity validators.
public enum PlanLoadError: Error, CustomStringConvertible {
    case fileUnreadable(path: String, detail: String)
    case malformedJSON(path: String, detail: String)
    case decodeRejected(detail: String)
    case integrityRejected(detail: String)

    public var description: String {
        switch self {
        case .fileUnreadable(let path, let detail):
            return "plan file is unreadable at \(path): \(detail)"
        case .malformedJSON(let path, let detail):
            return "plan file at \(path) is not valid JSON: \(detail)"
        case .decodeRejected(let detail):
            return detail
        case .integrityRejected(let detail):
            return detail
        }
    }
}

// MARK: - slugify

/// True where Python's Unicode `\w` matches: `_`, general category L*
/// (Lu/Ll/Lt/Lm/Lo), or any numeric-typed scalar (CPython's
/// isdecimal/isdigit/isnumeric union). Deliberately NOT Unicode `Alphabetic`,
/// which would wrongly admit Other_Alphabetic marks like U+0345 that the
/// reference replaces (verified empirically against python3 re, 2026-07-31).
private func isPythonWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    if scalar == "_" { return true }
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
        return true
    default:
        return scalar.properties.numericType != nil
    }
}

/// Return a filesystem-safe, non-empty name derived from a playlist name.
/// Reference: audit.py:30-33 — `re.sub(r"[^\w.-]+", "-", value.strip())` then
/// `.strip(".-") or "playlist"`. Runs of non-word characters collapse to one
/// dash; a trailing run's dash is never materialized because `strip(".-")`
/// would remove it anyway.
public func slugify(_ value: String) -> String {
    var kept: [Unicode.Scalar] = []
    var pendingDash = false
    for scalar in trimPythonWhitespace(value).unicodeScalars {
        if isPythonWordScalar(scalar) || scalar == "." || scalar == "-" {
            if pendingDash {
                kept.append("-")
                pendingDash = false
            }
            kept.append(scalar)
        } else {
            pendingDash = true
        }
    }
    var start = 0
    var end = kept.count
    while start < end, kept[start] == "." || kept[start] == "-" { start += 1 }
    while end > start, kept[end - 1] == "." || kept[end - 1] == "-" { end -= 1 }
    if start >= end { return "playlist" }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: kept[start..<end])
    return String(view)
}

// MARK: - CSV rendering (Python csv "excel" dialect, QUOTE_MINIMAL)

/// Quote when the field contains the delimiter, the quote character, or a
/// line-terminator character; escape quotes by doubling. Scalar-level checks
/// mirror Python's per-code-point behavior (Swift grapheme matching would
/// miss "\n" inside "\r\n" and quotes carrying combining marks).
private func csvEscaped(_ field: String) -> String {
    let needsQuoting = field.unicodeScalars.contains {
        $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n"
    }
    guard needsQuoting else { return field }
    var out = String.UnicodeScalarView()
    out.append("\"")
    for scalar in field.unicodeScalars {
        if scalar == "\"" {
            out.append("\"")
            out.append("\"")
        } else {
            out.append(scalar)
        }
    }
    out.append("\"")
    return String(out)
}

/// One CSV record, CRLF-terminated like Python csv's default lineterminator.
private func csvRow(_ fields: [String]) -> String {
    fields.map(csvEscaped).joined(separator: ",") + "\r\n"
}

private func pythonBool(_ value: Bool) -> String { value ? "True" : "False" }

private func optionalInt(_ value: Int?) -> String {
    value.map(String.init) ?? ""
}

/// The 12 per-track values in TrackSnapshot.to_dict() order, rendered the way
/// Python csv renders them (None -> empty, bools -> True/False).
private func trackCSVFields(_ track: TrackSnapshot) -> [String] {
    [
        String(track.sourceIndex),
        String(track.databaseId),
        track.persistentId,
        track.title,
        track.artist,
        track.album,
        optionalInt(track.durationMs),
        track.kind,
        optionalInt(track.bitRateKbps),
        optionalInt(track.sampleRateHz),
        track.cloudStatus,
        pythonBool(track.isFileTrack),
    ]
}

/// audit.py:80-89 — the shared source_*/winner_*/action/reason column set.
private let trackProvenanceFieldnames: [String] = [
    "source_source_index", "source_database_id", "source_persistent_id",
    "source_title", "source_artist", "source_album", "source_duration_ms",
    "source_kind", "source_bit_rate_kbps", "source_sample_rate_hz",
    "source_cloud_status", "source_is_file_track",
    "winner_source_index", "winner_database_id", "winner_persistent_id",
    "winner_title", "winner_artist", "winner_album", "winner_duration_ms",
    "winner_kind", "winner_bit_rate_kbps", "winner_sample_rate_hz",
    "winner_cloud_status", "winner_is_file_track", "action", "reason",
]

/// audit.py:379-382 — the merge CSV's leading copy-provenance columns.
private let mergeProvenanceFieldnames: [String] = [
    "source_copy_ordinal", "source_copy_persistent_id", "source_copy_within_index",
]

/// The action/reason classification shared by both CSV writers
/// (audit.py:93-121 and audit.py:397-416).
private struct ProvenanceIndex {
    let omittedRows: [Int: (winner: TrackSnapshot, reason: String)]
    let duplicateWinnerIndexes: Set<Int>
    let nonEligibleIndexes: Set<Int>

    init(decisions: [DuplicateDecision], nonEligibleSourceIndexes: [Int]) {
        var omittedRows: [Int: (winner: TrackSnapshot, reason: String)] = [:]
        var duplicateWinnerIndexes: Set<Int> = []
        for decision in decisions {
            duplicateWinnerIndexes.insert(decision.winner.sourceIndex)
            let reasons = reasonsByIndex(decision)
            for omitted in decision.omitted {
                // Python indexes `reasons[omitted.source_index]` and would
                // raise KeyError on a hole; plans reaching the writers are
                // canonical (buildPlan output), where the mapping is total.
                omittedRows[omitted.sourceIndex] = (decision.winner, reasons[omitted.sourceIndex]!)
            }
        }
        self.omittedRows = omittedRows
        self.duplicateWinnerIndexes = duplicateWinnerIndexes
        self.nonEligibleIndexes = Set(nonEligibleSourceIndexes)
    }

    func classify(_ sourceTrack: TrackSnapshot) -> (winner: TrackSnapshot, action: String, reason: String) {
        let sourceIndex = sourceTrack.sourceIndex
        if let entry = omittedRows[sourceIndex] {
            return (entry.winner, "omitted duplicate", entry.reason)
        }
        if duplicateWinnerIndexes.contains(sourceIndex) {
            return (sourceTrack, "retained duplicate winner", "selected duplicate winner")
        }
        if nonEligibleIndexes.contains(sourceIndex) {
            return (sourceTrack, "retained non-eligible", "non-eligible; retained unchanged")
        }
        return (sourceTrack, "retained unique", "unique")
    }
}

/// Python `dict(decision.reason_by_omitted_index)`: later duplicate keys win.
private func reasonsByIndex(_ decision: DuplicateDecision) -> [Int: String] {
    Dictionary(
        decision.reasonByOmittedIndex.map { ($0.sourceIndex, $0.reason) },
        uniquingKeysWith: { _, last in last }
    )
}

/// Render one provenance row for every ordered source occurrence.
/// Reference: audit.py:78-126 (`write_csv`).
public func renderDetailCSV(_ plan: ConsolidationPlan) -> String {
    var out = csvRow(trackProvenanceFieldnames)
    let index = ProvenanceIndex(
        decisions: plan.decisions,
        nonEligibleSourceIndexes: plan.nonEligibleSourceIndexes
    )
    for sourceTrack in plan.sourceTracks {
        let (winner, action, reason) = index.classify(sourceTrack)
        out += csvRow(trackCSVFields(sourceTrack) + trackCSVFields(winner) + [action, reason])
    }
    return out
}

/// Render one provenance row per ordered source occurrence across copies.
/// Reference: audit.py:366-427 (`_copy_of_index` + `write_merge_csv`).
public func renderMergeDetailCSV(_ plan: MergePlan) -> String {
    var out = csvRow(mergeProvenanceFieldnames + trackProvenanceFieldnames)
    let index = ProvenanceIndex(
        decisions: plan.decisions,
        nonEligibleSourceIndexes: plan.nonEligibleSourceIndexes
    )
    // Map each combined index to (copy_ordinal, copy_persistent_id, within_pos).
    var origin: [Int: (ordinal: Int, copyPersistentId: String, withinPosition: Int)] = [:]
    var combinedIndex = 0
    for (ordinal, copy) in plan.copies.enumerated() {
        for withinPosition in copy.tracks.indices {
            origin[combinedIndex] = (ordinal, copy.persistentId, withinPosition)
            combinedIndex += 1
        }
    }
    for sourceTrack in plan.combinedTracks {
        let (winner, action, reason) = index.classify(sourceTrack)
        let provenance = origin[sourceTrack.sourceIndex]!
        out += csvRow(
            [String(provenance.ordinal), provenance.copyPersistentId, String(provenance.withinPosition)]
                + trackCSVFields(sourceTrack) + trackCSVFields(winner) + [action, reason]
        )
    }
    return out
}

// MARK: - Markdown rendering

/// audit.py:129-130 — `_unavailable` is the negation of the resolver's
/// availability check (identical strip/casefold comparison).
private func isUnavailable(_ track: TrackSnapshot) -> Bool {
    !isAvailable(track)
}

/// Render the human-reviewable Markdown summary of duplicate decisions.
/// Reference: audit.py:133-172 (`write_markdown`) — templates verbatim.
public func renderSummaryMarkdown(_ plan: ConsolidationPlan) -> String {
    let outputCount = plan.winnerSourceIndexes.count
    let omittedCount = plan.sourceTrackCount - outputCount
    var lines: [String] = [
        "# \(plan.sourcePlaylistName)",
        "",
        "- Playlist ID: `\(plan.sourcePlaylistPersistentId)`",
        "- Fingerprint: `\(plan.sourceFingerprint)`",
        "- Input count: \(plan.sourceTrackCount)",
        "- Output count: \(outputCount)",
        "- Omitted count: \(omittedCount)",
        "- Non-eligible count: \(plan.nonEligibleSourceIndexes.count)",
        "CSV accounts for every source occurrence: \(plan.sourceTrackCount) rows.",
        "",
        "## Duplicate decisions",
        "",
    ]
    if plan.decisions.isEmpty {
        lines.append("No duplicate decisions were required.")
    }
    for decision in plan.decisions {
        let winner = decision.winner
        lines.append("### Winner: \(winner.title) — \(winner.artist) (source index \(winner.sourceIndex))")
        lines.append("- Winner persistent ID: `\(winner.persistentId)`")
        lines.append("- Winner unavailable: \(pythonBool(isUnavailable(winner)))")
        let reasons = reasonsByIndex(decision)
        for omitted in decision.omitted {
            lines.append("- Omitted: \(omitted.title) — \(omitted.artist) (source index \(omitted.sourceIndex))")
            lines.append("  - Persistent ID: `\(omitted.persistentId)`")
            lines.append("  - Reason: \(reasons[omitted.sourceIndex]!)")
            lines.append("  - Unavailable: \(pythonBool(isUnavailable(omitted)))")
        }
        lines.append("")
    }
    return lines.joined(separator: "\n") + "\n"
}

/// Render the merge summary. Reference: audit.py:430-468 (`write_merge_markdown`).
public func renderMergeSummaryMarkdown(_ plan: MergePlan) -> String {
    let combinedCount = plan.combinedTrackCount
    let outputCount = plan.winnerSourceIndexes.count
    var lines: [String] = [
        "# \(plan.mergedPlaylistSourceName) — Merged",
        "",
        "- Merge fingerprint: `\(plan.mergeFingerprint)`",
        "- Copies: \(plan.copies.count)",
        "- Combined input count: \(combinedCount)",
        "- Output count: \(outputCount)",
        "- Omitted count: \(combinedCount - outputCount)",
        "- Non-eligible count: \(plan.nonEligibleSourceIndexes.count)",
        "",
        "## Source copies",
        "",
    ]
    for (ordinal, copy) in plan.copies.enumerated() {
        lines.append("- Copy \(ordinal): `\(copy.persistentId)` — \(copy.tracks.count) tracks")
    }
    lines.append(contentsOf: ["", "## Duplicate decisions", ""])
    if plan.decisions.isEmpty {
        lines.append("No duplicate decisions were required.")
    }
    for decision in plan.decisions {
        let winner = decision.winner
        lines.append("### Winner: \(winner.title) — \(winner.artist) (combined index \(winner.sourceIndex))")
        let reasons = reasonsByIndex(decision)
        for omitted in decision.omitted {
            lines.append(
                "- Omitted: \(omitted.title) — \(omitted.artist) "
                    + "(combined index \(omitted.sourceIndex)); reason: \(reasons[omitted.sourceIndex]!)"
            )
        }
        lines.append("")
    }
    return lines.joined(separator: "\n") + "\n"
}

// MARK: - Plan JSON rendering

/// Swift-canonical plan JSON (locked decision, aligned with the fingerprint
/// encoding in Resolver.swift): pretty-printed, sorted keys, unescaped
/// slashes and UTF-8 (matching the intent of the reference's ensure_ascii=False),
/// trailing newline like the reference's write_json (audit.py:73-75). SHAPE
/// matches the reference's output; bytes and fingerprint values are Swift-owned.
private func canonicalPlanJSONText<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    // Encoding these value types cannot fail: every field is
    // JSON-representable (no Double, no non-string dictionary keys).
    let data = try! encoder.encode(value)
    return String(decoding: data, as: UTF8.self) + "\n"
}

/// Reference: audit.py:73-75 (`write_json`).
public func renderPlanJSON(_ plan: ConsolidationPlan) -> String {
    canonicalPlanJSONText(plan)
}

/// Reference: audit.py:362-363 (`write_merge_json`).
public func renderMergePlanJSON(_ plan: MergePlan) -> String {
    canonicalPlanJSONText(plan)
}

// MARK: - Atomic reservation + artifact writing

private let planJSONSuffix = ".plan.json"
private let detailCSVSuffix = ".detail.csv"
private let summaryMarkdownSuffix = ".summary.md"
private let reservationSuffix = ".plan.reservation"

/// audit.py:36-41 (`_paths_for`), with deviation 1 from the file header:
/// suffixes are APPENDED to the full prefix, never substituted for a trailing
/// dot-suffix of the slug. Identical to the reference for every dot-free slug.
private func pathsFor(prefixPath: String) -> AuditPaths {
    AuditPaths(
        planJson: prefixPath + planJSONSuffix,
        detailCsv: prefixPath + detailCSVSuffix,
        summaryMarkdown: prefixPath + summaryMarkdownSuffix
    )
}

/// The reference's `datetime.now().astimezone().strftime("%Y%m%d-%H%M%S%z")`
/// (audit.py:46). The clock and time zone are injected by the callers so
/// tests are deterministic (the reference tests patch `audit.datetime`).
private func timestampStamp(now: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyyMMdd-HHmmssZ"
    return formatter.string(from: now)
}

private enum ExclusiveCreate {
    case created(FileHandle)
    case alreadyExists
}

/// Python's `open(path, "x")`: O_CREAT|O_EXCL exclusive creation.
private func exclusiveCreate(atPath path: String) throws -> ExclusiveCreate {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
    if descriptor >= 0 {
        return .created(FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    }
    if errno == EEXIST {
        return .alreadyExists
    }
    throw PersistenceWriteError(path: path, detail: String(cString: strerror(errno)))
}

/// Exclusively reserve one unused artifact prefix for this audit attempt.
/// Reference: audit.py:44-66 (`_reserve_paths`): candidate N (N >= 2) appends
/// "-{N-1}" to the stem; a foreign reservation (EEXIST) or any existing
/// artifact moves to the next suffix; a transient reservation whose artifacts
/// turn out to exist is unlinked before moving on.
/// Join an artifact basename onto the directory WITHOUT URL path APIs:
/// URL's fileSystemRepresentation round-trip decomposes precomposed
/// characters (NFC -> NFD), which would change the on-disk artifact names and
/// the persisted AuditPaths strings for accented playlist names.
private func joinedPath(_ directoryPath: String, _ name: String) -> String {
    directoryPath.hasSuffix("/") ? directoryPath + name : directoryPath + "/" + name
}

/// Generalized reservation core: exclusively reserve one prefix whose
/// artifacts (prefix + each suffix in `artifactSuffixes`) do not exist yet.
/// Candidate N (N >= 2) appends "-{N-1}" to the stem; a foreign reservation
/// (EEXIST) or any existing artifact moves to the next suffix; a transient
/// reservation whose artifacts turn out to exist is unlinked before moving
/// on. Shared by the audit triple and the B2 mutation artifact pair.
private func reservePrefix(
    directoryPath: String,
    sourceName: String,
    artifactSuffixes: [String],
    now: Date,
    timeZone: TimeZone
) throws -> (prefixPath: String, reservationPath: String) {
    let stem = "\(slugify(sourceName))-\(timestampStamp(now: now, timeZone: timeZone))"
    var suffix = 1
    while true {
        let suffixText = suffix == 1 ? "" : "-\(suffix - 1)"
        let prefixPath = joinedPath(directoryPath, stem + suffixText)
        let reservationPath = prefixPath + reservationSuffix
        switch try exclusiveCreate(atPath: reservationPath) {
        case .alreadyExists:
            suffix += 1
        case .created(let handle):
            try handle.close()
            let fileManager = FileManager.default
            let artifactExists = artifactSuffixes.contains { artifactSuffix in
                fileManager.fileExists(atPath: prefixPath + artifactSuffix)
            }
            if !artifactExists {
                return (prefixPath, reservationPath)
            }
            try fileManager.removeItem(atPath: reservationPath)
            suffix += 1
        }
    }
}

private func reservePaths(
    directoryPath: String,
    sourceName: String,
    now: Date,
    timeZone: TimeZone
) throws -> (paths: AuditPaths, reservationPath: String) {
    let (prefixPath, reservationPath) = try reservePrefix(
        directoryPath: directoryPath,
        sourceName: sourceName,
        artifactSuffixes: [planJSONSuffix, detailCSVSuffix, summaryMarkdownSuffix],
        now: now,
        timeZone: timeZone
    )
    return (pathsFor(prefixPath: prefixPath), reservationPath)
}

/// Exclusively create and write each artifact in order, unlinking created
/// artifacts in reverse on any failure (audit.py:175-196 error branch).
private func createArtifacts(_ artifacts: [(path: String, text: String)]) throws {
    var created: [String] = []
    do {
        for (path, text) in artifacts {
            switch try exclusiveCreate(atPath: path) {
            case .alreadyExists:
                // Cannot happen behind a fresh reservation; fail closed anyway
                // (the reference's open("x") would raise FileExistsError here).
                throw PersistenceWriteError(path: path, detail: "artifact already exists")
            case .created(let handle):
                created.append(path)
                do {
                    try handle.write(contentsOf: Data(text.utf8))
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw PersistenceWriteError(path: path, detail: String(describing: error))
                }
            }
        }
    } catch {
        for path in created.reversed() {
            try? FileManager.default.removeItem(atPath: path)
        }
        throw error
    }
}

/// Shared body of write_audit / write_merge_audit (audit.py:175-196 and
/// audit.py:497-517): reserve, exclusively create and write each artifact,
/// unlink created artifacts in reverse on any failure, always release the
/// reservation.
private func writeArtifactSet(
    outputDir: URL,
    sourceName: String,
    now: () -> Date,
    timeZone: TimeZone,
    planJSONText: String,
    detailCSVText: String,
    summaryMarkdownText: String
) throws -> AuditPaths {
    let directory = outputDir.standardizedFileURL
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let (paths, reservationPath) = try reservePaths(
        directoryPath: directory.path,
        sourceName: sourceName,
        now: now(),
        timeZone: timeZone
    )
    defer { try? FileManager.default.removeItem(atPath: reservationPath) }
    try createArtifacts([
        (paths.planJson, planJSONText),
        (paths.detailCsv, detailCSVText),
        (paths.summaryMarkdown, summaryMarkdownText),
    ])
    return paths
}

/// Write timestamped JSON, CSV, and Markdown audit artifacts without
/// overwrite. Reference: audit.py:175-196 (`write_audit`).
public func writeAudit(
    outputDir: URL,
    plan: ConsolidationPlan,
    now: () -> Date = Date.init,
    timeZone: TimeZone = .current
) throws -> AuditPaths {
    try writeArtifactSet(
        outputDir: outputDir,
        sourceName: plan.sourcePlaylistName,
        now: now,
        timeZone: timeZone,
        planJSONText: renderPlanJSON(plan),
        detailCSVText: renderDetailCSV(plan),
        summaryMarkdownText: renderSummaryMarkdown(plan)
    )
}

/// Reference: audit.py:497-517 (`write_merge_audit`).
public func writeMergeAudit(
    outputDir: URL,
    plan: MergePlan,
    now: () -> Date = Date.init,
    timeZone: TimeZone = .current
) throws -> AuditPaths {
    try writeArtifactSet(
        outputDir: outputDir,
        sourceName: plan.mergedPlaylistSourceName,
        now: now,
        timeZone: timeZone,
        planJSONText: renderMergePlanJSON(plan),
        detailCSVText: renderMergeDetailCSV(plan),
        summaryMarkdownText: renderMergeSummaryMarkdown(plan)
    )
}

/// Return whether all three audit artifacts are regular files.
/// Reference: audit.py:199-204 (`audit_artifacts_exist`, Path.is_file()).
public func auditArtifactsExist(_ paths: AuditPaths) -> Bool {
    let fileManager = FileManager.default
    return [paths.planJson, paths.detailCsv, paths.summaryMarkdown].allSatisfy { path in
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}

// MARK: - Fail-closed loaders

/// True when JSONSerialization produced a JSON true/false (CFBoolean) rather
/// than a numeric token. Needed wherever booleans and numbers must be told
/// apart at the raw-token level, mirroring Python's `type(value) is bool`.
func isJSONBoolean(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
}

/// BINDING item 1: reject any float-typed number token anywhere in the
/// document (see file header). Dictionary keys are visited in sorted order so
/// the reported field is deterministic.
private func rejectNonIntegralNumbers(_ value: Any, path: String) throws {
    if let dictionary = value as? [String: Any] {
        for key in dictionary.keys.sorted() {
            try rejectNonIntegralNumbers(dictionary[key]!, path: "\(path).\(key)")
        }
        return
    }
    if let array = value as? [Any] {
        for (index, element) in array.enumerated() {
            try rejectNonIntegralNumbers(element, path: "\(path)[\(index)]")
        }
        return
    }
    if let number = value as? NSNumber, !(value is String) {
        if !isJSONBoolean(number) && CFNumberIsFloatType(number) {
            throw PlanLoadError.decodeRejected(
                detail: "\(path) must be an integer (found JSON number \(number))"
            )
        }
    }
}

private struct StrictJSONSyntaxError: Error {
    let message: String
}

/// Strict JSON syntax gate mirroring the reference's load surface —
/// `read_text(encoding="utf-8")` + `json.loads` (audit.py:353-359) — because
/// JSONSerialization is lenient in the fail-OPEN direction (it auto-detects
/// UTF-16, tolerates BOMs and trailing commas, and keeps the FIRST duplicate
/// key where Python keeps the last). Rejects: trailing commas, raw control
/// characters in strings, malformed escapes/numbers/literals, extra trailing
/// data — and (deviation 3, file header) duplicate object keys at any
/// nesting level, NaN/Infinity tokens, and lone surrogate escapes.
///
/// Nesting is CAPPED at 128 levels (fix round 2): the scanner recurses once
/// per object/array level, so unbounded input would exhaust the stack —
/// fatal, not catchable — long before Python's ~1000-frame RecursionError
/// (200,000 nested "[" SIGSEGVed the round-1 loader; JSONSerialization and
/// the reference both reject the same bytes cleanly). Real plans nest ~5 levels,
/// so 128 gives ~25x headroom while keeping worst-case scanner stack usage
/// far below the 512 KB default non-main-thread stack even in debug builds.
/// Any document between the cap and Python's limit is a rejection on both
/// sides regardless (no valid plan nests past ~6 levels) — only the error
/// class differs, in the sanctioned fail-closed direction.
///
/// Access: `public` since M5 fix round 2 (pre-authorized, access-level-only
/// change) so MusicBridge can reuse this exact gate as its wire-payload
/// syntax pre-pass instead of maintaining a divergent copy. Behavior is
/// unchanged; callers only need `check(_:)` and catch the thrown error
/// generically.
public struct StrictJSONScanner {
    private static let maximumNestingDepth = 128

    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var depth = 0

    init(_ text: String) {
        self.scalars = Array(text.unicodeScalars)
    }

    public static func check(_ text: String) throws {
        var scanner = StrictJSONScanner(text)
        try scanner.parseValue()
        scanner.skipWhitespace()
        if scanner.index != scanner.scalars.count {
            throw scanner.error("Extra data after JSON document")
        }
    }

    private var current: Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    private func error(_ message: String) -> StrictJSONSyntaxError {
        StrictJSONSyntaxError(message: "\(message) (scalar offset \(index))")
    }

    private mutating func skipWhitespace() {
        while let scalar = current,
              scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
            index += 1
        }
    }

    private mutating func parseValue() throws {
        skipWhitespace()
        guard let scalar = current else { throw error("Expecting value") }
        switch scalar {
        case "{": try parseObject()
        case "[": try parseArray()
        case "\"": _ = try parseString()
        case "t": try parseLiteral("true")
        case "f": try parseLiteral("false")
        case "n": try parseLiteral("null")
        case "-", "0"..."9": try parseNumber()
        default: throw error("Expecting value")
        }
    }

    private mutating func parseLiteral(_ literal: String) throws {
        for expected in literal.unicodeScalars {
            guard current == expected else { throw error("Expecting value") }
            index += 1
        }
    }

    private mutating func enterNestingLevel() throws {
        depth += 1
        if depth > Self.maximumNestingDepth {
            throw error("JSON document is nested too deeply (limit \(Self.maximumNestingDepth))")
        }
    }

    private mutating func parseObject() throws {
        try enterNestingLevel()
        defer { depth -= 1 }
        index += 1 // consume "{"
        var seenKeys: Set<[Unicode.Scalar]> = []
        skipWhitespace()
        if current == "}" {
            index += 1
            return
        }
        while true {
            skipWhitespace()
            if current == "}" {
                throw error("Illegal trailing comma before end of object")
            }
            guard current == "\"" else {
                throw error("Expecting property name enclosed in double quotes")
            }
            let key = try parseString()
            if !seenKeys.insert(key).inserted {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: key)
                throw error("duplicate object key \"\(String(view))\"")
            }
            skipWhitespace()
            guard current == ":" else { throw error("Expecting ':' delimiter") }
            index += 1
            try parseValue()
            skipWhitespace()
            if current == "," {
                index += 1
                continue
            }
            if current == "}" {
                index += 1
                return
            }
            throw error("Expecting ',' delimiter")
        }
    }

    private mutating func parseArray() throws {
        try enterNestingLevel()
        defer { depth -= 1 }
        index += 1 // consume "["
        skipWhitespace()
        if current == "]" {
            index += 1
            return
        }
        while true {
            skipWhitespace()
            if current == "]" {
                throw error("Illegal trailing comma before end of array")
            }
            try parseValue()
            skipWhitespace()
            if current == "," {
                index += 1
                continue
            }
            if current == "]" {
                index += 1
                return
            }
            throw error("Expecting ',' delimiter")
        }
    }

    private mutating func parseString() throws -> [Unicode.Scalar] {
        index += 1 // consume opening quote
        var decoded: [Unicode.Scalar] = []
        while true {
            guard let scalar = current else { throw error("Unterminated string") }
            if scalar == "\"" {
                index += 1
                return decoded
            }
            if scalar == "\\" {
                index += 1
                guard let escape = current else { throw error("Unterminated string") }
                switch escape {
                case "\"", "\\", "/":
                    decoded.append(escape)
                    index += 1
                case "b":
                    decoded.append("\u{08}")
                    index += 1
                case "f":
                    decoded.append("\u{0C}")
                    index += 1
                case "n":
                    decoded.append("\n")
                    index += 1
                case "r":
                    decoded.append("\r")
                    index += 1
                case "t":
                    decoded.append("\t")
                    index += 1
                case "u":
                    index += 1
                    let first = try parseHex4()
                    if (0xD800...0xDBFF).contains(first) {
                        guard current == "\\" else { throw error("Unpaired surrogate escape in string") }
                        index += 1
                        guard current == "u" else { throw error("Unpaired surrogate escape in string") }
                        index += 1
                        let second = try parseHex4()
                        guard (0xDC00...0xDFFF).contains(second) else {
                            throw error("Unpaired surrogate escape in string")
                        }
                        let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                        decoded.append(Unicode.Scalar(combined)!)
                    } else if (0xDC00...0xDFFF).contains(first) {
                        throw error("Unpaired surrogate escape in string")
                    } else {
                        decoded.append(Unicode.Scalar(first)!)
                    }
                default:
                    throw error("Invalid \\escape in string")
                }
                continue
            }
            if scalar.value < 0x20 {
                throw error("Invalid control character in string")
            }
            decoded.append(scalar)
            index += 1
        }
    }

    private mutating func parseHex4() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            guard let scalar = current, let digit = hexDigitValue(scalar) else {
                throw error("Invalid \\uXXXX escape in string")
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    private func hexDigitValue(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar {
        case "0"..."9": return Int(scalar.value - 0x30)
        case "a"..."f": return Int(scalar.value - 0x61 + 10)
        case "A"..."F": return Int(scalar.value - 0x41 + 10)
        default: return nil
        }
    }

    /// Python json's strict number grammar:
    /// `-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?`. NaN/Infinity, which Python
    /// parses via separate constants, never reach here ("N"/"I" are rejected
    /// by parseValue) — the reference rejects the resulting floats downstream.
    private mutating func parseNumber() throws {
        if current == "-" { index += 1 }
        guard let first = current, ("0"..."9").contains(first) else {
            throw error("Expecting value")
        }
        if first == "0" {
            index += 1
        } else {
            while let scalar = current, ("0"..."9").contains(scalar) { index += 1 }
        }
        if current == "." {
            index += 1
            guard let scalar = current, ("0"..."9").contains(scalar) else {
                throw error("Invalid number")
            }
            while let scalar = current, ("0"..."9").contains(scalar) { index += 1 }
        }
        if current == "e" || current == "E" {
            index += 1
            if current == "+" || current == "-" { index += 1 }
            guard let scalar = current, ("0"..."9").contains(scalar) else {
                throw error("Invalid number")
            }
            while let scalar = current, ("0"..."9").contains(scalar) { index += 1 }
        }
    }
}

/// Read + byte-check + strict-syntax-check + raw-token-check the plan
/// document. Fail-closed order: unreadable file, UTF-8 BOM (json.loads:
/// "Unexpected UTF-8 BOM"), non-UTF-8 bytes (read_text UnicodeDecodeError),
/// strict JSON syntax incl. duplicate keys, then the integral-float walk.
private func loadCheckedPlanData(from url: URL) throws -> Data {
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw PlanLoadError.fileUnreadable(path: url.path, detail: error.localizedDescription)
    }
    if data.starts(with: [0xEF, 0xBB, 0xBF]) {
        throw PlanLoadError.malformedJSON(path: url.path, detail: "Unexpected UTF-8 BOM")
    }
    guard let text = String(data: data, encoding: .utf8) else {
        throw PlanLoadError.malformedJSON(path: url.path, detail: "plan file is not valid UTF-8")
    }
    do {
        try StrictJSONScanner.check(text)
    } catch let syntaxError as StrictJSONSyntaxError {
        throw PlanLoadError.malformedJSON(path: url.path, detail: syntaxError.message)
    }
    let root: Any
    do {
        root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
        throw PlanLoadError.malformedJSON(path: url.path, detail: error.localizedDescription)
    }
    try rejectNonIntegralNumbers(root, path: "plan")
    return data
}

/// Render a DecodingError as "<snake_case field path>: <reason>".
private func describeDecodingError(_ error: DecodingError) -> String {
    let context: DecodingError.Context
    switch error {
    case .typeMismatch(_, let errorContext),
         .valueNotFound(_, let errorContext),
         .keyNotFound(_, let errorContext),
         .dataCorrupted(let errorContext):
        context = errorContext
    @unknown default:
        return String(describing: error)
    }
    let path = context.codingPath
        .map { $0.intValue.map(String.init) ?? $0.stringValue }
        .joined(separator: ".")
    return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
}

/// Load an immutable consolidation plan previously written by `writeAudit`.
/// Reference: audit.py:353-359 (`load_plan`) = read -> strict decode -> full
/// integrity validation, failing closed with a distinct error class per
/// failure surface.
public func loadPlan(from url: URL) throws -> ConsolidationPlan {
    let data = try loadCheckedPlanData(from: url)
    let plan: ConsolidationPlan
    do {
        plan = try JSONDecoder().decode(ConsolidationPlan.self, from: data)
    } catch let error as DecodingError {
        throw PlanLoadError.decodeRejected(detail: describeDecodingError(error))
    }
    do {
        try validatePlanIntegrity(plan)
    } catch let error as PlanIntegrityError {
        throw PlanLoadError.integrityRejected(detail: error.message)
    } catch let error as ResolverError {
        // Canonical recompute inside the validator; unreachable for plans that
        // passed the ordering checks, kept for fail-closed completeness.
        throw PlanLoadError.integrityRejected(detail: error.message)
    }
    return plan
}

/// Reference: audit.py:491-494 (`load_merge_plan`).
public func loadMergePlan(from url: URL) throws -> MergePlan {
    let data = try loadCheckedPlanData(from: url)
    let plan: MergePlan
    do {
        plan = try JSONDecoder().decode(MergePlan.self, from: data)
    } catch let error as DecodingError {
        throw PlanLoadError.decodeRejected(detail: describeDecodingError(error))
    }
    do {
        try validateMergePlanIntegrity(plan)
    } catch let error as PlanIntegrityError {
        throw PlanLoadError.integrityRejected(detail: error.message)
    } catch let error as ResolverError {
        throw PlanLoadError.integrityRejected(detail: error.message)
    }
    return plan
}

// MARK: - Mutation plan decode gate (Wave B)

/// Data-level strict decode for mutation artifacts: the SAME fail-closed
/// pipeline as loadPlan/loadMergePlan minus the file read — UTF-8 BOM
/// rejection, UTF-8 validation, StrictJSONScanner syntax gate (duplicate
/// keys, NaN/Infinity, lone surrogates, trailing data), the integral-float
/// raw-token walk (BINDING item, file header), then the exact-keys Codable
/// decode. It lives in this file so the private helpers are reusable, never
/// hand-copied. `source` names the payload in error messages; the mutation
/// artifact loader (loadMutationPlan) wraps this with the file read and
/// passes the file path.
public func decodeMutationPlan(fromJSONData data: Data, source: String) throws -> MutationPlan {
    if data.starts(with: [0xEF, 0xBB, 0xBF]) {
        throw PlanLoadError.malformedJSON(path: source, detail: "Unexpected UTF-8 BOM")
    }
    guard let text = String(data: data, encoding: .utf8) else {
        throw PlanLoadError.malformedJSON(path: source, detail: "mutation plan is not valid UTF-8")
    }
    do {
        try StrictJSONScanner.check(text)
    } catch let syntaxError as StrictJSONSyntaxError {
        throw PlanLoadError.malformedJSON(path: source, detail: syntaxError.message)
    }
    let root: Any
    do {
        root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
        throw PlanLoadError.malformedJSON(path: source, detail: error.localizedDescription)
    }
    do {
        try rejectNonIntegralNumbers(root, path: "mutation plan")
    } catch let error as PlanLoadError {
        throw error
    }
    do {
        return try JSONDecoder().decode(MutationPlan.self, from: data)
    } catch let error as DecodingError {
        throw PlanLoadError.decodeRejected(detail: describeDecodingError(error))
    }
}

// MARK: - Mutation audit artifacts (B2: delete/rename plans)

private let deletePlanSuffix = ".delete.plan.json"
private let renamePlanSuffix = ".rename.plan.json"

/// The reviewable artifact pair produced by one mutation audit.
public struct MutationAuditPaths: Equatable, Sendable {
    public let planURL: URL
    public let summaryURL: URL

    public init(planURL: URL, summaryURL: URL) {
        self.planURL = planURL
        self.summaryURL = summaryURL
    }
}

/// Write the `<slug>-<stamp>.delete.plan.json` / `.rename.plan.json` +
/// `.summary.md` pair for one mutation plan, never overwriting (the same
/// reservation + suffix-append scheme as `writeAudit`; artifact basenames are
/// joined by string concatenation, never URL path APIs — see `joinedPath`).
/// The plan artifact bytes are `plan.canonicalJSONData()` plus one trailing
/// newline, so dispatch-time SHA-256 rechecks must recompute the hash via
/// `loadMutationPlan(url:).sha256Hex()`, never over raw file bytes.
public func writeMutationAudit(
    outputDir: URL,
    plan: MutationPlan,
    summaryText: String,
    now: () -> Date = Date.init,
    timeZone: TimeZone = .current
) throws -> MutationAuditPaths {
    let directory = outputDir.standardizedFileURL
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let planSuffix: String
    switch plan.kind {
    case .delete:
        planSuffix = deletePlanSuffix
    case .rename:
        planSuffix = renamePlanSuffix
    }
    let (prefixPath, reservationPath) = try reservePrefix(
        directoryPath: directory.path,
        sourceName: plan.playlistName,
        artifactSuffixes: [planSuffix, summaryMarkdownSuffix],
        now: now(),
        timeZone: timeZone
    )
    defer { try? FileManager.default.removeItem(atPath: reservationPath) }
    let planPath = prefixPath + planSuffix
    let summaryPath = prefixPath + summaryMarkdownSuffix
    let planText = String(decoding: plan.canonicalJSONData(), as: UTF8.self) + "\n"
    try createArtifacts([
        (planPath, planText),
        (summaryPath, summaryText),
    ])
    return MutationAuditPaths(
        planURL: URL(fileURLWithPath: planPath),
        summaryURL: URL(fileURLWithPath: summaryPath)
    )
}

/// Load a mutation plan previously written by `writeMutationAudit`, through
/// the same fail-closed gates as every other plan JSON: unreadable file, BOM,
/// non-UTF-8 bytes, StrictJSONScanner (duplicate keys, trailing commas, raw
/// control characters, lone surrogates, nesting cap), the integral-float
/// raw-token walk, then the strict exact-keys decode of `MutationPlan`.
public func loadMutationPlan(url: URL) throws -> MutationPlan {
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw PlanLoadError.fileUnreadable(path: url.path, detail: error.localizedDescription)
    }
    return try decodeMutationPlan(fromJSONData: data, source: url.path)
}

// MARK: - Consumed sidecars and mutation result reports (B2 single-use)

private let consumedSidecarSuffix = ".consumed"
private let mutationResultSuffix = ".mutationresult.md"

/// Mark the mutation plan artifact at `planURL` consumed by creating the
/// sidecar `<plan-file-name>.consumed` beside it, containing the plan's
/// canonical SHA-256 hex. The artifact itself is only READ (to compute the
/// hash), never opened for writing. Marking an already-consumed plan is a
/// no-op: the existing marker persists byte-for-byte, because consumed can
/// never flip back and cleanup marks artifacts on execution OR abort.
/// Sidecar paths are built by string concatenation on `planURL.path`, never
/// URL path APIs (see `joinedPath` for the NFC/NFD rationale).
public func markMutationPlanConsumed(planURL: URL) throws {
    let plan = try loadMutationPlan(url: planURL)
    let sidecarPath = planURL.path + consumedSidecarSuffix
    switch try exclusiveCreate(atPath: sidecarPath) {
    case .alreadyExists:
        return
    case .created(let handle):
        do {
            try handle.write(contentsOf: Data((plan.sha256Hex() + "\n").utf8))
            try handle.close()
        } catch {
            try? handle.close()
            throw PersistenceWriteError(path: sidecarPath, detail: String(describing: error))
        }
    }
}

/// True when the consumed sidecar for `planURL` exists as a regular file.
/// Existence alone decides: a present-but-unreadable marker still means
/// consumed, which is the fail-closed direction for the arming gate.
public func isMutationPlanConsumed(planURL: URL) -> Bool {
    let sidecarPath = planURL.path + consumedSidecarSuffix
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: sidecarPath, isDirectory: &isDirectory)
        && !isDirectory.boolValue
}

/// Write `<baseName>.mutationresult.md` under `outputDir`, never overwriting:
/// candidate N (N >= 2) appends "-{N-1}" to the base name (the audit writers'
/// suffix-append scheme). `exclusiveCreate` is atomic, so a single artifact
/// needs no reservation file. Returns the URL of the created report.
public func writeMutationResult(outputDir: URL, baseName: String, text: String) throws -> URL {
    let directory = outputDir.standardizedFileURL
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var suffix = 1
    while true {
        let suffixText = suffix == 1 ? "" : "-\(suffix - 1)"
        let path = joinedPath(directory.path, baseName + suffixText + mutationResultSuffix)
        switch try exclusiveCreate(atPath: path) {
        case .alreadyExists:
            suffix += 1
        case .created(let handle):
            do {
                try handle.write(contentsOf: Data(text.utf8))
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(atPath: path)
                throw PersistenceWriteError(path: path, detail: String(describing: error))
            }
            return URL(fileURLWithPath: path)
        }
    }
}
