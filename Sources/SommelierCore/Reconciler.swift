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
    /// 9o9.11: the overflow strip was open in the scan this was built from (the fresh chevron's own read). Nothing is overflowed
    /// then (`systemOverflow` is empty), the chevron is fixed (never subject or target) but moves across it are ordinary.
    public var stripExpanded = false
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
        var expanded = false
        for r in resolved where r.item.frame.width > 1 && (!r.item.stale || r.item.isOnMenuBar) {
            guard seen.insert(r.key).inserted else { continue }
            if r.item.isOnMenuBar {
                if r.item.stale { stale.insert(r.key); uncorr.insert(r.key); if r.item.recentlyVerified { recent.insert(r.key) } }
                bar.append((r.item.frame.minX, r.key))
                if r.item.systemOverflow, !r.item.stale { ovf.insert(r.key) }
                if r.item.isOverflowChevron, !r.item.stale { chevron = chevron ?? r.key; if r.item.stripExpanded { expanded = true } }
                // Hosted-only items (modules, clock) are the agent's own elements: no join to corroborate.
                if (r.item.source == .appExtras && !r.item.joinEvidence.corroborated) || r.item.controlCenterAllowed == false
                    || r.item.hiddenInControlCenter { uncorr.insert(r.key) }
            } else { off.append(r.key); if r.item.placementUnknown { unknown.insert(r.key) } }
        }
        // Stable sort by x (enumerated index breaks ties).
        let ordered = bar.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
        self.init(onBar: ordered.map(\.element.1), parked: off, systemOverflow: ovf, overflowChevron: chevron, placementUnknown: unknown, uncorroborated: uncorr, staleOnBar: stale)
        self.carriedRecently = recent
        self.stripExpanded = expanded && chevron != nil
        if stripExpanded { systemOverflow = [] }   // an open strip draws every item at a real frame
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
                     units rule: HideUnitRule = .ownerKeys, churn: Set<ItemKey> = [], held: Set<ItemKey> = [],
                     unsteady: Set<ItemKey> = []) -> Plan {
        // 9o9.3 / 9o9.9: `Layout.visible` is the ordered record and every Visible key carries the obligation. The order-phase target is
        // the record over ALL keys observed on the bar, trusted or not; only the keys the capabilities pin (the system block, unhideable
        // items) and the held ones are anchors that keep their observed slot. Keys whose frame is not trusted are never a move subject
        // or relation target, but trusted keys are moved so the record holds among them AND relative to the untrusted ones.
        // `unsteady`: untrusted keys whose slot differs from the previous settled observation; no move crosses one this pass.
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
            for k in ovfKept where listed.contains(k) && want.contains(k) && drawnBefore(k, want) != drawnBefore(k, have) {
                skipped.append(SkippedAction(k, churnKeys.contains(k) ? SystemOverflowRule.churnSkipReason : Reconciler.overflowSkipReason))
            }
        }
        // 9o9.11: the record over every on-bar Visible key, overflowed ones included. Keys the layout does not list yet (new items placed
        // by the policy) and revealed hidden-section keys are not in the record: nothing is pulled out or pushed in because of them.
        let visibleRecord = Set(layout.visible)
        let fullRecord = desired.filter { onBarSet.contains($0) && visibleRecord.contains($0) }
        desired = desired.filter { !ovf.contains($0) && $0 != chevron }
        let kept = onBar.filter { !hideSet.contains($0) && !ovf.contains($0) && $0 != chevron }
        let base = kept + shows
        // gdu.94 / 9o9.3: an on-bar key whose frame is not trusted (slot not corroborated by a hosted element, or a stale frame) keeps its
        // observed slot: it is never the subject of a move, never a relation target while a fresh neighbour exists, and it is NOT part of
        // the trailing system block (one such key at the right end must not make every other key "unplaceable right of the system items").
        // 9o9.4: `held` keys (the engine gave up on them) are pinned the same way, silently: they keep their observed slot.
        let unfresh = observed.uncorroborated.union(observed.staleOnBar).union(held).intersection(onBarSet).intersection(Set(base))
        let pinned = Set(base.filter { !capabilities($0).canMove || unhideable.contains($0) })
        let anchors = pinned.union(held.intersection(unfresh))   // 9o9.9: untrusted keys are NOT anchors of the target
        if !unfresh.isEmpty, hides.isEmpty, shows.isEmpty {
            // What the order step would have done had these keys been movable: report each key it would have dragged (once).
            let baseSet = Set(base)
            let full = desired.filter { baseSet.contains($0) }
            if full.contains(where: unfresh.contains) {
                let t = Self.layoutTarget(base: base, desired: full, anchors: pinned)
                let would = Self.moves(from: base, to: t, anchors: pinned, boundary: chevron != nil)
                var seenSubjects = Set<ItemKey>()
                for case .move(let k, _) in would where unfresh.contains(k) && !held.contains(k) && seenSubjects.insert(k).inserted {
                    skipped.append(SkippedAction(k, observed.staleOnBar.contains(k) ? Reconciler.staleFrameSkipReason : Reconciler.uncorroboratedSkipReason))
                }
            }
        }
        let untrusted = unfresh.subtracting(held)   // 9o9.9: stay in the target at their record slot, but are never moved or targeted
        desired = desired.filter { !held.contains($0) }
        var target = Self.layoutTarget(base: base, desired: desired, anchors: anchors)
        // Anchors never move, so the target is reachable only if they appear in the same relative order in the layout
        // as on the bar. Offending anchors are reported; the rest is planned with every anchor in its observed slot.
        let anchorsInBase = base.filter { anchors.contains($0) && !unfresh.contains($0) }   // gdu.101: a stale frame proves no order
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
        let blockStart = Self.trailingBlockStart(base: kept, anchors: anchors.subtracting(unfresh))   // gdu.101 / 9o9.3: an untrusted key does not extend the system block
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
            // Anchors are fixed points of the minimal-move computation. A move whose relation target is a key without a trusted frame
            // (no fresh neighbour was available) is not planned: it is skipped as a stale frame and retried when the frame is fresh.
            let fixed = anchors.union(untrusted)
            let planned = Self.movesReporting(from: base, to: target, anchors: fixed, boundary: chevron != nil, avoid: unfresh, unsteady: unsteady.intersection(untrusted))
            actions = planned.actions
            // 9o9.11: with the drawn order settled, one move across the fold (pull-out or push-in) if the record asks for it.
            var foldKeys = Set<ItemKey>()
            if actions.isEmpty, chevron != nil, !observed.stripExpanded {
                let pile = ovfKept.filter { observed.systemOverflow.contains($0) }
                // The churn rule does not apply to a crossing: the actuator performs it with the strip OPEN after a fresh re-scan (real frames,
                // nothing re-folds until it closes), so churn-zone drawn keys may be the pull-out target or the push-in subject.
                let cannot = observed.uncorroborated.union(observed.staleOnBar).union(held)
                let drawnAll = onBar.filter { !hideSet.contains($0) && !observed.systemOverflow.contains($0) && $0 != chevron && wantOnBar.contains($0) }
                let foldBlockStart = blockStart < kept.count ? (drawnAll.firstIndex(of: kept[blockStart]) ?? drawnAll.count) : drawnAll.count
                let fold = Self.crossFoldMove(record: fullRecord, drawn: drawnAll, pile: pile, excluded: cannot, canMove: { capabilities($0).canMove },
                                              blockStart: foldBlockStart)
                if let f = fold {
                    actions = [f]
                    if case .move(let k, let rel) = f {
                        foldKeys.insert(k)
                        switch rel { case .before(let t), .after(let t): foldKeys.insert(t); default: break }
                    }
                }
                // The order among keys behind the chevron carries no information while the strip is collapsed (their stacked frames
                // are noise): a pile key the record orders differently from the stacked order is never moved, only reported.
                let rec = Dictionary(uniqueKeysWithValues: fullRecord.enumerated().map { ($1, $0) })
                let listedPile = pile.filter { rec[$0] != nil && !held.contains($0) && !churnKeys.contains($0) }
                let keep = Set(Self.lis(listedPile.map { rec[$0]! }))
                for k in listedPile where !keep.contains(rec[k]!) && !foldKeys.contains(k) && !skipped.contains(where: { $0.key == k }) {
                    skipped.append(SkippedAction(k, Reconciler.overflowSkipReason))
                }
                // A pile key the record places right of a drawn key but for which no crossing could be planned (no trusted drawn neighbour)
                // is reported, never silently left.
                if fold == nil {
                    let drawnRec = drawnAll.compactMap { rec[$0] }
                    for k in pile where !skipped.contains(where: { $0.key == k && $0.reason != Reconciler.overflowSkipReason }) {
                        guard let ik = rec[k], drawnRec.contains(where: { $0 < ik }) else { continue }
                        // The gdu.69 wording promises the strip will be opened for this key; here nothing will, so the truer reason replaces it.
                        skipped.removeAll { $0.key == k }
                        skipped.append(SkippedAction(k, Reconciler.noCrossingSkipReason))
                    }
                }
            }
            if !foldKeys.isEmpty { skipped.removeAll { foldKeys.contains($0.key) && $0.reason == Reconciler.overflowSkipReason } }
            // 9o9.9: a trusted subject blocked only by an untrusted wall is already explained by the untrusted key's own skip; not repeated.
            for k in planned.blocked where !skipped.contains(where: { $0.key == k })
                && !(planned.blockedBy[k].map { w in untrusted.contains(w) && skipped.contains { $0.key == w } } ?? false) { skipped.append(SkippedAction(k, Reconciler.staleFrameSkipReason)) }
            for (k, u) in planned.moving where !skipped.contains(where: { $0.key == k }) { skipped.append(SkippedAction(k, Reconciler.movingNeighbourSkipReason(u))) }
            let realPile = observed.systemOverflow.intersection(onBarSet)   // a crossing is judged against macOS's real pile, not the churn zone
            let foldActions = actions.filter { Self.crossesFold($0, overflow: realPile) }
            assert(Self.overflowViolations(actions.filter { !Self.crossesFold($0, overflow: realPile) }, forbidden: ovf.union(chevron.map { [$0] } ?? []),
                                           boundary: chevron != nil && !observed.stripExpanded).isEmpty,
                   "planned a move of or into macOS's overflow area")
            assert(foldActions.allSatisfy { Self.isLegalFoldMove($0, overflow: realPile, chevron: chevron) },
                   "planned a move inside macOS's overflow pile or onto the chevron")
            assert(Self.violations(actions.filter { !Self.crossesFold($0, overflow: realPile) }, target: target, anchors: fixed, blockStart: blockStart).isEmpty,
                   "planned a move of or into the trailing system block")
            phase = actions.isEmpty ? .converged : .order
        }
        return Plan(phase: phase, actions: actions, newItems: newItems, absent: absent, skipped: skipped, desiredOnBar: ovfKept + (chevron.map { [$0] } ?? []) + target)
    }

    /// gdu.101: why a hide of an on-bar key with a stale frame is not planned.
    public static let staleSkipReason = "position not refreshed; waiting for a fresh read"

    /// 9o9.3: why an order move is not planned: its subject, or the neighbour it would be dropped next to, has no trusted frame.
    public static let staleFrameSkipReason = "stale frame; waiting for a fresh read"

    /// 9o9.9: why a trusted key's move is held back: it would cross an untrusted key whose slot changed since the last settled observation.
    public static func movingNeighbourSkipReason(_ untrusted: ItemKey) -> String { "neighbour \(untrusted) is moving" }

    /// 9o9.9: whether a skip reason is the "neighbour … is moving" hold (transient, like a stale frame).
    public static func isMovingNeighbourSkip(_ reason: String) -> Bool { reason.hasPrefix("neighbour ") && reason.hasSuffix(" is moving") }

    /// 9o9.9: untrusted keys among `among` whose slot differs between two observations: the set of other keys left of the key
    /// (restricted to keys present in both) changed. No previous observation: none.
    public static func unsteadyKeys(previous: [ItemKey]?, current: [ItemKey], among: Set<ItemKey>) -> Set<ItemKey> {
        guard let previous else { return [] }
        let common = Set(previous).intersection(current)
        func left(_ bar: [ItemKey], _ k: ItemKey) -> Set<ItemKey>? {
            guard let i = bar.firstIndex(of: k) else { return nil }
            return Set(bar[..<i]).intersection(common)
        }
        return Set(among.filter { k in
            guard let a = left(previous, k), let b = left(current, k) else { return false }
            return a != b
        })
    }

    /// gdu.94: why a placed key whose bar position is not corroborated is not dragged.
    public static let uncorroboratedSkipReason = "its position on the bar is not corroborated by a hosted element (stale app-side frame or hidden in Control Center); no drag"

    /// Why an item in macOS's own overflow area is not planned (gdu.69).
    public static let overflowSkipReason = "behind the « chevron; its order there is set when the strip is next opened"

    /// 9o9.11: why a key behind the chevron that the record places right of a drawn key is not pulled out.
    public static let noCrossingSkipReason = "behind the « chevron; cannot be brought out yet: the item it should follow is not trusted on the bar"

    /// 9o9.11: whether a move crosses the fold: exactly one of its subject and relation target is behind the chevron (in `overflow`).
    /// The actuator opens the « strip for such a move (derived from the observation, never carried on the action).
    public static func crossesFold(_ a: PlannedAction, overflow: Set<ItemKey>) -> Bool {
        guard case .move(let k, let rel) = a else { return false }
        switch rel {
        case .before(let t), .after(let t): return overflow.contains(k) != overflow.contains(t)
        case .leftmost, .rightmost: return false
        }
    }

    /// 9o9.11: a cross-fold move is legal when it is a pull-out (overflowed subject, drawn target) or a push-in (drawn subject,
    /// overflowed target); never between two overflowed keys and never involving the chevron.
    static func isLegalFoldMove(_ a: PlannedAction, overflow: Set<ItemKey>, chevron: ItemKey?) -> Bool {
        guard case .move(let k, let rel) = a else { return false }
        switch rel {
        case .before(let t), .after(let t): return k != chevron && t != chevron && overflow.contains(k) != overflow.contains(t)
        case .leftmost, .rightmost: return false
        }
    }

    /// 9o9.11: the one move across the fold the record asks for, or nil. With a collapsed strip the fold must be a PREFIX of the record:
    /// every key behind the chevron sits left of every drawn key. A violation is a pair (drawn Y, pile X) with the record placing Y
    /// left of X. It is repaired by the smaller side: a push-in `Y .before(X)` (Y trusted and movable, X the record-first pile key right
    /// of Y) or a pull-out `X .after(A)` (X trusted and movable, A the nearest trusted drawn key left of X in the record, not in the
    /// trailing block). `excluded`: untrusted (uncorroborated / stale / held) and churned keys, never subject or target. The order among
    /// pile keys is never touched.
    static func crossFoldMove(record: [ItemKey], drawn: [ItemKey], pile: [ItemKey], excluded: Set<ItemKey>, canMove: (ItemKey) -> Bool,
                              blockStart: Int) -> PlannedAction? {
        let rec = Dictionary(uniqueKeysWithValues: record.enumerated().map { ($1, $0) })
        let pileSet = Set(pile)
        let drawnInRecord = drawn.filter { rec[$0] != nil && !pileSet.contains($0) }
        // Pull-out candidates: trusted pile keys with a drawn key left of them in the record.
        let xs = pile.filter { x in
            guard let ix = rec[x], !excluded.contains(x), canMove(x) else { return false }
            return drawnInRecord.contains { rec[$0]! < ix }
        }.sorted { rec[$0]! < rec[$1]! }
        // Push-in candidates: trusted movable drawn keys with a trusted pile key right of them in the record.
        let targets = pile.filter { rec[$0] != nil && !excluded.contains($0) }
        let ys = drawn.enumerated().filter { (i, y) in
            guard let iy = rec[y], i < blockStart, !excluded.contains(y), canMove(y) else { return false }
            return targets.contains { rec[$0]! > iy }
        }.map(\.element)
        func pullOut() -> PlannedAction? {
            for x in xs {
                let ix = rec[x]!
                let a = drawn.enumerated().filter { (i, d) in
                    guard let id = rec[d], id < ix, i < blockStart, !excluded.contains(d), !pileSet.contains(d) else { return false }
                    return true
                }.max { rec[$0.element]! < rec[$1.element]! }
                if let a { return .move(x, .after(a.element)) }
            }
            return nil
        }
        func pushIn() -> PlannedAction? {
            guard let y = ys.first else { return nil }
            let iy = rec[y]!
            guard let x = targets.filter({ rec[$0]! > iy }).min(by: { rec[$0]! < rec[$1]! }) else { return nil }
            return .move(y, .before(x))
        }
        if !ys.isEmpty, ys.count < xs.count { return pushIn() ?? pullOut() }
        return pullOut() ?? pushIn()
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
    /// `avoid`: keys never used as a relation target when another in-place neighbour exists (gdu.101: stale frames).
    static func moves(from current: [ItemKey], to target: [ItemKey], anchors: Set<ItemKey>, boundary: Bool = false, avoid: Set<ItemKey> = []) -> [PlannedAction] {
        movesReporting(from: current, to: target, anchors: anchors, boundary: boundary, avoid: avoid).actions
    }

    /// `moves`, plus the subjects that could not be spelled against a trusted neighbour (`blocked`) and the ones held back because the
    /// move would cross an `unsteady` untrusted key (`moving`: subject, key).
    /// With `avoid` (untrusted keys) the relation target is a neighbour in `target` that is trusted and already in place, nearest first,
    /// left side before right. The search passes over keys still waiting to be moved (later moves into the same gap are spelled against
    /// the same or a nearer in-place key and land in target order) and over untrusted keys (9o9.9): a trusted subject may cross an
    /// untrusted key when it is spelled against a trusted neighbour on the far side. A candidate is accepted only if, simulated on the
    /// physical bar, it leaves the subject on the target's side of every untrusted and every in-place key. No trusted neighbour at all:
    /// an edge drop (leftmost / rightmost) is used only if the search met no untrusted key; otherwise the subject is blocked. Never
    /// spelled against an untrusted key and never counted as in place.
    static func movesReporting(from current: [ItemKey], to target: [ItemKey], anchors: Set<ItemKey>, boundary: Bool = false,
                               avoid: Set<ItemKey> = [], unsteady: Set<ItemKey> = [])
        -> (actions: [PlannedAction], blocked: [ItemKey], moving: [(ItemKey, ItemKey)], blockedBy: [ItemKey: ItemKey]) {
        guard current != target, current.count == target.count else { return ([], [], [], [:]) }
        var tIndex: [ItemKey: Int] = [:]
        for (i, k) in target.enumerated() { tIndex[k] = i }
        let keep = keptSet(current: current, tIndex: tIndex, anchors: anchors)

        var inPlace = keep
        var out: [PlannedAction] = []
        var blocked: [ItemKey] = []
        var moving: [(ItemKey, ItemKey)] = []
        var blockedBy: [ItemKey: ItemKey] = [:]   // subject -> the untrusted key whose wall blocked it
        var cur = current   // the physical bar as the planned moves so far leave it (only tracked with `avoid`)
        func idx(_ k: ItemKey, in bar: [ItemKey]) -> Int { bar.firstIndex(of: k) ?? Int.max }
        func apply(_ k: ItemKey, _ r: Relation, to bar: [ItemKey]) -> [ItemKey] {
            var b = bar; b.removeAll { $0 == k }
            switch r {
            case .after(let t): if let i = b.firstIndex(of: t) { b.insert(k, at: i + 1) }
            case .before(let t): if let i = b.firstIndex(of: t) { b.insert(k, at: i) }
            case .leftmost: b.insert(k, at: 0)
            case .rightmost: b.append(k)
            }
            return b
        }
        /// `k` ends on the target's side of every untrusted and every in-place key.
        func lands(_ k: ItemKey, _ r: Relation) -> Bool {
            let after = apply(k, r, to: cur)
            for z in avoid.union(inPlace) where z != k {
                if (tIndex[k]! < tIndex[z]!) != (idx(k, in: after) < idx(z, in: after)) { return false }
            }
            return true
        }
        for (i, k) in target.enumerated() where !keep.contains(k) {
            let left = i > 0 ? target[i - 1] : nil
            let right = i + 1 < target.count ? target[i + 1] : nil
            var relation: Relation?
            if avoid.isEmpty {
                if let l = left, inPlace.contains(l) { relation = .after(l) }
                else if let r = right, inPlace.contains(r) { relation = .before(r) }
            } else {
                // Oscillation guard: a move that has to cross an untrusted key whose slot just changed waits for the bar to settle.
                if let u = unsteady.first(where: { (idx(k, in: cur) < idx($0, in: cur)) != (i < tIndex[$0]!) }) { moving.append((k, u)); continue }
                var hitUntrusted = false
                var wall: ItemKey?
                var candidates: [Relation] = []
                var j = i - 1
                while j >= 0 {
                    if avoid.contains(target[j]) { hitUntrusted = true; wall = wall ?? target[j] }
                    else if inPlace.contains(target[j]) { candidates.append(.after(target[j])); break }
                    j -= 1
                }
                j = i + 1
                while j < target.count {
                    if avoid.contains(target[j]) { hitUntrusted = true; wall = wall ?? target[j] }
                    else if inPlace.contains(target[j]) { candidates.append(.before(target[j])); break }
                    j += 1
                }
                relation = candidates.first { lands(k, $0) }
                if relation == nil, !candidates.isEmpty || hitUntrusted { blocked.append(k); if let w = wall { blockedBy[k] = w }; continue }   // no safe trusted in-place spelling
            }
            if relation == nil {
                if i == 0 {
                    // With a chevron, "leftmost" would drop the item left of it (inside the overflow area): drop before the
                    // first other drawn item instead (nothing has been moved yet at index 0).
                    if boundary {
                        guard let f = current.first(where: { $0 != k }) else { inPlace.insert(k); continue }
                        if avoid.contains(f) { blocked.append(k); continue }
                        relation = .before(f)
                    } else { relation = .leftmost }
                }
                else { relation = .rightmost }   // only reachable for the last index; left is always placed before it
            }
            out.append(.move(k, relation!))
            if !avoid.isEmpty { cur = apply(k, relation!, to: cur) }
            inPlace.insert(k)
        }
        return (out, blocked, moving, blockedBy)
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
