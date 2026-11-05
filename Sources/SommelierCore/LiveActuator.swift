import CoreGraphics
import Foundation

/// Per-key and aggregate outcome of a hide/show batch.
public enum ActuationMechanism: String, Sendable {
    /// cfprefsd-notified `isAllowed` write; MenuBarAgent applied it without a respawn.
    case live
    /// File write + `killall MenuBarAgent`.
    case respawn
    /// Nothing written: the Control Center store already had the wanted value (identifier-less units found already hidden).
    case alreadyApplied
    /// Live write applied per the Control Center store (readback), but no usable complete read confirmed it in time (gdu.55).
    /// Never a respawn reason; the result is `.verified` and the engine marks the key "applied; confirmation pending".
    case liveUnverified
}

public struct BatchOutcome: Sendable {
    /// One entry per requested key, plus keys of the same app that the app-level `isAllowed` flip necessarily changes.
    public var perKey: [ItemKey: ActuationResult]
    /// `.verified` only if every entry verified.
    public var result: ActuationResult
    /// Which path produced the result; nil when nothing was written (already satisfied, refused).
    public var mechanism: ActuationMechanism? = nil
    /// Wall time of the write-to-verified phase in milliseconds (platform clock), nil when nothing was written.
    public var elapsedMS: Int? = nil
    /// Extra remark for logs and `mbprobe` (e.g. `.liveUnverified`: "applied per Control Center store; confirmation pending").
    public var note: String? = nil
}

/// The real `MenuBarActuator`: precheck -> act -> settle -> verify (docs/architecture.md (c)).
/// An actor, so two actuations never overlap.
public actor LiveActuator: MenuBarActuator {
    public struct Config: Sendable {
        /// Minimum wait after a drag's mouse-up before the first settle poll (AX lags 0.4-2.0 s).
        public var dragFloor: TimeInterval = 2.0
        public var settleMaxWait: TimeInterval = 4.0
        public var stableFor: TimeInterval = 0.15
        public var userBusyWait: TimeInterval = 2.0
        public var allowFallback = true
        /// Skip the drag mechanism and go straight to the fallback (testing).
        public var forceFallback = false
        public var restartTimeout: TimeInterval = 15
        /// Use the cfprefsd-notified write (no respawn) when the platform has the entitlement; the respawn is the fallback.
        public var liveHideShow = true
        /// Full scans are polled until a COMPLETE read confirms the change (a live hide shows only on a complete read).
        public var liveVerifyTimeout: TimeInterval = 20
        /// Hard ceiling on full scans taken while waiting for a complete read.
        public var liveVerifyMaxScans = 8
        public var liveVerifyInterval: TimeInterval = 0.5
        /// gdu.55: MenuBarAgent may be restarted ONLY as a last resort when the live write itself failed (no entitlement, the
        /// write threw, or the readback never showed the intended value). nil = automatic: allowed only when the platform has no
        /// live path (`!liveHideShowAvailable`). A verification timeout is never a reason to restart.
        public var allowAgentRestart: Bool? = nil
        /// Read at the start of every batch; wins over `allowAgentRestart` when it returns non-nil (the Settings toggle).
        public var allowAgentRestartProvider: (@Sendable () -> Bool?)? = nil
        /// `isAllowed` readback after the live write: this many attempts spread over `readbackSpan` seconds.
        public var readbackAttempts = 3
        public var readbackSpan: TimeInterval = 1.5
        /// During a self-positioning streak (previous read `.completeExceptSelfPositioning`) the confirm polls use the fast hosted
        /// read, with a full scan every this many polls (gdu.55).
        public var fastConfirmEvery = 3
        /// A batch that asks the OPPOSITE of a write made less than this long ago waits out the remainder and rescans before
        /// it believes its pre-write scan: the earlier write may not be visible yet, and a stale scan would make the new batch
        /// look "already satisfied" or compute expectations against the wrong starting state (gdu.47).
        public var recentWriteSettle: TimeInterval = 1.5
        public var dragSteps = 10
        /// Second drag attempt uses more steps (docs/findings-drag: >=10 always worked, 20 is the next parameter).
        public var retrySteps = 20
        /// Owners that re-position their own items on every agent restart: with an unchanged order store, plain
        /// `agent-restart`s moved iStat's Time item to three different slots (docs/findings-restart-collateral.md). Their
        /// relative order is not evidence of drift caused by us and cannot be repaired through the store, so the drift
        /// check ignores them (their on/off-bar state is still covered by the collateral check).
        public var selfPositioningOwners: Set<String> = SelfPositioning.defaultOwners
        public init() {}
    }

    public let platform: any ActuatorPlatform
    public var config: Config
    public private(set) var trace: [String] = []
    private let log: @Sendable (String) -> Void

    public init(platform: any ActuatorPlatform, config: Config = Config(), log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.platform = platform; self.config = config; self.log = log
        if config.liveHideShow { log("live hide/show: \(platform.liveHideShowAvailable ? "available" : "unavailable (no app-group entitlement)")") }
    }

    public func setConfig(_ c: Config) { config = c }

    /// Whether a failed live write may fall back to the file write + MenuBarAgent restart (see `Config.allowAgentRestart`).
    private func restartAllowed() -> Bool {
        config.allowAgentRestartProvider?() ?? config.allowAgentRestart ?? !platform.liveHideShowAvailable
    }

    // Actor methods are re-entrant across `await`, so an explicit FIFO gate keeps whole actuations from interleaving.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }   // ownership is handed over by `release`
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    private func note(_ s: String) { trace.append(s); log(s) }

    // MARK: - Precheck

    private func globalPrecheck() -> ActuationResult? {
        guard platform.accessibilityTrusted() else { return .failed(.permissionDenied, nil) }
        if let who = platform.conflictingManager() { return .failed(.conflictingManager(who), nil) }
        return nil
    }

    private func settleDetector(subjectPIDs: Set<pid_t>) -> SettleDetector {
        let p = platform
        return SettleDetector(scanner: p, now: { p.now() }, sleep: { await p.sleep($0) },
                              isSubject: { subjectPIDs.contains($0.ownerPID) })
    }

    // MARK: - move

    private struct Plan {
        var snapshot: MenuBarSnapshot
        var resolved: [ResolvedItem]
        var subject: ResolvedItem
        var target: ResolvedItem?
    }

    /// A full scan that is not empty. A scan with zero on-bar items is a failed read, not a verdict: rescan (bounded).
    private func scanNonEmpty() async -> MenuBarSnapshot {
        var snap = await platform.scan()
        for _ in 0..<3 where snap.onBarLeftToRight.isEmpty { await platform.sleep(0.3); snap = await platform.scan() }
        return snap
    }

    private enum Lookup {
        case ok(Plan)
        case absent(String)            // subject or target missing / not on the bar
        case parkedSubject
        case untrustedFrame(String)    // gdu.94: subject's frame cannot be believed (hidden / stale / overlaps another fresh item)
    }

    /// gdu.94: nil when the subject's frame may be dragged at; otherwise why not. Two items cannot share a slot, so a frame that
    /// overlaps (by more than half of the subject's own width) a FRESH on-bar item of another key is a stale frame.
    static func frameTrustworthy(subject: ResolvedItem, among resolved: [ResolvedItem]) -> String? {
        let i = subject.item
        if i.stale { return "stale (carried forward from an earlier scan)" }
        if i.hiddenInControlCenter { return "hidden in Control Center" }
        if i.controlCenterAllowed == false { return "Control Center does not allow it (isAllowed=false)" }
        for o in resolved where o.key != subject.key && !o.item.stale && o.item.isOnMenuBar && o.item.frame.width > 1 {
            let w = i.frame.intersection(o.item.frame).width
            if !i.frame.intersection(o.item.frame).isNull, w > i.frame.width * 0.5 {
                return "its frame \(i.frame) overlaps the fresh item \(o.key) at \(o.item.frame)"
            }
        }
        return nil
    }

    private func lookup(_ key: ItemKey, _ relation: Relation, _ snap: MenuBarSnapshot) -> Lookup {
        let resolved = platform.resolve(snap)
        guard !snap.onBarLeftToRight.isEmpty else { return .absent("empty scan") }
        guard let subject = resolved.first(where: { $0.key == key }) else { return .absent("item absent") }
        var target: ResolvedItem?
        switch relation {
        case .before(let t), .after(let t):
            guard t != key, let tr = resolved.first(where: { $0.key == t }), ActuationVerifier.onBar(tr) else { return .absent("target absent") }
            target = tr
        default: break
        }
        guard ActuationVerifier.onBar(subject) else { return .parkedSubject }
        // A stale subject is rescanned by `prepare` (and times out if it stays stale); every other doubt is a refusal.
        if !subject.item.stale, let why = Self.frameTrustworthy(subject: subject, among: resolved) { return .untrustedFrame(why) }
        return .ok(Plan(snapshot: snap, resolved: resolved, subject: subject, target: target))
    }

    /// Looks up subject/target; a single scan that misses them is never believed: it is confirmed with a fast scan after
    /// 300 ms and then a full scan before `.notFound` / `.unsupportedItem` is returned. Re-scans (up to 3 times) while
    /// the frames are stale.
    private func prepare(_ key: ItemKey, _ relation: Relation, from first: MenuBarSnapshot?) async -> (Plan?, ActuationResult?) {
        var snap: MenuBarSnapshot
        if let first { snap = first } else { snap = await scanNonEmpty() }
        for round in 0...3 {
            var found = lookup(key, relation, snap)
            if case .ok = found {} else {
                let first = snap
                await platform.sleep(0.3)
                let fast = await platform.scanVisible()
                if case .ok = lookup(key, relation, fast) { snap = await scanNonEmpty(); found = lookup(key, relation, snap) }   // fast saw it: trust only a full scan
                else { snap = await scanNonEmpty(); found = lookup(key, relation, snap) }
                note("prepare: first scan missed (\(first.onBarLeftToRight.count) on-bar); confirmed with fast+full scan")
            }
            switch found {
            case .absent: return (nil, .failed(.notFound, snap))
            case .parkedSubject:
                return (nil, .failed(.unsupportedItem(reason: "The item is hidden (off the bar); show it before moving it."), snap))
            case .untrustedFrame(let why):
                let item = resolvedSubject(key, snap)?.item
                note("refusing drag: subject \(key) frame not trustworthy: \(why); item: \(item.map { "source=\($0.source.rawValue) frame=\($0.frame) onBar=\($0.isOnMenuBar) join=\($0.joinEvidence.rawValue) ccHidden=\($0.hiddenInControlCenter) ccAllowed=\($0.controlCenterAllowed.map(String.init(describing:)) ?? "?")" } ?? "absent")")
                return (nil, .failed(.mechanismFailed("subject \(key) frame not trustworthy: \(why)"), snap))
            case .ok(let plan):
                if !plan.subject.item.stale && !(plan.target?.item.stale ?? false) { return (plan, nil) }
                if round == 3 { return (nil, .failed(.timeout, snap)) }
                snap = await scanNonEmpty()
            }
        }
        return (nil, .failed(.timeout, snap))
    }

    private func resolvedSubject(_ key: ItemKey, _ snap: MenuBarSnapshot) -> ResolvedItem? {
        platform.resolve(snap).first(where: { $0.key == key })
    }

    private func waitMouseIdle() async -> Bool {
        var waited = 0.0
        while platform.pressedMouseButtons() != 0 {
            if waited >= config.userBusyWait { return false }
            await platform.sleep(0.1); waited += 0.1
        }
        return true
    }

    /// x to drop at for the relation, from the plan's frames. nil when no neighbor exists to aim at.
    private static func dropX(_ relation: Relation, plan: Plan) -> CGFloat? {
        // Stale items carry cached frames from an earlier layout; they must not pick the hover neighbour or the end slots.
        let freshBar = ActuationVerifier.barOrder(plan.resolved).filter { !$0.item.stale }
        let bar = freshBar.map(\.item)
        let me = plan.subject.item
        switch relation {
        case .before, .after:
            return DragTarget.dropX(for: DragRelation(relation), moved: me, target: plan.target?.item, bar: bar)
        case .leftmost:
            guard let first = freshBar.first(where: { !ActuationVerifier.isModule($0) && $0.key != plan.subject.key })
            else { return nil }
            return DragTarget.dropX(for: .before("first"), moved: me, target: first.item, bar: bar)
        case .rightmost:
            guard let last = freshBar.last(where: { !ActuationVerifier.isModule($0) && $0.key != plan.subject.key })
            else { return nil }
            return DragTarget.dropX(for: .after("last"), moved: me, target: last.item, bar: bar)
        }
    }

    private struct Observation {
        var snapshot: MenuBarSnapshot
        var resolved: [ResolvedItem]
        var settled: Bool
        var verdict: ActuationVerifier.Verdict
        var verified: Bool { settled && verdict.ok }
    }

    private func observe(_ key: ItemKey, _ relation: Relation, subjectPID: pid_t) async -> Observation {
        let out = await settleDetector(subjectPIDs: [subjectPID]).settled(maxWait: config.settleMaxWait, stableFor: config.stableFor)
        let resolved = platform.resolve(out.snapshot)
        let v = ActuationVerifier.moveVerdict(subject: key, relation: relation, resolved: resolved)
        note("observe settled=\(out.settled) polls=\(out.polls) full=\(out.fullScans) \(Int(out.elapsed * 1000))ms ok=\(v.ok)" + (out.settled || out.trace.isEmpty ? "" : " trace=[\(out.trace)]"))
        return Observation(snapshot: out.snapshot, resolved: resolved, settled: out.settled, verdict: v)
    }

    private var churnZone: Set<ItemKey> = []
    public func setChurnZone(_ keys: Set<ItemKey>) async { churnZone = keys }

    public func move(_ key: ItemKey, relation: Relation) async -> ActuationResult {
        await acquire(); defer { release() }
        return await performMove(key, relation: relation)
    }

    private func performMove(_ key: ItemKey, relation: Relation) async -> ActuationResult {
        trace = []
        if let f = globalPrecheck() { return f }
        let (planOpt, early) = await prepare(key, relation, from: nil)
        if let early { return early }
        var plan = planOpt!
        let cap = CapabilityRules(hasTrackedEntry: { _ in true }).capability(for: key)
        guard cap.canMove else { return .failed(.unsupportedItem(reason: cap.reason ?? "cannot move"), plan.snapshot) }
        if ActuationVerifier.moveVerdict(subject: key, relation: relation, resolved: plan.resolved).ok {
            // gdu.26: prepare() took ONE full scan; `.verified` needs the settle rule (two agreeing scans), so confirm first.
            var obs = await observe(key, relation, subjectPID: plan.subject.item.ownerPID)
            if !obs.settled { obs = await observe(key, relation, subjectPID: plan.subject.item.ownerPID) }
            if obs.verified { note("already satisfied (settled)"); return .verified(obs.snapshot) }
            if !obs.settled { return .failed(.timeout, obs.snapshot) }
            note("looked satisfied on one scan but the settled observation disagrees; planning from it")
            let (p, e) = await prepare(key, relation, from: obs.snapshot)
            if let e { return e }
            plan = p!
            if ActuationVerifier.moveVerdict(subject: key, relation: relation, resolved: plan.resolved).ok {
                return .failed(.timeout, plan.snapshot)   // flapping between scans: nothing is settled, claim nothing
            }
        }
        var lastError: ActuationError = .timeout
        var lastSnapshot = plan.snapshot
        var menuOpenedLast = false

        // gdu.25: items macOS has pushed into its menu bar overflow are reported on-bar but are not drawn, so a drag
        // cannot reach them (1/28 real drags there, 0/24 clean, the one pass confounded by a display change; 50/50 elsewhere). Skip the doomed drags; fail fast and honestly
        // unless the order-store fallback is allowed.
        var dragBlocked: String?
        if !config.forceFallback {
            let ovf = ActuationVerifier.overflowed(plan.resolved)
            let churn = churnZone.union(ChurnRead(resolved: plan.resolved).zone).subtracting(ovf)
            var involved = [plan.subject.key]
            if let t = plan.target { involved.append(t.key) }
            if let x = Self.dropX(relation, plan: plan) {
                involved += ActuationVerifier.barOrder(plan.resolved).filter { $0.item.frame.minX <= x && x <= $0.item.frame.maxX }.map(\.key)
            }
            if let hit = involved.first(where: { ovf.contains($0) || churn.contains($0) }) {
                dragBlocked = ovf.contains(hit)
                    ? "\(hit) \(ActuationError.overflowRefusalMarker) (hidden by macOS because the bar is full); a drag cannot reach it"
                    : "\(hit) \(SystemOverflowRule.churnRefusalMarker); a drag cannot be trusted there"
                note("drag skipped: \(dragBlocked!)")
                lastError = .mechanismFailed(dragBlocked!)
            }
        }

        if !config.forceFallback && dragBlocked == nil {
            for attempt in 1...2 {
                guard await waitMouseIdle() else { return .failed(.userBusy, lastSnapshot) }
                guard let x = Self.dropX(relation, plan: plan) else {
                    return .failed(.notVerified(expected: "\(key) \(relation)", observed: "no neighbor to aim at"), plan.snapshot)
                }
                let steps = attempt == 1 ? config.dragSteps : config.retrySteps
                let pid = plan.subject.item.ownerPID
                let targetText = plan.target.map { "\($0.key) frame=\($0.item.frame)" } ?? "none"
                note("attempt \(attempt): drag subject frame=\(plan.subject.item.frame) fresh=\(!plan.subject.item.stale) target=\(targetText) expect=\(relation) toX=\(Int(x)) steps=\(steps) bar=\(DropTrace.truncated(ActuationVerifier.barOrder(plan.resolved).map { "\(Int($0.item.frame.minX))" }))")
                let probeBefore = platform.menuProbe(for: plan.subject.item)
                let upAt: Date
                do { upAt = try await platform.drag(itemFrame: plan.subject.item.frame, toX: x, steps: steps) }
                catch DragError.userBusy { return .failed(.userBusy, lastSnapshot) }
                catch { return .failed(.mechanismFailed("could not post mouse events: \(error)"), lastSnapshot) }
                let probeAfter = platform.menuProbe(for: plan.subject.item)
                let opened = probeAfter.hasMenu || probeAfter.windowCount > probeBefore.windowCount
                menuOpenedLast = opened
                if opened {
                    note("attempt \(attempt): menu opened; Escape")
                    platform.pressEscape()
                    await platform.sleep(0.3)
                }
                let wait = config.dragFloor - platform.now().timeIntervalSince(upAt)
                if wait > 0 { await platform.sleep(wait) }
                var obs = await observe(key, relation, subjectPID: pid)
                if obs.verdict.ok && !obs.settled {   // right place but not settled/fresh: observe again, do not drag again
                    obs = await observe(key, relation, subjectPID: pid)
                }
                lastSnapshot = obs.snapshot
                if obs.verified {
                    note("attempt \(attempt): verified: \(key) \(DropTrace.between(key, in: ActuationVerifier.barOrder(obs.resolved).map(\.key)))" + (opened ? " (a menu had opened and was dismissed)" : ""))
                    return .verified(obs.snapshot)
                }
                if opened { lastError = .mechanismFailed("menu opened") }
                else if obs.verdict.ok || !obs.settled { lastError = .timeout }
                else { lastError = obs.verdict.error! }
                note("attempt \(attempt): \(lastError)")
                if attempt == 1 || config.allowFallback {
                    // Re-plan from the latest scan; the item may have vanished meanwhile.
                    let (p, e) = await prepare(key, relation, from: obs.snapshot)
                    if let e { return e }
                    plan = p!
                    if attempt == 1, ActuationVerifier.moveVerdict(subject: key, relation: relation, resolved: plan.resolved).ok, obs.settled {
                        // gdu.26: the settled observation said "not in place" and one fresh scan says "in place": a
                        // contradiction, not a verdict. Only a new settled observation may earn `.verified`.
                        let again = await observe(key, relation, subjectPID: pid)
                        lastSnapshot = again.snapshot
                        if again.verified { return .verified(again.snapshot) }
                        lastError = .timeout
                    }
                }
            }
        }

        guard config.allowFallback else { return .failed(lastError, lastSnapshot) }
        note("fallback: order store + agent restart")
        return await fallbackMove(key, relation, plan: plan, previous: lastError, menuOpened: menuOpenedLast)
    }

    /// Order-store edit + one agent restart. Only the values already present in the store are permuted, so unrelated
    /// positions are untouched.
    private func fallbackMove(_ key: ItemKey, _ relation: Relation, plan: Plan, previous: ActuationError, menuOpened: Bool) async -> ActuationResult {
        let store: [String: Double]
        do { store = try platform.readOrderStore() } catch { return .failed(.mechanismFailed("fallback: cannot read order store: \(error)"), plan.snapshot) }
        let bar = ActuationVerifier.barOrder(plan.resolved).filter { !ActuationVerifier.isModule($0) }
        var keys = bar.map(\.key)
        guard let from = keys.firstIndex(of: key) else { return .failed(.notFound, plan.snapshot) }
        keys.remove(at: from)
        switch relation {
        case .leftmost: keys.insert(key, at: 0)
        case .rightmost: keys.append(key)
        case .before(let t), .after(let t):
            guard let i = keys.firstIndex(of: t) else {
                return .failed(.mechanismFailed("fallback: relation target \(t) is not a movable item"), plan.snapshot)
            }
            if case .before = relation { keys.insert(key, at: i) } else { keys.insert(key, at: i + 1) }
        }
        // Only store-backed status keys take part; the subject (and target) must be among them.
        func inStore(_ k: ItemKey) -> Bool { if case .status = k { return store[k.description] != nil } else { return false } }
        var required = [key]
        if case .before(let t) = relation { required.append(t) }
        if case .after(let t) = relation { required.append(t) }
        if let bad = required.first(where: { !inStore($0) }) {
            return .failed(.mechanismFailed("fallback needs an order-store entry for \(bad)"), plan.snapshot)
        }
        let participants = keys.filter(inStore)
        // Strict order between the subject and its new neighbours (docs/findings-drag.md, gdu.25): the subject gets the
        // midpoint between them, or the contiguous run around the slot is re-based when no integer fits. Duplicate
        // values elsewhere in the store are not our concern; the full scan below verifies the outcome.
        guard let storePlan = OrderStorePlanner.plan(order: participants.map(\.description), subject: key.description,
                                                     values: store.filter { $0.key != key.description })
        else { return .failed(.mechanismFailed("fallback: cannot plan an order-store value for \(key)"), plan.snapshot) }
        let updates = storePlan.updates
        note("fallback plan: \(storePlan.rebased ? "re-base" : "midpoint") \(updates.sorted { $0.key < $1.key }.map { "\($0.key)=\(Int($0.value))" }.joined(separator: ", "))")
        await platform.waitForOrderStoreQuiet()
        if !updates.isEmpty {
            do { try platform.writeOrderStore(updates, allowModules: false) } catch { return .failed(.mechanismFailed("fallback: order store write failed: \(error)"), plan.snapshot) }
        }
        let r = await platform.restartAgent(timeout: config.restartTimeout, expectedChange: 0)
        note("fallback restart recovered=\(r.recovered) \(r.elapsedMS)ms wrote=\(updates.count)")
        let obs = await observe(key, relation, subjectPID: plan.subject.item.ownerPID)
        if obs.verified { return .verified(obs.snapshot) }
        if !obs.settled { return .failed(menuOpened ? .mechanismFailed("menu opened") : .timeout, obs.snapshot) }
        return .failed(obs.verdict.error ?? previous, obs.snapshot)
    }

    // MARK: - hide / show

    public func setHidden(_ key: ItemKey, _ hidden: Bool) async -> ActuationResult {
        await applyHiddenBatchDetailed([key: hidden]).result
    }

    public func applyHiddenBatch(_ changes: [ItemKey: Bool]) async -> ActuationResult {
        await applyHiddenBatchDetailed(changes).result
    }

    private func uniform(_ keys: some Collection<ItemKey>, _ r: ActuationResult) -> BatchOutcome {
        BatchOutcome(perKey: Dictionary(uniqueKeysWithValues: keys.map { ($0, r) }), result: r)
    }

    /// True when the last batch restarted MenuBarAgent (fallback path). The engine strikes such keys out at once.
    public private(set) var lastBatchRespawned = false
    private var batchRespawned = false
    /// Units of the last batch the capability rules refused (key -> reason). They were not written and are NOT in a mixed
    /// batch's `result`; `BatchOutcome.perKey` carries their `.failed(.unsupportedItem)`. The engine records them as skips.
    public private(set) var lastBatchRefused: [ItemKey: String] = [:]
    private var batchRefused: [ItemKey: String] = [:]
    /// Units of the last batch left alone because an unrequested member was stale (gdu.76): transient, NOT in `lastBatchRefused`.
    public private(set) var lastBatchUnsettled: [ItemKey: String] = [:]
    private var batchUnsettled: [ItemKey: String] = [:]
    /// Keys of the last batch applied per the Control Center store but not yet confirmed by a usable read (`.liveUnverified`).
    public private(set) var lastBatchUnconfirmed: Set<ItemKey> = []
    /// The keys and directions of the last batch that wrote, and when it finished (see `Config.recentWriteSettle`).
    private var lastWrite: (changes: [ItemKey: Bool], at: Date)?

    public func applyHiddenBatchDetailed(_ changes: [ItemKey: Bool]) async -> BatchOutcome {
        await acquire(); defer { release() }
        platform.beginTrackedSnapshot(); defer { platform.endTrackedSnapshot() }   // gdu.76: one Control Center read per batch
        batchRespawned = false
        batchRefused = [:]
        batchUnsettled = [:]
        var out = await performBatch(changes)
        lastBatchRefused = batchRefused
        lastBatchUnsettled = batchUnsettled
        for (k, why) in batchRefused { out.perKey[k] = .failed(.unsupportedItem(reason: why), nil) }
        for (k, why) in batchUnsettled { out.perKey[k] = .failed(.memberStale(why), nil) }
        lastBatchRespawned = batchRespawned || out.mechanism == .respawn
        let applied = changes.filter { batchRefused[$0.key] == nil && batchUnsettled[$0.key] == nil }
        lastBatchUnconfirmed = out.mechanism == .liveUnverified ? Set(out.perKey.keys.filter { batchRefused[$0] == nil && batchUnsettled[$0] == nil }) : []
        if out.mechanism == .live || out.mechanism == .respawn || out.mechanism == .liveUnverified { lastWrite = (applied, platform.now()) }
        return out
    }

    private func performBatch(_ changes: [ItemKey: Bool], recheck: Int = 1) async -> BatchOutcome {
        trace = []
        if let f = globalPrecheck() { return uniform(changes.keys, f) }
        var snap = await scanNonEmpty()
        if changes.isEmpty { return BatchOutcome(perKey: [:], result: .verified(snap)) }
        if let w = lastWrite {
            let age = platform.now().timeIntervalSince(w.at)
            if age < config.recentWriteSettle, changes.contains(where: { key, hide in w.changes[key].map { $0 != hide } ?? false }) {
                note("opposite of a write made \(Int(age * 1000)) ms ago; waiting before trusting the pre-write scan")
                await platform.sleep(config.recentWriteSettle - age)
                snap = await scanNonEmpty()
            }
        }
        var resolved = platform.resolve(snap)
        for _ in 0..<2 where changes.keys.contains(where: { k in !resolved.contains { $0.key == k } }) {
            // A key missing from one scan is not believed: confirm with another full scan before `.notFound`.
            await platform.sleep(0.3)
            snap = await scanNonEmpty()
            resolved = platform.resolve(snap)
        }

        // Validate every key before touching anything. A unit the capability rules refuse (not tracked, Apple app, no owner) is
        // split off with its own reason (gdu.72); the applicable units still go out in ONE write. Missing keys and conflicting
        // requests stay whole-batch failures.
        var refused: [ItemKey: String] = [:]
        var unsettled: [ItemKey: String] = [:]   // subset of the refused keys: transient stale-member refusals (gdu.76)
        var requestedBy: [String: [(key: ItemKey, hide: Bool)]] = [:]   // tracked key -> requested items
        for (key, hide) in changes.sorted(by: { $0.key.description < $1.key.description }) {
            guard let r = resolved.first(where: { $0.key == key }) else { return uniform(changes.keys, .failed(.notFound, snap)) }
            let tracked = platform.trackedKey(for: r)
            let rules = CapabilityRules(hasTrackedEntry: { _ in tracked != nil })
            let cap = rules.capability(for: key)
            guard cap.canHide, let tracked else {
                refused[key] = cap.reason ?? "cannot hide"
                continue
            }
            requestedBy[tracked, default: []].append((key, hide))
        }
        // gdu.75: the flag is per tracked ENTRY, so every item it governs changes with it. The actuator never changes an item the
        // batch did not request: a unit whose members are asked to differ, or whose flip would also move an unrequested member
        // (the planner groups by the same entry, so this is a belt-and-braces refusal), is refused whole instead.
        var wantByApp: [String: Bool] = [:]   // tracked key -> hidden
        for (tracked, reqs) in requestedBy.sorted(by: { $0.key < $1.key }) {
            let entry = platform.displayName(forTrackedKey: tracked)
            var why = HideUnitNames.groupRefusal(entry: entry)
            var transient = false
            let hide = reqs[0].hide
            var bad = reqs.contains { $0.hide != hide }
            if !bad {
                let asked = Set(reqs.map(\.key))
                for r in resolved where !asked.contains(r.key) && platform.trackedKey(for: r) == tracked {
                    // An unrequested member whose state is unknown could be flipped silently: refuse (gdu.76). A fresh one that
                    // already is in the target state is fine; a fresh one that would change is refused.
                    if r.item.stale { bad = true; transient = true; why = HideUnitNames.staleMemberRefusal(entry: entry); break }
                    if hide ? ActuationVerifier.onBar(r) : !ActuationVerifier.onBar(r) { bad = true; break }
                }
            }
            if bad { for q in reqs { refused[q.key] = why; if transient { unsettled[q.key] = why } } } else { wantByApp[tracked] = hide }
        }
        batchRefused.merge(refused.filter { unsettled[$0.key] == nil }) { a, _ in a }
        batchUnsettled.merge(unsettled) { a, _ in a }   // merge: the gdu.26 recheck recurses with the filtered batch and must not wipe earlier refusals
        let refusedLogged = refused.filter { unsettled[$0.key] == nil }   // gdu.78: unsettled units are logged once, by the engine
        if !refusedLogged.isEmpty {
            note("refused \(refusedLogged.count) unit(s) before the write: " + refusedLogged.sorted { $0.key.description < $1.key.description }.map { "\($0.key): \($0.value)" }.joined(separator: "; "))
        }
        if refused.count == changes.count {
            // Nothing applicable: no scan-dependent work, no write.
            let sortedRefused = refused.sorted { $0.key.description < $1.key.description }
            if refused.keys.allSatisfy({ unsettled[$0] != nil }) { return uniform(changes.keys, .failed(.memberStale(sortedRefused[0].value), snap)) }
            let first = (sortedRefused.first { unsettled[$0.key] == nil } ?? sortedRefused[0]).value
            return uniform(changes.keys, .failed(.unsupportedItem(reason: first), snap))
        }
        let changes = changes.filter { refused[$0.key] == nil }
        // Items of the same app that were not requested change with the app-level flag; they are verified too.
        var expectations: [ItemKey: Bool] = changes
        var members = Set<pid_t>()
        var expectedChange = 0   // hosted items that appear (+) / disappear (-) with the restart
        for r in resolved {
            if let t = platform.trackedKey(for: r), let want = wantByApp[t] {
                members.insert(r.item.ownerPID)
                if want, ActuationVerifier.onBar(r) { expectedChange -= 1 }
                if !want, !ActuationVerifier.onBar(r) { expectedChange += 1 }
                if expectations[r.key] == nil { expectations[r.key] = want }
            }
        }
        let before = Dictionary(resolved.filter { $0.confidence.isStoreBacked && !$0.item.stale }.map { ($0.key, ActuationVerifier.onBar($0)) },
                                uniquingKeysWith: { a, _ in a })

        // Already in the requested state? Then there is nothing to do (and no restart flash).
        func verdicts(_ rs: [ResolvedItem]) -> [ItemKey: ActuationVerifier.Verdict] {
            Dictionary(uniqueKeysWithValues: expectations.map { ($0.key, ActuationVerifier.visibilityVerdict(key: $0.key, hidden: $0.value, resolved: rs)) })
        }
        if verdicts(resolved).values.allSatisfy(\.ok) {
            // gdu.26: one full scan is not a verdict. Confirm with a second full scan that agrees (SettleDetector.agree, frames
            // within 1 pt) before saying `.verified`; a contradiction restarts the batch once from the newer scan.
            await platform.sleep(config.stableFor)
            let again = await scanNonEmpty()
            let againResolved = platform.resolve(again)
            let subjectPIDs = Set(resolved.filter { expectations[$0.key] != nil }.map(\.item.ownerPID))
            let stale = again.items.contains { subjectPIDs.contains($0.ownerPID) && $0.stale }
            if SettleDetector.agree(snap, again), !stale, verdicts(againResolved).values.allSatisfy(\.ok) {
                note("batch already satisfied (two agreeing full scans)")
                return finish(expectations, verdicts(againResolved), again, settled: true, collateral: [])
            }
            note("batch looked satisfied on one scan but the confirming scan disagrees")
            if recheck > 0 { return await performBatch(changes, recheck: recheck - 1) }
            return uniform(changes.keys, .failed(.timeout, again))
        }

        let respawnStart = platform.now()   // elapsed of a respawn result includes a failed live attempt
        if config.liveHideShow {
            if platform.liveHideShowAvailable {
                let t0 = respawnStart
                // Write-time evidence for identifier-less items (of7): the scanner cannot see their live hide (their app-side
                // frame stays on-bar), so the complete hosted count before the write is the baseline for a count drop.
                var unnamedOwners: [AssumedHiddenOwner] = []
                var hideOwners: [AssumedHiddenOwner] = []   // every owner of a hide in the batch (recorded when the store confirms it)
                var showPIDs = Set<pid_t>()
                for r in resolved {
                    guard let t = platform.trackedKey(for: r), let want = wantByApp[t] else { continue }
                    if !want { showPIDs.insert(r.item.ownerPID); continue }
                    guard ActuationVerifier.onBar(r), !r.item.stale else { continue }
                    if let i = hideOwners.firstIndex(where: { $0.pid == r.item.ownerPID }) { hideOwners[i].items += 1 }
                    else { hideOwners.append(AssumedHiddenOwner(pid: r.item.ownerPID, bundleID: r.item.ownerBundleID, items: 1, trackedKey: t)) }
                    if let i = unnamedOwners.firstIndex(where: { $0.pid == r.item.ownerPID }) { unnamedOwners[i].items += 1 }
                    else { unnamedOwners.append(AssumedHiddenOwner(pid: r.item.ownerPID, bundleID: r.item.ownerBundleID, items: 1, trackedKey: t)) }
                }
                // Owners with at least one identifier-less on-bar item; their count (all on-bar items of the owner) is recorded.
                let unnamedPIDs = Set(resolved.filter { r in
                    guard let t = platform.trackedKey(for: r), wantByApp[t] == true, ActuationVerifier.onBar(r), !r.item.stale else { return false }
                    return r.item.axIdentifier.isEmpty && r.item.axDescription.isEmpty
                }.map(\.item.ownerPID))
                unnamedOwners = unnamedOwners.filter { unnamedPIDs.contains($0.pid) }
                // Already hidden per the Control Center store (of7): identifier-less units whose `isAllowed` already reads false
                // are hidden as far as the agent is concerned (it enforces the store) even though their app-side frame says
                // on-bar. No write, no respawn: record the owners as assumed-hidden so the scanner reflects it.
                let onBarHideItems = resolved.filter { r in
                    guard let t = platform.trackedKey(for: r), wantByApp[t] == true else { return false }
                    return ActuationVerifier.onBar(r) && !r.item.stale
                }
                if showPIDs.isEmpty, !unnamedOwners.isEmpty,
                   onBarHideItems.allSatisfy({ $0.item.axIdentifier.isEmpty && $0.item.axDescription.isEmpty }),
                   let allowed = platform.readAllowedLive(Array(wantByApp.keys)),
                   wantByApp.keys.allSatisfy({ allowed[$0] == false }) {
                    platform.recordAssumedHidden(unnamedOwners, hostedAfter: nil)
                    note("already hidden per Control Center store; recorded assumed-hidden")
                    var out = BatchOutcome(perKey: Dictionary(uniqueKeysWithValues: expectations.keys.map { ($0, ActuationResult.verified(snap)) }),
                                           result: .verified(snap))
                    out.mechanism = .alreadyApplied; out.elapsedMS = 0
                    return out
                }
                // Evidence = WHICH hosted elements vanished (not how many): the pre-write hosted tree minus exactly the unit's
                // elements must equal the post-write tree, in order. Only for pure hides; a batch that also shows items cannot
                // predict the tree, so it keeps the complete-read poll alone.
                var baseline: [HostedEntry]?
                // gdu.51: a read that is incomplete ONLY because of self-positioning owners' stale items is enough for a unit that
                // is not itself self-positioning; layouts are then compared without those owners' entries.
                let unitSP = expectations.keys.contains { selfPositioning($0) }
                let spOwners = config.selfPositioningOwners
                func usable(_ s: MenuBarSnapshot) -> Bool { unitSP ? s.completeness == .complete : s.completeness.membershipUsable }
                func norm(_ l: [HostedEntry]) -> [HostedEntry] { unitSP ? l : SelfPositioning.strip(l, owners: spOwners) }
                if !unnamedOwners.isEmpty, showPIDs.isEmpty {
                    var from = ""
                    if usable(snap), let l = snap.hostedLayout, !l.isEmpty {
                        baseline = norm(l); from = "pre-write full scan"
                    }
                    let limit = platform.now().addingTimeInterval(4)
                    while baseline == nil, platform.now() < limit {
                        let s = await platform.scan()
                        if usable(s), let l = s.hostedLayout, !l.isEmpty { baseline = norm(l); from = "retried full scan"; break }
                        await platform.sleep(0.2)
                    }
                    if baseline == nil, let l = platform.recentCompleteHostedLayout(maxAge: 10) { baseline = norm(l); from = "scanner cache (<= 10 s old)" }
                    if let baseline { note("live: baseline = \(from), \(baseline.count) hosted elements, unit owns \(baseline.filter { $0.ownerPID.map(members.contains) ?? false }.count)") }
                    else { note("live: no complete hosted baseline (scan, 4 s of retries, cache); no element evidence for identifier-less items") }
                }
                var wrote = false
                let hidePIDs = Set(resolved.compactMap { r -> pid_t? in
                    guard let t = platform.trackedKey(for: r), wantByApp[t] == true else { return nil }
                    return r.item.ownerPID
                })
                if !hidePIDs.isEmpty { platform.expectToVanish(pids: hidePIDs) }
                // gdu.55: the respawn is for a failed WRITE only. The write counts as landed when the CFPreferences readback (the
                // store the agent obeys) shows the intended values; an unreadable store cannot contradict it.
                let intended = wantByApp.mapValues { !$0 }
                var writeFailure: String?
                do { try platform.setAllowedLive(intended); wrote = true }
                catch { writeFailure = "setAllowedLive threw: \(error)" }
                if wrote {
                    var landed = false
                    var seen = "unreadable"
                    let attempts = max(1, config.readbackAttempts)
                    for attempt in 1...attempts {
                        if let rb = platform.readAllowedLive(Array(intended.keys)) {
                            let wrong = intended.filter { kv in rb[kv.key].map { $0 != kv.value } ?? false }
                            seen = intended.keys.sorted().map { "\($0)=\(rb[$0].map(String.init(describing:)) ?? "?")" }.joined(separator: ", ")
                            if wrong.isEmpty { landed = true; break }
                        } else { landed = true; seen = "unreadable"; break }
                        if attempt < attempts { await platform.sleep(config.readbackSpan / Double(attempts - 1)) }
                    }
                    if landed { note("live: write applied per Control Center store (readback \(seen))") }
                    else { wrote = false; writeFailure = "readback after \(attempts) attempts does not show the intended isAllowed (\(seen))" }
                }
                if let why = writeFailure {
                    platform.clearExpectedToVanish()
                    guard restartAllowed() else {
                        note("live write failed (\(why)); agent restart not allowed -> failing the batch, no respawn")
                        return uniform(changes.keys, .failed(.liveWriteFailed(why), snap))
                    }
                    note("live write failed (\(why)); agent restart allowed -> falling back to respawn")
                }
                var evidence: String?
                if wrote {
                    // A show by us ends any assumed-hidden state of that owner before the verification scans read it.
                    if !showPIDs.isEmpty { platform.clearAssumedHidden(pids: showPIDs) }
                    if let baseline {
                        let tw = platform.now()
                        for at in [0.3, 0.8, 1.5, 2.5, 4.0, 6.0] {
                            let due = at - platform.now().timeIntervalSince(tw); if due > 0 { await platform.sleep(due) }
                            guard let after = await platform.hostedLayout() else { note("live: probe @\(Int(at * 1000))ms incomplete"); continue }
                            if HostedEvidence.removedExactly(before: baseline, after: norm(after), unitPIDs: members) {
                                let n = baseline.count - after.count
                                evidence = "hosted-element evidence: exactly the unit's \(n) element(s) vanished (\(baseline.count) -> \(after.count))"
                                platform.recordAssumedHidden(unnamedOwners, hostedAfter: after.count)
                                note("live: \(evidence!) at \(Int(at * 1000))ms")
                                break
                            }
                            note("live: probe @\(Int(at * 1000))ms: ambiguous: \(HostedEvidence.mismatch(before: baseline, after: norm(after), unitPIDs: members) ?? "?")")
                        }
                    }
                }
                if wrote {
                    var polls = 0
                    var complete = 0
                    var ended = "ceiling"
                    var lastScan: MenuBarSnapshot?
                    var lastVerdicts: [ItemKey: ActuationVerifier.Verdict] = [:]
                    var collateralNote = ""
                    // gdu.55 (gdu.54 e): while the previous full read was only `completeExceptSelfPositioning`, confirm with the
                    // fast hosted read and take a full scan every `fastConfirmEvery`-th poll.
                    var lastFullLevel = snap.completeness
                    // The FIRST complete read decides; an unsatisfied one gets ONE more complete read (a scan may have
                    // started before the write landed). No usable complete read within the ceiling -> `.liveUnverified`
                    // (applied per the store, confirmation pending); NEVER a respawn.
                    while true {
                        await platform.sleep(config.liveVerifyInterval)
                        let fast = !unitSP && lastFullLevel == .completeExceptSelfPositioning && config.fastConfirmEvery > 1 && polls % config.fastConfirmEvery != config.fastConfirmEvery - 1
                        let s = fast ? await platform.scanVisible() : await platform.scan()
                        polls += 1
                        if !fast { lastFullLevel = s.completeness }
                        lastScan = s
                        if fast {
                            // A fast read can only CONFIRM; an unsatisfied fast read is not a verdict (it carries no completeness).
                            let v = verdicts(platform.resolve(s))
                            if !s.onBarLeftToRight.isEmpty, v.values.allSatisfy(\.ok) {
                                complete += 1
                                let ms = Int(platform.now().timeIntervalSince(t0) * 1000)
                                note("live: verified by fast hosted read #\(polls) during a self-positioning streak; \(polls) scans, \(ms)ms, no respawn")
                                var out = finish(expectations, v, s, settled: true, collateral: [])
                                platform.clearExpectedToVanish()
                                out.mechanism = .live; out.elapsedMS = ms
                                return out
                            }
                            note("live: scan \(polls): fast read, not confirming yet")
                            if polls >= config.liveVerifyMaxScans { ended = "max scans (\(config.liveVerifyMaxScans))"; break }
                            if platform.now().timeIntervalSince(t0) >= config.liveVerifyTimeout { ended = "timeout (\(Int(config.liveVerifyTimeout)) s)"; break }
                            continue
                        }
                        if !usable(s) {
                            note("live: scan \(polls): \(s.completeness.rawValue)\(s.completenessReason.map { " (\($0))" } ?? "")")
                        }
                        if usable(s), !s.onBarLeftToRight.isEmpty {
                            complete += 1
                            let v = verdicts(platform.resolve(s))
                            lastVerdicts = v
                            // The poll's own complete scans carry the attributed hosted tree: the same element evidence applies when the
                            // timed probes were incomplete or too early. Record, then read once more with the flag in effect.
                            if evidence == nil, let baseline, let after = s.hostedLayout.map(norm),
                               HostedEvidence.removedExactly(before: baseline, after: after, unitPIDs: members) {
                                evidence = "hosted-element evidence (poll scan #\(polls)): exactly the unit's \(baseline.count - after.count) element(s) vanished (\(baseline.count) -> \(after.count))"
                                platform.recordAssumedHidden(unnamedOwners, hostedAfter: after.count)
                                note("live: \(evidence!)")
                                complete -= 1
                                continue
                            }
                            // (c) no other app-side item may have left the bar (only checked when we rely on element evidence).
                            let nowResolved = platform.resolve(s)
                            let leftBar = evidence == nil ? [] : before.filter { $0.value && expectations[$0.key] == nil }.compactMap { k, _ -> ItemKey? in
                                nowResolved.first { $0.key == k }.flatMap { !$0.item.stale && !ActuationVerifier.onBar($0) ? k : nil }
                            }
                            if v.values.allSatisfy(\.ok), !leftBar.isEmpty {
                                note("live: element evidence rejected, \(leftBar.map(\.description).sorted().joined(separator: ", ")) also left the bar")
                                platform.clearAssumedHidden(pids: Set(unnamedOwners.map(\.pid))); evidence = nil
                                collateralNote = leftBar.map(\.description).sorted().joined(separator: ", ")
                                ended = "collateral"; break
                            }
                            if v.values.allSatisfy(\.ok) {
                                let ms = Int(platform.now().timeIntervalSince(t0) * 1000)
                                let via = evidence.map { "live: verified by \($0); " } ?? ""
                                note("\(via)live: verified by complete read #\(complete) (rule: first/second complete read satisfied); \(polls) scans, \(complete) complete, \(ms)ms, no respawn, read level \(s.completeness.rawValue)")
                                var out = finish(expectations, v, s, settled: true, collateral: [])
                                platform.clearExpectedToVanish()
                                out.mechanism = .live; out.elapsedMS = ms
                                return out
                            }
                            if complete >= 2 { ended = "two complete reads unsatisfied"; break }
                        }
                        if polls >= config.liveVerifyMaxScans { ended = "max scans (\(config.liveVerifyMaxScans))"; break }
                        if platform.now().timeIntervalSince(t0) >= config.liveVerifyTimeout { ended = "timeout (\(Int(config.liveVerifyTimeout)) s)"; break }
                    }
                    let ms = Int(platform.now().timeIntervalSince(t0) * 1000)
                    let final = lastScan ?? snap
                    if ended == "collateral" {
                        note("live verify rejected after \(ms)ms: \(polls) scans, \(complete) complete, other item(s) left the bar; no respawn")
                        platform.clearExpectedToVanish()
                        var out = uniform(changes.keys, .failed(.notVerified(expected: "no other item changes", observed: "\(collateralNote) also left the bar"), final))
                        out.mechanism = .live; out.elapsedMS = ms
                        return out
                    }
                    if ended == "two complete reads unsatisfied" {
                        // The store says applied but two complete reads still show the unit: the agent did not act on it. Not a
                        // timeout and not a restart reason; the engine re-plans the hide from the next settled observation.
                        note("live verify contradicted after \(ms)ms: \(polls) scans, \(complete) complete, ended by \(ended); no respawn")
                        platform.clearAssumedHidden(pids: Set(hideOwners.map(\.pid)))
                        platform.clearExpectedToVanish()
                        var out = finish(expectations, lastVerdicts, final, settled: true, collateral: [])
                        out.mechanism = .live; out.elapsedMS = ms
                        return out
                    }
                    // Max scans / timeout without a contradiction: APPLIED per the store, confirmation pending.
                    note("live verify unconfirmed after \(ms)ms: \(polls) scans, \(complete) complete, ended by \(ended); applied per Control Center store; confirmation pending, no respawn")
                    if !hideOwners.isEmpty { platform.recordAssumedHidden(hideOwners, hostedAfter: nil) }
                    platform.clearExpectedToVanish()
                    var out = BatchOutcome(perKey: Dictionary(uniqueKeysWithValues: expectations.keys.map { ($0, ActuationResult.verified(final)) }),
                                           result: .verified(final))
                    out.mechanism = .liveUnverified; out.elapsedMS = ms
                    out.note = "applied per Control Center store; confirmation pending"
                    return out
                }
            } else if restartAllowed() {
                note("live hide/show unavailable (no app-group entitlement); using respawn")
            } else {
                note("live hide/show unavailable (no app-group entitlement) and agent restart is not allowed; failing the batch")
                return uniform(changes.keys, .failed(.liveWriteFailed("no app-group entitlement for live writes"), snap))
            }
        }
        // Layout before the restart (docs/findings-restart-collateral.md): MenuBarAgent re-bases the stored positions on
        // every restart, and the re-based values can re-sort items. Remember the store values so the order can be restored.
        platform.clearExpectedToVanish()
        platform.clearAssumedHidden(pids: members)   // the respawn rebuilds the layout; no write-time assumption survives it
        let store0 = (try? platform.readOrderStore()) ?? [:]
        // Participants: every item the agent lays out by store value, on the bar now (stale or not: its store value is still
        // its slot) plus the items about to be shown (their slot is their parked value). Hidden items drop out.
        let shownKeys = Set(expectations.filter { !$0.value }.map(\.key))
        let order0 = storeOrder(resolved, store0, extra: shownKeys, excluding: Set(expectations.filter { $0.value }.map(\.key)))
        let batchKeys = Set(expectations.keys)
        let frames0 = freshFrameOrder(resolved, excluding: batchKeys)
        await platform.waitForOrderStoreQuiet()
        do { try platform.writeAllowed(wantByApp.mapValues { !$0 })  }   // isAllowed == !hidden
        catch { return uniform(changes.keys, .failed(.mechanismFailed("could not write Control Center preferences: \(error)"), snap)) }

        func collateralChanges(_ rs: [ResolvedItem]) -> Set<String> {
            var c = Set<String>()
            // Only "fresh and on the bar before" -> "fresh and off the bar after" is a collateral change. Items that
            // were off the bar before (or unreadable) and are on it now are re-layout after the restart, not a change.
            for (k, wasOn) in before where expectations[k] == nil && wasOn {
                if let now = rs.first(where: { $0.key == k }), !now.item.stale, !ActuationVerifier.onBar(now) {
                    c.insert("\(k) is now off the bar")
                }
            }
            return c
        }
        let memberPIDs = members
        func confirmedCollateral(_ rs: [ResolvedItem], allOK: Bool) async -> [String] {
            var found = collateralChanges(rs)
            if !found.isEmpty && allOK {
                // Other apps re-lay out their items while the agent comes back; only a change that survives a
                // second settled observation counts as collateral.
                await platform.sleep(1.0)
                let again = await settleDetector(subjectPIDs: memberPIDs).settled(maxWait: config.settleMaxWait, stableFor: config.stableFor)
                found.formIntersection(collateralChanges(platform.resolve(again.snapshot)))
                note("batch collateral re-check: \(found.count) persist")
            }
            return found.sorted()
        }
        var last: (settled: Bool, verdicts: [ItemKey: ActuationVerifier.Verdict], collateral: [String]) = (false, [:], [])
        for round in 1...2 {
            batchRespawned = true
            let r = await platform.restartAgent(timeout: config.restartTimeout, expectedChange: expectedChange)
            note("batch restart \(round) recovered=\(r.recovered) \(r.elapsedMS)ms")
            let out = await settleDetector(subjectPIDs: members).settled(maxWait: config.settleMaxWait, stableFor: config.stableFor)
            snap = out.snapshot
            resolved = platform.resolve(snap)
            let v = verdicts(resolved)
            let collateral = await confirmedCollateral(resolved, allOK: v.values.allSatisfy(\.ok))
            last = (out.settled, v, collateral)
            note("batch round \(round): settled=\(out.settled) ok=\(v.values.filter(\.ok).count)/\(v.count) collateral=\(collateral.count)" + (out.settled || out.trace.isEmpty ? "" : " trace=[\(out.trace)]"))
            if out.settled && v.values.allSatisfy(\.ok) && collateral.isEmpty { break }
            // One retry only if the flags landed and nothing visible changed yet.
            guard round == 1,
                  let landed = try? platform.readAllowed(Array(wantByApp.keys)), landed == wantByApp.mapValues({ !$0 }),
                  v.values.allSatisfy({ !$0.ok }) else { break }
        }
        var driftFailure: ActuationError?
        if last.settled, last.verdicts.values.allSatisfy(\.ok), last.collateral.isEmpty {
            func drift(_ rs: [ResolvedItem]) -> (drifted: Bool, store1: [String: Double], storeWant: [ItemKey]) {
                let store1 = (try? platform.readOrderStore()) ?? [:]
                let order1 = storeOrder(rs, store1, extra: [], excluding: [])
                let storeWant = order0.filter(Set(order1).contains)
                let storeGot = order1.filter(Set(storeWant).contains)
                let storeDrift = storeWant.count >= 2 && storeWant != storeGot
                // Frame check: fresh on-bar keys, minus the keys being hidden/shown, must keep their relative order.
                let f1 = freshFrameOrder(rs, excluding: batchKeys)
                let common = Set(frames0).intersection(f1)
                let frameDrift = frames0.filter(common.contains) != f1.filter(common.contains)
                return (storeDrift || frameDrift, store1, storeWant)
            }
            let d0 = drift(resolved)
            if d0.drifted {
                driftRepairs += 1
                note("batch order drift after restart (store or frames); writing the pre-restart store values back")
                let expected = frames0.map(\.description).joined(separator: ", ")
                if let o = await restoreStoreValues(order0, before: store0, now: d0.store1, members: members) {
                    snap = o.snapshot
                    resolved = platform.resolve(snap)
                    let v = verdicts(resolved)
                    let coll = await confirmedCollateral(resolved, allOK: v.values.allSatisfy(\.ok))
                    last = (o.settled, v, coll)
                    let d1 = drift(resolved)
                    note("batch after order repair: settled=\(o.settled) ok=\(v.values.filter(\.ok).count)/\(v.count) collateral=\(coll.count) drift=\(d1.drifted)" + (o.settled || o.trace.isEmpty ? "" : " trace=[\(o.trace)]"))
                    if d1.drifted {
                        driftFailure = .notVerified(expected: "relative order kept: \(expected)",
                                                    observed: "order drifted and the repair did not restore it: " + freshFrameOrder(resolved, excluding: batchKeys).map(\.description).joined(separator: ", "))
                    }
                } else {
                    driftFailure = .notVerified(expected: "relative order kept: \(expected)",
                                                observed: "order drifted and the repair could not be applied: " + freshFrameOrder(resolved, excluding: batchKeys).map(\.description).joined(separator: ", "))
                }
            }
        }
        var outcome = finish(expectations, last.verdicts, snap, settled: last.settled, collateral: last.collateral)
        outcome.mechanism = .respawn
        outcome.elapsedMS = Int(platform.now().timeIntervalSince(respawnStart) * 1000)
        if let f = driftFailure, outcome.result.isVerified { outcome.result = .failed(f, snap) }
        return outcome
    }

    private func selfPositioning(_ k: ItemKey) -> Bool {
        SelfPositioning.isSelfPositioning(k, owners: config.selfPositioningOwners)
    }

    /// Number of batches whose post-restart drift check triggered a repair (diagnostics for the soak).
    public private(set) var driftRepairs = 0

    /// Fresh (non-stale) on-bar keys left to right by frame whose frame is trustworthy (`ResolvedItem.frameTrusted`: an AX
    /// identifier, or an identifier-less item whose owner/hosted pairing was corroborated, gdu.28), minus `excluding`, minus
    /// bare-heuristic keys and self-positioning owners.
    private func freshFrameOrder(_ rs: [ResolvedItem], excluding: Set<ItemKey>) -> [ItemKey] {
        var seen = Set<ItemKey>()
        return ActuationVerifier.barOrder(rs).filter { $0.confidence != .heuristic && !$0.item.stale && !excluding.contains($0.key) && !selfPositioning($0.key)
                // Items without an AX identifier are attributed by frame join, which mislabels neighbours (docs/findings-drag
                // pitfall 2): signal/GateOpener swapped with an unchanged store. Their frame is evidence only when the scanner
                // corroborated the pairing (description match or a mutual-exclusive frame overlap, `JoinEvidence`).
                && $0.frameTrusted }
            .map(\.key).filter { seen.insert($0).inserted }
    }

    /// Items the agent lays out by order-store value (status and module keys with an entry, non-heuristic), sorted by that
    /// value, biggest = leftmost. Includes stale items (their value is their slot; their frame is not trusted) and `extra`
    /// keys even when parked; `excluding` drops keys.
    private func storeOrder(_ rs: [ResolvedItem], _ store: [String: Double], extra: Set<ItemKey>, excluding: Set<ItemKey>) -> [ItemKey] {
        var seen = Set<ItemKey>()
        let keys = rs.filter { r in
            guard r.confidence.isStoreBacked, !excluding.contains(r.key), !selfPositioning(r.key), store[r.key.description] != nil else { return false }
            if case .heuristic = r.key { return false }
            return ActuationVerifier.onBar(r) || extra.contains(r.key)
        }.map(\.key).filter { seen.insert($0).inserted }
        return keys.sorted { (store[$0.description]!, $0.description) > (store[$1.description]!, $1.description) }
    }

    /// Writes the pre-restart store values of `keys` back (status AND module keys: the agent re-bases both), restarts once
    /// and settles. nil when there is nothing to write.
    private func restoreStoreValues(_ keys: [ItemKey], before: [String: Double], now: [String: Double], members: Set<pid_t>) async -> SettleOutcome? {
        var updates: [String: Double] = [:]
        for k in keys { if let v = before[k.description], now[k.description] != v { updates[k.description] = v } }
        await platform.waitForOrderStoreQuiet()
        if !updates.isEmpty {
            do { try platform.writeOrderStore(updates, allowModules: true) } catch { note("order repair write failed: \(error)"); return nil }
        }
        batchRespawned = true
        let r = await platform.restartAgent(timeout: config.restartTimeout, expectedChange: 0)
        note("order repair restart recovered=\(r.recovered) \(r.elapsedMS)ms wrote=\(updates.count)")
        return await settleDetector(subjectPIDs: members).settled(maxWait: config.settleMaxWait, stableFor: config.stableFor)
    }

    private func finish(_ expectations: [ItemKey: Bool], _ v: [ItemKey: ActuationVerifier.Verdict], _ snap: MenuBarSnapshot,
                        settled: Bool, collateral: [String]) -> BatchOutcome {
        var per: [ItemKey: ActuationResult] = [:]
        for k in expectations.keys {
            let verdict = v[k]!
            if verdict.ok && settled { per[k] = .verified(snap) }
            else if verdict.ok { per[k] = .failed(.timeout, snap) }
            else { per[k] = .failed(verdict.error!, snap) }
        }
        let result: ActuationResult
        if let bad = per.sorted(by: { $0.key.description < $1.key.description }).first(where: { !$0.value.isVerified }) {
            if case .failed(let e, _) = bad.value, case .timeout = e { result = .failed(.timeout, snap) }
            else {
                let failing = per.filter { !$0.value.isVerified }.keys.map(\.description).sorted()
                let observed = per.compactMap { (k, r) -> String? in
                    if case .failed(.notVerified(_, let o), _) = r { return "\(k): \(o)" } else { return nil }
                }.sorted().joined(separator: "; ")
                result = .failed(.notVerified(expected: "all of \(expectations.count) items in the requested state",
                                              observed: "failed: \(failing.joined(separator: ", ")); \(observed)"), snap)
            }
        } else if !collateral.isEmpty {
            result = .failed(.notVerified(expected: "no other item changes", observed: collateral.joined(separator: "; ")), snap)
        } else {
            result = .verified(snap)
        }
        return BatchOutcome(perKey: per, result: result)
    }
}
