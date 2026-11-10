import DecisionCore

/// sommelier-ejb.32: what the user's gesture does to the layout is computed by the PROVED core (Lean `applyGesture`), not here.
///
/// Swift keeps only: mapping UI rows and slots to a section index (`ArrangeDrop.index`), capability refusals, the "will not fit" hint, and
/// the translation between `ItemKey` and core `Key` ids (a scratch table that covers EVERY key of the layout, modules and parked keys included, and the
/// gesture's own keys). The new layout and the moved keys come back from Lean; there is no fallback: a `DecisionError` is the caller's to show.
public enum GestureRequest: Equatable, Sendable {
    /// Drop `key` into `section` at `index` (taken after the lifted keys are removed; clamped; `nil` appends, Visible: before the trailing system block).
    case drop(ItemKey, LayoutSection, index: Int?)
    /// "Hide what does not fit": these overflowed Visible keys, with their hide units, to the end of Hidden.
    case hideNotFitting([ItemKey])
}

/// `ItemKey <-> core Key` for the duration of ONE gesture: ids are assigned in first-seen order from the keys the call passes in.
struct GestureKeyTable {
    private(set) var ids: [ItemKey: UInt32] = [:]
    private(set) var keys: [ItemKey] = []
    mutating func id(_ k: ItemKey) -> UInt32 {
        if let i = ids[k] { return i }
        let i = UInt32(keys.count)
        ids[k] = i; keys.append(k)
        return i
    }
    func key(_ id: UInt32) -> ItemKey? { Int(id) < keys.count ? keys[Int(id)] : nil }
}

extension Layout {
    private static func section3(_ s: LayoutSection) -> LayoutSection3 {
        switch s { case .visible: return .visible; case .hidden: return .hidden; case .alwaysHidden: return .alwaysHidden }
    }

    /// The layout after the gesture and the keys the user moved, both computed by the proved core. Fields other than the three sections are carried over unchanged.
    public func applying(_ gesture: GestureRequest, units: HideUnitRule = .ownerKeys) throws(DecisionError) -> (layout: Layout, moved: [ItemKey]) {
        var table = GestureKeyTable()
        func ids(_ l: [ItemKey]) -> [Key] { l.map { table.id($0) } }
        let lay = Layout3(visible: ids(visible), hidden: ids(hidden), alwaysHidden: ids(alwaysHidden))
        let g: LayoutGesture
        switch gesture {
        case .drop(let k, let s, let index):
            let idx: UInt32? = index.map { UInt32(clamping: max(0, $0)) }   // a negative index is the start of the section
            g = .drop(table.id(k), Layout.section3(s), index: idx)
        case .hideNotFitting(let ks):
            g = .hideNotFitting(ids(ks))
        }
        // the hide-unit table covers every key the core will see; a unit is named by the id of its first key
        var rep: [HideUnit: UInt32] = [:]
        var unitTable: [Key: UInt32] = [:]
        var immovable = Set<Key>()
        for (i, k) in table.keys.enumerated() {
            let id = UInt32(i)
            let u = units.unit(of: k)
            unitTable[id] = rep[u] ?? { rep[u] = id; return id }()
            if case .module = k { immovable.insert(id) }
        }
        let r = try DecisionCore.applyGesture(layout: lay, units: unitTable, immovable: immovable, gesture: g)
        func back(_ l: [Key]) throws(DecisionError) -> [ItemKey] {
            var out: [ItemKey] = []
            for id in l { guard let k = table.key(id) else { throw DecisionError.undecodableOutput }; out.append(k) }
            return out
        }
        var out = self
        out.visible = try back(r.layout.visible)
        out.hidden = try back(r.layout.hidden)
        out.alwaysHidden = try back(r.layout.alwaysHidden)
        return (out, try back(r.moved))
    }

    /// Moves (or inserts) `key` into `section`: computed by the proved core (`applying`). A same-section drop moves only `key`; a cross-section drop moves the whole hide unit
    /// (`key` at the index, its siblings right behind it); `index` is taken after the lifted keys are removed and clamped; `nil` appends (Visible: before the trailing system block).
    /// Returns the keys the user moved (exactly `[key]`).
    @discardableResult
    public mutating func move(_ key: ItemKey, to section: LayoutSection, index: Int? = nil, units: HideUnitRule = .ownerKeys) throws(DecisionError) -> [ItemKey] {
        let r = try applying(.drop(key, section, index: index), units: units)
        self = r.layout
        return r.moved
    }

    /// "Hide what does not fit" (gdu.45): each of `keys` that is in Visible, with its hide-unit siblings, to the end of Hidden, in the order given; keys that are not in Visible are
    /// ignored. Computed by the proved core. Returns every key that moved (siblings included), once each, in the order moved.
    @discardableResult
    public mutating func hideNotFitting(_ keys: [ItemKey], units: HideUnitRule = .ownerKeys) throws(DecisionError) -> [ItemKey] {
        let r = try applying(.hideNotFitting(keys), units: units)
        self = r.layout
        return r.moved
    }
}
