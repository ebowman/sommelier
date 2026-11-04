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
    #expect(ArrangeSections.badge(status: .inPlace, running: true, pendingPlacement: false, isAnchor: false, timedOut: true) == .failed("not applied: the menu bar still does not match the layout"))
    #expect(ArrangeBadge.failed("x").tooltip == "Failed: x")
    #expect(["✓", "⟳", "⚠", "⊘", "⇠"] == [ArrangeBadge.inPlace, .moving, .failed(""), .cannotChange(""), .notFitting].map(\.glyph))
}

// MARK: anchors, boundary, ghosts

@Test func visibleMirrorsTheObservedBarWithModulesAsAnchorsAndTheBoundary() {
    let bar = [k("a"), k("b"), chev, k("c"), cc, clock]
    let layout = Layout(visible: bar)
    let c = make(bar: bar, ovf: [k("a"), k("b")], chevron: chev, layout: layout, status: Dictionary(uniqueKeysWithValues: bar.map { ($0, ItemStatus.inPlace) }).merging([k("a"): .notFitting, k("b"): .notFitting]) { $1 })
    #expect(c.visible.rows.map(\.key) == bar)
    #expect(c.visible.boundaryIndex == 2)
    #expect(c.visible.rows[0].notFitting && c.visible.rows[0].badge == .notFitting)
    #expect(c.visible.rows[3].badge == .inPlace && c.visible.rows[3].draggable)
    #expect(c.visible.rows[4].isAnchor && !c.visible.rows[4].draggable && c.visible.rows[4].badge == .none)
    #expect(c.visible.rows[4].capabilityNote == "system module")
    #expect(c.visible.rows[5].isAnchor)
}

@Test func visibleDoesNotReorderOptimisticallyAndShowsAGhostAtTheTargetSlot() {
    // layout wants c first; the bar still has a, b, c.
    let layout = Layout(visible: [k("c"), k("a"), k("b"), clock])
    let c = make(bar: [k("a"), k("b"), k("c"), clock], layout: layout, status: [k("c"): .pending, k("a"): .inPlace], awaiting: [k("c")])
    #expect(c.visible.rows.map(\.key) == [k("c"), k("a"), k("b"), k("c"), clock])
    #expect(c.visible.rows[0].isGhost && c.visible.rows[0].badge == .moving)
    #expect(!c.visible.rows[3].isGhost && c.visible.rows[3].badge == .moving)       // the real capsule is still where the bar has it
    #expect(c.visible.rows[1].badge == .inPlace)
    #expect(c.visible.rows[0].id != c.visible.rows[3].id)
}

@Test func awaitingKeyWithMatchingObservationShowsNoGhostAndPlacementMatches() {
    let layout = Layout(visible: [k("a"), k("b"), clock])
    let o = ObservedOrder(onBar: [k("a"), k("b"), clock], parked: [])
    #expect(ArrangeSections.placementMatches(k("b"), layout: layout, observed: o))
    let c = make(bar: o.onBar, layout: layout, status: [k("b"): .inPlace], awaiting: [k("b")])
    #expect(c.visible.rows.filter(\.isGhost).isEmpty)
    // (awaiting still shows moving until the view model prunes it after a settled pass)
    #expect(c.visible.rows[1].badge == .moving)
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

@Test func hiddenMovePutsARealCapsuleInVisibleAndAGhostInHiddenUntilParked() {
    let layout = Layout(visible: [k("b"), clock], hidden: [k("a")])
    let pendingBar = make(bar: [k("a"), k("b"), clock], layout: layout, status: [k("a"): .pending])
    #expect(pendingBar.visible.rows.map(\.key) == [k("a"), k("b"), clock])
    #expect(pendingBar.visible.rows[0].badge == .moving)
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

@Test func droppingRightOfTheTrailingSystemBlockClampsToBeforeIt() {
    let layout = Layout(visible: [k("a"), k("b"), cc, clock])
    let r = rows(layout)
    for slot in [2, 3, 4] {   // before cc, before clock, after clock
        guard case .move(let l, _, _) = ArrangeDrop.drop(layout: layout, rows: r, slot: slot, key: k("a"), section: .visible, capabilities: caps) else { Issue.record("slot \(slot)"); continue }
        #expect(l.visible == [k("b"), k("a"), cc, clock], "slot \(slot)")
    }
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
    let c = make(bar: [k("a"), a1, a2, clock], parked: [], layout: l, status: [a1: .pending, a2: .pending])
    #expect(c.visible.rows[1].badge == .moving && c.visible.rows[2].badge == .moving)
}

@Test func ghostRowsAreSkippedWhenComputingTheDropIndex() {
    // c is awaiting its move to the front: rows = [ghost c, a, b, real c, clock]. The real c is skipped (its layout slot is the ghost).
    let layout = Layout(visible: [k("c"), k("a"), k("b"), clock])
    let c = make(bar: [k("a"), k("b"), k("c"), clock], layout: layout, awaiting: [k("c")])
    #expect(ArrangeDrop.index(layout: layout, rows: c.visible.rows, slot: 0, key: k("a"), section: .visible) == 0)     // before the ghost
    #expect(ArrangeDrop.index(layout: layout, rows: c.visible.rows, slot: 3, key: k("a"), section: .visible) == 2) // before the real c: next target is the clock, clamped
    #expect(ArrangeDrop.index(layout: layout, rows: c.visible.rows, slot: 5, key: k("a"), section: .visible) == nil) // end -> before the trailing block
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

@Test func adoptRebuildsFromTheObservedBarKeepingAlwaysHiddenAndNotRunning() {
    let current = Layout(visible: [k("b"), k("a"), k("gone"), clock], hidden: [k("h")], alwaysHidden: [k("ah"), k("goneH")], newItemPolicy: .hidden)
    let obs = ObservedOrder(onBar: [k("a"), k("b"), cc, clock], parked: [k("h"), k("ah"), k("new")])
    let l = ArrangeDrop.adopt(observed: obs, current: current)
    #expect(l.visible == [k("a"), k("b"), k("gone"), cc, clock])     // observed verbatim; not-running key before the trailing block
    #expect(l.hidden == [k("h"), k("new")] && l.alwaysHidden == [k("ah"), k("goneH")])
    #expect(l.newItemPolicy == .hidden && l.isValid)
}

@Test func statusLineCountsPendingAndFailures() {
    func s(_ p: [ItemKey: ItemStatus], err: EngineError? = nil, conv: Bool = true, await n: Int = 0) -> String {
        ArrangeSections.statusLine(perItem: p, lastError: err, isConverged: conv, inFlight: false, pendingAwaiting: n)
    }
    #expect(s([k("a"): .inPlace]) == "Converged")
    #expect(s([k("a"): .pending, k("b"): .moving], conv: false) == "2 pending")
    #expect(s([:], conv: false) == "Working…")
    #expect(s([:], await: 1) == "1 pending")
    #expect(s([k("a"): .failed(.timeout)]) == "1 failed")
    #expect(s([:], err: .stoppedAfterFailures(3)) == "Error: stopped after 3 failures")
    #expect(s([k("a"): .pending], err: .observe("boom")) == "Error: boom · 1 pending")
}
