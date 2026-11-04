import Foundation

/// Observed menu bar state as the planner sees it: keys left to right on the bar, plus parked (off-bar) keys.
public struct ObservedOrder: Equatable, Sendable {
    public var onBar: [ItemKey]
    public var parked: [ItemKey]
    public init(onBar: [ItemKey], parked: [ItemKey]) {
        self.onBar = onBar
        self.parked = parked
    }

    /// Builds the observed order from a resolved scan. Fresh on-bar items (width > 1) in frame order become `onBar`;
    /// other items with width > 1 become `parked`. Items with width <= 1 (main-menu entries, not status items) are
    /// ignored, and STALE items (carried forward from an earlier scan) are EXCLUDED entirely: the planner never plans
    /// on data it cannot trust. Duplicate keys keep their first occurrence.
    public init(resolved: [ResolvedItem]) {
        var seen = Set<ItemKey>()
        var bar: [(CGFloat, ItemKey)] = []
        var off: [ItemKey] = []
        for r in resolved where !r.item.stale && r.item.frame.width > 1 {
            guard seen.insert(r.key).inserted else { continue }
            if r.item.isOnMenuBar { bar.append((r.item.frame.minX, r.key)) } else { off.append(r.key) }
        }
        // Stable sort by x (enumerated index breaks ties).
        let ordered = bar.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
        self.init(onBar: ordered.map(\.element.1), parked: off)
    }
}

public enum PlannedAction: Equatable, Sendable {
    case move(ItemKey, Relation)
    case hide(ItemKey)
    case show(ItemKey)
}

public enum PlanPhase: Equatable, Sendable {
    /// Hide/show actions only; apply as one batch, re-observe, then plan again.
    case membership
    /// Move actions only.
    case order
    case converged
}

public struct NewItem: Equatable, Sendable {
    public var key: ItemKey
    public var section: LayoutSection
    public init(_ key: ItemKey, _ section: LayoutSection) { self.key = key; self.section = section }
}

public struct SkippedAction: Equatable, Sendable {
    public var key: ItemKey
    public var reason: String
    public init(_ key: ItemKey, _ reason: String) { self.key = key; self.reason = reason }
}

public struct Plan: Equatable, Sendable {
    public var phase: PlanPhase
    /// Empty iff `phase == .converged`.
    public var actions: [PlannedAction]
    /// Observed keys absent from the layout, with the section the policy assigns. The engine persists these.
    public var newItems: [NewItem]
    /// Layout keys not observed (ignored).
    public var absent: [ItemKey]
    /// Actions suppressed by capabilities.
    public var skipped: [SkippedAction]
    /// The left-to-right on-bar order this plan converges to (in the membership phase, shown items are assumed to be
    /// appended at the end, since MenuBarAgent picks the real slot).
    public var desiredOnBar: [ItemKey]
}

/// Pure planner: observed snapshot + desired layout -> ordered actions. See docs/architecture.md (Reconciler).
public struct Reconciler: Sendable {
    public init() {}

    public func plan(observed: ObservedOrder, layout: Layout, capabilities: (ItemKey) -> Capability,
                     showHiddenSection: Bool = false) -> Plan {
        // Defensive dedup: first occurrence wins; a key on the bar is never also parked.
        var seen = Set<ItemKey>()
        let onBar = observed.onBar.filter { seen.insert($0).inserted }
        let parked = observed.parked.filter { seen.insert($0).inserted }
        let onBarSet = Set(onBar)
        let observedAll = Set(onBar + parked)

        // Classify.
        var newItems: [NewItem] = []
        var wantOnBar = Set<ItemKey>()
        var unknownVisible: [ItemKey] = []
        for k in onBar + parked {
            let onB = onBarSet.contains(k)
            if let s = layout.section(of: k) {
                if s == .visible || (s == .hidden && showHiddenSection) { wantOnBar.insert(k) }
            } else if onB {
                if layout.newItemPolicy == .visibleAtEnd {
                    wantOnBar.insert(k); unknownVisible.append(k); newItems.append(NewItem(k, .visible))
                } else {
                    newItems.append(NewItem(k, .hidden))
                }
            } else {
                newItems.append(NewItem(k, .hidden))   // unknown parked: never shown
            }
        }
        let absent = layout.allKeys.filter { !observedAll.contains($0) }

        // Membership actions.
        var skipped: [SkippedAction] = []
        var hides: [ItemKey] = [], shows: [ItemKey] = []
        var unhideable = Set<ItemKey>()
        for k in onBar where !wantOnBar.contains(k) {
            let cap = capabilities(k)
            if cap.canHide { hides.append(k) } else {
                unhideable.insert(k)
                skipped.append(SkippedAction(k, cap.reason ?? "cannot be hidden"))
            }
        }
        for k in parked where wantOnBar.contains(k) { shows.append(k) }

        // Desired order of everything that may sit on the bar.
        let observedWanted = wantOnBar
        var desired: [ItemKey] = layout.visible.filter { observedWanted.contains($0) }
        if showHiddenSection { desired += layout.hidden.filter { observedWanted.contains($0) } }
        desired += unknownVisible

        // Base sequence the order is planned on: the bar after the hides, shown items appended.
        let hideSet = Set(hides)
        let base = onBar.filter { !hideSet.contains($0) } + shows
        let anchors = Set(base.filter { !capabilities($0).canMove || unhideable.contains($0) })
        var target = Self.layoutTarget(base: base, desired: desired, anchors: anchors)
        // Anchors never move, so the target is reachable only if they appear in the same relative order in the layout
        // as on the bar. Offending anchors are reported; the rest is planned with every anchor in its observed slot.
        let anchorsInBase = base.filter { anchors.contains($0) }
        let tIdx = Dictionary(uniqueKeysWithValues: target.enumerated().map { ($1, $0) })
        let seq = anchorsInBase.map { tIdx[$0]! }
        if zip(seq, seq.dropFirst()).contains(where: { $0 >= $1 }) {
            let keep = Set(Self.lis(seq))
            for k in anchorsInBase where !keep.contains(tIdx[k]!) {
                skipped.append(SkippedAction(k, "immovable item is out of layout order"))
            }
            var fill = desired.filter { !anchors.contains($0) }.makeIterator()
            target = base.map { anchors.contains($0) ? $0 : (fill.next() ?? $0) }
        }

        var actions: [PlannedAction] = hides.map { .hide($0) } + shows.map { .show($0) }
        let phase: PlanPhase
        if !actions.isEmpty {
            phase = .membership
        } else {
            actions = Self.moves(from: base, to: target, anchors: anchors)
            phase = actions.isEmpty ? .converged : .order
        }
        return Plan(phase: phase, actions: actions, newItems: newItems, absent: absent, skipped: skipped, desiredOnBar: target)
    }

    /// The full left-to-right order the layout asks for, anchors included. Anchors the layout does not place (not in
    /// `desired`, e.g. an unhideable item the layout wants hidden) keep their observed slot; every other slot is filled
    /// with `desired` in order.
    static func layoutTarget(base: [ItemKey], desired: [ItemKey], anchors: Set<ItemKey>) -> [ItemKey] {
        let placed = Set(desired)
        var fill = desired.makeIterator()
        return base.map { (anchors.contains($0) && !placed.contains($0)) ? $0 : (fill.next() ?? $0) }
    }

    /// Minimal moves turning `current` into `target` (same key set) with `anchors` never moved.
    static func moves(from current: [ItemKey], to target: [ItemKey], anchors: Set<ItemKey>) -> [PlannedAction] {
        guard current != target, current.count == target.count else { return [] }
        var tIndex: [ItemKey: Int] = [:]
        for (i, k) in target.enumerated() { tIndex[k] = i }
        let keep = keptSet(current: current, tIndex: tIndex, anchors: anchors)

        var inPlace = keep
        var out: [PlannedAction] = []
        for (i, k) in target.enumerated() where !keep.contains(k) {
            let left = i > 0 ? target[i - 1] : nil
            let right = i + 1 < target.count ? target[i + 1] : nil
            let relation: Relation
            if let l = left, inPlace.contains(l) { relation = .after(l) }
            else if let r = right, inPlace.contains(r) { relation = .before(r) }
            else if i == 0 { relation = .leftmost }
            else { relation = .rightmost }   // only reachable for the last index; left is always placed before it
            out.append(.move(k, relation))
            inPlace.insert(k)
        }
        return out
    }

    /// Keys that stay put: all anchors plus, per gap between consecutive anchors, the longest increasing subsequence
    /// (by target index) of movable keys whose target index lies inside the gap's anchor bounds.
    private static func keptSet(current: [ItemKey], tIndex: [ItemKey: Int], anchors: Set<ItemKey>) -> Set<ItemKey> {
        var keep = anchors
        var segment: [Int] = []          // target indices of candidate movables in the current gap
        var lower = -1
        var byIndex: [Int: ItemKey] = [:]
        for (k, i) in tIndex { byIndex[i] = k }
        func flush(upper: Int) {
            let cands = segment.filter { $0 > lower && $0 < upper }
            for t in lis(cands) { keep.insert(byIndex[t]!) }
            segment.removeAll()
        }
        for k in current {
            let t = tIndex[k]!
            if anchors.contains(k) { flush(upper: t); lower = t } else { segment.append(t) }
        }
        flush(upper: Int.max)
        return keep
    }

    /// Longest strictly increasing subsequence (patience sorting with back-pointers); returns its values.
    static func lis(_ a: [Int]) -> [Int] {
        var tails: [Int] = []          // indices into a
        var prev = [Int](repeating: -1, count: a.count)
        for (i, v) in a.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi { let m = (lo + hi) / 2; if a[tails[m]] < v { lo = m + 1 } else { hi = m } }
            if lo > 0 { prev[i] = tails[lo - 1] }
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
        }
        var out: [Int] = []
        var i = tails.last ?? -1
        while i >= 0 { out.append(a[i]); i = prev[i] }
        return out.reversed()
    }
}
