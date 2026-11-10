import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// gdu.19: the pure model behind the Arrange window.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private let clock = ItemKey.module(name: "Clock")
private let cc = ItemKey.module(name: "com.apple.menuextra.controlcenter")
private let chev = ItemKey.module(name: "Show Hidden Menu Bar Items")
private func caps(_ key: ItemKey) -> Capability {
    if case .module = key { return Capability(canMove: false, canHide: false, reason: "system module") }
    if key == k("apple") { return Capability(canMove: true, canHide: false, reason: "Apple apps are hidden only in System Settings.") }
    return Capability(canMove: true, canHide: true)
}
private func info(_ key: ItemKey, ovf: Bool = false, onBar: Bool = true) -> ItemInfo {
    ItemInfo(key: key, title: "", axDescription: "\(key)".split(separator: ":").last.map(String.init) ?? "", ownerPID: 1, ownerBundleID: "com.x",
             ownerName: "Owner", width: 30, isOnBar: onBar, systemOverflow: ovf)
}
private func items(_ keys: [ItemKey]) -> [ItemKey: ItemInfo] { Dictionary(uniqueKeysWithValues: keys.map { ($0, info($0)) }) }
private func make(bar: [ItemKey], parked: [ItemKey] = [], ovf: Set<ItemKey> = [], chevron: ItemKey? = nil, layout: Layout,
                  status: [ItemKey: ItemStatus] = [:], awaiting: Set<ItemKey> = [], filter: String = "", show: Bool = false,
                  extraItems: [ItemKey] = []) -> ArrangeContent {
    ArrangeSections.make(observed: ObservedOrder(onBar: bar, parked: parked, systemOverflow: ovf, overflowChevron: chevron), layout: layout,
                         items: items(bar + parked + extraItems), perItem: status, capabilities: caps, showHiddenSection: show,
                         awaiting: awaiting, filter: filter)
}

// MARK: badge mapping

@Test func badgeMapsEveryItemStatus() {
    func b(_ s: ItemStatus?, running: Bool = true, pending: Bool = false, anchor: Bool = false) -> ArrangeBadge {
        ArrangeSections.badge(status: s, running: running, pendingPlacement: pending, isAnchor: anchor)
    }
    #expect(b(.inPlace) == .inPlace)
    #expect(b(.pending) == .moving)
    #expect(b(.moving) == .moving)
    #expect(b(.failed(.timeout)) == .failed("timed out"))
    #expect(b(.failed(.mechanismFailed("drag did not start"))) == .failed("drag did not start"))
    #expect(b(.unsupported("Apple apps are hidden only in System Settings.")) == .cannotChange("Apple apps are hidden only in System Settings."))
    #expect(b(.notFitting) == .notFitting)
    #expect(b(nil) == .none)
    #expect(b(.inPlace, running: false) == .none)
    // a stale "in place" never beats a requested-but-unseen move
    #expect(b(.inPlace, pending: true) == .moving)
    // failure and overflow outrank the pending-placement ghost
    #expect(b(.failed(.userBusy), pending: true) == .failed("mouse in use; try again"))
    #expect(b(.notFitting, pending: true) == .notFitting)
    // anchors carry no tick
    #expect(b(.inPlace, anchor: true) == .none)
    #expect(ArrangeSections.badge(status: .inPlace, running: true, pendingPlacement: false, isAnchor: false, timedOut: true) == .failed(ArrangeTracker.timeoutText))
    #expect(ArrangeBadge.failed("x").tooltip == "Failed: x")
    #expect(["✓", "⟳", "⚠", "⊘", "⇠"] == [ArrangeBadge.inPlace, .moving, .failed(""), .cannotChange(""), .notFitting].map(\.glyph))
}

// MARK: anchors, boundary, ghosts

@Test func visibleIsTheRecordWithModulesAsAnchorsAndTheFoldLine() {
    let bar = [k("a"), k("b"), chev, k("c"), cc, clock]
    let layout = Layout(visible: [k("a"), k("b"), k("c"), cc, clock])
    let c = make(bar: bar, ovf: [k("a"), k("b")], chevron: chev, layout: layout, status: Dictionary(uniqueKeysWithValues: bar.map { ($0, ItemStatus.inPlace) }).merging([k("a"): .notFitting, k("b"): .notFitting]) { $1 })
    #expect(c.visible.rows.map(\.key) == [k("a"), k("b"), chev, k("c"), cc, clock])
    #expect(c.visible.boundaryIndex == 2)
    #expect(c.visible.rows[0].notFitting && c.visible.rows[0].badge == .behindChevron && c.visible.rows[0].barState == .behindChevron)
    #expect(c.visible.rows[3].badge == .inPlace && c.visible.rows[3].draggable)
    #expect(c.visible.rows[4].isAnchor && !c.visible.rows[4].draggable && c.visible.rows[4].badge == .none)
    #expect(c.visible.rows[4].capabilityNote == "system module")
    #expect(c.visible.rows[5].isAnchor)
}

@Test func visibleIsTheRecordOrderEvenWhileTheBarStillHasTheOldOrder() {
    // the record wants c first; the bar still has a, b, c: ONE row per key, in record order, c moving
    let layout = Layout(visible: [k("c"), k("a"), k("b"), clock])
    let c = make(bar: [k("a"), k("b"), k("c"), clock], layout: layout, status: [k("c"): .pending, k("a"): .inPlace], awaiting: [k("c")])
    #expect(c.visible.rows.map(\.key) == [k("c"), k("a"), k("b"), clock])
    #expect(!c.visible.rows[0].isGhost && c.visible.rows[0].badge == .moving && c.visible.rows[0].barState == .moving)
    // only c is dragged; a and b are kept in place by the planner, so they keep the check (9o9.5)
    #expect(c.visible.rows.filter { $0.barState == .moving }.map(\.key) == [k("c")])
    #expect(c.visible.rows[0].badge != .inPlace)
}

@Test func awaitingKeyWithMatchingObservationShowsNoGhostAndPlacementMatches() {
    let layout = Layout(visible: [k("a"), k("b"), clock])
    let o = ObservedOrder(onBar: [k("a"), k("b"), clock], parked: [])
    #expect(ArrangeSections.placementMatches(k("b"), layout: layout, observed: o))
    let c = make(bar: o.onBar, layout: layout, status: [k("b"): .inPlace], awaiting: [k("b")])
    #expect(c.visible.rows.filter(\.isGhost).isEmpty)
    // (awaiting with a current status: the check, because the bar matches)
    #expect(c.visible.rows[1].badge == .inPlace)
}

@Test func placementMatchesIgnoresOverflowedItemsAndOtherSections() {
    let layout = Layout(visible: [k("o"), chev, k("a"), k("b")], hidden: [k("h")])
    let o = ObservedOrder(onBar: [k("o"), chev, k("b"), k("a")], parked: [k("h")], systemOverflow: [k("o")], overflowChevron: chev)
    #expect(!ArrangeSections.placementMatches(k("a"), layout: layout, observed: o))     // a/b swapped on the bar
    let o2 = ObservedOrder(onBar: [chev, k("a"), k("b")], parked: [k("h")], systemOverflow: [], overflowChevron: chev)
    #expect(ArrangeSections.placementMatches(k("a"), layout: layout, observed: o2))      // overflow item o not on bar: ignored
    #expect(ArrangeSections.placementMatches(k("h"), layout: layout, observed: o2))
    #expect(!ArrangeSections.placementMatches(k("h"), layout: layout, observed: ObservedOrder(onBar: [k("h")], parked: [])))
    #expect(ArrangeSections.placementMatches(k("h"), layout: layout, observed: ObservedOrder(onBar: [k("h")], parked: []), showHiddenSection: true))
}

@Test func hiddenMoveShowsAGhostInHiddenUntilParkedAndLeavesVisible() {
    let layout = Layout(visible: [k("b"), clock], hidden: [k("a")])
    let pendingBar = make(bar: [k("a"), k("b"), clock], layout: layout, status: [k("a"): .pending])
    #expect(pendingBar.visible.rows.map(\.key) == [k("b"), clock])      // Visible is the record: a is not in it
    #expect(pendingBar.hidden.rows.map(\.key) == [k("a")] && pendingBar.hidden.rows[0].isGhost && pendingBar.hidden.rows[0].badge == .moving)
    let done = make(bar: [k("b"), clock], parked: [k("a")], layout: layout, status: [k("a"): .inPlace, k("b"): .inPlace])
    #expect(done.hidden.rows[0].badge == .inPlace && !done.hidden.rows[0].isGhost)
}

@Test func parkedItemWantedVisibleIsAGhostAfterItsLayoutPredecessor() {
    let layout = Layout(visible: [k("a"), k("h"), k("b"), clock])
    let c = make(bar: [k("a"), k("b"), clock], parked: [k("h")], layout: layout, status: [k("h"): .pending])
    #expect(c.visible.rows.map(\.key) == [k("a"), k("h"), k("b"), clock])
    #expect(c.visible.rows[1].isGhost && c.visible.rows[1].badge == .moving)
    // without a predecessor it goes before its successor; unit siblings stay adjacent
    let l2 = Layout(visible: [k("h"), k("h2"), k("a"), clock])
    let c2 = make(bar: [k("a"), clock], parked: [k("h"), k("h2")], layout: l2)
    #expect(c2.visible.rows.map(\.key) == [k("h"), k("h2"), k("a"), clock])
}

@Test func notRunningItemsGoToACollapsedGroupWithNoBadge() {
    let layout = Layout(visible: [k("a"), k("gone"), clock], hidden: [k("gone2")])
    let c = make(bar: [k("a"), clock], layout: layout, status: [k("a"): .inPlace])
    #expect(c.visible.rows.map(\.key) == [k("a"), clock])
    #expect(c.visible.notRunning.map(\.key) == [k("gone")])
    #expect(c.visible.notRunning[0].badge == .none && c.visible.notRunning[0].draggable && c.visible.notRunning[0].notRunning)
    #expect(c.hidden.rows.isEmpty && c.hidden.notRunning.map(\.key) == [k("gone2")])
}

@Test func beforeTheFirstObservationRowsMakeNoClaims() {
    let c = ArrangeSections.make(observed: ObservedOrder(onBar: [], parked: []), layout: Layout(visible: [k("a")], hidden: [k("b")]), items: [:],
                                 perItem: [:], capabilities: caps)
    #expect(!c.observedAvailable)
    #expect((c.visible.rows + c.hidden.rows).allSatisfy { $0.badge == .none })
    #expect(c.visible.notRunning.isEmpty && c.hidden.notRunning.isEmpty)
    #expect(c.visible.rows.isEmpty && c.visiblePlaceholder == "No observation yet — scanning…")
}

@Test func aFailedObservationNeverDrawsTheLayoutAsTheBar() {
    let layout = Layout(visible: [k("a"), clock], hidden: [k("h")])
    let o = ObservedOrder(onBar: [k("a"), clock], parked: [k("h")])      // stale data from before the failure
    let c = ArrangeSections.make(observed: o, layout: layout, items: items([k("a"), clock, k("h")]), perItem: [:], capabilities: caps,
                                 observationProblem: ArrangeSections.observationProblem(lastError: .observe("scans did not agree")))
    #expect(!c.observedAvailable && c.visible.rows.isEmpty && c.visible.notRunning.isEmpty)
    #expect(c.visiblePlaceholder == "No observation yet — scans did not agree")
    #expect(c.hidden.rows.map(\.key) == [k("h")])                          // our data still renders
    #expect(ArrangeSections.observationProblem(lastError: .permissionDenied) != nil)
    #expect(ArrangeSections.observationProblem(lastError: .stoppedAfterFailures(3)) == nil)
}

@Test func withoutObservationDropsThatNeedTheBarAreRefusedButOurOwnDataMoves() {
    let layout = Layout(visible: [k("a"), clock], hidden: [k("h")])
    #expect(ArrangeDrop.outcome(layout: layout, key: k("h"), to: .visible, index: nil, capabilities: caps, observationAvailable: false) == .rejected(ArrangeDrop.noObservation))
    // Visible -> Hidden / Always hidden is a membership request the engine applies once it can read the bar
    for sec in [LayoutSection.hidden, .alwaysHidden] {
        if case .move(let l, _, _) = ArrangeDrop.outcome(layout: layout, key: k("a"), to: sec, index: nil, capabilities: caps, observationAvailable: false) {
            #expect(l.section(of: k("a")) == sec)
        } else { Issue.record("visible -> \(sec) must be accepted without an observation") }
    }
    if case .move = ArrangeDrop.outcome(layout: layout, key: k("h"), to: .alwaysHidden, index: nil, capabilities: caps, observationAvailable: false) {} else { Issue.record("hidden -> always hidden is our own data") }
    // 9o9.5: a reorder inside Visible edits the record; the engine decides when it can act
    let vis = Layout(visible: [k("a"), k("b"), clock])
    if case .move = ArrangeDrop.outcome(layout: vis, key: k("a"), to: .visible, index: 1, capabilities: caps, observationAvailable: false) {} else { Issue.record("Visible reorder needs no observation") }
}

// MARK: capabilities are never fabricated

private struct NoEntry: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: false, reason: "macOS has no Control Center entry for this app yet, so it cannot be hidden.") }
}

@Test func unknownItemInfoMeansAllowedAndKnownUntrackedIsRefusedWithTheRealReason() {
    let layout = Layout(visible: [k("a"), k("b"), clock])
    let rules = NoEntry()
    let known = [k("a"): info(k("a"))]
    let cap: (ItemKey) -> Capability = { ArrangeCapabilities.resolve($0, items: known, rules: rules) }
    // no ItemInfo for b: unknown -> the drop is allowed, the engine decides
    if case .move = ArrangeDrop.outcome(layout: layout, key: k("b"), to: .hidden, index: nil, capabilities: cap) {} else { Issue.record("unknown must be allowed") }
    // a is known and untracked: refused with the real reason
    #expect(ArrangeDrop.outcome(layout: layout, key: k("a"), to: .hidden, index: nil, capabilities: cap)
            == .rejected("macOS has no Control Center entry for this app yet, so it cannot be hidden."))
    // modules stay anchors by kind, with or without ItemInfo
    #expect(!ArrangeCapabilities.resolve(clock, items: [:], rules: CapabilityRules(hasTrackedEntry: { _ in true })).canMove)
    #expect(ArrangeCapabilities.resolve(k("zz"), items: [:], rules: rules) == Capability(canMove: true, canHide: true))
}

// MARK: clamping on both sides

@Test func visibleDropIndexIsClampedAfterLeadingAnchorsAndBeforeTheTrailingBlock() {
    let wifi = ItemKey.module(name: "WiFi")
    let layout = Layout(visible: [wifi, k("a"), k("b"), k("c"), cc, clock])
    let r = rows(layout)
    // slot 0 (left of the leading WiFi anchor) maps to index 1: after it
    #expect(ArrangeDrop.index(layout: layout, rows: r, slot: 0, key: k("c"), section: .visible) == 1)
    #expect(ArrangeDrop.index(layout: layout, rows: r, slot: 1, key: k("c"), section: .visible) == 1)
    // movable index 0 = first movable slot, 99 = before the trailing block
    #expect(ArrangeDrop.index(layout: layout, movableIndex: 0, key: k("c"), section: .visible) == 1)
    #expect(ArrangeDrop.index(layout: layout, movableIndex: 1, key: k("c"), section: .visible) == 2)
    #expect(ArrangeDrop.index(layout: layout, movableIndex: 99, key: k("a"), section: .visible) == nil)
    guard case .move(let l, _, _) = ArrangeDrop.drop(layout: layout, key: k("c"), section: .visible, movableIndex: 0, capabilities: caps) else { Issue.record("no move"); return }
    #expect(l.visible == [wifi, k("c"), k("a"), k("b"), cc, clock])
    guard case .move(let l2, _, _) = ArrangeDrop.drop(layout: layout, key: k("a"), section: .visible, movableIndex: 99, capabilities: caps) else { Issue.record("no move"); return }
    #expect(l2.visible == [wifi, k("b"), k("c"), k("a"), cc, clock])
    // movable indexes skip modules in the middle of the bar
    let mid = Layout(visible: [wifi, k("a"), cc, k("b"), k("c"), clock])
    #expect(ArrangeDrop.index(layout: mid, movableIndex: 1, key: k("c"), section: .visible) == 3)
}


@Test func unitSiblingsAreGroupedWithAHidesTogetherTooltip() {
    let a1 = ItemKey.status(ownerKey: "com.x.app", autosaveName: "one"), a2 = ItemKey.status(ownerKey: "com.x.app", autosaveName: "two")
    let layout = Layout(visible: [a1, a2, clock])
    let c = make(bar: [a1, a2, clock], layout: layout, status: [a1: .inPlace, a2: .inPlace])
    #expect(c.visible.rows[0].unit == c.visible.rows[1].unit)
    #expect(c.visible.rows[0].unitTooltip == "Hides together with two")
    #expect(c.visible.rows[2].unitTooltip == nil)
}

@Test func hideBlockedItemsStayInPlaceButCarryTheCapabilityReason() {
    let layout = Layout(visible: [k("apple"), clock])
    let c = make(bar: [k("apple"), clock], layout: layout, status: [k("apple"): .inPlace])
    #expect(c.visible.rows[0].badge == .inPlace && !c.visible.rows[0].canHide && c.visible.rows[0].draggable)
    #expect(c.visible.rows[0].capabilityNote == "Apple apps are hidden only in System Settings.")
}

// MARK: filtering

@Test func filterMatchesTitleOwnerAndBundleCaseInsensitively() {
    let layout = Layout(visible: [k("Alpha"), k("beta"), clock], hidden: [k("alphaH")], alwaysHidden: [k("zed")])
    let all = make(bar: [k("Alpha"), k("beta"), clock], parked: [k("alphaH"), k("zed")], layout: layout)
    #expect(all.visible.rows.count == 3)
    let f = make(bar: [k("Alpha"), k("beta"), clock], parked: [k("alphaH"), k("zed")], layout: layout, filter: " ALPHA ")
    #expect(f.visible.rows.map(\.key) == [k("Alpha")] && f.hidden.rows.map(\.key) == [k("alphaH")] && f.alwaysHidden.rows.isEmpty)
    #expect(make(bar: [k("Alpha"), clock], layout: Layout(visible: [k("Alpha"), clock]), filter: "owner").visible.rows.count == 2)
    #expect(make(bar: [k("Alpha"), clock], layout: Layout(visible: [k("Alpha"), clock]), filter: "com.x").visible.rows.count == 2)
    #expect(make(bar: [k("Alpha")], layout: Layout(visible: [k("Alpha")]), filter: "nomatch").visible.rows.isEmpty)
}

// MARK: drop arithmetic

private func rows(_ layout: Layout, bar: [ItemKey]? = nil) -> [ArrangeRow] {
    let b = bar ?? layout.visible
    return make(bar: b, layout: layout, status: Dictionary(uniqueKeysWithValues: b.map { ($0, ItemStatus.inPlace) })).visible.rows
}

@Test func droppingOnItsOwnPositionIsANoop() {
    let layout = Layout(visible: [k("a"), k("b"), k("c"), cc, clock])
    let r = rows(layout)
    for slot in [1, 2] {     // before b, before c: both are b's own position
        #expect(ArrangeDrop.drop(layout: layout, rows: r, slot: slot, key: k("b"), section: .visible, capabilities: caps) == .noop)
    }
}

@Test func droppingBetweenCapsulesReorders() {
    let layout = Layout(visible: [k("a"), k("b"), k("c"), cc, clock])
    guard case .move(let l, let moved, let nf) = ArrangeDrop.drop(layout: layout, rows: rows(layout), slot: 0, key: k("c"), section: .visible, capabilities: caps) else { Issue.record("not a move"); return }
    #expect(l.visible == [k("c"), k("a"), k("b"), cc, clock] && moved == [k("c")] && !nf)
    guard case .move(let l2, _, _) = ArrangeDrop.drop(layout: layout, rows: rows(layout), slot: 3, key: k("a"), section: .visible, capabilities: caps) else { Issue.record("not a move"); return }
    #expect(l2.visible == [k("b"), k("c"), k("a"), cc, clock])
}

@Test func droppingIntoOrRightOfTheTrailingSystemBlockIsRefusedAndRightBeforeItIsAllowed() {
    let layout = Layout(visible: [k("a"), k("b"), cc, clock])
    let r = rows(layout)
    guard case .move(let l, _, _) = ArrangeDrop.drop(layout: layout, rows: r, slot: 2, key: k("a"), section: .visible, capabilities: caps) else { Issue.record("slot 2"); return }
    #expect(l.visible == [k("b"), k("a"), cc, clock])
    for slot in [3, 4] {   // between cc and clock, after clock
        #expect(ArrangeDrop.drop(layout: layout, rows: r, slot: slot, key: k("a"), section: .visible, capabilities: caps) == .rejected("macOS keeps the system items at the right end"), "slot \(slot)")
    }
    // the by-index path (env move) still clamps
    guard case .move(let l2, _, _) = ArrangeDrop.drop(layout: layout, key: k("a"), section: .visible, movableIndex: nil, capabilities: caps) else { Issue.record("index"); return }
    #expect(l2.visible == [k("b"), k("a"), cc, clock])
}

@Test func droppingLeftOfTheBoundaryIsAllowedAndFlaggedAsWillNotFit() {
    let bar = [k("o"), chev, k("a"), k("b"), clock]
    let layout = Layout(visible: bar)
    let r = make(bar: bar, ovf: [k("o")], chevron: chev, layout: layout).visible.rows
    guard case .move(let l, _, let nf) = ArrangeDrop.drop(layout: layout, rows: r, slot: 0, key: k("b"), section: .visible, capabilities: caps) else { Issue.record("not a move"); return }
    #expect(l.visible.first == k("b") && nf)
    guard case .move(_, _, let nf2) = ArrangeDrop.drop(layout: layout, rows: r, slot: 4, key: k("a"), section: .visible, capabilities: caps) else { Issue.record("not a move"); return }
    #expect(!nf2)
}

@Test func dropIntoHiddenAppendsOrInsertsAndRespectsCapabilities() {
    let layout = Layout(visible: [k("a"), k("b"), clock], hidden: [k("h1"), k("h2")])
    let hr = make(bar: [k("a"), k("b"), clock], parked: [k("h1"), k("h2")], layout: layout).hidden.rows
    guard case .move(let l, _, _) = ArrangeDrop.drop(layout: layout, rows: hr, slot: 1, key: k("a"), section: .hidden, capabilities: caps) else { Issue.record("not a move"); return }
    #expect(l.hidden == [k("h1"), k("a"), k("h2")] && l.visible == [k("b"), clock])
    guard case .move(let l2, _, _) = ArrangeDrop.drop(layout: layout, rows: hr, slot: 2, key: k("a"), section: .alwaysHidden, capabilities: caps) else { Issue.record("not a move"); return }
    #expect(l2.alwaysHidden == [k("a")])
    // reordering inside Hidden
    guard case .move(let l3, _, _) = ArrangeDrop.drop(layout: layout, rows: hr, slot: 0, key: k("h2"), section: .hidden, capabilities: caps) else { Issue.record("not a move"); return }
    #expect(l3.hidden == [k("h2"), k("h1")])
    #expect(ArrangeDrop.drop(layout: layout, rows: hr, slot: 0, key: k("h1"), section: .hidden, capabilities: caps) == .noop)
    // Apple app cannot be hidden; a module cannot be moved at all
    let l4 = Layout(visible: [k("apple"), clock])
    if case .rejected(let why) = ArrangeDrop.outcome(layout: l4, key: k("apple"), to: .hidden, index: nil, capabilities: caps) { #expect(why.contains("Apple")) } else { Issue.record("expected rejection") }
    if case .rejected = ArrangeDrop.outcome(layout: l4, key: clock, to: .hidden, index: nil, capabilities: caps) {} else { Issue.record("expected rejection") }
    #expect(ArrangeDrop.outcome(layout: l4, key: k("apple"), to: .visible, index: 0, capabilities: caps) == .noop)
}

@Test func hiddenToVisibleAtIndexZeroAndWithoutIndex() {
    let layout = Layout(visible: [k("a"), cc, clock], hidden: [k("h")])
    guard case .move(let l, _, _) = ArrangeDrop.outcome(layout: layout, key: k("h"), to: .visible, index: 0, capabilities: caps) else { Issue.record("not a move"); return }
    #expect(l.visible == [k("h"), k("a"), cc, clock] && l.hidden.isEmpty)
    guard case .move(let l2, _, _) = ArrangeDrop.outcome(layout: layout, key: k("h"), to: .visible, index: nil, capabilities: caps) else { Issue.record("not a move"); return }
    #expect(l2.visible == [k("a"), k("h"), cc, clock])
}

@Test func unitMovesBringSiblingsAndReportThem() {
    let a1 = ItemKey.status(ownerKey: "com.x.app", autosaveName: "one"), a2 = ItemKey.status(ownerKey: "com.x.app", autosaveName: "two")
    let layout = Layout(visible: [k("a"), a1, a2, clock])
    guard case .move(let l, let moved, _) = ArrangeDrop.outcome(layout: layout, key: a1, to: .hidden, index: nil, capabilities: caps) else { Issue.record("not a move"); return }
    #expect(moved == [a1, a2] && l.hidden == [a1, a2] && l.visible == [k("a"), clock])
    // dropping next to a capsule of its own unit is its own position
    let r = rows(layout)
    #expect(ArrangeDrop.drop(layout: layout, rows: r, slot: 2, key: a1, section: .visible, capabilities: caps) == .noop)
    // the awaiting set of a unit move covers the siblings, so both show moving
    let c = make(bar: [k("a"), a1, a2, clock], parked: [], layout: layout, status: [a1: .pending, a2: .pending])
    #expect(c.visible.rows[1].badge == .moving && c.visible.rows[2].badge == .moving)
}

@Test func ghostRowsAreSkippedWhenComputingTheDropIndex() {
    // c is awaiting its move to the front: rows = [ghost c, a, b, real c, clock]. The real c is skipped (its layout slot is the ghost).
    let layout = Layout(visible: [k("c"), k("a"), k("b"), clock])
    let c = make(bar: [k("a"), k("b"), k("c"), clock], layout: layout, awaiting: [k("c")])
    #expect(ArrangeDrop.index(layout: layout, rows: c.visible.rows, slot: 0, key: k("a"), section: .visible) == 0)     // before the ghost
    #expect(ArrangeDrop.index(layout: layout, rows: c.visible.rows, slot: 3, key: k("a"), section: .visible) == 2) // before the real c: next target is the clock, clamped
    #expect(ArrangeDrop.index(layout: layout, rows: c.visible.rows, slot: 5, key: k("a"), section: .visible) == 2) // end: after the clock, clamped to before the trailing block (gdu.101: neighbour-key rule)
}

@Test func stepSkipsAnchorsAndStopsAtTheTrailingBlock() {
    let layout = Layout(visible: [k("a"), cc, k("b"), k("c"), clock])
    let r = rows(layout)
    guard case .move(let l, _, _) = ArrangeDrop.step(layout: layout, rows: r, key: k("b"), .left, capabilities: caps) else { Issue.record("not a move"); return }
    #expect(l.visible == [k("b"), k("a"), cc, k("c"), clock])        // past a (cc anchor skipped by the search, a is the next movable)
    guard case .move(let l2, _, _) = ArrangeDrop.step(layout: layout, rows: r, key: k("b"), .right, capabilities: caps) else { Issue.record("not a move"); return }
    #expect(l2.visible == [k("a"), cc, k("c"), k("b"), clock])
    #expect(ArrangeDrop.step(layout: layout, rows: r, key: k("c"), .right, capabilities: caps) == .noop)  // only clock to the right
    #expect(ArrangeDrop.step(layout: layout, rows: r, key: k("a"), .left, capabilities: caps) == .noop)
    #expect(ArrangeDrop.step(layout: layout, rows: r, key: clock, .left, capabilities: caps) != .noop)   // anchors: capability rejects
}

// MARK: gdu.67 - an order-only drop never crosses a self-positioning row

private let istat67 = ItemKey.status(ownerKey: "com.bjango.istatmenus.status", autosaveName: "cpu")
private let istat67b = ItemKey.status(ownerKey: "com.bjango.istatmenus.status", autosaveName: "mem")
private func caps67(_ key: ItemKey) -> Capability {
    SelfPositioning.isSelfPositioning(key) ? Capability(canMove: false, canHide: true) : caps(key)
}
private func crossName(_ key: ItemKey) -> String { key == istat67 ? "CPU" : "\(key)" }

@Test func aDropThatDoesNotCrossASelfPositioningRowIsAllowed() {
    let bar = [k("a"), k("c"), istat67, k("b"), clock]
    let layout = Layout(visible: bar)
    if case .move(let l, _, _) = ArrangeDrop.outcome(layout: layout, key: k("c"), to: .visible, index: 0, capabilities: caps67, bar: bar) {
        #expect(l.visible == [k("c"), k("a"), istat67, k("b"), clock])
    } else { Issue.record("a move left of istat that stays left of it must be allowed") }
    // hiding across it is a section change: allowed
    if case .move = ArrangeDrop.outcome(layout: layout, key: k("a"), to: .hidden, index: nil, capabilities: caps67, bar: bar) {} else { Issue.record("hide must be allowed") }
    // istat not on the bar at all: no crossing applies
    let noBar = [k("a"), k("b"), clock]
    if case .move = ArrangeDrop.outcome(layout: Layout(visible: [k("a"), istat67, k("b"), clock]), key: k("b"), to: .visible, index: 0, capabilities: caps67, bar: noBar) {} else { Issue.record("istat off the bar") }
}

// gdu.120 (replaces aDropAcrossASelfPositioningRowIsRefusedInBothDirections, twoAdjacentSelfPositioningRowsAreEachRefused,
// stepAcrossASelfPositioningRowIsRefusedAndNotStepable): iStat rows are ordinary, so crossing one is accepted, in both directions,
// by drop and by step, and two adjacent iStat rows impose no restriction either.
@Test func aDropOrStepAcrossAnIStatRowIsAcceptedLikeAnyOtherRow() {
    let bar = [k("a"), istat67, istat67b, k("b"), clock]
    let layout = Layout(visible: bar)
    if case .move(let l, _, _) = ArrangeDrop.outcome(layout: layout, key: k("b"), to: .visible, index: 1, capabilities: caps, bar: bar) {
        #expect(l.visible.firstIndex(of: k("b"))! < l.visible.firstIndex(of: istat67)!)
    } else { Issue.record("left across iStat must be accepted") }
    if case .move(let l, _, _) = ArrangeDrop.outcome(layout: layout, key: k("a"), to: .visible, index: 2, capabilities: caps, bar: bar) {
        #expect(l.visible.firstIndex(of: k("a"))! > l.visible.firstIndex(of: istat67)!)
    } else { Issue.record("right across iStat must be accepted") }
    // the iStat row itself is draggable (capability is the ordinary one) and can be stepped
    if case .move = ArrangeDrop.step(layout: layout, rows: rows(layout), key: istat67, .right, capabilities: caps, bar: bar) {} else { Issue.record("iStat row must be stepable") }
}

@Test func aDropAcrossAModuleAnchorKeepsItsExistingBehaviour() {
    let bar = [k("a"), k("b"), cc, clock]
    let layout = Layout(visible: bar)
    if case .move(let l, _, _) = ArrangeDrop.outcome(layout: layout, key: k("a"), to: .visible, index: 1, capabilities: caps67, bar: bar) {
        #expect(l.visible == [k("b"), k("a"), cc, clock])
    } else { Issue.record("module anchors are not self-positioning rows") }
}

// MARK: toolbar actions

@Test func hideNotFittingHidesTheOverflowedUnitsAndReportsBlockedOnes() {
    let o1 = k("o1"), o2 = k("o2"), ap = k("apple")
    let layout = Layout(visible: [o1, ap, o2, chev, k("a"), clock])
    let obs = ObservedOrder(onBar: layout.visible, parked: [], systemOverflow: [o1, ap, o2], overflowChevron: chev)
    let r = ArrangeDrop.hideNotFitting(layout: layout, observed: obs, capabilities: caps)
    #expect(r.layout.hidden == [o1, o2] && r.moved == [o1, o2] && r.blocked == [ap])
    #expect(r.layout.visible == [ap, chev, k("a"), clock])
    let none = ArrangeDrop.hideNotFitting(layout: layout, observed: ObservedOrder(onBar: layout.visible, parked: []), capabilities: caps)
    #expect(none.layout == layout && none.moved.isEmpty)
}


@Test func anObservationWithoutAnErrorRendersTheCapsulesNotThePlaceholder() {
    // (the status-line half of the former `unsettledObservationIsShownAsObservedButUnsettled` went with `ArrangeSections.statusLine`, sommelier-ejb.7)
    let o = ObservedOrder(onBar: [k("a"), k("b")], parked: [])
    let c = ArrangeSections.make(observed: o, layout: Layout(visible: [k("a"), k("b")]), items: [:], perItem: [:], capabilities: { _ in Capability(canMove: true, canHide: true) },
                                 observationProblem: ArrangeSections.observationProblem(lastError: nil))
    #expect(c.observedAvailable && c.visiblePlaceholder == nil)
}

// MARK: the waiting state machine

private func trackerFixture() -> (Layout, ObservedOrder, ObservedOrder) {
    let layout = Layout(visible: [k("b"), k("a"), clock])
    return (layout, ObservedOrder(onBar: [k("a"), k("b"), clock], parked: []), ObservedOrder(onBar: [k("b"), k("a"), clock], parked: []))
}
private let t0 = Date(timeIntervalSince1970: 1_000)

@Test func checkRequiresAPassAfterTheDropAndAPlacementMatch() {
    let (layout, wrong, right) = trackerFixture()
    var t = ArrangeTracker()
    t.record([k("b")], passesStarted: 5, now: t0)
    // the pass that was in flight at the drop finishes (sequence 5): stale status is suppressed, nothing resolves
    #expect(t.suppressed(passSequence: 5) == [k("b")])
    #expect(t.update(observed: right, layout: layout, perItem: [k("b"): .inPlace], passSequence: 5, showHiddenSection: false, now: t0 + 1).isEmpty)
    #expect(t.awaiting == [k("b")])
    // a later pass says in place but the bar does not match: still waiting (no check from status alone)
    #expect(t.update(observed: wrong, layout: layout, perItem: [k("b"): .inPlace], passSequence: 6, showHiddenSection: false, now: t0 + 2).isEmpty)
    #expect(t.awaiting == [k("b")] && t.suppressed(passSequence: 6).isEmpty)
    // pass after the drop + match: resolved
    let log = t.update(observed: right, layout: layout, perItem: [k("b"): .inPlace], passSequence: 6, showHiddenSection: false, now: t0 + 3)
    #expect(log.count == 1 && t.isEmpty)
}

@Test func aFailureFromBeforeTheDropIsIgnoredAndOneAfterItIsShownWithItsText() {
    let (layout, wrong, _) = trackerFixture()
    var t = ArrangeTracker()
    let stale: [ItemKey: ItemStatus] = [k("b"): .failed(.notVerified(expected: "leftmost", observed: "unchanged"))]
    t.record([k("b")], passesStarted: 3, now: t0)
    t.update(observed: wrong, layout: layout, perItem: stale, passSequence: 3, showHiddenSection: false, now: t0 + 0.1)
    #expect(t.awaiting == [k("b")])
    let c = ArrangeSections.make(observed: wrong, layout: layout, items: items(wrong.onBar), perItem: stale, capabilities: caps,
                                 awaiting: t.awaiting, suppressedStatus: t.suppressed(passSequence: 3))
    #expect(c.visible.rows.first { $0.key == k("b") && !$0.isGhost }?.badge == .moving)    // not the old error
    // the judging pass fails: the wait ends and the badge shows the error
    let log = t.update(observed: wrong, layout: layout, perItem: stale, passSequence: 4, showHiddenSection: false, now: t0 + 9)
    #expect(log.first?.contains("not verified: expected leftmost, saw unchanged") == true && t.isEmpty)
    let c2 = ArrangeSections.make(observed: wrong, layout: layout, items: items(wrong.onBar), perItem: stale, capabilities: caps,
                                  awaiting: t.awaiting, suppressedStatus: t.suppressed(passSequence: 4))
    #expect(c2.visible.rows.first { $0.key == k("b") }?.badge == .cannotPlace("not verified: expected leftmost, saw unchanged"))
}

@Test func unsupportedFromAJudgingPassEndsTheWait() {
    let (layout, wrong, _) = trackerFixture()
    var t = ArrangeTracker()
    t.record([k("b")], passesStarted: 1, now: t0)
    t.update(observed: wrong, layout: layout, perItem: [k("b"): .unsupported("nope")], passSequence: 2, showHiddenSection: false, now: t0 + 1)
    #expect(t.isEmpty)
}

@Test func timeoutFiresAtNinetySecondsAndClearsOnALaterMatch() {
    let (layout, wrong, right) = trackerFixture()
    var t = ArrangeTracker()
    t.record([k("b")], passesStarted: 1, now: t0)
    t.update(observed: wrong, layout: layout, perItem: [k("b"): .inPlace], passSequence: 2, showHiddenSection: false, now: t0 + 89)
    #expect(t.timedOut.isEmpty)
    let log = t.update(observed: wrong, layout: layout, perItem: [k("b"): .inPlace], passSequence: 3, showHiddenSection: false, now: t0 + 91)
    #expect(t.timedOut == [k("b")] && log.count == 1)
    let c = ArrangeSections.make(observed: wrong, layout: layout, items: items(wrong.onBar), perItem: [k("b"): .inPlace], capabilities: caps,
                                 awaiting: t.awaiting, timedOut: t.timedOut)
    #expect(c.visible.rows.first { $0.key == k("b") && !$0.isGhost }?.badge == .cannotPlace(ArrangeTracker.timeoutText))
    t.update(observed: right, layout: layout, perItem: [k("b"): .inPlace], passSequence: 4, showHiddenSection: false, now: t0 + 100)
    #expect(t.isEmpty && t.timedOut.isEmpty)
}

@Test func retryResetsTheSequenceAndTheClock() {
    let (layout, wrong, _) = trackerFixture()
    var t = ArrangeTracker()
    t.record([k("b")], passesStarted: 1, now: t0)
    t.update(observed: wrong, layout: layout, perItem: [k("b"): .inPlace], passSequence: 2, showHiddenSection: false, now: t0 + 95)
    #expect(t.timedOut == [k("b")])
    t.retry(passesStarted: 7, now: t0 + 96)
    #expect(t.timedOut.isEmpty && t.suppressed(passSequence: 7) == [k("b")])
    // a pre-retry failure does not end the retried wait
    t.update(observed: wrong, layout: layout, perItem: [k("b"): .failed(.timeout)], passSequence: 7, showHiddenSection: false, now: t0 + 97)
    #expect(t.awaiting == [k("b")])
    #expect(t.entries[k("b")]?.dropSequence == 7 && t.entries[k("b")]?.since == t0 + 96)
}

@Test func unitSiblingsAreTrackedTogether() {
    let a1 = ItemKey.status(ownerKey: "com.x.app", autosaveName: "one"), a2 = ItemKey.status(ownerKey: "com.x.app", autosaveName: "two")
    let layout = Layout(visible: [a1, a2, clock])
    let wrong = ObservedOrder(onBar: [a2, a1, clock], parked: [])
    var t = ArrangeTracker()
    t.record([a1, a2], passesStarted: 0, now: t0)
    #expect(t.awaiting == [a1, a2] && t.suppressed(passSequence: 0) == [a1, a2])
    t.update(observed: wrong, layout: layout, perItem: [a1: .failed(.timeout), a2: .inPlace], passSequence: 1, showHiddenSection: false, now: t0 + 1)
    #expect(t.awaiting == [a2])      // a1's failure resolved, a2 still waits for its placement
}

@Test func unsettledStateNeverJudgesAndPausesTheClock() {
    let (layout, _, right) = trackerFixture()
    var t = ArrangeTracker()
    t.record([k("b")], passesStarted: 5, now: t0)
    // (a) an unsettled pass after the drop, pre-drop .inPlace and a matching placement: still pending, spinner kept
    #expect(t.update(observed: right, layout: layout, perItem: [k("b"): .inPlace], passSequence: 6, showHiddenSection: false, now: t0 + 1, observationSettled: false).isEmpty)
    #expect(t.awaiting == [k("b")] && t.suppressed(passSequence: 6, observationSettled: false) == [k("b")])
    // (c) a failure from before the drop is never shown, and nothing resolves, however long the unsettled state lasts
    #expect(t.update(observed: right, layout: layout, perItem: [k("b"): .failed(.timeout)], passSequence: 7, showHiddenSection: false, now: t0 + 200, observationSettled: false).isEmpty)
    #expect(t.awaiting == [k("b")] && t.timedOut.isEmpty)
    #expect(t.suppressed(passSequence: 7, observationSettled: false) == [k("b")])
    // (b) settled again with a pass after the drop and a match: resolved; the 200 s unsettled did not run the 90 s clock
    let log = t.update(observed: right, layout: layout, perItem: [k("b"): .inPlace], passSequence: 7, showHiddenSection: false, now: t0 + 201)
    #expect(log.count == 1 && t.isEmpty)
}

// MARK: self-positioning rows (gdu.61)

@Test func orderOnlyDropOfAnIStatRowIsAcceptedLikeAnyOtherAndHideShowToo() {   // gdu.120: was refused as "positions itself"
    let istat = ItemKey.status(ownerKey: "com.bjango.istatmenus.status", autosaveName: "cpu")
    let layout = Layout(visible: [k("a"), istat, k("b")], hidden: [k("h")])
    let free: (ItemKey) -> Capability = { _ in Capability(canMove: true, canHide: true) }
    // order-only inside Visible: accepted, like any ordinary item
    if case .move(let l, _, _) = ArrangeDrop.outcome(layout: layout, key: istat, to: .visible, index: 0, capabilities: free) {
        #expect(l.visible.first == istat)
    } else { Issue.record("an iStat row must be draggable inside Visible") }
    // hide (section change) is accepted
    if case .move(let l, _, _) = ArrangeDrop.outcome(layout: layout, key: istat, to: .hidden, index: nil, capabilities: free) {
        #expect(l.hidden.contains(istat) && !l.visible.contains(istat))
    } else { Issue.record("hiding a self-positioning row must be accepted") }
    // show (hidden -> visible) is accepted
    let parked = Layout(visible: [k("a")], hidden: [istat])
    if case .move(let l, _, _) = ArrangeDrop.outcome(layout: parked, key: istat, to: .visible, index: 0, capabilities: free) {
        #expect(l.visible.contains(istat))
    } else { Issue.record("showing a self-positioning row must be accepted") }
    // a normal row's order drop is accepted
    if case .move(let l, _, _) = ArrangeDrop.outcome(layout: layout, key: k("b"), to: .visible, index: 0, capabilities: free) {
        #expect(l.visible.first == k("b"))
    } else { Issue.record("an ordinary row can be reordered") }
}

// MARK: gdu.101 - stale on-bar items are shown, drops resolve by neighbour key and refuse stale neighbours

private let istat: [ItemKey] = (0..<9).map { .status(ownerKey: "com.bjango.istatmenus.status", autosaveName: "istat\($0)") }

/// The 2026-11-05 13:59 shape: 15 fresh third-party rows + 9 stale iStat rows (interleaved) + 2 modules; the layout lists all of them.
private func incident() -> (layout: Layout, bar: [ItemKey], content: ArrangeContent) {
    let fresh = (0..<15).map { k("f\($0)") }
    var bar: [ItemKey] = []
    for (i, f) in fresh.enumerated() { bar.append(f); if i % 2 == 0, i / 2 < istat.count { bar.append(istat[i / 2]) } }
    bar += istat.suffix(from: min(istat.count, 8)).filter { !bar.contains($0) }
    bar += [cc, clock]
    let layout = Layout(visible: bar)
    let o = ObservedOrder(onBar: bar, parked: [], uncorroborated: Set(istat), staleOnBar: Set(istat))
    let c = ArrangeSections.make(observed: o, layout: layout, items: items(bar), perItem: [:], capabilities: caps)
    return (layout, bar, c)
}

@Test func staleOnBarItemsAreRowsWithStaleBadgeAndStillDraggable() {
    let (_, bar, c) = incident()
    #expect(c.visible.rows.map(\.key) == bar && bar.count == 26)
    let stale = c.visible.rows.filter(\.staleFrame)
    #expect(stale.count == 9 && stale.allSatisfy { $0.draggable && $0.badge == .stale && $0.badge.glyph == "~" && $0.barState == .staleFrame })
    #expect(c.visible.rows.filter { !$0.staleFrame && $0.badge == .stale }.isEmpty)
    #expect(ArrangeBadge.stale.tooltip == "Position being re-read" && stale.allSatisfy { $0.badgeTooltip == "Position being re-read" })
}

@Test func dropNextToAFreshNeighbourLandsNextToThatKey() {
    let (layout, _, c) = incident()
    let rows = c.visible.rows
    // f1 and f2 are adjacent fresh rows (the iStat rows sit after the even ones): the drop lands right after f1 in layout.visible.
    let i = rows.firstIndex { $0.key == k("f1") }!
    guard case .move(let l, _, _) = ArrangeDrop.drop(layout: layout, rows: rows, slot: i + 1, key: k("f9"), section: .visible, capabilities: caps) else { Issue.record("not a move"); return }
    let p = l.visible.firstIndex(of: k("f9"))!
    #expect(l.visible[p - 1] == k("f1") && l.visible[p + 1] == k("f2"))
}

@Test func dropBesideAStaleRowIsAcceptedBecauseTheRecordIsEdited() {
    let (layout, _, c) = incident()
    let rows = c.visible.rows
    let s = rows.firstIndex { $0.key == istat[0] }!
    for slot in [s, s + 1] {   // left of a stale row, right of a stale row
        if case .move = ArrangeDrop.drop(layout: layout, rows: rows, slot: slot, key: k("f9"), section: .visible, capabilities: caps) {} else { Issue.record("drop beside a stale row refused at \(slot)") }
    }
    // Move left/right across a stale capsule is accepted too.
    if case .move = ArrangeDrop.step(layout: layout, rows: rows.map { var r = $0; if r.key == k("f0") { r.staleFrame = true }; return r }, key: k("f1"), .left, capabilities: caps) {}
    else { Issue.record("step across a stale row was refused") }
}

@Test func hiddenStripDropsIgnoreStaleness() {
    let (_, _, c) = incident()
    let layout = Layout(visible: c.visible.rows.map(\.key), hidden: [k("h1"), k("h2")])
    let hr = [k("h1"), k("h2")].map { ArrangeRow(key: $0, title: "", ownerName: "", ownerBundleID: nil, ownerPID: nil, badge: .none, draggable: true, canHide: true, isAnchor: false, isGhost: false, isBoundary: false, notFitting: false, notRunning: false, unit: HideUnitRule.ownerKeys.unit(of: $0), unitMates: [], capabilityNote: nil) }
    guard case .move(let l, _, _) = ArrangeDrop.drop(layout: layout, rows: hr, slot: 1, key: k("f0"), section: .hidden, capabilities: caps) else { Issue.record("not a move"); return }
    #expect(l.hidden == [k("h1"), k("f0"), k("h2")])
}
