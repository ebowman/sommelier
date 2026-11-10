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
    /// gdu.121: parked keys macOS folded for width (a subset of `parked`, which keeps them). macOS hides items that do not fit behind «;
    /// the agent hosts only part of that pile, so a parked, allowed, running item while « is fresh is folded, not hidden by
    /// membership — never a show.
    public var foldedParked: Set<ItemKey> = []
    /// gdu.129: the chevron of THIS scan is carried (stale) but was `recentlyVerified` (gdu.120). Display and fold stability only: the
    /// fold (`foldedParked`) and the « rows hold through it; `overflowChevron` stays nil, so no fold move is planned and no strip opens.
    public var chevronRecent = false
    /// gdu.144 D1: a chevron item is on the bar in this read, FRESH, carried (recent) or STALE with no time limit. Any chevron in any read means
    /// the bar may be full; a stale one counts as a chevron for pile rows and planning (its pile is derived from its last frame).
    public var chevronPresent = false
    /// ejb.13 (A6): stale items that are NOT on the bar, which the filter in `init(resolved:)` drops (a carried-forward parked item is never planned
    /// on). Their position is unread in this scan: `ReadAdapter` sends them to `unread`. Not used by the planner.
    public var staleOff: Set<ItemKey> = []
    /// ejb.13: the key of the first chevron item on the bar in this read, of ANY kind (fresh, carried or stale; `overflowChevron` is the fresh one only).
    /// `ReadAdapter` uses it to keep the chevron out of every list the core sees (A7: the chevron is never a key).
    public var chevronAnyKey: ItemKey?
    /// ejb.13: the keys of EVERY item in the read whose role is the overflow chevron (`isOverflowChevron`), on the bar or not, fresh or stale, even
    /// those the filter drops. `ReadAdapter` keeps all of them out of every list and out of `CoreKeys` (a stale off-bar chevron must never be interned).
    public var chevronKeys: Set<ItemKey> = []
    /// ejb.13 (A6): parked keys whose placement this scan cannot vouch for: `placementUnknown`, plus every parked key Control Center does not
    /// say is hidden (`controlCenterAllowed == nil`, or allowed and not hidden: folded for width, or just not drawn). A superset of `foldedParked`
    /// and `placementUnknown`. Not used by the planner.
    public var parkedUnreadable: Set<ItemKey> = []
    /// gdu.144 D1: a chevron of any kind is in this read.
    public var hasChevron: Bool { overflowChevron != nil || chevronRecent || chevronPresent }
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

    /// gdu.147: this observation as if `key`'s item were absent from the scan (what `EngineFactory.dropSelf` used to produce). Every per-key
    /// flag and list loses the key; the rest is untouched (each other item's pile flag is its own, from the scan).
    public func without(_ key: ItemKey) -> ObservedOrder {
        var o = self
        o.onBar.removeAll { $0 == key }; o.parked.removeAll { $0 == key }
        o.systemOverflow.remove(key); o.placementUnknown.remove(key); o.uncorroborated.remove(key); o.staleOnBar.remove(key)
        o.carriedRecently.remove(key); o.foldedParked.remove(key); o.staleOff.remove(key); o.parkedUnreadable.remove(key)
        return o
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
        var staleOvf = Set<ItemKey>()
        var unknown = Set<ItemKey>()
        var uncorr = Set<ItemKey>()
        var stale = Set<ItemKey>()
        var recent = Set<ItemKey>()
        var chevron: ItemKey?
        var chevronRecentSeen = false
        var staleChevronMinX: CGFloat?
        var chevronAnyKey: ItemKey?
        var expanded = false
        var foldCandidates = Set<ItemKey>()
        var staleOffKeys = Set<ItemKey>()
        var unreadable = Set<ItemKey>()
        var chevronRoleKeys = Set<ItemKey>()
        for r in resolved where r.item.isOverflowChevron { chevronRoleKeys.insert(r.key) }   // ejb.13: by role, wherever the item stands
        for r in resolved where r.item.frame.width > 1 && r.item.stale && !r.item.isOnMenuBar && !r.item.isOverflowChevron { staleOffKeys.insert(r.key) }   // ejb.13
        for r in resolved where r.item.frame.width > 1 && (!r.item.stale || r.item.isOnMenuBar) {
            guard seen.insert(r.key).inserted else { continue }
            if r.item.isOnMenuBar {
                if r.item.stale { stale.insert(r.key); uncorr.insert(r.key); if r.item.recentlyVerified { recent.insert(r.key) } }
                bar.append((r.item.frame.minX, r.key))
                if r.item.systemOverflow { ovf.insert(r.key); if r.item.stale { staleOvf.insert(r.key) } }
                if r.item.isOverflowChevron { chevronAnyKey = chevronAnyKey ?? r.key }
                if r.item.isOverflowChevron, r.item.stale, r.item.recentlyVerified { chevronRecentSeen = true }
                if r.item.isOverflowChevron, r.item.stale { staleChevronMinX = staleChevronMinX ?? r.item.frame.minX }
                if r.item.isOverflowChevron, !r.item.stale { chevron = chevron ?? r.key; if r.item.stripExpanded { expanded = true } }
                // Hosted-only items (modules, clock) are the agent's own elements: no join to corroborate.
                if (r.item.source == .appExtras && !r.item.joinEvidence.corroborated) || r.item.controlCenterAllowed == false
                    || r.item.hiddenInControlCenter { uncorr.insert(r.key) }
            } else {
                off.append(r.key)
                if r.item.isOverflowChevron { /* never unread: the chevron is the boundary (ejb.13) */ }
                else if r.item.placementUnknown || r.item.controlCenterAllowed == nil || (r.item.controlCenterAllowed == true && !r.item.hiddenInControlCenter) { unreadable.insert(r.key) }   // ejb.13
                if r.item.placementUnknown { unknown.insert(r.key) }
                else if r.item.controlCenterAllowed == true, !r.item.hiddenInControlCenter { foldCandidates.insert(r.key) }
            }
        }
        // 9o9.17: a stale item keeps its pile flag (carried frame), but only against a fresh chevron of the read (gdu.45).
        if chevron == nil { ovf.subtract(staleOvf) }
        // gdu.144 D1: a stale chevron (no fresh one in the read) still marks the bar full: whatever stands left of its last frame is folded.
        // Only against a collapsed layout: items drawn left of a chevron would mean an open strip, which needs a fresh chevron.
        if chevron == nil, let cx = staleChevronMinX {
            for (x, key) in bar where x + 1 < cx && key != chevronAnyKey && !(resolved.first { $0.key == key }?.item.isOverflowChevron ?? false) { ovf.insert(key) }
        }
        // Stable sort by x (enumerated index breaks ties).
        let ordered = bar.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
        self.init(onBar: ordered.map(\.element.1), parked: off, systemOverflow: ovf, overflowChevron: chevron, placementUnknown: unknown, uncorroborated: uncorr, staleOnBar: stale)
        self.carriedRecently = recent
        self.chevronAnyKey = chevronAnyKey
        self.chevronKeys = chevronRoleKeys
        self.staleOff = staleOffKeys.subtracting(bar.map(\.1)).subtracting(off)
        self.parkedUnreadable = unreadable
        self.stripExpanded = expanded && chevron != nil
        if stripExpanded { systemOverflow = [] }   // an open strip draws every item at a real frame
        // gdu.121: with a fresh chevron and the strip collapsed, an allowed parked item is folded for width.
        // gdu.129: a carried chevron verified within the recency window keeps the fold (no flicker between « and "not on the bar").
        chevronRecent = chevron == nil && chevronRecentSeen
        chevronPresent = chevronAnyKey != nil
        if chevron != nil || chevronRecent, !stripExpanded { foldedParked = foldCandidates }
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
    /// Hide / show actions only (never a move). Empty iff `phase == .converged`.
    public var actions: [PlannedAction]
    /// Observed keys absent from the layout, with the section the policy assigns. The engine persists these.
    public var newItems: [NewItem]
    /// Layout keys not observed (ignored).
    public var absent: [ItemKey]
    /// Actions suppressed by capabilities.
    public var skipped: [SkippedAction]
}

/// Pure planner: observed snapshot + desired layout -> ordered actions. See docs/architecture.md (Reconciler).
public struct Reconciler: Sendable {
    public init() {}

    /// 9o9.21: true for the overflow chevron, by key or by the observation's flag. Such a key is never a new item.
    static func isChevron(_ k: ItemKey, _ observed: ObservedOrder) -> Bool { k.isOverflowChevron || k == observed.overflowChevron }

    /// Membership planning ONLY (hide / show, new items, skips for membership). Order is decided by `DecisionCore.step` (sommelier-ejb.7): no order
    /// planner lives here. `scripts/check-single-decider.sh` keeps it that way.
    public func plan(observed: ObservedOrder, layout: Layout, capabilities rawCapabilities: (ItemKey) -> Capability,
                     showHiddenSection: Bool = false, showAlwaysHidden: Bool = false,
                     units rule: HideUnitRule = .ownerKeys) -> Plan {
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
        for k in onBar + parked {
            // 9o9.21: the chevron is the agent's own control, never a record key: it is neither a NEW item (no placement, no notice)
            // nor ever hidden or shown by the plan, whatever its unit or the policy says.
            if Self.isChevron(k, observed) { if onBarSet.contains(k) { wantOnBar.insert(k) }; continue }
            // gdu.147: Sommelier's own item is never hidden or shown by the plan: it is always a Visible record key (a new one is recorded
            // in Visible whatever `newItemPolicy` says), so it takes part in the order only.
            if k.isSommelierStatusItem {
                if onBarSet.contains(k) { wantOnBar.insert(k) }
                if layout.section(of: k) == nil { newItems.append(NewItem(k, .visible)) }
                continue
            }
            let wants = unitWantsBar[rule.unit(of: k)] ?? false
            if wants { wantOnBar.insert(k) }
            if layout.section(of: k) == nil {
                newItems.append(NewItem(k, unitJoinSection[rule.unit(of: k)] ?? (wants ? .visible : .hidden)))
            }
        }
        let absent = layout.allKeys.filter { !observedAll.contains($0) }

        // Membership actions. A unit that must hide but has an unhideable item on the bar is not hidden at all.
        var hides: [ItemKey] = [], shows: [ItemKey] = []
        var blocker: [HideUnit: ItemKey] = [:]
        for k in onBar where !wantOnBar.contains(k) && !capabilities(k).canHide {
            if blocker[rule.unit(of: k)] == nil { blocker[rule.unit(of: k)] = k }
        }
        for k in onBar where !wantOnBar.contains(k) {
            if let b = blocker[rule.unit(of: k)] {
                skipped.append(SkippedAction(k, k == b ? (capabilities(k).reason ?? "cannot be hidden")
                                                       : "cannot be hidden: \(b) in the same app cannot be hidden"))
            } else if observed.staleOnBar.contains(k) {
                // gdu.101: never hide on a stale frame alone; the item is on the bar as of the last read.
                skipped.append(SkippedAction(k, Reconciler.staleSkipReason))
            } else {
                hides.append(k)
            }
        }
        for k in parked where wantOnBar.contains(k) {
            // gdu.121: folded for width (behind « while the bar is full): never a show, only reported.
            if observed.foldedParked.contains(k) { skipped.append(SkippedAction(k, Reconciler.foldedParkedSkipReason)) } else { shows.append(k) }
        }

        let actions: [PlannedAction] = hides.map { .hide($0) } + shows.map { .show($0) }
        return Plan(phase: actions.isEmpty ? .converged : .membership, actions: actions, newItems: newItems, absent: absent, skipped: skipped)
    }

    /// gdu.101: why a hide of an on-bar key with a stale frame is not planned.
    public static let staleSkipReason = "position not refreshed; waiting for a fresh read"

    /// gdu.94: why a placed key whose bar position is not corroborated is not dragged.
    public static let uncorroboratedSkipReason = "its position on the bar is not corroborated by a hosted element (stale app-side frame or hidden in Control Center); no drag"

    /// gdu.121: why a parked, allowed key is not shown while the chevron is fresh.
    public static let foldedParkedSkipReason = "behind « (the bar is full; macOS folds it for width)"

    /// Why an item in macOS's own overflow area is not shown or moved by the engine (gdu.69).
    public static let overflowSkipReason = "behind the « chevron; its order there is set when the strip is next opened"
}
