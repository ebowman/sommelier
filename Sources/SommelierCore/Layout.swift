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
    /// 9o9.2: true from an upgrade (a legacy `orderMode`/`placed` field was read) until the engine has adopted the observed bar
    /// order into `visible` (so nothing moves on first launch). Persisted so a relaunch before adoption keeps the pending state.
    /// Absent on disk = false; written only while true.
    public var pendingAdoption: Bool
    /// 9o9.18: when a hand drag ended and its result is not adopted yet (the engine's adoption wait). A relaunch resumes the wait instead of
    /// enforcing the pre-drag record. Absent on disk = nil; written only while set (ISO 8601).
    public var pendingHandDrag: Date?
    /// 9o9.18: keys a hand drag left unverified (unread or ambiguous frames): a relaunch must not enforce the record against them.
    /// Absent on disk = empty; written only while non-empty.
    public var unreadAfterHandDrag: [ItemKey]
    /// 9o9.27: one Arrange drop made while a hand drag awaited adoption (the composed Visible after the drop and the keys it moved).
    public struct WindowDrop: Equatable, Sendable {
        public var visible: [ItemKey]
        public var moved: [ItemKey]
        public init(visible: [ItemKey], moved: [ItemKey]) { self.visible = visible; self.moved = moved }
    }
    /// 9o9.27: the Arrange drops made during the adoption wait and the record before the first one, so a relaunch inside the window
    /// re-applies them on top of the adopted drag. Absent on disk = empty; written only while `handWindowDrops` is non-empty.
    public var handWindowBaseline: [ItemKey]
    public var handWindowDrops: [WindowDrop]
    /// gdu.145: names of one-time record migrations that have already run on this file ("gdu145"). Absent on disk = empty; written only while
    /// non-empty. Older builds ignore the unknown field (their decoders read only the keys they know) and drop it on their next save, which
    /// at worst re-runs the migration once (it is idempotent and backs up first).
    public var migrations: [String]

    public init(schemaVersion: Int = Layout.currentSchemaVersion, visible: [ItemKey] = [], hidden: [ItemKey] = [],
                alwaysHidden: [ItemKey] = [], newItemPolicy: NewItemPolicy = .visibleAtEnd, pendingAdoption: Bool = false,
                pendingHandDrag: Date? = nil, unreadAfterHandDrag: [ItemKey] = [],
                handWindowBaseline: [ItemKey] = [], handWindowDrops: [WindowDrop] = [], migrations: [String] = []) {
        self.migrations = migrations
        self.handWindowBaseline = handWindowBaseline
        self.handWindowDrops = handWindowDrops
        self.pendingAdoption = pendingAdoption
        self.pendingHandDrag = pendingHandDrag
        self.unreadAfterHandDrag = unreadAfterHandDrag
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

    /// gdu.114: removes keys `heuristic:com.apple.MenuBarAgent::#N` (empty fingerprint) left by earlier builds that made keys for
    /// unnamed off-bar hosted elements. Sections lose them; everything else is untouched.
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
        return (out, removed)
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

    /// The maximal suffix of `section` consisting only of `.module` keys (Control Center modules, Clock). On macOS 26+
    /// a third-party item cannot be placed right of this block, so it is an unreachable region.
    public func trailingSystemBlock(in section: LayoutSection = .visible) -> [ItemKey] {
        let ks = keys(in: section)
        var start = ks.count
        while start > 0, case .module = ks[start - 1] { start -= 1 }
        return Array(ks[start...])
    }

    // `move(_:to:index:units:)` and `hideNotFitting(_:units:)` live in GestureCore.swift: since ejb.32 a gesture is computed by the proved Lean core.
    // The pure-Swift implementation they replaced is kept ONLY in Tests/SommelierCoreTests/GestureOracle.swift, as the oracle of the differential test.

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

    /// gdu.147: records `key` in Visible at `slot` (an insertion index, clamped; the engine chooses it by `LayoutEngine.ownCandidateSlot`, judged by the proved core).
    public mutating func insertObserved(_ key: ItemKey, atVisibleSlot slot: Int) {
        remove(key)
        insert([key], into: .visible, at: slot)
    }

    /// Index where the trailing run of `.module` keys starts in Visible (the first slot of the system block; `visible.count` when none).
    public var trailingSystemBlockStart: Int {
        var s = visible.count
        while s > 0, case .module = visible[s - 1] { s -= 1 }
        return s
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

    /// gdu.147: Sommelier's own item is never hidden. A layout that lists it in Hidden / Always hidden (an old or hand-edited file) gets it
    /// back in Visible, before the trailing system block (the right-most Visible slot). `healed` is true when something moved.
    public func healingSommelierItem() -> (layout: Layout, healed: Bool) {
        let k = ItemKey.sommelierStatusItem
        guard hidden.contains(k) || alwaysHidden.contains(k) else { return (self, false) }
        var out = self
        out.hidden.removeAll { $0 == k }
        out.alwaysHidden.removeAll { $0 == k }
        if !out.visible.contains(k) { out.insert([k], into: .visible, at: nil) }
        return (out, true)
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
        return (out, dropped)
    }

    // MARK: Codable (keys are stored as their string form)

    private enum CodingKeys: String, CodingKey { case schemaVersion, visible, hidden, alwaysHidden, newItemPolicy, pendingAdoption, pendingHandDrag, unreadAfterHandDrag, handWindowBaseline, handWindowDrops, migrations }

    static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
    static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    struct WindowDropCoding: Codable {
        var visible: [String]
        var moved: [String]
    }
    static func windowDrops(_ raw: [WindowDropCoding]?) -> [WindowDrop] {
        (raw ?? []).map { WindowDrop(visible: $0.visible.compactMap { ItemKey(storeKey: $0) }, moved: $0.moved.compactMap { ItemKey(storeKey: $0) }) }
    }

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
            pendingAdoption: try c.decodeIfPresent(Bool.self, forKey: .pendingAdoption) ?? false,
            pendingHandDrag: try c.decodeIfPresent(String.self, forKey: .pendingHandDrag).flatMap(Self.isoDate),
            unreadAfterHandDrag: try (c.decodeIfPresent([String].self, forKey: .unreadAfterHandDrag) ?? []).compactMap { ItemKey(storeKey: $0) },
            handWindowBaseline: try (c.decodeIfPresent([String].self, forKey: .handWindowBaseline) ?? []).compactMap { ItemKey(storeKey: $0) },
            handWindowDrops: Self.windowDrops(try c.decodeIfPresent([WindowDropCoding].self, forKey: .handWindowDrops)),
            migrations: try c.decodeIfPresent([String].self, forKey: .migrations) ?? [])
        var l = raw.dedup().layout.healingSommelierItem().layout
        l.visible.removeAll(where: \.isOverflowChevron)   // 9o9.14 (the warning is reported by `decode`)
        l.hidden.removeAll(where: \.isOverflowChevron)
        l.alwaysHidden.removeAll(where: \.isOverflowChevron)
        self = l
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(visible.map(\.description), forKey: .visible)
        try c.encode(hidden.map(\.description), forKey: .hidden)
        try c.encode(alwaysHidden.map(\.description), forKey: .alwaysHidden)
        try c.encode(newItemPolicy, forKey: .newItemPolicy)
        if pendingAdoption { try c.encode(true, forKey: .pendingAdoption) }   // absent = false
        if let d = pendingHandDrag { try c.encode(Self.isoString(d), forKey: .pendingHandDrag) }
        if !unreadAfterHandDrag.isEmpty { try c.encode(unreadAfterHandDrag.map(\.description), forKey: .unreadAfterHandDrag) }
        if !migrations.isEmpty { try c.encode(migrations, forKey: .migrations) }
        if !handWindowDrops.isEmpty {
            try c.encode(handWindowBaseline.map(\.description), forKey: .handWindowBaseline)
            try c.encode(handWindowDrops.map { WindowDropCoding(visible: $0.visible.map(\.description), moved: $0.moved.map(\.description)) }, forKey: .handWindowDrops)
        }
    }

    /// Decodes a layout file, reporting duplicates that were dropped and hide-unit normalization (reported once, here). Does not migrate.
    public static func decode(_ data: Data) throws -> (layout: Layout, warnings: [String], adoptBarOrder: Bool) {
        struct Raw: Decodable {
            var schemaVersion: Int?
            var visible: [String]?
            var hidden: [String]?
            var alwaysHidden: [String]?
            var newItemPolicy: NewItemPolicy?
            var pendingAdoption: Bool?
            var pendingHandDrag: String?
            var unreadAfterHandDrag: [String]?
            var handWindowBaseline: [String]?
            var handWindowDrops: [WindowDropCoding]?
            var migrations: [String]?
            var legacyOrderMode: Bool
            var legacyPlaced: Bool
            enum CodingKeys: String, CodingKey { case schemaVersion, visible, hidden, alwaysHidden, newItemPolicy, pendingAdoption, pendingHandDrag, unreadAfterHandDrag, handWindowBaseline, handWindowDrops, migrations, orderMode, placed }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
                visible = try c.decodeIfPresent([String].self, forKey: .visible)
                hidden = try c.decodeIfPresent([String].self, forKey: .hidden)
                alwaysHidden = try c.decodeIfPresent([String].self, forKey: .alwaysHidden)
                newItemPolicy = try c.decodeIfPresent(NewItemPolicy.self, forKey: .newItemPolicy)
                pendingAdoption = try c.decodeIfPresent(Bool.self, forKey: .pendingAdoption)
                pendingHandDrag = try c.decodeIfPresent(String.self, forKey: .pendingHandDrag)
                unreadAfterHandDrag = try c.decodeIfPresent([String].self, forKey: .unreadAfterHandDrag)
                handWindowBaseline = try c.decodeIfPresent([String].self, forKey: .handWindowBaseline)
                handWindowDrops = try c.decodeIfPresent([WindowDropCoding].self, forKey: .handWindowDrops)
                migrations = try c.decodeIfPresent([String].self, forKey: .migrations)
                legacyOrderMode = c.contains(.orderMode)   // 9o9.2: legacy fields are ignored (their value is not even parsed)
                legacyPlaced = c.contains(.placed)
            }
        }
        let r = try JSONDecoder().decode(Raw.self, from: data)
        let raw = Layout(
            schemaVersion: r.schemaVersion ?? 1,
            visible: try (r.visible ?? []).map(parse),
            hidden: try (r.hidden ?? []).map(parse),
            alwaysHidden: try (r.alwaysHidden ?? []).map(parse),
            newItemPolicy: r.newItemPolicy ?? .visibleAtEnd,
            pendingAdoption: false)
        // 9o9.14: heal files that recorded the overflow chevron; the warning is emitted here, once, and the key is gone from every section.
        var stripped = raw
        var chevronSections: [LayoutSection] = []
        for s in LayoutSection.allCases where raw.keys(in: s).contains(where: \.isOverflowChevron) {
            chevronSections.append(s)
            switch s {
            case .visible: stripped.visible.removeAll(where: \.isOverflowChevron)
            case .hidden: stripped.hidden.removeAll(where: \.isOverflowChevron)
            case .alwaysHidden: stripped.alwaysHidden.removeAll(where: \.isOverflowChevron)
            }
        }
        let d = stripped.dedup()
        let healedOwn = d.layout.healingSommelierItem()
        let n = healedOwn.layout.normalizedHideUnits()
        var warnings: [String] = []
        if r.legacyOrderMode { warnings.append("ignored legacy field orderMode") }
        if r.legacyPlaced { warnings.append("ignored legacy field placed") }
        // A legacy field means this file predates the record-is-the-order model: the engine adopts the bar's order once.
        let adopt = r.legacyOrderMode || r.legacyPlaced || (r.pendingAdoption ?? false)
        var layout = n.layout
        layout.pendingAdoption = adopt
        layout.pendingHandDrag = r.pendingHandDrag.flatMap(isoDate)
        layout.unreadAfterHandDrag = (r.unreadAfterHandDrag ?? []).compactMap { ItemKey(storeKey: $0) }
        layout.handWindowBaseline = (r.handWindowBaseline ?? []).compactMap { ItemKey(storeKey: $0) }
        layout.handWindowDrops = windowDrops(r.handWindowDrops)
        layout.migrations = r.migrations ?? []
        if healedOwn.healed { warnings.append("Sommelier's own status item was outside Visible; moved back to visible (it is never hidden)") }
        warnings += chevronSections.map { "ignored chevron key in \($0.rawValue)" }
        warnings += d.dropped.map { "duplicate key \($0.0) dropped from \($0.1.rawValue)" }
        if !n.moved.isEmpty {
            warnings.append("hide units normalized: " + n.moved.map(\.description).joined(separator: ", ")
                + " moved to visible (all items governed by one Control Center entry hide or show at once)")
        }
        return (layout, warnings, adopt)
    }

    /// Schema migration. No transforms exist yet; lower versions are just bumped.
    public static func migrate(_ layout: Layout) throws -> Layout {
        if layout.schemaVersion > currentSchemaVersion { throw LayoutError.unsupportedSchema(layout.schemaVersion) }
        var l = layout
        l.schemaVersion = currentSchemaVersion
        return l
    }
}
