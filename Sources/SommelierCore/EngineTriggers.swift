import AppKit
import Foundation

/// Wires external events to `LayoutEngine.requestReconcile()`: app launch/quit (coalesced: a burst within 1 s is one pass),
/// sleep/wake (no pass across sleep; reconcile 3 s after wake) and a 10 s poll that
/// only triggers when a fast scan shows a different on-bar order or parked set than `EngineState.observed`.
/// No logic here beyond wiring; the engine coalesces triggers.
@MainActor
public final class EngineTriggers {
    private let engine: LayoutEngine
    private let state: EngineState
    private let scanner: any SnapshotScanning
    private let resolve: @Sendable (MenuBarSnapshot) -> [ResolvedItem]
    private let pollInterval: TimeInterval
    private var tokens: [any NSObjectProtocol] = []
    private var timer: Timer?

    public init(engine: LayoutEngine, state: EngineState, scanner: any SnapshotScanning,
                resolve: @escaping @Sendable (MenuBarSnapshot) -> [ResolvedItem], pollInterval: TimeInterval = 10) {
        self.engine = engine; self.state = state; self.scanner = scanner; self.resolve = resolve
        self.pollInterval = pollInterval
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
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    public func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        for t in tokens { nc.removeObserver(t) }
        tokens = []
        timer?.invalidate(); timer = nil
    }

    /// Trailing 1 s window per burst: the engine replaces a pending request with the same reason.
    private func scheduleDebounced() {
        let engine = engine
        Task { await engine.scheduleReconcile(after: .seconds(1), reason: "app launch/quit") }
    }

    private func poll() async {
        let fresh = ObservedOrder(resolved: resolve(await scanner.scanVisible()))
        guard !fresh.onBar.isEmpty else { return }
        let cur = state.observed
        // On-bar order only: the fast scan can omit parked items, so comparing the parked set would trigger spuriously.
        if fresh.onBar != cur.onBar { await engine.requestReconcile() }
    }
}
