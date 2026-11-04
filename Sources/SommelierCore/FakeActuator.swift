import Foundation

/// In-memory actuator for tests and UI development. Order is left-to-right; hidden items are removed from the order
/// view but remembered in `hidden`. Scripted failures: `failOnCall(n, error)` fails the Nth call (1-based, all methods
/// counted together) without mutating state.
public actor FakeActuator: MenuBarActuator {
    public enum Call: Equatable, Sendable {
        case move(ItemKey, Relation)
        case setHidden(ItemKey, Bool)
        case applyHiddenBatch([ItemKey: Bool])
    }

    public private(set) var order: [ItemKey]
    public private(set) var hidden: Set<ItemKey>
    public private(set) var calls: [Call] = []
    private var scripted: [Int: ActuationError] = [:]
    private var drift: [Int: (String, String)] = [:]
    private let capabilities: any CapabilityProvider
    private let makeSnapshot: @Sendable ([ItemKey], Set<ItemKey>) -> MenuBarSnapshot

    public init(order: [ItemKey], hidden: Set<ItemKey> = [],
                capabilities: any CapabilityProvider = CapabilityRules(hasTrackedEntry: { _ in true }),
                makeSnapshot: @escaping @Sendable ([ItemKey], Set<ItemKey>) -> MenuBarSnapshot = { _, _ in
                    MenuBarSnapshot(items: [], capturedAt: Date(timeIntervalSince1970: 0)) }) {
        self.order = order
        self.hidden = hidden
        self.capabilities = capabilities
        self.makeSnapshot = makeSnapshot
    }

    /// Makes the Nth call apply its changes normally but report `.failed(.notVerified(expected:observed:), snapshot)`.
    public func scriptDrift(onCall n: Int, expected: String, observed: String) { drift[n] = (expected, observed) }
    /// Moves `key` to `index` in the order without recording a call (simulates an item shifted by the agent restart).
    public func displace(_ key: ItemKey, toIndex index: Int) {
        guard let i = order.firstIndex(of: key) else { return }
        order.remove(at: i); order.insert(key, at: min(index, order.count))
    }

    /// Every `applyHiddenBatch` takes this long between starting and applying (a slow live write).
    public func setBatchDelay(_ d: Duration) { batchDelay = d }
    /// Batches that have started (counted before their delay), for tests that act while one is in flight.
    public private(set) var batchStarts = 0
    private var batchDelay: Duration = .zero

    public func failOnCall(_ n: Int, _ error: ActuationError) { scripted[n] = error }

    private func snapshot() -> MenuBarSnapshot { makeSnapshot(order, hidden) }

    /// Records the call; returns a scripted failure if one is due.
    private func begin(_ call: Call) -> ActuationResult? {
        calls.append(call)
        if let e = scripted[calls.count] { return .failed(e, snapshot()) }
        return nil
    }

    public func move(_ key: ItemKey, relation: Relation) async -> ActuationResult {
        if let f = begin(.move(key, relation)) { return f }
        guard let from = order.firstIndex(of: key) else { return .failed(.notFound, snapshot()) }
        let cap = capabilities.capability(for: key)
        guard cap.canMove else { return .failed(.unsupportedItem(reason: cap.reason ?? "cannot move"), snapshot()) }
        var rest = order
        rest.remove(at: from)
        let to: Int
        switch relation {
        case .leftmost: to = 0
        case .rightmost: to = rest.count
        case .before(let t), .after(let t):
            guard t != key, let i = rest.firstIndex(of: t) else { return .failed(.notFound, snapshot()) }
            if case .before = relation { to = i } else { to = i + 1 }
        }
        rest.insert(key, at: to)
        order = rest
        return .verified(snapshot())
    }

    public func setHidden(_ key: ItemKey, _ hide: Bool) async -> ActuationResult {
        if let f = begin(.setHidden(key, hide)) { return f }
        return apply([key: hide])
    }

    public func applyHiddenBatch(_ changes: [ItemKey: Bool]) async -> ActuationResult {
        if let f = begin(.applyHiddenBatch(changes)) { return f }
        let n = calls.count
        batchStarts += 1
        if batchDelay > .zero { try? await Task.sleep(for: batchDelay) }
        let r = apply(changes)
        if let d = drift[n], case .verified = r {
            return .failed(.notVerified(expected: d.0, observed: d.1), snapshot())
        }
        return r
    }

    /// All-or-nothing: validates every key before mutating.
    private func apply(_ changes: [ItemKey: Bool]) -> ActuationResult {
        for key in changes.keys {
            guard order.contains(key) || hidden.contains(key) else { return .failed(.notFound, snapshot()) }
            let cap = capabilities.capability(for: key)
            guard cap.canHide else { return .failed(.unsupportedItem(reason: cap.reason ?? "cannot hide"), snapshot()) }
        }
        for (key, hide) in changes {
            if hide { hidden.insert(key) } else { hidden.remove(key) }
        }
        return .verified(snapshot())
    }
}
