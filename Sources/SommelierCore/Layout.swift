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
    /// gdu.89: the keys the USER placed in Visible (a drop in Arrange, including a drop from Hidden into Visible). Only these create an
    /// order obligation on the real bar; every other visible key follows whatever order macOS gives it (the layout merely records it).
    /// Optional on disk (absent = empty, so every layout written before this field plans no moves). A key enters only through
    /// `markPlaced` (Arrange's submit); builders, "Adopt current order", "Hide what does not fit", new-item appends and
    /// `normalizedAroundSelfPositioning` never add to it. A key that leaves the layout (or Visible) leaves `placed`. The array order is
    /// not meaningful (the planner uses the order of `visible`).
    public var placed: [ItemKey]
    /// The planner's view of `placed`.
    public var placedSet: Set<ItemKey> { Set(placed) }
    /// Who owns the bar's order (sommelier-8z5). Absent on disk = `.macOSOwns`; always written. `placed` is inert unless `.placedOnly`.
    public var orderMode: OrderMode
    /// True when the engine may plan order moves (only `.placedOnly`; enforced in sommelier-8z5.2).
    public var enforcesOrder: Bool { orderMode == .placedOnly }

    /// A copy with `orderMode` replaced (everything else, `placed` included, untouched).
    public func withOrderMode(_ m: OrderMode) -> Layout {
        var out = self
        out.orderMode = m
        return out
    }

    public init(schemaVersion: Int = Layout.currentSchemaVersion, visible: [ItemKey] = [], hidden: [ItemKey] = [],
                alwaysHidden: [ItemKey] = [], newItemPolicy: NewItemPolicy = .visibleAtEnd, placed: [ItemKey] = [], orderMode: OrderMode = .macOSOwns) {
        self.placed = placed
        self.orderMode = orderMode
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
        return Set(all).count == all.count && Set(placed).isSubset(of: Set(all))
    }

    /// Records `keys` as user-placed (those that are in `visible`; others are ignored: only Visible has a bar order to enforce).
    public mutating func markPlaced(_ keys: [ItemKey]) {
        let vis = Set(visible)
        for k in keys where vis.contains(k) && !placed.contains(k) { placed.append(k) }
    }

    /// gdu.114: removes keys `heuristic:com.apple.MenuBarAgent::#N` (empty fingerprint) left by earlier builds that made keys for
    /// unnamed off-bar hosted elements. Sections and `placed` lose them; everything else is untouched.
    public func prunedAgentNoise() -> (Layout, removed: [ItemKey]) {
        func junk(_ k: ItemKey) -> Bool {
            if case .heuristic(let b, let fp, _) = k { return b == "com.apple.MenuBarAgent" && fp.isEmpty }
            return false
        }
        var out = self
        var removed: [ItemKey] = []
        for k in visible + hidden + alwaysHidden where junk(k) { removed.append(k) }
        out.visible = visible.filter { !junk($0) }
        out.hidden = hidden.filter { !junk($0) }
        out.alwaysHidden = alwaysHidden.filter { !junk($0) }
        out.placed = placed.filter { !junk($0) }
        return (out, removed)
    }

    /// Drops `placed` entries that are not in `visible` any more (and duplicates).
    func pruningPlaced() -> Layout {
        var out = self
        let vis = Set(visible)
        var seen = Set<ItemKey>()
        out.placed = placed.filter { vis.contains($0) && seen.insert($0).inserted }
        return out
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
        placed.removeAll { $0 == key }
        return found
    }

    /// The maximal suffix of `section` consisting only of `.module` keys (Control Center modules, Clock). On macOS 26+
    /// a third-party item cannot be placed right of this block, so it is an unreachable region.
    public func trailingSystemBlock(in section: LayoutSection = .visible) -> [ItemKey] {
        let ks = keys(in: section)
        var start = ks.count
        while start > 0, case .module = ks[start - 1] { start -= 1 }
        return Array(ks[start...])
    }

    /// Moves (or inserts) the WHOLE hide unit of `key` into `section` and returns every key that moved, `key` first.
    /// Control Center hides per app (see `HideUnit`), so siblings (all keys of the same unit currently in the layout)
    /// come along: the moved key lands at `index` (clamped to 0...count, evaluated after the unit is lifted out) and
    /// its siblings follow immediately after it, in their previous layout order (visible, hidden, alwaysHidden).
    /// With `index == nil`, `.hidden`/`.alwaysHidden` append; `.visible` inserts immediately BEFORE the trailing run of
    /// `.module` keys (see `trailingSystemBlock`), because anything right of it is unreachable and the engine would
    /// otherwise try to drag real items to realize it. With no such run it appends. An explicit index is taken literally.
    @discardableResult
    public mutating func move(_ key: ItemKey, to section: LayoutSection, index: Int? = nil, units: HideUnitRule = .ownerKeys) -> [ItemKey] {
        let unit = units.unit(of: key)
        let siblings = allKeys.filter { $0 != key && units.unit(of: $0) == unit }
        let group = [key] + siblings
        for k in group { remove(k) }
        insert(group, into: section, at: index)
        return group
    }

    /// "Hide what does not fit" (gdu.45; called by the Arrange window toolbar, gdu.19): moves each key, with its
    /// hide-unit siblings, to the end of `hidden`, in the order given. Keys not in the layout or already hidden/always
    /// hidden are ignored. Returns every key that actually moved (siblings included), in the order moved.
    @discardableResult
    public mutating func hideNotFitting(_ keys: [ItemKey], units: HideUnitRule = .ownerKeys) -> [ItemKey] {
        var moved: [ItemKey] = []
        for k in keys {
            guard let s = section(of: k), s == .visible else { continue }
            for m in move(k, to: .hidden, units: units) where !moved.contains(m) { moved.append(m) }
        }
        return moved
    }

    /// Single-key placement, no sibling handling (used by builders and in-section reordering).
    private mutating func insert(_ group: [ItemKey], into section: LayoutSection, at index: Int?) {
        var ks = keys(in: section)
        let i: Int
        if let index {
            i = max(0, min(index, ks.count))
        } else if section == .visible {
            var start = ks.count
            while start > 0, case .module = ks[start - 1] { start -= 1 }
            i = start
        } else {
            i = ks.count
        }
        ks.insert(contentsOf: group, at: i)
        set(ks, in: section)
    }

    /// Places exactly `key` (removed from any section first), leaving its hide-unit siblings where they are. `.hidden` and
    /// `.alwaysHidden` append; `.visible` inserts immediately BEFORE the trailing run of `.module` keys (see
    /// `trailingSystemBlock`), or appends when there is none, so it is not a literal append for `.visible`. The engine uses it
    /// to record new items; `LayoutBuilder` does NOT (it fills sections verbatim). Use `move` for user-facing hide/show
    /// changes (it carries the whole unit) and `reorder` for an explicit index.
    public mutating func append(_ key: ItemKey, to section: LayoutSection) {
        remove(key)
        insert([key], into: section, at: nil)
    }

    public mutating func reorder(_ key: ItemKey, in section: LayoutSection, toIndex: Int) {
        remove(key)
        insert([key], into: section, at: toIndex)
    }

    /// De-duplicates keeping the first occurrence in visible -> hidden -> alwaysHidden order, then normalizes hide
    /// units (see `normalizedHideUnits`). Silent; use `validatedReportingNormalization()` where the user should hear
    /// about moved keys.
    public func validated(units: HideUnitRule = .ownerKeys) -> Layout { validatedReportingNormalization(units: units).0 }

    /// Like `validated()` but also returns the keys that normalization moved to `visible`. This is a return value, not
    /// a stored property, so `Layout` stays a pure value with no hidden state; the load path (store/engine) and
    /// `mbprobe` print or log the list once when a layout is loaded.
    public func validatedReportingNormalization(units: HideUnitRule = .ownerKeys) -> (Layout, moved: [ItemKey]) {
        let n = dedup().layout.normalizedHideUnits(units: units)
        return (n.layout, n.moved)
    }

    /// Hide units are all-or-nothing. A unit with keys in `visible` AND in a hidden section (`hidden`/`alwaysHidden`)
    /// can never converge, so its hidden-section keys move to `visible`, inserted before the trailing system block
    /// (the default `move` rule) in their original relative order (`hidden` first, then `alwaysHidden`). A unit split
    /// only between `hidden` and `alwaysHidden` is untouched (both are hidden). `moved` lists the keys moved.
    public func normalizedHideUnits(units: HideUnitRule = .ownerKeys) -> (layout: Layout, moved: [ItemKey]) {
        let visibleUnits = Set(visible.map { units.unit(of: $0) })
        let moved = (hidden + alwaysHidden).filter { visibleUnits.contains(units.unit(of: $0)) }
        guard !moved.isEmpty else { return (self, []) }
        let movedSet = Set(moved)
        var out = self
        out.hidden.removeAll { movedSet.contains($0) }
        out.alwaysHidden.removeAll { movedSet.contains($0) }
        out.insert(moved, into: .visible, at: nil)
        return (out, moved)
    }

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
        return (out.pruningPlaced(), dropped)
    }

    // MARK: Codable (keys are stored as their string form)

    private enum CodingKeys: String, CodingKey { case schemaVersion, visible, hidden, alwaysHidden, newItemPolicy, placed, orderMode }

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
            newItemPolicy: try c.decodeIfPresent(NewItemPolicy.self, forKey: .newItemPolicy) ?? .visibleAtEnd,
            placed: try (c.decodeIfPresent([String].self, forKey: .placed) ?? []).map(Self.parse),
            orderMode: try c.decodeIfPresent(OrderMode.self, forKey: .orderMode) ?? .macOSOwns)
        self = raw.dedup().layout
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(visible.map(\.description), forKey: .visible)
        try c.encode(hidden.map(\.description), forKey: .hidden)
        try c.encode(alwaysHidden.map(\.description), forKey: .alwaysHidden)
        try c.encode(newItemPolicy, forKey: .newItemPolicy)
        try c.encode(orderMode, forKey: .orderMode)
        if !placed.isEmpty { try c.encode(placed.map(\.description), forKey: .placed) }   // absent = empty: files without obligations keep their old shape
    }

    /// Decodes a layout file, reporting duplicates that were dropped and hide-unit normalization (reported once, here). Does not migrate.
    public static func decode(_ data: Data) throws -> (layout: Layout, warnings: [String]) {
        struct Raw: Decodable {
            var schemaVersion: Int?
            var visible: [String]?
            var hidden: [String]?
            var alwaysHidden: [String]?
            var newItemPolicy: NewItemPolicy?
            var placed: [String]?
            var orderMode: OrderMode?
        }
        let r = try JSONDecoder().decode(Raw.self, from: data)
        let raw = Layout(
            schemaVersion: r.schemaVersion ?? 1,
            visible: try (r.visible ?? []).map(parse),
            hidden: try (r.hidden ?? []).map(parse),
            alwaysHidden: try (r.alwaysHidden ?? []).map(parse),
            newItemPolicy: r.newItemPolicy ?? .visibleAtEnd,
            placed: try (r.placed ?? []).map(parse),
            orderMode: r.orderMode ?? .macOSOwns)
        let d = raw.dedup()
        let n = d.layout.normalizedHideUnits()
        var warnings = d.dropped.map { "duplicate key \($0.0) dropped from \($0.1.rawValue)" }
        if !n.moved.isEmpty {
            warnings.append("hide units normalized: " + n.moved.map(\.description).joined(separator: ", ")
                + " moved to visible (all items governed by one Control Center entry hide or show at once)")
        }
        return (n.layout, warnings)
    }

    /// Schema migration. No transforms exist yet; lower versions are just bumped.
    public static func migrate(_ layout: Layout) throws -> Layout {
        if layout.schemaVersion > currentSchemaVersion { throw LayoutError.unsupportedSchema(layout.schemaVersion) }
        var l = layout
        l.schemaVersion = currentSchemaVersion
        return l
    }
}
