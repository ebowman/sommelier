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

/// The granularity at which Control Center hides: `trackedApplications[...].isAllowed` applies to a whole app, so
/// hiding one status item of an app parks all of its items (docs/findings-visibility.md). Layout, Reconciler and the
/// UI therefore treat every item of a unit as one thing. `id` is the owner key for status items, `module:<Name>` for
/// each Control Center module (modules hide independently), and the bundle id for heuristic keys.
public struct HideUnit: Hashable, Sendable, CustomStringConvertible {
    public let id: String
    public init(id: String) { self.id = id }
    public var description: String { id }
}

extension ItemKey {
    public var hideUnit: HideUnit {
        switch self {
        case .status(let owner, _): return HideUnit(id: owner)
        case .module(let name): return HideUnit(id: Self.modulePrefix + name)
        case .heuristic(let bundleID, _, _): return HideUnit(id: bundleID)
        }
    }
}

/// Groups keys by hide unit. An array, not a dictionary: units appear in first-seen order and so do the keys within a
/// unit. Duplicate keys are kept as given (callers dedupe).
public func hideUnits(_ keys: some Sequence<ItemKey>) -> [(unit: HideUnit, keys: [ItemKey])] {
    var index: [HideUnit: Int] = [:]
    var out: [(unit: HideUnit, keys: [ItemKey])] = []
    for k in keys {
        let u = k.hideUnit
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
    /// Synthesized from item attributes; not a store key.
    case heuristic

    private var rank: Int { switch self { case .exact: 0; case .inferred: 1; case .heuristic: 2 } }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    /// Single-character marker for tables.
    public var marker: String { switch self { case .exact: "="; case .inferred: "~"; case .heuristic: "?" } }
}
