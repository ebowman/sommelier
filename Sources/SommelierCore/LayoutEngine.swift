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
        public init() {}
    }

    private let observer: any MenuBarObserver
    private let actuator: any MenuBarActuator
    private let store: any LayoutStore
    private let capabilities: any CapabilityProvider
    private let state: EngineState
    private let busy: @Sendable () -> Bool
    private var itemInfo: [ItemKey: ItemInfo] = [:]
    private let resolveSnapshot: @Sendable (MenuBarSnapshot) -> [ResolvedItem]
    private let sleep: @Sendable (Duration) async -> Void
    private let log: @Sendable (String) -> Void
    public var config: Config

    private var layout: Layout = .empty
    private var showHidden = false
    private var loaded = false
    private var failures: [ItemKey: ActuationError] = [:]
    private var pending = false
    private var draining = false
    private var inPass = false
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
    /// Hide units temporarily revealed on purpose (overflow-panel click-forwarding, gdu.17): hold token per unit.
    private var transientReveals: [HideUnit: Int] = [:]
    private var nextHoldToken = 0
    /// Consecutive passes in which the key failed (1...maxKeyFailures); a key at the limit is no longer retried.
    private var strikes: [ItemKey: Int] = [:]
    private var failedThisPass: Set<ItemKey> = []
    private var allFailedStreak = 0
    private var cutThisPass = false
    /// While set and in the future, observations are not acted on (MenuBarAgent just respawned; its first scans are incomplete).
    private var notReadyUntil: ContinuousClock.Instant?
    /// Between willSleep and didWake: no pass starts, a running pass ends after its current action.
    private var sleeping = false
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
                showHiddenSection: Bool = false, config: Config = Config(),
                agentPID: @escaping @Sendable () -> pid_t? = { nil },
                isOwnAgentPID: @escaping @Sendable (pid_t) -> Bool = { _ in false }) {
        self.agentPID = agentPID; self.isOwnAgentPID = isOwnAgentPID
        self.showHidden = showHiddenSection
        self.observer = observer; self.actuator = actuator; self.store = store; self.capabilities = capabilities
        self.state = state; self.busy = busy; self.resolveSnapshot = resolveSnapshot; self.sleep = sleep
        self.log = log; self.config = config
    }

    // MARK: Public control

    /// Loads the layout (missing file -> empty; corrupt -> `lastError` and the engine stays stopped) and publishes it.
    /// Does not start a pass; call `requestReconcile()`.
    public func start() async {
        do {
            let (l0, moved) = try store.load().validatedReportingNormalization()
            layout = l0
            if !moved.isEmpty {
                NSLog("[Sommelier] layout: all items of an app hide or show at once; moved to visible: %@",
                      moved.map(\.description).joined(separator: ", "))
            }
            loaded = true
            stopped = false
        } catch {
            loaded = false
            stopped = true
            await publish { $0.lastError = .observe("cannot load layout: \(error)") }
            return
        }
        let l = layout, sh = showHidden
        await publish { $0.layout = l; $0.showHiddenSection = sh; $0.lastError = nil }
    }

    public func setLayout(_ new: Layout) async {
        layout = new
        loaded = true
        do { try store.save(new) } catch { log("cannot save layout: \(error)") }
        await publish { $0.layout = new }
        await clearFailures()
        requestReconcile(supersede: true, reason: "setLayout")
    }

    public func setShowHiddenSection(_ on: Bool) async {
        showHidden = on
        await publish { $0.showHiddenSection = on }
        requestReconcile(supersede: true, reason: "setShowHiddenSection")
    }

    /// Forgets suppressed failures and resumes a stopped engine. Does not itself trigger a pass.
    public func clearFailures() async {
        failures = [:]; strikes = [:]; failedThisPass = []; allFailedStreak = 0
        stopped = !loaded   // a layout that never loaded stays stopped until `start()` succeeds or `setLayout`
        chained = 0
        await publish { s in
            s.perItem = s.perItem.filter { if case .failed = $0.value { return false } else { return true } }
            switch s.lastError {
            case .permissionDenied?, .stoppedAfterFailures?, .batchDrift?: s.lastError = nil
            default: break
            }
        }
    }

    /// External trigger. Concurrent triggers coalesce: at most one further pass runs after the current one.
    /// `supersede` (explicit user actions only, never the poll): an observation still in progress is abandoned so the
    /// pass for this request starts at once instead of after up to `AgreedScanObserver.deadline` seconds.
    public func requestReconcile(supersede: Bool = false, reason: String = "trigger") {
        guard loaded else { Task { await self.noteLayoutNotLoaded() }; return }
        guard !stopped, !sleeping else { return }
        if requestedAt == nil || supersede { requestedAt = .now; requestReason = reason; requestedDuringPass = inPass }
        pending = true
        if supersede, let t = observeTask {
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
        requestReconcile(supersede: supersede, reason: reason)
    }

    /// MenuBarAgent respawned: every AX element is invalid and its first scans are empty or incomplete. Observations are not
    /// acted on for `settle`, transient reveal holds are dropped (the revealed element is gone), and ONE reconcile follows.
    public func agentRestarted(settle: Duration = .seconds(2)) async {
        notReadyUntil = .now + settle
        let units = Array(transientReveals.keys)
        transientReveals = [:]
        if !units.isEmpty {
            log("agent restarted: dropping \(units.count) transient reveal hold(s)")
            let keys = itemInfo.keys.filter { units.contains($0.hideUnit) }
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

    // MARK: Scheduling

    private func kick() {
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while pending, !stopped, !sleeping {
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
        let bad = Set(failures.keys), caps = capabilities
        return { k in
            bad.contains(k) ? Capability(canMove: false, canHide: false, reason: "failed earlier") : caps.capability(for: k)
        }
    }

    private func makePlan(_ obs: ObservedOrder) -> Plan {
        var p = Reconciler().plan(observed: withoutTransient(obs), layout: layout, capabilities: effectiveCaps(), showHiddenSection: showHidden)
        // While any unit is revealed for click-forwarding the bar is deliberately in flux (the revealed element can show up
        // as an unknown heuristic item at the unit's frame): the engine plans NOTHING, not even other units, and records no
        // new items. A hold is short-lived; the pass after `endTransientReveal` reconciles.
        if !transientReveals.isEmpty { p.actions = []; p.newItems = []; p.phase = .converged }
        return p
    }

    /// Keys of units under a transient reveal are invisible to the planner: it neither hides nor orders them.
    func withoutTransient(_ obs: ObservedOrder) -> ObservedOrder {
        guard !transientReveals.isEmpty else { return obs }
        var o = obs
        o.onBar = obs.onBar.filter { transientReveals[$0.hideUnit] == nil }
        o.parked = obs.parked.filter { transientReveals[$0.hideUnit] == nil }
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
        let keys = itemInfo.keys.filter { $0.hideUnit == unit }
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
        let keys = itemInfo.keys.filter { $0.hideUnit == unit }
        await publish { s in for k in keys where s.perItem[k] == .pending { s.perItem[k] = .inPlace } }
        requestReconcile(supersede: true, reason: "transient reveal ended")
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

    private func statuses(_ obs: ObservedOrder, _ plan: Plan) -> [ItemKey: ItemStatus] {
        var out: [ItemKey: ItemStatus] = [:]
        for k in obs.onBar + obs.parked { out[k] = obs.systemOverflow.contains(k) ? .notFitting : .inPlace }
        for a in plan.actions { out[Self.key(of: a)] = .pending }
        for k in obs.onBar + obs.parked where transientReveals[k.hideUnit] != nil { out[k] = .pending }
        for s in plan.skipped where failures[s.key] == nil {
            out[s.key] = .unsupported(s.reason)
        }
        for (k, e) in failures where out[k] != nil { out[k] = .failed(e) }
        return out
    }

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
        await publish { s in s.observed = obs; s.items = info; s.observationSettled = true; if let st { s.perItem = st } }
    }

    private func setStatus(_ k: ItemKey, _ st: ItemStatus, inFlight: PlannedAction?) async {
        await publish { s in s.perItem[k] = st; s.inFlight = inFlight }
    }

    private func finish(_ report: PassReport, converged: Bool) async -> PassReport {
        let now = Date()
        await publish { s in
            s.inFlight = nil; s.lastPassAt = now; s.passCount += 1; s.passSequence += 1; s.isConverged = converged
        }
        // A key that failed fewer than `maxKeyFailures` passes in a row is retried by one more pass (bounded by the strikes).
        if !converged, draining, !pending, !stopped, !cutThisPass, chained < config.maxChainedPasses, hasRetryableFailure { chained += 1; pending = true }
        return report
    }

    /// `allowUnsettled`: accept the latest complete read although two scans did not agree (the pass shows it, never acts on it).
    private func observeOnce(allowUnsettled: Bool = false, provisional: Bool = false) async -> Result<(ObservedOrder, Bool), ObserveError> {
        var progress: (@Sendable ([ResolvedItem]) -> Void)?
        if provisional {
            progress = { @Sendable [weak self] items in
                Task { await self?.publishProvisional(items) }
            }
        }
        do {
            let r = try await observer.observeDetailed(progress: progress)
            let o = ObservedOrder(resolved: r.items)
            if o.onBar.isEmpty { return .failure(.empty) }
            if !r.settled, !allowUnsettled { return .failure(.noAgreement(scans: r.scans)) }
            itemInfo = ItemInfo.merge(previous: itemInfo, fresh: ItemInfo.index(from: r.items))
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
        itemInfo = ItemInfo.merge(previous: itemInfo, fresh: ItemInfo.index(from: items))
        let info = itemInfo
        log("first observation published (provisional, unsettled)")
        await publish { s in s.observed = o; s.items = info; s.observationSettled = false }
    }

    /// Updates `obs` from an actuation result; false when no trustworthy observation could be obtained.
    private func adopt(_ snap: MenuBarSnapshot?, into obs: inout ObservedOrder) async -> Bool {
        if await foreignAgentChange() { return false }
        if let snap {
            let resolved = resolveSnapshot(snap)
            let o = ObservedOrder(resolved: resolved)
            if !o.onBar.isEmpty {
                itemInfo = ItemInfo.merge(previous: itemInfo, fresh: ItemInfo.index(from: resolved))
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

    private enum PassObservation { case settled(ObservedOrder), end(PassReport) }

    /// Observes for a pass. Unsettled and failed observations end the pass here (published, nothing planned).
    private func observeForPass() async -> PassObservation {
        let provisional = !hasObservation
        let task = Task { await self.observeOnce(allowUnsettled: true, provisional: provisional) }
        observeTask = task
        let t0 = ContinuousClock.now
        let result = await task.value
        observeTask = nil
        let took = Self.ms(t0.duration(to: .now))
        switch result {
        case .success(let (o, settled)):
            if settled { return .settled(o) }
            hasObservation = true
            let info = itemInfo
            log("observation unsettled; not actuating (\(took) ms)")
            await publish { s in
                s.observed = o; s.items = info; s.observationSettled = false
                if case .observe? = s.lastError { s.lastError = nil }
            }
            if draining { pending = true }
            let r = PassReport(outcome: .unsettled)
            _ = await finish(r, converged: false)
            return .end(r)
        case .failure(let e):
            if e == .superseded {
                log("observation abandoned after \(took) ms for a newer request")
                if draining { pending = true }
                let r = PassReport(outcome: .superseded)
                _ = await finish(r, converged: false)
                return .end(r)
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
            _ = await finish(PassReport(outcome: .observeFailed), converged: false)
            return .end(PassReport(outcome: .observeFailed))
        }
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
        lastStart = .now
        var actionCount = 0
        await publish { $0.passesStarted += 1 }

        if let r = requestedAt {
            requestedAt = nil
            let ms = Self.ms(r.duration(to: .now))
            log("pass started \(ms) ms after \(requestReason)")
            if ms > 2000 {
                log("pass delayed: \(requestedDuringPass ? "a pass was already running when the request arrived" : "scheduling (min interval or busy wait)") \(ms) ms")
            }
        }

        // (a) observe. Observation moves nothing, so it proceeds even while the user is busy; only actuation waits.
        var obs: ObservedOrder
        switch await observeForPass() {
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
        if let until = notReadyUntil {
            if .now < until {
                log("agent restarted moments ago; not acting on this observation")
                let r = PassReport(outcome: .unsettled)
                _ = await finish(r, converged: false)
                return r
            }
            notReadyUntil = nil
        }

        await publish { if case .observe? = $0.lastError { $0.lastError = nil } }
        pruneFailures(obs)

        // (c) plan
        var plan = makePlan(obs)

        // (d) persist new items, once per pass
        if !plan.newItems.isEmpty {
            for n in plan.newItems { layout.append(n.key, to: n.section) }
            await noteNewItems(plan.newItems)
            do { try store.save(layout) } catch { log("cannot save layout: \(error)") }
            let l = layout
            await publish { $0.layout = l }
            plan = makePlan(obs)
        }
        log(Self.describe(plan))
        await publishObserved(obs, plan)   // (e) skipped -> unsupported inside statuses()

        var phaseReached = plan.phase
        var consecutiveFailures = 0
        func report(_ o: PassReport.Outcome) -> PassReport { PassReport(outcome: o, phase: phaseReached, actionCount: actionCount) }

        func isConverged() -> Bool { failures.isEmpty }

        // (f)
        if plan.phase == .converged {
            chained = 0; allFailedStreak = 0
            let ok = isConverged()
            _ = await finish(report(ok ? .converged : .incomplete), converged: ok)
            return report(ok ? .converged : .incomplete)
        }

        func abort(_ o: PassReport.Outcome) async -> PassReport {
            let r = report(o)
            return await finish(r, converged: false)
        }

        // (g) membership phase
        if plan.phase == .membership {
            let caps = effectiveCaps()
            var batch: [ItemKey: Bool] = [:]
            var order: [ItemKey] = []
            for a in plan.actions {
                switch a {
                case .hide(let k):
                    guard caps(k).canHide else { log("engine: refusing hide of \(k): capability forbids"); continue }
                    batch[k] = true; order.append(k)
                case .show(let k): batch[k] = false; order.append(k)
                case .move: break
                }
            }
            guard let first = order.first else { return await abort(.incomplete) }
            let firstAction: PlannedAction = batch[first] == true ? .hide(first) : .show(first)
            await publish { s in for k in order { s.perItem[k] = .pending }; s.inFlight = firstAction }
            let result = await actuator.applyHiddenBatch(batch)
            actionCount += 1
            var err: ActuationError?
            var snap: MenuBarSnapshot?
            switch result {
            case .verified(let s): snap = s
            case .failed(let e, let s): err = e; snap = s
            }
            let respawned = await actuator.lastBatchRespawned
            if respawned { passAgent = agentPID() }   // our own fallback respawn: the pass continues with the new agent
            if let e = err, await handleFatal(e) { return await abort(.stopped) }
            // A batch that reported anything other than success (userBusy and fatal errors aside) ends the pass.
            var driftErr: ActuationError?
            if let e = err, e != .userBusy { driftErr = e }
            guard await adopt(snap, into: &obs) else {
                if let e = driftErr { return await endAfterBatchDrift(e, obs: obs, report: report(.incomplete)) }
                return await abort(.observeFailed)
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
                    let nowHide: Bool
                    switch a { case .hide: nowHide = true; case .show: nowHide = false; case .move: continue }
                    if nowHide == wasHide { markFailed(k, failErr, fullStrike: respawned); failedAny = true }
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
        }

        // (h) order phase
        var lastAction: PlannedAction?
        while plan.phase == .order {
            // Every iteration re-plans from the CURRENT layout, so a setLayout that arrived during a drag is acted on at the
            // next iteration (the rest of the running drag cannot be taken back); log when that happens.
            if let r = requestedAt, requestedDuringPass {
                requestedAt = nil
                log("\(requestReason) picked up by the running pass at its next re-plan, \(Self.ms(r.duration(to: .now))) ms after the request")
            }
            if consecutiveFailures >= config.maxConsecutiveFailures { return await stopForFailures(report(.incomplete), obs: obs) }
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
            await setStatus(key, .moving, inFlight: action)
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
                markFailed(key, e)
                guard await adopt(snap, into: &obs) else { return await abort(.observeFailed) }
            }
            plan = makePlan(obs)
            phaseReached = plan.phase
            await publishObserved(obs, plan)
            if consecutiveFailures >= config.maxConsecutiveFailures { return await stopForFailures(report(.incomplete), obs: obs) }
        }
        await publish { $0.inFlight = nil }
        if plan.phase == .converged {
            chained = 0; allFailedStreak = 0
            let ok = isConverged()
            _ = await finish(report(ok ? .converged : .incomplete), converged: ok)
            return report(ok ? .converged : .incomplete)
        }
        return await abort(.incomplete)
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
        else { err = .observe(String(describing: e)) }
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
