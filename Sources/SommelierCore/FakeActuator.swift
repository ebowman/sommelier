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

    /// An app quits / launches (test support): the key leaves or rejoins the bar (gdu.74).
    public func removeItem(_ key: ItemKey) { order.removeAll { $0 == key }; hidden.remove(key) }
    public func addItem(_ key: ItemKey) { if !order.contains(key) { order.append(key) } }

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

    /// Runs synchronously each time a call is recorded (before it is applied), with the 1-based call count.
    public func setAfterCall(_ f: (@Sendable (Int) -> Void)?) { afterCall = f }
    private var afterCall: (@Sendable (Int) -> Void)?

    public func failOnCall(_ n: Int, _ error: ActuationError) { scripted[n] = error }

    /// The next `batches` batches report every key as applied-but-unconfirmed (`.liveUnverified`); with `applyChange: false` the
    /// change is not actually made (the agent did not act on the store value, so a later read contradicts the claim).
    public func scriptUnconfirmed(batches: Int = 1, applyChange: Bool = true) { unconfirmedBatches = batches; unconfirmedApplies = applyChange }
    private var unconfirmedBatches = 0, unconfirmedApplies = true
    public private(set) var lastBatchUnconfirmed: Set<ItemKey> = []

    /// Units this fake refuses in a batch (key -> reason), on top of its capabilities (gdu.72). They are split off; the rest is applied.
    public func setRefusals(_ r: [ItemKey: String]) { refusals = r }
    private var refusals: [ItemKey: String] = [:]
    public private(set) var lastBatchRefused: [ItemKey: String] = [:]
    /// Keys the fake leaves alone as transiently unsettled (a stale member, gdu.76): reason by key; mutate to "settle" them.
    public private(set) var unsettled: [ItemKey: String] = [:]
    public func setUnsettled(_ u: [ItemKey: String]) { unsettled = u }
    public private(set) var lastBatchUnsettled: [ItemKey: String] = [:]

    private func snapshot() -> MenuBarSnapshot { makeSnapshot(order, hidden) }

    /// Records the call; returns a scripted failure if one is due.
    private func begin(_ call: Call) -> ActuationResult? {
        calls.append(call)
        afterCall?(calls.count)
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
        lastBatchUnconfirmed = []
        var changes = changes
        lastBatchRefused = [:]
        lastBatchUnsettled = [:]
        for key in changes.keys where unsettled[key] != nil { lastBatchUnsettled[key] = unsettled[key]; changes[key] = nil }
        if changes.isEmpty, let why = lastBatchUnsettled.values.sorted().first { return .failed(.memberStale(why), snapshot()) }
        for key in changes.keys where order.contains(key) || hidden.contains(key) {
            let cap = capabilities.capability(for: key)
            if let why = refusals[key] ?? (cap.canHide ? nil : (cap.reason ?? "cannot hide")) { lastBatchRefused[key] = why }
        }
        for k in lastBatchRefused.keys { changes[k] = nil }
        if changes.isEmpty, let why = lastBatchRefused.values.sorted().first {
            return .failed(.unsupportedItem(reason: why), snapshot())
        }
        if unconfirmedBatches > 0 {
            unconfirmedBatches -= 1
            let snap = snapshot()
            if unconfirmedApplies { _ = apply(changes) }
            lastBatchUnconfirmed = Set(changes.keys)
            return .verified(unconfirmedApplies ? snapshot() : snap)
        }
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
