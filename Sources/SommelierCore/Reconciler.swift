import Foundation

/// Observed menu bar state as the planner sees it: keys left to right on the bar, plus parked (off-bar) keys.
public struct ObservedOrder: Equatable, Sendable {
    public var onBar: [ItemKey]
    public var parked: [ItemKey]
    /// Keys in `onBar` that macOS pushed into its own overflow (gdu.45): reported on the bar, not drawn, undraggable.
    public var systemOverflow: Set<ItemKey>
    /// The overflow chevron when it is on the bar: the hard left boundary of everything that may be dragged (gdu.45).
    public var overflowChevron: ItemKey?
    public init(onBar: [ItemKey], parked: [ItemKey], systemOverflow: Set<ItemKey> = [], overflowChevron: ItemKey? = nil) {
        self.onBar = onBar
        self.parked = parked
        self.systemOverflow = systemOverflow
        self.overflowChevron = overflowChevron
    }

    /// Builds the observed order from a resolved scan. Fresh on-bar items (width > 1) in frame order become `onBar`;
    /// other items with width > 1 become `parked`. Items with width <= 1 (main-menu entries, not status items) are
    /// ignored, and STALE items (carried forward from an earlier scan) are EXCLUDED entirely: the planner never plans
    /// on data it cannot trust. Duplicate keys keep their first occurrence.
    public init(resolved: [ResolvedItem]) {
        var seen = Set<ItemKey>()
        var bar: [(CGFloat, ItemKey)] = []
        var off: [ItemKey] = []
        var ovf = Set<ItemKey>()
        var chevron: ItemKey?
        for r in resolved where !r.item.stale && r.item.frame.width > 1 {
            guard seen.insert(r.key).inserted else { continue }
            if r.item.isOnMenuBar {
                bar.append((r.item.frame.minX, r.key))
                if r.item.systemOverflow { ovf.insert(r.key) }
                if r.item.isOverflowChevron { chevron = chevron ?? r.key }
            } else { off.append(r.key) }
        }
        // Stable sort by x (enumerated index breaks ties).
        let ordered = bar.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
        self.init(onBar: ordered.map(\.element.1), parked: off, systemOverflow: ovf, overflowChevron: chevron)
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

        // Classify. Hide granularity is the app (HideUnit): decide per unit, then apply the decision to every observed
        // key of the unit, so the plan never hides one item of an app and leaves a sibling on the bar.
        // A unit is hidden only if ALL its layout-listed observed keys are in hidden/alwaysHidden (and the hidden
        // section is not being revealed); otherwise it is shown. A unit the layout does not list at all follows the
        // new-item policy, and only when one of its items is on the bar (a parked unknown app is never shown).
        var skipped: [SkippedAction] = []
        var unitWantsBar: [HideUnit: Bool] = [:]
        // Section an unknown key of a unit gets when the unit is known only through layout-listed siblings that are
        // ABSENT from this observation (gdu.44): it joins its unit's section instead of following `newItemPolicy`.
        var unitJoinSection: [HideUnit: LayoutSection] = [:]
        var listedByUnit: [HideUnit: [LayoutSection]] = [:]
        for s in LayoutSection.allCases { for k in layout.keys(in: s) { listedByUnit[k.hideUnit, default: []].append(s) } }
        for (unit, ks) in hideUnits(onBar + parked) {
            var secs = ks.compactMap { layout.section(of: $0) }
            if secs.isEmpty, let listed = listedByUnit[unit] {
                secs = listed
                unitJoinSection[unit] = listed.contains(.alwaysHidden) ? .alwaysHidden : (listed.allSatisfy { $0 != .visible } ? .hidden : .visible)
            }
            if secs.isEmpty {
                unitWantsBar[unit] = layout.newItemPolicy == .visibleAtEnd && ks.contains { onBarSet.contains($0) }
                continue
            }
            let allHidden = secs.allSatisfy { $0 != .visible }
            // An always-hidden item keeps its whole app hidden even while the hidden section is revealed: the reveal is
            // temporary, "never show" is not.
            let pinned = secs.contains(.alwaysHidden)
            let revealed = showHiddenSection && secs.contains(.hidden) && !pinned
            let wants = !allHidden || revealed
            unitWantsBar[unit] = wants
            if !wants {
                if showHiddenSection, allHidden, pinned, let pin = ks.first(where: { layout.section(of: $0) == .alwaysHidden }) {
                    for k in ks where layout.section(of: k) == .hidden {
                        skipped.append(SkippedAction(k, "kept hidden together with \(pin): an always-hidden item keeps its app hidden"))
                    }
                }
                continue
            }
            if !allHidden, let anchor = ks.first(where: { layout.section(of: $0) == .visible }) {
                for k in ks {
                    let s = layout.section(of: k)
                    if s == .alwaysHidden || (s == .hidden && !showHiddenSection) {
                        skipped.append(SkippedAction(k, "hidden together with \(anchor.hideUnit.id): all items of an app hide or show at once"))
                    }
                }
            }
        }
        var newItems: [NewItem] = []
        var wantOnBar = Set<ItemKey>()
        var unknownVisible: [ItemKey] = []
        for k in onBar + parked {
            let wants = unitWantsBar[k.hideUnit] ?? false
            if wants { wantOnBar.insert(k) }
            if layout.section(of: k) == nil {
                if wants { unknownVisible.append(k) }
                newItems.append(NewItem(k, unitJoinSection[k.hideUnit] ?? (wants ? .visible : .hidden)))
            }
        }
        let absent = layout.allKeys.filter { !observedAll.contains($0) }

        // Membership actions. A unit that must hide but has an unhideable item on the bar is not hidden at all.
        var hides: [ItemKey] = [], shows: [ItemKey] = []
        var unhideable = Set<ItemKey>()
        var blocker: [HideUnit: ItemKey] = [:]
        for k in onBar where !wantOnBar.contains(k) && !capabilities(k).canHide {
            if blocker[k.hideUnit] == nil { blocker[k.hideUnit] = k }
        }
        for k in onBar where !wantOnBar.contains(k) {
            if let b = blocker[k.hideUnit] {
                unhideable.insert(k)
                skipped.append(SkippedAction(k, k == b ? (capabilities(k).reason ?? "cannot be hidden")
                                                       : "cannot be hidden: \(b) in the same app cannot be hidden"))
            } else {
                hides.append(k)
            }
        }
        for k in parked where wantOnBar.contains(k) { shows.append(k) }

        // Desired order of everything that may sit on the bar. Hidden-listed keys pulled onto the bar by their unit
        // follow the visible ones, in layout order.
        var desired: [ItemKey] = layout.visible.filter { wantOnBar.contains($0) }
        if showHiddenSection { desired += layout.hidden.filter { wantOnBar.contains($0) } }
        let placed = Set(desired)
        desired += (layout.hidden + layout.alwaysHidden).filter { wantOnBar.contains($0) && !placed.contains($0) }
        desired += unknownVisible

        // Base sequence the order is planned on: the bar after the hides, shown items appended.
        let hideSet = Set(hides)
        // Items in macOS's own overflow are not drawn and cannot be dragged, and the chevron is the hard left boundary of
        // the drawn bar: the order is planned on the drawn items right of it only, so no move has an overflowed item or the
        // chevron as subject or relation target, and none lands left of the chevron (`.leftmost` is rewritten, see `moves`).
        let ovf = observed.systemOverflow.intersection(onBarSet)
        let chevron = observed.overflowChevron.flatMap { onBarSet.contains($0) ? $0 : nil }
        let ovfKept = onBar.filter { ovf.contains($0) && wantOnBar.contains($0) && !hideSet.contains($0) }
        // macOS decides what overflows (total width); a layout's order across the overflow boundary is not a request we can
        // act on. Overflowed keys and the chevron are therefore dropped from `desired` and `base` before the ORDER planning:
        // no drawn key is anchored or reported because of them, whatever the layout lists (unknown, pulled-in, normalized,
        // churned). Membership (hiding an overflowed key) was decided above and is unchanged.
        desired = desired.filter { !ovf.contains($0) && $0 != chevron }
        let kept = onBar.filter { !hideSet.contains($0) && !ovf.contains($0) && $0 != chevron }
        let base = kept + shows
        let anchors = Set(base.filter { !capabilities($0).canMove || unhideable.contains($0) })
        var target = Self.layoutTarget(base: base, desired: desired, anchors: anchors)
        // Anchors never move, so the target is reachable only if they appear in the same relative order in the layout
        // as on the bar. Offending anchors are reported; the rest is planned with every anchor in its observed slot.
        let anchorsInBase = base.filter { anchors.contains($0) }
        let tIdx = Dictionary(uniqueKeysWithValues: target.enumerated().map { ($1, $0) })
        let seq = anchorsInBase.map { tIdx[$0]! }
        var anchorsOutOfOrder = false
        if zip(seq, seq.dropFirst()).contains(where: { $0 >= $1 }) {
            anchorsOutOfOrder = true
            let keep = Set(Self.lis(seq))
            // Not reported in a membership phase (gdu.44): the bar is about to change, a transient or churned bar can show
            // anchors out of order that the next (order) pass finds fine. The order pass re-evaluates and reports them.
            if shows.isEmpty && hides.isEmpty {
                for k in anchorsInBase where !keep.contains(tIdx[k]!) {
                    skipped.append(SkippedAction(k, "immovable item is out of layout order"))
                }
            }
            var fill = desired.filter { !anchors.contains($0) }.makeIterator()
            target = base.map { anchors.contains($0) ? $0 : (fill.next() ?? $0) }
        }

        // Trailing system block: the maximal suffix of the bar made only of anchors (Control Center modules, clock).
        // Nothing movable can be placed right of its first item, so such targets are reported and relocated to the last
        // slot before the block (relative order kept); no drag ever targets the block.
        // The block is taken from the observed bar BEFORE shown items are appended (`kept`): in a membership pass the shows
        // would otherwise hide it, and `skipped`/`desiredOnBar` would put a key right of the clock until the order pass (gdu.44).
        let blockStart = Self.trailingBlockStart(base: kept, anchors: anchors)
        if blockStart < kept.count {
            let blockSet = Set(kept[blockStart...])
            let systemBlock = blockSet.contains { if case .module = $0 { true } else { false } }
            if anchorsOutOfOrder, systemBlock, let first = desired.firstIndex(where: { blockSet.contains($0) }) {
                // Out-of-order anchors keep their slots, so the movable keys the layout puts right of the block land left of
                // it without being "beyond" in `target`: they still get their own skip entry (gdu.44). Only for a block that
                // really holds system items (modules); a trailing run of merely immovable/failed third-party items is not one.
                for k in desired[(first + 1)...] where !anchors.contains(k) && !blockSet.contains(k) {
                    skipped.append(SkippedAction(k, "cannot be placed right of the system items (\(kept[blockStart]))"))
                }
            }
            let firstBlockInTarget = target.firstIndex { blockSet.contains($0) } ?? target.count
            let limit = min(blockStart, firstBlockInTarget)
            let beyond = target.enumerated().filter { $0.offset >= limit && !anchors.contains($0.element) }.map(\.element)
            if !beyond.isEmpty {
                for k in beyond where !skipped.contains(where: { $0.key == k && $0.reason.hasPrefix("cannot be placed right of the system items") }) {
                    skipped.append(SkippedAction(k, "cannot be placed right of the system items (\(kept[blockStart]))"))
                }
                target = target.filter { !blockSet.contains($0) } + kept[blockStart...]
            }
        }

        var actions: [PlannedAction] = hides.map { .hide($0) } + shows.map { .show($0) }
        let phase: PlanPhase
        if !actions.isEmpty {
            phase = .membership
        } else {
            actions = Self.moves(from: base, to: target, anchors: anchors, boundary: chevron != nil)
            assert(Self.overflowViolations(actions, forbidden: ovf.union(chevron.map { [$0] } ?? []), boundary: chevron != nil).isEmpty,
                   "planned a move of or into macOS's overflow area")
            assert(Self.violations(actions, target: target, anchors: anchors, blockStart: blockStart).isEmpty,
                   "planned a move of or into the trailing system block")
            phase = actions.isEmpty ? .converged : .order
        }
        return Plan(phase: phase, actions: actions, newItems: newItems, absent: absent, skipped: skipped, desiredOnBar: ovfKept + (chevron.map { [$0] } ?? []) + target)
    }

    /// Post-condition (gdu.45): a move whose subject or relation target is overflowed or the chevron, or (with a chevron)
    /// that drops at the far left of the bar, i.e. left of the chevron.
    static func overflowViolations(_ actions: [PlannedAction], forbidden: Set<ItemKey>, boundary: Bool) -> [PlannedAction] {
        actions.filter {
            guard case .move(let k, let rel) = $0 else { return false }
            if forbidden.contains(k) { return true }
            switch rel {
            case .before(let t), .after(let t): return forbidden.contains(t)
            case .leftmost: return boundary
            case .rightmost: return false
            }
        }
    }

    /// Index in `base` where the trailing run of anchors starts (`base.count` when the last item is movable).
    static func trailingBlockStart(base: [ItemKey], anchors: Set<ItemKey>) -> Int {
        var i = base.count
        while i > 0, anchors.contains(base[i - 1]) { i -= 1 }
        return i
    }

    /// Post-condition: actions whose subject is an anchor, or whose destination slot in `target` is at/after `blockStart`.
    static func violations(_ actions: [PlannedAction], target: [ItemKey], anchors: Set<ItemKey>, blockStart: Int) -> [PlannedAction] {
        actions.filter {
            guard case .move(let k, _) = $0 else { return false }
            return anchors.contains(k) || (target.firstIndex(of: k) ?? Int.max) >= blockStart
        }
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
    static func moves(from current: [ItemKey], to target: [ItemKey], anchors: Set<ItemKey>, boundary: Bool = false) -> [PlannedAction] {
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
            else if i == 0 {
                // With a chevron, "leftmost" would drop the item left of it (inside the overflow area): drop before the
                // first other drawn item instead (nothing has been moved yet at index 0).
                if boundary {
                    guard let f = current.first(where: { $0 != k }) else { inPlace.insert(k); continue }
                    relation = .before(f)
                } else { relation = .leftmost }
            }
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
