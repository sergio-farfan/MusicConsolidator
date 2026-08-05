// AuditFlowModel.swift
// The @Observable view model behind the review→approve→apply flow (screens
// 1–6), extended in M8 with the sectioned source browser (listing scan +
// sections + selection) and the consolidate batch queue, and in M9 with
// IN-APP APPLY: completing the confirm gate reveals an Apply button (the
// CLI hand-off panel is gone; the python CLI remains the dev reference only).
//
// M9 apply contract:
// - The apply path is loadPlan/loadMergePlan(PERSISTED PLAN ARTIFACT) →
//   MusicBridgeSession.applyPlan/applyMergePlan — NEVER the in-memory plan
//   object. "Approval names this exact plan file" stays literally true, and
//   a tampered artifact is rejected by the fail-closed loaders before any
//   command is dispatched.
// - ONE APPLY PER FRESH AUDIT (cli.py parity): an apply attempt — success
//   OR failure — consumes the audit. The only paths afterwards are Start
//   over / next queue item; re-apply of the same plan is impossible.
// - The apply is single-flight, mutually exclusive with scans and audits,
//   and UNCANCELLABLE from the UI: the guarded write is one atomic
//   operation from the app's view (MusicBridgeSession.applyPlan is one
//   synchronous call on its detached task) — the readback verifies or the
//   apply fails closed. While an apply runs, navigation locks to the apply
//   screen and every other action is refused at the model level.
//
// M8 mutual exclusion: listing scans and audits are both single-flight AND
// mutually exclusive at the model level (never two concurrent OSA reads);
// M9 adds the apply to the same exclusion set.
// The batch queue serves BOTH modes since M10 (consolidate: checked
// single-copy playlists; merge: checked exact-name groups) as ONE state
// machine; a queue is always all one mode. It never bulk-approves: every
// queued item flows through its own plan review + confirm gate + its own
// apply; the queue only removes source-selection friction between items.
//
// Threading: all Music I/O and persistence run OFF the main actor in
// detached stage tasks; state mutation happens exclusively on the main
// actor between stages, so phase transitions are strictly ordered. A fresh,
// non-Sendable OSAKitRunner is created INSIDE the read stage's detached task
// (the documented single-threaded runner posture) and never escapes it.
//
// Single-flight: startAudit is a no-op while a run is in flight.
//
// Cancellation: cancelAudit() cancels the pipeline task; cancellation is
// honored BETWEEN phases (after read, after plan, after write). The OSA
// read call itself is uncancellable — a cancelled read still runs to
// completion in its detached task and its result is then discarded. A
// cancel that lands after the write phase started may leave a fully
// written artifact triple on disk; artifacts are never overwritten, so
// this is safe (the cancelled-state copy says so).
//
// Stale-state rule: startAudit, startOver, and a mode change all clear the
// completed audit and the confirm-gate state BEFORE anything else, and a
// run-generation counter guards every asynchronous state application, so a
// stale plan can never survive into (or complete over) a new audit.

import AppKit
import Foundation
import Observation
import ConsolidatorCore
import MusicBridge

/// Pipeline-local failure for the CLI-parity artifact existence check.
nonisolated struct AuditPipelineError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}

/// A mutation-gate precondition failure: the VERBATIM refusal reason
/// rendered by the refused phase (fail closed — never repaired, never
/// retried).
nonisolated struct MutationGateRefusal: Error, CustomStringConvertible, Sendable {
    let reason: String
    var description: String { reason }

    init(_ reason: String) {
        self.reason = reason
    }
}

@MainActor
@Observable
final class AuditFlowModel {
    // MARK: value types

    enum FlowStep: Hashable, CaseIterable {
        case source
        case review
        case confirm
        case apply
        case report
    }

    /// The streaming-progress phases. Each carries its start instant so the
    /// UI can tick elapsed time (a bare spinner is forbidden: reads cost
    /// ~8-9 s + ~0.16 s/track — a 1,600-track playlist is 4-5 minutes).
    enum Phase: Equatable, Sendable {
        case reading(started: Date)
        case buildingPlan(started: Date)
        case writingArtifacts(started: Date)

        var started: Date {
            switch self {
            case .reading(let date), .buildingPlan(let date), .writingArtifacts(let date):
                return date
            }
        }

        var label: String {
            switch self {
            case .reading: return "Reading playlist(s)\u{2026}"
            case .buildingPlan: return "Building plan\u{2026}"
            case .writingArtifacts: return "Writing artifacts\u{2026}"
            }
        }
    }

    /// One rendered failure: the error class plus the VERBATIM message (the
    /// package error types are CustomStringConvertible by design).
    struct AuditFailure: Equatable, Sendable {
        let category: String
        let message: String
    }

    enum RunState: Equatable, Sendable {
        case idle
        case running(Phase)
        case failed(AuditFailure)
        case cancelled
    }

    /// The M9 apply lifecycle. `.running` carries the stage entries emitted
    /// so far (the artifact load, then the bridge phases); success and
    /// failure both CONSUME the audit — only Start over / the next queue
    /// item lead anywhere afterwards.
    enum ApplyState: Equatable {
        case idle
        case running([ApplyStageEntry])
        case succeeded(ApplySuccessDisplay)
        case failed(ApplyFailureDisplay)
    }

    /// The completed audit: the CANONICAL plan object returned by the build
    /// (the binding M7 data-flow rule — renderers receive only this), the
    /// persisted artifact triple, and timing for the freshness note.
    struct CompletedAudit: Sendable {
        enum PlanArtifact: Sendable {
            case consolidation(ConsolidationPlan)
            case merge(MergePlan)
        }

        let mode: ConsolidatorMode
        let plan: PlanArtifact
        let paths: AuditPaths
        let completedAt: Date
        let readSeconds: Double
        let totalSeconds: Double

        var sourceName: String {
            switch plan {
            case .consolidation(let plan): return plan.sourcePlaylistName
            case .merge(let plan): return plan.mergedPlaylistSourceName
            }
        }

        var inputCount: Int {
            switch plan {
            case .consolidation(let plan): return plan.sourceTrackCount
            case .merge(let plan): return plan.combinedTrackCount
            }
        }

        var outputCount: Int {
            switch plan {
            case .consolidation(let plan): return plan.winnerSourceIndexes.count
            case .merge(let plan): return plan.winnerSourceIndexes.count
            }
        }

        var omittedCount: Int { inputCount - outputCount }

        var nonEligibleCount: Int { nonEligibleSourceIndexes.count }

        var decisions: [DuplicateDecision] {
            switch plan {
            case .consolidation(let plan): return plan.decisions
            case .merge(let plan): return plan.decisions
            }
        }

        var fingerprint: String {
            switch plan {
            case .consolidation(let plan): return plan.sourceFingerprint
            case .merge(let plan): return plan.mergeFingerprint
            }
        }

        /// Merge copies in plan (ascending playlist id) order; nil for
        /// consolidate mode.
        var copies: [PlaylistSnapshot]? {
            if case .merge(let plan) = plan { return plan.copies }
            return nil
        }

        /// A5: this audit's LIVE per-copy counts — merge: each copy's track
        /// count in plan (ascending playlist id) order; consolidate: the
        /// single source track count.
        var liveCopyCounts: [Int] {
            switch plan {
            case .consolidation(let plan): return [plan.sourceTrackCount]
            case .merge(let plan): return plan.copies.map { $0.tracks.count }
            }
        }

        private var nonEligibleSourceIndexes: [Int] {
            switch plan {
            case .consolidation(let plan): return plan.nonEligibleSourceIndexes
            case .merge(let plan): return plan.nonEligibleSourceIndexes
            }
        }

        /// The non-eligible tracks (no semantic key; retained in place).
        var nonEligibleTracks: [TrackSnapshot] {
            let indexes = Set(nonEligibleSourceIndexes)
            let tracks: [TrackSnapshot]
            switch plan {
            case .consolidation(let plan): tracks = plan.sourceTracks
            case .merge(let plan): tracks = plan.combinedTracks
            }
            return tracks.filter { indexes.contains($0.sourceIndex) }
        }

        /// The planned output tracks in output order (winner indexes mapped
        /// the way the verifiers map them). Feeds the near-identical-winner
        /// pairs panel on screen 2 (M8).
        var outputTracks: [TrackSnapshot] {
            let tracks: [TrackSnapshot]
            let winnerIndexes: [Int]
            switch plan {
            case .consolidation(let plan):
                tracks = plan.sourceTracks
                winnerIndexes = plan.winnerSourceIndexes
            case .merge(let plan):
                tracks = plan.combinedTracks
                winnerIndexes = plan.winnerSourceIndexes
            }
            return planOutputTracks(winnerSourceIndexes: winnerIndexes, from: tracks)
        }
    }

    /// The M8 source-browser listing lifecycle. `LoadedListing` carries both
    /// the raw enumeration and its derived sections so views never regroup.
    /// `fromCache` (M11) marks a listing restored from the persisted cache —
    /// browser-only data; audits and applies ALWAYS re-read live.
    struct LoadedListing: Equatable, Sendable {
        let listings: [PlaylistListing]
        let sections: PlaylistBrowseSections
        let scannedAt: Date
        let fromCache: Bool
    }

    enum ListingState: Equatable, Sendable {
        case idle
        case scanning(started: Date)
        case failed(AuditFailure)
        case loaded(LoadedListing)
    }

    // MARK: Wave B mutation-gate value types (B2/B4/B5/B6)

    /// Everything an ARMED gate holds: the persisted plan, its artifact
    /// paths, the pre-mutation listing baseline, the freshness window, the
    /// typed-token requirements (unique-identity rule, B4), and the rename
    /// collision warning (B5 — text, never a block).
    struct MutationGateState: Equatable, Sendable {
        let plan: MutationPlan
        let paths: MutationAuditPaths
        /// The fresh listing the mutation audit captured — the baseline
        /// `performMutation` fingerprints against and diffs against.
        let baseline: [PlaylistListing]
        let armedAt: Date
        /// Artifact creation + 600 s (B2).
        let freshnessDeadline: Date
        /// True when >1 live playlist shares the exact name.
        let requiresCountToken: Bool
        /// True when the track count is ambiguous among those same-name
        /// copies too.
        let requiresPIDSuffixToken: Bool
        let collisionWarning: String?
        /// The typed-name token target (B4/B5): the playlist's current
        /// exact name for delete and plain rename; the canonical
        /// DESTINATION name for Align-names renames, whose deviant current
        /// names are practically untypeable.
        let confirmationName: String
    }

    /// Live execution progress: single mutations are copy 0 of 1; the
    /// cleanup orchestration (B3) reuses this per copy. `startedAt` feeds
    /// the ticking elapsed readout (a bare spinner is forbidden).
    struct MutationExecutionProgress: Equatable, Sendable {
        let copyIndex: Int
        let copyCount: Int
        let phase: MutationPhase
        let startedAt: Date
    }

    /// The terminal display: verified or failed closed, plus the consumed
    /// artifact reference and the result-report location.
    struct MutationFinishDisplay: Equatable, Sendable {
        let kind: MutationKind
        let playlistName: String
        let newName: String?
        let verified: Bool
        let mismatches: [String]
        let informational: [String]
        let consumedPlanFileName: String
        let resultReportPath: String?
        /// Non-nil when persisting the result report failed (loud, like
        /// `runReportWriteFailure`).
        let resultWriteFailure: String?
    }

    /// The gate lifecycle (contract B2/B4/B5). `auditing` carries its start
    /// instant so the surface can tick elapsed time.
    enum MutationGatePhase: Equatable {
        case idle
        case auditing(started: Date)
        case armed(MutationGateState)
        case executing(MutationExecutionProgress)
        case finished(MutationFinishDisplay)
        case refused(String)
    }

    // MARK: dependencies

    private let makeRunner: @Sendable () -> any ScriptRunner
    private let defaults: UserDefaults
    private let cacheDirectoryPath: String
    private nonisolated static let outputDirectoryDefaultsKey = "AuditOutputDirectoryPath"
    private nonisolated static let confirmEachApplyDefaultsKey = "ConfirmEachApply"
    private nonisolated static let pauseOnJudgmentDefaultsKey = "PauseOnJudgmentItems"
    // UI rework Part 2 — user preferences (Settings destination).
    private nonisolated static let appearanceModeDefaultsKey = "AppearanceMode"
    private nonisolated static let reloadLibraryOnStartDefaultsKey = "ReloadLibraryOnStart"
    private nonisolated static let defaultBrowserTabOnLaunchDefaultsKey = "DefaultBrowserTabOnLaunch"
    private nonisolated static let playSoundOnRunFinishDefaultsKey = "PlaySoundOnRunFinish"
    /// Injectable finish-run sound hook (UI rework Part 2): fires from
    /// `finishRun()` when `playSoundOnRunFinish` is on. Defaults to the real
    /// `NSSound` playback; tests inject a counting closure instead.
    private let playFinishSound: @Sendable () -> Void

    /// The app-launch session identity stamped into every mutation artifact
    /// (B2: a gate can only ever arm against an artifact from THIS launch).
    let appSessionID: String
    /// Injectable clock for the 600 s mutation-artifact freshness contract.
    private let now: @Sendable () -> Date

    private var listingCacheURL: URL {
        URL(fileURLWithPath: cacheDirectoryPath, isDirectory: true)
            .appendingPathComponent("listing-cache.json")
    }

    // MARK: observable state

    /// The audit mode. MUTATE ONLY through `setMode(_:)` (fix round 1,
    /// finding 1): a raw setter with a didSet cannot veto the change, and a
    /// mid-apply mode flip would bump the generation and silently orphan the
    /// guarded write's outcome — including fail-closed diagnostics after a
    /// write that may have landed in Music.
    private(set) var mode: ConsolidatorMode = .consolidate

    var playlistName: String = ""
    private(set) var outputDirectoryPath: String
    private(set) var preflight: AutomationPreflightResult?
    private(set) var isPreflightRunning = false
    private(set) var runState: RunState = .idle
    private(set) var result: CompletedAudit?
    var step: FlowStep = .source {
        didSet {
            if step == .review { hasVisitedReview = true }
        }
    }

    /// Whether screen 2 has been visited for the CURRENT audit (fix round
    /// 4, item 3: the confirm gate requires the plan review to have been
    /// seen). Set by the `step` transition, cleared with the audit.
    private(set) var hasVisitedReview = false

    // Confirm-gate state (screen 3). Gate (a) — the "sources are never
    // modified" notice — is unconditionally displayed by the view.
    var reviewedPlanToggle = false
    var typedTargetName = ""

    // M11 settings (persisted; both default OFF per Sergio).
    private(set) var confirmEachApply = false
    private(set) var pauseOnJudgmentItems = false

    // UI rework Part 2 — user preferences (persisted; see the matching
    // setters and the "MARK: preferences" section below).
    private(set) var appearanceMode: AppearanceMode = .system
    private(set) var reloadLibraryOnStart = false
    private(set) var defaultBrowserTabOnLaunch: BrowserTab = .merge
    private(set) var playSoundOnRunFinish = false

    // M11 run state (the unattended batch + its mandatory report).
    private(set) var isRunUnattended = false
    private(set) var runStartedAt: Date?
    private(set) var runRecords: [RunItemRecord] = []
    private(set) var finishedRunReport: BatchRunReport?
    /// The session's last finished batch run (nil until one finishes).
    /// Survives `acknowledgeRunReport` and `startOver` — spec C2.2 state 4
    /// ("this session").
    private(set) var lastRunSummary: LastRunSummary?
    private(set) var runReportPath: String?
    /// LOUD persistence failure for the mandatory report artifact (fix
    /// round 1, minor a): nil on success; the verbatim reason otherwise.
    private(set) var runReportWriteFailure: String?

    // Wave C1 failure-taxonomy state (spec C1.3). Paired with `applyState`:
    // non-nil exactly while applyState is .failed; cleared wherever the
    // apply state resets.
    private(set) var applyFailureClass: ApplyFailureClass?

    // Wave C1 leftover-resolve state (spec C1.5). The resolve read is OSA
    // activity: `isResolvingLeftoverTarget` folds into `isMutationBusy`, so
    // every existing mutual-exclusion guard covers it.
    private(set) var isResolvingLeftoverTarget = false
    private(set) var leftoverResolveNotice: String?
    /// Fix round 1 (combined Task 4+5 review, Critical finding): which
    /// target the in-flight (or last-finished) resolve is FOR — the
    /// run-report screen's multiple rows scope their spinner/notice
    /// rendering to the row whose `targetName` scalar-exact-matches this,
    /// never rendering under every qualifying row. Set alongside
    /// `isResolvingLeftoverTarget`/`leftoverResolveNotice` in
    /// `startDeleteLeftoverTarget`; cleared wherever `leftoverResolveNotice`
    /// is cleared.
    private(set) var leftoverResolveTargetName: String?
    @ObservationIgnored private(set) var leftoverResolveTask: Task<Void, Never>?
    /// Fix round 1 (Important finding): generation guard for the resolve's
    /// asynchronous completion, mirroring `mutationGeneration`/`runGeneration`.
    /// Bumped by a fresh resolve start AND by `discardCompletedAudit()` /
    /// `resetQueue()` (defense in depth: navigation guards below refuse
    /// while `isMutationBusy`, but any future reset path that does not check
    /// it can never let an orphaned resolve arm a gate or write a stale
    /// notice after the context it belongs to is gone).
    @ObservationIgnored private var leftoverResolveGeneration = 0
    /// Honored at the next item boundary; the current item always finishes
    /// its guarded apply (or fails closed) first.
    @ObservationIgnored private var stopRequested = false

    /// Total seconds of the most recent finished apply (per-item time).
    private(set) var lastApplySeconds: Double?
    @ObservationIgnored private var applyStartedAt: Date?

    // M9 in-app apply state (screens 4-6).
    private(set) var applyState: ApplyState = .idle

    /// The final stage sequence of the last finished apply (success or
    /// failure) — the progress list freezes here for the result screens and
    /// the flow tests' order assertions.
    private(set) var completedApplyStages: [ApplyStage]?

    /// The in-flight apply task (exposed so tests can await it). The apply
    /// itself is never cancelled: the guarded write is atomic from the
    /// app's view.
    @ObservationIgnored private(set) var applyTask: Task<Void, Never>?

    // Wave B mutation-gate state (B2/B4/B5; attended only — B6). The typed
    // token inputs are bound raw: NEVER trimmed, folded, or normalized.
    private(set) var mutationGatePhase: MutationGatePhase = .idle
    var typedMutationName = ""
    var typedMutationCount = ""
    var typedMutationPIDSuffix = ""

    /// Browser rename editor state (Task 15): which row's editor is open
    /// and its destination-name draft. The DRAFT is an input, not a
    /// typed-confirm token; the gate's own tokens remain unnormalized.
    var browserRenamePID: String?
    var browserRenameDraft = ""

    /// The in-flight mutation task (audit read or guarded dispatch),
    /// exposed so tests can await it.
    @ObservationIgnored private(set) var mutationTask: Task<Void, Never>?

    /// Generation guard for the gate's asynchronous state applications
    /// (bumped by every new mutation audit and every dismissal).
    @ObservationIgnored private var mutationGeneration = 0

    // M8 source-browser state.
    private(set) var listingState: ListingState = .idle
    var searchText: String = ""

    // Browser list ordering (session-only, DISPLAY-ONLY — never feeds a
    // guard, plan, or queue; Sergio, 2026-08-05).
    private(set) var browserSortKey: BrowserSortKey = .name
    private(set) var browserSortAscending = true

    func toggleBrowserSort(_ key: BrowserSortKey) {
        if browserSortKey == key {
            browserSortAscending.toggle()
        } else {
            browserSortKey = key
            browserSortAscending = true
        }
    }
    var browserSelection: BrowserSelection?
    /// Consolidate-tab checkbox picks, by persistent ID (unique by the
    /// listing parse's own gate; names can repeat and canonically-equivalent
    /// name strings would collide in a Set).
    private(set) var checkedPersistentIds: Set<String> = []
    /// Merge-tab checkbox picks (M10), by EXACT group name. An ARRAY with
    /// scalar-exact membership, never a Set<String>: String hashing merges
    /// canonically-equivalent names, and two distinct exact-name groups can
    /// be canonically equivalent (the NFC/NFD twin class).
    private(set) var checkedGroupNames: [String] = []
    /// The shift-click range anchor (spec A4): the id of the last directly
    /// clicked checkable row — a group name on the merge tab, a persistent
    /// ID on the consolidate tab. Cleared on rescan and on a mode (tab)
    /// switch so a range can never span two listings or two tabs.
    private(set) var selectionAnchor: String?
    private(set) var queue: [AuditQueueItem] = []
    private(set) var queueIndex = 0
    private(set) var isQueueActive = false

    /// The in-flight pipeline task (exposed so tests and cancellation can
    /// await/cancel it).
    @ObservationIgnored private(set) var auditTask: Task<Void, Never>?

    /// The in-flight listing scan task (exposed so tests can await it).
    @ObservationIgnored private(set) var scanTask: Task<Void, Never>?

    /// Guards every asynchronous state application: bumped by each new run
    /// and by every discard, so a superseded pipeline can never write state.
    @ObservationIgnored private var runGeneration = 0

    /// The listing scan's own generation guard (scans and audits are
    /// mutually exclusive but separately superseded).
    @ObservationIgnored private var scanGeneration = 0

    /// The exact name the in-flight audit was started with — the queue's
    /// transition guard (playlistName is mutable UI state; this is not).
    @ObservationIgnored private var activeAuditName = ""

    // MARK: init

    init(
        makeRunner: @escaping @Sendable () -> any ScriptRunner = { OSAKitRunner() },
        defaults: UserDefaults = .standard,
        defaultOutputDirectoryPath: String = "/Users/sergio.farfan/projects/git/MusicConsolidator/reports",
        cacheDirectoryPath: String = defaultListingCacheDirectoryPath(),
        appSessionID: String = UUID().uuidString,
        now: @escaping @Sendable () -> Date = { Date() },
        playFinishSound: @escaping @Sendable () -> Void = { NSSound(named: "Glass")?.play() }
    ) {
        self.makeRunner = makeRunner
        self.defaults = defaults
        self.cacheDirectoryPath = cacheDirectoryPath
        self.appSessionID = appSessionID
        self.now = now
        self.playFinishSound = playFinishSound
        self.outputDirectoryPath = defaults.string(forKey: Self.outputDirectoryDefaultsKey)
            ?? defaultOutputDirectoryPath
        self.confirmEachApply = defaults.bool(forKey: Self.confirmEachApplyDefaultsKey)
        self.pauseOnJudgmentItems = defaults.bool(forKey: Self.pauseOnJudgmentDefaultsKey)
        self.appearanceMode = AppearanceMode(
            rawValue: defaults.string(forKey: Self.appearanceModeDefaultsKey) ?? ""
        ) ?? .system
        self.reloadLibraryOnStart = defaults.bool(forKey: Self.reloadLibraryOnStartDefaultsKey)
        self.defaultBrowserTabOnLaunch = BrowserTab(
            rawValue: defaults.string(forKey: Self.defaultBrowserTabOnLaunchDefaultsKey) ?? ""
        ) ?? .merge
        self.playSoundOnRunFinish = defaults.bool(forKey: Self.playSoundOnRunFinishDefaultsKey)
        // M11: instant startup from the persisted listing cache (browser
        // only; audits/applies always re-read live). No Apple event fires
        // here — the cache is a local file.
        if let cache = loadListingCache(at: listingCacheURL) {
            let listings = playlistListings(from: cache)
            listingState = .loaded(
                LoadedListing(
                    listings: listings,
                    sections: buildPlaylistBrowseSections(from: listings),
                    scannedAt: cache.scannedAt,
                    fromCache: true
                )
            )
        }
    }

    // MARK: M11 settings

    func setConfirmEachApply(_ value: Bool) {
        confirmEachApply = value
        defaults.set(value, forKey: Self.confirmEachApplyDefaultsKey)
    }

    func setPauseOnJudgmentItems(_ value: Bool) {
        pauseOnJudgmentItems = value
        defaults.set(value, forKey: Self.pauseOnJudgmentDefaultsKey)
    }

    // MARK: preferences (UI rework Part 2)

    func setAppearanceMode(_ value: AppearanceMode) {
        appearanceMode = value
        defaults.set(value.rawValue, forKey: Self.appearanceModeDefaultsKey)
    }

    func setReloadLibraryOnStart(_ value: Bool) {
        reloadLibraryOnStart = value
        defaults.set(value, forKey: Self.reloadLibraryOnStartDefaultsKey)
    }

    /// Only the persisted preference — never the live `browserTab`. Applied
    /// to `browserTab` exactly once, at launch (see `ConsolidatorFlowView`'s
    /// one-shot launch-effects block).
    func setDefaultBrowserTabOnLaunch(_ value: BrowserTab) {
        defaultBrowserTabOnLaunch = value
        defaults.set(value.rawValue, forKey: Self.defaultBrowserTabOnLaunchDefaultsKey)
    }

    func setPlaySoundOnRunFinish(_ value: Bool) {
        playSoundOnRunFinish = value
        defaults.set(value, forKey: Self.playSoundOnRunFinishDefaultsKey)
    }

    // MARK: derived state

    var isRunning: Bool {
        if case .running = runState { return true }
        return false
    }

    /// True while an in-app apply is in flight (M9).
    var isApplying: Bool {
        if case .running = applyState { return true }
        return false
    }

    /// True while an unattended run OWNS the flow — including the judgment
    /// PAUSE, where nothing is running or applying but prior auto-applied
    /// writes exist and the mandatory report is still pending (fix round 1,
    /// finding 1: the pause window must be as guarded as the busy states).
    var isUnattendedRunActive: Bool {
        isRunUnattended && isQueueActive
    }

    /// True once this audit's one apply has finished — success or failure
    /// (the audit is consumed; only Start over / next queue item remain).
    var isApplyConsumed: Bool {
        switch applyState {
        case .succeeded, .failed: return true
        case .idle, .running: return false
        }
    }

    // MARK: Wave B mutation-gate derived state

    /// True while the mutation gate holds the OSA slot (its audit read or
    /// its guarded dispatch) — joined into the M8/M9 mutual-exclusion set.
    var isMutationBusy: Bool {
        // Wave C1: the leftover-resolve read holds the OSA slot too — more
        // exclusion, never less (fail-closed direction).
        if isResolvingLeftoverTarget { return true }
        // Cleanup-scan hotfix (2026-08-05): the scan's listing read holds
        // the OSA slot as well; every other entry point refuses meanwhile.
        if case .scanning = cleanupScanState { return true }
        switch mutationGatePhase {
        case .auditing, .executing: return true
        case .idle, .armed, .finished, .refused: return false
        }
    }

    var armedMutation: MutationGateState? {
        if case .armed(let state) = mutationGatePhase { return state }
        return nil
    }

    /// The typed name token, scalar-exact (String == would accept
    /// canonically-equivalent drift — the confirm-gate rule, reused).
    var mutationTypedNameMatches: Bool {
        guard let armed = armedMutation else { return false }
        return scalarExact(typedMutationName, armed.confirmationName)
    }

    /// First-divergence diagnostics for the name token — the same
    /// `firstScalarDivergence` helper the confirm gate renders.
    var mutationNameDivergence: ScalarDivergence? {
        guard let armed = armedMutation, !typedMutationName.isEmpty,
              !mutationTypedNameMatches else { return nil }
        return firstScalarDivergence(
            expected: armed.confirmationName, actual: typedMutationName
        )
    }

    /// All required identity tokens satisfied — scalar-exact, NEVER
    /// normalized (no trim, no case fold, no NFC/NFD folding; spec B5).
    /// Persistent IDs are 16-character ASCII hex, so `suffix(4)` is exactly
    /// the last four scalars.
    var mutationGateSatisfied: Bool {
        guard let armed = armedMutation, mutationTypedNameMatches else { return false }
        if armed.requiresCountToken,
           !scalarExact(typedMutationCount, String(armed.plan.trackCount)) {
            return false
        }
        if armed.requiresPIDSuffixToken,
           !scalarExact(
               typedMutationPIDSuffix,
               String(armed.plan.playlistPersistentID.suffix(4))
           ) {
            return false
        }
        return true
    }

    var canStartAudit: Bool {
        !isRunning && !playlistName.isEmpty
    }

    /// The exact CLI target name for the completed audit's source.
    var targetName: String? {
        result.map { defaultTargetName(mode: $0.mode, sourceName: $0.sourceName) }
    }

    /// Gate (c): the typed re-entry must match the target name scalar-exactly
    /// (String == would accept canonically-equivalent drift).
    var typedTargetNameMatches: Bool {
        guard let targetName else { return false }
        return scalarExact(typedTargetName, targetName)
    }

    /// The confirm-gate near-miss diagnostic (M8): once something has been
    /// typed and it is not an exact match, WHICH scalar differs — the
    /// first-divergence index plus U+XXXX of expected vs typed.
    var typedNameDivergence: ScalarDivergence? {
        guard let targetName, !typedTargetName.isEmpty, !typedTargetNameMatches else {
            return nil
        }
        return firstScalarDivergence(expected: targetName, actual: typedTargetName)
    }

    // MARK: browser derived state (M8)

    var isScanning: Bool {
        if case .scanning = listingState { return true }
        return false
    }

    var loadedListing: LoadedListing? {
        if case .loaded(let loaded) = listingState { return loaded }
        return nil
    }

    var loadedSections: PlaylistBrowseSections? {
        loadedListing?.sections
    }

    /// The sections as the browser DISPLAYS them: the loaded sections
    /// through the active search filter (SourceSelectionView applies the
    /// same pure function). Range order and select-all eligibility follow
    /// what the user actually sees; checks hidden by the filter survive.
    private var displayedBrowserSections: PlaylistBrowseSections? {
        loadedSections.map { filteredSections($0, query: searchText) }
    }

    var currentQueueItem: AuditQueueItem? {
        guard isQueueActive, queue.indices.contains(queueIndex) else { return nil }
        return queue[queueIndex]
    }

    /// Scalar-exact membership for the merge-tab group checks (M10).
    func isGroupChecked(_ name: String) -> Bool {
        checkedGroupNames.contains { scalarExact($0, name) }
    }

    // MARK: step navigation (fix round 4, item 3)

    /// Step legality — the single source of truth shared by the sidebar
    /// rows and the in-screen buttons: step 2 requires a completed audit,
    /// step 3 additionally requires step 2 to have been visited, and step 4
    /// requires an apply to have started (it is entered by the Apply button,
    /// not by navigation). While an apply is IN FLIGHT navigation locks to
    /// the apply screen — the guarded write must not be walked away from.
    func canNavigate(to step: FlowStep) -> Bool {
        if isApplying { return step == .apply }
        // M11: while an unattended run works (audits included), navigation
        // locks to the run surface — nothing reachable may interfere.
        if isRunUnattended, isQueueActive, isRunning { return step == .apply }
        switch step {
        case .source:
            return true
        case .review:
            return result != nil && !isRunning
        case .confirm:
            return result != nil && !isRunning && hasVisitedReview
        case .apply:
            return isApplyConsumed || (isRunUnattended && isQueueActive)
        case .report:
            return finishedRunReport != nil
        }
    }

    /// Navigate when legal; a no-op otherwise (the sidebar explains why via
    /// `stepBlockedReason`).
    func navigate(to step: FlowStep) {
        guard canNavigate(to: step) else { return }
        self.step = step
    }

    /// Why a step is currently unreachable, for the sidebar's `.help`.
    func stepBlockedReason(for step: FlowStep) -> String? {
        guard !canNavigate(to: step) else { return nil }
        if isApplying { return "Wait for the running apply to finish." }
        if isRunning { return "Wait for the running check to finish." }
        switch step {
        case .source:
            return nil
        case .review:
            return "Run a read-only check first."
        case .confirm:
            return result == nil
                ? "Run a read-only check first."
                : "Review the plan (step 2) first."
        case .apply:
            return "Apply from the confirm gate (step 3) first."
        case .report:
            return "Finish a batch run first \u{2014} its report lands here."
        }
    }

    // MARK: Wave C2 destination navigation (spec C2.1/C2.3)

    /// Where the detail column is. MUTATE ONLY through
    /// `selectDestination(_:)` (the `setMode(_:)` guarded-setter posture):
    /// a raw setter could walk away from a guarded write's live surface.
    private(set) var selectedDestination: AppDestination = .library

    /// The C2.3 hot-path lock — the EXACT predicate `canNavigate(to:)`
    /// opens with today: an apply in flight, or an unattended run actively
    /// working (audits included). While hot, selection locks to
    /// `.activity`. Deliberately NOT shared with canNavigate (which
    /// survives verbatim as the staged panel's sequencer).
    var isDestinationLocked: Bool {
        if isApplying { return true }
        if isRunUnattended, isQueueActive, isRunning { return true }
        return false
    }

    /// Destination legality — the single source of truth the sidebar rows
    /// disable on.
    func canSelect(_ destination: AppDestination) -> Bool {
        !isDestinationLocked || destination == .activity
    }

    /// Select when legal; a no-op otherwise (the sidebar explains why via
    /// `destinationBlockedReason(for:)`) — the `navigate(to:)` posture.
    func selectDestination(_ destination: AppDestination) {
        guard canSelect(destination) else { return }
        selectedDestination = destination
    }

    /// Why a destination is currently unreachable, for the sidebar's
    /// `.help` — the existing blocked-reason strings, reused verbatim.
    func destinationBlockedReason(for destination: AppDestination) -> String? {
        guard !canSelect(destination) else { return nil }
        if isApplying { return "Wait for the running apply to finish." }
        return "Wait for the running check to finish."
    }

    /// The Activity sidebar chip (spec C2.3), derived per render.
    var activityChip: ActivityChipState {
        activityChipState(
            isRunning: isRunning,
            isApplying: isApplying,
            isUnattendedRunActive: isUnattendedRunActive,
            hasAttendedResult: result != nil,
            hasFinishedReport: finishedRunReport != nil
        )
    }

    var isQueueComplete: Bool {
        isQueueActive && !queue.isEmpty && queueIndex >= queue.count
    }

    /// All confirm gates: reviewed toggle + scalar-exact typed re-entry over
    /// a completed audit. Only then is the Apply button revealed (M9; the
    /// M7/M8 CLI hand-off panel is gone).
    var gateSatisfied: Bool {
        result != nil && reviewedPlanToggle && typedTargetNameMatches
    }

    /// Whether the one in-app apply may start: every gate satisfied, no
    /// other OSA activity, and this audit's apply not yet consumed
    /// (one apply per fresh audit — success or failure, there is no second
    /// attempt without a new audit).
    var canApply: Bool {
        guard case .idle = applyState else { return false }
        // hasVisitedReview aligns the model gate with the navigation gate
        // (fix round 1, minor b — defense-in-depth: it is true by
        // construction whenever a gate can be satisfied, since a completed
        // audit lands on step 2).
        return gateSatisfied && hasVisitedReview && !isRunning && !isScanning
    }

    /// The plan artifact's basename, for the freshness note.
    var planFileName: String? {
        result.map { artifactBasename($0.paths.planJson) }
    }

    // MARK: actions

    func setOutputDirectory(path: String) {
        outputDirectoryPath = path
        defaults.set(path, forKey: Self.outputDirectoryDefaultsKey)
    }

    /// The CURRENT output directory, read live from the given defaults —
    /// the single owner of the key (M11 fix round 1, minor e: the history
    /// window reads through here instead of duplicating the key).
    nonisolated static func currentOutputDirectoryPath(
        defaults: UserDefaults = .standard
    ) -> String {
        defaults.string(forKey: outputDirectoryDefaultsKey)
            ?? "/Users/sergio.farfan/projects/git/MusicConsolidator/reports"
    }

    /// The single mutating entry point for mode changes (fix round 1,
    /// finding 1). Refused while an apply is in flight — the mode picker is
    /// also disabled then, but the model guard is the load-bearing one. A
    /// same-mode set is a no-op (never discards). A legal change discards
    /// the completed audit and resets the queue (a queue is always all one
    /// mode — M10; the highlighted row is tab-local; the loaded listing and
    /// BOTH modes' checkbox picks are mode-independent and survive).
    func setMode(_ newMode: ConsolidatorMode) {
        guard !isApplying, !isUnattendedRunActive, newMode != mode else { return }
        mode = newMode
        discardCompletedAudit()
        resetQueue()
        browserSelection = nil
        selectionAnchor = nil
    }

    /// Automation preflight (reused M6 surface). Blocks while the TCC
    /// consent prompt is on screen, so it runs off the main actor.
    func runPreflight() {
        guard !isPreflightRunning else { return }
        isPreflightRunning = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                AutomationPreflight.determineMusicAutomationPermission(askUserIfNeeded: true)
            }.value
            preflight = outcome
            isPreflightRunning = false
        }
    }

    // MARK: browser actions (M8)

    /// Enumerate the library through the STATIC listing script (read-only).
    /// Single-flight, and mutually exclusive with audits and applies:
    /// overlapping OSA activity is refused at the model level, not just in
    /// the UI.
    func rescanLibrary() {
        guard !isScanning, !isRunning, !isApplying, !isMutationBusy else { return }
        scanGeneration += 1
        let generation = scanGeneration
        let make = makeRunner

        listingState = .scanning(started: Date())
        scanTask = Task { [weak self] in
            do {
                let loaded = try await Self.scanStage(make: make)
                self?.applyListing(loaded, generation: generation)
            } catch {
                self?.applyListingFailure(error, generation: generation)
            }
        }
    }

    /// Toggle one consolidate-tab checkbox. Only single-copy playlists are
    /// eligible: the engine fails closed on ambiguous names, so group
    /// members are refused here too (the UI also disables them).
    /// `rangeSelect` (spec A4) applies the clicked row's new state to the
    /// whole displayed checkable range from the anchor; every direct click
    /// re-establishes the anchor.
    func toggleChecked(persistentId: String, rangeSelect: Bool = false) {
        guard let sections = displayedBrowserSections,
              sections.singletons.contains(where: { scalarExact($0.persistentId, persistentId) })
        else { return }
        let checkable = Set(sections.singletons.map(\.persistentId))
        let orderedIDs = sections.allPlaylists.map(\.persistentId)
            .filter { checkable.contains($0) }
        let outcome = applyRangeToggle(
            anchor: rangeSelect ? selectionAnchor : nil,
            clicked: persistentId,
            orderedIDs: orderedIDs,
            current: checkedPersistentIds
        )
        checkedPersistentIds = outcome.selection
        selectionAnchor = outcome.newAnchor
    }

    /// M10 call sites (older wiring, existing tests) route through the
    /// range-capable toggle as a plain click.
    func toggleCheckedGroup(name: String) {
        toggleChecked(name: name, rangeSelect: false)
    }

    /// Toggle one merge-tab GROUP checkbox (M10 semantics; range-capable
    /// since Wave A). Only displayed exact-name groups are eligible — near
    /// matches and singletons are refused here too, so cross-name merging
    /// stays impossible by construction. The checked container stays an
    /// ARRAY with scalar-exact membership (never Set<String>: String
    /// hashing merges canonically-equivalent names); the range outcome is
    /// reconciled back into it in section order, and checked groups hidden
    /// by the active filter survive untouched.
    func toggleChecked(name: String, rangeSelect: Bool) {
        guard let sections = displayedBrowserSections,
              sections.groups.contains(where: { scalarExact($0.name, name) })
        else { return }
        let orderedIDs = sections.groups.map(\.name)
        let outcome = applyRangeToggle(
            anchor: rangeSelect ? selectionAnchor : nil,
            clicked: name,
            orderedIDs: orderedIDs,
            current: Set(checkedGroupNames)
        )
        let hidden = checkedGroupNames.filter { checked in
            !orderedIDs.contains { scalarExact($0, checked) }
        }
        let displayedChecked = orderedIDs.filter { candidate in
            outcome.selection.contains { scalarExact($0, candidate) }
        }
        checkedGroupNames = hidden + displayedChecked
        selectionAnchor = outcome.newAnchor
    }

    /// Cmd+A / the section-header "Select all" (spec A4). Merge tab: every
    /// DISPLAYED mergeable group — near matches and singletons are not
    /// checkable there. Consolidate tab: every displayed checkable row —
    /// the singletons, near-match-flagged ones included (they are legal to
    /// consolidate). Existing checks, including ones hidden by the active
    /// filter, survive.
    func selectAllEligible() {
        guard let sections = displayedBrowserSections else { return }
        switch mode {
        case .merge:
            let additions = sections.groups.map(\.name).filter { name in
                !checkedGroupNames.contains { scalarExact($0, name) }
            }
            checkedGroupNames.append(contentsOf: additions)
        case .consolidate:
            checkedPersistentIds.formUnion(sections.singletons.map(\.persistentId))
        }
    }

    /// Cmd+D / the section-header "Clear" (spec A4): clears the ACTIVE
    /// tab's checks and the range anchor. The other tab's checks survive
    /// (checkbox picks are mode-independent — setMode's documented
    /// contract).
    func clearSelection() {
        switch mode {
        case .merge:
            checkedGroupNames = []
        case .consolidate:
            checkedPersistentIds = []
        }
        selectionAnchor = nil
    }

    /// Build the batch queue from the current mode's checks — consolidate:
    /// checked single-copy playlists; merge (M10): checked exact-name
    /// groups — in section (alphabetical) order, and start item 1's audit.
    /// A queue is always ALL one mode (each mode builds only from its own
    /// checks; a mode switch resets any active queue). Each item still
    /// flows through its own plan review + confirm gate + apply — no bulk
    /// approve.
    func startQueue() {
        guard !isRunning, !isScanning, !isApplying, !isMutationBusy, !isQueueActive,
              let sections = loadedSections else { return }
        // A5: capture scan-time counts with each item — per-copy for merge
        // groups (copies are already in ascending playlist-id order, the
        // concatenation order), the single listing count for consolidate.
        let items: [AuditQueueItem]
        switch mode {
        case .consolidate:
            items = sections.allPlaylists
                .filter { checkedPersistentIds.contains($0.persistentId) }
                .map {
                    AuditQueueItem(
                        name: $0.name, status: .pending, copyCounts: [$0.trackCount]
                    )
                }
        case .merge:
            items = sections.groups
                .filter { isGroupChecked($0.name) }
                .map {
                    AuditQueueItem(
                        name: $0.name,
                        status: .pending,
                        copyCounts: $0.copies.map(\.trackCount)
                    )
                }
        }
        guard !items.isEmpty else { return }

        queue = items
        queueIndex = 0
        isQueueActive = true
        // M11: initialize the run. Unattended is the contract-amendment
        // default (one-time launch approval + unchanged engine guards +
        // the mandatory post-run report); "Confirm each apply" restores
        // the M9 per-item gate flow.
        isRunUnattended = !confirmEachApply
        runStartedAt = Date()
        runRecords = []
        finishedRunReport = nil
        runReportPath = nil
        runReportWriteFailure = nil
        stopRequested = false
        selectedDestination = .activity
        startCurrentQueueItemAudit()
        // AFTER the audit start (whose discard resets the step): the
        // unattended run owns the apply surface for its whole duration.
        if isRunUnattended { step = .apply }
    }

    /// Request an early end of an unattended run: the CURRENT item always
    /// finishes its guarded apply (or fails closed) first; remaining items
    /// are recorded as not run. At an IDLE boundary — the judgment pause —
    /// the run finishes immediately: the report is built and persisted NOW
    /// (fix round 1, finding 1: stopping is the sanctioned exit; wiping is
    /// impossible).
    func requestStopAfterCurrentItem() {
        guard isRunUnattended, isQueueActive else { return }
        stopRequested = true
        if !isRunning, !isApplying {
            finishRun()
        }
    }

    /// Skip the current item — any state short of APPLIED: once the item's
    /// verified apply happened, the playlist EXISTS in Music, and recording
    /// .skipped would falsify the record of a live write (M9 fix round 1,
    /// finding 2 — the status check the M8 comment promised). The
    /// M8-fix-round-1 guard set also applies: advancing while a scan/read/
    /// apply holds the OSA slot would increment the index, startAudit would
    /// refuse, and the next item would strand as .pending under the finished
    /// item's stale plan.
    func skipCurrentQueueItem() {
        // Final review, Finding I-2: the C1 shortcut renders on this same
        // queue failure screen; a resolve in flight must refuse Skip too —
        // advancing the queue while `startCurrentQueueItemAudit` would be
        // silently refused by `!isMutationBusy` strands the next item
        // `.pending` under a stale plan.
        guard let current = currentQueueItem, current.status != .applied,
              !isRunning, !isScanning, !isApplying, !isMutationBusy else { return }
        queue[queueIndex].status = .skipped
        recordRunItem(named: current.name, outcome: .skipped)
        advanceQueue()
    }

    /// Advance the queue after the current item's VERIFIED apply (M9: the
    /// item is marked `.applied` by the apply pipeline itself; there is no
    /// hand-off state anymore). Refused until the apply actually succeeded,
    /// and refused while any OSA activity is in flight — including a C1
    /// leftover resolve (final review, Finding I-2, symmetry).
    func continueQueueAfterApply() {
        guard let current = currentQueueItem, current.status == .applied,
              !isRunning, !isScanning, !isApplying, !isMutationBusy else { return }
        advanceQueue()
    }

    /// Re-audit the current failed item (a FRESH audit — a failed apply
    /// consumed the old plan; nothing is ever re-applied).
    func retryCurrentQueueItem() {
        // Final review, Finding I-2: without `!isMutationBusy`, Retry would
        // delete the failed record and then silently fail to start the
        // fresh audit (startAudit refuses on isMutationBusy), stranding the
        // item `.pending` and falsifying the mandatory report as `.notRun`.
        guard let current = currentQueueItem, current.status == .failed,
              !isRunning, !isScanning, !isApplying, !isMutationBusy else { return }
        queue[queueIndex].status = .pending
        // A retry is a fresh attempt: the failed record is superseded.
        runRecords.removeAll { scalarExact($0.name, current.name) }
        startCurrentQueueItemAudit()
    }

    /// Dismiss a completed queue (the rail's Done action). Carries the same
    /// !isApplying guard as every other queue action (M9 fix round 1) and
    /// never dismisses an ACTIVE unattended run (M11 fix round 1 — the
    /// mandatory report must land first).
    func dismissQueue() {
        guard !isApplying, !isUnattendedRunActive else { return }
        resetQueue()
    }

    private func startCurrentQueueItemAudit() {
        guard let current = currentQueueItem else { return }
        playlistName = current.name
        startAudit()
    }

    private func advanceQueue() {
        queueIndex += 1
        if currentQueueItem != nil, !stopRequested {
            startCurrentQueueItemAudit()
            // The unattended run keeps the apply surface between items
            // (startAudit's discard resets the step to .source).
            if isRunUnattended { step = .apply }
        } else {
            finishRun()
        }
    }

    /// End the run (complete or stopped early): record what never ran,
    /// build + persist the MANDATORY post-run report, and land on the
    /// report screen. The canonical plan artifacts remain the durable
    /// record; the report is the after-the-fact review surface the batch
    /// amendment requires.
    private func finishRun() {
        let stoppedEarly = stopRequested && currentQueueItem != nil
        for item in queue where !runRecords.contains(where: { scalarExact($0.name, item.name) }) {
            recordRunItem(named: item.name, outcome: .notRun)
        }
        // Records in queue order (they were appended in outcome order).
        let ordered = queue.compactMap { item in
            runRecords.first { scalarExact($0.name, item.name) }
        }
        let report = BatchRunReport(
            mode: mode,
            unattended: isRunUnattended,
            startedAt: runStartedAt ?? Date(),
            finishedAt: Date(),
            stoppedEarly: stoppedEarly,
            items: ordered
        )
        var path: String?
        var writeFailure: String?
        do {
            path = try writeRunReportArtifact(
                text: renderRunReportText(report),
                baseName: runReportBaseName(startedAt: report.startedAt),
                directoryPath: outputDirectoryPath
            )
        } catch {
            // The report is the MANDATORY artifact — a persistence failure
            // is surfaced loudly on the report screen (minor a). The
            // in-memory report still renders for immediate review.
            writeFailure = "could not persist the run report under "
                + "\(outputDirectoryPath): \(String(describing: error))"
        }
        discardCompletedAudit()
        isRunUnattended = false
        stopRequested = false
        runStartedAt = nil
        finishedRunReport = report
        lastRunSummary = LastRunSummary(
            appliedCount: report.appliedCount, failedCount: report.failedCount
        )
        runReportPath = path
        runReportWriteFailure = writeFailure
        step = .report
        if playSoundOnRunFinish { playFinishSound() }
    }

    /// Append (or supersede) one item's run record. Judgment summaries come
    /// from the CANONICAL audited plan when one is present; `elapsed` is
    /// the item's apply time (nil where no apply ran).
    private func recordRunItem(
        named name: String,
        outcome: RunItemOutcome,
        elapsed: Double? = nil,
        failureClass: ApplyFailureClass? = nil
    ) {
        guard isQueueActive else { return }
        var judgment = JudgmentSummaries(
            nearIdenticalPairLines: [], distinctOmissionLines: [], countAnomalyLines: []
        )
        var inputCount: Int?
        var outputCount: Int?
        var planFileName: String?
        var itemTargetName: String?
        if let audit = result, scalarExact(audit.sourceName, name) {
            judgment = judgmentSummaries(
                decisions: audit.decisions,
                outputTracks: audit.outputTracks,
                inputCount: audit.inputCount,
                outputCount: audit.outputCount
            )
            inputCount = audit.inputCount
            outputCount = audit.outputCount
            planFileName = artifactBasename(audit.paths.planJson)
            itemTargetName = defaultTargetName(mode: audit.mode, sourceName: audit.sourceName)
        }
        runRecords.removeAll { scalarExact($0.name, name) }
        runRecords.append(
            RunItemRecord(
                name: name,
                outcome: outcome,
                failureClass: failureClass,
                inputCount: inputCount,
                outputCount: outputCount,
                nearIdenticalPairLines: judgment.nearIdenticalPairLines,
                distinctOmissionLines: judgment.distinctOmissionLines,
                countAnomalyLines: judgment.countAnomalyLines,
                targetName: itemTargetName,
                planFileName: planFileName,
                elapsedSeconds: elapsed
            )
        )
    }

    private func resetQueue() {
        isQueueActive = false
        queue = []
        queueIndex = 0
        // Fix round 1 (Important finding), defense in depth: invalidate any
        // in-flight leftover resolve's completion so it can never act on a
        // context this reset just discarded.
        leftoverResolveGeneration += 1
    }

    private nonisolated static func scanStage(
        make: @escaping @Sendable () -> any ScriptRunner
    ) async throws -> LoadedListing {
        try await Task.detached(priority: .userInitiated) {
            // Fresh runner per scan, created and consumed inside this task
            // only (the documented single-threaded runner posture).
            let session = MusicBridgeSession(runner: make())
            let listings = try session.listPlaylists()
            return LoadedListing(
                listings: listings,
                sections: buildPlaylistBrowseSections(from: listings),
                scannedAt: Date(),
                fromCache: false
            )
        }.value
    }

    private func applyListing(_ loaded: LoadedListing, generation: Int) {
        guard generation == scanGeneration else { return }
        listingState = .loaded(loaded)
        pruneBrowserState(against: loaded.sections)
        // M11: persist the fresh listing for instant startup (best-effort;
        // browser only — audits/applies stay live-read).
        saveListingCache(
            cachedListing(from: loaded.listings, scannedAt: loaded.scannedAt),
            at: listingCacheURL
        )
    }

    private func applyListingFailure(_ error: Error, generation: Int) {
        guard generation == scanGeneration else { return }
        listingState = .failed(Self.classifyFailure(error))
    }

    /// After a rescan, drop stale selection/checkbox state that no longer
    /// resolves (the active queue is left alone: a drifted item's audit
    /// fails closed on its own).
    private func pruneBrowserState(against sections: PlaylistBrowseSections) {
        // Wave A (spec A4): the anchor never survives a rescan — row order
        // and membership may have changed.
        selectionAnchor = nil
        if let selection = browserSelection {
            let resolves: Bool
            switch selection {
            case .group(let name):
                resolves = sections.groups.contains { scalarExact($0.name, name) }
            case .nearMatch(let normalized):
                resolves = sections.nearMatches.contains {
                    scalarExact($0.normalizedName, normalized)
                }
            case .singleton(let persistentId):
                resolves = sections.singletons.contains {
                    scalarExact($0.persistentId, persistentId)
                }
            }
            if !resolves { browserSelection = nil }
        }
        checkedPersistentIds.formIntersection(sections.singletons.map(\.persistentId))
        // M10: checked groups that no longer resolve to a mergeable group
        // (a copy vanished or was renamed) are pruned scalar-exactly.
        checkedGroupNames.removeAll { name in
            !sections.groups.contains { scalarExact($0.name, name) }
        }
    }

    /// Start one read-only audit run (single-flight; also refused while a
    /// listing scan or an apply holds the OSA slot).
    func startAudit() {
        guard !isRunning, !isScanning, !isApplying, !isMutationBusy else { return }
        let name = playlistName
        guard !name.isEmpty else { return }
        activeAuditName = name
        selectedDestination = .activity

        // Stale-state rule: the previous plan and gate state never survive
        // into a new audit.
        discardCompletedAudit()
        runGeneration += 1
        let generation = runGeneration
        let mode = self.mode
        let outputDirectoryPath = self.outputDirectoryPath
        let make = makeRunner

        runState = .running(.reading(started: Date()))
        auditTask = Task { [weak self] in
            await self?.runPipeline(
                generation: generation,
                mode: mode,
                name: name,
                outputDirectoryPath: outputDirectoryPath,
                make: make
            )
        }
    }

    /// Request cancellation. Honored between phases; the in-flight OSA read
    /// itself cannot be interrupted (its result is discarded).
    func cancelAudit() {
        auditTask?.cancel()
    }

    /// Back to screen 1 with no plan state left behind. Queue state resets
    /// too (both modes' checkbox picks survive so a fresh queue is one
    /// click away). Refused while an apply is in flight — the guarded write
    /// must run to its verified (or fail-closed) end before the context is
    /// discarded.
    func startOver() {
        // Fix round 1, finding 1: an active unattended run — INCLUDING the
        // judgment pause — is never silently wiped; stop the run instead
        // (the report is built and persisted first).
        // Fix round 1 (combined Task 4+5 review, Important finding): also
        // refused while a leftover resolve (or any other mutation-gate
        // activity) holds the OSA slot — the orphaned resolve must never
        // complete against a context the user has already navigated away
        // from.
        guard !isApplying, !isUnattendedRunActive, !isMutationBusy else { return }
        discardCompletedAudit()
        resetQueue()
        runState = .idle
        isRunUnattended = false
        runStartedAt = nil
        runRecords = []
        finishedRunReport = nil
        runReportPath = nil
        runReportWriteFailure = nil
        stopRequested = false
    }

    /// Dismiss the post-run report (its artifact stays on disk and in the
    /// history browser) and return to the browser.
    func acknowledgeRunReport() {
        // Fix round 1 (combined Task 4+5 review, Important finding): refused
        // while a leftover resolve is in flight (the report screen's own
        // shortcut) — clicking Done immediately after the shortcut must
        // never orphan that resolve against a discarded report.
        guard !isApplying, !isMutationBusy else { return }
        finishedRunReport = nil
        runReportPath = nil
        runReportWriteFailure = nil
        leftoverResolveNotice = nil
        leftoverResolveTargetName = nil
        resetQueue()
        selectedDestination = .library
        if step == .report { step = .source }
    }

    // MARK: in-app apply (M9; state mutation stays on the main actor)

    /// Start THE one apply for the current audit. Single-flight, mutually
    /// exclusive with every other OSA activity, and gated on `canApply`
    /// (all confirm gates + not consumed). The plan is reloaded FROM THE
    /// PERSISTED ARTIFACT through the fail-closed loaders — never taken
    /// from memory.
    func startApply() {
        guard canApply else { return }
        startApplyCore()
    }

    /// The shared apply launch (M11: also entered by the unattended run,
    /// which retires the typed-name gate per the batch amendment). The
    /// ENGINE guards hold on every path: one apply per audit (idle apply
    /// state), OSA mutual exclusion, artifact-loaded plan, generation
    /// guard.
    private func startApplyCore() {
        guard case .idle = applyState, !isRunning, !isScanning, !isMutationBusy,
              let result, let targetName else { return }
        let generation = runGeneration
        let mode = result.mode
        let planPath = result.paths.planJson
        let make = makeRunner

        completedApplyStages = nil
        applyFailureClass = nil
        applyStartedAt = Date()
        lastApplySeconds = nil
        applyState = .running([ApplyStageEntry(stage: .loadingPlan, started: Date())])
        step = .apply
        selectedDestination = .activity
        applyTask = Task { [weak self] in
            await self?.runApplyPipeline(
                generation: generation,
                mode: mode,
                planPath: planPath,
                targetName: targetName,
                make: make
            )
        }
    }

    /// Wave C1: records the LAST bridge phase synchronously on the detached
    /// apply thread. The main-actor stage hops (advanceApplyStage) are
    /// enqueued Tasks and can land AFTER finishApply/failApply runs (late
    /// hops are deliberately dropped), so `stages.last` is racy as a
    /// failed-stage source; this box is written inside the bridge's
    /// synchronous callback (dispatch order, same thread) and read exactly
    /// once when the pipeline finishes.
    private final class ApplyPhaseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var last: ApplyPhase?

        func record(_ phase: ApplyPhase) {
            lock.lock()
            last = phase
            lock.unlock()
        }

        /// The failed stage: the last phase the bridge entered, or the
        /// app-level artifact load when no bridge phase was ever reached.
        var lastStage: ApplyStage {
            lock.lock()
            defer { lock.unlock() }
            return last.map(ApplyStage.bridge) ?? .loadingPlan
        }
    }

    private func runApplyPipeline(
        generation: Int,
        mode: ConsolidatorMode,
        planPath: String,
        targetName: String,
        make: @escaping @Sendable () -> any ScriptRunner
    ) async {
        let phaseBox = ApplyPhaseBox()
        do {
            let outcome = try await Self.applyStage(
                mode: mode,
                planPath: planPath,
                targetName: targetName,
                make: make
            ) { [weak self] phase in
                // Wave C1: record synchronously FIRST — classification must
                // never race the main-actor hops below.
                phaseBox.record(phase)
                // Phase callbacks arrive on the detached task's thread in
                // dispatch order. DESIGN ASSUMPTION: main-actor hops from a
                // single thread are processed in enqueue order, so the
                // progress list reads in guarded order. The actual
                // PROTECTION is the state guard in advanceApplyStage — a
                // late or reordered hop can only append to a still-running
                // list or be dropped; it can never resurrect or disturb a
                // finished apply.
                Task { @MainActor in
                    self?.advanceApplyStage(.bridge(phase), generation: generation)
                }
            }
            finishApply(
                outcome, mode: mode, targetName: targetName,
                failedStage: phaseBox.lastStage, generation: generation
            )
        } catch {
            failApply(error, failedStage: phaseBox.lastStage, generation: generation)
        }
    }

    /// The whole apply as ONE off-main-actor stage: fail-closed artifact
    /// load, then the M5 orchestration through a fresh runner created and
    /// consumed inside this task only. There is no cancellation seam by
    /// design: the guarded write is atomic from the app's view.
    private nonisolated static func applyStage(
        mode: ConsolidatorMode,
        planPath: String,
        targetName: String,
        make: @escaping @Sendable () -> any ScriptRunner,
        onPhase: @escaping @Sendable (ApplyPhase) -> Void
    ) async throws -> ApplyResult {
        try await Task.detached(priority: .userInitiated) {
            let url = URL(fileURLWithPath: planPath)
            let session = MusicBridgeSession(runner: make())
            session.applyProgress = onPhase
            switch mode {
            case .consolidate:
                // Decision 1 (contract fidelity): loadPlan validates the
                // exact named artifact — strict bytes, strict decode, full
                // integrity — before any command is dispatched.
                let plan = try loadPlan(from: url)
                return try session.applyPlan(plan: plan, targetName: targetName)
            case .merge:
                let plan = try loadMergePlan(from: url)
                return try session.applyMergePlan(plan: plan, targetName: targetName)
            }
        }.value
    }

    private func advanceApplyStage(_ stage: ApplyStage, generation: Int) {
        guard generation == runGeneration,
              case .running(var stages) = applyState,
              stages.last?.stage != stage else { return }
        stages.append(ApplyStageEntry(stage: stage, started: Date()))
        applyState = .running(stages)
    }

    private func finishApply(
        _ outcome: ApplyResult,
        mode: ConsolidatorMode,
        targetName: String,
        failedStage: ApplyStage,
        generation: Int
    ) {
        guard generation == runGeneration,
              case .running(let stages) = applyState,
              let result else { return }
        completedApplyStages = stages.map(\.stage)
        lastApplySeconds = applyStartedAt.map { -$0.timeIntervalSinceNow }
        if outcome.verificationOk {
            applyState = .succeeded(
                ApplySuccessDisplay(
                    mode: mode,
                    targetName: targetName,
                    trackCount: outcome.actualCount,
                    plannedCount: outcome.plannedCount,
                    fingerprint: outcome.sourceFingerprint,
                    paths: result.paths
                )
            )
            markCurrentQueueItem(as: .applied)
            if let current = currentQueueItem, current.status == .applied {
                recordRunItem(
                    named: current.name,
                    outcome: .applied(trackCount: outcome.actualCount),
                    elapsed: lastApplySeconds
                )
            }
        } else {
            // Wave C1: classify from the race-free captured stage plus the
            // returned unverified result (spec C1.2). Fail-closed stance
            // unchanged: this item still counts as failed everywhere.
            let failureClass = classifyApplyFailure(
                failedStage: failedStage, result: outcome
            )
            applyFailureClass = failureClass
            applyState = .failed(applyVerificationFailureDisplay(outcome))
            markCurrentQueueItem(as: .failed)
            if let current = currentQueueItem, current.status == .failed {
                recordRunItem(
                    named: current.name,
                    outcome: .failed(
                        reason: outcome.mismatches.joined(separator: "; ")
                    ),
                    elapsed: lastApplySeconds,
                    failureClass: failureClass
                )
            }
        }
        // M11: the unattended run advances itself — failures included (fail
        // closed, record, continue; no stall).
        if isRunUnattended, isQueueActive { advanceQueue() }
    }

    private func failApply(_ error: Error, failedStage: ApplyStage, generation: Int) {
        guard generation == runGeneration,
              case .running(let stages) = applyState else { return }
        completedApplyStages = stages.map(\.stage)
        lastApplySeconds = applyStartedAt.map { -$0.timeIntervalSinceNow }
        // Wave C1: a thrown error means verifyingReadback either never ran
        // or itself threw — result is nil by definition (spec C1.2).
        let failureClass = classifyApplyFailure(failedStage: failedStage, result: nil)
        applyFailureClass = failureClass
        let display = classifyApplyFailure(error)
        applyState = .failed(display)
        markCurrentQueueItem(as: .failed)
        if let current = currentQueueItem, current.status == .failed {
            recordRunItem(
                named: current.name,
                outcome: .failed(reason: display.message),
                elapsed: lastApplySeconds,
                failureClass: failureClass
            )
        }
        if isRunUnattended, isQueueActive { advanceQueue() }
    }

    /// Queue transition after an apply outcome: the finished apply belongs
    /// to the current queue item only when it is the item that was audited
    /// (exact name agrees, like the audit-side transitions). Both modes
    /// since M10 — the queue's mode is invariantly the current mode, and
    /// the apply is generation-tied to the audited result.
    private func markCurrentQueueItem(as status: AuditQueueStatus) {
        guard let current = currentQueueItem, current.status == .audited,
              let result, scalarExact(current.name, result.sourceName) else { return }
        queue[queueIndex].status = status
    }

    // MARK: pipeline (state mutation stays on the main actor)

    private enum SnapshotStage: Sendable {
        case single(PlaylistSnapshot)
        case copies([PlaylistSnapshot])
    }

    private func runPipeline(
        generation: Int,
        mode: ConsolidatorMode,
        name: String,
        outputDirectoryPath: String,
        make: @escaping @Sendable () -> any ScriptRunner
    ) async {
        let clock = ContinuousClock()
        let overallStart = clock.now
        do {
            // Stage 1 — live read (the only Music access; read-only JXA).
            let readStart = clock.now
            let snapshot = try await Self.readStage(mode: mode, name: name, make: make)
            let readSeconds = Self.seconds(readStart.duration(to: clock.now))
            try Self.checkCancelled()
            guard applyPhase(.buildingPlan(started: Date()), generation: generation) else { return }

            // Stage 2 — deterministic plan build (pure, off the main actor).
            let planArtifact = try await Self.planStage(snapshot: snapshot, name: name)
            try Self.checkCancelled()
            guard applyPhase(.writingArtifacts(started: Date()), generation: generation) else { return }

            // Stage 3 — persist the reviewable artifact triple (no-overwrite).
            let paths = try await Self.writeStage(
                plan: planArtifact,
                mode: mode,
                outputDirectoryPath: outputDirectoryPath
            )
            try Self.checkCancelled()

            let totalSeconds = Self.seconds(overallStart.duration(to: clock.now))
            applySuccess(
                CompletedAudit(
                    mode: mode,
                    plan: planArtifact,
                    paths: paths,
                    completedAt: Date(),
                    readSeconds: readSeconds,
                    totalSeconds: totalSeconds
                ),
                generation: generation
            )
        } catch is CancellationError {
            applyCancelled(generation: generation)
        } catch {
            applyFailure(error, generation: generation)
        }
    }

    private nonisolated static func readStage(
        mode: ConsolidatorMode,
        name: String,
        make: @escaping @Sendable () -> any ScriptRunner
    ) async throws -> SnapshotStage {
        try await Task.detached(priority: .userInitiated) {
            // Fresh runner per read, created and consumed inside this task
            // only (OSAKitRunner is single-threaded and non-Sendable).
            let session = MusicBridgeSession(runner: make())
            switch mode {
            case .consolidate:
                return SnapshotStage.single(try session.snapshotPlaylist(name: name))
            case .merge:
                return SnapshotStage.copies(try session.snapshotAllCopies(name: name))
            }
        }.value
    }

    private nonisolated static func planStage(
        snapshot: SnapshotStage,
        name: String
    ) async throws -> CompletedAudit.PlanArtifact {
        try await Task.detached(priority: .userInitiated) {
            switch snapshot {
            case .single(let source):
                return CompletedAudit.PlanArtifact.consolidation(try buildPlan(source))
            case .copies(let copies):
                return .merge(try buildMergePlan(name: name, copies: copies))
            }
        }.value
    }

    private nonisolated static func writeStage(
        plan: CompletedAudit.PlanArtifact,
        mode: ConsolidatorMode,
        outputDirectoryPath: String
    ) async throws -> AuditPaths {
        try await Task.detached(priority: .userInitiated) {
            let outputDir = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
            let paths: AuditPaths
            switch plan {
            case .consolidation(let plan):
                paths = try writeAudit(outputDir: outputDir, plan: plan)
            case .merge(let plan):
                paths = try writeMergeAudit(outputDir: outputDir, plan: plan)
            }
            // cli.py parity (cli.py:65-66, 126-127): all three artifacts
            // must exist before the audit is reported.
            guard auditArtifactsExist(paths) else {
                throw AuditPipelineError(
                    mode == .consolidate
                        ? "the check did not produce all three required artifacts"
                        : "the merge check did not produce all three required artifacts"
                )
            }
            return paths
        }.value
    }

    private nonisolated static func checkCancelled() throws {
        if Task.isCancelled { throw CancellationError() }
    }

    private nonisolated static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: generation-guarded state application

    private func applyPhase(_ phase: Phase, generation: Int) -> Bool {
        guard generation == runGeneration, isRunning else { return false }
        runState = .running(phase)
        return true
    }

    private func applySuccess(_ audit: CompletedAudit, generation: Int) {
        guard generation == runGeneration else { return }
        result = audit
        reviewedPlanToggle = false
        typedTargetName = ""
        runState = .idle
        step = .review
        // Queue transition (M8; both modes since M10): the audit that just
        // completed belongs to the current queue item only when mode and
        // exact name agree. The queue's mode is invariantly the model's
        // mode (setMode resets any queue), so matching the audit's own mode
        // against the current mode is the full check.
        if audit.mode == mode,
           let current = currentQueueItem, current.status == .pending,
           scalarExact(current.name, audit.sourceName) {
            queue[queueIndex].status = .audited
            // A5: refresh with the audit's live per-copy counts — the queue
            // item ONLY. The cached listing and the browser listing state
            // keep their scan-time counts; divergence is display-only and
            // never a guard input.
            queue[queueIndex].copyCounts = audit.liveCopyCounts
            // M11: the unattended run applies straight through — the typed
            // gate retires per the batch amendment — UNLESS the
            // pause-on-judgment setting holds this item for review (the
            // attended M9 detour; the run resumes after its apply).
            if isRunUnattended {
                let judgment = judgmentSummaries(
                    decisions: audit.decisions,
                    outputTracks: audit.outputTracks,
                    inputCount: audit.inputCount,
                    outputCount: audit.outputCount
                )
                if pauseOnJudgmentItems && !judgment.isEmpty {
                    // Paused: step is already .review; navigation unlocks
                    // because nothing is running.
                } else {
                    step = .apply
                    startApplyCore()
                }
            }
        }
    }

    private func applyCancelled(generation: Int) {
        guard generation == runGeneration else { return }
        runState = .cancelled
        // Fix round 1, folded minor: a cancelled queue read must not strand
        // its item as .pending (Retry only exists for .failed). Mark it
        // failed so the rail's Retry/Skip affordances apply; the read-only
        // cancel semantics are unchanged (artifacts on disk stay put).
        // Both modes since M10 (the queue's mode is the current mode).
        if let current = currentQueueItem, current.status == .pending,
           scalarExact(current.name, activeAuditName) {
            queue[queueIndex].status = .failed
            recordRunItem(named: current.name, outcome: .failed(reason: "cancelled"))
            if isRunUnattended { advanceQueue() }
        }
    }

    private func applyFailure(_ error: Error, generation: Int) {
        guard generation == runGeneration else { return }
        let failure = Self.classifyFailure(error)
        runState = .failed(failure)
        // Queue transition (mirrors applySuccess; the failed run's name is
        // pinned at startAudit, independent of the mutable text state).
        // Both modes since M10.
        if let current = currentQueueItem, current.status == .pending,
           scalarExact(current.name, activeAuditName) {
            queue[queueIndex].status = .failed
            recordRunItem(named: current.name, outcome: .failed(reason: failure.message))
            // M11: an unattended run never stalls — record and continue.
            if isRunUnattended { advanceQueue() }
        }
    }

    /// Error class labels per the brief: MusicCommandError is the
    /// "automation failed" class, MusicBridgeError the "library state"
    /// class; messages are always verbatim.
    private nonisolated static func classifyFailure(_ error: Error) -> AuditFailure {
        let message = String(describing: error)
        let category: String
        switch error {
        case is MusicCommandError: category = "Automation failed"
        case is MusicBridgeError: category = "Library state"
        case is ResolverError: category = "Plan build failed"
        case is PersistenceWriteError, is AuditPipelineError: category = "Artifact write failed"
        default: category = "Unexpected error"
        }
        return AuditFailure(category: category, message: message)
    }

    /// Clear the completed audit and every gate that depends on it. Bumps
    /// the run generation so a superseded pipeline can never re-apply state.
    /// If a run is somehow still in flight (the views prevent this), it is
    /// cancelled and the state returns to idle rather than stranding a
    /// `.running` phase no pipeline will ever clear.
    private func discardCompletedAudit() {
        runGeneration += 1
        if isRunning {
            auditTask?.cancel()
            runState = .idle
        }
        result = nil
        reviewedPlanToggle = false
        typedTargetName = ""
        step = .source
        hasVisitedReview = false
        // M9: a consumed (or somehow superseded) apply never leaks into a
        // new audit; the generation bump above already orphans any stale
        // apply pipeline's state application.
        applyState = .idle
        completedApplyStages = nil
        applyFailureClass = nil
        leftoverResolveNotice = nil
        leftoverResolveTargetName = nil
        // Fix round 1 (Important finding), defense in depth: invalidate any
        // in-flight leftover resolve's completion — mirrors `resetQueue()`.
        leftoverResolveGeneration += 1
    }

    // MARK: Wave C1 — the "Delete leftover target…" shortcut (spec C1.5)

    /// Resolve the recorded leftover-target name against a FRESH live
    /// listing (never the browser cache), scalar-exactly. Exactly one match
    /// opens the existing Wave B delete gate through startMutationAudit —
    /// every B7/B6 guard, typed-token requirement, artifact, and readback
    /// applies unchanged, and the gate presents at the existing sheet
    /// anchors. Zero or multiple matches (and a failed listing read)
    /// surface `leftoverResolveNotice` instead; no gate opens. Disabled
    /// under the same conditions as every mutation entry point.
    func startDeleteLeftoverTarget(named targetName: String) {
        guard !isRunning, !isScanning, !isApplying, !isMutationBusy,
              !isUnattendedRunActive else { return }
        leftoverResolveNotice = nil
        leftoverResolveTargetName = targetName
        isResolvingLeftoverTarget = true
        // Fix round 1 (Important finding): generation-guard this resolve's
        // completion, mirroring `mutationGeneration` — invalidated by a
        // fresh resolve start (this bump) or by `discardCompletedAudit()` /
        // `resetQueue()` running while this one is still in flight.
        leftoverResolveGeneration += 1
        let generation = leftoverResolveGeneration
        let make = makeRunner
        leftoverResolveTask = Task { [weak self] in
            let outcome: Result<[PlaylistListing], Error> = await Task.detached(
                priority: .userInitiated
            ) {
                Result { try MusicBridgeSession(runner: make()).listPlaylists() }
            }.value
            self?.finishLeftoverResolve(outcome, targetName: targetName, generation: generation)
        }
    }

    private func finishLeftoverResolve(
        _ outcome: Result<[PlaylistListing], Error>,
        targetName: String,
        generation: Int
    ) {
        // The busy flag always clears — a stale completion still frees the
        // OSA slot it held. Everything else (gate arm, notice write) is a
        // no-op when a newer resolve or a reset superseded this one.
        isResolvingLeftoverTarget = false
        guard generation == leftoverResolveGeneration else { return }
        switch outcome {
        case .failure(let error):
            // Spec-silent case, resolved fail-closed: a read failure can
            // pin nothing — same control, verbatim error, no gate.
            leftoverResolveNotice =
                "Could not read the live library to pin the leftover: "
                + String(describing: error)
        case .success(let listings):
            let matches = listings.filter { scalarExact($0.name, targetName) }
            if matches.count == 1 {
                startMutationAudit(kind: .delete, persistentID: matches[0].persistentId)
            } else {
                leftoverResolveNotice =
                    "Could not pin the leftover uniquely (\(matches.count) live matches) "
                    + "\u{2014} delete it from the Library browser instead."
            }
        }
    }

    // MARK: Wave B mutation gate (B2/B4/B5/B6)

    /// The contract-excluded names and persistent IDs (AGENTS.md B7
    /// amendment): refused for delete, for rename, and as rename
    /// destinations.
    nonisolated static let mutationRefusedNames = [
        "#Musica xTotal",
        "#Musica xTotal \u{2014} Consolidated",
    ]
    nonisolated static let mutationRefusedPersistentIDs = [
        "E02030832FD20B07",
        "61EC0FC6E0F1C250",
    ]

    /// Entry refusals (B4, applied to delete AND rename): smart,
    /// special-kind, contract-excluded names (scalar-exact), and the pilot
    /// persistent IDs. Returns the verbatim refusal reason, or nil.
    nonisolated static func mutationEntryRefusalReason(_ entry: PlaylistListing) -> String? {
        if entry.isSmart {
            return "refused: \u{201C}\(entry.name)\u{201D} is a smart playlist; "
                + "smart playlists are never mutated"
        }
        if !scalarExact(entry.specialKind, "none") {
            return "refused: \u{201C}\(entry.name)\u{201D} has special kind "
                + "\u{201C}\(entry.specialKind)\u{201D}; special-kind playlists are never mutated"
        }
        if mutationRefusedNames.contains(where: { scalarExact($0, entry.name) }) {
            return "refused: \u{201C}\(entry.name)\u{201D} is contract-excluded from every mutation"
        }
        if mutationRefusedPersistentIDs.contains(where: { scalarExact($0, entry.persistentId) }) {
            return "refused: persistent ID \(entry.persistentId) is contract-excluded "
                + "from every mutation"
        }
        return nil
    }

    /// Rename-destination refusal (B5): the contract-excluded names are
    /// refused as destinations outright.
    nonisolated static func mutationDestinationRefusalReason(_ newName: String) -> String? {
        if mutationRefusedNames.contains(where: { scalarExact($0, newName) }) {
            return "refused: \u{201C}\(newName)\u{201D} is a contract-excluded rename destination"
        }
        return nil
    }

    /// The B2 freshness/single-use preconditions, checked at ARM time and
    /// RE-checked at dispatch: session match, age <= 600 s, consumed marker
    /// absent, and the artifact SHA-256 re-read from disk. Returns the
    /// verbatim refusal reason, or nil when every check passes. (The fresh
    /// live-listing fingerprint re-check is `performMutation`'s first
    /// phase, immediately before the writer.)
    nonisolated static func mutationPreconditionFailure(
        armedPlan: MutationPlan,
        planURL: URL,
        sessionID: String,
        at instant: Date
    ) -> String? {
        if !scalarExact(armedPlan.sessionID, sessionID) {
            return "refused: mutation artifact was produced by session "
                + "\(armedPlan.sessionID), not this app launch session (\(sessionID))"
        }
        guard let created = ISO8601DateFormatter().date(from: armedPlan.createdAtISO8601) else {
            return "refused: mutation artifact carries an unparseable creation time "
                + "\u{201C}\(armedPlan.createdAtISO8601)\u{201D}"
        }
        let age = instant.timeIntervalSince(created)
        if age < 0 || age > 600 {
            return "refused: mutation artifact is stale (age \(Int(age)) s exceeds the "
                + "600 s freshness contract); run a fresh safety check"
        }
        if isMutationPlanConsumed(planURL: planURL) {
            return "refused: mutation artifact \(planURL.lastPathComponent) is already "
                + "consumed; nothing can ever re-arm it"
        }
        let reloaded: MutationPlan
        do {
            reloaded = try loadMutationPlan(url: planURL)
        } catch {
            return "refused: mutation artifact re-read failed: \(String(describing: error))"
        }
        if !scalarExact(reloaded.sha256Hex(), armedPlan.sha256Hex()) {
            return "refused: mutation artifact SHA-256 changed on disk; the armed plan "
                + "no longer matches \(planURL.lastPathComponent)"
        }
        return nil
    }

    /// Run the MUTATION AUDIT for one browser row (B2 artifact-first): a
    /// fresh listing + a fresh track snapshot of the pinned persistent ID
    /// -> MutationPlan -> writeMutationAudit -> armed gate. Refused while
    /// any OSA activity is in flight and during any unattended run (B6).
    /// Starting a new audit over an ARMED gate aborts the old one — its
    /// artifact is consumed first (abort consumes, B2).
    func startMutationAudit(
        kind: MutationKind,
        persistentID: String,
        newName: String? = nil,
        confirmWithDestinationName: Bool = false
    ) {
        guard !isRunning, !isScanning, !isApplying, !isMutationBusy,
              !isUnattendedRunActive else { return }
        if case .armed(let previous) = mutationGatePhase {
            consumeArmedMutationArtifacts(previous)
        }
        typedMutationName = ""
        typedMutationCount = ""
        typedMutationPIDSuffix = ""
        if kind == .rename {
            guard let destination = newName, !destination.isEmpty else {
                mutationGatePhase = .refused(
                    "refused: rename requires a non-empty destination name"
                )
                return
            }
            if let reason = Self.mutationDestinationRefusalReason(destination) {
                mutationGatePhase = .refused(reason)
                return
            }
        }
        mutationGeneration += 1
        let generation = mutationGeneration
        let make = makeRunner
        let outputDirectoryPath = self.outputDirectoryPath
        let sessionID = appSessionID
        let clock = now
        mutationGatePhase = .auditing(started: now())
        mutationTask = Task { [weak self] in
            do {
                let stage = try await Self.mutationAuditStage(
                    kind: kind,
                    persistentID: persistentID,
                    newName: kind == .rename ? newName : nil,
                    confirmWithDestinationName: confirmWithDestinationName,
                    outputDirectoryPath: outputDirectoryPath,
                    sessionID: sessionID,
                    now: clock,
                    make: make
                )
                self?.armMutation(stage, generation: generation)
            } catch {
                self?.refuseMutation(error, generation: generation)
            }
        }
    }

    /// Dispatch THE one guarded mutation for the armed gate. Requires every
    /// typed identity token (scalar-exact), no other OSA activity, and no
    /// active unattended run (B6). The B2 preconditions are RE-checked off
    /// the main actor immediately before the writer; any failure refuses
    /// fail-closed and consumes the artifact.
    func executeMutation() {
        guard case .armed(let state) = mutationGatePhase else { return }
        // Final review, Finding I-1: `.armed` itself never sets
        // `isMutationBusy`, but Wave C1 made the leftover resolve a second,
        // independent contributor to it — without this guard, a second
        // resolve could still be reading `listPlaylists()` when this
        // dispatches, breaking the "one OSA activity at a time" invariant.
        guard mutationGateSatisfied, !isRunning, !isScanning, !isApplying,
              !isUnattendedRunActive, !isMutationBusy else { return }
        // Wave B Task 14: an armed GROUP routes to the sequential per-copy
        // orchestration; the single delete/rename path below is unchanged.
        if let context = cleanupContext {
            executeCleanupGroup(context: context, baseline: state.baseline)
            return
        }
        let generation = mutationGeneration
        let sessionID = appSessionID
        let clock = now
        let make = makeRunner
        let outputDirectoryPath = self.outputDirectoryPath
        mutationGatePhase = .executing(
            MutationExecutionProgress(
                copyIndex: 0, copyCount: 1, phase: .reValidating, startedAt: now()
            )
        )
        mutationTask = Task { [weak self] in
            let outcome = await Self.mutationDispatchStage(
                state: state,
                sessionID: sessionID,
                now: clock,
                outputDirectoryPath: outputDirectoryPath,
                make: make
            ) { [weak self] phase in
                Task { @MainActor in
                    self?.advanceMutationPhase(phase, generation: generation)
                }
            }
            self?.finishMutation(outcome, generation: generation)
        }
    }

    /// Dismiss the gate. From ARMED this is the abort path: the artifact is
    /// consumed first (B2 — execution AND abort both consume). Refused
    /// while the audit read or the guarded dispatch is in flight.
    func dismissMutationGate() {
        switch mutationGatePhase {
        case .auditing, .executing:
            return
        case .armed(let state):
            mutationGeneration += 1
            consumeArmedMutationArtifacts(state)
            mutationGatePhase = .idle
        case .finished, .refused, .idle:
            mutationGeneration += 1
            cleanupContext = nil
            mutationGatePhase = .idle
        }
        typedMutationName = ""
        typedMutationCount = ""
        typedMutationPIDSuffix = ""
    }

    // MARK: mutation stages (all Music I/O off the main actor)

    /// What the detached mutation audit hands back for arming.
    private struct MutationAuditArmedStage: Sendable {
        let plan: MutationPlan
        let paths: MutationAuditPaths
        let baseline: [PlaylistListing]
        let requiresCountToken: Bool
        let requiresPIDSuffixToken: Bool
        let collisionWarning: String?
        let confirmationName: String
    }

    private nonisolated static func mutationAuditStage(
        kind: MutationKind,
        persistentID: String,
        newName: String?,
        confirmWithDestinationName: Bool,
        outputDirectoryPath: String,
        sessionID: String,
        now: @escaping @Sendable () -> Date,
        make: @escaping @Sendable () -> any ScriptRunner
    ) async throws -> MutationAuditArmedStage {
        try await Task.detached(priority: .userInitiated) {
            // Fresh runner, created and consumed inside this task only.
            let session = MusicBridgeSession(runner: make())
            // (1) Fresh listing — the plan's fingerprint baseline.
            let listing = try session.listPlaylists()
            let matches = listing.filter { scalarExact($0.persistentId, persistentID) }
            guard matches.count == 1, let entry = matches.first else {
                throw MutationGateRefusal(matches.isEmpty
                    ? "refused: no live playlist carries persistent ID \(persistentID); "
                        + "rescan and retry"
                    : "refused: \(matches.count) live playlists carry persistent ID "
                        + "\(persistentID); the listing is ambiguous")
            }
            if let reason = mutationEntryRefusalReason(entry) {
                throw MutationGateRefusal(reason)
            }
            // (2) Fresh track snapshot of the pinned copy — the ordered
            // track persistent IDs the writer revalidates in-execution.
            let copies = try session.snapshotAllCopies(name: entry.name)
            let pinnedCopies = copies.filter { scalarExact($0.persistentId, persistentID) }
            guard pinnedCopies.count == 1, let pinned = pinnedCopies.first else {
                throw MutationGateRefusal(
                    "refused: the snapshot found \(pinnedCopies.count) copies with "
                        + "persistent ID \(persistentID); expected exactly 1"
                )
            }
            guard pinned.tracks.count == entry.trackCount else {
                throw MutationGateRefusal(
                    "refused: \u{201C}\(entry.name)\u{201D} drifted during the safety "
                        + "check: the listing reports \(entry.trackCount) tracks, the "
                        + "snapshot has \(pinned.tracks.count)"
                )
            }
            // (3) The plan and its reviewable artifact pair (no-overwrite).
            let plan = MutationPlan(
                kind: kind,
                playlistName: entry.name,
                playlistPersistentID: entry.persistentId,
                trackCount: pinned.tracks.count,
                orderedTrackPersistentIDs: pinned.tracks.map(\.persistentId),
                newName: newName,
                listingFingerprint: listingFingerprint(of: listing),
                evidence: nil,
                createdAtISO8601: ISO8601DateFormatter().string(from: now()),
                sessionID: sessionID
            )
            let outputDir = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
            let paths = try writeMutationAudit(
                outputDir: outputDir,
                plan: plan,
                summaryText: mutationSummaryText(plan: plan)
            )
            // (4) ARM-TIME precondition check against the artifact ON DISK
            // (B2): the gate arms against the persisted plan file, never
            // the in-memory object.
            if let reason = mutationPreconditionFailure(
                armedPlan: plan, planURL: paths.planURL, sessionID: sessionID, at: now()
            ) {
                throw MutationGateRefusal(reason)
            }
            // (5) The unique-identity token requirements (B4).
            let sameName = listing.filter { scalarExact($0.name, entry.name) }
            let requiresCountToken = sameName.count > 1
            let sameCount = sameName.filter { $0.trackCount == entry.trackCount }
            let requiresPIDSuffixToken = requiresCountToken && sameCount.count > 1
            // (6) The rename collision warning (B5) — never a block.
            var collisionWarning: String?
            if kind == .rename, let destination = newName {
                let colliding = listing.filter {
                    scalarExact($0.name, destination)
                        && !scalarExact($0.persistentId, entry.persistentId)
                }
                if !colliding.isEmpty {
                    collisionWarning = "Renaming to \u{201C}\(destination)\u{201D} creates "
                        + "a same-name group with \(colliding.count) existing playlist(s) "
                        + "\u{2014} that is what makes a near-match twin mergeable on the "
                        + "next scan. The rename is not blocked."
                }
            }
            return MutationAuditArmedStage(
                plan: plan,
                paths: paths,
                baseline: listing,
                requiresCountToken: requiresCountToken,
                requiresPIDSuffixToken: requiresPIDSuffixToken,
                collisionWarning: collisionWarning,
                confirmationName: confirmWithDestinationName && kind == .rename
                    ? (newName ?? entry.name)
                    : entry.name
            )
        }.value
    }

    private enum MutationDispatchOutcome: Sendable {
        case refused(String)
        case finished(MutationFinishDisplay)
    }

    private nonisolated static func mutationDispatchStage(
        state: MutationGateState,
        sessionID: String,
        now: @escaping @Sendable () -> Date,
        outputDirectoryPath: String,
        make: @escaping @Sendable () -> any ScriptRunner,
        onPhase: @escaping @Sendable (MutationPhase) -> Void
    ) async -> MutationDispatchOutcome {
        await Task.detached(priority: .userInitiated) { () -> MutationDispatchOutcome in
            // DISPATCH RE-CHECK (B2). A precondition failure is an abort —
            // and an abort consumes the artifact too (marking an
            // already-consumed plan is a no-op by the persistence contract).
            if let reason = mutationPreconditionFailure(
                armedPlan: state.plan, planURL: state.paths.planURL,
                sessionID: sessionID, at: now()
            ) {
                try? markMutationPlanConsumed(planURL: state.paths.planURL)
                return .refused(reason)
            }
            // Execution consumes the artifact BEFORE the writer dispatch: a
            // crash mid-write must never leave a re-armable artifact.
            do {
                try markMutationPlanConsumed(planURL: state.paths.planURL)
            } catch {
                return .refused(
                    "refused: could not mark the mutation artifact consumed: "
                        + String(describing: error)
                )
            }
            let planFileName = state.paths.planURL.lastPathComponent
            var verified = false
            var mismatches: [String] = []
            var informational: [String] = []
            do {
                // Fresh runner, created and consumed inside this task only.
                let session = MusicBridgeSession(runner: make())
                let outcome = try session.performMutation(
                    plan: state.plan,
                    baseline: state.baseline,
                    targetGuard: nil,
                    progress: onPhase
                )
                verified = outcome.verified
                mismatches = outcome.mismatches
                informational = outcome.informational
            } catch {
                // Writer/orchestration failure NEVER flips to success:
                // report verbatim, never repair, never retry.
                mismatches = ["mutation failed: \(String(describing: error))"]
            }
            // The result-report artifact (B2) — persisted for History and
            // cleanup evidence; a write failure is loud, never silent.
            var resultReportPath: String?
            var resultWriteFailure: String?
            do {
                let url = try writeMutationResult(
                    outputDir: URL(fileURLWithPath: outputDirectoryPath, isDirectory: true),
                    baseName: mutationResultBaseName(planFileName: planFileName),
                    text: mutationResultText(
                        plan: state.plan,
                        planFileName: planFileName,
                        verified: verified,
                        mismatches: mismatches,
                        informational: informational
                    )
                )
                resultReportPath = url.path
            } catch {
                resultWriteFailure = "could not persist the mutation result under "
                    + "\(outputDirectoryPath): \(String(describing: error))"
            }
            return .finished(
                MutationFinishDisplay(
                    kind: state.plan.kind,
                    playlistName: state.plan.playlistName,
                    newName: state.plan.newName,
                    verified: verified,
                    mismatches: mismatches,
                    informational: informational,
                    consumedPlanFileName: planFileName,
                    resultReportPath: resultReportPath,
                    resultWriteFailure: resultWriteFailure
                )
            )
        }.value
    }

    // MARK: mutation generation-guarded state application

    private func armMutation(_ stage: MutationAuditArmedStage, generation: Int) {
        guard generation == mutationGeneration,
              case .auditing = mutationGatePhase else { return }
        let armedAt = now()
        let created = ISO8601DateFormatter().date(from: stage.plan.createdAtISO8601) ?? armedAt
        mutationGatePhase = .armed(
            MutationGateState(
                plan: stage.plan,
                paths: stage.paths,
                baseline: stage.baseline,
                armedAt: armedAt,
                freshnessDeadline: created.addingTimeInterval(600),
                requiresCountToken: stage.requiresCountToken,
                requiresPIDSuffixToken: stage.requiresPIDSuffixToken,
                collisionWarning: stage.collisionWarning,
                confirmationName: stage.confirmationName
            )
        )
    }

    private func refuseMutation(_ error: Error, generation: Int) {
        guard generation == mutationGeneration else { return }
        mutationGatePhase = .refused(String(describing: error))
    }

    private func advanceMutationPhase(_ phase: MutationPhase, generation: Int) {
        guard generation == mutationGeneration,
              case .executing(let progress) = mutationGatePhase else { return }
        mutationGatePhase = .executing(
            MutationExecutionProgress(
                copyIndex: progress.copyIndex,
                copyCount: progress.copyCount,
                phase: phase,
                startedAt: progress.startedAt
            )
        )
    }

    private func finishMutation(_ outcome: MutationDispatchOutcome, generation: Int) {
        guard generation == mutationGeneration,
              case .executing = mutationGatePhase else { return }
        switch outcome {
        case .refused(let reason):
            mutationGatePhase = .refused(reason)
        case .finished(let display):
            mutationGatePhase = .finished(display)
        }
        typedMutationName = ""
        typedMutationCount = ""
        typedMutationPIDSuffix = ""
    }

    // MARK: mutation artifact text renderers

    /// Strip the fixed artifact suffix to derive the result-report base
    /// name: "<slug>-<ts>.delete.plan.json" -> "<slug>-<ts>". The suffixes
    /// are pure ASCII, so String.hasSuffix cannot be confused by canonical
    /// equivalence here.
    private nonisolated static func mutationResultBaseName(planFileName: String) -> String {
        for suffix in [".delete.plan.json", ".rename.plan.json"]
        where planFileName.hasSuffix(suffix) {
            return String(planFileName.dropLast(suffix.count))
        }
        return planFileName
    }

    private nonisolated static func mutationSummaryText(plan: MutationPlan) -> String {
        var lines = [
            "# Mutation check \u{2014} \(plan.kind.rawValue)",
            "",
            "- Playlist: \(plan.playlistName)",
            "- Persistent ID: \(plan.playlistPersistentID)",
            "- Track count: \(plan.trackCount)",
        ]
        if let newName = plan.newName {
            lines.append("- Rename destination: \(newName)")
        }
        lines.append("- Listing fingerprint: \(plan.listingFingerprint)")
        lines.append("- Created: \(plan.createdAtISO8601)")
        lines.append("- Session: \(plan.sessionID)")
        lines.append("- Plan SHA-256: \(plan.sha256Hex())")
        if let evidence = plan.evidence {
            lines.append("- Evidence merge plan: \(evidence.mergePlanFileName)")
            if let report = evidence.runReportFileName {
                lines.append("- Evidence run report: \(report)")
            }
            lines.append("- Evidence verification: \(evidence.verificationNote)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private nonisolated static func mutationResultText(
        plan: MutationPlan,
        planFileName: String,
        verified: Bool,
        mismatches: [String],
        informational: [String]
    ) -> String {
        var lines = [
            "# Mutation result \u{2014} \(plan.kind.rawValue)",
            "",
            "- Outcome: \(verified ? "VERIFIED" : "FAILED CLOSED")",
            "- Playlist: \(plan.playlistName)",
            "- Persistent ID: \(plan.playlistPersistentID)",
        ]
        if let newName = plan.newName {
            lines.append("- Renamed to: \(newName)")
        }
        lines.append("- Consumed plan: \(planFileName)")
        lines.append("- Consumed plan SHA-256: \(plan.sha256Hex())")
        if verified {
            lines.append(
                "- Readback proof: the bijective full-listing diff returned no mismatches"
            )
        }
        if !mismatches.isEmpty {
            lines.append("")
            lines.append("## Verbatim mismatches")
            lines.append(contentsOf: mismatches.map { "- \($0)" })
        }
        if !informational.isEmpty {
            lines.append("")
            lines.append("## Informational")
            lines.append(contentsOf: informational.map { "- \($0)" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Wave B cleanup tab state (B3)

    enum CleanupScanState: Equatable {
        case idle
        case scanning(started: Date)
        case failed(String)
        case loaded([CleanupCandidate], scannedAt: Date)
    }

    /// The armed cleanup GROUP: one delete plan + artifact pair per live
    /// copy, in plan-copy order, plus the in-writer target guard. Non-nil
    /// exactly while the mutation gate is serving a group; the single
    /// delete/rename path never sets it.
    struct CleanupGroupContext: Equatable {
        let groupName: String
        let targetName: String
        let targetGuard: MutationScriptBuilder.TargetGuardPayload
        let plans: [MutationPlan]
        let paths: [MutationAuditPaths]
    }

    private(set) var cleanupScanState: CleanupScanState = .idle
    private(set) var cleanupContext: CleanupGroupContext?
    @ObservationIgnored private(set) var cleanupScanTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupGeneration = 0

    /// The Cleanup tab is a separate axis from the audit mode: selecting it
    /// leaves `mode` (and both modes' checks/queues) untouched.
    private(set) var isCleanupTabSelected = false

    var browserTab: BrowserTab {
        if isCleanupTabSelected { return .cleanup }
        return mode == .merge ? .merge : .consolidate
    }

    func setBrowserTab(_ newTab: BrowserTab) {
        switch newTab {
        case .cleanup:
            guard !isApplying, !isUnattendedRunActive else { return }
            isCleanupTabSelected = true
        case .merge:
            isCleanupTabSelected = false
            setMode(.merge)
        case .consolidate:
            isCleanupTabSelected = false
            setMode(.consolidate)
        }
    }

    // MARK: cleanup live sample (prefetch OFF the main actor; gate-arm only,
    // scoped to exactly ONE group's two names — refresh no longer needs a
    // live sample at all now that scan() is listing-only)

    /// One consistent live sample for the @MainActor CleanupScanner: the
    /// full listing plus snapshotAllCopies per name, all read in ONE
    /// detached task so no live read ever blocks the main actor.
    private struct CleanupLiveSample: Sendable {
        let listing: [PlaylistListing]
        let snapshots: [CleanupNameSnapshots]
    }

    private struct CleanupNameSnapshots: Sendable {
        let name: String
        let copies: [PlaylistSnapshot]
    }

    /// Disk-only lookup of the ONE discovered group matching `planFileName`,
    /// as its two live-sample names (groupName, targetName), scalar-exact
    /// deduped, order preserved. nil when no discovered group's plan basename
    /// matches — the evidence for this candidate vanished since the button
    /// was clicked (deleted/renamed plan artifact).
    private func cleanupGroupNames(planFileName: String) -> [String]? {
        let scanner = CleanupScanner(
            reportsDir: URL(fileURLWithPath: outputDirectoryPath, isDirectory: true),
            listPlaylists: { [] }
        )
        guard let group = scanner.discoverGroups().first(
            where: { scalarExact($0.planFileName, planFileName) }
        ) else { return nil }
        var names = [group.groupName]
        if !names.contains(where: { scalarExact($0, group.targetName) }) {
            names.append(group.targetName)
        }
        return names
    }

    private nonisolated static func cleanupLiveSample(
        names: [String],
        make: @escaping @Sendable () -> any ScriptRunner
    ) async throws -> CleanupLiveSample {
        try await Task.detached(priority: .userInitiated) { () -> CleanupLiveSample in
            let session = MusicBridgeSession(runner: make())
            let listing = try session.listPlaylists()
            var snapshots: [CleanupNameSnapshots] = []
            for name in names {
                // A name absent from Music is not an error — rule 1 (target
                // absent) catches it in candidacy. Use best-effort here so
                // the whole scan does not abort when a target has been
                // renamed or deleted since the merge-plan was written.
                snapshots.append(CleanupNameSnapshots(
                    name: name,
                    copies: (try? session.snapshotAllCopies(name: name)) ?? []
                ))
            }
            return CleanupLiveSample(listing: listing, snapshots: snapshots)
        }.value
    }

    /// Run the scanner's listing-level candidacy over an instant closure.
    private func cleanupScan(listing: [PlaylistListing]) throws -> [CleanupCandidate] {
        let scanner = CleanupScanner(
            reportsDir: URL(fileURLWithPath: outputDirectoryPath, isDirectory: true),
            listPlaylists: { listing }
        )
        return try scanner.scan()
    }

    // MARK: cleanup refresh (listing-only; B3 discovery + candidacy, fresh at scan time)

    func refreshCleanup() {
        guard !isRunning, !isScanning, !isApplying, !isMutationBusy,
              !isUnattendedRunActive else { return }
        if case .scanning = cleanupScanState { return }
        cleanupGeneration += 1
        let generation = cleanupGeneration
        let make = makeRunner
        cleanupScanState = .scanning(started: now())
        cleanupScanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let listing = try await Self.cleanupListingOnly(make: make)
                guard generation == self.cleanupGeneration else { return }
                let candidates = try self.cleanupScan(listing: listing)
                guard generation == self.cleanupGeneration else { return }
                self.cleanupScanState = .loaded(candidates, scannedAt: self.now())
            } catch {
                guard generation == self.cleanupGeneration else { return }
                self.cleanupScanState = .failed(String(describing: error))
            }
        }
    }

    /// ONE cheap listPlaylists() read, off the main actor: refresh needs no
    /// per-track live sample at all now that `CleanupScanner.scan()` is
    /// listing-only (Wave C hotfix #2).
    private nonisolated static func cleanupListingOnly(
        make: @escaping @Sendable () -> any ScriptRunner
    ) async throws -> [PlaylistListing] {
        try await Task.detached(priority: .userInitiated) {
            try MusicBridgeSession(runner: make()).listPlaylists()
        }.value
    }

    // MARK: cleanup gate arming (listing candidacy re-check + scoped armVerification)

    /// Arm the ONE per-group gate: look up this group's two live-sample
    /// names disk-only FIRST (before any live read — a plan artifact that
    /// vanished since the button was clicked refuses synchronously here, so
    /// there is no pointless live read and no `.auditing` UI flash for a
    /// candidate that is already gone from disk; mirrors the sync
    /// destination-validation refusal in `startMutationAudit`). Then a live
    /// sample scoped to exactly those two names, the listing-level candidacy
    /// re-check (`scan()`), and the full ordered-track re-verification
    /// (`armVerification`) before writing one delete plan + reviewable
    /// artifact pair per surviving live copy. The typed group name is the
    /// whole token set (spec B3) — every plan's playlistName IS the group
    /// name, and requiresCountToken/requiresPIDSuffixToken stay false.
    func startCleanupAudit(planFileName: String) {
        guard !isRunning, !isScanning, !isApplying, !isMutationBusy,
              !isUnattendedRunActive else { return }
        if case .armed(let previous) = mutationGatePhase {
            consumeArmedMutationArtifacts(previous)
        }
        typedMutationName = ""
        typedMutationCount = ""
        typedMutationPIDSuffix = ""
        guard let names = cleanupGroupNames(planFileName: planFileName) else {
            mutationGeneration += 1
            mutationGatePhase = .refused(
                "refused: cleanup group for \(planFileName) is no longer discovered; "
                    + "refresh the Cleanup tab and re-review"
            )
            return
        }
        mutationGeneration += 1
        let generation = mutationGeneration
        let make = makeRunner
        mutationGatePhase = .auditing(started: now())
        mutationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sample = try await Self.cleanupLiveSample(names: names, make: make)
                try self.armCleanupGroup(
                    planFileName: planFileName, sample: sample, generation: generation
                )
            } catch {
                self.refuseMutation(error, generation: generation)
            }
        }
    }

    private func armCleanupGroup(
        planFileName: String,
        sample: CleanupLiveSample,
        generation: Int
    ) throws {
        let outputDir = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
        let scanner = CleanupScanner(reportsDir: outputDir, listPlaylists: { sample.listing })
        let candidates = try scanner.scan()
        guard let candidate = candidates.first(
            where: { scalarExact($0.planFileName, planFileName) }
        ) else {
            throw MutationGateRefusal(
                "refused: cleanup group for \(planFileName) is no longer discovered; "
                    + "refresh the Cleanup tab and re-review"
            )
        }
        if let reason = candidate.disqualification {
            throw MutationGateRefusal("refused at gate-arm re-check: \(reason)")
        }
        guard let group = scanner.discoverGroups().first(
            where: { scalarExact($0.planFileName, planFileName) }
        ) else {
            throw MutationGateRefusal(
                "refused: cleanup group for \(planFileName) is no longer discovered; "
                    + "refresh the Cleanup tab and re-review"
            )
        }
        let targetCopies = sample.snapshots.first {
            scalarExact($0.name, candidate.targetName)
        }?.copies ?? []
        let liveCopies = sample.snapshots.first {
            scalarExact($0.name, candidate.groupName)
        }?.copies ?? []
        if let reason = try scanner.armVerification(
            group: group, listing: sample.listing,
            groupLiveCopies: liveCopies, targetLiveCopies: targetCopies
        ) {
            throw MutationGateRefusal("refused at gate-arm re-check: \(reason)")
        }
        guard targetCopies.count == 1, let target = targetCopies.first else {
            throw MutationGateRefusal(
                "refused: expected exactly 1 live \u{201C}\(candidate.targetName)\u{201D}, "
                    + "found \(targetCopies.count)"
            )
        }
        let liveCount = candidate.copies.filter { $0.disposition == .live }.count
        let note = "gate-arm re-check: merged target \u{201C}\(candidate.targetName)\u{201D} "
            + "verified fresh (ordered database IDs + persistent IDs + count); "
            + "\(liveCount) live copies re-validated against the merge plan"
        let fingerprint = listingFingerprint(of: sample.listing)
        let createdAt = ISO8601DateFormatter().string(from: now())
        var plans: [MutationPlan] = []
        var paths: [MutationAuditPaths] = []
        // Any throw below must not leave earlier-written, never-armed
        // artifacts re-armable-looking on disk: consume them before rethrow.
        func failArming(_ error: Error) -> Error {
            for auditPaths in paths {
                try? markMutationPlanConsumed(planURL: auditPaths.planURL)
            }
            return error
        }
        for status in candidate.copies where status.disposition == .live {
            guard let live = liveCopies.first(
                where: { scalarExact($0.persistentId, status.persistentID) }
            ) else {
                throw failArming(MutationGateRefusal(
                    "refused: live copy \(status.persistentID) vanished or was renamed "
                        + "between the re-check and arming"
                ))
            }
            let plan = MutationPlan(
                kind: .delete,
                playlistName: live.name,
                playlistPersistentID: live.persistentId,
                trackCount: live.tracks.count,
                orderedTrackPersistentIDs: live.tracks.map(\.persistentId),
                newName: nil,
                listingFingerprint: fingerprint,
                evidence: MutationEvidence(
                    mergePlanFileName: candidate.planFileName,
                    runReportFileName: nil,
                    verificationNote: note
                ),
                createdAtISO8601: createdAt,
                sessionID: appSessionID
            )
            let auditPaths: MutationAuditPaths
            do {
                auditPaths = try writeMutationAudit(
                    outputDir: outputDir, plan: plan,
                    summaryText: Self.mutationSummaryText(plan: plan)
                )
            } catch {
                throw failArming(error)
            }
            paths.append(auditPaths)
            if let reason = Self.mutationPreconditionFailure(
                armedPlan: plan, planURL: auditPaths.planURL,
                sessionID: appSessionID, at: now()
            ) {
                throw failArming(MutationGateRefusal(reason))
            }
            plans.append(plan)
        }
        guard let firstPlan = plans.first, let firstPaths = paths.first else {
            throw MutationGateRefusal(
                "refused: cleanup group has no live copies left to delete"
            )
        }
        guard generation == mutationGeneration, case .auditing = mutationGatePhase else {
            // Superseded after the artifacts landed: they must never stay
            // re-armable (B2 — abort consumes).
            for auditPaths in paths {
                try? markMutationPlanConsumed(planURL: auditPaths.planURL)
            }
            return
        }
        cleanupContext = CleanupGroupContext(
            groupName: candidate.groupName,
            targetName: candidate.targetName,
            targetGuard: MutationScriptBuilder.TargetGuardPayload(
                name: candidate.targetName,
                orderedTrackPersistentIDs: target.tracks.map(\.persistentId)
            ),
            plans: plans,
            paths: paths
        )
        let created = ISO8601DateFormatter().date(from: createdAt) ?? now()
        mutationGatePhase = .armed(MutationGateState(
            plan: firstPlan,
            paths: firstPaths,
            baseline: sample.listing,
            armedAt: now(),
            freshnessDeadline: created.addingTimeInterval(600),
            requiresCountToken: false,
            requiresPIDSuffixToken: false,
            collisionWarning: nil,
            confirmationName: candidate.groupName
        ))
    }

    // MARK: cleanup group execution (B3: strictly sequential, fail-closed)

    private enum CleanupCopyOutcome: Sendable {
        case verified
        case failed(mismatches: [String])
        case notAttempted
    }

    private func executeCleanupGroup(
        context: CleanupGroupContext,
        baseline: [PlaylistListing]
    ) {
        let generation = mutationGeneration
        let sessionID = appSessionID
        let clock = now
        let make = makeRunner
        let outputDirectoryPath = self.outputDirectoryPath
        let copyCount = context.plans.count
        mutationGatePhase = .executing(MutationExecutionProgress(
            copyIndex: 0, copyCount: copyCount, phase: .reValidating, startedAt: now()
        ))
        mutationTask = Task { [weak self] in
            let outcome = await Self.cleanupDispatchStage(
                context: context,
                baseline: baseline,
                sessionID: sessionID,
                now: clock,
                outputDirectoryPath: outputDirectoryPath,
                make: make
            ) { [weak self] copyIndex, phase in
                Task { @MainActor in
                    self?.advanceCleanupPhase(
                        copyIndex: copyIndex, copyCount: copyCount,
                        phase: phase, generation: generation
                    )
                }
            }
            self?.finishMutation(outcome, generation: generation)
            self?.clearCleanupContext(generation: generation)
        }
    }

    private func advanceCleanupPhase(
        copyIndex: Int, copyCount: Int, phase: MutationPhase, generation: Int
    ) {
        guard generation == mutationGeneration,
              case .executing(let progress) = mutationGatePhase else { return }
        mutationGatePhase = .executing(MutationExecutionProgress(
            copyIndex: copyIndex, copyCount: copyCount,
            phase: phase, startedAt: progress.startedAt
        ))
    }

    private func clearCleanupContext(generation: Int) {
        guard generation == mutationGeneration else { return }
        cleanupContext = nil
    }

    /// The B3 execution contract: copies strictly sequential, one
    /// performMutation per copy, baseline chained through a fresh listing
    /// after each verified copy, abort every remaining copy on the FIRST
    /// failure (thrown writer error, dispatch re-check refusal, or readback
    /// mismatch), consume every group artifact, write ONE result report.
    /// Never repair, never retry.
    private nonisolated static func cleanupDispatchStage(
        context: CleanupGroupContext,
        baseline: [PlaylistListing],
        sessionID: String,
        now: @escaping @Sendable () -> Date,
        outputDirectoryPath: String,
        make: @escaping @Sendable () -> any ScriptRunner,
        onPhase: @escaping @Sendable (Int, MutationPhase) -> Void
    ) async -> MutationDispatchOutcome {
        await Task.detached(priority: .userInitiated) { () -> MutationDispatchOutcome in
            let session = MusicBridgeSession(runner: make())
            var currentBaseline = baseline
            var outcomes = [CleanupCopyOutcome](
                repeating: .notAttempted, count: context.plans.count
            )
            var informational: [String] = []
            var failureMismatches: [String] = []
            var aborted = false
            for (index, plan) in context.plans.enumerated() {
                if aborted { break }
                // B2 dispatch re-check, per copy, immediately before its writer.
                if let reason = mutationPreconditionFailure(
                    armedPlan: plan, planURL: context.paths[index].planURL,
                    sessionID: sessionID, at: now()
                ) {
                    outcomes[index] = .failed(mismatches: [reason])
                    failureMismatches = [reason]
                    aborted = true
                    break
                }
                // Consume BEFORE the writer dispatch (a crash mid-write must
                // never leave a re-armable artifact).
                do {
                    try markMutationPlanConsumed(planURL: context.paths[index].planURL)
                } catch {
                    let reason = "refused: could not mark cleanup artifact consumed: "
                        + String(describing: error)
                    outcomes[index] = .failed(mismatches: [reason])
                    failureMismatches = [reason]
                    aborted = true
                    break
                }
                do {
                    let outcome = try session.performMutation(
                        plan: plan,
                        baseline: currentBaseline,
                        targetGuard: context.targetGuard,
                        progress: { onPhase(index, $0) }
                    )
                    informational.append(contentsOf: outcome.informational)
                    if outcome.verified {
                        outcomes[index] = .verified
                        if index + 1 < context.plans.count {
                            // Baseline chain: the post-copy listing becomes
                            // copy k+1's baseline; copy k+1's own fingerprint
                            // recheck keeps any gap drift fail-closed.
                            currentBaseline = try session.listPlaylists()
                        }
                    } else {
                        outcomes[index] = .failed(mismatches: outcome.mismatches)
                        failureMismatches = outcome.mismatches
                        aborted = true
                    }
                } catch {
                    let reason = "mutation failed: \(String(describing: error))"
                    outcomes[index] = .failed(mismatches: [reason])
                    failureMismatches = [reason]
                    aborted = true
                }
            }
            // Abort consumes the never-dispatched artifacts too (B2); marking
            // an already-consumed plan is a no-op by the persistence contract.
            for paths in context.paths {
                try? markMutationPlanConsumed(planURL: paths.planURL)
            }
            let verifiedAll = outcomes.allSatisfy {
                if case .verified = $0 { return true }
                return false
            }
            var resultReportPath: String?
            var resultWriteFailure: String?
            let firstPlanFileName = context.paths[0].planURL.lastPathComponent
            do {
                let url = try writeMutationResult(
                    outputDir: URL(fileURLWithPath: outputDirectoryPath, isDirectory: true),
                    baseName: mutationResultBaseName(planFileName: firstPlanFileName),
                    text: cleanupResultText(
                        context: context, outcomes: outcomes,
                        informational: informational, verifiedAll: verifiedAll
                    )
                )
                resultReportPath = url.path
            } catch {
                resultWriteFailure = "could not persist the cleanup result under "
                    + "\(outputDirectoryPath): \(String(describing: error))"
            }
            return .finished(MutationFinishDisplay(
                kind: .delete,
                playlistName: context.groupName,
                newName: nil,
                verified: verifiedAll,
                mismatches: failureMismatches,
                informational: informational,
                consumedPlanFileName: firstPlanFileName,
                resultReportPath: resultReportPath,
                resultWriteFailure: resultWriteFailure
            ))
        }.value
    }

    /// The ONE group-run report. Per verified copy it emits the
    /// machine-readable accounting line `deleted-ok <pid> <sha>` (three
    /// space-separated tokens; <sha> = that copy's consumed plan SHA-256 hex
    /// — the exact format Task 11's re-entry accounting parses). Failing
    /// copies carry their mismatch strings VERBATIM; never-dispatched copies
    /// are recorded NOT ATTEMPTED.
    private nonisolated static func cleanupResultText(
        context: CleanupGroupContext,
        outcomes: [CleanupCopyOutcome],
        informational: [String],
        verifiedAll: Bool
    ) -> String {
        var lines = [
            "# Mutation result \u{2014} cleanup group delete",
            "",
            "- Outcome: \(verifiedAll ? "VERIFIED" : "FAILED CLOSED")",
            "- Group: \(context.groupName)",
            "- Merged target: \(context.targetName)",
            "- Copies planned: \(context.plans.count)",
            "- Evidence merge plan: "
                + (context.plans[0].evidence?.mergePlanFileName ?? "(none)"),
        ]
        for (index, plan) in context.plans.enumerated() {
            lines.append("")
            lines.append("## Copy \(index) \u{2014} \(plan.playlistPersistentID)")
            lines.append("- Consumed plan: \(context.paths[index].planURL.lastPathComponent)")
            lines.append("- Consumed plan SHA-256: \(plan.sha256Hex())")
            switch outcomes[index] {
            case .verified:
                lines.append("- Outcome: VERIFIED (bijective listing diff clean)")
                lines.append("deleted-ok \(plan.playlistPersistentID) \(plan.sha256Hex())")
            case .failed(let mismatches):
                lines.append("- Outcome: FAILED CLOSED")
                lines.append("### Verbatim mismatches")
                lines.append(contentsOf: mismatches.map { "- \($0)" })
            case .notAttempted:
                lines.append(
                    "- Outcome: NOT ATTEMPTED (aborted after an earlier copy "
                        + "failed closed; artifact consumed unexecuted)"
                )
            }
        }
        if !informational.isEmpty {
            lines.append("")
            lines.append("## Informational")
            lines.append(contentsOf: informational.map { "- \($0)" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Abort-consumption shared by executeMutation supersede paths,
    /// dismissMutationGate, and startMutationAudit/startCleanupAudit when
    /// they replace an armed gate: single gates consume their one artifact,
    /// group gates consume every copy artifact.
    private func consumeArmedMutationArtifacts(_ state: MutationGateState) {
        if let context = cleanupContext {
            for paths in context.paths {
                try? markMutationPlanConsumed(planURL: paths.planURL)
            }
            cleanupContext = nil
        } else {
            try? markMutationPlanConsumed(planURL: state.paths.planURL)
        }
    }
}
