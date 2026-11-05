import Foundation

/// Stable identity of a menu bar item that survives relaunches and reorders.
///
/// The string form of `.status` and `.module` is byte-identical to the key format of MenuBarAgent's order store
/// (`TrailingItemPreferredPositions` in com.apple.MenuBar.plist): `status:<ownerKey>::<autosaveName>` and
/// `module:<Name>`. Note `ownerKey` is usually the bundle id but not always (see `OwnerKeyRule`).
public enum ItemKey: Hashable, Codable, Sendable, CustomStringConvertible {
    case status(ownerKey: String, autosaveName: String)
    case module(name: String)
    /// Fallback when no autosave name is resolvable. `ordinal` disambiguates identical fingerprints left to right.
    case heuristic(bundleID: String, fingerprint: String, ordinal: Int)

    public static let statusPrefix = "status:"
    public static let modulePrefix = "module:"
    public static let heuristicPrefix = "heuristic:"
    static let separator = "::"

    public var description: String {
        switch self {
        case .status(let o, let a): return "\(Self.statusPrefix)\(o)\(Self.separator)\(a)"
        case .module(let n): return "\(Self.modulePrefix)\(n)"
        case .heuristic(let b, let f, let n): return "\(Self.heuristicPrefix)\(b)\(Self.separator)\(f)#\(n)"
        }
    }

    /// Parses a store key (or the `heuristic:` form produced by `description`). Splits `status:` keys at the FIRST
    /// `::`, so autosave names may contain `:` and spaces (`Main Status Menu`) but owner keys may not contain `::`.
    /// Returns nil for anything else (e.g. the malformed `status:Item-0` present in the store).
    public init?(storeKey: String) {
        if storeKey.hasPrefix(Self.statusPrefix) {
            let rest = storeKey.dropFirst(Self.statusPrefix.count)
            guard let r = rest.range(of: Self.separator) else { return nil }
            self = .status(ownerKey: String(rest[..<r.lowerBound]), autosaveName: String(rest[r.upperBound...]))
        } else if storeKey.hasPrefix(Self.modulePrefix) {
            let name = String(storeKey.dropFirst(Self.modulePrefix.count))
            guard !name.isEmpty else { return nil }
            self = .module(name: name)
        } else if storeKey.hasPrefix(Self.heuristicPrefix) {
            let rest = storeKey.dropFirst(Self.heuristicPrefix.count)
            guard let r = rest.range(of: Self.separator), let h = rest.lastIndex(of: "#"), h >= r.upperBound,
                  let n = Int(rest[rest.index(after: h)...]) else { return nil }
            self = .heuristic(bundleID: String(rest[..<r.lowerBound]), fingerprint: String(rest[r.upperBound..<h]), ordinal: n)
        } else {
            return nil
        }
    }
}

/// The granularity at which Control Center hides: `trackedApplications[...].isAllowed` applies to a whole ENTRY, so
/// hiding one status item parks every item the entry governs (docs/findings-visibility.md). Layout, Reconciler and the
/// UI therefore treat every item of a unit as one thing. The unit of a key is decided by `HideUnitRule` (gdu.75): the
/// tracked entry key when the key resolves to one (a helper shares its parent's unit), else `id` = the owner key for
/// status items, `module:<Name>` for each Control Center module (modules hide independently), the bundle id for heuristic keys.
public struct HideUnit: Hashable, Sendable, CustomStringConvertible {
    public let id: String
    public init(id: String) { self.id = id }
    public var description: String { id }
}

extension ItemKey {
    /// The OWNER-KEY unit: the fallback for a key with no tracked entry. Code that groups keys must go through a
    /// `HideUnitRule` instead (the planner and the actuator share one, gdu.75).
    public var hideUnit: HideUnit {
        switch self {
        case .status(let owner, _): return HideUnit(id: owner)
        case .module(let name): return HideUnit(id: Self.modulePrefix + name)
        case .heuristic(let bundleID, _, _): return HideUnit(id: bundleID)
        }
    }
}

/// THE hide-unit rule (gdu.75), shared by planner, Layout, Arrange, activator and engine: keys that resolve to the same
/// Control Center tracked entry (`TrackedEntryResolver`, the same lookup the actuator uses) form ONE unit whose id is the
/// entry key, so a helper (Hazel Helper) and its parent app (com.noodlesoft.Hazel) hide, show and move together. Keys with
/// no entry keep the owner-key unit (`ItemKey.hideUnit`). A snapshot value: build it once per pass/render, not per key.
public struct HideUnitRule: Sendable {
    /// No Control Center knowledge: every key is its own owner-key unit (the pre-gdu.75 rule; also the default in tests).
    public static let ownerKeys = HideUnitRule(resolver: nil, bundleIDs: [:])
    public let resolver: TrackedEntryResolver?
    /// Owning process bundle ids by key (candidates for the entry lookup, as the actuator does).
    public let bundleIDs: [ItemKey: String]
    public init(resolver: TrackedEntryResolver?, bundleIDs: [ItemKey: String] = [:]) {
        self.resolver = resolver; self.bundleIDs = bundleIDs
    }
    public init(resolver: TrackedEntryResolver?, items: [ItemKey: ItemInfo]) {
        self.init(resolver: resolver, bundleIDs: items.compactMapValues(\.ownerBundleID))
    }

    /// The tracked entry key governing `key`, nil when none (no resolver, module, untracked).
    public func trackedKey(of key: ItemKey) -> String? { resolver?.trackedKey(for: key, bundleID: bundleIDs[key]) }

    public func unit(of key: ItemKey) -> HideUnit {
        if let t = trackedKey(of: key) { return HideUnit(id: t) }
        return key.hideUnit
    }
}

/// Groups keys by hide unit. An array, not a dictionary: units appear in first-seen order and so do the keys within a
/// unit. Duplicate keys are kept as given (callers dedupe).
public func hideUnits(_ keys: some Sequence<ItemKey>, rule: HideUnitRule = .ownerKeys) -> [(unit: HideUnit, keys: [ItemKey])] {
    var index: [HideUnit: Int] = [:]
    var out: [(unit: HideUnit, keys: [ItemKey])] = []
    for k in keys {
        let u = rule.unit(of: k)
        if let i = index[u] { out[i].keys.append(k) } else { index[u] = out.count; out.append((u, [k])) }
    }
    return out
}

/// How much the resolver trusts a key.
public enum KeyConfidence: String, Codable, Sendable, Comparable {
    /// Backed by the order store / defaults AND corroborated by an item attribute (AXIdentifier) that is not a frame.
    case exact
    /// Real store key, but the item-to-autosave-name pairing rests on an assumption (order, single candidate).
    case inferred
    /// Synthesized from item attributes (fingerprint + ordinal), not a store key, but the owner/hosted-frame pairing was
    /// independently corroborated (`JoinEvidence.corroborated`, gdu.28): the key is stable across MenuBarAgent respawns and
    /// the item's own moves and its frame can be trusted for order checks.
    case corroborated
    /// Synthesized from item attributes; not a store key.
    case heuristic

    private var rank: Int { switch self { case .exact: 0; case .inferred: 1; case .corroborated: 2; case .heuristic: 3 } }
    /// True when the key is a real order-store key (exact or inferred), as opposed to a synthesized fingerprint.
    public var isStoreBacked: Bool { self == .exact || self == .inferred }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    /// Single-character marker for tables.
    public var marker: String { switch self { case .exact: "="; case .inferred: "~"; case .corroborated: "+"; case .heuristic: "?" } }
}
