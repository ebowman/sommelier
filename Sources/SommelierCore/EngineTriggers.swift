import AppKit
import Foundation

/// Wires external events to `LayoutEngine.requestReconcile()`: app launch/quit (coalesced: a burst within 1 s is one pass),
/// sleep/wake (no pass across sleep; reconcile 3 s after wake) and a poll (e7t) that triggers a pass only when the
/// `BarSignature` of a fast scan CHANGED from the baseline and a confirming scan 1 s later shows the same new signature.
/// The signature is the one `AgreedScanObserver` uses for agreement (iStat order, WiFi/Focus presence, heuristic noise,
/// stale flags and width<=1 entries do not count). The baseline is the signature seen by the previous quiet poll and is
/// dropped whenever a pass ran/was requested or a user action happened, so the pass's own changes never re-trigger.
/// The period backs off while quiet. No logic here beyond wiring; the engine coalesces triggers.
public struct PollConfig: Sendable {
    /// Base period; 10 s.
    public var interval: TimeInterval = 10
    /// Delay of the confirming scan.
    public var confirmDelay: TimeInterval = 1
    /// Back-off: after `quietPollsPerStep` consecutive quiet polls the period grows by `interval` (10, 20, 30 s), capped at
    /// `maxInterval`. Reset by any detected change, user action or app launch/quit.
    public var quietPollsPerStep: Int = 3
    public var maxInterval: TimeInterval = 30
    /// No poll pass within this many seconds of a user-initiated request.
    public var userQuietPeriod: TimeInterval = 5
    public init() {}

    public func period(quietPolls: Int) -> TimeInterval {
        min(maxInterval, interval * Double(1 + quietPolls / max(1, quietPollsPerStep)))
    }
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
    private var tokens: [any NSObjectProtocol] = []
    private var timer: Timer?
    // Poll state.
    private var baseline: BarSignature.Value?
    private var lastPassesStarted: Int?
    private var lastUserActions: Int?
    private(set) var quietPolls = 0
    private(set) var polls = 0
    private(set) var triggered = 0

    /// `gate`, `trigger` and `sleep` are test seams; the defaults read the engine.
    public init(engine: LayoutEngine, state: EngineState, scanner: any SnapshotScanning,
                resolve: @escaping @Sendable (MenuBarSnapshot) -> [ResolvedItem], config: PollConfig = PollConfig(),
                signature: BarSignature = BarSignature(), log: @escaping @Sendable (String) -> Void = { _ in },
                gate: (() async -> PollGate)? = nil, trigger: (() async -> Void)? = nil,
                sleep: ((Duration) async -> Void)? = nil) {
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
    }

    public func start() {
        guard tokens.isEmpty else { return }
        let engine = engine
        Task { await engine.resumeFromSleep() }   // a wake missed while stopped must not leave the engine asleep
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleDebounced() }
            })
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
        timer?.invalidate(); timer = nil
    }

    private func scheduleNextPoll() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: config.period(quietPolls: quietPolls), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.tokens.isEmpty else { return }
                await self.poll()
                if !self.tokens.isEmpty { self.scheduleNextPoll() }
            }
        }
    }

    /// Trailing 1 s window per burst: the engine replaces a pending request with the same reason.
    private func scheduleDebounced() {
        quietPolls = 0; baseline = nil
        let engine = engine
        Task { await engine.scheduleReconcile(after: .seconds(1), reason: "app launch/quit") }
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

    func poll() async {
        polls += 1
        let g = await gate()
        // A user action or a pass since the previous poll invalidates the baseline and the back-off.
        if let last = lastUserActions, last != g.userActions { baseline = nil; quietPolls = 0 }
        lastUserActions = g.userActions
        if let last = lastPassesStarted, last != g.passesStarted { baseline = nil; quietPolls = 0 }
        lastPassesStarted = g.passesStarted
        if let why = skipReason(g) { baseline = nil; log("poll skipped: \(why)"); return }
        guard let sig = await scanSignature() else { return }
        guard let base = baseline else { baseline = sig; return }
        if sig == base { quietPolls += 1; return }
        // Changed: confirm with a second scan before acting (a one-scan flicker never triggers).
        let what = sig.diff(from: base)
        await sleep(.seconds(config.confirmDelay))
        let g2 = await gate()
        if let why = skipReason(g2) ?? (g2.passesStarted != g.passesStarted ? "a pass started" : nil) {
            baseline = nil; log("poll change not confirmed (\(why)): \(what)"); return
        }
        guard let sig2 = await scanSignature() else { log("poll change not confirmed (unusable scan): \(what)"); quietPolls += 1; return }
        guard sig2 == sig else {
            log("poll change not confirmed (second scan differs: \(sig2.diff(from: sig))): \(what)")
            quietPolls = 0
            return
        }
        triggered += 1; quietPolls = 0; baseline = nil
        log("poll change confirmed, requesting a pass: \(what)")
        await trigger()
    }
}
