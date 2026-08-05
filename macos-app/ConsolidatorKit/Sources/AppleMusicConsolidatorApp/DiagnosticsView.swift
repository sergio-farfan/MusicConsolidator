// DiagnosticsView.swift
// The M6b read harness, retained as the app's DIAGNOSTICS surface (M7):
// preflight, raw all-copies read, and raw-wire-JSON export — the fidelity-
// probe surface for future checks (opened from the Window menu or with
// Cmd-Shift-D). READ-ONLY: the only Music command it can issue is the
// package's read JXA (buildReadJXA -> ScriptCommand.readJXA) executed
// through OSAKitRunner. The guarded writers (buildApplyScript,
// buildMergeApplyScript, applyPlan, applyMergePlan) are deliberately never
// referenced here; adding any write path is out of scope until a later
// milestone with Sergio's explicit approval.
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

            if let preflightStatus {
                statusRow(label: "Automation preflight", text: preflightStatus)
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
