import Foundation
import Testing
@testable import SommelierCore

// gdu.117: the Arrange window's per-render work moved into the memoized content. Menu enablement is precomputed per row and must
// equal what the drop pipeline decides; a quiet tick must leave everything the view renders from untouched.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private let clock = ItemKey.module(name: "Clock")
private func caps(_ key: ItemKey) -> Capability {
    if case .module = key { return Capability(canMove: false, canHide: false, reason: "system module") }
    if key == k("nohide") { return Capability(canMove: true, canHide: false, reason: "cannot hide") }
    return Capability(canMove: true, canHide: true)
}
private func info(_ key: ItemKey) -> ItemInfo {
    ItemInfo(key: key, title: "", axDescription: "\(key)".split(separator: ":").last.map(String.init) ?? "", ownerPID: 1, ownerBundleID: "com.x",
             ownerName: "Owner", width: 30, isOnBar: true, systemOverflow: false)
}

@Suite struct ArrangeIdleCostTests {
    private let a = k("a"), b = k("b"), c = k("c"), d = k("d"), e = k("e"), nohide = k("nohide"), ghost = k("ghost")

    private func built(filter: String = "", observed: Bool = true) -> (ArrangeContent, Layout, ObservedOrder, Set<ItemKey>) {
        let layout = Layout(visible: [a, b, nohide, ghost, c, clock], hidden: [d], alwaysHidden: [e])
        let bar = observed ? [a, b, nohide, c, clock] : []
        let o = ObservedOrder(onBar: bar, parked: [d, e, ghost])
        let keys = bar + o.parked
        let parked = Set(o.parked)
        let content = ArrangeSections.make(observed: o, layout: layout, items: Dictionary(uniqueKeysWithValues: keys.map { ($0, info($0)) }),
                                           perItem: [:], capabilities: caps,
                                           lastPlan: PlanSummary(plan: Reconciler().plan(observed: o, layout: layout, capabilities: caps), held: []),
                                           filter: filter)
        return (content, layout, o, parked)
    }

    private func allRows(_ c: ArrangeContent) -> [ArrangeRow] {
        [c.visible, c.hidden, c.alwaysHidden].flatMap { $0.rows + $0.notRunning }
    }

    @Test func movableToEqualsTheDropOutcomeForEverySectionOfEveryRow() {
        let (content, layout, o, parked) = built()
        let rows = allRows(content)
        #expect(rows.count >= 6)
        for r in rows where !r.isBoundary {
            for s in LayoutSection.allCases {
                let there = layout.section(of: r.key) == s && !(s == .visible && parked.contains(r.key))
                var want = false
                if !there, case .move = ArrangeDrop.outcome(layout: layout, key: r.key, to: s, index: nil, capabilities: caps,
                                                            observationAvailable: !o.onBar.isEmpty, parked: parked) { want = true }
                #expect(r.movableTo.contains(s) == want, "\(r.key) -> \(s)")
            }
        }
    }

    @Test func movableToMatchesTheViewModelRuleAndAnchorsAndTheFoldLineHaveNone() {
        let (content, layout, o, parked) = built()
        for r in allRows(content) {
            for s in LayoutSection.allCases {
                #expect(r.movableTo.contains(s) == ArrangeDrop.canMove(layout: layout, key: r.key, to: s, capabilities: caps,
                                                                         observationAvailable: !o.onBar.isEmpty, parked: parked) || r.isAnchor)
            }
            if r.isAnchor { #expect(r.movableTo.isEmpty) }
        }
        // an item that cannot be hidden may still move to Visible, never to Hidden
        let nh = content.visible.rows.first { $0.key == nohide }!
        #expect(!nh.movableTo.contains(.hidden) && !nh.movableTo.contains(.alwaysHidden))
        // a parked key listed Visible: Move to Visible is a show request
        let g = content.visible.rows.first { $0.key == ghost }!
        #expect(g.isGhost && g.movableTo.contains(.visible) && g.movableTo.contains(.hidden))
        // listed in Hidden -> may not move to Hidden
        let dRow = content.hidden.rows.first { $0.key == d }!
        #expect(!dRow.movableTo.contains(.hidden) && dRow.movableTo.contains(.visible))
    }

    @Test func withoutAnObservationOnlyOurOwnDataMoves() {
        let (content, _, _, _) = built(observed: false)
        let dRow = content.hidden.rows.first { $0.key == d }!
        #expect(!dRow.movableTo.contains(.visible))
        #expect(dRow.movableTo.contains(.alwaysHidden))
    }

    @Test func stepFlagsEqualTheStepOutcomeOnTheFilteredRows() {
        for filter in ["", "a"] {
            let (content, layout, o, _) = built(filter: filter)
            let rows = content.visible.rows
            for r in rows where !r.isBoundary && !r.isAnchor {
                for dir in [ArrangeDrop.Direction.left, .right] {
                    var want = false
                    if case .move = ArrangeDrop.step(layout: layout, rows: rows, key: r.key, dir, capabilities: caps, observationAvailable: !o.onBar.isEmpty,
                                                     bar: o.onBar, displayName: { "\($0)" }) { want = true }
                    #expect((dir == .left ? r.canStepLeft : r.canStepRight) == want, "\(r.key) \(dir) filter=\(filter)")
                }
            }
        }
        let (content, _, _, _) = built()
        let first = content.visible.rows.first { $0.key == a }!
        #expect(!first.canStepLeft && first.canStepRight)
    }

    @Test func buildingTwiceGivesEqualContent() {
        #expect(built().0 == built().0)
    }

    @Test func aQuietTrackerUpdateLeavesTheRenderStateEqual() {
        var t = ArrangeTracker()
        let o = ObservedOrder(onBar: [a, b], parked: [])
        let layout = Layout(visible: [a, b], hidden: [], alwaysHidden: [])
        t.record([a], passesStarted: 1, now: Date(timeIntervalSince1970: 0), awaitingStamp: false)
        let before = t.renderState
        for i in 1...5 {   // the bookkeeping (`lastUpdate`, and `since` while unsettled) changes; nothing the view draws does
            t.update(observed: o, layout: layout, perItem: [:], passSequence: 1, showHiddenSection: false,
                     now: Date(timeIntervalSince1970: Double(i)), observationSettled: i % 2 == 0)
            #expect(t.renderState == before)
        }
        #expect(t != ArrangeTracker())
    }

    @Test func renderStateChangesWhenWhatTheViewDrawsChanges() {
        var t = ArrangeTracker()
        let empty = t.renderState
        let tk = t.record([a], passesStarted: 1, now: Date(), awaitingStamp: true)
        let waiting = t.renderState
        #expect(waiting != empty)
        t.stamp(ticket: tk, passesStartedAtRevision: 3)
        #expect(t.renderState != waiting)
        t.removeAll()
        #expect(t.renderState == empty)
    }

    @Test func pendingResolveReportsNoChangeWhileNothingResolves() {
        var p = PendingLayout()
        let r0 = p.resolve(stateRevision: 5)
        #expect(!r0)
        p.submit(Layout(visible: [a], hidden: [], alwaysHidden: []))
        let snapshot = p
        let r1 = p.resolve(stateRevision: 5)   // submission has not returned its revision
        #expect(!r1 && p == snapshot)
        p.submitted(revision: 7)
        let r2 = p.resolve(stateRevision: 6)
        #expect(!r2 && p.isActive)
        let r3 = p.resolve(stateRevision: 7)
        #expect(r3 && !p.isActive)
    }
}
