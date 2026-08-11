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
    /// (trimmed), or the first entry of the LEGACY listing (the reference
    /// side, never the reader under test) when the caller's was empty.
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
    /// LEGACY listing (ascending playlist id) is used instead — "the first
    /// user playlist" the Task 3 brief calls for, chosen from the REFERENCE
    /// reader so the reader under test never selects its own subject (M6,
    /// 2026-08-11). An empty library (no user playlists at all) is a hard
    /// failure: there is nothing to snapshot-compare.
    ///
    /// `runner` is caller-supplied so tests can inject a fake; the real
    /// call site (DiagnosticsView.startCompareReaders) passes a fresh
    /// OSAKitRunner, created and consumed entirely within its own detached
    /// task, exactly like `readAllCopies`.
    ///
    /// This is the ONLY production caller of the two deprecated legacy
    /// builders, and it dies with them. It reaches them through the
    /// `legacyListingScript()`/`legacyReadScript(name:)` accessors rather than
    /// naming them directly — see the "legacy-builder deprecation seam" note in
    /// MusicScriptBuilder.swift for why the deprecation cannot simply be
    /// silenced at this call site (M1, 2026-08-11).
    static func compareReaders(
        playlistName: String, runner: ScriptRunner
    ) throws -> ReaderCompareOutcome {
        // Each timed block spans RUN + PARSE together (never just the OSA
        // call) — true parity with `readAllCopies`'s elapsed contract, which
        // `ReaderElapsed`'s doc comment promises. Folding the parse inside
        // the timed closure (rather than timing the run and parsing after)
        // is what makes that promise true, not just documented.
        let legacyListingRun: (value: [PlaylistListing], seconds: Double)
        do {
            legacyListingRun = try timedRun {
                try parsePlaylistListing(
                    raw: runner.run(.readJXA(script: legacyListingScript()))
                )
            }
        } catch {
            throw ReaderCompareFailure(stage: "legacy listing", message: String(describing: error))
        }
        let liveListingRun: (value: [PlaylistListing], seconds: Double)
        do {
            liveListingRun = try timedRun {
                try parsePlaylistListing(
                    raw: runner.run(.readJXA(script: buildListPlaylistsJXA()))
                )
            }
        } catch {
            throw ReaderCompareFailure(stage: "live listing", message: String(describing: error))
        }
        let legacyListing = legacyListingRun.value
        let liveListing = liveListingRun.value

        let trimmedName = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetName: String
        if !trimmedName.isEmpty {
            targetName = trimmedName
        } else if let first = legacyListing.first {
            // M6 (2026-08-11): the fallback target comes from the LEGACY
            // listing, never the live one. The live reader is the READER UNDER
            // TEST here — sourcing the snapshot subject from its output lets a
            // defect in it choose what it is judged against (in the limit, a
            // live listing that dropped every playlist but one would quietly
            // narrow the cross-check to that one). The legacy reader is the
            // reference side, so it picks the subject.
            targetName = first.name
        } else {
            throw ReaderCompareFailure(
                stage: "snapshot",
                message: "the library has no user playlists to compare"
            )
        }

        let legacyReadRun: (value: [PlaylistSnapshot], seconds: Double)
        do {
            legacyReadRun = try timedRun {
                try parseAllCopies(
                    raw: runner.run(.readJXA(script: legacyReadScript(name: targetName))),
                    name: targetName
                )
            }
        } catch {
            throw ReaderCompareFailure(stage: "legacy snapshot", message: String(describing: error))
        }
        let liveReadRun: (value: [PlaylistSnapshot], seconds: Double)
        do {
            liveReadRun = try timedRun {
                try parseAllCopies(
                    raw: runner.run(.readJXA(script: buildReadJXA(name: targetName))),
                    name: targetName
                )
            }
        } catch {
            throw ReaderCompareFailure(stage: "live snapshot", message: String(describing: error))
        }
        let legacyCopies = legacyReadRun.value
        let liveCopies = liveReadRun.value

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

    /// Times `body` — RUN and PARSE together, whatever `body` does — and
    /// returns its value alongside the elapsed seconds. Generic so the same
    /// helper covers both the `[PlaylistListing]` and `[PlaylistSnapshot]`
    /// reads; each call site folds its `runner.run` and its parse into one
    /// closure so neither read's elapsed time can silently drop the parse.
    private static func timedRun<T>(_ body: () throws -> T) throws -> (value: T, seconds: Double) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try body()
        let elapsed = start.duration(to: clock.now)
        return (value, elapsedSecondsValue(of: elapsed))
    }

    // MARK: scalar-exact field comparators (final-review finding I1, 2026-08-11)
    //
    // These comparisons USED to be `legacyEntry != liveEntry` / `legacyTrack
    // != liveTrack` / `legacyCopy.name != liveCopy.name` — the synthesized
    // Equatable conformances and Swift `String ==`. Both compare text by
    // Unicode CANONICAL EQUIVALENCE, so "Caf\u{00E9}" (NFC) and
    // "Cafe\u{0301}" (NFD) are `==` and the cross-check would have reported
    // `identical` over two wires that carry materially different bytes —
    // exactly the divergence class a wire-fidelity probe exists to catch,
    // silently swallowed by its own comparator. Every String field now goes
    // through `Self.scalarExact` (scalar-by-scalar, no normalization), the
    // discipline this file's own doc comment already demanded: "Never String
    // == on wire-derived text." Numerics and Bools keep `==`, which is exact
    // for them. Each comparator returns the FIELD NAME that diverged so the
    // rendered verdict names it.

    /// Scalar-exact field diff for one listing entry pair; nil when every
    /// field agrees. Field order is the wire's own record order.
    private static func listingFieldDifference(
        legacy: PlaylistListing, live: PlaylistListing
    ) -> String? {
        if legacy.playlistId != live.playlistId { return "playlist id" }
        if !Self.scalarExact(legacy.name, live.name) { return "name" }
        if !Self.scalarExact(legacy.persistentId, live.persistentId) { return "persistent ID" }
        if legacy.trackCount != live.trackCount { return "track count" }
        if legacy.isSmart != live.isSmart { return "smart flag" }
        if !Self.scalarExact(legacy.specialKind, live.specialKind) { return "special kind" }
        return nil
    }

    /// Scalar-exact field diff for one track pair; nil when all eleven wire
    /// fields plus the derived file-track flag agree.
    private static func trackFieldDifference(
        legacy: TrackSnapshot, live: TrackSnapshot
    ) -> String? {
        if legacy.sourceIndex != live.sourceIndex { return "source index" }
        if legacy.databaseId != live.databaseId { return "database ID" }
        if !Self.scalarExact(legacy.persistentId, live.persistentId) { return "persistent ID" }
        if !Self.scalarExact(legacy.title, live.title) { return "title" }
        if !Self.scalarExact(legacy.artist, live.artist) { return "artist" }
        if !Self.scalarExact(legacy.album, live.album) { return "album" }
        if legacy.durationMs != live.durationMs { return "duration" }
        if !Self.scalarExact(legacy.kind, live.kind) { return "kind" }
        if legacy.bitRateKbps != live.bitRateKbps { return "bit rate" }
        if legacy.sampleRateHz != live.sampleRateHz { return "sample rate" }
        if !Self.scalarExact(legacy.cloudStatus, live.cloudStatus) { return "cloud status" }
        if legacy.isFileTrack != live.isFileTrack { return "file-track flag" }
        return nil
    }

    private static func firstListingDifference(
        legacy: [PlaylistListing], live: [PlaylistListing]
    ) -> String? {
        if legacy.count != live.count {
            return "listing count differs: legacy \(legacy.count), live \(live.count)"
        }
        for (index, pair) in zip(legacy, live).enumerated() {
            let (legacyEntry, liveEntry) = pair
            if let field = Self.listingFieldDifference(legacy: legacyEntry, live: liveEntry) {
                return "listing entry \(index + 1) \(field) differs: "
                    + "legacy \(legacyEntry), live \(liveEntry)"
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
                if let field = Self.trackFieldDifference(legacy: legacyTrack, live: liveTrack) {
                    return "copy \(index + 1) track \(trackIndex + 1) \(field) differs: "
                        + "legacy \(legacyTrack), live \(liveTrack)"
                }
            }
            if !Self.scalarExact(legacyCopy.name, liveCopy.name) {
                return "copy \(index + 1) name differs: "
                    + "legacy \(legacyCopy.name), live \(liveCopy.name)"
            }
            if !Self.scalarExact(legacyCopy.persistentId, liveCopy.persistentId) {
                return "copy \(index + 1) persistent ID differs: "
                    + "legacy \(legacyCopy.persistentId), live \(liveCopy.persistentId)"
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
    @State private var exportErrorText: String?
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

            if let exportErrorText {
                Text(exportErrorText)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
    //
    // FIELD OWNERSHIP (M5, 2026-08-11): each action owns a DISJOINT set of
    // fields — it writes only those and clears exactly those, never a field
    // another action owns.
    //   runPreflight        -> preflightStatus
    //   startRead           -> errorText, elapsedText, copies, rawWireJSON
    //   exportRawWireJSON   -> exportStatus, exportErrorText
    //   startCompareReaders -> compareStatus, compareErrorText
    // Before this, `runPreflight` cleared `errorText` — a field it never
    // writes — while the read and the export SHARED `errorText`/`exportStatus`
    // between them, so whose message was on screen depended on which action
    // ran last. Two consequences of the split, both deliberate: the read's
    // "raw wire JSON was retained" hint now rides on the read's own
    // `errorText` (it describes the READ's outcome, not an export), and
    // `startCompareReaders` leaves the read's fields untouched — the read's
    // whole result block stays on screen across a compare, message included,
    // because the compare reports through its own two fields.

    private func runPreflight() {
        guard !isBusy else { return }
        isBusy = true
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
                rawWireJSON = failure.rawWireJSON
                if failure.rawWireJSON != nil {
                    // The retained-evidence hint is part of the READ's own
                    // outcome message (M5 field ownership), so an export —
                    // past or future — can never overwrite or be confused
                    // with it.
                    errorText = failure.message + "\n"
                        + "Parsing failed, but the raw wire JSON was "
                        + "retained and can still be exported."
                } else {
                    errorText = failure.message
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
        // Both fields this action owns are cleared first (M5), so a successful
        // export never renders under a stale export failure and a failed
        // export never renders under a stale success line. Cancelling the
        // panel changes nothing, and the read's own fields are never touched.
        exportStatus = nil
        exportErrorText = nil
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
            exportErrorText = String(describing: error)
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
