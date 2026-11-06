import Foundation

public struct PassReport: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case converged
        /// Ran, but the bar is not (fully) in the desired order: failures, the action cap, or work left for a next pass.
        case incomplete
        case skippedBusy
        case observeFailed
        /// The scans never agreed: the latest complete read was published but nothing was planned or done.
        case unsettled
        /// Abandoned during observation because a newer request (setLayout) needs a pass; the next pass starts at once.
        case superseded
        case permissionDenied
        /// Stopped (permission denied earlier, corrupt layout) and not resumed by `clearFailures()`.
        case stopped
        /// MenuBarAgent was respawned (by someone else) during the pass: nothing was actuated from observations of the new agent.
        case agentRestarted
        /// A conflicting manager (Bartender) is running (`setConflict`): no further actuator call was made; nothing struck or failed.
        case paused
    }
    public var outcome: Outcome
    /// Phase of the last plan computed in the pass.
    public var phase: PlanPhase?
    /// Actuator calls made (one membership batch counts as 1).
    public var actionCount: Int
    public init(outcome: Outcome, phase: PlanPhase? = nil, actionCount: Int = 0) {
        self.outcome = outcome; self.phase = phase; self.actionCount = actionCount
    }
}

/// Closed-loop runtime: observe -> plan -> act -> verify. See docs/architecture.md (LayoutEngine).
///
/// Suppression (flapping guard, gdu.21): a key whose actuation fails in a pass is an anchor for the rest of that pass
/// (the planner can neither move nor hide it). It is retried by the next pass, but when the SAME key fails
/// `Config.maxKeyFailures` (3) passes in a row it is marked `.failed` persistently (logged once) and stays an anchor until
/// `setLayout`, `clearFailures()` (the Retry button), or the key disappears from the observed bar (its app quit). The whole
/// engine reports `stoppedAfterFailures` only after `Config.maxAllFailedPasses` consecutive passes in which EVERY action failed.
public actor LayoutEngine {
    public struct Config: Sendable {
        public var minPassInterval: Duration = .milliseconds(500)
        public var maxActionsPerPass = 50
        public var busyWait: Duration = .seconds(3)
        public var busyPoll: Duration = .milliseconds(100)
        /// Consecutive self-rescheduled incomplete passes (membership then order) before the engine waits for an external trigger.
        public var maxChainedPasses = 2
        /// A pass stops (and does not chain) after this many consecutive failed actuator calls.
        public var maxConsecutiveFailures = 3
        /// The same key failing this many passes in a row is `.failed` until the layout changes or Retry.
        public var maxKeyFailures = 3
        /// Consecutive passes in which every action failed (each ended by `maxConsecutiveFailures`) before the engine reports `stoppedAfterFailures`.
        public var maxAllFailedPasses = 3
        /// Owners (iStat Menus) whose stale items do not block a pass (gdu.51: a move that drops next to one is only actuated on a
        /// COMPLETE read) and which the planner treats as ANCHORS: never moved, never planned by the layout, their observed slot is
        /// authoritative (gdu.33). Hiding and showing them is unaffected.
        public var selfPositioningOwners: Set<String> = SelfPositioning.defaultOwners
        /// `setLayout` calls closer together than this are one request: only the last layout is planned (gdu.47). Zero = no window.
        public var layoutCoalesce: Duration = .milliseconds(300)
        /// A burst of `setLayout` calls cannot postpone its pass past this long after the burst's first call.
        public var layoutCoalesceMax: Duration = .seconds(1)
        /// The Control Center tracked entries as stored now (nil = unreadable or not wired: owner-key hide units). Read at the start of
        /// every pass and when a layout is adopted; it decides the hide units (`HideUnitRule`, gdu.75), the same lookup the actuator uses.
        public var trackedResolver: @Sendable () -> TrackedEntryResolver? = { nil }
        /// gdu.71: a USER-INITIATED pass (reveal / re-hide, Arrange drop) may use the engine's last adopted observation, if it is
        /// younger than this and its read level is usable, as the first of the two agreeing scans, so one fresh scan must agree
        /// before planning. Zero disables the reuse. Trigger-, poll- and restart-initiated passes never reuse.
        public var userPassReuseWindow: Duration = .seconds(2)
        /// gdu.77: the window for an adopted observation whose age was refreshed by an unchanged poll (`notePollUnchanged`); the
        /// poll interval (10 s) plus the scan and timer slack. The fresh full scan must still agree on the full signature.
        public var polledSeedReuseWindow: Duration = .seconds(13)
        /// gdu.78: delayed retry of units a batch left unsettled (stale member): first delay, doubling per attempt up to the cap; after
        /// `unsettledRetryMaxAttempts` attempts or `unsettledRetryMaxWait` since the first unsettled batch the engine stops scheduling
        /// and the status line reports the units (they stay pending, never struck) until a real trigger or user action.
        /// gdu.87: retry of a pass that failed because Control Center's store is unreadable: first delay, doubling up to the cap, forever
        /// while the condition persists (the bar signature cannot change when a grant arrives, so nothing else would notice).
        public var storeRetryBase: Duration = .seconds(5)
        public var storeRetryCap: Duration = .seconds(60)
        /// gdu.105: while an order move is skipped because its subject's position is not corroborated (gdu.94), re-plan after this
        /// delay, doubling up to the cap; after `positionWaitTimeout` of continuous waiting the key becomes `.unsupported`.
        public var positionRetryBase: Duration = .seconds(2)
        public var positionRetryCap: Duration = .seconds(15)
        public var positionWaitTimeout: Duration = .seconds(60)
        public var unsettledRetryBase: Duration = .seconds(3)
        public var unsettledRetryCap: Duration = .seconds(60)
        public var unsettledRetryMaxAttempts = 10
        public var unsettledRetryMaxWait: Duration = .seconds(300)
        /// Builds the planner's capability rules from the SAME per-pass tracked-entry snapshot as the hide units (gdu.74), so an
        /// entry appearing or disappearing after launch is seen by planner and actuator alike. nil = the fixed provider given to `init`.
        /// gdu.79: the live Control Center `isAllowed` for a tracked entry key (nil = unreadable). The membership guard reads it; nil
        /// everywhere (the default) means the guard has no evidence and never fires.
        public var trackedAllowed: @Sendable (String) -> Bool? = { _ in nil }
        public var capabilitiesFor: (@Sendable (TrackedEntryResolver?) -> any CapabilityProvider)?
        public init() {}
    }

    private let observer: any MenuBarObserver
    private let actuator: any MenuBarActuator
    private let store: any LayoutStore
    private let capabilities: any CapabilityProvider
    private let state: EngineState
    private let busy: @Sendable () -> Bool
    private var itemInfo: [ItemKey: ItemInfo] = [:] { didSet { rule = HideUnitRule(resolver: resolverSnapshot, items: itemInfo) } }
    /// The tracked entries the current `rule` was built from (refreshed by `refreshHideUnits`).
    private var resolverSnapshot: TrackedEntryResolver?
    /// THE hide-unit rule of this engine (gdu.75): published in `EngineState.hideUnits` so Arrange and the panel group like the planner.
    private var rule = HideUnitRule.ownerKeys
    /// The capability rules of the current pass (derived from `resolverSnapshot` when `Config.capabilitiesFor` is set; gdu.74).
    private var activeCapabilities: (any CapabilityProvider)?
    /// Bumped whenever the tracked-entry snapshot content changes; `actuatorRefused` entries remember the epoch they were refused in.
    private var snapshotEpoch = 0
    private func refreshHideUnits() {
        let fresh = config.trackedResolver()
        if fresh?.entries != resolverSnapshot?.entries || (fresh == nil) != (resolverSnapshot == nil) { snapshotEpoch += 1 }
        resolverSnapshot = fresh
        activeCapabilities = config.capabilitiesFor?(fresh)
        rule = HideUnitRule(resolver: resolverSnapshot, items: itemInfo)
    }
    /// Read level of the latest observation (gdu.51).
    private var observedCompleteness = ReadCompleteness.complete
    /// Keys applied by a `.liveUnverified` batch and not yet confirmed by a settled complete read; value = hidden (gdu.55).
    private var unconfirmed: [ItemKey: Bool] = [:]
    /// Keys the latest observation reports hidden only through the assumed-hidden state (no hosted-tree evidence).
    private var assumedKeys: Set<ItemKey> = []
    private let resolveSnapshot: @Sendable (MenuBarSnapshot) -> [ResolvedItem]
    private let sleep: @Sendable (Duration) async -> Void
    private let log: @Sendable (String) -> Void
    public var config: Config

    private var layout: Layout = .empty
    /// gdu.79: keys the layout lists as visible because a USER placed them there (a `setLayout` that moved them into `visible`); a
    /// layout loaded from disk, built by init-from-current, adopted at first launch or extended by the new-item policy is not one.
    /// Cleared when the key is no longer listed visible or is seen on the bar.
    private var userPlacedVisible: Set<ItemKey> = []
    /// Per key: what the latest scan knew about where the item is (source, frame, join, Control Center flag), for the membership log.
    private var evidence: [ItemKey: String] = [:]
    private func noteEvidence(_ resolved: [ResolvedItem]) {
        for r in resolved where !r.item.stale {
            let i = r.item
            evidence[r.key] = "source=\(i.source.rawValue) frame=(\(Int(i.frame.minX)),\(Int(i.frame.minY)) \(Int(i.frame.width))x\(Int(i.frame.height))) onBar=\(i.isOnMenuBar) join=\(i.joinEvidence.rawValue)"
                + (i.hiddenReason.map { " hidden=\($0.rawValue)" } ?? "") + (i.controlCenterAllowed.map { " scanIsAllowed=\($0)" } ?? "")
        }
    }
    private var showHidden = false
    private var showAlways = false
    private var loaded = false
    private var failures: [ItemKey: ActuationError] = [:]
    private var pending = false
    /// Bumped by every explicit request that changes what a running pass should do (`setLayout`, `setShowHiddenSection`).
    /// A pass remembers the value it started with; a different value means its plan is stale and it ends `.superseded` (gdu.47).
    private var layoutGeneration = 0
    private var supersedeReason = "setLayout"
    /// When the first `setLayout` of the open coalescing burst arrived.
    private var burstStart: ContinuousClock.Instant?
    private var draining = false
    private var storeRetryAttempts = 0
    static let storeRetryReason = "store unreadable retry"
    static let positionRetryReason = "position retry"
    /// gdu.105: keys currently skipped for an uncorroborated position, with when the continuous wait began; keys that timed out.
    private var positionWaitSince: [ItemKey: ContinuousClock.Instant] = [:]
    private var positionTimedOut: Set<ItemKey> = []
    private var positionRetryAttempts = 0
    /// Test/diagnostic view: keys waiting for a trustworthy position, retries scheduled so far in this wait.
    public var positionWaitInfo: (waiting: Int, timedOut: Int, attempts: Int) { (positionWaitSince.count - positionTimedOut.count, positionTimedOut.count, positionRetryAttempts) }
    private var inPass = false
    /// When the last explicit (superseding) request arrived: `setLayout`, show/hide section, hold release, agent restart.
    private var userActionAt: ContinuousClock.Instant?
    private var userActions = 0
    /// The poll signature of the engine's latest agreed/adopted observation and a serial that changes with every publication (e7t).
    private var pollSignature: BarSignature.Value?
    private var pollSignatureSerial = 0
    private func notePollSignature(_ items: [ResolvedItem]) {
        let rule = BarSignature()
        guard let v = rule.value(AgreedScanObserver.dedupe(items).items)?.forPoll(selfPositioningOwners: rule.selfPositioningOwners) else { return }
        pollSignature = v; pollSignatureSerial += 1
    }
    private func noteUserAction() { userActionAt = .now; userActions += 1 }

    // MARK: Unsettled-unit retry (gdu.78)
    /// The reason of the delayed pass that retries unsettled units. Not a poll trigger (the poll calls `requestReconcile(reason: "poll")`,
    /// which the gdu.58 cap counts at the trigger) and not user-initiated (`fireDelayed` seeds only "setLayout").
    static let unsettledReason = "unsettled units"
    private var unsettledKeys = Set<ItemKey>()
    private var unsettledAttempts = 0
    private var unsettledSince: ContinuousClock.Instant?
    private var unsettledDelay: Duration?
    private var unsettledNoticeShown = false
    /// Test/diagnostic view: retry attempts fired so far, the delay of the retry currently scheduled (nil = none), units waiting.
    public var unsettledRetryInfo: (attempts: Int, scheduledDelay: Duration?, waiting: Int) { (unsettledAttempts, unsettledDelay, unsettledKeys.count) }

    /// A batch left `now` unsettled and applied/ruled on the rest of `batch`: schedule the back-off retry, or give up honestly.
    private func noteUnsettled(_ now: Set<ItemKey>, batch: Set<ItemKey>) async {
        unsettledKeys.subtract(batch); unsettledKeys.formUnion(now)
        if unsettledKeys.isEmpty { return await clearUnsettled() }
        if unsettledSince == nil { unsettledSince = .now }
        if unsettledAttempts >= config.unsettledRetryMaxAttempts || (unsettledSince.map { $0.duration(to: .now) >= config.unsettledRetryMaxWait } ?? false) {
            delayed[Self.unsettledReason]?.cancel(); delayed[Self.unsettledReason] = nil; unsettledDelay = nil
            log("engine: \(unsettledKeys.count) unit(s) still waiting for the bar to settle after \(unsettledAttempts) retries; no further retry until a trigger")
            let n = unsettledKeys.count
            unsettledNoticeShown = true
            await publish { $0.unsettledNotice = n == 1 ? "1 item waiting for the bar to settle" : "\(n) items waiting for the bar to settle" }
            return
        }
        var d = config.unsettledRetryBase
        for _ in 0..<unsettledAttempts { d = d * 2; if d >= config.unsettledRetryCap { break } }
        if d > config.unsettledRetryCap { d = config.unsettledRetryCap }
        unsettledDelay = d
        scheduleReconcile(after: d, reason: Self.unsettledReason)
    }

    /// Nothing is unsettled any more (applied, or superseded): cancel the retry and reset the back-off and notice.
    private func clearUnsettled() async {
        unsettledKeys = []
        resetUnsettledBackoff()
        if unsettledNoticeShown { unsettledNoticeShown = false; await publish { $0.unsettledNotice = nil } }
    }

    /// gdu.78: a unit that left the bar is no longer waiting (so the notice never counts a gone unit).
    private func pruneUnsettled(_ obs: ObservedOrder) {
        guard !unsettledKeys.isEmpty else { return }
        let present = Set(obs.onBar + obs.parked)
        let kept = unsettledKeys.intersection(present)
        guard kept.count != unsettledKeys.count else { return }
        unsettledKeys = kept
        if kept.isEmpty { resetUnsettledBackoff(); return }
        if unsettledNoticeShown {
            let n = kept.count
            Task { await self.publish { $0.unsettledNotice = n == 1 ? "1 item waiting for the bar to settle" : "\(n) items waiting for the bar to settle" } }
        }
    }

    private func resetUnsettledBackoff() {
        unsettledAttempts = 0; unsettledSince = nil; unsettledDelay = nil
        delayed[Self.unsettledReason]?.cancel(); delayed[Self.unsettledReason] = nil
        if unsettledNoticeShown { unsettledNoticeShown = false; Task { await self.publish { $0.unsettledNotice = nil } } }
    }
    private var stopped = false
    private var busyRetried = false
    private var chained = 0
    private var lastStart: ContinuousClock.Instant?
    /// The running observation of the current pass; cancelled by an explicit request (`setLayout`) so the new pass starts at once.
    private var observeTask: Task<Result<(ObservedOrder, Bool), ObserveError>, Never>?
    /// True once any observation (settled or provisional) has been published.
    private var hasObservation = false
    /// When the oldest unserved request arrived, for the "pass delayed" log.
    private var requestedAt: ContinuousClock.Instant?
    private var requestReason = "request"
    private var requestedDuringPass = false
    /// gdu.71: the oldest unserved request is a user action (setLayout, setReveal), not a trigger.
    private var requestUserInitiated = false
    /// gdu.71: the latest adopted observation (a settled observation, or a snapshot adopted after an actuator call), for reuse
    /// as the first scan of a user-initiated pass.
    private var lastAdopted: (items: [ResolvedItem], completeness: ReadCompleteness, at: ContinuousClock.Instant)?
    /// gdu.77: the poll-signature serial that belongs to `lastAdopted` (nil when its signature could not be noted), and whether its
    /// age was refreshed by an unchanged poll (which widens the reuse window to `polledSeedReuseWindow`).
    private var lastAdoptedSerial: Int?
    private var lastAdoptedPolled = false
    private func noteAdopted(_ items: [ResolvedItem], _ completeness: ReadCompleteness, serialBefore: Int) {
        lastAdopted = (items, completeness, .now)
        noteChurn(items, completeness)
        lastAdoptedSerial = pollSignatureSerial != serialBefore ? pollSignatureSerial : nil
        lastAdoptedPolled = false
    }

    /// gdu.77: the poll's fast scan read the bar as the engine's own latest signature (`serial`). Refreshes ONLY the age of the
    /// adopted observation (never its content) so an idle user click may still use it as the first of its two agreeing scans.
    /// Ignored when the serial moved on, a pass is running or requested, or no adopted observation belongs to that serial.
    public func notePollUnchanged(serial: Int) {
        guard let a = lastAdopted, lastAdoptedSerial == serial, pollSignatureSerial == serial,
              !inPass, !pending, requestedAt == nil, notReadyUntil == nil else { return }
        if !lastAdoptedPolled { log("poll: bar unchanged since the adopted observation; its age is refreshed for the next user pass") }
        lastAdopted = (a.items, a.completeness, .now)
        lastAdoptedPolled = true
    }
    /// Fresh scans the latest `observeOnce` used.
    private var lastObserveScans = 0
    /// Hide units temporarily revealed on purpose (overflow-panel click-forwarding, gdu.17): hold token per unit.
    private var transientReveals: [HideUnit: Int] = [:]
    private var nextHoldToken = 0
    /// Consecutive passes in which the key failed (1...maxKeyFailures); a key at the limit is no longer retried.
    private var strikes: [ItemKey: Int] = [:]
    /// gdu.69: keys whose move the actuator refused in THIS pass because the subject or anchor is in macOS's overflow area
    /// (belt and braces: the planner already skips flagged items). Never struck; their moves are dropped from the plan.
    private var overflowRefused: [ItemKey: String] = [:]
    /// gdu.80: the last two COMPLETE reads' churn data (pile + first-drawn neighbourhood). The churn zone is their union; the
    /// overflow set is settled when both agree. A pass that changed membership on a full bar never orders; the order phase waits
    /// for two agreeing complete reads.
    private var recentReads: [ChurnRead] = []
    private func noteChurn(_ items: [ResolvedItem], _ completeness: ReadCompleteness) {
        guard completeness == .complete else { return }
        recentReads.append(ChurnRead(resolved: items))
        if recentReads.count > 2 { recentReads.removeFirst(recentReads.count - 2) }
    }
    /// gdu.72: units the actuator refused to write (key -> reason; not tracked, Apple app...). Kept across passes so they are not
    /// retried every pass, never struck, shown `.unsupported`; cleared by `clearFailures` (layout change, Retry).
    private var actuatorRefused: [ItemKey: String] = [:]
    /// The `snapshotEpoch` each `actuatorRefused` key was refused in (gdu.74): re-evaluated when the snapshot has changed since.
    private var refusedEpoch: [ItemKey: Int] = [:]
    private var failedThisPass: Set<ItemKey> = []
    private var allFailedStreak = 0
    private var cutThisPass = false
    /// While set and in the future, observations are not acted on (MenuBarAgent just respawned; its first scans are incomplete).
    private var notReadyUntil: ContinuousClock.Instant?
    /// Between willSleep and didWake: no pass starts, a running pass ends after its current action.
    private var sleeping = false
    /// Name of a conflicting menu bar manager (Bartender), set from outside the actor so it takes effect between two actuator
    /// calls of a running pass. While set, no pass starts and a running pass ends `.paused` before its next actuator call.
    private nonisolated let conflictBox = ConflictBox()
    private var conflicted: Bool { conflictBox.value != nil }
    private var delayed: [String: Task<Void, Never>] = [:]
    private var noticeSerial = 0
    private let agentPID: @Sendable () -> pid_t?
    private let isOwnAgentPID: @Sendable (pid_t) -> Bool
    /// The agent pid the running pass started with (re-based after our own respawn).
    private var passAgent: pid_t?
    private var foreignRestartInPass = false

    public init(observer: any MenuBarObserver, actuator: any MenuBarActuator, store: any LayoutStore,
                capabilities: any CapabilityProvider, state: EngineState,
                busy: @escaping @Sendable () -> Bool = { false },
                resolveSnapshot: @escaping @Sendable (MenuBarSnapshot) -> [ResolvedItem],
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                log: @escaping @Sendable (String) -> Void = { _ in },
                showHiddenSection: Bool = false, showAlwaysHidden: Bool = false, config: Config = Config(),
                agentPID: @escaping @Sendable () -> pid_t? = { nil },
                isOwnAgentPID: @escaping @Sendable (pid_t) -> Bool = { _ in false }) {
        self.agentPID = agentPID; self.isOwnAgentPID = isOwnAgentPID
        self.showHidden = showHiddenSection
        self.showAlways = showAlwaysHidden
        self.observer = observer; self.actuator = actuator; self.store = store; self.capabilities = capabilities
        self.state = state; self.busy = busy; self.resolveSnapshot = resolveSnapshot; self.sleep = sleep
        self.log = log; self.config = config
    }

    // MARK: Public control

    /// Loads the layout (missing file -> empty; corrupt -> `lastError` and the engine stays stopped) and publishes it.
    /// Does not start a pass; call `requestReconcile()`.
    public func start() async {
        var movedAtLoad: [ItemKey] = []
        refreshHideUnits()
        do {
            let loadedLayout = try store.load()
            let (pruned, junk) = loadedLayout.prunedAgentNoise()
            if !junk.isEmpty {
                log("layout: pruned \(junk.count) agent heuristic key(s) with an empty fingerprint")
                try? store.save(pruned)
            }
            let (l0, moved) = pruned.validatedReportingNormalization(units: rule)
            layout = l0
            if !l0.enforcesOrder || !l0.placed.isEmpty { logOrderMode(l0) }
            if l0.enforcesOrder && l0.placed.isEmpty {
                // gdu.89: every layout written before the `placed` field. The engine never infers an order obligation from a saved order.
                log("layout loaded: no order obligations exist (no item was placed by you in Arrange); the engine will plan no moves, items keep the order macOS gives them")
            }
            movedAtLoad = moved
            if !moved.isEmpty {
                AppLog.log(.engine, "layout: all items governed by one Control Center entry hide or show at once; moved to visible: \(moved.map(\.description).joined(separator: ", "))")
            }
            loaded = true
            stopped = false
        } catch {
            loaded = false
            stopped = true
            await publish { $0.lastError = .observe("cannot load layout: \(error)") }
            return
        }
        let l = layout, sh = showHidden, mv = movedAtLoad
        await publish { $0.layout = l; $0.showHiddenSection = sh; $0.lastError = nil; $0.lastNormalization = mv; $0.layoutRevision += 1; $0.passesStartedAtRevision = $0.passesStarted }
    }

    /// Keys the engine itself appended (new-item policy) with the layout revision that added them and their engine-chosen
    /// position, newest last, capped at `maxEngineAdditions` (gdu.52). `setLayout(_:basedOn:)` re-adds those newer than the
    /// revision a drop was composed on, so a drop never discards an item the engine appended in between.
    private var engineAdditions: [(revision: Int, key: ItemKey, section: LayoutSection, index: Int)] = []
    private static let maxEngineAdditions = 50

    /// Re-adds engine additions newer than `revision` that `l` lacks (user placement in `l` wins). Returns the count re-added.
    private func mergeEngineAdditions(into l: inout Layout, since revision: Int) -> Int {
        var n = 0
        for a in engineAdditions where a.revision > revision && l.section(of: a.key) == nil {
            // A sibling of the same hide unit already in `l` decides the section (units stay whole).
            let sibling = l.allKeys.first { $0 != a.key && rule.unit(of: $0) == rule.unit(of: a.key) }
            let sec = sibling.flatMap { l.section(of: $0) } ?? a.section
            l.reorder(a.key, in: sec, toIndex: a.index)
            n += 1
        }
        return n
    }

    /// Adopts the requested layout, publishes it with a new revision stamp (`layoutRevision`, `passesStartedAtRevision`) and returns
    /// that stamp: the caller judges its change only by passes started after it. `revision`: the layout revision the caller composed
    /// `requested` on. When given, keys the engine appended since then that `requested` lacks are re-added at their engine positions
    /// (log `setLayout merged ...`); a key `requested` already places keeps the user's placement. `nil` (mbprobe, `apply`):
    /// `requested` replaces the layout wholesale.
    @discardableResult
    public func setLayout(_ requested: Layout, basedOn revision: Int? = nil, userPlacement: Bool = true, moved movedKeys: Set<ItemKey> = []) async -> LayoutRevision {
        noteUserAction()
        var requested = requested
        if let revision {
            let n = mergeEngineAdditions(into: &requested, since: revision)
            if n > 0 { log("setLayout merged \(n) engine-added key(s) composed on revision \(revision)") }
        }
        // Hide units are all-or-nothing: a split unit can never converge, so it is normalized (and reported) here too (gdu.44).
        refreshHideUnits()
        var (new, moved) = requested.normalizedHideUnits(units: rule)
        if !moved.isEmpty {
            log("layout: all items governed by one Control Center entry hide or show at once; moved to visible: \(moved.map(\.description).joined(separator: ", "))")
        }
        // gdu.89: order obligations. A user placement (Arrange submit) carries its placed keys in `requested.placed`; a call that is not
        // a user placement (a layout built from a scan) can neither add nor clear obligations. Either way only visible keys can hold one.
        new.placed = userPlacement ? requested.placed : layout.placed
        new = new.pruningPlaced()
        new.orderMode = userPlacement ? requested.orderMode : layout.orderMode   // a scan-built layout never changes who owns the order (8z5.1)
        // gdu.79: keys this call moved into `visible` are the user's explicit placement; the rest keep the status they had.
        let wasVisible = Set(layout.visible)
        userPlacedVisible = userPlacedVisible.intersection(new.visible)
        if userPlacement {
            userPlacedVisible.formUnion(new.visible.filter { !wasVisible.contains($0) })
            // gdu.95: a key the user dropped counts as placed even when the layout already listed it visible (hidden in Control Center).
            userPlacedVisible.formUnion(movedKeys.intersection(Set(new.visible)))
        }
        layout = new
        loaded = true
        noteSupersede("setLayout")
        do { try store.save(new) } catch { log("cannot save layout: \(error)") }
        let stamp = await publishLayout(new, normalized: moved)
        await clearFailures()
        if config.layoutCoalesce > .zero {
            // The pass for this layout starts after the window; a further setLayout inside it replaces this one (same reason
            // key), so a quick change of mind plans only the final layout. The drop's revision stamp is unaffected: the first
            // drop's keys are judged by the first pass started after the stamp, against the then-current (final) layout.
            if delayed["setLayout"] != nil { log("setLayout coalesced with an earlier one inside \(config.layoutCoalesce)") }
            var delay = config.layoutCoalesce
            if delayed["setLayout"] != nil, let b = burstStart {
                delay = min(delay, max(.zero, config.layoutCoalesceMax - b.duration(to: .now)))   // the burst's cap
            } else {
                burstStart = .now
            }
            scheduleReconcile(after: delay, reason: "setLayout")
        } else {
            requestReconcile(supersede: true, reason: "setLayout", userInitiated: true)
        }
        return stamp
    }

    private func logOrderMode(_ l: Layout) {
        if l.enforcesOrder { log("order mode: placed items only (\(l.placed.count) placed)") }
        else { log("order mode: macOS owns the order (\(l.placed.count) remembered placements, not enforced)") }
    }

    /// 8z5.2: switches who owns the order. Unchanged: returns the current revision, no write. Otherwise persists, bumps the revision,
    /// publishes and requests a pass. `placed` is untouched (macOSOwns keeps the keys recorded; placedOnly re-arms them).
    @discardableResult
    public func setOrderMode(_ mode: OrderMode) async -> LayoutRevision {
        let current: LayoutRevision = await MainActor.run { [state] in LayoutRevision(revision: state.layoutRevision, passesStarted: state.passesStarted) }
        guard loaded else {   // never overwrite a layout file that failed to load with a default layout
            log("order mode: ignored, layout not loaded")
            return current
        }
        if layout.orderMode == mode { return current }
        noteUserAction()
        let new = layout.withOrderMode(mode)
        layout = new
        noteSupersede("setOrderMode")
        do { try store.save(new) } catch { log("cannot save layout: \(error)") }
        logOrderMode(new)
        let stamp = await publishLayout(new)
        await clearFailures()   // also ends any position wait
        if !new.enforcesOrder { await publish { $0.orderMoveNotice = nil; $0.orderMoveReasons = [:] } }
        requestReconcile(supersede: true, reason: "setOrderMode", userInitiated: true)
        return stamp
    }

    /// A request arrived that makes a running pass's plan stale: invalidate it and abandon an observation in progress.
    private func noteSupersede(_ reason: String) {
        layoutGeneration += 1
        supersedeReason = reason
        if let t = observeTask {
            log("\(reason): abandoning the observation in progress")
            t.cancel()
        }
    }

    /// Publishes `l` as the next layout revision, stamped with the passes started so far (one main-actor hop, so the stamp is exact).
    @discardableResult
    private func publishLayout(_ l: Layout, normalized: [ItemKey]? = nil) async -> LayoutRevision {
        let s = state, hu = rule   // gdu.76: the rule setLayout just refreshed is published with the layout, not at the next observation
        return await MainActor.run {
            s.layout = l
            s.hideUnits = hu
            if let normalized { s.lastNormalization = normalized }
            s.layoutRevision += 1
            s.passesStartedAtRevision = s.passesStarted
            return LayoutRevision(revision: s.layoutRevision, passesStarted: s.passesStarted)
        }
    }

    public func setShowHiddenSection(_ on: Bool) async {
        await setReveal(hidden: on, alwaysHidden: showAlways && on)
    }

    /// Reveal request (inline "show the rest"): `hidden` shows the hidden section, `alwaysHidden` also the always-hidden one.
    /// A normal pass follows (live writes, verification); `EngineState.revealedObserved` follows the pass, not this call.
    public func setReveal(hidden: Bool, alwaysHidden: Bool) async {
        showHidden = hidden
        showAlways = alwaysHidden
        noteSupersede("setShowHiddenSection")
        await publish { $0.showHiddenSection = hidden; $0.showAlwaysHidden = alwaysHidden }
        requestReconcile(supersede: true, reason: "setShowHiddenSection", userInitiated: true)
    }

    /// Forgets suppressed failures and resumes a stopped engine. Does not itself trigger a pass.
    public func clearFailures() async {
        failures = [:]; strikes = [:]; failedThisPass = []; allFailedStreak = 0; actuatorRefused = [:]; refusedEpoch = [:]
        positionWaitSince = [:]; positionTimedOut = []; positionRetryAttempts = 0
        delayed[Self.positionRetryReason]?.cancel(); delayed[Self.positionRetryReason] = nil
        unconfirmed = [:]
        stopped = !loaded   // a layout that never loaded stays stopped until `start()` succeeds or `setLayout`
        chained = 0
        await publish { s in
            s.perItem = s.perItem.filter { if case .failed = $0.value { return false } else { return true } }
            switch s.lastError {
            case .permissionDenied?, .stoppedAfterFailures?, .batchDrift?, .batchFailed?: s.lastError = nil
            default: break
            }
        }
    }

    /// External trigger. Concurrent triggers coalesce: at most one further pass runs after the current one.
    /// `supersede` (explicit user actions only, never the poll): an observation still in progress is abandoned so the
    /// pass for this request starts at once instead of after up to `AgreedScanObserver.deadline` seconds.
    /// `userInitiated` (gdu.71; set by `setLayout` and `setReveal`, never by the poll, triggers or restarts): the pass may reuse the last
    /// adopted observation as its first agreeing scan (`Config.userPassReuseWindow`).
    public func requestReconcile(supersede: Bool = false, reason: String = "trigger", userInitiated: Bool = false) {
        guard loaded else { Task { await self.noteLayoutNotLoaded() }; return }
        guard !stopped, !sleeping, !conflicted else { return }
        if supersede { noteUserAction() }
        if reason != Self.unsettledReason, reason != "poll" { resetUnsettledBackoff() }   // gdu.78: a non-poll trigger / user action restarts the back-off
        if requestedAt == nil || supersede { requestedAt = .now; requestReason = reason; requestedDuringPass = inPass; requestUserInitiated = userInitiated }
        else if userInitiated { requestUserInitiated = true }
        pending = true
        if supersede, let t = observeTask {
            supersedeReason = reason
            log("\(reason): abandoning the observation in progress")
            t.cancel()
        }
        kick()
    }

    private func noteLayoutNotLoaded() async {
        await publish { $0.lastError = .observe("layout not loaded") }
    }

    /// Runs exactly one pass now (not subject to `minPassInterval`), even if a scheduled one is pending.
    public func reconcileOnce() async -> PassReport {
        if !loaded { await start() }
        guard loaded else { await noteLayoutNotLoaded(); return PassReport(outcome: .stopped) }
        guard !stopped else { return PassReport(outcome: .stopped) }
        while inPass { await Task.yield(); await sleep(.milliseconds(10)) }
        pending = false
        return await runPass(scheduled: false)
    }

    // MARK: Robustness events (gdu.21)

    /// gdu.87: schedules the next bounded-back-off retry after a pass failed with `ObserveError.trackedStoreUnreadable`.
    private func scheduleStoreRetry() {
        let factor = 1 << min(storeRetryAttempts, 12)
        let delay = min(config.storeRetryBase * factor, config.storeRetryCap)
        storeRetryAttempts += 1
        log("Control Center's store is unreadable; retrying in \(delay)")
        scheduleReconcile(after: delay, reason: Self.storeRetryReason)
    }

    /// Requests a reconcile after `delay`. A later call with the same `reason` replaces the pending one (a burst of display
    /// notifications or app launches yields ONE pass).
    public func scheduleReconcile(after delay: Duration, reason: String, supersede: Bool = false) {
        delayed[reason]?.cancel()
        delayed[reason] = Task { [weak self] in
            try? await Task.sleep(for: delay)   // wall clock on purpose (the injected `sleep` paces passes)
            guard !Task.isCancelled else { return }
            await self?.fireDelayed(reason, supersede: supersede)
        }
    }

    private func fireDelayed(_ reason: String, supersede: Bool) {
        delayed[reason] = nil
        if reason == Self.unsettledReason { unsettledAttempts += 1; unsettledDelay = nil }
        if reason == "setLayout" { burstStart = nil }
        requestReconcile(supersede: supersede, reason: reason, userInitiated: reason == "setLayout")
    }

    /// MenuBarAgent respawned: every AX element is invalid and its first scans are empty or incomplete. Observations are not
    /// acted on for `settle`, transient reveal holds are dropped (the revealed element is gone), and ONE reconcile follows.
    public func agentRestarted(settle: Duration = .seconds(2)) async {
        notReadyUntil = .now + settle
        lastAdopted = nil; lastAdoptedSerial = nil; lastAdoptedPolled = false
        let units = Array(transientReveals.keys)
        transientReveals = [:]
        if !units.isEmpty {
            log("agent restarted: dropping \(units.count) transient reveal hold(s)")
            let keys = itemInfo.keys.filter { units.contains(rule.unit(of: $0)) }
            await publish { s in for k in keys where s.perItem[k] == .pending { s.perItem[k] = .inPlace } }
        }
        scheduleReconcile(after: settle, reason: "agent restarted", supersede: true)
    }

    /// The system is about to sleep: no new pass starts and a running pass ends after the action in flight.
    public func willSleep() {
        guard !sleeping else { return }
        sleeping = true
        pending = false
        delayed.values.forEach { $0.cancel() }
        delayed = [:]
        log("willSleep: no new passes until wake")
    }

    /// Wake: reconcile after `settle` (displays and the agent need a moment).
    public func didWake(settle: Duration = .seconds(3)) {
        sleeping = false
        log("didWake: reconcile in \(settle)")
        scheduleReconcile(after: settle, reason: "wake")
    }

    /// Clears a sleep flag whose wake notification was missed (the triggers were stopped in between).
    public func resumeFromSleep() { sleeping = false }

    public var isSleeping: Bool { sleeping }

    /// A conflicting manager appeared (`who`) or went away (`nil`). Callable from any context and effective at once: the pass in
    /// flight issues no further actuator call and ends `.paused` (no failure recorded). Clearing does not start a pass; the
    /// caller reconciles afterwards.
    public nonisolated func setConflict(_ who: String?) { conflictBox.value = who }

    // MARK: Scheduling

    private func kick() {
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while pending, !stopped, !sleeping, !conflicted {
            if let last = lastStart {
                let wait = config.minPassInterval - last.duration(to: .now)
                if wait > .zero { await sleep(wait) }
            }
            let t0 = ContinuousClock.now
            while inPass { await Task.yield(); await sleep(.milliseconds(10)) }
            noteDelay("previous pass still running", since: t0)
            pending = false
            _ = await runPass(scheduled: true)
        }
        draining = false
    }

    /// Logs a wait of more than 2 s, with its reason.
    private func noteDelay(_ reason: String, since t0: ContinuousClock.Instant) {
        let ms = Self.ms(t0.duration(to: .now))
        if ms > 2000 { log("pass delayed: \(reason) \(ms) ms") }
    }

    private static func ms(_ d: Duration) -> Int {
        let c = d.components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: One pass

    private func publish(_ body: @MainActor @Sendable (EngineState) -> Void) async {
        let s = state
        await MainActor.run { body(s) }
    }

    private func effectiveCaps() -> @Sendable (ItemKey) -> Capability {
        let bad = Set(failures.keys), caps = activeCapabilities ?? capabilities, refused = actuatorRefused
        return { k in
            if let why = refused[k] { return Capability(canMove: caps.capability(for: k).canMove, canHide: false, reason: why) }
            return bad.contains(k) ? Capability(canMove: false, canHide: false, reason: "failed earlier") : caps.capability(for: k)
        }
    }

    /// gdu.74, start of each pass (after the snapshot refresh): a refused unit whose key vanished is dropped; one refused under an
    /// older tracked-entry snapshot is dropped when the rules now allow it (it is tried again, no Retry needed). Units the rules
    /// still refuse, or refused under the current snapshot, stay `.unsupported` (no strike).
    private func reevaluateRefused(_ obs: ObservedOrder) {
        guard !actuatorRefused.isEmpty else { return }
        let present = Set(obs.onBar + obs.parked)
        let caps = activeCapabilities ?? capabilities
        for k in Array(actuatorRefused.keys) {
            if !present.contains(k) || (refusedEpoch[k] != snapshotEpoch && caps.capability(for: k).canHide) {
                actuatorRefused[k] = nil; refusedEpoch[k] = nil
            }
        }
    }

    static let noEntrySkipReason = "cannot be shown: no Control Center entry"
    static let fullBarSkipReason = "cannot be shown: the bar is full; macOS would keep it behind the chevron. It is in the panel."
    /// Number of keys withheld by the last pass's full-bar rule (log once per change, not once per pass).
    private var fullBarLogged = 0

    private func makePlan(_ obs: ObservedOrder) -> Plan {
        refreshHideUnits()
        reevaluateRefused(obs)
        pruneUnsettled(obs)
        var planObs = withoutTransient(obs)
        userPlacedVisible.subtract(planObs.onBar)   // a user placement that came true is spent: a later hide by someone else stands
        // gdu.79: parked keys the planner must not show. (1) placement unknown: nothing proves they are hidden, so there is nothing to
        // show. (2) listed visible but not by the user while Control Center says isAllowed == false: a layout from disk / init-from-current
        // / a scan must never un-hide an item the user hid. Both come back as explicit skips (neutral), never as an action.
        var guarded: [(key: ItemKey, why: String)] = []
        for k in planObs.parked where planObs.placementUnknown.contains(k) {
            guarded.append((k, "placement unknown (app-side frame only, no hosted element)"))
        }
        let flagCandidates = planObs.parked.filter { layout.section(of: $0) == .visible && !userPlacedVisible.contains($0) && !planObs.placementUnknown.contains($0) }
        for k in flagCandidates {
            guard let tk = resolverSnapshot?.trackedKey(for: k, bundleID: itemInfo[k]?.ownerBundleID), config.trackedAllowed(tk) == false else { continue }
            guarded.append((k, "Hidden in Control Center. Drop it into Visible (or use Move to Visible) to show it."))
            log("engine: not showing \(k): Control Center \(tk) isAllowed=false, layout lists it visible but not by a user placement; evidence: \(evidence[k] ?? "none")")
        }
        if !guarded.isEmpty { let g = Set(guarded.map(\.key)); planObs.parked.removeAll { g.contains($0) } }
        // gdu.72: parked units the actuator still refuses (after `reevaluateRefused`) are withheld from the Reconciler so it does not
        // plan an endless show; they come back as explicit skips with the refusal reason. On-bar ones: `effectiveCaps` (cannot hide).
        let refusedParked = planObs.parked.filter { actuatorRefused[$0] != nil }
        if !refusedParked.isEmpty { planObs.parked.removeAll { actuatorRefused[$0] != nil } }
        // gdu.111: on a FULL bar (a fresh overflow chevron is present) a reveal into the menu bar is useless: there is no free space, so
        // macOS keeps the shown items behind its chevron (reported, not drawn). The panel is the reveal; the hidden-listed parked keys are
        // withheld from the Reconciler and come back as "cannot be shown" skips (counted by `revealSkipNotice`). No show, no re-plan.
        var fullBarWithheld: [ItemKey] = []
        if (showHidden || showAlways), planObs.overflowChevron != nil {
            fullBarWithheld = planObs.parked.filter { k in
                let sec = layout.section(of: k)
                return (showHidden && sec == .hidden) || (showAlways && sec == .alwaysHidden)
            }
            if !fullBarWithheld.isEmpty {
                let w = Set(fullBarWithheld)
                planObs.parked.removeAll { w.contains($0) }
                if fullBarLogged != fullBarWithheld.count { log("reveal: bar is full (chevron): \(fullBarWithheld.count) hidden items stay in the panel, none shown") }
            }
        }
        fullBarLogged = fullBarWithheld.count
        var p = Reconciler().plan(observed: planObs, layout: layout, capabilities: effectiveCaps(), showHiddenSection: showHidden, showAlwaysHidden: showAlways,
                                         selfPositioningOwners: config.selfPositioningOwners, units: rule,
                                         churn: SystemOverflowRule.churnZone(recentReads), placed: layout.enforcesOrder ? layout.placedSet : [])   // 8z5.2: macOS owns the order -> nothing is placed, nothing may move
        // While any unit is revealed for click-forwarding the bar is deliberately in flux (the revealed element can show up
        // as an unknown heuristic item at the unit's frame): the engine plans NOTHING, not even other units, and records no
        // new items. A hold is short-lived; the pass after `endTransientReveal` reconciles.
        if !transientReveals.isEmpty { p.actions = []; p.newItems = []; p.phase = .converged }
        for g in guarded {
            p.skipped.removeAll { $0.key == g.key }
            p.skipped.append(SkippedAction(g.key, g.why))
        }
        for k in fullBarWithheld where !p.skipped.contains(where: { $0.key == k }) {
            p.skipped.append(SkippedAction(k, Self.fullBarSkipReason))
        }
        for k in refusedParked {
            p.skipped.removeAll { $0.key == k }
            // gdu.78: during a reveal the refusal is a "cannot be shown" skip, so `revealSkipNotice` counts it.
            let why = actuatorRefused[k] ?? "cannot be shown"
            // Only a unit in a REVEALED section (the set `finish` judges the reveal by) is a "cannot be shown" skip.
            let sec = layout.section(of: k)
            let wanted = (showHidden && sec == .hidden) || (showAlways && sec == .alwaysHidden)
            p.skipped.append(SkippedAction(k, wanted && !why.hasPrefix("cannot be shown") ? "cannot be shown: " + why : why))
        }
        if !overflowRefused.isEmpty {
            func refused(_ a: PlannedAction) -> ItemKey? {
                guard case .move(let k, let rel) = a else { return nil }
                if overflowRefused[k] != nil { return k }
                switch rel {
                case .before(let t), .after(let t): return overflowRefused[t] != nil ? k : nil
                case .leftmost, .rightmost: return nil
                }
            }
            let dropped = p.actions.compactMap(refused)
            if !dropped.isEmpty {
                p.actions.removeAll { refused($0) != nil }
                for k in dropped where !p.skipped.contains(where: { $0.key == k }) { p.skipped.append(SkippedAction(k, Reconciler.overflowSkipReason)) }
                if p.phase == .order, p.actions.isEmpty { p.phase = .converged }
            }
        }
        return p
    }

    /// Keys of units under a transient reveal are invisible to the planner: it neither hides nor orders them.
    func withoutTransient(_ obs: ObservedOrder) -> ObservedOrder {
        guard !transientReveals.isEmpty else { return obs }
        var o = obs
        o.onBar = obs.onBar.filter { transientReveals[rule.unit(of: $0)] == nil }
        o.parked = obs.parked.filter { transientReveals[rule.unit(of: $0)] == nil }
        return o
    }

    // MARK: Transient reveal (a hold)

    /// Marks `unit` as deliberately on the bar for up to `timeout`: passes leave it alone and `perItem` shows it as
    /// `.pending` ("revealed from the overflow panel"). Returns false when the unit is already held. Expires by itself.
    @discardableResult
    public func beginTransientReveal(_ unit: HideUnit, timeout: Duration = .seconds(60)) async -> Bool {
        guard transientReveals[unit] == nil else { return false }
        nextHoldToken += 1
        let token = nextHoldToken
        transientReveals[unit] = token
        log("hold: \(unit) revealed from the overflow panel (timeout \(timeout))")
        let keys = itemInfo.keys.filter { rule.unit(of: $0) == unit }
        await publish { s in for k in keys { s.perItem[k] = .pending } }
        Task { [weak self] in
            try? await Task.sleep(for: timeout)   // wall clock on purpose: the injected `sleep` is a test seam for pacing
            await self?.expireTransientReveal(unit, token: token)
        }
        return true
    }

    public func endTransientReveal(_ unit: HideUnit) async {
        guard transientReveals.removeValue(forKey: unit) != nil else { return }
        log("hold: \(unit) released; reconciling")
        let keys = itemInfo.keys.filter { rule.unit(of: $0) == unit }
        await publish { s in for k in keys where s.perItem[k] == .pending { s.perItem[k] = .inPlace } }
        requestReconcile(supersede: true, reason: "transient reveal ended")
    }

    /// Publishes (or clears) the poll's suppression notice for the Arrange status line (gdu.58).
    public func setPollSuppression(_ s: PollSuppression?) async { await publish { $0.pollSuppression = s } }

    /// What the poll (`EngineTriggers`) needs to decide whether it may run now (e7t).
    public func pollGate() -> PollGate {
        PollGate(busy: inPass || pending || requestedAt != nil || delayed.keys.contains { $0 != Self.unsettledReason } || sleeping || !loaded,
                 holdActive: !transientReveals.isEmpty, userActions: userActions,
                 secondsSinceUserAction: userActionAt.map { Double($0.duration(to: .now).components.seconds) + Double($0.duration(to: .now).components.attoseconds) / 1e18 }, engineSignature: pollSignature, engineSignatureSerial: pollSignatureSerial)
    }

    public func isTransientlyRevealed(_ unit: HideUnit) -> Bool { transientReveals[unit] != nil }

    private func expireTransientReveal(_ unit: HideUnit, token: Int) async {
        guard transientReveals[unit] == token else { return }
        log("hold: \(unit) expired")
        await endTransientReveal(unit)
    }

    /// Start-of-pass bookkeeping: drops state of vanished keys, breaks strike streaks of keys that did not fail in the
    /// previous pass, and lets keys still below the strike limit be retried (keys at the limit stay suppressed).
    private func pruneFailures(_ obs: ObservedOrder) {
        let present = Set(obs.onBar + obs.parked)
        failures = failures.filter { present.contains($0.key) }
        strikes = strikes.filter { present.contains($0.key) }
        let previous = failedThisPass
        failedThisPass = []
        overflowRefused = [:]
        cutThisPass = false
        let limit = config.maxKeyFailures
        for (k, n) in strikes where n < limit && !previous.contains(k) { strikes[k] = nil }
        for k in Array(failures.keys) where (strikes[k] ?? 0) < limit { failures[k] = nil }
    }

    /// Records an actuation failure of `key` in this pass (one strike per pass); logs once when the key reaches the limit.
    private func markFailed(_ key: ItemKey, _ e: ActuationError, fullStrike: Bool = false) {
        failures[key] = e
        guard failedThisPass.insert(key).inserted else { return }
        // A hide/show that ended in an agent respawn costs ONE respawn per key per layout change: strike out at once.
        let n = fullStrike ? config.maxKeyFailures : (strikes[key] ?? 0) + 1
        strikes[key] = n
        if n == config.maxKeyFailures {
            log(fullStrike ? "\(key) failed after an agent respawn (\(e)); marked failed until the layout changes or Retry"
                           : "\(key) failed \(n) passes in a row (\(e)); marked failed until the layout changes or Retry")
        }
    }

    private var hasRetryableFailure: Bool { failures.keys.contains { (strikes[$0] ?? 0) < config.maxKeyFailures } }

    /// A failed key whose placement a settled observation finds realized (and that the plan does not touch) is no longer failed:
    /// a wrong earlier verdict, or something else fixed it (gdu.48). A failure recorded in THIS pass stays until a later pass. `.unsupported` is derived afresh every pass anyway.
    private func clearFailuresInPlace(_ obs: ObservedOrder, _ plan: Plan) {
        let acting = Set(plan.actions.map(Self.key(of:)))
        for k in Array(failures.keys) where !acting.contains(k) && !failedThisPass.contains(k) && transientReveals[rule.unit(of: k)] == nil
            && (obs.onBar.contains(k) || obs.parked.contains(k))
            && ArrangeSections.placementMatches(k, layout: layout, observed: obs, showHiddenSection: showHidden, showAlwaysHidden: showAlways) {
            failures[k] = nil; strikes[k] = nil
            log("cleared failure for \(k): now in place")
        }
    }

    private func statuses(_ obs: ObservedOrder, _ plan: Plan) -> [ItemKey: ItemStatus] {
        clearFailuresInPlace(obs, plan)
        var out: [ItemKey: ItemStatus] = [:]
        for k in obs.onBar + obs.parked { out[k] = obs.systemOverflow.contains(k) ? .notFitting : .inPlace }
        for a in plan.actions { out[Self.key(of: a)] = .pending }
        for k in obs.onBar + obs.parked where transientReveals[rule.unit(of: k)] != nil { out[k] = .pending }
        var waiting = Set<ItemKey>()
        let now = ContinuousClock.now
        for s in plan.skipped where failures[s.key] == nil && out[s.key] != .notFitting {
            if s.reason == Reconciler.uncorroboratedSkipReason {   // gdu.105: transient, see positionWaitTimeout
                let since = positionWaitSince[s.key] ?? now
                positionWaitSince[s.key] = since
                waiting.insert(s.key)
                if since.duration(to: now) > config.positionWaitTimeout {
                    if positionTimedOut.insert(s.key).inserted { log("\(s.key): position not corroborated for \(config.positionWaitTimeout); marked unsupported until the layout changes or Retry") }
                    out[s.key] = .unsupported("could not corroborate its position on the bar for \(Self.seconds(config.positionWaitTimeout)) s: " + s.reason)
                } else {
                    out[s.key] = .waitingForPosition(s.reason)
                }
            } else {
                out[s.key] = .unsupported(s.reason)
            }
        }
        for k in Array(positionWaitSince.keys) where !waiting.contains(k) { positionWaitSince[k] = nil; positionTimedOut.remove(k) }
        if positionWaitSince.count > positionTimedOut.count {
            if delayed[Self.positionRetryReason] == nil {
                let delay = Self.positionRetryDelay(attempt: positionRetryAttempts, config: config)
                positionRetryAttempts += 1
                log("position of \(positionWaitSince.count - positionTimedOut.count) item(s) not corroborated; re-planning in \(delay)")
                scheduleReconcile(after: delay, reason: Self.positionRetryReason)
            }
        } else {
            positionRetryAttempts = 0
            delayed[Self.positionRetryReason]?.cancel(); delayed[Self.positionRetryReason] = nil
        }
        for (k, e) in failures where out[k] != nil { out[k] = .failed(e) }
        return out
    }

    static func positionRetryDelay(attempt: Int, config: Config) -> Duration {
        min(config.positionRetryBase * (1 << min(attempt, 12)), config.positionRetryCap)
    }

    private static func seconds(_ d: Duration) -> Int { Int(d.components.seconds) }

    static func describe(_ plan: Plan) -> String {
        func d(_ a: PlannedAction) -> String {
            switch a {
            case .hide(let k): return "hide \(k)"
            case .show(let k): return "show \(k)"
            case .move(let k, let r):
                switch r {
                case .before(let t): return "move \(k) before \(t)"
                case .after(let t): return "move \(k) after \(t)"
                case .leftmost: return "move \(k) leftmost"
                case .rightmost: return "move \(k) rightmost"
                }
            }
        }
        var out = "plan: phase=\(plan.phase) actions=\(plan.actions.count) skipped=\(plan.skipped.count)"
        for (i, a) in plan.actions.prefix(10).enumerated() { out += "\n  \(i + 1). \(d(a))" }
        if plan.actions.count > 10 { out += "\n  ... \(plan.actions.count - 10) more" }
        return out
    }

    private static func key(of a: PlannedAction) -> ItemKey {
        switch a { case .move(let k, _), .hide(let k), .show(let k): return k }
    }

    private func publishObserved(_ obs: ObservedOrder, _ plan: Plan? = nil) async {
        let st = plan.map { statuses(obs, $0) }
        let info = itemInfo
        hasObservation = true
        let pc = Set(unconfirmed.keys)
        let hu = rule
        await publish { s in s.observed = obs; s.items = info; s.hideUnits = hu; s.observationSettled = true; s.pendingConfirmation = pc; if let st { s.perItem = st } }
    }

    private func setStatus(_ k: ItemKey, _ st: ItemStatus, inFlight: PlannedAction?) async {
        await publish { s in s.perItem[k] = st; s.inFlight = inFlight }
    }

    private func finish(_ report: PassReport, converged: Bool) async -> PassReport {
        let now = Date()
        // Observed reveal state, only from a pass that completed its work (converged or incomplete) and from what it observed.
        let judge = report.outcome == .converged || report.outcome == .incomplete
        let lay = layout, wantHidden = showHidden, wantAlways = showAlways
        await publish { s in
            s.inFlight = nil; s.lastPassAt = now; s.passCount += 1; s.passSequence += 1; s.isConverged = converged
            if judge {
                let onBar = Set(s.observed.onBar)
                let usable: (ItemKey) -> Bool = { k in
                    switch s.perItem[k] { case .failed?, .unsupported?, .waitingForPosition?: return false; default: return true }
                }
                let anyShown: Bool
                if wantHidden || wantAlways {
                    var wanted: [ItemKey] = []
                    if wantHidden { wanted += lay.hidden }
                    if wantAlways { wanted += lay.alwaysHidden }
                    anyShown = wanted.contains { onBar.contains($0) && usable($0) }
                } else {
                    anyShown = (lay.hidden + lay.alwaysHidden).contains { onBar.contains($0) && usable($0) }
                }
                s.revealedObserved = anyShown
            }
        }
        if converged, !unsettledKeys.isEmpty { await clearUnsettled() }   // gdu.78
        // A key that failed fewer than `maxKeyFailures` passes in a row is retried by one more pass (bounded by the strikes).
        if !converged, draining, !pending, !stopped, !cutThisPass, chained < config.maxChainedPasses, hasRetryableFailure { chained += 1; pending = true }
        return report
    }

    /// `allowUnsettled`: accept the latest complete read although two scans did not agree (the pass shows it, never acts on it).
    private func observeOnce(allowUnsettled: Bool = false, provisional: Bool = false, seed: ObservationSeed? = nil) async -> Result<(ObservedOrder, Bool), ObserveError> {
        var progress: (@Sendable ([ResolvedItem]) -> Void)?
        if provisional {
            progress = { @Sendable [weak self] items in
                Task { await self?.publishProvisional(items) }
            }
        }
        do {
            let r = try await observer.observeDetailed(progress: progress, seed: seed)
            let o = ObservedOrder(resolved: r.items)
            if o.onBar.isEmpty { return .failure(.empty) }
            if !r.settled, !allowUnsettled { return .failure(.noAgreement(scans: r.scans)) }
            observedCompleteness = r.completeness
            lastObserveScans = r.scans
            let serialBefore = pollSignatureSerial
            if r.settled { notePollSignature(r.items) }
            if r.settled, r.completeness.membershipUsable { noteAdopted(r.items, r.completeness, serialBefore: serialBefore) }
            assumedKeys = Set(r.items.filter { $0.item.hiddenReason == .assumedNotHosted }.map(\.key))
            if r.settled, r.completeness == .complete {
                // A settled complete read confirms a pending hide when the unit is off the bar by evidence (not by assumption),
                // a pending show when it is on the bar.
                let done = unconfirmed.filter { k, hide in hide ? (o.parked.contains(k) && !assumedKeys.contains(k)) : o.onBar.contains(k) }.map(\.key)
                if !done.isEmpty {
                    for k in done { unconfirmed[k] = nil }
                    log("confirmed by a settled complete read: \(done.map(\.description).sorted().joined(separator: ", "))")
                }
            }
            itemInfo = ItemInfo.merge(previous: itemInfo, fresh: ItemInfo.index(from: r.items), retaining: ItemInfo.staleOnlyKeys(from: r.items))
            noteEvidence(r.items)
            return .success((o, r.settled))
        } catch let e as ObserveError {
            return .failure(e)
        } catch {
            return .failure(.noAgreement(scans: 0))
        }
    }

    /// The first complete scan of a pass, published before agreement so the Arrange window has a bar to show. Only when
    /// nothing has been observed yet; never replaces a settled observation.
    public func showProvisional(_ items: [ResolvedItem]) async { await publishProvisional(items) }

    private func publishProvisional(_ items: [ResolvedItem]) async {
        guard !hasObservation else { return }
        let o = ObservedOrder(resolved: items)
        guard !o.onBar.isEmpty else { return }
        hasObservation = true
        itemInfo = ItemInfo.merge(previous: itemInfo, fresh: ItemInfo.index(from: items), retaining: ItemInfo.staleOnlyKeys(from: items))
        noteEvidence(items)
        let info = itemInfo
        log("first observation published (provisional, unsettled)")
        let hu = rule
        await publish { s in s.observed = o; s.items = info; s.hideUnits = hu; s.observationSettled = false }
    }

    /// Updates `obs` from an actuation result; false when no trustworthy observation could be obtained.
    private func adopt(_ snap: MenuBarSnapshot?, into obs: inout ObservedOrder) async -> Bool {
        if await foreignAgentChange() { return false }
        if let why = snap?.trackedStoreProblem {   // gdu.87: a read without the store proves nothing about hidden/visible
            let m = ObserveError.trackedStoreMessage(why)
            await publish { $0.lastError = .observe(m) }
            scheduleStoreRetry()
            return false
        }
        if let snap {
            let resolved = resolveSnapshot(snap)
            let o = ObservedOrder(resolved: resolved)
            if !o.onBar.isEmpty {
                itemInfo = ItemInfo.merge(previous: itemInfo, fresh: ItemInfo.index(from: resolved), retaining: ItemInfo.staleOnlyKeys(from: resolved))
                noteEvidence(resolved)
                let serialBefore = pollSignatureSerial
                notePollSignature(resolved)
                if snap.completeness.membershipUsable { noteAdopted(resolved, snap.completeness, serialBefore: serialBefore) }
                obs = o; return true
            }
        }
        switch await observeOnce() {
        case .success(let (o, _)): obs = o; return true
        case .failure(let e):
            if e == .permissionDenied { stopped = true; await publish { $0.lastError = .permissionDenied } }
            else { let m = e.description; await publish { $0.lastError = .observe(m) } }
            return false
        }
    }

    /// gdu.71: the last adopted observation as a seed, when reuse applies: enabled, recent, usable read level, no agent restart
    /// pending. Safe because that observation already passed the agreement rule (or was a verified post-write read) and a fresh
    /// scan must still agree with it; the writes that follow are verified exactly as before.
    private func reusableSeed() -> ObservationSeed? {
        guard config.userPassReuseWindow > .zero, let a = lastAdopted, a.completeness.membershipUsable,
              notReadyUntil == nil, !foreignRestartInPass,
              a.at.duration(to: .now) <= (lastAdoptedPolled ? config.polledSeedReuseWindow : config.userPassReuseWindow) else { return nil }
        return ObservationSeed(items: a.items, completeness: a.completeness)
    }

    private enum PassObservation { case settled(ObservedOrder), end(PassReport) }

    /// Observes for a pass. Unsettled and failed observations end the pass here (published, nothing planned).
    private func observeForPass(seed: ObservationSeed? = nil) async -> PassObservation {
        let provisional = !hasObservation
        let task = Task { await self.observeOnce(allowUnsettled: true, provisional: provisional, seed: seed) }
        observeTask = task
        let t0 = ContinuousClock.now
        let result = await task.value
        observeTask = nil
        let took = Self.ms(t0.duration(to: .now))
        switch result {
        case .success(let (o, settled)):
            if settled {
                let reused = seed != nil && lastObserveScans == 1
                log("observe=\(took) ms scans=\(lastObserveScans) reuse=\(reused ? "yes" : "no")\(seed != nil && !reused ? " (adopted observation offered, the fresh scan disagreed)" : "")")
                await publish { s in s.lastObserveMillis = took; s.lastObserveReused = reused }
                return .settled(o)
            }
            hasObservation = true
            let info = itemInfo
            log("observation unsettled; not actuating (\(took) ms)")
            let hu = rule
            await publish { s in
                s.observed = o; s.items = info; s.hideUnits = hu; s.observationSettled = false
                if case .observe? = s.lastError { s.lastError = nil }
            }
            if draining { pending = true }
            let r = PassReport(outcome: .unsettled)
            _ = await finish(r, converged: false)
            return .end(r)
        case .failure(let e):
            if e == .superseded {
                log("observation abandoned after \(took) ms for a newer request")
                return .end(await endSuperseded(PassReport(outcome: .superseded)))
            }
            if e == .permissionDenied {
                stopped = true
                pending = false
                await publish { $0.lastError = .permissionDenied }
                _ = await finish(PassReport(outcome: .permissionDenied), converged: false)
                return .end(PassReport(outcome: .permissionDenied))
            }
            let msg = e.description
            await publish { $0.lastError = .observe(msg) }
            if case .trackedStoreUnreadable = e { scheduleStoreRetry() }
            _ = await finish(PassReport(outcome: .observeFailed), converged: false)
            return .end(PassReport(outcome: .observeFailed))
        }
    }

    /// A conflicting manager was detected during the pass: end it before the next actuator call. Not a failure: no strike,
    /// no suppression, `perItem` statuses stay as published (pending, never `.failed`).
    private func pausedMidPass(_ r: PassReport) async -> PassReport {
        log("conflicting manager running (\(conflictBox.value ?? "?")); pass ends before the next actuator call")
        pending = false
        await publish { $0.inFlight = nil }
        return await finish(r, converged: false)
    }

    /// Ends a pass whose plan a newer request made stale (gdu.47): nothing is recorded as a failure, no strikes, the next pass
    /// plans from the NEW layout and a fresh full scan. While a `setLayout` coalescing window is open its timer starts that pass.
    private func endSuperseded(_ r: PassReport) async -> PassReport {
        log("pass superseded by \(supersedeReason)")
        await publish { $0.inFlight = nil }
        if draining, delayed["setLayout"] == nil { pending = true }
        return await finish(r, converged: false)
    }

    private func runPass(scheduled: Bool) async -> PassReport {
        passAgent = agentPID()
        foreignRestartInPass = false
        let r = await runPassBody(scheduled: scheduled)
        if foreignRestartInPass {
            foreignRestartInPass = false
            return PassReport(outcome: .agentRestarted, phase: r.phase, actionCount: r.actionCount)
        }
        return r
    }

    /// True (once per pass) when MenuBarAgent was respawned by someone else since the pass started: observations of the new
    /// agent are discarded, nothing more is actuated, and a reconcile follows the not-ready window. Our own respawn re-bases.
    private func foreignAgentChange() async -> Bool {
        if foreignRestartInPass { return true }
        guard let start = passAgent, let cur = agentPID(), cur != start else { return false }
        if isOwnAgentPID(cur) { passAgent = cur; return false }
        log("agent restarted during the pass: pid \(start) -> \(cur); discarding its observations")
        foreignRestartInPass = true
        await agentRestarted()
        return true
    }

    private func runPassBody(scheduled: Bool) async -> PassReport {
        inPass = true
        defer { inPass = false }
        let generation = layoutGeneration
        lastStart = .now
        var actionCount = 0
        await publish { $0.passesStarted += 1; if $0.orderNotAppliedNotice != nil { $0.orderNotAppliedNotice = nil }; $0.orderMoveNotice = nil; $0.orderMoveReasons = [:] }

        var userPass = false
        if let r = requestedAt {
            requestedAt = nil
            userPass = requestUserInitiated
            requestUserInitiated = false
            let ms = Self.ms(r.duration(to: .now))
            log("pass started \(ms) ms after \(requestReason)")
            if ms > 2000 {
                log("pass delayed: \(requestedDuringPass ? "a pass was already running when the request arrived" : "scheduling (min interval or busy wait)") \(ms) ms")
            }
        }

        // (a) observe. Observation moves nothing, so it proceeds even while the user is busy; only actuation waits.
        var obs: ObservedOrder
        switch await observeForPass(seed: userPass ? reusableSeed() : nil) {
        case .settled(let o): obs = o
        case .end(let r): return r
        }

        // (b) busy pause (actuation only; unchanged semantics). A wait makes the observation old, so it is repeated.
        if busy() {
            var waited = Duration.zero
            let t0 = ContinuousClock.now
            while busy(), waited < config.busyWait {
                await sleep(config.busyPoll)
                waited += config.busyPoll
            }
            noteDelay("user busy", since: t0)
            if busy() {
                if scheduled, !busyRetried { busyRetried = true; pending = true }
                log("user is busy; pass skipped")
                await publish { $0.passSequence += 1 }
                return PassReport(outcome: .skippedBusy)
            }
            switch await observeForPass() {
            case .settled(let o): obs = o
            case .end(let r): return r
            }
        }
        busyRetried = false

        if await foreignAgentChange() {
            let r = PassReport(outcome: .agentRestarted)
            _ = await finish(r, converged: false)
            return r
        }

        // (b2) not ready: asleep, or MenuBarAgent respawned moments ago (its first scans are empty or incomplete, and even an
        // agreed read can lack items). Nothing is planned or done from such an observation; the delayed reconcile follows.
        if sleeping {
            log("system is going to sleep; pass skipped")
            let r = PassReport(outcome: .incomplete)
            _ = await finish(r, converged: false)
            return r
        }
        if conflicted {
            log("conflicting manager running; pass skipped")
            let r = PassReport(outcome: .paused)
            _ = await finish(r, converged: false)
            return r
        }
        if let until = notReadyUntil {
            if .now < until {
                log("agent restarted moments ago; not acting on this observation")
                let r = PassReport(outcome: .unsettled)
                _ = await finish(r, converged: false)
                return r
            }
            notReadyUntil = nil
        }

        if generation != layoutGeneration { return await endSuperseded(PassReport(outcome: .superseded)) }   // the layout changed during observation
        await publish { if case .observe? = $0.lastError { $0.lastError = nil } }
        storeRetryAttempts = 0
        delayed[Self.storeRetryReason]?.cancel(); delayed[Self.storeRetryReason] = nil
        pruneFailures(obs)

        // (c) plan
        var plan = makePlan(obs)

        // (d) persist new items, once per pass
        if !plan.newItems.isEmpty {
            for n in plan.newItems { layout.append(n.key, to: n.section) }
            await noteNewItems(plan.newItems)
            do { try store.save(layout) } catch { log("cannot save layout: \(error)") }
            let stamp = await publishLayout(layout)   // a new revision: the engine itself changed the layout (gdu.48)
            for n in plan.newItems {
                guard let sec = layout.section(of: n.key), let i = layout.keys(in: sec).firstIndex(of: n.key) else { continue }
                engineAdditions.append((stamp.revision, n.key, sec, i))
            }
            if engineAdditions.count > Self.maxEngineAdditions { engineAdditions.removeFirst(engineAdditions.count - Self.maxEngineAdditions) }
            plan = makePlan(obs)
        }
        log(Self.describe(plan))
        await publishObserved(obs, plan)   // (e) skipped -> unsupported inside statuses()

        var phaseReached = plan.phase
        var consecutiveFailures = 0
        func report(_ o: PassReport.Outcome) -> PassReport { PassReport(outcome: o, phase: phaseReached, actionCount: actionCount) }

        func isConverged() -> Bool { failures.isEmpty }

        // (e2) ORDER actuation that involves a self-positioning owner (a move's relation target) waits for a COMPLETE
        // read: with their items stale, their frames and slots are not trusted (gdu.51). Membership is not affected.
        if plan.phase == .order, observedCompleteness != .complete {
            let owners = config.selfPositioningOwners
            // Only the relation TARGET can be a self-positioning item: the planner never moves one (they are anchors, gdu.33).
            let involved = plan.actions.contains { a in
                guard case .move(_, let rel) = a else { return false }
                switch rel {
                case .before(let t), .after(let t): return SelfPositioning.isSelfPositioning(t, owners: owners)
                case .leftmost, .rightmost: return false
                }
            }
            if involved {
                log("engine: order actuation involves a self-positioning owner and the read is \(observedCompleteness.rawValue); waiting for a complete read")
                if draining { pending = true }
                let r = PassReport(outcome: .unsettled)
                _ = await finish(r, converged: false)
                return r
            }
        }

        // (f)
        if plan.phase == .converged {
            chained = 0; allFailedStreak = 0
            let ok = isConverged()
            if ok { _ = await normalizeAroundSelfPositioning(obs, generation: generation) }
            _ = await finish(report(ok ? .converged : .incomplete), converged: ok)
            return report(ok ? .converged : .incomplete)
        }

        func abort(_ o: PassReport.Outcome) async -> PassReport {
            let r = report(o)
            return await finish(r, converged: false)
        }

        // (f2) gdu.80: on a full bar (a chevron) the order phase needs a settled overflow set; a reveal never orders.
        if plan.phase == .order, let r = await fullBarOrderGate(obs: obs, wroteMembership: false, fullBefore: false, actionCount: actionCount, phase: phaseReached) { return r }

        // (g) membership phase
        if plan.phase == .membership {
            let caps = effectiveCaps()
            var batch: [ItemKey: Bool] = [:]
            var order: [ItemKey] = []
            var noEntry: [ItemKey] = []
            for a in plan.actions {
                switch a {
                case .hide(let k):
                    guard caps(k).canHide else { log("engine: refusing hide of \(k): capability forbids"); continue }
                    batch[k] = true; order.append(k)
                case .show(let k):
                    // gdu.114: a show of a key with no Control Center entry writes nothing; refuse it and withhold it from the planner.
                    if resolverSnapshot != nil, resolverSnapshot?.trackedKey(for: k, bundleID: itemInfo[k]?.ownerBundleID) == nil {
                        log("engine: refusing show of \(k): no Control Center entry")
                        actuatorRefused[k] = Self.noEntrySkipReason; refusedEpoch[k] = snapshotEpoch
                        noEntry.append(k)
                        continue
                    }
                    batch[k] = false; order.append(k)
                case .move: break
                }
            }
            if !noEntry.isEmpty { await publish { [noEntry] s in for k in noEntry { s.perItem[k] = .unsupported(Self.noEntrySkipReason) } } }
            guard let first = order.first else { return await abort(.incomplete) }
            let fullBefore = obs.overflowChevron != nil
            if conflicted { return await pausedMidPass(report(.paused)) }
            let firstAction: PlannedAction = batch[first] == true ? .hide(first) : .show(first)
            await publish { s in for k in order { s.perItem[k] = .pending }; s.inFlight = firstAction }
            // The actuator computes its expectations and `before` map from ITS OWN scan taken right before the write; the engine
            // passes only the keys and directions, never a snapshot, so a stale engine observation cannot leak into the verdict.
            log("membership batch: \(batch.count) key(s); the actuator verifies against its own pre-write scan")
            for k in order {
                let tk = resolverSnapshot?.trackedKey(for: k, bundleID: itemInfo[k]?.ownerBundleID)
                let flag = tk.flatMap { config.trackedAllowed($0) }
                log("membership write: \(batch[k] == true ? "hide" : "show") \(k); layout=\(layout.section(of: k)?.rawValue ?? "none") userPlaced=\(userPlacedVisible.contains(k)); Control Center \(tk ?? "no entry") isAllowed=\(flag.map(String.init(describing:)) ?? "?"); \(evidence[k] ?? "no scan evidence")")
            }
            let result = await actuator.applyHiddenBatch(batch)
            actionCount += 1
            var err: ActuationError?
            var snap: MenuBarSnapshot?
            switch result {
            case .verified(let s): snap = s
            case .failed(let e, let s): err = e; snap = s
            }
            let respawned = await actuator.lastBatchRespawned
            // gdu.72: units the actuator refused before the write are skips (neutral `.unsupported`), not failures: no strike, no
            // batchFailed, not retried. When every unit was refused the batch result is only that refusal and is dropped.
            let refusedNow = (await actuator.lastBatchRefused).filter { batch[$0.key] != nil }
            if !refusedNow.isEmpty {
                for (k, why) in refusedNow { actuatorRefused[k] = why; refusedEpoch[k] = snapshotEpoch }
                log("engine: actuator refused \(refusedNow.count) unit(s) (skipped, not failures): " + refusedNow.sorted { $0.key.description < $1.key.description }.map { "\($0.key): \($0.value)" }.joined(separator: "; "))
                if refusedNow.count == batch.count { err = nil }
            }
            // gdu.76: units left alone because a member was stale are TRANSIENT: no actuatorRefused entry, no strike, they stay
            // pending and the next pass plans them again (the planner requests the member once it is fresh).
            let unsettledNow = (await actuator.lastBatchUnsettled).filter { batch[$0.key] != nil }
            if !unsettledNow.isEmpty {
                log("engine: actuator left \(unsettledNow.count) unit(s) pending (not failures, not refused): " + unsettledNow.sorted { $0.key.description < $1.key.description }.map { "\($0.key): \($0.value)" }.joined(separator: "; "))
                if refusedNow.count + unsettledNow.count == batch.count { err = nil }
            }
            // gdu.78: delayed retry with back-off (the poll ignores stale flags, so nothing else would notice the member settling).
            await noteUnsettled(Set(unsettledNow.keys), batch: Set(batch.keys))
            for k in batch.keys { unconfirmed[k] = nil }
            if err == nil {
                for k in await actuator.lastBatchUnconfirmed { if let hide = batch[k] { unconfirmed[k] = hide } }
                if !unconfirmed.isEmpty { log("applied per the Control Center store, confirmation pending: \(unconfirmed.keys.map(\.description).sorted().joined(separator: ", "))") }
            }
            if case .liveWriteFailed(let why)? = err { log("engine: live write failed (\(why)); no MenuBarAgent restart") }
            if respawned { passAgent = agentPID() }   // our own fallback respawn: the pass continues with the new agent
            if let e = err, await handleFatal(e) { return await abort(.stopped) }
            if generation != layoutGeneration {
                // A newer layout arrived while the batch ran. The batch stands on its own verification against the layout it was
                // planned from; it is NOT a failure for the new layout. Adopt what it observed, reset its keys to the new plan's
                // statuses, drop the rest of the stale plan, and let the next pass plan from the new layout and a fresh scan.
                if await adopt(snap, into: &obs) { await publishObserved(obs, makePlan(obs)) }
                else if foreignRestartInPass {
                    // MenuBarAgent was respawned by someone else: the gdu.21 outcome, not a plain supersede.
                    await publish { $0.inFlight = nil }
                    return await finish(report(.agentRestarted), converged: false)
                }
                log("batch finished (\(err.map { "\($0)" } ?? "verified")) after the layout changed; not judged against the new layout")
                return await endSuperseded(report(.superseded))
            }
            // A batch that reported anything other than success (userBusy and fatal errors aside) ends the pass.
            var driftErr: ActuationError?
            if let e = err, e != .userBusy { driftErr = e }
            guard await adopt(snap, into: &obs) else {
                if let e = driftErr { return await endAfterBatchDrift(e, obs: obs, report: report(.incomplete)) }
                return await abort(.observeFailed)
            }
            if err == .userBusy {
                // Same as a userBusy single action: not a failure, nothing struck or suppressed. Keys the batch verified keep
                // their status (they re-plan as in place); the remainder stays pending and the pass is rescheduled.
                log("membership batch refused: user is busy; pass rescheduled")
                consecutiveFailures += 1
                await publishObserved(obs, makePlan(obs))
                await publish { $0.inFlight = nil }
                if draining { pending = true }
                return await abort(.incomplete)
            }
            let after = makePlan(obs)
            log("re-plan after batch: " + Self.describe(after))
            phaseReached = after.phase
            if after.phase == .membership {
                let failErr = err ?? .notVerified(expected: "membership change", observed: "unchanged")
                // A key that still needs the SAME change failed. One that now needs the OPPOSITE change did not fail: its desired
                // state was changed while the batch ran (a reveal toggled, a layout edit), so the batch did what it was asked.
                var failedAny = false
                for a in after.actions {
                    let k = Self.key(of: a)
                    guard let wasHide = batch[k] else { continue }
                    if unsettledNow[k] != nil { continue }   // transient: neither a failure nor a strike
                    let nowHide: Bool
                    switch a { case .hide: nowHide = true; case .show: nowHide = false; case .move: continue }
                    if nowHide == wasHide, unconfirmed[k] != nil {
                        log("\(k): applied per the Control Center store, still unconfirmed by the read; not a failure")
                    } else if nowHide == wasHide {
                        var writeFailed = false
                        if case .liveWriteFailed? = err { writeFailed = true }
                        markFailed(k, failErr, fullStrike: respawned || writeFailed); failedAny = true
                    }
                    else { log("\(k): desired state changed while the batch ran; not a failure") }
                }
                if failedAny { consecutiveFailures += 1 }
            }
            plan = makePlan(obs)
            phaseReached = plan.phase
            await publishObserved(obs, plan)
            await publish { $0.inFlight = nil }
            if let e = driftErr { return await endAfterBatchDrift(e, obs: obs, report: report(.incomplete)) }
            if consecutiveFailures >= config.maxConsecutiveFailures { return await stopForFailures(report(.incomplete), obs: obs) }
            if plan.phase == .converged {
                let ok = isConverged()
                _ = await finish(report(ok ? .converged : .incomplete), converged: ok)
                return report(ok ? .converged : .incomplete)
            }
            guard plan.phase == .order else {
                // Still membership work (agent moved things): let the next pass handle it after it settles.
                return await rescheduleIncomplete(report(.incomplete), converged: false)
            }
            // gdu.80: the membership batch changed what fits: on a full bar the overflow pile just changed, so nothing is dragged
            // in this pass. A follow-up pass orders once two complete reads agree on the pile.
            if let r = await fullBarOrderGate(obs: obs, wroteMembership: true, fullBefore: fullBefore, actionCount: actionCount, phase: phaseReached) { return r }
        }

        // (h) order phase
        var lastAction: PlannedAction?
        while plan.phase == .order {
            // Every iteration re-plans from the CURRENT layout, so a setLayout that arrived during a drag is acted on at the
            // next iteration (the rest of the running drag cannot be taken back); log when that happens.
            if generation != layoutGeneration {
                log("layout changed during the order phase; dropping the rest of the stale plan")
                return await endSuperseded(report(.superseded))
            }
            if let r = requestedAt, requestedDuringPass {
                requestedAt = nil
                log("\(requestReason) picked up by the running pass at its next re-plan, \(Self.ms(r.duration(to: .now))) ms after the request")
            }
            if consecutiveFailures >= config.maxConsecutiveFailures { return await stopForFailures(report(.incomplete), obs: obs) }
            if conflicted { return await pausedMidPass(report(.paused)) }
            if sleeping {
                log("system is going to sleep; pass ends after the action in flight")
                await publish { $0.inFlight = nil }
                return await abort(.incomplete)
            }
            guard actionCount < config.maxActionsPerPass else {
                log("maxActionsPerPass reached")
                return await rescheduleIncomplete(report(.incomplete), converged: false)
            }
            guard let action = plan.actions.first, case .move(let key, let rel) = action else { break }
            if !layout.enforcesOrder {   // 8z5.2: deterministic, never reached (the planner got an empty placed set)
                log("engine: refusing move of \(key): macOS owns the order")
                plan.actions = []; plan.phase = .converged
                break
            }
            if !effectiveCaps()(key).canMove {
                log("engine: refusing move of \(key): capability forbids")
                failures[key] = .unsupportedItem(reason: "capability forbids")
                failedThisPass.insert(key); strikes[key] = config.maxKeyFailures   // deterministic: no retry
                plan = makePlan(obs)
                continue
            }
            if lastAction == action {
                // Verified last time yet still planned: the actuator's verdict and our observation disagree.
                markFailed(key, .notVerified(expected: "\(rel)", observed: "unchanged"))
                consecutiveFailures += 1
                await publishObserved(obs, makePlan(obs))
                plan = makePlan(obs)
                phaseReached = plan.phase
                lastAction = nil
                continue
            }
            lastAction = action
            do {   // gdu.89: say why this drag happens (status line, row tooltip, log)
                func name(_ k: ItemKey) -> String { itemInfo[k].map(OverflowEntries.displayName) ?? k.description }
                var target: ItemKey?
                switch rel { case .before(let t), .after(let t): target = t; default: break }
                let text = OrderMoveNotice.text(name: name(key), relation: rel, target: target.map(name))
                switch rel {
                case .after(let t): log("order: moving \(key) after \(t) (user placement)")
                case .before(let t): log("order: moving \(key) before \(t) (user placement)")
                case .leftmost: log("order: moving \(key) to the left end (user placement)")
                case .rightmost: log("order: moving \(key) to the right end (user placement)")
                }
                log("order: why: \(text); observed around \(key): \(DropTrace.around(key, in: obs.onBar))")   // gdu.102
                await publish { $0.orderMoveNotice = text; $0.orderMoveReasons[key] = text }
            }
            log("engine: move subject evidence: \(evidence[key] ?? "none")")   // gdu.94
            await setStatus(key, .moving, inFlight: action)
            await actuator.setChurnZone(SystemOverflowRule.churnZone(recentReads))
            let result = await actuator.move(key, relation: rel)
            actionCount += 1
            switch result {
            case .verified(let snap):
                consecutiveFailures = 0; allFailedStreak = 0
                guard await adopt(snap, into: &obs) else { return await abort(.observeFailed) }
            case .failed(let e, let snap):
                consecutiveFailures += 1
                if await handleFatal(e) { return await abort(.stopped) }
                if e == .userBusy {
                    _ = await adopt(snap, into: &obs)
                    await publishObserved(obs, makePlan(obs))
                    if draining { pending = true }
                    return await abort(.incomplete)
                }
                if e.isOverflowRefusal {
                    // gdu.69: refused before any drag; the item did not fail. A skip, not a strike.
                    consecutiveFailures -= 1
                    if overflowRefused[key] == nil { log("\(key): move skipped, in the system overflow area (\(e)); not a failure") }
                    overflowRefused[key] = Reconciler.overflowSkipReason
                } else { markFailed(key, e) }
                guard await adopt(snap, into: &obs) else { return await abort(.observeFailed) }
            }
            plan = makePlan(obs)
            phaseReached = plan.phase
            await publishObserved(obs, plan)
            if consecutiveFailures >= config.maxConsecutiveFailures { return await stopForFailures(report(.incomplete), obs: obs) }
        }
        await publish { $0.inFlight = nil; $0.orderMoveNotice = nil; $0.orderMoveReasons = [:] }
        if plan.phase == .converged {
            chained = 0; allFailedStreak = 0
            let ok = isConverged()
            if ok { _ = await normalizeAroundSelfPositioning(obs, generation: generation) }
            _ = await finish(report(ok ? .converged : .incomplete), converged: ok)
            return report(ok ? .converged : .incomplete)
        }
        return await abort(.incomplete)
    }

    /// gdu.80: decides whether an ORDER plan may be acted on a full bar. Returns the pass report when the pass must end here:
    ///  - reveal pass (showHidden/showAlways): membership only, never a drag; the differing order is surfaced as a notice
    ///  - membership was written this pass: order deferred; a follow-up pass orders after the bar has settled
    ///  - the last two complete reads disagree on the overflow set: order deferred until they agree
    /// nil: proceed (no chevron, or the pile is settled and nothing was written).
    private func fullBarOrderGate(obs: ObservedOrder, wroteMembership: Bool, fullBefore: Bool, actionCount: Int, phase: PlanPhase) async -> PassReport? {
        // Full now, full before the write (a re-hide can empty the pile and drop the chevron), or full in either of the last two reads.
        guard obs.overflowChevron != nil || (wroteMembership && fullBefore) || recentReads.suffix(2).contains(where: \.hasChevron) else { return nil }
        func end(_ o: PassReport.Outcome, converged: Bool, retry: Bool) async -> PassReport {
            let r = PassReport(outcome: o, phase: phase, actionCount: actionCount)
            if retry, draining, !stopped, chained < config.maxChainedPasses { chained += 1; pending = true }
            await publish { $0.inFlight = nil }
            return await finish(r, converged: converged)
        }
        if showHidden || showAlways {
            log("order not applied: bar is full (reveal pass: membership only, nothing is dragged)")
            let text = Self.orderNotAppliedText
            await publish { $0.orderNotAppliedNotice = text }
            return await end(.converged, converged: failures.isEmpty, retry: false)
        }
        if wroteMembership {
            log("order deferred: membership changed this pass")
            return await end(.incomplete, converged: false, retry: true)
        }
        if !SystemOverflowRule.overflowSettled(recentReads) {
            log("order deferred: overflow set unsettled")
            return await end(.unsettled, converged: false, retry: true)
        }
        return nil
    }
    static let orderNotAppliedText = "Order not applied: bar is full"

    /// gdu.67: a persisted layout that straddles a self-positioning item ([B, iStat, A] while the bar is [A, iStat, B]) is not
    /// reachable: the planner keeps iStat as an anchor and ends [B, A, iStat]. Once a pass has converged on a complete read, the
    /// layout is rewritten to the order the bar actually has around that item (it is moved in the layout, never on the bar), so
    /// the straddle does not re-trigger every pass. The moved self-positioning keys are recorded as `lastNormalization` (the
    /// Arrange status line says so). Returns true when the layout was rewritten.
    private func normalizeAroundSelfPositioning(_ obs: ObservedOrder, generation: Int) async -> Bool {
        guard generation == layoutGeneration, observedCompleteness == .complete, transientReveals.isEmpty, failures.isEmpty else { return false }
        let (new, moved) = layout.normalizedAroundSelfPositioning(observed: obs, owners: config.selfPositioningOwners)
        guard !moved.isEmpty else { return false }
        log("layout: straddled self-positioning item(s) \(moved.map(\.description).joined(separator: ", ")); the layout follows the bar around them")
        layout = new
        do { try store.save(new) } catch { log("cannot save layout: \(error)") }
        await publishLayout(new, normalized: moved)
        return true
    }

    /// Log line and a transient Arrange-window notice for unknown items placed by the new-item policy (no system notification).
    private func noteNewItems(_ items: [NewItem]) async {
        let named = items.map { n in (name: itemInfo[n.key].map(OverflowEntries.displayName) ?? n.key.description, section: n.section) }
        guard let text = NewItemNotice.text(named) else { return }
        log(text)
        noticeSerial += 1
        let serial = noticeSerial
        await publish { $0.newItemNotice = text }
        Task { [weak self] in
            try? await Task.sleep(for: NewItemNotice.lifetime)
            await self?.clearNotice(serial)
        }
    }

    private func clearNotice(_ serial: Int) async {
        guard serial == noticeSerial else { return }
        await publish { $0.newItemNotice = nil }
    }

    /// Permission and conflicting-manager errors stop the engine. Returns true when the pass must end.
    private func handleFatal(_ e: ActuationError) async -> Bool {
        switch e {
        case .permissionDenied:
            stopped = true; pending = false
            await publish { $0.lastError = .permissionDenied }
            return true
        case .conflictingManager(let m):
            stopped = true; pending = false
            await publish { $0.lastError = .conflictingManager(m) }
            return true
        default: return false
        }
    }

    /// Ends a pass after too many consecutive failed actions: leaves the rest pending, never chains. The failed keys were
    /// struck individually (`markFailed`); the engine itself reports `stoppedAfterFailures` only after
    /// `maxAllFailedPasses` such passes in a row (no action succeeded in between).
    private func stopForFailures(_ r: PassReport, obs: ObservedOrder) async -> PassReport {
        let n = config.maxConsecutiveFailures
        allFailedStreak += 1
        cutThisPass = true
        log("pass ended after \(n) consecutive failed actions (\(allFailedStreak) such pass(es) in a row)")
        pending = false
        chained = config.maxChainedPasses
        await publishObserved(obs, makePlan(obs))
        if allFailedStreak >= config.maxAllFailedPasses {
            log("stopped after \(allFailedStreak) passes in which every action failed")
            await publish { $0.lastError = .stoppedAfterFailures(n) }
        }
        return await finish(r, converged: false)
    }

    /// Ends a pass whose membership batch reported failure/drift: surfaces the error, never drags, never chains.
    /// The next requested or scheduled pass runs normally.
    private func endAfterBatchDrift(_ e: ActuationError, obs: ObservedOrder, report: PassReport) async -> PassReport {
        log("batch reported \(e); pass ended without order phase")
        chained = config.maxChainedPasses
        await publishObserved(obs, makePlan(obs))
        let err: EngineError
        if case .notVerified(let exp, let got) = e { err = .batchDrift(expected: exp, observed: got) }
        else { err = .batchFailed(ArrangeSections.describe(e)) }
        await publish { $0.lastError = err; $0.inFlight = nil }
        return await finish(report, converged: false)
    }

    /// Ends an incomplete pass that made progress; schedules one follow-up (bounded) so the order phase runs.
    private func rescheduleIncomplete(_ r: PassReport, converged: Bool) async -> PassReport {
        if draining, r.actionCount > 0, chained < config.maxChainedPasses, !stopped {
            chained += 1
            pending = true
        }
        return await finish(r, converged: converged)
    }
}

/// Snapshot of the engine's activity for the poll (e7t).
public struct PollGate: Sendable, Equatable {
    /// A pass is running or requested (pending/delayed), the engine sleeps or has no layout.
    public var busy: Bool
    public var holdActive: Bool
    /// Filled in by the caller from `EngineState` (the engine actor does not own them).
    public var passesStarted: Int
    public var observationSettled: Bool
    public var secondsSinceUserAction: Double?
    /// Count of explicit user-initiated requests so far (a change resets the poll's back-off).
    public var userActions: Int
    /// The engine's latest observed `BarSignature.forPoll` and its publication serial: the poll's reference after any pass.
    public var engineSignature: BarSignature.Value?
    public var engineSignatureSerial: Int
    public init(busy: Bool = false, holdActive: Bool = false, userActions: Int = 0, passesStarted: Int = 0, observationSettled: Bool = true,
                secondsSinceUserAction: Double? = nil, engineSignature: BarSignature.Value? = nil, engineSignatureSerial: Int = 0) {
        self.engineSignature = engineSignature; self.engineSignatureSerial = engineSignatureSerial
        self.busy = busy; self.holdActive = holdActive; self.passesStarted = passesStarted
        self.observationSettled = observationSettled; self.userActions = userActions
        self.secondsSinceUserAction = secondsSinceUserAction
    }
}

/// The poll hit `PollConfig.maxPollPassesPerMinute` and triggers nothing until `until` (gdu.58). Not an error.
public struct PollSuppression: Sendable, Equatable {
    public var until: Date
    public var keys: [ItemKey]
    public init(until: Date, keys: [ItemKey]) { self.until = until; self.keys = keys }
}

final class ConflictBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

extension Layout {
    /// gdu.67: moves each self-positioning key of `visible` that the layout places on the other side of a movable, drawn bar
    /// item than the bar does to the slot the bar has (before the first following on-bar key). Returns the keys moved.
    /// Overflowed keys, the chevron, modules and other self-positioning keys do not count.
    func normalizedAroundSelfPositioning(observed: ObservedOrder, owners: Set<String>) -> (Layout, moved: [ItemKey]) {
        let bar = observed.onBar
        let ignored = observed.systemOverflow.union(observed.overflowChevron.map { [$0] } ?? [])
        var l = self
        var moved: [ItemKey] = []
        for a in visible where SelfPositioning.isSelfPositioning(a, owners: owners) {
            guard let ab = bar.firstIndex(of: a), !ignored.contains(a), let ai = l.visible.firstIndex(of: a) else { continue }
            let straddles = l.visible.enumerated().contains { i, k in
                guard k != a, !SelfPositioning.isSelfPositioning(k, owners: owners), !ignored.contains(k), let kb = bar.firstIndex(of: k) else { return false }
                if case .module = k { return false }
                return (i < ai) != (kb < ab)
            }
            guard straddles else { continue }
            l.visible.remove(at: ai)
            let at = l.visible.firstIndex { k in !ignored.contains(k) && (bar.firstIndex(of: k).map { $0 > ab } ?? false) } ?? l.visible.count
            l.visible.insert(a, at: at)
            if l.visible != visible { moved.append(a) }
        }
        return (l, moved)
    }
}
