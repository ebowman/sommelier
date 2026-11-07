import Foundation

/// Observed menu bar state as the planner sees it: keys left to right on the bar, plus parked (off-bar) keys.
public struct ObservedOrder: Equatable, Sendable {
    public var onBar: [ItemKey]
    public var parked: [ItemKey]
    /// Keys in `onBar` that macOS pushed into its own overflow (gdu.45): reported on the bar, not drawn, undraggable.
    public var systemOverflow: Set<ItemKey>
    /// The overflow chevron when it is on the bar: the hard left boundary of everything that may be dragged (gdu.45).
    public var overflowChevron: ItemKey?
    /// Keys in `parked` whose placement is unknown (gdu.79: app-side frame only, no hosted element, Control Center does not say hidden).
    /// The planner must not treat them as parked: they are neither shown nor counted as hidden.
    public var placementUnknown: Set<ItemKey>
    /// gdu.94: keys in `onBar` whose slot rests on no hosted element (an app-side frame only: join `.none` / not corroborated), or that
    /// Control Center lists hidden / not allowed. The frame may be stale and sit on another item's slot: never a move subject.
    public var uncorroborated: Set<ItemKey>
    /// gdu.101: keys in `onBar` whose frame is a carried-forward (stale) read: the item IS on the bar, at its last-known slot, but the app
    /// has not answered a position read. Always also in `uncorroborated` when built from a scan. Shown (flagged) by the Arrange window,
    /// never a move subject, never hidden on a stale frame alone.
    public var staleOnBar: Set<ItemKey>
    /// gdu.120: the subset of `staleOnBar` that was `recentlyVerified` (carried briefly with an unchanged frame). DISPLAY only: the
    /// planner reads `staleOnBar`, so these keys are still never a move subject or target.
    public var carriedRecently: Set<ItemKey> = []
    public init(onBar: [ItemKey], parked: [ItemKey], systemOverflow: Set<ItemKey> = [], overflowChevron: ItemKey? = nil,
                placementUnknown: Set<ItemKey> = [], uncorroborated: Set<ItemKey> = [], staleOnBar: Set<ItemKey> = []) {
        self.staleOnBar = staleOnBar
        self.uncorroborated = uncorroborated
        self.placementUnknown = placementUnknown
        self.onBar = onBar
        self.parked = parked
        self.systemOverflow = systemOverflow
        self.overflowChevron = overflowChevron
    }

    /// Builds the observed order from a resolved scan. Fresh on-bar items (width > 1) in frame order become `onBar`;
    /// other items with width > 1 become `parked`. Items with width <= 1 (main-menu entries, not status items) are
    /// ignored. STALE items (carried forward from an earlier scan): a stale ON-BAR item is kept in `onBar` at its last-known x and
    /// flagged in `staleOnBar` + `uncorroborated` (gdu.101: the UI must not omit items that are on the bar; the planner treats it as an
    /// immovable anchor); a stale PARKED item is excluded (the planner never plans on it). Duplicate keys keep their first occurrence.
    public init(resolved: [ResolvedItem]) {
        var seen = Set<ItemKey>()
        var bar: [(CGFloat, ItemKey)] = []
        var off: [ItemKey] = []
        var ovf = Set<ItemKey>()
        var unknown = Set<ItemKey>()
        var uncorr = Set<ItemKey>()
        var stale = Set<ItemKey>()
        var recent = Set<ItemKey>()
        var chevron: ItemKey?
        for r in resolved where r.item.frame.width > 1 && (!r.item.stale || r.item.isOnMenuBar) {
            guard seen.insert(r.key).inserted else { continue }
            if r.item.isOnMenuBar {
                if r.item.stale { stale.insert(r.key); uncorr.insert(r.key); if r.item.recentlyVerified { recent.insert(r.key) } }
                bar.append((r.item.frame.minX, r.key))
                if r.item.systemOverflow, !r.item.stale { ovf.insert(r.key) }
                if r.item.isOverflowChevron, !r.item.stale { chevron = chevron ?? r.key }
                // Hosted-only items (modules, clock) are the agent's own elements: no join to corroborate.
                if (r.item.source == .appExtras && !r.item.joinEvidence.corroborated) || r.item.controlCenterAllowed == false
                    || r.item.hiddenInControlCenter { uncorr.insert(r.key) }
            } else { off.append(r.key); if r.item.placementUnknown { unknown.insert(r.key) } }
        }
        // Stable sort by x (enumerated index breaks ties).
        let ordered = bar.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
        self.init(onBar: ordered.map(\.element.1), parked: off, systemOverflow: ovf, overflowChevron: chevron, placementUnknown: unknown, uncorroborated: uncorr, staleOnBar: stale)
        self.carriedRecently = recent
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

    public func plan(observed: ObservedOrder, layout: Layout, capabilities rawCapabilities: (ItemKey) -> Capability,
                     showHiddenSection: Bool = false, showAlwaysHidden: Bool = false,
                     units rule: HideUnitRule = .ownerKeys, churn: Set<ItemKey> = [], placed: Set<ItemKey>? = nil) -> Plan {
        // gdu.89: `placed` = the keys whose position the user chose (`Layout.placed`). Only they create an order obligation: the order
        // target is the OBSERVED order with each placed key moved next to its neighbour as the layout records it; every other key
        // keeps the order the bar gives it and is never the subject of a move. `nil` keeps the legacy full-order enforcement
        // (the whole of `Layout.visible`), which is what `placed == Set(layout.visible)` asks for; production callers (the engine,
        // mbprobe) always pass `layout.placed`.
        let userOrder = placed != nil
        // gdu.120: iStat Menus items are ordinary orderable items (verified live: a Command-drag takes effect and holds); there is
        // no anchor treatment by owner. Only the capability the caller reports (and stale/uncorroborated slots, below) pins a key.
        func capabilities(_ k: ItemKey) -> Capability { rawCapabilities(k) }
        // Defensive dedup: first occurrence wins; a key on the bar is never also parked.
        var seen = Set<ItemKey>()
        let onBar = observed.onBar.filter { seen.insert($0).inserted }
        let parked = observed.parked.filter { seen.insert($0).inserted }
        let onBarSet = Set(onBar)
        let parkedSet = Set(parked)
        let observedAll = Set(onBar + parked)

        // Classify. Hide granularity is the Control Center entry (HideUnit, gdu.75): decide per unit, then apply the decision to every observed
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
        for s in LayoutSection.allCases { for k in layout.keys(in: s) { listedByUnit[rule.unit(of: k), default: []].append(s) } }
        for (unit, ks) in hideUnits(onBar + parked, rule: rule) {
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
            // `showAlwaysHidden` (option-click) lifts the pin for this reveal only.
            let pinned = secs.contains(.alwaysHidden) && !showAlwaysHidden
            let revealed = (showHiddenSection && secs.contains(.hidden) && !pinned) || (showAlwaysHidden && secs.contains(.alwaysHidden))
            var wants = !allHidden || revealed
            // gdu.15: a unit pulled onto the bar only by a reveal is dropped (whole unit, units stay whole) when one of its parked
            // keys cannot be shown (no Control Center entry: the same predicate LiveActuator refuses a batch on). The reveal
            // then shows the applicable units instead of one untracked key refusing the whole batch. A key that failed earlier
            // is skipped like any other (gdu.73): the struck-out key keeps its own `.failed` status, the rest of the reveal shows.
            if wants, allHidden, revealed,
               let bad = ks.first(where: { parkedSet.contains($0) && !capabilities($0).canHide }) {
                // gdu.73: the reason comes from the capability itself (Apple app vs not tracked vs a refusal's own reason).
                let why = "cannot be shown: " + (capabilities(bad).reason ?? "not tracked by Control Center")
                for k in ks where parkedSet.contains(k) { skipped.append(SkippedAction(k, k == bad ? why : "\(why) (\(bad) in the same app)")) }
                wants = false
            }
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
                    if (s == .alwaysHidden && !showAlwaysHidden) || (s == .hidden && !showHiddenSection) {
                        skipped.append(SkippedAction(k, "hidden together with \(rule.unit(of: anchor).id): all items governed by one Control Center entry hide or show at once"))
                    }
                }
            }
        }
        var newItems: [NewItem] = []
        var wantOnBar = Set<ItemKey>()
        var unknownVisible: [ItemKey] = []
        for k in onBar + parked {
            let wants = unitWantsBar[rule.unit(of: k)] ?? false
            if wants { wantOnBar.insert(k) }
            if layout.section(of: k) == nil {
                if wants { unknownVisible.append(k) }
                newItems.append(NewItem(k, unitJoinSection[rule.unit(of: k)] ?? (wants ? .visible : .hidden)))
            }
        }
        let absent = layout.allKeys.filter { !observedAll.contains($0) }

        // Membership actions. A unit that must hide but has an unhideable item on the bar is not hidden at all.
        var hides: [ItemKey] = [], shows: [ItemKey] = []
        var unhideable = Set<ItemKey>()
        var blocker: [HideUnit: ItemKey] = [:]
        for k in onBar where !wantOnBar.contains(k) && !capabilities(k).canHide {
            if blocker[rule.unit(of: k)] == nil { blocker[rule.unit(of: k)] = k }
        }
        for k in onBar where !wantOnBar.contains(k) {
            if let b = blocker[rule.unit(of: k)] {
                unhideable.insert(k)
                skipped.append(SkippedAction(k, k == b ? (capabilities(k).reason ?? "cannot be hidden")
                                                       : "cannot be hidden: \(b) in the same app cannot be hidden"))
            } else if observed.staleOnBar.contains(k) {
                // gdu.101: never hide on a stale frame alone; the item is on the bar as of the last read.
                skipped.append(SkippedAction(k, Reconciler.staleSkipReason))
            } else {
                hides.append(k)
            }
        }
        for k in parked where wantOnBar.contains(k) { shows.append(k) }

        // Desired order of everything that may sit on the bar. Hidden-listed keys pulled onto the bar by their unit
        // follow the visible ones, in layout order.
        var desired: [ItemKey] = layout.visible.filter { wantOnBar.contains($0) }
        if showHiddenSection { desired += layout.hidden.filter { wantOnBar.contains($0) } }
        if showAlwaysHidden { desired += layout.alwaysHidden.filter { wantOnBar.contains($0) } }
        let alreadyDesired = Set(desired)
        desired += (layout.hidden + layout.alwaysHidden).filter { wantOnBar.contains($0) && !alreadyDesired.contains($0) }
        desired += unknownVisible

        // Base sequence the order is planned on: the bar after the hides, shown items appended.
        let hideSet = Set(hides)
        // Items in macOS's own overflow are not drawn and cannot be dragged, and the chevron is the hard left boundary of
        // the drawn bar: the order is planned on the drawn items right of it only, so no move has an overflowed item or the
        // chevron as subject or relation target, and none lands left of the chevron (`.leftmost` is rewritten, see `moves`).
        // gdu.80: churn-zone keys (in the pile, or beside the first drawn item, in either of the last two complete reads) are
        // treated exactly like overflowed keys: never a move subject or anchor. The caller passes a non-empty set only while one of the last two complete reads had a chevron (the chevron may be gone now).
        let churnKeys = churn.intersection(onBarSet).subtracting(observed.systemOverflow)
        let ovf = observed.systemOverflow.intersection(onBarSet).union(churnKeys)
        let chevron = observed.overflowChevron.flatMap { onBarSet.contains($0) ? $0 : nil }
        let ovfKept = onBar.filter { ovf.contains($0) && wantOnBar.contains($0) && !hideSet.contains($0) }
        // macOS decides what overflows (total width); a layout's order across the overflow boundary is not a request we can
        // act on. Overflowed keys and the chevron are therefore dropped from `desired` and `base` before the ORDER planning:
        // no drawn key is anchored or reported because of them, whatever the layout lists (unknown, pulled-in, normalized,
        // churned). Membership (hiding an overflowed key) was decided above and is unchanged.
        // Self-positioning keys are not placed by the layout either: they keep their observed slot (like any unplaced anchor),
        // so their order never yields a move or an "out of order" finding.
        // gdu.69: an overflowed key the layout places differently relative to the DRAWN keys than where it sits (a move of it, or
        // around it, would have been planned) is reported as one skip with the honest reason. The order among overflowed keys
        // carries no information, and a layout that agrees with the observed order stays silent (gdu.45).
        do {
            let all = Set(onBar)
            let want = desired.filter { all.contains($0) && !hideSet.contains($0) && $0 != chevron }
            let have = onBar.filter { wantOnBar.contains($0) && !hideSet.contains($0) && $0 != chevron }
            func drawnBefore(_ k: ItemKey, _ list: [ItemKey]) -> Set<ItemKey>? {
                guard let i = list.firstIndex(of: k) else { return nil }
                return Set(list[..<i].filter { !ovf.contains($0) })
            }
            let listed = Set(layout.visible + layout.hidden + layout.alwaysHidden)
            for k in ovfKept where listed.contains(k) && want.contains(k) && (placed?.contains(k) ?? true) && drawnBefore(k, want) != drawnBefore(k, have) {
                skipped.append(SkippedAction(k, churnKeys.contains(k) ? SystemOverflowRule.churnSkipReason : Reconciler.overflowSkipReason))
            }
        }
        desired = desired.filter { !ovf.contains($0) && $0 != chevron }
        let kept = onBar.filter { !hideSet.contains($0) && !ovf.contains($0) && $0 != chevron }
        let base = kept + shows
        // gdu.94: an on-bar key whose slot is not corroborated by a hosted element (or that Control Center lists hidden) keeps its observed
        // slot like an anchor: it is never the subject of a move. Only a key the user placed is reported (once).
        let uncorroborated = observed.uncorroborated.union(observed.staleOnBar).intersection(onBarSet).intersection(Set(base))
        let anchors = Set(base.filter { !capabilities($0).canMove || unhideable.contains($0) || uncorroborated.contains($0) })
        if let placed, !uncorroborated.isEmpty, hides.isEmpty, shows.isEmpty {
            // What the order step would have done had these keys been movable: report each key it would have dragged (once).
            let free = Set(base.filter { !capabilities($0).canMove || unhideable.contains($0) })
            let desiredSet = Set(desired), baseSet = Set(base)
            let movable = layout.visible.filter { placed.contains($0) && desiredSet.contains($0) && baseSet.contains($0) && !free.contains($0) }
            if movable.contains(where: uncorroborated.contains) {
                let t = Self.placedTarget(base: base, placed: movable, anchors: free.subtracting(observed.staleOnBar), visible: layout.visible, eligible: desiredSet.subtracting(observed.staleOnBar))
                let would = Self.moves(from: base, to: t, anchors: Set(base).subtracting(movable), boundary: chevron != nil)
                var seenSubjects = Set<ItemKey>()
                for case .move(let k, _) in would where uncorroborated.contains(k) && seenSubjects.insert(k).inserted {
                    skipped.append(SkippedAction(k, Reconciler.uncorroboratedSkipReason))
                }
            }
        }
        // gdu.89: in user-order mode the planner's "anchors" for the order step are every key that is not a placed, movable one.
        var placedMovable: [ItemKey] = []
        var target: [ItemKey]
        if let placed {
            let baseSet = Set(base)
            let desiredSet = Set(desired)
            placedMovable = layout.visible.filter { placed.contains($0) && desiredSet.contains($0) && baseSet.contains($0) && !anchors.contains($0) }
            target = Self.placedTarget(base: base, placed: placedMovable, anchors: anchors.subtracting(observed.staleOnBar), visible: layout.visible, eligible: desiredSet.subtracting(observed.staleOnBar))
        } else {
            target = Self.layoutTarget(base: base, desired: desired, anchors: anchors)
        }
        // Anchors never move, so the target is reachable only if they appear in the same relative order in the layout
        // as on the bar. Offending anchors are reported; the rest is planned with every anchor in its observed slot.
        let anchorsInBase = base.filter { anchors.contains($0) && !observed.staleOnBar.contains($0) }   // gdu.101: a stale frame proves no order
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
        let blockStart = Self.trailingBlockStart(base: kept, anchors: anchors.subtracting(observed.staleOnBar))   // gdu.101: a stale key does not extend the system block
        if blockStart < kept.count {
            let blockSet = Set(kept[blockStart...])
            // Name the first MODULE of the block in skip messages: a self-positioning item (iStat, an anchor) can sit at its start
            // (gdu.61). The block itself is unchanged, so the `violations` post-condition is unaffected.
            let blockName = kept[blockStart...].first { if case .module = $0 { true } else { false } } ?? kept[blockStart]
            let systemBlock = blockSet.contains { if case .module = $0 { true } else { false } }
            if anchorsOutOfOrder, systemBlock, let first = desired.firstIndex(where: { blockSet.contains($0) }) {
                // Out-of-order anchors keep their slots, so the movable keys the layout puts right of the block land left of
                // it without being "beyond" in `target`: they still get their own skip entry (gdu.44). Only for a block that
                // really holds system items (modules); a trailing run of merely immovable/failed third-party items is not one.
                for k in desired[(first + 1)...] where !anchors.contains(k) && !blockSet.contains(k) {
                    skipped.append(SkippedAction(k, "cannot be placed right of the system items (\(blockName))"))
                }
            }
            let firstBlockInTarget = target.firstIndex { blockSet.contains($0) } ?? target.count
            let limit = min(blockStart, firstBlockInTarget)
            // With shows pending, target slots are displaced by the appended shown keys (a shown key sits in the last slot and the
            // block moves earlier), so "beyond" is judged by the layout's own order: a key is right of the block only if
            // `desired` puts it after the block's first key.
            let beyond: [ItemKey]
            if shows.isEmpty {
                beyond = target.enumerated().filter { $0.offset >= limit && !anchors.contains($0.element) }.map(\.element)
            } else if userOrder {
                beyond = []   // shown keys that nobody placed land where macOS puts them; no layout order is claimed for them
            } else if let first = desired.firstIndex(where: { blockSet.contains($0) }) {
                let inTarget = Set(target)
                beyond = desired[(first + 1)...].filter { !anchors.contains($0) && inTarget.contains($0) }
            } else { beyond = [] }
            if !beyond.isEmpty || !shows.isEmpty {
                for k in beyond where !skipped.contains(where: { $0.key == k && $0.reason.hasPrefix("cannot be placed right of the system items") }) {
                    skipped.append(SkippedAction(k, "cannot be placed right of the system items (\(blockName))"))
                }
                target = target.filter { !blockSet.contains($0) } + kept[blockStart...]
            }
        }

        var actions: [PlannedAction] = hides.map { .hide($0) } + shows.map { .show($0) }
        let phase: PlanPhase
        if !actions.isEmpty {
            phase = .membership
        } else {
            // Non-placed keys are never moved: they act as fixed points of the minimal-move computation (their relative order
            // in `target` is their observed one, so this is always consistent).
            let fixed = userOrder ? Set(base).subtracting(placedMovable) : anchors
            actions = Self.moves(from: base, to: target, anchors: fixed, boundary: chevron != nil, avoid: observed.staleOnBar)
            assert(Self.overflowViolations(actions, forbidden: ovf.union(chevron.map { [$0] } ?? []), boundary: chevron != nil).isEmpty,
                   "planned a move of or into macOS's overflow area")
            assert(Self.violations(actions, target: target, anchors: anchors, blockStart: blockStart).isEmpty,
                   "planned a move of or into the trailing system block")
            phase = actions.isEmpty ? .converged : .order
        }
        return Plan(phase: phase, actions: actions, newItems: newItems, absent: absent, skipped: skipped, desiredOnBar: ovfKept + (chevron.map { [$0] } ?? []) + target)
    }

    /// gdu.101: why a hide of an on-bar key with a stale frame is not planned.
    public static let staleSkipReason = "position not refreshed; waiting for a fresh read"

    /// gdu.94: why a placed key whose bar position is not corroborated is not dragged.
    public static let uncorroboratedSkipReason = "its position on the bar is not corroborated by a hosted element (stale app-side frame or hidden in Control Center); no drag"

    /// Why an item in macOS's own overflow area is not planned (gdu.69).
    public static let overflowSkipReason = "in the system overflow area; macOS decides what fits"

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

    /// gdu.89: the observed order (`base`) with each placed key re-inserted next to its neighbour as `visible` records it.
    /// `placed` is in layout order; `eligible` = keys that may serve as a neighbour (drawn, not overflowed, not the chevron, not
    /// self-positioning). A placed key with a non-placed eligible neighbour anywhere in `visible` goes after its nearest left
    /// neighbour in the sequence, else before the nearest right one. Placed keys whose only neighbours are other placed keys
    /// (the user placed the whole region, or an "adopt"-free full order) have no observed key to hang on: they refill the slots
    /// they vacated in layout order, as the full-order rule always did. A placed key with no eligible neighbour at all goes
    /// leftmost (first in the layout) or rightmost (before the trailing anchor block, which nothing movable may pass).
    static func placedTarget(base: [ItemKey], placed: [ItemKey], anchors: Set<ItemKey>, visible: [ItemKey], eligible: Set<ItemKey>) -> [ItemKey] {
        guard !placed.isEmpty else { return base }
        let baseSet = Set(base)
        let lifted = Set(placed)
        // gdu.101: a Control Center module is never a neighbour to hang on (right of it is the unreachable system block); the search
        // goes outward past modules and self-positioning keys to the nearest ELIGIBLE key on either side.
        let usable = eligible.intersection(baseSet).filter { if case .module = $0 { return false } else { return true } }
        // Partition: hung on an observed (non-placed) key / refilling slots / alone.
        var hung: [ItemKey] = [], refill: [ItemKey] = [], alone: [ItemKey] = []
        for p in placed {
            let others = visible.filter { $0 != p && usable.contains($0) }
            if others.isEmpty { alone.append(p) }
            else if others.contains(where: { !lifted.contains($0) }) { hung.append(p) }
            else { refill.append(p) }
        }
        var fill = refill.makeIterator()
        let refillSet = Set(refill)
        var cur: [ItemKey] = []
        for k in base {
            if refillSet.contains(k) { if let n = fill.next() { cur.append(n) } }
            else if !lifted.contains(k) { cur.append(k) }
        }
        let late = Set(hung + alone)
        for p in placed where late.contains(p) {
            guard let li = visible.firstIndex(of: p) else { continue }
            let inCur = Set(cur)
            let left = visible[..<li].lastIndex(where: { inCur.contains($0) && usable.contains($0) })
            let right = visible[(li + 1)...].first(where: { inCur.contains($0) && usable.contains($0) })
            // gdu.101: a module between the left neighbour and P means P sits right of the module in the layout; prefer the right neighbour.
            let moduleBetween = left.map { visible[$0..<li].contains { if case .module = $0 { true } else { false } } } ?? false
            if let lx = left, !(moduleBetween && right != nil), let i = cur.firstIndex(of: visible[lx]) {
                cur.insert(p, at: i + 1)
            } else if let r = visible[(li + 1)...].first(where: { inCur.contains($0) && usable.contains($0) }), let i = cur.firstIndex(of: r) {
                cur.insert(p, at: i)
            } else if li == 0 {
                cur.insert(p, at: 0)
            } else {
                cur.insert(p, at: trailingBlockStart(base: cur, anchors: anchors))
            }
        }
        return cur
    }

    /// Minimal moves turning `current` into `target` (same key set) with `anchors` never moved.
    /// `avoid`: keys never used as a relation target when another in-place neighbour exists (gdu.101: stale frames).
    static func moves(from current: [ItemKey], to target: [ItemKey], anchors: Set<ItemKey>, boundary: Bool = false, avoid: Set<ItemKey> = []) -> [PlannedAction] {
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
            if let l = left, inPlace.contains(l), !avoid.contains(l) { relation = .after(l) }
            else if let r = right, inPlace.contains(r), !avoid.contains(r) { relation = .before(r) }
            else if let l = left, inPlace.contains(l) { relation = .after(l) }
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
