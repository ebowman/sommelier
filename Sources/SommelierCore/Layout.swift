import Foundation

public enum LayoutSection: String, Codable, Sendable, CaseIterable { case visible, hidden, alwaysHidden }

/// Where an item that is not in the layout yet (a newly installed app) goes.
public enum NewItemPolicy: String, Codable, Sendable { case visibleAtEnd, hidden }

public enum LayoutError: Error, Sendable {
    /// A key string in the layout file could not be parsed by `ItemKey(storeKey:)`.
    case badKey(String)
    /// The file declares a schema newer than this build understands.
    case unsupportedSchema(Int)
    /// The file could not be decoded; a copy was saved at `backup`.
    case corrupt(underlying: any Error, backup: URL)
}

/// Desired state: three ordered sections of item keys. A key appears in at most one section.
/// Free of AX/UI types; the planner diffs it against observed snapshots.
public struct Layout: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let empty = Layout()

    public var schemaVersion: Int
    public var visible: [ItemKey]
    public var hidden: [ItemKey]
    public var alwaysHidden: [ItemKey]
    public var newItemPolicy: NewItemPolicy

    public init(schemaVersion: Int = Layout.currentSchemaVersion, visible: [ItemKey] = [], hidden: [ItemKey] = [],
                alwaysHidden: [ItemKey] = [], newItemPolicy: NewItemPolicy = .visibleAtEnd) {
        self.schemaVersion = schemaVersion
        self.visible = visible
        self.hidden = hidden
        self.alwaysHidden = alwaysHidden
        self.newItemPolicy = newItemPolicy
    }

    // MARK: Queries

    public func keys(in section: LayoutSection) -> [ItemKey] {
        switch section {
        case .visible: return visible
        case .hidden: return hidden
        case .alwaysHidden: return alwaysHidden
        }
    }

    public func section(of key: ItemKey) -> LayoutSection? {
        LayoutSection.allCases.first { keys(in: $0).contains(key) }
    }

    public var allKeys: [ItemKey] { visible + hidden + alwaysHidden }

    public var isValid: Bool {
        let all = allKeys
        return Set(all).count == all.count
    }

    // MARK: Mutators (each preserves the at-most-one-section invariant)

    private mutating func set(_ keys: [ItemKey], in section: LayoutSection) {
        switch section {
        case .visible: visible = keys
        case .hidden: hidden = keys
        case .alwaysHidden: alwaysHidden = keys
        }
    }

    /// Removes the key from whichever section holds it (all of them, defensively) and returns the first one.
    @discardableResult
    public mutating func remove(_ key: ItemKey) -> LayoutSection? {
        var found: LayoutSection?
        for s in LayoutSection.allCases {
            var ks = keys(in: s)
            if ks.contains(key) {
                found = found ?? s
                ks.removeAll { $0 == key }
                set(ks, in: s)
            }
        }
        return found
    }

    /// Moves (or inserts) `key` into `section` at `index` (clamped to 0...count; nil appends).
    public mutating func move(_ key: ItemKey, to section: LayoutSection, index: Int? = nil) {
        remove(key)
        var ks = keys(in: section)
        let i = index.map { max(0, min($0, ks.count)) } ?? ks.count
        ks.insert(key, at: i)
        set(ks, in: section)
    }

    public mutating func append(_ key: ItemKey, to section: LayoutSection) {
        move(key, to: section, index: nil)
    }

    public mutating func reorder(_ key: ItemKey, in section: LayoutSection, toIndex: Int) {
        move(key, to: section, index: toIndex)
    }

    /// De-duplicates keeping the first occurrence in visible -> hidden -> alwaysHidden order.
    public func validated() -> Layout { dedup().layout }

    private func dedup() -> (layout: Layout, dropped: [(ItemKey, LayoutSection)]) {
        var seen = Set<ItemKey>()
        var out = self
        var dropped: [(ItemKey, LayoutSection)] = []
        for s in LayoutSection.allCases {
            var kept: [ItemKey] = []
            for k in keys(in: s) {
                if seen.insert(k).inserted { kept.append(k) } else { dropped.append((k, s)) }
            }
            out.set(kept, in: s)
        }
        return (out, dropped)
    }

    // MARK: Codable (keys are stored as their string form)

    private enum CodingKeys: String, CodingKey { case schemaVersion, visible, hidden, alwaysHidden, newItemPolicy }

    private static func parse(_ s: String) throws -> ItemKey {
        guard let k = ItemKey(storeKey: s) else { throw LayoutError.badKey(s) }
        return k
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = Layout(
            schemaVersion: try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            visible: try (c.decodeIfPresent([String].self, forKey: .visible) ?? []).map(Self.parse),
            hidden: try (c.decodeIfPresent([String].self, forKey: .hidden) ?? []).map(Self.parse),
            alwaysHidden: try (c.decodeIfPresent([String].self, forKey: .alwaysHidden) ?? []).map(Self.parse),
            newItemPolicy: try c.decodeIfPresent(NewItemPolicy.self, forKey: .newItemPolicy) ?? .visibleAtEnd)
        self = raw.dedup().layout
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(visible.map(\.description), forKey: .visible)
        try c.encode(hidden.map(\.description), forKey: .hidden)
        try c.encode(alwaysHidden.map(\.description), forKey: .alwaysHidden)
        try c.encode(newItemPolicy, forKey: .newItemPolicy)
    }

    /// Decodes a layout file, reporting duplicates that were dropped. Does not migrate.
    public static func decode(_ data: Data) throws -> (layout: Layout, warnings: [String]) {
        struct Raw: Decodable {
            var schemaVersion: Int?
            var visible: [String]?
            var hidden: [String]?
            var alwaysHidden: [String]?
            var newItemPolicy: NewItemPolicy?
        }
        let r = try JSONDecoder().decode(Raw.self, from: data)
        let raw = Layout(
            schemaVersion: r.schemaVersion ?? 1,
            visible: try (r.visible ?? []).map(parse),
            hidden: try (r.hidden ?? []).map(parse),
            alwaysHidden: try (r.alwaysHidden ?? []).map(parse),
            newItemPolicy: r.newItemPolicy ?? .visibleAtEnd)
        let d = raw.dedup()
        return (d.layout, d.dropped.map { "duplicate key \($0.0) dropped from \($0.1.rawValue)" })
    }

    /// Schema migration. No transforms exist yet; lower versions are just bumped.
    public static func migrate(_ layout: Layout) throws -> Layout {
        if layout.schemaVersion > currentSchemaVersion { throw LayoutError.unsupportedSchema(layout.schemaVersion) }
        var l = layout
        l.schemaVersion = currentSchemaVersion
        return l
    }
}
