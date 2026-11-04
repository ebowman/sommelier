import Foundation

public enum ObserveError: Error, Equatable, Sendable, CustomStringConvertible {
    case permissionDenied
    /// Full scans never agreed (or kept containing stale items) within the budget.
    case noAgreement(scans: Int)
    /// The bar had no on-bar item in any scan: a failed read, never a state.
    case empty

    public var description: String {
        switch self {
        case .permissionDenied: return "Accessibility permission is not granted"
        case .noAgreement(let n): return "scans did not agree after \(n) attempts"
        case .empty: return "the menu bar scan returned no items"
        }
    }
}

/// Produces the observed, resolved menu bar. Implementations must only return data they trust (no stale items).
public protocol MenuBarObserver: Sendable {
    func observe() async throws -> [ResolvedItem]
}

/// Polls full scans until two consecutive fresh scans agree (same on-bar order, same parked set), or gives up.
public struct AgreedScanObserver: MenuBarObserver {
    public var scanner: any SnapshotScanning
    public var resolve: @Sendable (MenuBarSnapshot) -> [ResolvedItem]
    public var maxScans: Int
    /// Seconds allowed per `observe()` call.
    public var deadline: TimeInterval
    public var accessibilityTrusted: @Sendable () -> Bool
    public var sleep: @Sendable (Duration) async -> Void

    public init(scanner: any SnapshotScanning,
                resolve: @escaping @Sendable (MenuBarSnapshot) -> [ResolvedItem],
                maxScans: Int = 6, deadline: TimeInterval = 15,
                accessibilityTrusted: @escaping @Sendable () -> Bool,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.scanner = scanner; self.resolve = resolve; self.maxScans = maxScans; self.deadline = deadline
        self.accessibilityTrusted = accessibilityTrusted; self.sleep = sleep
    }

    /// Stale items and items with width <= 1 (the frontmost app's main-menu entries, which change on app switches)
    /// are excluded: they are not part of what the planner sees (`ObservedOrder(resolved:)`), so they must not decide
    /// agreement either.
    static func signature(_ all: [ResolvedItem]) -> String {
        let r = all.filter { !$0.item.stale && $0.item.frame.width > 1 }
        let on = r.filter { $0.item.isOnMenuBar }.map { $0.key.description }.joined(separator: "\n")
        let off = r.filter { !$0.item.isOnMenuBar }.map { $0.key.description }.sorted().joined(separator: "\n")
        return on + "\n--\n" + off
    }

    public func observe() async throws -> [ResolvedItem] { try await observeCounting().items }

    /// Like `observe()`, also returning the number of full scans taken.
    public func observeCounting() async throws -> (items: [ResolvedItem], scans: Int) {
        guard accessibilityTrusted() else { throw ObserveError.permissionDenied }
        let limit = Date().addingTimeInterval(deadline)
        var scans = 0
        var prevSig: String?
        var sawNonEmpty = false
        while scans < maxScans, Date() < limit {
            let snap = await scanner.scan()
            scans += 1
            let res = resolve(snap)
            let stale = res.contains { $0.item.stale }
            let empty = snap.onBarLeftToRight.isEmpty
            if !empty { sawNonEmpty = true }
            let sig = Self.signature(res)
            if ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_OBSERVE"] != nil {
                FileHandle.standardError.write(Data("observe scan \(scans): stale=\(res.filter { $0.item.stale }.map { $0.key.description }) agree=\(sig == prevSig) \(sig.count)\n".utf8))
            }
            if !stale, !empty, sig == prevSig { return (res, scans) }
            prevSig = stale ? nil : sig
            await sleep(.milliseconds(300))
        }
        if scans > 0, !sawNonEmpty { throw ObserveError.empty }
        throw ObserveError.noAgreement(scans: scans)
    }
}

/// Scripted observer for tests and `mbprobe apply --fake`. Each call returns the next script entry; the last entry
/// repeats once the script is exhausted.
public final class FixtureObserver: MenuBarObserver, @unchecked Sendable {
    public enum Step: Sendable {
        case items([ResolvedItem])
        case failure(ObserveError)
    }
    private let lock = NSLock()
    private var steps: [Step]
    private var index = 0
    private var _calls = 0
    public var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    public init(steps: [Step]) { precondition(!steps.isEmpty); self.steps = steps }
    public convenience init(_ items: [[ResolvedItem]]) { self.init(steps: items.map { .items($0) }) }
    public convenience init(throwing e: ObserveError) { self.init(steps: [.failure(e)]) }

    public func observe() async throws -> [ResolvedItem] {
        let step: Step = {
            lock.lock(); defer { lock.unlock() }
            _calls += 1
            let s = steps[min(index, steps.count - 1)]
            index += 1
            return s
        }()
        switch step {
        case .items(let r): return r
        case .failure(let e): throw e
        }
    }
}

/// Builds snapshots/resolved items that carry their `ItemKey` in `axIdentifier`; used with `FakeActuator`.
public enum FakeMenuBar {
    private static func item(_ key: ItemKey, x: CGFloat, onBar: Bool) -> MenuBarItem {
        MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: key.description, axDescription: "",
                    axIdentifier: key.description, frame: CGRect(x: x, y: 0, width: 24, height: 24),
                    source: .appExtras, isOnMenuBar: onBar)
    }

    /// On-bar items left to right, then parked ones (every key in `hidden` that is not in `order` too).
    public static func snapshot(order: [ItemKey], hidden: Set<ItemKey>) -> MenuBarSnapshot {
        let bar = order.filter { !hidden.contains($0) }.enumerated().map { item($1, x: 100 + CGFloat($0) * 30, onBar: true) }
        let off = (hidden.sorted { $0.description < $1.description }).map { item($0, x: -1000, onBar: false) }
        return MenuBarSnapshot(items: bar + off, capturedAt: Date())
    }

    public static func resolve(_ s: MenuBarSnapshot) -> [ResolvedItem] {
        s.items.compactMap { i in
            ItemKey(storeKey: i.axIdentifier).map { ResolvedItem(item: i, key: $0, confidence: .exact) }
        }
    }

    public static func resolved(onBar: [ItemKey], parked: [ItemKey] = []) -> [ResolvedItem] {
        resolve(snapshot(order: onBar, hidden: Set(parked)))
    }
}
