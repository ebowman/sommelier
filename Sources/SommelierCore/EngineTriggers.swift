import AppKit
import Foundation

/// Wires external events to `LayoutEngine.requestReconcile()`: app launch/quit (coalesced: a burst within 1 s is one pass),
/// sleep/wake (no pass across sleep; reconcile 3 s after wake) and a poll (e7t) that triggers a pass only when the
/// `BarSignature` of a fast scan CHANGED from the baseline and a confirming scan 1 s later shows the same new signature.
/// The signature is the one `AgreedScanObserver` uses for agreement (iStat order, WiFi/Focus presence, heuristic noise,
/// stale flags and width<=1 entries do not count). The reference is the signature of the engine's latest observation (published
/// with every pass), else the last quiet poll's: a change after a pass's last observation is caught by the next poll, and a skip
/// never drops the reference.
/// Fixed period (no back-off: worst-case detection stays within 12 s). No logic here beyond wiring; the engine coalesces triggers.
public struct PollConfig: Sendable {
    /// Base period; 10 s.
    public var interval: TimeInterval = 10
    /// Delay of the confirming scan.
    public var confirmDelay: TimeInterval = 1
    /// No poll pass within this many seconds of a user-initiated request.
    public var userQuietPeriod: TimeInterval = 5
    /// Cap on poll-triggered passes within any sliding minute (gdu.58): an unexempted two-state flapper would otherwise trigger
    /// a pass every 10-20 s. Launch/quit triggers and user actions are not counted and not limited.
    public var maxPollPassesPerMinute = 2
    /// How long the poll triggers nothing once the cap was hit (it keeps scanning); 5 min.
    public var suppressFor: TimeInterval = 300
    public init() {}

    /// Worst-case detection latency of a change: one full period plus the confirming scan (about 11 s; goal: 12 s).
    public var worstCaseDetection: TimeInterval { interval + confirmDelay }
}

/// One running process as the launch/quit path sees it (gdu.56).
public struct RunningApp: Sendable, Equatable {
    public var pid: Int32
    public var bundleID: String?
    public var policy: NSApplication.ActivationPolicy
    public init(pid: Int32, bundleID: String?, policy: NSApplication.ActivationPolicy) {
        self.pid = pid; self.bundleID = bundleID; self.policy = policy
    }
}

/// Source of the running-apps list (gdu.56). `LiveRunningApps` observes `NSWorkspace.runningApplications` with KVO, which (unlike
/// `didLaunchApplicationNotification`, which AppKit does not post for agent/background apps) covers every activation policy.
/// Tests inject a fake and push changes.
@MainActor
public protocol RunningAppsSource: AnyObject {
    func current() -> [RunningApp]
    /// Calls `onChange` (main actor) whenever the list may have changed; replaces any earlier handler.
    func startObserving(_ onChange: @escaping @MainActor () -> Void)
    func stopObserving()
}

@MainActor
public final class LiveRunningApps: NSObject, RunningAppsSource {
    private var observation: NSKeyValueObservation?
    public override init() { super.init() }
    public func current() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.map { RunningApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, policy: $0.activationPolicy) }
    }
    public func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        observation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { _, _ in
            Task { @MainActor in onChange() }
        }
    }
    public func stopObserving() { observation?.invalidate(); observation = nil }
}

@MainActor
public final class EngineTriggers {
    private let engine: LayoutEngine
    private let state: EngineState
    private let scanner: any SnapshotScanning
    private let resolve: @Sendable (MenuBarSnapshot) -> [ResolvedItem]
    private let config: PollConfig
    private let signature: BarSignature
    private let log: @Sendable (String) -> Void
    private let gate: () async -> PollGate
    private let trigger: () async -> Void
    private let sleep: (Duration) async -> Void
    private let now: @Sendable () -> Date
    private let report: (PollSuppression?) async -> Void
    private let apps: any RunningAppsSource
    private let ownerPIDs: () -> Set<Int32>?
    private let launchQuitTrigger: () async -> Void
    /// pid -> app as of the last diff: the single dedupe point for the notification and the KVO path (one launch = one event).
    private var known: [Int32: RunningApp] = [:]
    private var tokens: [any NSObjectProtocol] = []
    private var timer: Timer?
    // Poll state.
    private var baseline: BarSignature.Value?
    /// In-poll reference, valid only while the engine has published nothing newer (`baselineSerial`).
    private var baselineSerial = -1
    /// The signature that last triggered a pass: a second trigger for the same bar means the pass cannot change it (e.g. a parked
    /// item the fast scan sees differently), so it is not repeated.
    private var lastTriggered: BarSignature.Value?
    /// Poll-trigger timestamps (sliding minute) and the active suppression window (gdu.58).
    private var triggerTimes: [Date] = []
    /// Free-confirm bookkeeping (gdu.60): the signature that was steady (read unchanged for at least a minute) before the latest
    /// counted change, and whether that change's single free "confirm" (the return to it) is still unused.
    private var preChange: BarSignature.Value?
    private var confirmFree = false
    /// The latest pass was a free confirm (so `preChange` is steady again), and the signature of the latest counted change.
    private var lastWasConfirm = false
    /// Signatures of the counted changes within the last `suppressFor` (the repeat horizon, gdu.60); cleared by `stop()`.
    private var countedHistory: [(sig: BarSignature.Value, at: Date)] = []
    private var suppressedUntil: Date?
    /// The last scan signature and the most recent one that differed from it (the flapping pair).
    private var lastSeen: BarSignature.Value?
    private var priorDifferent: BarSignature.Value?
    /// When `lastSeen` first appeared, and how long `priorDifferent` had been the reading before `lastSeen` replaced it.
    private var seenSince = Date.distantPast
    private var priorHeld: TimeInterval = 0
    private(set) var polls = 0
    private(set) var triggered = 0

    /// `gate`, `trigger` and `sleep` are test seams; the defaults read the engine.
    public init(engine: LayoutEngine, state: EngineState, scanner: any SnapshotScanning,
                resolve: @escaping @Sendable (MenuBarSnapshot) -> [ResolvedItem], config: PollConfig = PollConfig(),
                signature: BarSignature = BarSignature(), log: @escaping @Sendable (String) -> Void = { _ in },
                gate: (() async -> PollGate)? = nil, trigger: (() async -> Void)? = nil,
                sleep: ((Duration) async -> Void)? = nil, now: @escaping @Sendable () -> Date = { Date() },
                reportSuppression: ((PollSuppression?) async -> Void)? = nil,
                apps: (any RunningAppsSource)? = nil, ownerPIDs: @escaping () -> Set<Int32>? = { nil },
                launchQuitTrigger: (() async -> Void)? = nil) {
        self.now = now
        self.apps = apps ?? LiveRunningApps()
        self.ownerPIDs = ownerPIDs
        self.launchQuitTrigger = launchQuitTrigger ?? { [engine] in
            // Trailing 1 s window per burst: the engine replaces a pending request with the same reason.
            await engine.scheduleReconcile(after: .seconds(1), reason: "app launch/quit")
        }
        self.engine = engine; self.state = state; self.scanner = scanner; self.resolve = resolve
        self.config = config; self.signature = signature; self.log = log
        self.gate = gate ?? { [engine, state] in
            var g = await engine.pollGate()
            g.passesStarted = state.passesStarted
            g.observationSettled = state.observationSettled
            return g
        }
        self.trigger = trigger ?? { [engine] in await engine.requestReconcile(reason: "poll") }
        self.sleep = sleep ?? { try? await Task.sleep(for: $0) }
        self.report = reportSuppression ?? { [engine] in await engine.setPollSuppression($0) }
    }

    public func start() {
        guard tokens.isEmpty else { return }
        let engine = engine
        Task { await engine.resumeFromSleep() }   // a wake missed while stopped must not leave the engine asleep
        let nc = NSWorkspace.shared.notificationCenter
        known = Dictionary(apps.current().map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        // Notification path: logged for diagnosis, then the same pid diff as KVO (so both for one pid make ONE event). AppKit does
        // not reliably post these for agent (LSUIElement) apps; the KVO path below covers them (gdu.56).
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let launch = n.name == NSWorkspace.didLaunchApplicationNotification
                let note = app.map { RunningApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, policy: $0.activationPolicy) }
                let what = app.map { "\(n.name.rawValue): pid \($0.processIdentifier) bundle \($0.bundleIdentifier ?? "-") policy \($0.activationPolicy.rawValue)" }
                Task { @MainActor in
                    guard let self else { return }
                    if let what { self.log("notification \(what)") }
                    await self.syncApps(notified: note.map { ($0, launch) })
                }
            })
        }
        apps.startObserving { [weak self] in
            Task { @MainActor in await self?.syncApps() }
        }
        tokens.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let engine = self?.engine else { return }
            Task { await engine.willSleep() }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let engine = self?.engine else { return }
            Task { await engine.didWake() }
        })
        scheduleNextPoll()
    }

    public func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        for t in tokens { nc.removeObserver(t) }
        tokens = []
        apps.stopObserving()
        timer?.invalidate(); timer = nil
        countedHistory = []; triggerTimes = []; preChange = nil; confirmFree = false; lastWasConfirm = false
    }

    private func scheduleNextPoll() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: config.interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.tokens.isEmpty else { return }
                await self.poll()
                if !self.tokens.isEmpty { self.scheduleNextPoll() }
            }
        }
    }

    /// Diffs the running apps against `known`; ONE launch/quit request per call that found a relevant change (a burst of helpers is
    /// further coalesced by the engine's trailing 1 s window). Launch: policy .accessory or .regular (menu-bar-only utilities are
    /// .accessory; .prohibited background apps own no items). Quit: an app that was .accessory/.regular and, when the owner set is
    /// known, owned an item in the latest scan; with ownership unknown (`ownerPIDs()` nil) any such app counts.
    /// `notified`: a didLaunch/didTerminate notification always requests (re-arms) the pass even when KVO already updated `known`:
    /// KVO fires at process registration, the notification when the app finished launching, and its status item may appear after
    /// the KVO pass already scanned (same-reason requests replace each other within the debounce, so close arrivals stay one pass).
    func syncApps(notified: (app: RunningApp, launch: Bool)? = nil) async {
        let now = Dictionary(apps.current().map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let launched = now.values.filter { known[$0.pid] == nil }
        let quit = known.values.filter { now[$0.pid] == nil }
        known = now
        func visible(_ a: RunningApp) -> Bool { a.policy == .accessory || a.policy == .regular }
        let owners = ownerPIDs()
        var force = false
        if let n = notified, visible(n.app), n.launch || (owners?.contains(n.app.pid) ?? true) { force = true }
        guard !launched.isEmpty || !quit.isEmpty || force else { return }
        let l = launched.filter(visible)
        let q = quit.filter { visible($0) && (owners?.contains($0.pid) ?? true) }
        for a in launched { log("launch pid \(a.pid) bundle \(a.bundleID ?? "-") policy \(a.policy.rawValue)\(visible(a) ? "" : " (ignored)")") }
        for a in quit { log("quit pid \(a.pid) bundle \(a.bundleID ?? "-") policy \(a.policy.rawValue)\(q.contains(a) ? "" : " (ignored)")") }
        guard force || !l.isEmpty || !q.isEmpty else { return }
        await launchQuitTrigger()
    }

    /// Signature of a fresh fast scan; nil when unusable (empty bar, or a non-self-positioning stale item on the bar).
    private func scanSignature() async -> BarSignature.Value? {
        let res = AgreedScanObserver.dedupe(resolve(await scanner.scanVisible())).items
        guard res.contains(where: { $0.item.isOnMenuBar && $0.item.frame.width > 1 }) else { return nil }
        return signature.value(res)?.forPoll(selfPositioningOwners: signature.selfPositioningOwners)
    }

    /// Skip rules: a pass running/requested, a transient reveal hold, an unsettled observation, a recent user action.
    private func skipReason(_ g: PollGate) -> String? {
        if g.busy { return "a pass is running or requested" }
        if g.holdActive { return "a transient reveal hold is active" }
        if !g.observationSettled { return "the observation is not settled" }
        if let s = g.secondsSinceUserAction, s < config.userQuietPeriod { return "a user action \(Int(s)) s ago" }
        return nil
    }

    /// Reference signature: the in-poll baseline while the engine has published nothing newer; otherwise the engine's own latest
    /// observation, so anything that changed after a pass's last observation is caught by the next poll. Skips never drop it.
    private func reference(_ g: PollGate) -> BarSignature.Value? {
        if let b = baseline, baselineSerial == g.engineSignatureSerial { return b }
        return g.engineSignature
    }

    func poll() async {
        polls += 1
        let g = await gate()
        if let why = skipReason(g) { log("poll skipped: \(why)"); return }
        guard let sig = await scanSignature() else { return }
        if let l = lastSeen, l != sig { priorDifferent = l; priorHeld = now().timeIntervalSince(seenSince); seenSince = now() }
        else if lastSeen == nil { seenSince = now() }
        lastSeen = sig
        // Suppression window (gdu.58): keep scanning (the pair above stays current), trigger nothing. A genuine single change
        // during the window is therefore also left to the next launch/quit trigger or user action, or to the first poll after it.
        if let until = suppressedUntil {
            if now() < until { return }
            suppressedUntil = nil
            await report(nil)
            log("poll: suppression ended, resuming")
        }
        // The guard holds only while the bar keeps reading as the signature that last triggered a pass: any other reading (e.g. the
        // bar fixed by that pass) clears it, so a later recurrence of the same change triggers again.
        if sig != lastTriggered { lastTriggered = nil }
        guard let base = reference(g) else { baseline = sig; baselineSerial = g.engineSignatureSerial; return }
        if sig == base {
            baseline = sig; baselineSerial = g.engineSignatureSerial
            // gdu.77: the bar still reads as the engine's own latest observation (not merely as an earlier poll): refresh its age.
            if sig == g.engineSignature { await engine.notePollUnchanged(serial: g.engineSignatureSerial) }
            return
        }
        // Changed: confirm with a second scan before acting (a one-scan flicker never triggers).
        let what = sig.diff(from: base)
        await sleep(.seconds(config.confirmDelay))
        let g2 = await gate()
        if let why = skipReason(g2) ?? (g2.passesStarted != g.passesStarted ? "a pass started" : nil) {
            log("poll change not confirmed (\(why)): \(what)"); return
        }
        guard let sig2 = await scanSignature() else { log("poll change not confirmed (unusable scan): \(what)"); return }
        guard sig2 == sig else {
            log("poll change not confirmed (second scan differs: \(sig2.diff(from: sig))): \(what)")
            return
        }
        if sig == lastTriggered { baseline = sig; baselineSerial = g.engineSignatureSerial; log("poll change unchanged by the previous pass; not repeating: \(what)"); return }
        let t = now()
        triggerTimes.removeAll { t.timeIntervalSince($0) >= 60 }
        countedHistory.removeAll { t.timeIntervalSince($0.at) >= config.suppressFor }
        // A return to the signature that was steady before the last counted change is that change's confirm pass (a steady
        // fast/full-scan disagreement costs it once per real change): triggered, not counted, once.
        let isConfirm = confirmFree && preChange == sig
        if isConfirm {
            confirmFree = false; lastWasConfirm = true
        } else {
            if triggerTimes.count >= config.maxPollPassesPerMinute {
                let keys = Self.flappingKeys(sig, priorDifferent ?? base)
                suppressedUntil = t.addingTimeInterval(config.suppressFor)
                log("poll: suppressed for \(Int(config.suppressFor / 60)) min — flapping keys: \(keys.joined(separator: ", "))")
                await report(PollSuppression(until: suppressedUntil!, keys: keys.compactMap { ItemKey(storeKey: $0) }))
                return
            }
            // Pre-change signature of this counted change: kept while the previous counted change (still in the window) has its
            // confirm unused, and after that change's confirm restored it; otherwise the reading just before this change, if it
            // had been steady for a minute. A change identical to the previous counted one within the window (a flapper, not a
            // new real change) gets no free confirm.
            if confirmFree && !triggerTimes.isEmpty {
                // keep preChange
            } else if lastWasConfirm, preChange != nil, priorDifferent == preChange {
                // the confirm restored it
            } else if let p = priorDifferent, p != sig, priorHeld >= 60 { preChange = p } else { preChange = nil }
            let repeats = countedHistory.contains { $0.sig == sig }
            if repeats { preChange = nil }
            confirmFree = preChange != nil
            lastWasConfirm = false; countedHistory.append((sig, t))
            if repeats { triggerTimes.append(t) }   // oscillation evidence: the repeat takes two slots of the cap
            triggerTimes.append(t)
        }
        lastTriggered = sig
        triggered += 1
        // The pass will publish a newer engine signature; until then do not re-trigger for the same bar.
        baseline = sig; baselineSerial = g.engineSignatureSerial
        log("poll change confirmed, requesting a pass: \(what)")
        await trigger()
    }

    /// The minimal set of keys whose membership (on the bar / parked / present at all) or relative position differs between two
    /// signatures (gdu.60): a key whose class changed, plus the common on-bar keys that left the longest common order
    /// (`OrderDiff`: a single item moved far lists only that item, an adjacent swap lists one of the two, shifted neighbours are never listed).
    static func flappingKeys(_ a: BarSignature.Value, _ b: BarSignature.Value) -> [String] {
        func cls(_ v: BarSignature.Value, _ k: String) -> Int { v.order.contains(k) ? 1 : v.parked.contains(k) ? 2 : 0 }
        var d = Set(a.presence).symmetricDifference(b.presence)
        for k in Set(a.order).union(a.parked).union(b.order).union(b.parked) where cls(a, k) != cls(b, k) { d.insert(k) }
        let common = Set(a.order).intersection(b.order)
        d.formUnion(OrderDiff.changedKeys(a.order.filter(common.contains), b.order.filter(common.contains)))
        return d.sorted()
    }
}
