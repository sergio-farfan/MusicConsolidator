// DiagnosticsView.swift
// Apple Music Consolidator
// Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
// The M6b read harness, retained as the app's DIAGNOSTICS surface (M7):
// preflight, raw all-copies read, raw-wire-JSON export, and (Task 3,
// bulk-read-speedup) "Compare readers" — the fidelity-probe surface for
// future checks (opened from the Window menu or with Cmd-Shift-D).
// READ-ONLY: every Music command this view can issue is a `.readJXA`
// ScriptCommand executed through OSAKitRunner — buildReadJXA for the raw
// all-copies read; buildReadJXA/buildListPlaylistsJXA (live, columnar) and
// legacyReadJXAScript/legacyListPlaylistsScript (retained ONE release,
// Compare-readers-only) for the cross-check. The guarded writers
// (buildApplyScript, buildMergeApplyScript, applyPlan, applyMergePlan) are
// deliberately never referenced here; adding any write path is out of scope
// until a later milestone with Sergio's explicit approval.
//
// Threading: all Music I/O runs off the main actor in a detached task.
// OSAKitRunner is not thread-safe and not Sendable by design, so a FRESH
// runner is created inside each detached task and never escapes it; the
// single-flight guard (isBusy) disables the buttons while an operation is
// in flight, so no two OSA executions ever overlap.
//
// Fidelity: the EXACT raw wire string returned by the runner (pre-parse) is
// retained and exportable as UTF-8, unmodified — the artifact for the M6b
// live descriptor-fidelity re-verification (scalar diff against osascript
// output produced separately; see XCODE-SETUP.md). The raw string is kept
// even when parsing fails, so a parse rejection never destroys the evidence.
//
// Errors render verbatim: MusicCommandError, MusicBridgeError, and the
// package's other error types are CustomStringConvertible and
// message-bearing by design, so String(describing:) is the exact operator
// message.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ConsolidatorCore
import MusicBridge

// MARK: - worker-side value types (nonisolated: constructed off the main actor)

/// First/last track display fields for one copy.
nonisolated struct TrackEndpointSummary: Sendable, Equatable {
    let title: String
    let persistentID: String
}

/// Display summary of one same-name copy, in the package's plan order
/// (ascending numeric playlist id — the parseAllCopies order).
nonisolated struct CopySummary: Sendable, Equatable, Identifiable {
    let id: Int
    /// Display-only; "?" when the supplementary id decode could not be
    /// cross-checked (see ReadWorker.displayPlaylistIDs).
    let playlistID: String
    let persistentID: String
    let name: String
    /// "U+XXXX U+XXXX …" rendering, present only when the name contains at
    /// least one non-ASCII scalar.
    let nameScalars: String?
    let trackCount: Int
    let firstTrack: TrackEndpointSummary?
    let lastTrack: TrackEndpointSummary?
}

nonisolated struct ReadOutcome: Sendable {
    /// The exact, pre-parse wire string the runner returned.
    let rawWireJSON: String
    let copies: [CopySummary]
    /// Runner execution + authoritative parse, measured together.
    let elapsedSeconds: Double
}

/// Failure surfaced by the read worker. `message` is the verbatim
/// description of the underlying package error; `rawWireJSON` is non-nil
/// when the runner succeeded but parsing failed, so the fidelity artifact
/// can still be exported.
nonisolated struct ReadWorkerFailure: Error, Sendable {
    let message: String
    let rawWireJSON: String?
}

// MARK: - the read worker (all Music I/O lives here, off the main actor)

nonisolated enum ReadWorker {
    /// The full read-only pipeline: build the read JXA via the package's
    /// public builder, execute it through a fresh OSAKitRunner, parse with
    /// the package's public all-copies parser. Synchronous and blocking —
    /// call from a detached task only.
    static func readAllCopies(name: String) throws -> ReadOutcome {
        let clock = ContinuousClock()
        let start = clock.now

        // Fresh runner per read: OSAKitRunner is single-threaded by
        // contract and never escapes this function.
        let runner = OSAKitRunner()
        let script = buildReadJXA(name: name)

        let raw: String
        do {
            raw = try runner.run(.readJXA(script: script))
        } catch {
            throw ReadWorkerFailure(message: String(describing: error), rawWireJSON: nil)
        }

        let copies: [PlaylistSnapshot]
        do {
            copies = try parseAllCopies(raw: raw, name: name)
        } catch {
            throw ReadWorkerFailure(message: String(describing: error), rawWireJSON: raw)
        }

        let elapsed = start.duration(to: clock.now)
        let playlistIDs = displayPlaylistIDs(raw: raw, name: name, copies: copies)

        let summaries = copies.enumerated().map { offset, copy -> CopySummary in
            CopySummary(
                id: offset,
                playlistID: playlistIDs[offset],
                persistentID: copy.persistentId,
                name: copy.name,
                nameScalars: scalarRendering(of: copy.name),
                trackCount: copy.tracks.count,
                firstTrack: copy.tracks.first.map {
                    TrackEndpointSummary(title: $0.title, persistentID: $0.persistentId)
                },
                lastTrack: copy.tracks.last.map {
                    TrackEndpointSummary(title: $0.title, persistentID: $0.persistentId)
                }
            )
        }
        return ReadOutcome(
            rawWireJSON: raw,
            copies: summaries,
            elapsedSeconds: elapsedSecondsValue(of: elapsed)
        )
    }

    // MARK: display helpers

    /// Scalar-sequence equality (Unicode scalar by scalar, no canonical
    /// normalization) — the display-side mirror of the package's internal
    /// scalar-exact discipline. Never String == on wire-derived text.
    static func scalarExact(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }

    /// "U+XXXX U+XXXX …" rendering of every scalar, returned only when the
    /// text contains at least one non-ASCII scalar (nil otherwise).
    static func scalarRendering(of text: String) -> String? {
        guard text.unicodeScalars.contains(where: { !$0.isASCII }) else { return nil }
        return text.unicodeScalars
            .map { String(format: "U+%04X", $0.value) }
            .joined(separator: " ")
    }

    private static func elapsedSecondsValue(of duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: display-only playlist ids

    // parseAllCopies (the authoritative parse) orders copies by ascending
    // numeric playlist id but does not expose the id on PlaylistSnapshot.
    // For display, the raw wire JSON is decoded a second time here with a
    // minimal Decodable shape, the exact-name matches are ordered by the
    // same (id, original offset) key the package uses, and each id is
    // paired with its parsed copy — cross-checked scalar-exactly against
    // the copy's persistent ID. This adjunct is FAIL-SOFT and display-only:
    // any decode or pairing mismatch renders "?" for the id and never
    // alters or blocks the parsed result.

    private struct WireEnvelope: Decodable {
        let playlists: [WirePlaylistHeader]
    }

    private struct WirePlaylistHeader: Decodable {
        let id: WireNumber?
        let name: String?
        let persistentID: String?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case persistentID = "persistent_id"
        }
    }

    private enum WireNumber: Decodable {
        case integer(Int)
        case double(Double)

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let integer = try? single.decode(Int.self) {
                self = .integer(integer)
            } else {
                self = .double(try single.decode(Double.self))
            }
        }

        var sortKey: Double {
            switch self {
            case .integer(let value): return Double(value)
            case .double(let value): return value
            }
        }

        var displayText: String {
            switch self {
            case .integer(let value):
                return String(value)
            case .double(let value):
                return Int(exactly: value).map(String.init) ?? String(value)
            }
        }
    }

    private static func displayPlaylistIDs(
        raw: String, name: String, copies: [PlaylistSnapshot]
    ) -> [String] {
        let unknown = Array(repeating: "?", count: copies.count)
        guard
            let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: Data(raw.utf8))
        else {
            return unknown
        }
        let matches = envelope.playlists.enumerated().filter { entry in
            guard let candidate = entry.element.name else { return false }
            return scalarExact(candidate, name)
        }
        guard matches.count == copies.count else { return unknown }
        let ordered = matches.sorted { lhs, rhs in
            let lhsKey = lhs.element.id?.sortKey ?? .infinity
            let rhsKey = rhs.element.id?.sortKey ?? .infinity
            return lhsKey != rhsKey ? lhsKey < rhsKey : lhs.offset < rhs.offset
        }
        return zip(ordered, copies).map { entry, copy in
            guard let id = entry.element.id,
                  let persistentID = entry.element.persistentID,
                  scalarExact(persistentID, copy.persistentId) else {
                return "?"
            }
            return id.displayText
        }
    }
}

// MARK: - reader cross-check (Task 3, bulk-read-speedup: legacy vs columnar)
//
// "Compare readers" is the ONE-RELEASE Diagnostics harness that validates
// the columnar readers (Task 1's buildListPlaylistsJXA, Task 2's buildReadJXA)
// against the retained pre-columnar builders (legacyListPlaylistsScript,
// legacyReadJXAScript) before those legacy builders are deleted. It covers
// BOTH readers — the library listing and one playlist's snapshot — never
// just one, and diffs the PARSED results (PlaylistListing / PlaylistSnapshot
// equality), never the raw script text: the wire JSON CONTRACT is what must
// agree, not the JXA source that produced it.

/// One reader pair's elapsed time (run + parse, exactly like `ReadOutcome`),
/// so the speedup between the legacy and live readers is visible side by
/// side.
nonisolated struct ReaderElapsed: Sendable {
    let legacySeconds: Double
    let liveSeconds: Double
}

/// The result of one "Compare readers" run: both cross-checks (listing, then
/// one playlist's snapshot) always run — even when the first already
/// differs — so every elapsed time is populated. `firstDifference` is nil
/// only when EVERY parsed field of BOTH comparisons agrees; otherwise it
/// names the earliest disagreement, checking the listing before the
/// snapshot (the same order the two script pairs run in).
nonisolated struct ReaderCompareOutcome: Sendable {
    let listingElapsed: ReaderElapsed
    let snapshotElapsed: ReaderElapsed
    /// The playlist name actually snapshot-compared — either the caller's
    /// (trimmed), or the first entry of the live listing when the caller's
    /// was empty.
    let snapshotPlaylistName: String
    let firstDifference: String?
    var isIdentical: Bool { firstDifference == nil }
}

/// Thrown when a script fails to run or its wire reply fails to parse.
/// `stage` names exactly which of the four reads failed (legacy/live,
/// listing/snapshot) — an idiom bug, surfaced verbatim, never silently
/// swallowed or misattributed to Music.
nonisolated struct ReaderCompareFailure: Error, Sendable {
    let stage: String
    let message: String
}

extension ReadWorker {
    /// Cross-check the legacy and live readers against each other: the
    /// library listing first, then one playlist's snapshot — diffed on
    /// their PARSED results. `playlistName`, trimmed: when non-empty, that
    /// exact name is snapshot-compared; when empty, the FIRST entry of the
    /// live listing (ascending playlist id) is used instead — "the first
    /// user playlist" the Task 3 brief calls for. An empty library (no user
    /// playlists at all) is a hard failure: there is nothing to
    /// snapshot-compare.
    ///
    /// `runner` is caller-supplied so tests can inject a fake; the real
    /// call site (DiagnosticsView.startCompareReaders) passes a fresh
    /// OSAKitRunner, created and consumed entirely within its own detached
    /// task, exactly like `readAllCopies`.
    static func compareReaders(
        playlistName: String, runner: ScriptRunner
    ) throws -> ReaderCompareOutcome {
        let legacyListingRun: (output: String, seconds: Double)
        do {
            legacyListingRun = try timedRun {
                try runner.run(.readJXA(script: legacyListPlaylistsScript()))
            }
        } catch {
            throw ReaderCompareFailure(stage: "legacy listing", message: String(describing: error))
        }
        let liveListingRun: (output: String, seconds: Double)
        do {
            liveListingRun = try timedRun {
                try runner.run(.readJXA(script: buildListPlaylistsJXA()))
            }
        } catch {
            throw ReaderCompareFailure(stage: "live listing", message: String(describing: error))
        }

        let legacyListing: [PlaylistListing]
        do {
            legacyListing = try parsePlaylistListing(raw: legacyListingRun.output)
        } catch {
            throw ReaderCompareFailure(stage: "legacy listing", message: String(describing: error))
        }
        let liveListing: [PlaylistListing]
        do {
            liveListing = try parsePlaylistListing(raw: liveListingRun.output)
        } catch {
            throw ReaderCompareFailure(stage: "live listing", message: String(describing: error))
        }

        let trimmedName = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetName: String
        if !trimmedName.isEmpty {
            targetName = trimmedName
        } else if let first = liveListing.first {
            targetName = first.name
        } else {
            throw ReaderCompareFailure(
                stage: "snapshot",
                message: "the library has no user playlists to compare"
            )
        }

        let legacyReadRun: (output: String, seconds: Double)
        do {
            legacyReadRun = try timedRun {
                try runner.run(.readJXA(script: legacyReadJXAScript(name: targetName)))
            }
        } catch {
            throw ReaderCompareFailure(stage: "legacy snapshot", message: String(describing: error))
        }
        let liveReadRun: (output: String, seconds: Double)
        do {
            liveReadRun = try timedRun {
                try runner.run(.readJXA(script: buildReadJXA(name: targetName)))
            }
        } catch {
            throw ReaderCompareFailure(stage: "live snapshot", message: String(describing: error))
        }

        let legacyCopies: [PlaylistSnapshot]
        do {
            legacyCopies = try parseAllCopies(raw: legacyReadRun.output, name: targetName)
        } catch {
            throw ReaderCompareFailure(stage: "legacy snapshot", message: String(describing: error))
        }
        let liveCopies: [PlaylistSnapshot]
        do {
            liveCopies = try parseAllCopies(raw: liveReadRun.output, name: targetName)
        } catch {
            throw ReaderCompareFailure(stage: "live snapshot", message: String(describing: error))
        }

        let difference = firstListingDifference(legacy: legacyListing, live: liveListing)
            ?? firstSnapshotDifference(legacy: legacyCopies, live: liveCopies)

        return ReaderCompareOutcome(
            listingElapsed: ReaderElapsed(
                legacySeconds: legacyListingRun.seconds, liveSeconds: liveListingRun.seconds
            ),
            snapshotElapsed: ReaderElapsed(
                legacySeconds: legacyReadRun.seconds, liveSeconds: liveReadRun.seconds
            ),
            snapshotPlaylistName: targetName,
            firstDifference: difference
        )
    }

    private static func timedRun(
        _ body: () throws -> String
    ) throws -> (output: String, seconds: Double) {
        let clock = ContinuousClock()
        let start = clock.now
        let output = try body()
        let elapsed = start.duration(to: clock.now)
        return (output, elapsedSecondsValue(of: elapsed))
    }

    private static func firstListingDifference(
        legacy: [PlaylistListing], live: [PlaylistListing]
    ) -> String? {
        if legacy.count != live.count {
            return "listing count differs: legacy \(legacy.count), live \(live.count)"
        }
        for (index, pair) in zip(legacy, live).enumerated() {
            let (legacyEntry, liveEntry) = pair
            if legacyEntry != liveEntry {
                return "listing entry \(index + 1) differs: legacy \(legacyEntry), live \(liveEntry)"
            }
        }
        return nil
    }

    private static func firstSnapshotDifference(
        legacy: [PlaylistSnapshot], live: [PlaylistSnapshot]
    ) -> String? {
        if legacy.count != live.count {
            return "snapshot copy count differs: legacy \(legacy.count), live \(live.count)"
        }
        for (index, pair) in zip(legacy, live).enumerated() {
            let (legacyCopy, liveCopy) = pair
            if legacyCopy.tracks.count != liveCopy.tracks.count {
                return "copy \(index + 1) track count differs: "
                    + "legacy \(legacyCopy.tracks.count), live \(liveCopy.tracks.count)"
            }
            for (trackIndex, trackPair) in zip(legacyCopy.tracks, liveCopy.tracks).enumerated() {
                let (legacyTrack, liveTrack) = trackPair
                if legacyTrack != liveTrack {
                    return "copy \(index + 1) track \(trackIndex + 1) differs: "
                        + "legacy \(legacyTrack), live \(liveTrack)"
                }
            }
            if legacyCopy.name != liveCopy.name || legacyCopy.persistentId != liveCopy.persistentId {
                return "copy \(index + 1) differs: legacy \(legacyCopy), live \(liveCopy)"
            }
        }
        return nil
    }
}

// MARK: - the view

@MainActor
struct DiagnosticsView: View {
    @State private var playlistName = "Trance 2022"
    @State private var isBusy = false
    @State private var preflightStatus: String?
    @State private var copies: [CopySummary] = []
    @State private var rawWireJSON: String?
    @State private var elapsedText: String?
    @State private var exportStatus: String?
    @State private var errorText: String?
    @State private var compareStatus: String?
    @State private var compareErrorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics — read-only harness (raw read + wire-JSON export)")
                .font(.headline)

            HStack {
                Text("Playlist name:")
                TextField("Playlist name", text: $playlistName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 12) {
                Button("Preflight Automation") { runPreflight() }
                    .disabled(isBusy)
                Button("Read all copies (read-only)") { startRead() }
                    .disabled(isBusy || playlistName.isEmpty)
                Button("Export raw wire JSON…") { exportRawWireJSON() }
                    .disabled(isBusy || rawWireJSON == nil)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                Button("Compare readers (legacy vs columnar)") { startCompareReaders() }
                    .disabled(isBusy)
            }

            if let preflightStatus {
                statusRow(label: "Automation preflight", text: preflightStatus)
            }

            if let compareStatus {
                statusRow(label: "Compare readers", text: compareStatus)
            }

            if let compareErrorText {
                Text(compareErrorText)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let elapsedText {
                Text(elapsedText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let exportStatus {
                Text(exportStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !copies.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(copies) { copy in
                            CopySummaryView(copy: copy, totalCopies: copies.count)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 540)
    }

    private func statusRow(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: actions (single-flight; state mutation stays on the main actor)

    private func runPreflight() {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        preflightStatus = nil
        Task {
            // AEDeterminePermissionToAutomateTarget blocks while the consent
            // prompt is on screen — run it off the main actor.
            let result = await Task.detached(priority: .userInitiated) {
                AutomationPreflight.determineMusicAutomationPermission(askUserIfNeeded: true)
            }.value
            preflightStatus = result.displayText
            isBusy = false
        }
    }

    private func startRead() {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        exportStatus = nil
        elapsedText = nil
        copies = []
        rawWireJSON = nil
        let name = playlistName
        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try ReadWorker.readAllCopies(name: name)
                }.value
                copies = outcome.copies
                rawWireJSON = outcome.rawWireJSON
                let copyWord = outcome.copies.count == 1 ? "copy" : "copies"
                let seconds = String(format: "%.3f", outcome.elapsedSeconds)
                elapsedText = "Read \(outcome.copies.count) \(copyWord) "
                    + "(\(outcome.rawWireJSON.utf8.count) bytes of wire JSON) "
                    + "in \(seconds) s (run + parse)"
            } catch let failure as ReadWorkerFailure {
                errorText = failure.message
                rawWireJSON = failure.rawWireJSON
                if failure.rawWireJSON != nil {
                    exportStatus = "Parsing failed, but the raw wire JSON was "
                        + "retained and can still be exported."
                }
            } catch {
                errorText = String(describing: error)
            }
            isBusy = false
        }
    }

    /// "Compare readers": legacy vs columnar for BOTH the library listing
    /// and one playlist's snapshot (Task 3, bulk-read-speedup). A fresh
    /// OSAKitRunner is created and consumed entirely inside the detached
    /// task — never escapes it — exactly like `startRead`.
    private func startCompareReaders() {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        compareStatus = nil
        compareErrorText = nil
        let name = playlistName
        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    let runner = OSAKitRunner()
                    return try ReadWorker.compareReaders(playlistName: name, runner: runner)
                }.value
                compareStatus = Self.describeCompareOutcome(outcome)
            } catch let failure as ReaderCompareFailure {
                compareErrorText = "\(failure.stage) failed: \(failure.message)"
            } catch {
                compareErrorText = String(describing: error)
            }
            isBusy = false
        }
    }

    private static func describeCompareOutcome(_ outcome: ReaderCompareOutcome) -> String {
        let listing = outcome.listingElapsed
        let snapshot = outcome.snapshotElapsed
        let listingText = String(
            format: "listing — legacy %.3f s, live %.3f s",
            listing.legacySeconds, listing.liveSeconds
        )
        let snapshotText = String(
            format: "snapshot \"%@\" — legacy %.3f s, live %.3f s",
            outcome.snapshotPlaylistName, snapshot.legacySeconds, snapshot.liveSeconds
        )
        let verdict = outcome.firstDifference.map { "first difference: \($0)" } ?? "identical"
        return "\(listingText)\n\(snapshotText)\n\(verdict)"
    }

    private func exportRawWireJSON() {
        guard let raw = rawWireJSON else { return }
        let panel = NSSavePanel()
        panel.title = "Export raw wire JSON"
        panel.nameFieldStringValue = "raw-wire.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // EXACT bytes: the UTF-8 encoding of the exact string the runner
            // returned, pre-parse. Nothing is appended (no trailing newline)
            // and nothing is re-serialized — this is the fidelity-diff
            // artifact. Diff note: osascript stdout appends one trailing
            // "\n" that this artifact intentionally lacks (see
            // XCODE-SETUP.md, live fidelity re-verification).
            try Data(raw.utf8).write(to: url, options: [.atomic])
            exportStatus = "Exported \(raw.utf8.count) bytes to \(url.path)"
        } catch {
            errorText = String(describing: error)
        }
    }
}

// MARK: - per-copy row

private struct CopySummaryView: View {
    let copy: CopySummary
    let totalCopies: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Copy \(copy.id + 1) of \(totalCopies)")
                .font(.subheadline)
                .bold()
            row("playlist id", copy.playlistID)
            row("persistent ID", copy.persistentID)
            row("name", copy.name)
            if let scalars = copy.nameScalars {
                row("name scalars", scalars)
            }
            row("tracks", String(copy.trackCount))
            row("first", endpointText(copy.firstTrack))
            row("last", endpointText(copy.lastTrack))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary)
        )
    }

    private func endpointText(_ endpoint: TrackEndpointSummary?) -> String {
        guard let endpoint else { return "(no tracks)" }
        return "\(endpoint.title) — \(endpoint.persistentID)"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label + ":")
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
