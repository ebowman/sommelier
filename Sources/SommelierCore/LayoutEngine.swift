import Foundation
import DecisionCore

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
        /// 9o9.3: order drags per pass (the safety envelope: one move, then a fresh observation on the chained pass).
        public var maxOrderMovesPerPass = 1
        public var busyWait: Duration = .seconds(3)
        /// A pass that ended `.paused` because the user is interacting is retried after this long.
        public var interactionRetry: Duration = .seconds(2)
        /// 9o9.8: the paused retry doubles per pause episode (2, 4, 8 ... s) up to this; also the fixed retry while locked / asleep.
        public var interactionRetryMax: Duration = .seconds(60)
        /// 9o9.8: a "a menu is open" reason that persists longer than this is ignored until it clears and reappears.
        public var menuOpenMaxWait: Duration = .seconds(120)
        /// An Arrange drag flag older than this is treated as lost (its "ended" event never came).
        public var arrangeDragMaxAge: Duration = .seconds(30)
        /// 9o9.7: after a hand Command-drag in the menu bar ends, the engine waits this long for a settled complete observation to adopt
        /// (it never enforces the old record meanwhile); at the limit it adopts the last settled complete observation taken since the drag.
        public var handDragAdoptWait: Duration = .seconds(10)
        /// How long the transient notices (new item, hand drag, System Settings adoption) stay up (tests shorten it).
        public var noticeLifetime: Duration = NewItemNotice.lifetime
        /// Wall clock for the attempt window and the per-minute cap (tests override it).
        public var now: @Sendable () -> Date = { Date() }
        /// 9o9.27: the monotonic clock behind the min pass interval and the agent-restart settle (tests drive it explicitly).
        public var instant: @Sendable () -> ContinuousClock.Instant = { .now }
        /// 9o9.27: how a scheduled reconcile (`scheduleReconcile`) waits out its delay (tests release it explicitly).
        public var delaySleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        public var busyPoll: Duration = .milliseconds(100)
        /// Consecutive self-rescheduled incomplete passes (membership then order) before the engine waits for an external trigger.
        public var maxChainedPasses = 2
        /// A pass stops (and does not chain) after this many consecutive failed actuator calls.
        public var maxConsecutiveFailures = 3
        /// The same key failing this many passes in a row is `.failed` until the layout changes or Retry.
        public var maxKeyFailures = 3
        /// Consecutive passes in which every action failed (each ended by `maxConsecutiveFailures`) before the engine reports `stoppedAfterFailures`.
        public var maxAllFailedPasses = 3
        /// Owners (iStat Menus) whose stale items do not block a pass (gdu.51: a move of or next to one is only actuated on a
        /// COMPLETE read). READ COMPLETENESS only (gdu.120): they are ordinary orderable items, not anchors.
        public var selfPositioningOwners: Set<String> = SelfPositioning.defaultOwners
        /// `setLayout` calls closer together than this are one request: only the last layout is planned (gdu.47). Zero = no window.
        public var layoutCoalesce: Duration = .milliseconds(300)
        /// gdu.136: after a user edit whose other pending order moves were deferred, the regular pass that performs them runs this long
        /// after the pass that announced them (the status line says "Done: X. Next: Y" meanwhile).
        public var userEditFollowUp: Duration = .seconds(3)
        /// gdu.144 D1: the bar counts as full from launch until three consecutive complete reads show no chevron. Production keeps this `true`; tests
        /// written for plain (chevron-less) bars start from "known not full" to keep their many-move scenarios.
        public var assumeFullBarAtLaunch = true
        /// ejb.15: record the audit trace of the core-driven order path (events, emitted actions, their results). TESTS ONLY.
        public var recordCoreTrace = false
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
    private let interaction: (any InteractionSource)?
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
    /// 9o9.3: the on-bar order of the last observation that was complete, settled and had no stale on-bar frame; what a drop made while
    /// the upgrade adoption is pending adopts first.
    private var lastCleanBar: [ItemKey]?
    private var lastPauseLogged: String?
    private var pausePublished = false
    /// 9o9.8: the retry delay of the current pause episode (nil = no episode), and the last one scheduled (diagnostics/tests).
    private var pauseRetry: Duration?
    private(set) var lastPauseRetryDelay: Duration?
    private var menuOpenSince: Date?
    private var menuLastSeen: Date?
    private var menuIgnored = false
    private nonisolated let userPausedBox = ConflictBox()
    private nonisolated let arrangeDragBox = ArrangeDragBox()
    /// 9o9.7: a hand Command-drag in the menu bar in progress, and the actuator calls in flight / started (the synthetic drags are ours).
    private nonisolated let handDragBox = HandDragBox()
    private nonisolated let flightBox = ActuatorFlightBox()
    /// A hand drag ended and its result is not adopted yet: the time the wait for a settled read ends (the wait itself never ends until one comes).
    private var handAdopt: Date?
    /// 9o9.18: when that hand drag ended (persisted as `Layout.pendingHandDrag` while the adoption is pending).
    private var handDragStarted: Date?
    /// The last settled, complete observation taken since the hand drag ended (adopted at the deadline when no clean one came).
    private var handAgreeing: ObservedOrder?
    private var handWaitLogged = false
    /// 9o9.26: Arrange drops made while the adoption waits (the record before the first one, then each drop's composed Visible and moved keys).
    /// The adoption judges the hand drag against the baseline and re-applies the drops on top of it.
    private var handBaseline: [ItemKey]?
    private var windowDrops: [(visible: [ItemKey], moved: Set<ItemKey>)] = []
    /// Keys whose frames were stale or uncorroborated when a hand drag was adopted as "unchanged" at the deadline: when they were stamped.
    private var handDragUnverified: Set<ItemKey> = [] {
        didSet {
            if handDragUnverified != oldValue {
                persistUnverified()
                Task { [weak self] in await self?.publishUnverified() }
            }
        }
    }

    /// 9o9.18: the unverified keys are part of the saved layout (only while non-empty), so a relaunch cannot enforce the record against a
    /// key still unread. Writes only when the saved value differs.
    private func persistUnverified() {
        guard loaded else { return }
        let keys = handDragUnverified.sorted { $0.description < $1.description }
        guard layout.unreadAfterHandDrag != keys else { return }
        layout.unreadAfterHandDrag = keys
        do { try store.save(layout) } catch { log("cannot save layout: \(error)") }
    }

    /// 9o9.18: the pending-adoption marker follows `handDragStarted`; saved only when it changed.
    private func persistHandMarker() {
        let drops = windowDrops.map { Layout.WindowDrop(visible: $0.visible, moved: $0.moved.sorted { $0.description < $1.description }) }
        let baseline = drops.isEmpty ? [] : (handBaseline ?? [])
        guard loaded, layout.pendingHandDrag != handDragStarted || layout.handWindowDrops != drops || layout.handWindowBaseline != baseline else { return }
        layout.pendingHandDrag = handDragStarted
        layout.handWindowDrops = drops; layout.handWindowBaseline = baseline
        do { try store.save(layout) } catch { log("cannot save layout: \(error)") }
    }

    /// 9o9.18: a relaunch with the hand-drag markers set: the adoption wait resumes (order phase suppressed, membership deferred, the
    /// first adoptable read decides). A marker older than `handDragResumeMaxAge` is adopted from anyway: never enforce the pre-drag record.
    static let handDragResumeMaxAge: TimeInterval = 60
    private func resumeHandDragState() {
        let keys = Set(layout.unreadAfterHandDrag).intersection(layout.visible)
        if !keys.isEmpty { handDragUnverified = keys }
        persistUnverified()
        guard let started = layout.pendingHandDrag else { return }
        let age = max(0, config.now().timeIntervalSince(started))
        handDragStarted = started
        if !layout.handWindowDrops.isEmpty {
            handBaseline = layout.handWindowBaseline
            windowDrops = layout.handWindowDrops.map { ($0.visible, Set($0.moved)) }
        }
        handAdopt = age < Self.handDragResumeMaxAge ? config.now().addingTimeInterval(windowSeconds(config.handDragAdoptWait)) : config.now()
        log("hand drag: resumed adoption after relaunch (age \(Int(age))s)")
    }
    private var publishedUnverified: Set<ItemKey> = []
    /// 9o9.5: publishes `handDragUnverified` as `EngineState.unverifiedAfterHandDrag` whenever it changed (the Arrange row shows it).
    func publishUnverified() async {
        let now = handDragUnverified
        guard now != publishedUnverified else { return }
        publishedUnverified = now
        await publish { $0.unverifiedAfterHandDrag = now }
    }
    private var handWaitLoggedAt: Date?
    private var handNoticeSerial = 0
    private var systemNoticeSerial = 0
    /// Test hook: pretends a clean observation of `bar` was read (the pass records it and adopts in the same step, so a pending adoption never coexists with one in production).
    func setCleanBarForTesting(_ bar: [ItemKey]?) { lastCleanBar = bar }
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
    /// gdu.80: the last two COMPLETE reads' churn data (pile + first-drawn neighbourhood). The churn zone is their union; the
    /// overflow set is settled when both agree. A pass that changed membership on a full bar never orders; the order phase waits
    /// for two agreeing complete reads.
    private(set) var recentReads: [ChurnRead] = []
    func noteChurn(_ items: [ResolvedItem], _ completeness: ReadCompleteness) {
        // 9o9.17: carried frames keep pile membership, so a read that lacks only self-positioning items is as good as a complete one for
        // the pile set; an incomplete read still says nothing.
        guard completeness != .incomplete else { return }
        recentReads.append(ChurnRead(resolved: items))
        if recentReads.count > 2 { recentReads.removeFirst(recentReads.count - 2) }
    }
    /// gdu.72: units the actuator refused to write (key -> reason; not tracked, Apple app...). Kept across passes so they are not
    /// retried every pass, never struck, shown `.unsupported`; cleared by `clearFailures` (layout change, Retry).
    private var actuatorRefused: [ItemKey: String] = [:]
    /// The `snapshotEpoch` each `actuatorRefused` key was refused in (gdu.74): re-evaluated when the snapshot has changed since.
    private var refusedEpoch: [ItemKey: Int] = [:]
    /// A user edit (or Try again) has not had its pass yet: that pass is the user's (it may reuse a seed and does not start with `passBoundary`).
    private var userEditPassOwed = false
    /// A user's edit chain is open: set by an edit / Try again, kept while its pass and the passes chained from it run, ended by the first regular
    /// pass (or when the drain ends). The core's `passBoundary` is sent when it ends (sommelier-ejb.7: the only chain state besides the owed flag).
    private var userEditChain = false
    static let userEditFollowUpReason = "userEditFollowUp"
    /// MEMBERSHIP-ONLY fold memory (sommelier-ejb.7; was the not-full proof's `lastFreshChevronObs`): the pile and the folded-parked keys of the last
    /// read with a FRESH chevron. A read that carries the chevron stale (or not at all) while the bar may still be full gets them back (`effective`),
    /// so a folded item is never "shown". It decides NO order move; it is dropped after three consecutive fully-read chevronless reads.
    private struct FoldMemory { var systemOverflow: Set<ItemKey>; var foldedParked: Set<ItemKey> }
    private var foldMemory: FoldMemory?
    private var chevronlessReads = 0
    /// Bounded follow-up passes asked while the core says "checking" (its proof of a not-full bar takes effect one read later, port item 2).
    private var checkingFollowUps = 0
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
    private var conflicted: Bool { conflictBox.value != nil || userPausedBox.value != nil }
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
                interaction: (any InteractionSource)? = nil,
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
        self.state = state; self.busy = busy; self.interaction = interaction; self.resolveSnapshot = resolveSnapshot; self.sleep = sleep
        self.log = log; self.config = config
        if config.recordCoreTrace { core.trace = [] }
    }

    // MARK: Verified decision core (ejb.15; docs/wiring-plan.md sections 1, 2, 5)
    //
    // This actor is the single serial owner of ONE `DecisionState` and ONE `CoreKeys` (inside `core`). Every core call below runs on the actor,
    // never in a `publish` closure on the main actor. ORDER moves are decided ONLY by `DecisionCore.step`; the old order planner
    // (`makePlan`, `Reconciler`'s order phase, the gates) still runs for DISPLAY until Wiring 4/5 but its actions never reach the actuator.

    private var core = CoreDriver()
    /// ejb.19: the last pass read was held back (settled:false) by the adapter's pile rule alone; and how many follow-up passes that has asked for in a row.
    private var heldByAdapter = false
    private var heldPasses = 0
    private var coreSeeded = false
    private var coreErrorShown = false
    private var publishedDisplay: CoreDisplay?
    /// A display computed by `coreStep` and not yet on `EngineState` (`.some(nil)` = publish "no display"). Carried by the next `publish` or `flushCoreDisplay`.
    private var pendingDisplay: CoreDisplay??
    /// A `lastError` change for the core's own errors, stashed by `coreStep` (which never suspends) and carried by the next `publish`. `.set(m)`: show the decision error; `.clear`: remove it.
    private enum PendingCoreError { case set(String), clear }
    private var pendingCoreError: PendingCoreError?
    /// The last `BarObservation` `observeOnce` produced (the adapter's input besides the `ObservedOrder`).
    private var lastBarObs: BarObservation?

    /// Test support: the audit of the core-driven order path.
    func coreAudit() -> (emitted: Int, resolved: Int, violations: Int, awaiting: Bool, trace: [CoreTraceEntry]) {
        (core.emitted, core.resolved, core.violations, core.awaiting != nil, core.trace ?? [])
    }
    func coreLastRead() -> Read? { core.lastRead }
    func coreDisplayForTests() -> CoreDisplay? { core.display }
    /// TESTS ONLY: makes every core step fail with `e` (nil: normal), to exercise the `DecisionError` path.
    func injectCoreFailureForTests(_ e: DecisionError?, onMoveResultOnly: Bool = false) { core.injectedFailure = e; core.injectOnMoveResultOnly = onMoveResultOnly }
    /// Timing of the `.read` steps so far: (count, total ns, worst ns).
    func coreReadStepTiming() -> (count: Int, totalNanos: Int64, worstNanos: Int64) { (core.readSteps, core.readStepNanos, core.readStepWorstNanos) }
    func coreAdaptTiming() -> (count: Int, totalNanos: Int64, worstNanos: Int64) { (core.adaptCount, core.adaptNanos, core.adaptWorstNanos) }
    func coreStateForTests() -> DecisionState? { core.state }
    func coreKeysForTests() -> CoreKeys { core.keys }

    /// THE call into `DecisionCore.step`. Returns the emitted actions (at most one). A `DecisionError` is logged, shown as `lastError`, and
    /// stops order actuation (no action is returned) until the next successful step; it never defaults to anything.
    @discardableResult
    private func coreStep(_ e: Event, _ name: String, site: String) -> [Action] {
        if !coreSeeded {
            coreSeeded = true
            // TESTS ONLY (`assumeFullBarAtLaunch == false`, "known not full"): three quiet polls of a chevronless complete bar prove it, as 3 real reads would.
            if !config.assumeFullBarAtLaunch {
                let quiet = Read(kind: .poll, chevron: .absent, level: .complete, settled: true, stripOpen: false, drawn: [], pile: [], folded: [], trusted: [], nearFold: [])
                for _ in 0..<3 { _ = core.step(.read(quiet), name: "read", site: "test seed (assumeFullBarAtLaunch == false)") }
            }
        }
        // No suspension in here (callers rely on it): errors and displays are stashed and carried by the next `publish` / `flushCoreDisplay`.
        switch core.step(e, name: name, site: site) {
        case .success(let actions):
            if coreErrorShown, !core.isDown, core.displayError == nil { coreErrorShown = false; pendingCoreError = .clear }
            return actions
        case .failure(let err):
            log("engine: decision core error at \(site) (\(name)): \(err); order actuation stopped until the next successful step")
            coreErrorShown = true
            pendingCoreError = .set("\(err)")
            return []
        }
    }

    /// Computes the display (a pass read computes its own; a non-read event left it stale) and stashes what changed for the next publish.
    /// Called ONLY where it can be published: after a pass read, and by `flushCoreDisplay` (end of a pass, end of a user event). Never suspends.
    private func settleCoreDisplay(site: String) {
        core.settleDisplay()
        if let de = core.displayError {   // the status/rows query failed: nothing is shown as matching, the error leads
            if !coreErrorShown || publishedDisplay != nil { log("engine: decision core display error at \(site): \(de)") }
            coreErrorShown = true
            publishedDisplay = nil
            pendingDisplay = .some(nil)
            pendingCoreError = .set("\(de)")
            return
        }
        if coreErrorShown, !core.isDown { coreErrorShown = false; pendingCoreError = .clear }
        if core.display != publishedDisplay {   // only a pass read (or a non-read event) changes it; a poll read never does
            let d = core.display
            publishedDisplay = d
            pendingDisplay = .some(d)
        }
    }

    /// The record as core ids (what `ReadAdapter` makes of `layout.visible`: deduped, no chevron, no immovable key).
    private func coreRecordIDs() -> [Key] {
        let caps = activeCapabilities ?? capabilities
        var seen = Set<ItemKey>(), out: [Key] = []
        for k in layout.visible where !core.keys.isChevron(k) && seen.insert(k).inserted && caps.capability(for: k).canMove {
            if let id = try? core.keys.intern(k) { out.append(id) }
        }
        return out
    }

    /// An ENGINE-made change of the record (new items, adoption, hand-drag adoption, System Settings hides): `userEdit(rec, [])`.
    private func coreSyncRecord(site: String) {
        let rec = coreRecordIDs()
        guard rec != core.record else { return }
        coreStep(.userEdit(record: rec, moved: []), "userEdit", site: site)
        if !core.isDown { core.record = rec }
    }

    /// The USER's edit (`setLayout` with moved keys placed by the user): `userEdit(rec, moved)`.
    private func coreUserEdit(moved: Set<ItemKey>, site: String) {
        let rec = coreRecordIDs()
        let ids = moved.sorted { $0.description < $1.description }.compactMap { k in core.keys.isChevron(k) ? nil : try? core.keys.intern(k) }
        coreStep(.userEdit(record: rec, moved: ids), "userEdit", site: site)
        if !core.isDown { core.record = rec }
    }

    /// The one answer to an emitted action. Exactly one per `Action`: vetoes after the step send `busy` with `posted: false`.
    private func coreResult(_ a: Action, _ outcome: Outcome, posted: Bool, site: String) {
        coreStep(.moveResult(a.subject, outcome, posted: posted), "moveResult", site: site)
    }

    /// Safety net: no emitted action may stay unanswered when a pass ends, whatever path ended it.
    private func coreSettleStraggler(site: String) {
        guard let w = core.awaiting else { return }
        log("engine: BUG? an emitted order move of \(w.subject) was not answered; answering busy (not posted) at \(site)")
        coreResult(w.action, .busy, posted: false, site: site)
    }

    /// Control Center entries that belong together (an app and its helpers): the adapter's `ownerFamilies`.
    private func coreOwnerFamilies() -> [[String]] {
        (resolverSnapshot?.entries ?? []).filter { !$0.menuItemKeys.isEmpty }.map { [$0.key] + $0.menuItemKeys }
    }

    /// Feeds ONE read to the core: adapts it (`ReadAdapter`), syncs the record, then `step(.read)`.
    /// `vetoed` = a Swift-only veto known BEFORE the step (pause, conflict, sleep, not ready, membership batch this pass, pending adoption,
    /// hand-drag adoption, transient reveal, reveal pass, post-move evidence): the read is downgraded to `settled: false`, which is the ONLY
    /// edit a veto may make. A vetoed read is still fed, and never decides anything. Returns the emitted actions of a pass read.
    @discardableResult
    private func coreRead(_ o: ObservedOrder, bar: BarObservation, kind: ReadKind, vetoed: Bool, site: String) -> [Action] {
        let caps = activeCapabilities ?? capabilities
        let immovable = Set((layout.visible + o.onBar + o.parked).filter { !caps.capability(for: $0).canMove })
        var ctx = ReadContext(observation: bar, kind: kind, previousCompletePile: core.lastCompletePile, handDragUnverified: handDragUnverified,
                              immovable: immovable, churnZone: SystemOverflowRule.churnZone(recentReads), selfPositioningOwners: config.selfPositioningOwners,
                              log: log, itemInfo: itemInfo, ownerFamilies: coreOwnerFamilies())
        if vetoed { ctx.settled = false }
        let adapted: AdaptedRead
        let adaptT0 = ContinuousClock.now
        do {
            adapted = try ReadAdapter.adapt(o, context: ctx, record: layout.visible, keys: &core.keys)
            let d = adaptT0.duration(to: .now).components
            core.noteAdapt(d.seconds * 1_000_000_000 + d.attoseconds / 1_000_000_000)
        } catch {
            log("engine: read adapter error at \(site): \(error); this read is not fed")
            core.note(.error("adapter: \(error)"))
            return []
        }
        heldByAdapter = kind == .pass && !vetoed && bar.settled && bar.completeness == .complete && !adapted.read.settled   // ejb.19: the adapter alone held this pass read
        if kind == .pass, ctx.settled, !adapted.read.settled { log(SystemOverflowRule.unsettledText(recentReads)) }   // the pile of the last two complete reads disagrees: evidence only
        if bar.completeness == .complete {
            let suspects = Set(o.staleOnBar).union(o.uncorroborated)
            core.lastCompletePile = Set(o.onBar.filter { !suspects.contains($0) && !core.keys.isChevron($0) && o.systemOverflow.contains($0) })
        }
        if adapted.record != core.record {   // engine-made record changes reach the core before the read that judges them
            coreStep(.userEdit(record: adapted.record, moved: []), "userEdit", site: site + " (record sync)")
            if !core.isDown { core.record = adapted.record }
        }
        let actions = coreStep(.read(adapted.read), "read", site: site)
        if kind == .pass {
            settleCoreDisplay(site: site)   // a pass read is where the display is published
            if core.displayError != nil, let a = actions.first {   // the status/rows query failed: no order move is performed (lastError leads)
                coreResult(a, .busy, posted: false, site: site + " (display error)")
                return []
            }
        }
        if kind != .pass || vetoed, let a = actions.first {   // cannot happen (only a settled pass read decides); answered, never performed
            log("engine: BUG? the core emitted a move on a \(kind == .poll ? "poll" : "vetoed") read; not performed")
            coreResult(a, .busy, posted: false, site: site + " (unexpected action)")
            return []
        }
        return actions
    }

    /// A read the pass cannot act on (an early exit of the pass): still fed, as evidence only.
    private func coreFeedVetoed(_ o: ObservedOrder, site: String) {
        guard let b = lastBarObs else { return }
        coreRead(o, bar: b, kind: .pass, vetoed: true, site: site)
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
            if l0.pendingAdoption { log("layout: legacy order fields found; the bar order will be adopted on the first complete, settled observation (no order move is planned until then)") }
            movedAtLoad = moved
            if !moved.isEmpty {
                AppLog.log(.engine, "layout: all items governed by one Control Center entry hide or show at once; moved to visible: \(moved.map(\.description).joined(separator: ", "))")
            }
            loaded = true
            stopped = false
            resumeHandDragState()
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
        // 9o9.2/9o9.3: the pending-adoption flag is engine state: a scan-built layout never changes it. A user placement that changes
        // Visible while the adoption is pending FIRST adopts the record from the last clean observation and then applies the drop on
        // top of it (it must not enforce the legacy saved order, which could reorder unrelated items). With no clean observation yet
        // the layout is left as it is (the Arrange window refuses such a drop before it gets here).
        new.pendingAdoption = layout.pendingAdoption
        new.pendingHandDrag = layout.pendingHandDrag   // 9o9.18: engine state, like pendingAdoption
        new.handWindowBaseline = layout.handWindowBaseline; new.handWindowDrops = layout.handWindowDrops   // 9o9.27 (refreshed below)
        var adoptedPendingNow = false
        if layout.pendingAdoption, userPlacement, new.visible != layout.visible {
            guard let bar = lastCleanBar else {
                log("setLayout refused: the menu bar order has not been read yet (adoption pending)")
                let s = state
                return await MainActor.run { LayoutRevision(revision: s.layoutRevision, passesStarted: s.passesStarted) }
            }
            let adopted = Self.adoptedVisible(layout.visible, bar: bar)
            new.visible = Self.applyingDrop(to: adopted, requested: new.visible, moved: movedKeys)
            new.pendingAdoption = false
            adoptedPendingNow = true
            log("layout: adopted bar order before applying the drop (\(new.visible.count) keys)")
        }
        // gdu.79: keys this call moved into `visible` are the user's explicit placement; the rest keep the status they had.
        let wasVisible = Set(layout.visible)
        userPlacedVisible = userPlacedVisible.intersection(new.visible)
        if userPlacement {
            userPlacedVisible.formUnion(new.visible.filter { !wasVisible.contains($0) })
            // gdu.95: a key the user dropped counts as placed even when the layout already listed it visible (hidden in Control Center).
            userPlacedVisible.formUnion(movedKeys.intersection(Set(new.visible)))
        }
        if new.visible != layout.visible {
            // 9o9.7: the user's own word from Arrange supersedes an unread hand drag, but only for the keys that edit repositioned;
            // adopting the current order (pending adoption) took the whole bar as the record.
            if adoptedPendingNow { handDragUnverified = [] }
            else {
                // Only keys the edit MOVED or REMOVED: a key whose neighbours changed because something was dropped next to it
                // was not touched. The caller's `moved` set is authoritative; without it the mover is derived from the two lists.
                let edited = movedKeys.isEmpty ? Self.movedOrRemoved(old: layout.visible, new: new.visible, unverified: handDragUnverified)
                    : Set(layout.visible).subtracting(new.visible).union(movedKeys)
                handDragUnverified.subtract(edited)
                // 9o9.26: a drop made while the hand drag awaits adoption is re-applied on top of it (the adoption takes the bar verbatim).
                if handAdopt != nil, userPlacement {
                    if handBaseline == nil { handBaseline = layout.visible }
                    windowDrops.append((new.visible, edited.intersection(new.visible)))
                    new.handWindowBaseline = handBaseline ?? []
                    new.handWindowDrops = windowDrops.map { Layout.WindowDrop(visible: $0.visible, moved: $0.moved.sorted { $0.description < $1.description }) }
                }
            }
        }
        new.unreadAfterHandDrag = handDragUnverified.filter(new.visible.contains).sorted { $0.description < $1.description }
        layout = new
        loaded = true
        noteSupersede("setLayout")
        do { try store.save(new) } catch { log("cannot save layout: \(error)") }
        let stamp = await publishLayout(new, normalized: moved)
        // The user's edit opens a chain: its pass (and the passes chained from it) belong to the user (the core restricts them to the owed keys).
        if userPlacement, !movedKeys.isEmpty {
            userEditChain = true
            userEditPassOwed = true
        }
        await clearFailures()
        // ejb.15 event userEdit (wiring plan section 1): the USER's placement (moved keys) is `userEdit(rec, moved)`; any other change of the record
        // (a scan-built layout, a pending-adoption drop with nothing moved) is the engine's: `userEdit(rec, [])`.
        if userPlacement, !movedKeys.isEmpty { coreUserEdit(moved: movedKeys, site: "setLayout (user placement)") }
        else { coreSyncRecord(site: "setLayout (no user move)") }
        await flushCoreDisplay()
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

    // MARK: Hand drags (9o9.7)

    /// The monitor's events (main thread). Synchronous on purpose: whether a drag is Sommelier's own is decided here, at the moment the
    /// button goes down, by the actuator-in-flight flag around `actuator.move` / `applyHiddenBatch`.
    public nonisolated func handDragEvent(_ e: HandDragEvent) {
        switch e {
        case .began:
            if flightBox.inFlight { handDragBox.ignoreCurrent(); return }   // our own synthetic drag
            handDragBox.begin(now: Date(), flightSerial: flightBox.serial)
            log("engine: you started dragging in the menu bar; no moves until you let go")
        case .ended:
            guard let began = handDragBox.end() else { return }
            // The drag itself is what is compared: an actuator call after this point (membership, a later order move) is not part of it.
            let moved = flightBox.inFlight || flightBox.serial != began
            Task { await self.handDragEnded(engineMoved: moved) }
        }
    }

    /// The hand drag ended: the next settled complete observation decides the new order. Observations in progress are abandoned (they
    /// may show the bar mid-drag), the pause backoff is over, and a pass runs now.
    func handDragEnded(engineMoved: Bool) async {
        guard loaded, !stopped else { return }
        endHandAdoption()
        if engineMoved {
            // The bar holds Sommelier's own move as well as the user's: nothing can be read from it as the user's order.
            log("layout: your menu bar drag was not adopted: Sommelier moved an item during it")
            handBaseline = nil; windowDrops = []   // the drops are already in the record
            persistHandMarker()
        } else {
            handAdopt = config.now().addingTimeInterval(windowSeconds(config.handDragAdoptWait))
            handDragStarted = config.now()
            persistHandMarker()
            log("engine: you finished a menu bar drag; adopting the resulting order")
        }
        pauseRetry = nil
        delayed[Self.interactionPauseReason]?.cancel(); delayed[Self.interactionPauseReason] = nil
        noteSupersede("hand drag")
        if handAdopt != nil { scheduleReconcile(after: config.handDragAdoptWait, reason: Self.handDragReason) }
        requestReconcile(reason: "hand drag")
    }
    static let handDragReason = "hand drag adopt"

    /// `persist: false` when the caller is about to adopt: the marker then clears in the very save that writes the adopted record.
    private func endHandAdoption(persist: Bool = true) {
        handDragStarted = nil
        if persist { persistHandMarker() }
        handAdopt = nil; handAgreeing = nil; handWaitLogged = false; handWaitLoggedAt = nil
        delayed[Self.handDragReason]?.cancel(); delayed[Self.handDragReason] = nil
    }

    /// An adoptable read: settled (the caller guarantees it) and complete, or complete except the self-positioning owners' carried frames.
    private var readIsAdoptable: Bool { observedCompleteness == .complete || observedCompleteness == .completeExceptSelfPositioning }

    /// Stale (carried) on-bar keys of a read: their frames say nothing about where the user left them.
    private func staleOnBarKeys(_ obs: ObservedOrder) -> Set<ItemKey> {
        obs.staleOnBar.intersection(obs.onBar).subtracting(obs.overflowChevron.map { [$0] } ?? [])
    }

    /// Unread on-bar keys of a read: stale (carried) or uncorroborated (an ambiguous join: its frame may belong to another item).
    private func unreadOnBarKeys(_ obs: ObservedOrder) -> Set<ItemKey> {
        obs.uncorroborated.union(obs.staleOnBar).intersection(obs.onBar).subtracting(obs.overflowChevron.map { [$0] } ?? [])
    }

    /// Called with a settled observation while a hand drag awaits adoption. An adoptable read decides at once, unless it shows the order
    /// UNCHANGED while some on-bar frame is stale: the dragged item may be one of those (its frame not refreshed yet), so that read only
    /// waits (and is the deadline fallback).
    private func considerHandDragAdoption(_ obs: ObservedOrder) async {
        guard handAdopt != nil else { return }
        if readIsAdoptable {
            let old = handBaseline ?? layout.visible
            let unchanged = Self.handDragAdopted(obs, record: old).visible == old
            if !unchanged || unreadOnBarKeys(obs).isEmpty { endHandAdoption(persist: false); await adoptHandDrag(obs); return }
            handAgreeing = obs
        }
        if !handWaitLogged {
            handWaitLogged = true
            log("layout: hand drag adoption waiting: \(!readIsAdoptable ? "the read is \(observedCompleteness.rawValue)" : "on-bar frames are not fresh and corroborated (the dragged item may be one of them)")")
        }
        scheduleReconcile(after: .seconds(2), reason: "hand drag retry")
    }

    /// At the start of a pass: the wait for a settled observation is over. Adopt the last adoptable read taken since the drag (an
    /// "unchanged" one whose stale keys then become unverified). With none, KEEP WAITING (the order phase stays suppressed): the old
    /// record is never enforced over the user's drag.
    private func expireHandDragAdoption() async {
        guard let deadline = handAdopt, config.now() >= deadline else { return }
        if let last = handAgreeing {
            endHandAdoption(persist: false)
            log("layout: hand drag: no clean observation within \(config.handDragAdoptWait); adopting the last settled one")
            await adoptHandDrag(last, atDeadline: true)
            return
        }
        let now = config.now()
        if handWaitLoggedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            handWaitLoggedAt = now
            log("hand drag: still waiting for a clean read")
        }
        scheduleReconcile(after: .seconds(2), reason: "hand drag retry")
    }

    /// A key left unverified by a deadline adoption is now read fresh: its observed slot is the user's (a drag that earlier reads could not
    /// show). Only that key is placed, at its observed slot relative to ALL observed on-bar neighbours (fresh or stale: the planner
    /// orders trusted keys against the stale ones' observed slots, so the record must agree); every other difference is not a hand drag's.
    private func adoptLateHandDrags(_ obs: ObservedOrder) async {
        guard !handDragUnverified.isEmpty, handAdopt == nil, readIsAdoptable else { return }
        let stale = staleOnBarKeys(obs)
        let ambiguous = obs.uncorroborated.subtracting(stale)   // fresh but ambiguous: neither placed nor an anchor
        let full = Self.handDragBar(obs, record: layout.visible)
        let seen = full.filter { !ambiguous.contains($0) }
        var visible = layout.visible
        var adopted: [ItemKey] = []
        for k in handDragUnverified.sorted(by: { $0.description < $1.description }) {
            guard obs.onBar.contains(k), !stale.contains(k), !obs.uncorroborated.contains(k) else { continue }
            if !obs.stripExpanded, obs.systemOverflow.contains(k) { continue }   // stacked behind the chevron: no order to read
            guard let fi = seen.firstIndex(of: k), visible.contains(k), let ai = full.firstIndex(of: k) else { handDragUnverified.remove(k); continue }
            // An ambiguous key right beside it makes its slot unreadable (it may be the dragged one): wait for a clean read.
            if (ai > 0 && ambiguous.contains(full[ai - 1])) || (ai + 1 < full.count && ambiguous.contains(full[ai + 1])) { continue }
            var next = visible
            next.removeAll { $0 == k }
            let anchor: ItemKey
            if let p = seen[..<fi].last(where: { next.contains($0) }) { anchor = p }
            else if let n = seen[(fi + 1)...].first(where: { next.contains($0) }) { anchor = n }
            else { handDragUnverified.remove(k); continue }
            // 9o9.18 (P1b): a held-back key (ambiguous, or unverified and unread) whose RECORD slot lies between the anchor and this key
            // may be the dragged one misread at a distant slot: wait for it to read clean.
            let heldBack = ambiguous.union(handDragUnverified.intersection(stale)).subtracting([k])
            if let r0 = visible.firstIndex(of: k), let r1 = visible.firstIndex(of: anchor),
               heldBack.contains(where: { h in visible.firstIndex(of: h).map { min(r0, r1) < $0 && $0 < max(r0, r1) } ?? false }) { continue }
            guard let ai2 = next.firstIndex(of: anchor) else { continue }
            let after = seen[..<fi].contains(anchor)
            // The insertion gap itself: held-back keys right beside the slot the key would take sit where it may really belong.
            if after { if next[(ai2 + 1)...].first.map(heldBack.contains) ?? false { continue } }
            else if ai2 > 0, heldBack.contains(next[ai2 - 1]) { continue }
            handDragUnverified.remove(k)
            next.insert(k, at: after ? ai2 + 1 : ai2)
            if next != visible { visible = next; adopted.append(k) }
        }
        guard !adopted.isEmpty else { return }
        var l = layout
        l.visible = visible
        layout = l
        do { try store.save(l) } catch { log("cannot save layout: \(error)") }
        for k in adopted { log("layout: adopted your menu bar drag of \(k) (read late)") }
        _ = await publishLayout(l)
        coreSyncRecord(site: "adoptLateHandDrags (hand-drag adoption)")   // ejb.15: engine-made record change = userEdit(rec, [])
        await publishUnverified()
        await announceHandDrag()
    }

    private func announceHandDrag() async {
        handNoticeSerial += 1
        let serial = handNoticeSerial
        await publish { $0.handDragNotice = HandDragNotice.text }
        let lifetime = config.noticeLifetime
        Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            await self?.clearHandNotice(serial)
        }
    }

    /// Pure: the on-bar order a hand drag is judged by: the observed order verbatim for every on-bar key, fresh or stale, trusted or not
    /// (a carried frame is the last real position, and the planner orders trusted keys against those same observed slots; fresh ambiguous keys are held back by `handDragAdopted`); only the
    /// chevron is left out. With the strip collapsed the
    /// stacked frames of the keys behind the chevron carry no order (9o9.11), so those keys keep their record order among
    /// themselves in the slots they occupy; with the strip open every frame is real and the observation is used as it is.
    static func handDragBar(_ obs: ObservedOrder, record: [ItemKey]) -> [ItemKey] {
        var bar = obs.onBar.filter { $0 != obs.overflowChevron && !$0.isOverflowChevron }
        guard !obs.stripExpanded, !obs.systemOverflow.isEmpty else { return bar }
        let slots = bar.indices.filter { obs.systemOverflow.contains(bar[$0]) }
        let rank = Dictionary(record.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let pile = slots.map { bar[$0] }.sorted { (rank[$0] ?? .max) < (rank[$1] ?? .max) }
        for (i, s) in slots.enumerated() { bar[s] = pile[i] }
        return bar
    }

    /// Pure: the new record for a hand drag. Fresh corroborated and stale keys are adopted at their observed slot; fresh but UNCORROBORATED
    /// keys (`deferred`) are not read from this observation: each keeps its record slot after its nearest preceding record neighbour that the
    /// adoption did not move (else before its nearest following one), never attached to the dragged key.
    static func handDragAdopted(_ obs: ObservedOrder, record: [ItemKey]) -> (visible: [ItemKey], deferred: Set<ItemKey>, multi: Bool) {
        let barAll = handDragBar(obs, record: record)
        let deferred = obs.uncorroborated.subtracting(obs.staleOnBar).intersection(Set(barAll)).intersection(Set(record))
        guard !deferred.isEmpty else { return (adoptedVisible(record, bar: barAll), [], false) }
        let trusted = barAll.filter { !deferred.contains($0) }
        let base = adoptedVisible(record.filter { !deferred.contains($0) }, bar: trusted)
        let oldT = record.filter { base.contains($0) && trusted.contains($0) }
        let newT = base.filter { oldT.contains($0) }
        var moved = Set<ItemKey>()
        var multi = false   // 9o9.18: more than one key moved: held-back keys are placed after the moved ones
        if oldT != newT {
            // Prefer the mover that explains the WHOLE bar (held-back keys included): a drag past an ambiguous key is one move.
            let oldAll = record.filter { barAll.contains($0) }, newAll = barAll.filter { record.contains($0) }
            if let mf = movedByDrag(old: oldAll, new: newAll), !deferred.contains(mf.key),
               oldT.filter({ $0 != mf.key }) == newT.filter({ $0 != mf.key }) {
                moved = [mf.key]
            } else if let m = movedByDrag(old: oldT, new: newT) { moved = [m.key]; multi = movedByDrag(old: oldAll, new: newAll) == nil } else {
                moved = Set(oldT).subtracting(keptInOrder(oldT, newT))
                multi = true
            }
        }
        // Unmoved keys, held-back ones included, keep their record order; each moved key then goes to its observed slot.
        var out = base.filter { !moved.contains($0) }
        var placed: [ItemKey: Int] = [:]
        for (i, k) in record.enumerated() where deferred.contains(k) && !multi {
            if let a = record[..<i].last(where: { out.contains($0) && !deferred.contains($0) }), let ai = out.firstIndex(of: a) {
                out.insert(k, at: ai + placed[a, default: 0] + 1); placed[a, default: 0] += 1
            } else if let n = record[(i + 1)...].first(where: { out.contains($0) && !deferred.contains($0) }), let ni = out.firstIndex(of: n) {
                out.insert(k, at: ni)
            } else { out.insert(k, at: min(i, out.count)) }
        }
        for m in barAll where moved.contains(m) {
            let bi = barAll.firstIndex(of: m)!
            if let p = barAll[..<bi].last(where: { out.contains($0) }), let pi = out.firstIndex(of: p) { out.insert(m, at: pi + 1) }
            else if let n = barAll[(bi + 1)...].first(where: { out.contains($0) }), let ni = out.firstIndex(of: n) { out.insert(m, at: ni) }
            else { out.insert(m, at: min(base.firstIndex(of: m) ?? out.count, out.count)) }
        }
        if multi {
            // After every moved key has its observed slot: a held-back key follows its nearest record predecessor wherever that went
            // (else precedes its nearest record successor), unmoved neighbours first; it is never the first key just because its neighbours were moved.
            for (i, d) in record.enumerated() where deferred.contains(d) {
                if let p = record[..<i].last(where: { out.contains($0) && !moved.contains($0) }) ?? record[..<i].last(where: { out.contains($0) }), let pi = out.firstIndex(of: p) { out.insert(d, at: pi + 1) }
                else if let n = record[(i + 1)...].first(where: { out.contains($0) }), let ni = out.firstIndex(of: n) { out.insert(d, at: ni) }
                else { out.append(d) }
            }
        }
        return (out, deferred, multi)
    }

    /// Pure: the unread keys adjacent (in the observed bar, or in the new record) to ANY key that could be the mover of old -> new
    /// (every key whose lone travel explains the change; else every key outside a longest common subsequence). Empty when nothing moved.
    static func unreadNearDrop(old: [ItemKey], new: [ItemKey], bar: [ItemKey], unread: Set<ItemKey>) -> Set<ItemKey> {
        guard !unread.isEmpty else { return [] }
        let common = Set(old).intersection(new)
        let o = old.filter(common.contains), n = new.filter(common.contains)
        guard o != n else { return [] }
        var movers = Set<ItemKey>()
        for k in o {
            guard let i = o.firstIndex(of: k), let j = n.firstIndex(of: k), i != j else { continue }
            var a = o, b = n
            a.remove(at: i); b.remove(at: j)
            if a == b { movers.insert(k) }
        }
        if movers.isEmpty { movers = Set(o).subtracting(keptInOrder(o, n)) }
        var out = Set<ItemKey>()
        for list in [bar, new] {
            for m in movers {
                guard let i = list.firstIndex(of: m) else { continue }
                for d in [-1, 1] where list.indices.contains(i + d) && unread.contains(list[i + d]) && list[i + d] != m { out.insert(list[i + d]) }
            }
        }
        return out.intersection(common)
    }

    /// Pure (9o9.26): the `held` keys lying inside the stretch a possible mover travelled, in the old record or the new one (inclusive of the
    /// mover's own old and new slots). A drag past a held-back key may really be that key's own move misread at a distant slot, so the key
    /// is not placed from this read. Empty when nothing moved.
    static func heldInMoveSpan(old: [ItemKey], new: [ItemKey], held: Set<ItemKey>) -> Set<ItemKey> {
        guard !held.isEmpty else { return [] }
        let common = Set(old).intersection(new)
        let o = old.filter(common.contains), n = new.filter(common.contains)
        guard o != n else { return [] }
        var movers = Set<ItemKey>()
        for k in o {
            guard let i = o.firstIndex(of: k), let j = n.firstIndex(of: k), i != j else { continue }
            var a = o, b = n
            a.remove(at: i); b.remove(at: j)
            if a == b { movers.insert(k) }
        }
        if movers.isEmpty { movers = Set(o).subtracting(keptInOrder(o, n)) }
        var out = Set<ItemKey>()
        for m in movers {
            guard let i = o.firstIndex(of: m), let j = n.firstIndex(of: m) else { continue }
            let lo = min(i, j), hi = max(i, j)
            out.formUnion(o[lo...hi]); out.formUnion(n[lo...hi])
        }
        return out.intersection(held).intersection(common)
    }

    /// Pure: keys `new` no longer holds, plus the keys an edit MOVED among those both lists hold: the single mover when one key
    /// travelled (`movedByDrag`), else every key outside a longest common subsequence. Neighbours of a drop are not moved.
    /// On a tie between equally good readings a key in `unverified` is kept as UNMOVED (never counted as moved).
    static func movedOrRemoved(old: [ItemKey], new: [ItemKey], unverified: Set<ItemKey> = []) -> Set<ItemKey> {
        let common = Set(old).intersection(new)
        let o = old.filter(common.contains), n = new.filter(common.contains)
        var out = Set(old).subtracting(new)
        if o != n { out.formUnion(movedByDrag(old: o, new: n, avoiding: unverified).map { [$0.key] } ?? Set(o).subtracting(keptInOrder(o, n, prefer: unverified))) }
        return out
    }

    /// Pure: the keys of a longest common subsequence of `a` and `b` (deterministic).
    /// Length comes first; among equally long subsequences the one keeping more `prefer` keys wins.
    static func keptInOrder(_ a: [ItemKey], _ b: [ItemKey], prefer: Set<ItemKey> = []) -> Set<ItemKey> {
        let base = a.count + 1
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + base + (prefer.contains(a[i]) ? 1 : 0) : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out = Set<ItemKey>()
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { out.insert(a[i]); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        return out
    }

    /// Pure: the key a reorder moved and what it now follows (nil key = more than one key moved). Among equivalent readings the key
    /// that travelled farthest wins.
    /// On an exact tie a key in `avoiding` (unverified) is not the mover.
    static func movedByDrag(old: [ItemKey], new: [ItemKey], avoiding: Set<ItemKey> = []) -> (key: ItemKey, after: ItemKey?)? {
        var best: (key: ItemKey, dist: Int)?
        for k in old {
            guard let i = old.firstIndex(of: k), let j = new.firstIndex(of: k), i != j else { continue }
            var a = old, b = new
            a.remove(at: i); b.remove(at: j)
            guard a == b else { continue }
            let d = abs(i - j)
            if let cur = best {
                if d > cur.dist || (d == cur.dist && avoiding.contains(cur.key) && !avoiding.contains(k)) { best = (k, d) }
            } else { best = (k, d) }
        }
        guard let b = best, let j = new.firstIndex(of: b.key) else { return nil }
        return (b.key, j > 0 ? new[j - 1] : nil)
    }

    /// The user's drag is the record: reorders Visible to the observed order, saves, logs, publishes the notice, and gives the engine a
    /// fresh start with every item (the old attempts concerned the old record).
    private func adoptHandDrag(_ obs: ObservedOrder, atDeadline: Bool = false) async {
        let current = layout.visible
        let old = handBaseline ?? current       // 9o9.26: the record before any Arrange drop made during the wait
        let drops = windowDrops
        handBaseline = nil; windowDrops = []
        let adopted = Self.handDragAdopted(obs, record: old)
        let new = adopted.visible
        let unread = unreadOnBarKeys(obs).filter(old.contains)
        for k in Self.handDragBar(obs, record: old) where !unread.contains(k) { handDragUnverified.remove(k) }   // fresh and corroborated: final
        guard new != old else {
            // Nothing the user dragged is visible: an ambiguous read may be the dragged key, so a corroborated read decides later.
            handDragUnverified.formUnion(adopted.deferred)
            if atDeadline, !unread.isEmpty {
                log("hand drag: left the order unchanged as far as Sommelier can see; \(unread.count) item(s) still unread")
                handDragUnverified.formUnion(unread)
            } else { log("layout: your menu bar drag left the order unchanged") }
            persistUnverified(); persistHandMarker()
            return
        }
        var final = new
        for d in drops { final = Self.applyingDrop(to: final, requested: d.visible.filter(Set(final).contains), moved: d.moved.intersection(final)) }
        // keys the record gained since the baseline (and not in the drops) stay, after their nearest preceding neighbour; keys it lost stay gone
        if !drops.isEmpty {
            final = final.filter(current.contains)
            for (i, k) in current.enumerated() where !final.contains(k) {
                if let p = current[..<i].last(where: { final.contains($0) }), let pi = final.firstIndex(of: p) { final.insert(k, at: pi + 1) } else { final.insert(k, at: 0) }
            }
        }
        var l = layout
        l.visible = final
        l.pendingHandDrag = nil
        l.handWindowBaseline = []; l.handWindowDrops = []
        l.unreadAfterHandDrag = handDragUnverified.filter(final.contains).sorted { $0.description < $1.description }
        layout = l
        do { try store.save(l) } catch { log("cannot save layout: \(error)") }
        let namer = RowNameRule.Namer(layout: layout, items: itemInfo)
                func name(_ k: ItemKey) -> String { itemInfo[k] != nil ? namer.name(k) : k.description }
        if !drops.isEmpty, let k = drops.last?.moved.sorted(by: { $0.description < $1.description }).first {
            log("layout: re-applied your Arrange drop of \(name(k)) after the menu bar drag was adopted")
        }
        // An unread key next to the drop may be the real mover (or the real neighbour): its slot is not trusted, so it is placed when read.
        let nearDrop = Self.unreadNearDrop(old: old, new: new, bar: Self.handDragBar(obs, record: old), unread: unread)
        handDragUnverified.formUnion(nearDrop)
        // 9o9.18: more than one key moved (no single mover explains the change): an ambiguous key's slot among the moved ones is a
        // guess, so it is held back (never planned against) and placed only when it reads clean.
        // 9o9.26: also when `handDragAdopted` itself saw more than one moved key: a misread ambiguous key can make the adopted record
        // look like a single move, so the check on the record alone is not enough.
        if !adopted.deferred.isEmpty, adopted.multi || Self.movedByDrag(old: old, new: new) == nil {
            handDragUnverified.formUnion(adopted.deferred.filter(new.contains))
            if nearDrop.isEmpty { log("hand drag: adopted; \(adopted.deferred.count) ambiguous item(s) among several moved keys will be placed when read") }
        }
        // 9o9.26: and an ambiguous key inside the stretch a mover travelled (a swap past it, with it misread far away, looks like one move).
        // Only one whose trusted neighbours on the bar are no longer its record neighbours (A dragged clear across an ambiguous key that
        // still reads between the same two keys is not in doubt).
        let barNow = Self.handDragBar(obs, record: old).filter(old.contains)
        func trustedNeighbours(_ list: [ItemKey], of h: ItemKey) -> (ItemKey?, ItemKey?) {
            let l = list.filter { $0 == h || !adopted.deferred.contains($0) }
            guard let i = l.firstIndex(of: h) else { return (nil, nil) }
            return (i > 0 ? l[i - 1] : nil, i + 1 < l.count ? l[i + 1] : nil)
        }
        let inSpan = Self.heldInMoveSpan(old: old, new: new, held: adopted.deferred).subtracting(handDragUnverified)
            .filter { trustedNeighbours(old, of: $0) != trustedNeighbours(barNow, of: $0) }
        if !inSpan.isEmpty {
            handDragUnverified.formUnion(inSpan)
            if nearDrop.isEmpty {
                log("hand drag: adopted; \(inSpan.count) ambiguous item(s) inside the dragged range will be placed when read")
            }
        }
        // 9o9.26: a key an Arrange drop moved during the wait is the user's placement, not in doubt: the hold-backs above must not keep it
        // out of the planner (setLayout cleared it at drop time), or the next clean read would revert the drop.
        handDragUnverified.subtract(drops.flatMap(\.moved))
        if let u = nearDrop.sorted(by: { $0.description < $1.description }).first {
            log("hand drag: adopted; \(name(u)) next to the drop is unread and will be placed when read")
        } else if let m = Self.movedByDrag(old: old, new: new) {
            log("layout: adopted your menu bar drag: \(name(m.key)) now \(m.after.map { "after \(name($0))" } ?? "first")")
        } else {
            log("layout: adopted your menu bar drag: \(new.count) keys reordered")
        }
        _ = await publishLayout(l)
        coreSyncRecord(site: "adoptHandDrag (hand-drag adoption)")   // ejb.15: engine-made record change = userEdit(rec, [])
        await publishUnverified()
        await announceHandDrag()
    }

    private func clearHandNotice(_ serial: Int) async {
        guard serial == handNoticeSerial else { return }
        await publish { $0.handDragNotice = nil }
    }

    /// Reorders `visible` to the observed on-bar order (keys not on the bar keep their relative order, inserted after their nearest
    /// preceding observed neighbour), saves, clears `pendingAdoption`. Called only with a complete, settled observation.
    func adoptBarOrder(_ obs: ObservedOrder) async {
        let n = layout.pendingAdoption ? Self.adoptedVisible(layout.visible, bar: obs.onBar) : layout.visible
        var l = layout
        l.visible = n
        l.pendingAdoption = false
        layout = l
        do { try store.save(l) } catch { log("cannot save layout: \(error)") }
        log("layout: adopted bar order on upgrade (\(n.count) keys)")
        _ = await publishLayout(l)
        coreSyncRecord(site: "adoptBarOrder (upgrade adoption)")   // ejb.15: engine-made record change = userEdit(rec, [])
    }

    /// Pure (9o9.3): `adopted` (the record adopted from the bar) with the user's drop applied. `requested` is the Visible order the
    /// drop was composed on (legacy order + the drop). Keys of `requested` that were not moved keep their adopted relative order; each
    /// moved (or new) key goes right after its nearest preceding unmoved key of `requested`, or first when none precedes it. Keys
    /// `requested` no longer lists are removed.
    static func applyingDrop(to adopted: [ItemKey], requested: [ItemKey], moved: Set<ItemKey>) -> [ItemKey] {
        let want = Set(requested)
        let known = Set(adopted)
        let mv = moved.union(requested.filter { !known.contains($0) })
        var out = adopted.filter { want.contains($0) && !mv.contains($0) }
        var anchor: ItemKey?
        for k in requested {
            if !mv.contains(k) { anchor = k; continue }
            if let a = anchor, let i = out.firstIndex(of: a) { out.insert(k, at: i + 1) } else { out.insert(k, at: 0) }
            anchor = k
        }
        return out
    }

    /// Pure: `visible` reordered so its on-bar keys follow `bar`; off-bar keys stay after their nearest preceding neighbour in `visible`
    /// (the one that precedes them in the old order, after that neighbour's move), or lead when none precedes them.
    static func adoptedVisible(_ visibleIn: [ItemKey], bar barIn: [ItemKey]) -> [ItemKey] {
        let visible = visibleIn.filter { !$0.isOverflowChevron }   // 9o9.14: the chevron is never a record key
        let bar = barIn.filter { !$0.isOverflowChevron }
        let inVisible = Set(visible)
        var seen = Set<ItemKey>()
        let order = bar.filter { inVisible.contains($0) && seen.insert($0).inserted }
        let onBar = Set(order)
        // Each off-bar key hangs on the nearest preceding key of `visible` that is on the bar (nil = leading); runs keep relative order.
        var leading: [ItemKey] = []
        var after: [ItemKey: [ItemKey]] = [:]
        var anchor: ItemKey?
        for k in visible {
            if onBar.contains(k) { anchor = k }
            else if let a = anchor { after[a, default: []].append(k) }
            else { leading.append(k) }
        }
        var out = leading
        for k in order { out.append(k); out += after[k] ?? [] }
        return out
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

    /// The user's Retry ("Re-apply layout"): clears failures; the core gives the engine its budget and the one strip grant back (`userRetry`).
    public func userRetry() async {
        userEditPassOwed = true   // Re-apply marks the next pass as the user's (a full, unrestricted one: an old edit's window is over)
        userEditChain = false
        await clearFailures()
        coreStep(.userRetry, "userRetry", site: "userRetry() (Re-apply layout)")   // ejb.15 event userRetry
        await flushCoreDisplay()
    }

    /// The Arrange "Try again" of one row: forgets the key's membership failure and gives it a fresh wait. The core's `retryKey` makes the key owed again.
    public func retry(key: ItemKey) async {
        failures[key] = nil; strikes[key] = nil
        positionWaitSince[key] = nil; positionTimedOut.remove(key)   // 9o9.24: a fresh 60 s wait
        log("engine: retry \(key): attempts cleared")
        userEditChain = true; userEditPassOwed = true   // Try again is the user's own move for its next pass only
        if !core.keys.isChevron(key), let id = try? core.keys.intern(key) { coreStep(.retryKey(id), "retryKey", site: "retry(key:) (Try again)"); await flushCoreDisplay() }   // ejb.15 event retryKey
        await publish { s in
            if case .cannotPlace? = s.perItem[key] { s.perItem[key] = .pending }
        }
        requestReconcile(reason: "retry", userInitiated: true)
    }

    /// "Pause Sommelier": observation continues, no actuator call is made. Never persisted. Resuming plans again at once.
    public func setUserPaused(_ on: Bool) async {
        guard (userPausedBox.value != nil) != on else { return }
        userPausedBox.value = on ? "paused by you" : nil
        log(on ? "engine: paused: Sommelier paused by you" : "engine: resumed by you")
        await publish { $0.userPaused = on }
        if !on { requestReconcile(reason: "resumed", userInitiated: true) }
    }

    /// The Arrange window reports a drag hovering its drop targets; no actuator call is made while it lasts. Effective at once.
    public nonisolated func setArrangeDragInFlight(_ on: Bool) { arrangeDragBox.set(on, now: Date()) }

    private func windowSeconds(_ d: Duration) -> TimeInterval { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    /// Nil when the user is not interacting. Otherwise waits up to `busyWait`; returns (reason, waited) where `reason` is nil if it cleared.
    private func interactionBlock() -> String? {
        if handDragBox.active(now: Date(), maxAge: windowSeconds(config.arrangeDragMaxAge)) { return LiveInteractionSource.handDragReason }
        if arrangeDragBox.active(now: Date(), maxAge: windowSeconds(config.arrangeDragMaxAge)) { return "an Arrange drag is in flight" }
        guard let raw = interaction?.blockingReason() else { menuOpenSince = nil; menuIgnored = false; return nil }
        guard raw == LiveInteractionSource.menuOpenReason else { menuOpenSince = nil; menuIgnored = false; return raw }
        // 9o9.8: a pop-up window that stays "open" for menuOpenMaxWait is not a menu the user is using; ignore it until it clears.
        let t = config.now()
        if let last = menuLastSeen, t.timeIntervalSince(last) > 2 * windowSeconds(config.interactionRetryMax) {
            menuOpenSince = nil; menuIgnored = false   // it went away unobserved and came back
        }
        menuLastSeen = t
        if menuOpenSince == nil { menuOpenSince = t }
        if !menuIgnored, t.timeIntervalSince(menuOpenSince!) > windowSeconds(config.menuOpenMaxWait) {
            menuIgnored = true
            log("engine: a pop-up window has been open for 2 min; ignoring it for ordering")
        }
        return menuIgnored ? nil : raw
    }

    /// While locked / asleep nothing is observed: the pass ends before observing and waits for a wake signal or the long retry.
    private func dormantReason() -> String? {
        guard let r = interactionBlock() else { return nil }
        return (r == LiveInteractionSource.screenLockedReason || r == LiveInteractionSource.displayAsleepReason) ? r : nil
    }

    /// 9o9.8: unlock / display wake / session active. Ends the pause backoff and runs a pass now.
    public func interactionResumed() {
        pauseRetry = nil
        delayed[Self.interactionPauseReason]?.cancel()
        delayed[Self.interactionPauseReason] = nil
        requestReconcile(reason: "wake signal")
    }

    private enum Quiet { case clear, waitedThenClear, blocked(String) }

    private func awaitQuiet() async -> Quiet {
        guard var reason = interactionBlock() else {
            await clearPauseNotice()
            return .clear
        }
        var waited = Duration.zero
        while waited < config.busyWait {
            await sleep(config.busyPoll)
            waited += config.busyPoll
            guard let r = interactionBlock() else { await clearPauseNotice(); return .waitedThenClear }
            reason = r
        }
        return .blocked(reason)
    }

    private func clearPauseNotice() async {
        lastPauseLogged = nil
        pauseRetry = nil
        if pausePublished { pausePublished = false; await publish { $0.pauseReason = nil } }
    }

    /// Ends the pass `.paused` because the user is interacting: the reason is logged once per episode, nothing is struck.
    private func endPausedForInteraction(_ reason: String, _ r: PassReport) async -> PassReport {
        if lastPauseLogged != reason { log("engine: paused: \(reason)"); lastPauseLogged = reason }
        pending = false
        pausePublished = true
        await publish { $0.inFlight = nil; $0.pauseReason = reason }
        let delay: Duration
        if reason == LiveInteractionSource.screenLockedReason || reason == LiveInteractionSource.displayAsleepReason {
            delay = max(config.interactionRetry, config.interactionRetryMax)
        } else if let prev = pauseRetry {
            delay = max(prev, min(prev * 2, config.interactionRetryMax))
        } else {
            delay = config.interactionRetry
        }
        pauseRetry = delay
        lastPauseRetryDelay = delay
        scheduleReconcile(after: delay, reason: Self.interactionPauseReason)
        return await finish(r, converged: false)
    }
    static let interactionPauseReason = "interaction pause"

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
    /// TESTS ONLY: exactly one REGULAR pass (a poll: no user edit behind it), not subject to `minPassInterval`. The user's pass and its chained pass are
    /// `reconcileOnce()`; this is what ends them.
    func regularPassForTests() async -> PassReport {
        while inPass { await Task.yield(); await sleep(.milliseconds(10)) }
        requestedAt = .now; requestReason = "poll"; requestUserInitiated = false; pending = false
        return await runPass(scheduled: true)
    }
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
        let wait = config.delaySleep
        delayed[reason] = Task { [weak self] in
            await wait(delay)   // wall clock by default (the injected `sleep` paces passes); tests inject `Config.delaySleep`
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
        notReadyUntil = config.instant() + settle
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
        core.lastCompletePile = nil   // ejb.19: the pile from before the sleep proves nothing; two agreeing complete reads are needed again
        log("didWake: reconcile in \(settle)")
        scheduleReconcile(after: settle, reason: "wake")
    }

    /// Display reconfiguration (ejb.27): like a wake, the pile read before it proves nothing, so two agreeing complete reads are needed again.
    public func screensChanged() {
        core.lastCompletePile = nil
        scheduleReconcile(after: .seconds(1), reason: "display change")
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
                let wait = config.minPassInterval - last.duration(to: config.instant())
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
        let pd = pendingDisplay   // taken before the suspension, so a later step's display is never overwritten by this one
        let pe = pendingCoreError
        pendingDisplay = nil; pendingCoreError = nil
        await MainActor.run {
            if let pd { s.coreDisplay = pd }
            switch pe {
            case .set(let m)?: s.lastError = .decision(m)
            case .clear?: if case .decision? = s.lastError { s.lastError = nil }
            case nil: break
            }
            body(s)
        }
    }

    /// Puts a display computed by `coreStep` on `EngineState` (a suspension point: call it only where the caller may suspend).
    func flushCoreDisplay() async {
        settleCoreDisplay(site: "flush")
        guard pendingDisplay != nil || pendingCoreError != nil else { return }
        await publish { _ in }
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

    /// 9o9.25: parked keys the layout lists Visible that Control Center hides (`isAllowed == false`) and the user did not place through
    /// Sommelier. Placement-unknown keys never qualify (nothing proves they are hidden).
    private func systemHiddenVisible(_ obs: ObservedOrder) -> [(key: ItemKey, tracked: String)] {
        var out: [(key: ItemKey, tracked: String)] = []
        for k in obs.parked where layout.section(of: k) == .visible && !userPlacedVisible.contains(k) && !obs.placementUnknown.contains(k) {
            guard let tk = resolverSnapshot?.trackedKey(for: k, bundleID: itemInfo[k]?.ownerBundleID), config.trackedAllowed(tk) == false else { continue }
            out.append((k, tk))
        }
        return out
    }

    /// 9o9.25: a change the user made outside Sommelier is adopted into the record (like a hand drag, 9o9.7): a Visible key that Control
    /// Center hides and the user did not place here moves ONCE to the end of Hidden (hide-unit siblings along), the layout is saved and
    /// a transient notice is published. Skipped while the upgrade adoption or a hand-drag adoption is pending, and under a transient reveal.
    private func adoptSystemSettingsHides(_ obs: ObservedOrder) async {
        guard !layout.pendingAdoption, handAdopt == nil else { return }
        let adoptObs = withoutTransient(obs)
        let onBar = Set(adoptObs.onBar)
        var found: [(key: ItemKey, tracked: String)] = []
        for f in systemHiddenVisible(adoptObs) {
            // A drawn sibling means the user did not hide the whole unit: adopting would hide an item they left on the bar.
            let unit = rule.unit(of: f.key)
            if let sib = layout.allKeys.first(where: { $0 != f.key && rule.unit(of: $0) == unit && onBar.contains($0) }) {
                log("layout: not adopting System Settings hide of \(f.key): its sibling \(sib) is on the bar")
                continue
            }
            found.append(f)
        }
        guard !found.isEmpty else { return }
        var l = layout
        var moved: [ItemKey] = []
        for (k, tk) in found {
            guard l.section(of: k) == .visible else { continue }
            for m in l.move(k, to: .hidden, units: rule) where !moved.contains(m) { moved.append(m) }
            log("layout: adopted System Settings: \(k) is hidden there; moved to Hidden")
            log("engine: Control Center \(tk) isAllowed=false; evidence: \(evidence[k] ?? "none")")
        }
        guard !moved.isEmpty else { return }
        layout = l
        userPlacedVisible.subtract(moved)
        do { try store.save(l) } catch { log("cannot save layout: \(error)") }
        _ = await publishLayout(l)
        coreSyncRecord(site: "adoptSystemSettingsHides (System Settings hides)")   // ejb.15: engine-made record change = userEdit(rec, [])
        let namer = RowNameRule.Namer(layout: layout, items: itemInfo)
        let names = moved.map { itemInfo[$0] != nil ? namer.name($0) : $0.description }
        systemNoticeSerial += 1
        let serial = systemNoticeSerial
        let text = SystemSettingsNotice.text(names)
        await publish { $0.systemSettingsNotice = text }
        let lifetime = config.noticeLifetime
        Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            await self?.clearSystemNotice(serial)
        }
    }

    private func clearSystemNotice(_ serial: Int) async {
        guard serial == systemNoticeSerial else { return }
        await publish { $0.systemSettingsNotice = nil }
    }

    private func makePlan(_ obs: ObservedOrder) -> Plan {
        refreshHideUnits()
        reevaluateRefused(obs)
        pruneUnsettled(obs)
        var planObs = withoutTransient(effective(obs))
        userPlacedVisible.subtract(planObs.onBar)   // a user placement that came true is spent: a later hide by someone else stands
        // gdu.79: parked keys the planner must not show. (1) placement unknown: nothing proves they are hidden, so there is nothing to
        // show. (2) listed visible but not by the user while Control Center says isAllowed == false: a layout from disk / init-from-current
        // / a scan must never un-hide an item the user hid. Both come back as explicit skips (neutral), never as an action.
        var guarded: [(key: ItemKey, why: String)] = []
        for k in planObs.parked where planObs.placementUnknown.contains(k) {
            guarded.append((k, "placement unknown (app-side frame only, no hosted element)"))
        }
        // 9o9.25: such keys are normally adopted into Hidden before planning (`adoptSystemSettingsHides`); this guard only covers the
        // passes where that adoption is deferred (upgrade adoption pending, a hand drag being read): never show them meanwhile.
        for (k, _) in systemHiddenVisible(planObs) {
            guarded.append((k, "Hidden in Control Center. Drop it into Visible (or use Move to Visible) to show it."))
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
        // Membership only: order is decided by the core (`DecisionCore.step`), never here.
        var p = Reconciler().plan(observed: planObs, layout: layout, capabilities: effectiveCaps(), showHiddenSection: showHidden, showAlwaysHidden: showAlways, units: rule)
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
        return p
    }

    /// The fold memory's evidence (membership only), one call per read: a fresh chevron stores its pile and folded-parked keys; any other chevron
    /// (carried, stale) keeps the memory; three consecutive FULLY read chevronless reads (`complete`, or `completeExceptSelfPositioning`) drop it.
    /// Passes and quiet polls both feed it; the count is also what tells a quiet poll when the core has seen enough reads to need a pass (`notePollScan`).
    private func noteFoldEvidence(_ obs: ObservedOrder, completeness: ReadCompleteness) {
        if obs.overflowChevron != nil { foldMemory = FoldMemory(systemOverflow: obs.systemOverflow, foldedParked: obs.foldedParked); chevronlessReads = 0; return }
        if obs.hasChevron { chevronlessReads = 0; return }
        guard completeness == .complete || completeness == .completeExceptSelfPositioning else { chevronlessReads = 0; return }
        chevronlessReads += 1
        guard chevronlessReads >= 3, foldMemory != nil else { return }
        foldMemory = nil
        log("engine: three complete reads without a chevron: the fold memory is dropped")
    }

    /// A quiet poll's scan: evidence only. It goes to the core as a `poll` read (never decides) and feeds the fold memory; while the core still says
    /// "checking" a pass follows (its proof of a not-full bar takes effect one read later). Ignored while a pass runs or is requested.
    public func notePollScan(_ items: [ResolvedItem], completeness: ReadCompleteness,
                             unreadOwners: [UnreadOwner] = [], cachedOwners: [UnreadOwner] = [], ownerEvidence: OwnerEvidence? = nil) async {
        guard !inPass, !pending, requestedAt == nil, loaded, !stopped else { return }
        let o = ObservedOrder(resolved: items)
        // ejb.15 event read, kind poll (wiring plan section 1; EngineTriggers `scanSignature`): a quiet poll's scan is evidence only. One scan is not an
        // agreeing pair, so it is `settled: false`; a poll never decides (the core refuses a move on any read that is not a settled pass read).
        // An empty bar is a non-observation, still told to the core (`observed: false`).
        coreRead(o, bar: BarObservation(items: items, settled: false, completeness: completeness, unreadOwners: unreadOwners,
                                              cachedOwners: cachedOwners, ownerEvidence: ownerEvidence),
                       kind: .poll, vetoed: false, site: "notePollScan (quiet poll)")
        guard !o.onBar.isEmpty else { return }
        noteFoldEvidence(o, completeness: completeness)
        // Three complete chevronless reads are the core's proof of a not-full bar (it takes effect on the NEXT read, and releases a hold / a spent budget): until
        // the published status says "matches" a pass follows to read and publish it (bounded; a quiet bar is otherwise never re-read).
        if chevronlessReads >= 3, let shown = core.display?.status, shown != .matches, checkingFollowUps < Self.maxCheckingFollowUps {
            checkingFollowUps += 1
            requestReconcile(reason: "poll")
        } else if core.display?.status == .matches { checkingFollowUps = 0 }
    }
    static let maxCheckingFollowUps = 6

    /// The fold memory applied to a read whose chevron is not fresh: its pile is the stale chevron's own, joined with the last fresh one's.
    /// The chevron key stands for the fold, so a folded parked item is never shown on a carried or stale scan (membership only).
    private func effective(_ obs: ObservedOrder) -> ObservedOrder {
        guard obs.overflowChevron == nil, let f = foldMemory else { return obs }
        var o = obs
        let onBar = Set(obs.onBar)
        o.systemOverflow = obs.systemOverflow.union(f.systemOverflow.intersection(onBar))
        o.foldedParked = obs.foldedParked.union(f.foldedParked.intersection(Set(obs.parked)))
        if let c = obs.onBar.first(where: { $0.isOverflowChevron }) { o.overflowChevron = c }
        return o
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
        let folded = obs.systemOverflow.union(obs.foldedParked)   // gdu.144: a folded key's failed pull-out stays failed (it is still behind «) until Retry or the next edit
        for k in Array(failures.keys) where !acting.contains(k) && !failedThisPass.contains(k) && transientReveals[rule.unit(of: k)] == nil && !folded.contains(k)
            && (obs.onBar.contains(k) || obs.parked.contains(k))
            && ArrangeSections.placementMatches(k, layout: layout, observed: obs, showHiddenSection: showHidden, showAlwaysHidden: showAlways) {
            failures[k] = nil; strikes[k] = nil
            log("cleared failure for \(k): now in place")
        }
    }

    private func statuses(_ obs: ObservedOrder, _ plan: Plan) -> [ItemKey: ItemStatus] {
        clearFailuresInPlace(obs, plan)
        var out: [ItemKey: ItemStatus] = [:]
        // 9o9.11: an overflowed key is `.notFitting` while the record leaves it behind the chevron (every key left of it in the record is
        // also overflowed or not on the bar). One the record places right of a drawn key is not "not fitting": it is out of place
        // (a pull-out / push-in is planned for it, or it waits its turn) and reads as in place only if the order check says so.
        for k in obs.onBar + obs.parked {
            // A key whose record position is inconsistent with the fold (pile key with a drawn key left of it, drawn key with a pile key
            // right of it) is never `.inPlace`: it is pending until the crossing is done (or a skip/failure says otherwise below).
            out[k] = ArrangeSections.foldBaseStatus(k, layout: layout, observed: obs)
        }
        for a in plan.actions { out[Self.key(of: a)] = .pending }
        for k in obs.onBar + obs.parked where transientReveals[rule.unit(of: k)] != nil { out[k] = .pending }
        var waiting = Set<ItemKey>()
        let now = ContinuousClock.now
        // Membership skips (cannot be hidden / shown, folded parked, stale hide, ...): a neutral `.unsupported` with the reason. (The order planner's
        // skips are gone: the core's rows say what happens to an order move.)
        for s in plan.skipped where failures[s.key] == nil && out[s.key] != .notFitting && s.reason != Reconciler.foldedParkedSkipReason {
            out[s.key] = .unsupported(s.reason)
        }
        // D5 (9o9.24, gdu.105): a Visible key on the bar whose position is not corroborated (uncorroborated or stale) is on a 60 s timer:
        // before it, its base status stands (Arrange shows ~ with the honest text); after it, it is unsupported (a warning with Try again).
        // The timer is wall-clock, outside the core's model; it may only DOWNGRADE a row (CoreRowRule.reconcile).
        let skippedKeys = Set(plan.skipped.map(\.key))
        let quiet = obs.uncorroborated.union(obs.staleOnBar).intersection(obs.onBar).subtracting(obs.systemOverflow)
            .subtracting(obs.overflowChevron.map { [$0] } ?? []).subtracting(skippedKeys).subtracting(handDragUnverified)   // held by the planner (no skip, but not "quiet")
        for k in quiet where layout.visible.contains(k) && failures[k] == nil && out[k] != .notFitting {
            let since = positionWaitSince[k] ?? now
            positionWaitSince[k] = since
            waiting.insert(k)
            if since.duration(to: now) > config.positionWaitTimeout {
                if positionTimedOut.insert(k).inserted { log("\(k): position not corroborated for \(config.positionWaitTimeout); marked unsupported until the layout changes or Retry") }
                out[k] = .unsupported("could not corroborate its position on the bar for \(Self.seconds(config.positionWaitTimeout)) s: " + Reconciler.uncorroboratedSkipReason)
            } else if !ArrangeSections.placementMatches(k, layout: layout, observed: obs, showHiddenSection: showHidden, showAlwaysHidden: showAlways) {
                // out of place on an unreadable slot: waiting for a trustworthy read (a display state; the core never moves an untrusted key, and its row decides the verdict)
                out[k] = .waitingForPosition(obs.staleOnBar.contains(k) ? Reconciler.staleSkipReason : Reconciler.uncorroboratedSkipReason)
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

    private func publishObserved(_ rawObs: ObservedOrder, _ plan: Plan? = nil) async {
        let obs = effective(rawObs)   // gdu.144 B1: a carried scan shows the last fresh pile
        let st = plan.map { statuses(obs, $0) }
        let info = itemInfo
        hasObservation = true
        let pc = Set(unconfirmed.keys)
        let hu = rule
        // 9o9.5: the plan's partition goes out with its statuses (after `statuses` cleared in-place failures, so `held` is current).
        let summary = plan.map { _ in PlanSummary() }   // only `passStarted` is published (stamped inside publish): the signal the Arrange tracker waits for
        await publish { s in
            s.observed = obs; s.items = info; s.hideUnits = hu; s.observationSettled = true; s.pendingConfirmation = pc
            if let st { s.perItem = st }
            if var summary { summary.passStarted = s.passesStarted; s.lastPlan = summary }
        }
    }

    private func setStatus(_ k: ItemKey, _ st: ItemStatus, inFlight: PlannedAction?) async {
        await publish { s in s.perItem[k] = st; s.inFlight = inFlight }
    }

    private func finish(_ report: PassReport, converged: Bool) async -> PassReport {
        let now = Date()
        // Observed reveal state, only from a pass that completed its work (converged or incomplete) and from what it observed.
        // The core's word: "converged" is published only when the core's status says the menu bar matches the record (checking, moving, differs: not converged).
        let coreMatches: Bool = { switch core.display?.status { case .matches?: return true; default: return false } }()
        let judge = report.outcome == .converged || report.outcome == .incomplete
        let lay = layout, wantHidden = showHidden, wantAlways = showAlways
        await publish { s in
            s.inFlight = nil; s.lastPassAt = now; s.passCount += 1; s.passSequence += 1; s.isConverged = converged && coreMatches
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
            lastBarObs = r
            // The fold memory's chevronless count restarts on a chevron in ANY read (settled or not) and on any read that is not fully read.
            if o.hasChevron || (r.completeness != .complete && r.completeness != .completeExceptSelfPositioning) { chevronlessReads = 0 }
            // ejb.15 wiring plan section 1 (read, `observed`): an empty bar is a non-observation, still a read the core is told about (evidence only).
            if o.onBar.isEmpty { coreRead(o, bar: r, kind: .pass, vetoed: true, site: "observeOnce: empty bar"); return .failure(.empty) }
            if !r.settled, !allowUnsettled { coreRead(o, bar: r, kind: .pass, vetoed: true, site: "observeOnce: scans disagree"); return .failure(.noAgreement(scans: r.scans)) }
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
        if o.hasChevron { chevronlessReads = 0 }
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
        // 9o9.12: a snapshot taken with the « strip open describes a bar that no longer exists once the actuator has closed the strip again
        // (stacked frames are back): never adopt it directly; observe afresh. A strip the user left open costs one full observation.
        if let snap, !snap.stripExpanded {
            let resolved = resolveSnapshot(snap)
            let o = ObservedOrder(resolved: resolved)
            if o.hasChevron { chevronlessReads = 0 }
            if !o.onBar.isEmpty {
                // wiring plan section 1: the actuator's post-move snapshot is a pass read with settled:false, evidence only
                coreRead(o, bar: BarObservation(items: resolved, settled: false, completeness: snap.completeness, unreadOwners: snap.unreadOwners,
                                                      cachedOwners: snap.cachedOwners, ownerEvidence: snap.ownerEvidence),
                               kind: .pass, vetoed: true, site: "adopt: post-move snapshot")
                itemInfo = ItemInfo.merge(previous: itemInfo, fresh: ItemInfo.index(from: resolved), retaining: ItemInfo.staleOnlyKeys(from: resolved))
                noteEvidence(resolved)
                let serialBefore = pollSignatureSerial
                notePollSignature(resolved)
                if snap.completeness.membershipUsable { noteAdopted(resolved, snap.completeness, serialBefore: serialBefore) }
                obs = o; return true
            }
        }
        switch await observeOnce() {
        case .success(let (o, _)):
            if let b = lastBarObs { coreRead(o, bar: b, kind: .pass, vetoed: true, site: "adopt: post-move scan") }   // evidence only (section 1)
            obs = o; return true
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
            coreFeedVetoed(o, site: "observeForPass: unsettled read (evidence only)")   // wiring plan section 1: an unsettled pass read is still a read
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
        if let who = conflictBox.value { log("conflicting manager running (\(who)); pass ends before the next actuator call") }
        else { log("engine: paused: Sommelier paused by you; pass ends before the next actuator call") }
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
        coreSettleStraggler(site: "runPass (end of pass)")   // ejb.15: exactly one moveResult per emitted action, whatever path ended the pass
        // When the user's chain ends, however it ends (spent, paused, failed, converged), the core is told (`passBoundary`): nothing the user asked for
        // can fire later. (Only the drain chains: `pending` is set by a chained pass, and a request that arrived meanwhile is a regular pass.)
        // An owed user pass (`userEditPassOwed`) means a drop or Re-apply arrived while THIS pass ran (it superseded it): the chain is not over, its
        // pass has not run yet, and a boundary now would drop the user's owed moves in the core (the drop was lost). Its own pass ends the chain.
        if userEditChain, draining, !pending, !userEditPassOwed {
            coreStep(.passBoundary, "passBoundary", site: "runPass (a user chain ends)")   // ejb.15 event passBoundary: the user's chain is over
            // What the chain did not finish is the core's business: ONE regular pass (its budget and gates apply) makes it, so the status never
            // sticks at "Working…" / "Moving" with nobody left to move anything. A regular pass is never part of the chain, so this cannot repeat.
            if r.actionCount > 0 || core.display?.status == .moving, delayed[Self.userEditFollowUpReason] == nil, !stopped {
                scheduleReconcile(after: config.userEditFollowUp, reason: Self.userEditFollowUpReason)
            }
        }
        await flushCoreDisplay()   // ejb.16: the last display changes of the pass (after the straggler answer and the user chain's boundary) are published
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
        heldByAdapter = false   // ejb.27: a pass that makes no observation must not reuse the previous pass's value
        let generation = layoutGeneration
        lastStart = config.instant()
        var actionCount = 0
        await publish { $0.passesStarted += 1; $0.orderMoveNotice = nil; $0.orderMoveReasons = [:] }

        var userPass = false
        let hadRequest = requestedAt != nil
        if let r = requestedAt {
            requestedAt = nil
            userPass = requestUserInitiated
            requestUserInitiated = false
            let ms = Self.ms(r.duration(to: .now))
            log("pass started \(ms) ms after \(requestReason)")
            if requestReason == Self.userEditFollowUpReason { chained = 0 }   // gdu.144: the follow-up of an exhausted user chain is a fresh chain of its own
            if ms > 2000 {
                log("pass delayed: \(requestedDuringPass ? "a pass was already running when the request arrived" : "scheduling (min interval or busy wait)") \(ms) ms")
            }
        }

        // The first pass after a user edit IS the user's pass, whichever request starts it (a poll can win the race against the coalescing
        // window of the edit's own request). ONLY an edit (setLayout with moved keys), `userRetry()` and `retry(key:)` mark a user's pass; Resume,
        // a reveal toggle and every other `userInitiated` request are regular passes for this purpose (they may reuse a seed).
        var editPass = false
        if userEditPassOwed { userPass = true; editPass = true; userEditPassOwed = false }
        // A pass started for a user's edit (`editPass`) or chained from it (no request of its own: `!hadRequest`) is part of the user's chain (the
        // core restricts it to the owed keys); the first regular pass (poll, trigger, the follow-up) ends the chain.
        if userEditChain, !editPass, hadRequest { log("engine: user-edit restriction ended (regular pass)"); userEditChain = false }
        // ejb.15 event passBoundary: the start of a REGULAR pass (a request that is not the user's edit pass). Never at the start of the Re-apply pass
        // (`userRetry()` marks it `userEditPassOwed`, so it is an `editPass`), and not for a pass chained from a user's edit (no request of its own).
        if hadRequest, !editPass { coreStep(.passBoundary, "passBoundary", site: "runPassBody (regular pass start)") }

        // (a0) 9o9.8: locked / asleep -> do not observe at all (wake signal or the long retry resumes); otherwise the pause episode is over.
        if let why = dormantReason() { return await endPausedForInteraction(why, PassReport(outcome: .paused)) }
        await expireHandDragAdoption()
        if interactionBlock() == nil { await clearPauseNotice() }

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
                coreFeedVetoed(obs, site: "runPassBody (b) user busy (veto)")
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
            coreFeedVetoed(obs, site: "runPassBody foreign agent restart (veto)")
            let r = PassReport(outcome: .agentRestarted)
            _ = await finish(r, converged: false)
            return r
        }

        // (b2) not ready: asleep, or MenuBarAgent respawned moments ago (its first scans are empty or incomplete, and even an
        // agreed read can lack items). Nothing is planned or done from such an observation; the delayed reconcile follows.
        if sleeping {
            log("system is going to sleep; pass skipped")
            coreFeedVetoed(obs, site: "runPassBody (b2) sleeping (veto)")
            let r = PassReport(outcome: .incomplete)
            _ = await finish(r, converged: false)
            return r
        }
        if conflicted {
            log(conflictBox.value != nil ? "conflicting manager running; pass skipped" : "engine: paused: Sommelier paused by you; pass skipped")
            coreFeedVetoed(obs, site: "runPassBody (b2) conflict/pause (veto)")
            let r = PassReport(outcome: .paused)
            _ = await finish(r, converged: false)
            return r
        }
        if let until = notReadyUntil {
            if config.instant() < until {
                log("agent restarted moments ago; not acting on this observation")
                coreFeedVetoed(obs, site: "runPassBody (b2) not ready (veto)")
                let r = PassReport(outcome: .unsettled)
                _ = await finish(r, converged: false)
                return r
            }
            notReadyUntil = nil
        }

        if generation != layoutGeneration {   // the layout changed during observation
            coreFeedVetoed(obs, site: "runPassBody superseded during observation (veto)")
            return await endSuperseded(PassReport(outcome: .superseded))
        }
        await publish { if case .observe? = $0.lastError { $0.lastError = nil } }
        storeRetryAttempts = 0
        delayed[Self.storeRetryReason]?.cancel(); delayed[Self.storeRetryReason] = nil
        pruneFailures(obs)

        // (c0) upgrade migration (9o9.2): the first complete, settled observation after upgrading from an order-mode layout becomes the record.
        // Only a complete read whose on-bar frames are ALL fresh qualifies (a carried frame, even a recently verified one, may be a wrong slot).
        if observedCompleteness == .complete, obs.staleOnBar.isEmpty, lastCleanBar != obs.onBar {
            lastCleanBar = obs.onBar
            if layout.pendingAdoption { await publish { $0.cleanObservationAvailable = true } }
        }
        if layout.pendingAdoption {
            if observedCompleteness == .complete, obs.staleOnBar.isEmpty { await adoptBarOrder(obs) }
            else {
                let reason = observedCompleteness != .complete ? "the read is \(observedCompleteness.rawValue)" : "on-bar frames are not fresh"
                log("layout: adoption waiting: \(reason) (\(obs.staleOnBar.count) stale frames)")
            }
        }

        if handAdopt != nil { await considerHandDragAdoption(obs) }
        else { await adoptLateHandDrags(obs) }

        await adoptSystemSettingsHides(obs)   // 9o9.25

        // (c) plan
        noteFoldEvidence(obs, completeness: observedCompleteness)
        var plan = makePlan(obs)
        // (d) persist new items, once per pass
        if !plan.newItems.isEmpty {
            for n in plan.newItems { layout.append(n.key, to: n.section) }
            await noteNewItems(plan.newItems)
            do { try store.save(layout) } catch { log("cannot save layout: \(error)") }
            let stamp = await publishLayout(layout)   // a new revision: the engine itself changed the layout (gdu.48)
            coreSyncRecord(site: "runPassBody (d) new items")   // ejb.15: engine-made record change = userEdit(rec, [])
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

        func isConverged() -> Bool { failures.isEmpty && !core.isDown && core.displayError == nil }   // a core that cannot be called never shows "converged" (plan section 5)

        // ejb.15 event read (wiring plan section 1): this pass's settled read goes to the core. The Swift-only vetoes known BEFORE the step may only
        // downgrade it to settled:false (evidence); they never decide and never skip feeding the read: pending adoption, hand-drag adoption, a
        // transient reveal, a reveal pass, a membership batch this pass (assumption 4). (Pause, conflict, sleep, not ready, user busy and a
        // superseded pass exit earlier and feed the read the same way, `coreFeedVetoed`.)
        // The user's interaction (a menu open, the mouse down, a modifier held, locked, asleep, an Arrange drag) is a pause: known BEFORE the step, so it
        // is a veto of the read, never an action answered `busy` afterwards (a `busy` answer would make the core `skip` the key until a user event).
        // The wait for the user to be quiet is the old one (`awaitQuiet`); only a pass whose last word from the core was not "matches" (it may have order
        // work) waits, as before; a bar the core last found matching is not held up by an open menu.
        let coreIdle: Bool = { switch core.display?.status { case .matches?, .matchesExcept?: return true; default: return false } }()
        if plan.phase != .membership, !coreIdle, interactionBlock() != nil {
            switch await awaitQuiet() {
            case .clear: break
            case .waitedThenClear:
                coreFeedVetoed(obs, site: "runPassBody (c) user interaction, waited (veto)")
                if draining { pending = true }   // the observation is old after the wait: a fresh pass re-observes
                await publish { $0.inFlight = nil }
                let r = report(.incomplete)
                return await finish(r, converged: false)
            case .blocked(let why):
                coreFeedVetoed(obs, site: "runPassBody (c) user interaction (veto)")
                await publish { $0.orderMoveNotice = nil; $0.orderMoveReasons = [:] }
                return await endPausedForInteraction(why, report(.paused))
            }
        }
        let coreVeto = plan.phase == .membership || layout.pendingAdoption || handAdopt != nil || !transientReveals.isEmpty || showHidden || showAlways
        var coreAction: Action?
        if let b = lastBarObs { coreAction = coreRead(obs, bar: b, kind: .pass, vetoed: coreVeto, site: "runPassBody (c) pass read").first }
        // ejb.19: the adapter held a scanner-settled read (no earlier complete pile to agree with, or the pile moved): the core made no move on it, so
        // one bounded follow-up pass supplies the second read (a stalled engine would wait for a trigger). Bounded by `maxChainedPasses` in a row.
        if coreAction == nil, heldByAdapter {
            if heldPasses < config.maxChainedPasses, draining, !stopped { heldPasses += 1; pending = true }
        } else if lastBarObs != nil { heldPasses = 0 }

        // No core move and no membership work: the pass ends. (A pass with membership work goes on to (g); its read was vetoed, so the core made no move.)
        // The core's word decides what is shown (its status); here the pass only reports that it did all it was asked.
        if coreAction == nil, plan.phase == .converged {
            chained = 0; allFailedStreak = 0
            let ok = isConverged()
            _ = await finish(report(ok ? .converged : .incomplete), converged: ok)
            return report(ok ? .converged : .incomplete)
        }

        func abort(_ o: PassReport.Outcome) async -> PassReport {
            let r = report(o)
            return await finish(r, converged: false)
        }

        // (f2) gdu.80: on a full bar (a chevron) the order phase needs a settled overflow set; a reveal never orders.

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
            if handAdopt != nil {   // 9o9.7: the adoption must read a bar nobody but the user touched; membership waits for it
                log("engine: membership change deferred until the menu bar drag is adopted")
                scheduleReconcile(after: .seconds(2), reason: "hand drag retry")
                return await abort(.incomplete)
            }
            if conflicted { return await pausedMidPass(report(.paused)) }
            switch await awaitQuiet() {   // 9o9.4: no actuator call while the user is interacting
            case .clear: flightBox.begin()   // 9o9.7: at once (see the order loop)
            case .waitedThenClear:
                if draining { pending = true }   // the observation is old after the wait: a fresh pass re-observes
                return await abort(.incomplete)
            case .blocked(let why): return await endPausedForInteraction(why, report(.paused))
            }
            // The bar before the write: a membership change on a full bar (or one that shows an item) leaves the order to be read afresh by the next pass.
            let fullBeforeWrite = obs.hasChevron || recentReads.suffix(2).contains(where: \.hasChevron)
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
            flightBox.end()
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
            // gdu.80 / ejb.15 assumption 4: the membership batch changed what fits, so nothing is dragged in this pass (its read was fed settled:false).
            // A show, or any change on a full bar, may have moved what the order depends on: a follow-up pass reads the changed bar and the core orders
            // (bounded by `maxChainedPasses`). A plain hide on a bar with no chevron leaves nothing to read: the pass is converged.
            if plan.phase == .converged, !((batch.values.contains(false) && !(showHidden || showAlways)) || fullBeforeWrite || obs.hasChevron) {
                let ok = isConverged()
                // converged as far as this pass can tell; one bounded follow-up pass lets the core read the settled bar (this pass's read was vetoed) and publish its word
                if ok, draining, chained < config.maxChainedPasses, !stopped { chained += 1; pending = true }
                _ = await finish(report(ok ? .converged : .incomplete), converged: ok)
                return report(ok ? .converged : .incomplete)
            }
            if plan.phase == .converged { log("order deferred: membership changed this pass") }
            // Still membership work (agent moved things) or a changed bar to read: the next pass handles it after it settles.
            return await rescheduleIncomplete(report(.incomplete), converged: false)
        }

        // (h) order phase: ONE move per pass, and only from the core's Action (ejb.15). Nothing else in the engine decides an order move.
        var orderMoves = 0
        var moveFailed = false   // a failed drag ends the pass's order phase (the core strikes the key; no hammering within one pass)
        while true {   // one iteration per core Action; only `Config.maxOrderMovesPerPass > 1` (tests) loops, production makes one move per pass
        guard let ca = coreAction else {
            // The core made no move. (If the core could not be called, `lastError` says so and the pass is never "converged".)
            if orderMoves == 0 {
                await publish { $0.inFlight = nil; $0.orderMoveNotice = nil; $0.orderMoveReasons = [:] }
                return await abort(.incomplete)
            }
            break
        }
        guard let (key, rel) = core.relation(ca) else {
            // the core named a key this engine never interned: nothing to drag, answered at once (no mouse event: not an attempt)
            log("engine: the core's move names an unknown key; not performed")
            coreResult(ca, .failed, posted: false, site: "order phase: unknown key")
            return await abort(.incomplete)
        }
        let action: PlannedAction = .move(key, rel)
        // Swift-only vetoes known only AFTER the step: each answers the emitted action with `busy, posted: false` (the core re-arms nothing it did not owe).
        if generation != layoutGeneration {
            coreResult(ca, .busy, posted: false, site: "order phase: superseded (veto)")
            log("layout changed before the order move; dropping it")
            return await endSuperseded(report(.superseded))
        }
        if conflicted {
            coreResult(ca, .busy, posted: false, site: "order phase: conflict/pause (veto)")
            return await pausedMidPass(report(.paused))
        }
        if sleeping {
            coreResult(ca, .busy, posted: false, site: "order phase: sleeping (veto)")
            log("system is going to sleep; pass ends before the move")
            await publish { $0.inFlight = nil }
            return await abort(.incomplete)
        }
        guard actionCount < config.maxActionsPerPass else {
            coreResult(ca, .busy, posted: false, site: "order phase: maxActionsPerPass (veto)")
            log("maxActionsPerPass reached")
            return await rescheduleIncomplete(report(.incomplete), converged: false)
        }
        switch await awaitQuiet() {   // 9o9.4: no actuator call while the user is interacting
        case .clear: flightBox.begin()   // 9o9.7: at once, so a mouse-down after the gate check is never read as a hand drag
        case .waitedThenClear:
            coreResult(ca, .busy, posted: false, site: "order phase: awaitQuiet waited (veto)")
            if draining { pending = true }
            await publish { $0.inFlight = nil }
            return await abort(.incomplete)
        case .blocked(let why):
            coreResult(ca, .busy, posted: false, site: "order phase: awaitQuiet blocked (veto)")
            await publish { $0.orderMoveNotice = nil; $0.orderMoveReasons = [:] }
            return await endPausedForInteraction(why, report(.paused))
        }
        if generation != layoutGeneration {   // the layout changed while we waited for the user to be quiet
            flightBox.end()
            coreResult(ca, .busy, posted: false, site: "order phase: superseded while waiting (veto)")
            return await endSuperseded(report(.superseded))
        }
        do {   // gdu.89: say why this drag happens (status line, row tooltip, log)
            let namer = RowNameRule.Namer(layout: layout, items: itemInfo)
            func name(_ k: ItemKey) -> String { itemInfo[k] != nil ? namer.name(k) : k.description }
            var target: ItemKey?
            switch rel { case .before(let t), .after(let t): target = t; default: break }
            let text = OrderMoveNotice.text(name: name(key), relation: rel, target: target.map(name))
            switch rel {
            case .after(let t): log("order: moving \(key) after \(t) (core action\(ca.user ? ", the user's" : ""))")
            case .before(let t): log("order: moving \(key) before \(t) (core action\(ca.user ? ", the user's" : ""))")
            case .leftmost, .rightmost: break
            }
            log("order: why: \(text); observed around \(key): \(DropTrace.around(key, in: obs.onBar))")   // gdu.102
            await publish { $0.orderMoveNotice = text; $0.orderMoveReasons[key] = text }
        }
        log("engine: move subject evidence: \(evidence[key] ?? "none")")   // gdu.94
        await setStatus(key, .moving, inFlight: action)
        // THE single actuator.move call site: nothing else in the engine moves an item in the order.
        await actuator.setChurnZone(SystemOverflowRule.churnZone(recentReads))
        await actuator.setRecordOrder(layout.visible)   // 9o9.19: a crossing is verified by the fold rule against the record
        await actuator.setEngineInitiated(!ca.user)     // the strip-open refusal backstop (LiveActuator): only the user's own move may open the strip
        await actuator.setSingleDrag(true)              // assumption 5: ONE physical drag per move, on every bar
        await actuator.setStripAllowed(ca.strip)        // assumption 7: a move that needs the strip is refused unless the core licensed it
        let result = await actuator.move(key, relation: rel)
        flightBox.end()
        actionCount += 1
        let touchedMouse = await actuator.lastMoveTouchedMouse
        let (outcome, posted) = OutcomeMapper.map(result, touchedMouse: touchedMouse)
        coreResult(ca, outcome, posted: posted, site: "order phase: the actuator's answer")   // the one moveResult of this action
        switch result {
        case .verified(let snap):
            consecutiveFailures = 0; allFailedStreak = 0
            guard await adopt(snap, into: &obs) else { return await abort(.observeFailed) }
        case .failed(let e, let snap):
            moveFailed = true
            if await handleFatal(e) { return await abort(.stopped) }
            if e == .userBusy {   // the core re-arms nothing it did not owe (`busy` outcome); no failure, no strike
                _ = await adopt(snap, into: &obs)
                await publishObserved(obs, makePlan(obs))
                if draining { pending = true }
                return await abort(.incomplete)
            }
            // The CORE has judged the outcome (strikes, the hold, the give-up, the next move). Here only the pass-level accounting: a refusal before
            // any drag (the actuator's backstop) or a strip failure is not a failed action; every other failure counts toward `maxConsecutiveFailures`.
            if e.isStripHoldFailure {
                log(e.isStripMoveDidNotHold ? "\(key): a move across the fold did not hold; the core holds every fold move until Retry or your next edit"
                    : e.isStripUnplaceable ? "\(key): the « strip opened but the item could not be pinned down inside it; the core holds every fold move until Retry or your next edit"
                                         : "\(key): the « strip could not be opened; the core holds every fold move until Retry or your next edit")
                if ca.user { markFailed(key, e, fullStrike: true) }   // the user's own pull-out: its row says what happened (display only; the core judged the outcome)
            }
            else if e.isOverflowRefusal || e.isStripNotAllowedRefusal { log("\(key): move refused before any drag (\(e)); not a failure") }
            else { consecutiveFailures += 1; markFailed(key, e) }   // display + the bounded retry chain (`finish`); the core judged the outcome (strikes, give-up)
            guard await adopt(snap, into: &obs) else { return await abort(.observeFailed) }
        }
        orderMoves += 1
        await publishObserved(obs, makePlan(obs))
        // More than one move per pass (a test configuration): the next move is decided by a FRESH SETTLED read of the changed bar, never by the
        // post-move snapshot (which was fed as evidence only).
        if consecutiveFailures >= config.maxConsecutiveFailures { return await stopForFailures(report(.incomplete), obs: obs) }
        guard orderMoves < config.maxOrderMovesPerPass, !moveFailed else { break }
        if conflicted { return await pausedMidPass(report(.paused)) }
        if sleeping {
            log("system is going to sleep; pass ends after the action in flight")
            await publish { $0.inFlight = nil }
            return await abort(.incomplete)
        }
        switch await observeForPass() {
        case .settled(let o): obs = o
        case .end(let r): return r
        }
        if let b = lastBarObs { coreAction = coreRead(obs, bar: b, kind: .pass, vetoed: false, site: "runPassBody (h) next read of a multi-move pass").first } else { coreAction = nil }
        }
        await publish { $0.inFlight = nil; $0.orderMoveNotice = nil; $0.orderMoveReasons = [:] }
        // One order move per pass: the chained pass re-reads the moved bar (a post-move read is evidence only) and the core decides the next move or
        // judges the bar matching. A failed move is chained the same way: the core's strikes decide whether it is tried again (bounded by `maxChainedPasses`).
        if orderMoves >= config.maxOrderMovesPerPass || moveFailed {
            log("order: \(orderMoves) move(s) this pass (maxOrderMovesPerPass \(config.maxOrderMovesPerPass)); the core judges the result on the next pass")
            return await rescheduleIncomplete(report(.incomplete), converged: false)
        }
        // A multi-move pass (tests) whose core has nothing more to move.
        chained = 0; allFailedStreak = 0
        let ok = isConverged()
        _ = await finish(report(ok ? .converged : .incomplete), converged: ok)
        return report(ok ? .converged : .incomplete)
    }

    /// Log line and a transient Arrange-window notice for unknown items placed by the new-item policy (no system notification).
    private func noteNewItems(_ items: [NewItem]) async {
        let namer = RowNameRule.Namer(layout: layout, items: itemInfo)
        let named = items.map { n in (name: itemInfo[n.key] != nil ? namer.name(n.key) : n.key.description, section: n.section) }
        guard let text = NewItemNotice.text(named) else { return }
        log(text)
        noticeSerial += 1
        let serial = noticeSerial
        await publish { $0.newItemNotice = text }
        let lifetime = config.noticeLifetime
        Task { [weak self] in
            try? await Task.sleep(for: lifetime)
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
