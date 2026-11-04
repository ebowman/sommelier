import AppKit
import Foundation

/// Wires external events to `LayoutEngine.requestReconcile()`: app launch/quit (debounced 1 s) and a 10 s poll that
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
    private var debounce: Task<Void, Never>?

    public init(engine: LayoutEngine, state: EngineState, scanner: any SnapshotScanning,
                resolve: @escaping @Sendable (MenuBarSnapshot) -> [ResolvedItem], pollInterval: TimeInterval = 10) {
        self.engine = engine; self.state = state; self.scanner = scanner; self.resolve = resolve
        self.pollInterval = pollInterval
    }

    public func start() {
        guard tokens.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleDebounced() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    public func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        for t in tokens { nc.removeObserver(t) }
        tokens = []
        timer?.invalidate(); timer = nil
        debounce?.cancel(); debounce = nil
    }

    private func scheduleDebounced() {
        debounce?.cancel()
        let engine = engine
        debounce = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await engine.requestReconcile()
        }
    }

    private func poll() async {
        let fresh = ObservedOrder(resolved: resolve(await scanner.scanVisible()))
        guard !fresh.onBar.isEmpty else { return }
        let cur = state.observed
        // On-bar order only: the fast scan can omit parked items, so comparing the parked set would trigger spuriously.
        if fresh.onBar != cur.onBar { await engine.requestReconcile() }
    }
}
