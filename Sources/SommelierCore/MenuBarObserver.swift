import Foundation

public enum ObserveError: Error, Equatable, Sendable, CustomStringConvertible {
    case permissionDenied
    /// Full scans never agreed (or kept containing stale items) within the budget.
    case noAgreement(scans: Int)
    /// The bar had no on-bar item in any scan: a failed read, never a state.
    case empty
    /// The observation was abandoned because a newer request (a layout change) needs a pass now.
    case superseded

    public var description: String {
        switch self {
        case .permissionDenied: return "Accessibility permission is not granted"
        case .noAgreement(let n): return "scans did not agree after \(n) attempts"
        case .empty: return "the menu bar scan returned no items"
        case .superseded: return "observation superseded by a newer request"
        }
    }
}

/// One observation of the bar: the items of the best full scan and whether two scans agreed on them.
public struct BarObservation: Sendable {
    public var items: [ResolvedItem]
    /// True when two consecutive full scans agreed (see `AgreedScanObserver`). False = the latest COMPLETE read, shown to
    /// the user but never acted on (gdu.46).
    public var settled: Bool
    public var scans: Int
    /// The weakest read level among the scans this observation rests on (gdu.51). `.completeExceptSelfPositioning`: the
    /// self-positioning owners' items are stale (present, but their frames are not trusted).
    public var completeness: ReadCompleteness
    public init(items: [ResolvedItem], settled: Bool = true, scans: Int = 1, completeness: ReadCompleteness = .complete) {
        self.items = items; self.settled = settled; self.scans = scans; self.completeness = completeness
    }
}

/// Produces the observed, resolved menu bar. Implementations must only return data they trust (no stale items) from `observe()`.
public protocol MenuBarObserver: Sendable {
    /// Strict: returns only a settled observation, throws otherwise.
    func observe() async throws -> [ResolvedItem]
    /// Lenient: may return an unsettled observation instead of throwing `noAgreement`. `progress` is called once, with the
    /// first complete scan, so a caller can show something before agreement is reached.
    func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> BarObservation
}

public extension MenuBarObserver {
    func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> BarObservation {
        BarObservation(items: try await observe(), settled: true)
    }
}

/// Why the last two scans did not agree (gdu.30): the keys that were stale on the bar in the last scan, and, when both scans
/// were usable, the keys whose presence/placement differed between them.
public struct ScanDisagreement: Equatable, Sendable {
    public var scans: Int
    public var staleKeys: [String]
    public var changedKeys: [String]

    public init(scans: Int, staleKeys: [String], changedKeys: [String]) {
        self.scans = scans; self.staleKeys = staleKeys; self.changedKeys = changedKeys
    }

    /// `previous`/`last` are the two final scans (previous nil = only one scan was taken).
    public static func make(scans: Int, previous: [ResolvedItem]?, last: [ResolvedItem], rule: BarSignature) -> ScanDisagreement {
        let stale = Set(rule.blockingStale(last).map { $0.key.description }).sorted()
        var changed: [String] = []
        // The diff ignores the blocking stale items (reported separately), so a stale scan still shows what else moved.
        let blocked = Set(rule.blockingStale(last).map(\.key)).union(previous.map { rule.blockingStale($0).map(\.key) } ?? [])
        func usable(_ x: [ResolvedItem]) -> [ResolvedItem] { x.filter { !blocked.contains($0.key) } }
        if let previous, let a = rule.value(usable(previous)), let b = rule.value(usable(last)) {
            func set(_ v: BarSignature.Value) -> Set<String> { Set(v.order).union(v.presence).union(v.parked).union(v.staleParked) }
            var diff = set(a).symmetricDifference(set(b))
            // Same members, different order: the keys whose position among the ordered keys moved.
            if a.order != b.order {
                for (i, k) in b.order.enumerated() where a.order.firstIndex(of: k) != i { diff.insert(k) }
                for (i, k) in a.order.enumerated() where b.order.firstIndex(of: k) != i { diff.insert(k) }
            }
            changed = diff.sorted()
        }
        return ScanDisagreement(scans: scans, staleKeys: stale, changedKeys: changed)
    }

    public var message: String {
        var m = "scans did not agree after \(scans) attempts; not writing"
        if !staleKeys.isEmpty { m += "\n  stale in the last scan: " + staleKeys.joined(separator: ", ") }
        if !changedKeys.isEmpty { m += "\n  differed between the last two scans: " + changedKeys.joined(separator: ", ") }
        if staleKeys.isEmpty, changedKeys.isEmpty { m += "\n  (no stale or differing keys identified; the last scan may have been incomplete)" }
        return m
    }
}

/// Polls full scans until two consecutive fresh scans agree, or gives up (gdu.46).
///
/// Agreement rule (`signature`): the two scans must show the same
///  1. ORDER of the on-bar identified keys: status/module items that carry an AX identifier, are not heuristic keys, are not
///     owned by a self-positioning app (iStat: it re-lays its own items out and changes their widths) and are not in
///     `volatileKeys`;
///  2. PRESENCE (sorted set) of every other on-bar key (identifier-less items and iStat count for presence, not for order:
///     identifier-less items such as signal/GateOpener swap places because they are attributed by frame join);
///  3. set of parked keys, and set of stale parked keys.
/// `volatileKeys` (`module:WiFi`, `module:com.apple.menuextra.focusmode`) are exempt altogether: the agent's hosted tree
/// drops/re-adds those leftmost system modules between reads (docs/findings-restart-collateral.md, gdu.46), which made
/// agreement impossible for minutes. A stale item ON THE BAR still blocks agreement. A key never appears twice in a result.
/// Width <= 1 items (main-menu entries) are ignored.
///
/// When the budget (`maxScans`/`deadline`) is exhausted the latest complete read (hosted tree read without failures) is
/// returned with `settled == false`; `progress` additionally gets the first non-empty scan, complete or not.
public struct AgreedScanObserver: MenuBarObserver {
    public var scanner: any SnapshotScanning
    public var resolve: @Sendable (MenuBarSnapshot) -> [ResolvedItem]
    public var maxScans: Int
    /// Seconds allowed per `observe()` call.
    public var deadline: TimeInterval
    public var accessibilityTrusted: @Sendable () -> Bool
    public var sleep: @Sendable (Duration) async -> Void
    public var selfPositioningOwners: Set<String>
    public var volatileKeys: Set<ItemKey>
    public var log: @Sendable (String) -> Void

    public static let defaultVolatileKeys: Set<ItemKey> = [.module(name: "WiFi"), .module(name: "com.apple.menuextra.focusmode"),
                                                               .module(name: "Show Hidden Menu Bar Items")]

    public init(scanner: any SnapshotScanning,
                resolve: @escaping @Sendable (MenuBarSnapshot) -> [ResolvedItem],
                maxScans: Int = 6, deadline: TimeInterval = 15,
                selfPositioningOwners: Set<String> = SelfPositioning.defaultOwners,
                volatileKeys: Set<ItemKey> = AgreedScanObserver.defaultVolatileKeys,
                accessibilityTrusted: @escaping @Sendable () -> Bool,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.scanner = scanner; self.resolve = resolve; self.maxScans = maxScans; self.deadline = deadline
        self.selfPositioningOwners = selfPositioningOwners; self.volatileKeys = volatileKeys
        self.accessibilityTrusted = accessibilityTrusted; self.sleep = sleep; self.log = log
    }

    /// Keeps one item per key: the first by array order (on-bar left to right, then parked), preferring a fresh one over a
    /// stale one. Returns the keys that were duplicated.
    static func dedupe(_ all: [ResolvedItem]) -> (items: [ResolvedItem], duplicated: [ItemKey]) {
        var first: [ItemKey: Int] = [:]
        var dup: [ItemKey] = []
        var out: [ResolvedItem] = []
        for r in all {
            if let i = first[r.key] {
                if !dup.contains(r.key) { dup.append(r.key) }
                if out[i].item.stale, !r.item.stale { out[i] = r }
            } else { first[r.key] = out.count; out.append(r) }
        }
        return (out, dup)
    }

    static func weakest(_ a: ReadCompleteness, _ b: ReadCompleteness) -> ReadCompleteness {
        if a == .incomplete || b == .incomplete { return .incomplete }
        return a == .complete && b == .complete ? .complete : .completeExceptSelfPositioning
    }

    private var rule: BarSignature { BarSignature(selfPositioningOwners: selfPositioningOwners, volatileKeys: volatileKeys) }

    /// nil = this scan cannot be used for agreement (a stale item is on the bar). Shared with the poll (`BarSignature`).
    func signature(_ all: [ResolvedItem]) -> BarSignature.Value? { rule.value(all) }

    /// Strict: throws `noAgreement` when the scans never agreed.
    public func observe() async throws -> [ResolvedItem] { try await observeCounting().items }

    /// Strict, also returning the number of full scans taken.
    public func observeCounting() async throws -> (items: [ResolvedItem], scans: Int) {
        let o = try await observeDetailed(progress: nil)
        guard o.settled else { throw ObserveError.noAgreement(scans: o.scans) }
        return (o.items, o.scans)
    }

    public func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> BarObservation {
        let r = try await scanLoop(progress: progress)
        if let o = r.observation { return o }
        throw ObserveError.noAgreement(scans: r.disagreement.scans)
    }

    /// Strict like `observeCounting`, but a failure to agree reports WHY (stale / differing keys of the last scans).
    public func observeDiagnosed() async throws -> (items: [ResolvedItem], scans: Int, disagreement: ScanDisagreement?) {
        let r = try await scanLoop(progress: nil)
        guard let o = r.observation, o.settled else { return ([], r.disagreement.scans, r.disagreement) }
        return (o.items, o.scans, nil)
    }

    private func scanLoop(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> (observation: BarObservation?, disagreement: ScanDisagreement) {
        guard accessibilityTrusted() else { throw ObserveError.permissionDenied }
        let limit = Date().addingTimeInterval(deadline)
        var scans = 0
        var prevSig: BarSignature.Value?
        var prevRes: [ResolvedItem]?
        var lastRes: [ResolvedItem] = []
        var sawNonEmpty = false
        var sentProgress = false
        // Latest complete read; a read without a stale item on the bar is preferred over one with.
        var best: [ResolvedItem]?
        var bestClean = false
        var bestLevel = ReadCompleteness.complete
        var prevLevel = ReadCompleteness.complete
        while scans < maxScans, Date() < limit {
            if Task.isCancelled { throw ObserveError.superseded }
            let snap = await scanner.scan()
            scans += 1
            let raw = resolve(snap)
            let (res, dups) = Self.dedupe(raw)
            prevRes = scans == 1 ? nil : lastRes
            lastRes = res
            if !dups.isEmpty {
                // Which copies existed (so the cause is visible in the log): x, size, stale flag, source, identifier.
                let detail = dups.map { k in
                    k.description + " = " + raw.filter { $0.key == k }.map {
                        "[x=\(Int($0.item.frame.minX)) w=\(Int($0.item.frame.width)) \($0.item.stale ? "stale" : "fresh") \($0.item.source.rawValue) id=\($0.item.axIdentifier) desc=\($0.item.axDescription)]"
                    }.joined(separator: " ")
                }
                log("observe scan \(scans): duplicate key(s) collapsed: " + detail.joined(separator: "; "))
            }
            let empty = snap.onBarLeftToRight.isEmpty
            if !empty { sawNonEmpty = true }
            let sig = signature(res)
            let onBarStale = res.filter { $0.item.stale && $0.item.isOnMenuBar }.map { $0.key.description }
            let level = snap.completeness
            log("observe scan \(scans): hostedComplete=\(snap.hostedReadComplete.map(String.init) ?? "n/a") level=\(level.rawValue) items=\(res.count) onBarStale=\(onBarStale.count) agree=\(sig != nil && sig == prevSig)")
            if ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_OBSERVE"] != nil {
                FileHandle.standardError.write(Data("observe scan \(scans): blocked=\(sig == nil) agree=\(sig != nil && sig == prevSig) \(sig?.joined.count ?? 0)\n".utf8))
            }
            // The first scan with anything on the bar is shown at once as provisional, even when the hosted read was incomplete
            // (a slow iStat read leaves its items stale, and a pass would otherwise show nothing for 10+ s); only a COMPLETE
            // read may be returned as the unsettled result.
            if !empty, !sentProgress { sentProgress = true; progress?(res) }
            if !empty, level.membershipUsable {
                if sig != nil || !bestClean { best = res; bestClean = sig != nil; bestLevel = level }
            }
            if !empty, let sig, sig == prevSig {
                return (BarObservation(items: res, settled: true, scans: scans, completeness: Self.weakest(level, prevLevel)),
                        ScanDisagreement(scans: scans, staleKeys: [], changedKeys: []))
            }
            prevSig = sig
            prevLevel = level
            await sleep(.milliseconds(300))
        }
        if Task.isCancelled { throw ObserveError.superseded }
        if scans > 0, !sawNonEmpty { throw ObserveError.empty }
        let disagreement = ScanDisagreement.make(scans: scans, previous: prevRes, last: lastRes, rule: rule)
        if let best {
            log("scans did not agree after \(scans) attempts; returning the latest complete read, unsettled")
            return (BarObservation(items: best, settled: false, scans: scans, completeness: bestLevel), disagreement)
        }
        return (nil, disagreement)
    }
}

/// The agreement signature of one resolved scan (see `AgreedScanObserver`), shared by the observer's two-scan agreement and the
/// 10 s poll (`EngineTriggers`, e7t) so the two cannot drift: what is too noisy to agree on is too noisy to trigger a pass.
public struct BarSignature: Sendable {
    public var selfPositioningOwners: Set<String>
    public var volatileKeys: Set<ItemKey>
    public init(selfPositioningOwners: Set<String> = SelfPositioning.defaultOwners,
                volatileKeys: Set<ItemKey> = AgreedScanObserver.defaultVolatileKeys) {
        self.selfPositioningOwners = selfPositioningOwners; self.volatileKeys = volatileKeys
    }

    public struct Value: Equatable, Sendable {
        public var order: [String], presence: [String], parked: [String], staleParked: [String]
        public var joined: String {
            [order, presence, parked, staleParked].map { $0.joined(separator: "\n") }.joined(separator: "\n--\n")
        }
        /// The poll's view (e7t): the same components, but parked = identified keys only (a heuristic parked key is noise) and
        /// no stale-parked component (a stale flag is not a change).
        /// Presence also drops the self-positioning owners' items: their fast-scan presence flaps with their staleness (e7t:
        /// all eight iStat items vanish and return between polls), and they position themselves.
        public func forPoll(selfPositioningOwners: Set<String>) -> Value {
            let selfKeys = selfPositioningOwners.map { ItemKey.statusPrefix + $0 + ItemKey.separator }
            return Value(order: order,
                         presence: presence.filter { k in !selfKeys.contains { k.hasPrefix($0) } },
                         parked: parked.filter { !$0.hasPrefix(ItemKey.heuristicPrefix) }, staleParked: [])
        }
        /// One-line explanation of what differs from `other`: component names with the keys added/removed.
        public func diff(from other: Value) -> String {
            var parts: [String] = []
            func part(_ name: String, _ a: [String], _ b: [String], ordered: Bool) {
                guard a != b else { return }
                let added = Set(a).subtracting(b).sorted(), removed = Set(b).subtracting(a).sorted()
                var d = name
                if !added.isEmpty { d += " +[" + added.joined(separator: ", ") + "]" }
                if !removed.isEmpty { d += " -[" + removed.joined(separator: ", ") + "]" }
                if ordered, added.isEmpty, removed.isEmpty { d += " reordered" }
                parts.append(d)
            }
            part("order", order, other.order, ordered: true)
            part("presence", presence, other.presence, ordered: false)
            part("parked", parked, other.parked, ordered: false)
            part("staleParked", staleParked, other.staleParked, ordered: false)
            return parts.joined(separator: "; ")
        }
    }

    /// MenuBarAgent's own entries (the Apple main menu: `heuristic:com.apple.MenuBarAgent::...`) come and go between reads.
    static func isAgentNoise(_ k: ItemKey) -> Bool {
        if case .heuristic(let b, _, _) = k { return b == "com.apple.MenuBarAgent" }
        return false
    }

    private func isSelfPositioning(_ r: ResolvedItem) -> Bool {
        if case .status(let owner, _) = r.key, selfPositioningOwners.contains(owner) { return true }
        return SelfPositioning.matches(r.item, owners: selfPositioningOwners)
    }

    private func orderable(_ r: ResolvedItem) -> Bool {
        if volatileKeys.contains(r.key) || r.confidence == .heuristic || r.item.axIdentifier.isEmpty { return false }
        if case .status(let owner, _) = r.key, selfPositioningOwners.contains(owner) { return false }
        return true
    }

    /// The on-bar stale items that make a scan unusable for agreement (after the shared non-item/noise exclusions).
    public func blockingStale(_ all: [ResolvedItem]) -> [ResolvedItem] {
        all.filter { !LayoutBuilder.isNonItem($0) && !volatileKeys.contains($0.key) && !Self.isAgentNoise($0.key) }
            .filter { $0.item.stale && $0.item.isOnMenuBar && !isSelfPositioning($0) }
    }

    /// nil = this scan cannot be used (a stale item of a non-self-positioning owner is on the bar).
    public func value(_ all: [ResolvedItem]) -> Value? {
        let r = all.filter { !LayoutBuilder.isNonItem($0) && !volatileKeys.contains($0.key) && !Self.isAgentNoise($0.key) }
        // A stale item of a self-positioning owner does not block (gdu.51): it counts for presence, never for order.
        if !blockingStale(all).isEmpty { return nil }
        let bar = r.filter { $0.item.isOnMenuBar }
        let off = r.filter { !$0.item.isOnMenuBar }
        return Value(order: bar.filter(orderable).map { $0.key.description },
                     presence: bar.map { $0.key.description }.sorted(),
                     parked: off.filter { !$0.item.stale }.map { $0.key.description }.sorted(),
                     staleParked: off.filter { $0.item.stale }.map { $0.key.description }.sorted())
    }
}

/// Scripted observer for tests and `mbprobe apply --fake`. Each call returns the next script entry; the last entry
/// repeats once the script is exhausted.
public final class FixtureObserver: MenuBarObserver, @unchecked Sendable {
    public enum Step: Sendable {
        case items([ResolvedItem])
        /// Returned by `observeDetailed` as an unsettled observation; `observe()` (strict) throws `noAgreement` for it.
        case unsettled([ResolvedItem])
        case failure(ObserveError)
    }
    private let lock = NSLock()
    private var steps: [Step]
    private var index = 0
    private var _calls = 0
    public var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    public init(steps: [Step]) { precondition(!steps.isEmpty); self.steps = steps }
    public convenience init(_ items: [[ResolvedItem]]) { self.init(steps: items.map { .items($0) }) }
    public convenience init(unsettled items: [ResolvedItem]) { self.init(steps: [.unsettled(items)]) }
    public convenience init(throwing e: ObserveError) { self.init(steps: [.failure(e)]) }

    public func observe() async throws -> [ResolvedItem] {
        let o = try await observeDetailed(progress: nil)
        guard o.settled else { throw ObserveError.noAgreement(scans: o.scans) }
        return o.items
    }

    public func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> BarObservation {
        let step: Step = {
            lock.lock(); defer { lock.unlock() }
            _calls += 1
            let s = steps[min(index, steps.count - 1)]
            index += 1
            return s
        }()
        switch step {
        case .items(let r): return BarObservation(items: r, settled: true)
        case .unsettled(let r): progress?(r); return BarObservation(items: r, settled: false)
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
