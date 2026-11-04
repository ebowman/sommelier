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
/// Suppression: a key whose actuation failed is a *suppressed* key. The planner is told it can neither move nor hide
/// it (it becomes an anchor), and it is not retried until `setLayout`, `clearFailures()`, or the key disappears from
/// the observed bar (its app quit). This prevents a 10 s poll from re-running a failing agent restart forever.
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

    public init(observer: any MenuBarObserver, actuator: any MenuBarActuator, store: any LayoutStore,
                capabilities: any CapabilityProvider, state: EngineState,
                busy: @escaping @Sendable () -> Bool = { false },
                resolveSnapshot: @escaping @Sendable (MenuBarSnapshot) -> [ResolvedItem],
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                log: @escaping @Sendable (String) -> Void = { _ in },
                showHiddenSection: Bool = false, config: Config = Config()) {
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
        failures = [:]
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
        guard !stopped else { return }
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

    // MARK: Scheduling

    private func kick() {
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while pending, !stopped {
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
        Reconciler().plan(observed: obs, layout: layout, capabilities: effectiveCaps(), showHiddenSection: showHidden)
    }

    private func pruneFailures(_ obs: ObservedOrder) {
        let present = Set(obs.onBar + obs.parked)
        failures = failures.filter { present.contains($0.key) }
    }

    private func statuses(_ obs: ObservedOrder, _ plan: Plan) -> [ItemKey: ItemStatus] {
        var out: [ItemKey: ItemStatus] = [:]
        for k in obs.onBar + obs.parked { out[k] = obs.systemOverflow.contains(k) ? .notFitting : .inPlace }
        for a in plan.actions { out[Self.key(of: a)] = .pending }
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

        await publish { if case .observe? = $0.lastError { $0.lastError = nil } }
        pruneFailures(obs)

        // (c) plan
        var plan = makePlan(obs)

        // (d) persist new items, once per pass
        if !plan.newItems.isEmpty {
            for n in plan.newItems { layout.append(n.key, to: n.section) }
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
            chained = 0
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
                for a in after.actions where batch[Self.key(of: a)] != nil { failures[Self.key(of: a)] = failErr }
                consecutiveFailures += 1
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
            guard actionCount < config.maxActionsPerPass else {
                log("maxActionsPerPass reached")
                return await rescheduleIncomplete(report(.incomplete), converged: false)
            }
            guard let action = plan.actions.first, case .move(let key, let rel) = action else { break }
            if !effectiveCaps()(key).canMove {
                log("engine: refusing move of \(key): capability forbids")
                failures[key] = .unsupportedItem(reason: "capability forbids")
                plan = makePlan(obs)
                continue
            }
            if lastAction == action {
                // Verified last time yet still planned: the actuator's verdict and our observation disagree.
                failures[key] = .notVerified(expected: "\(rel)", observed: "unchanged")
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
                consecutiveFailures = 0
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
                failures[key] = e
                guard await adopt(snap, into: &obs) else { return await abort(.observeFailed) }
            }
            plan = makePlan(obs)
            phaseReached = plan.phase
            await publishObserved(obs, plan)
            if consecutiveFailures >= config.maxConsecutiveFailures { return await stopForFailures(report(.incomplete), obs: obs) }
        }
        await publish { $0.inFlight = nil }
        if plan.phase == .converged {
            chained = 0
            let ok = isConverged()
            _ = await finish(report(ok ? .converged : .incomplete), converged: ok)
            return report(ok ? .converged : .incomplete)
        }
        return await abort(.incomplete)
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

    /// Ends a pass after too many consecutive failures: reports it, leaves the rest pending, never chains.
    private func stopForFailures(_ r: PassReport, obs: ObservedOrder) async -> PassReport {
        let n = config.maxConsecutiveFailures
        log("stopped after \(n) consecutive failures")
        pending = false
        chained = config.maxChainedPasses
        await publishObserved(obs, makePlan(obs))
        await publish { $0.lastError = .stoppedAfterFailures(n) }
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
