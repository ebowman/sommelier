import Testing
import Foundation
@testable import SommelierCore

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private func m(_ n: String) -> ItemKey { .module(name: n) }
private let wifi = m("WiFi"), bento = m("BentoBox"), clock = m("Clock")
private func caps(_ key: ItemKey) -> Capability {
    if case .module = key { return Capability(canMove: false, canHide: false, reason: "cannot be moved past Control Center/clock") }
    return Capability(canMove: true, canHide: true)
}

struct LayoutDefaultInsertionTests {
    private func base() -> Layout {
        Layout(visible: [k("a"), k("b"), wifi, k("c"), bento, clock])
    }
    @Test func visibleInsertsBeforeTrailingModules() {
        var l = base(); l.move(k("n"), to: .visible)
        #expect(l.visible == [k("a"), k("b"), wifi, k("c"), k("n"), bento, clock])
        #expect(l.visible.firstIndex(of: k("n")) == 4)
    }
    @Test func noModulesAppends() {
        var l = Layout(visible: [k("a"), k("b")]); l.move(k("n"), to: .visible)
        #expect(l.visible == [k("a"), k("b"), k("n")])
    }
    @Test func explicitIndexUnchanged() {
        var l = base(); l.move(k("n"), to: .visible, index: 99)
        #expect(l.visible.last == k("n"))
        l.move(k("n"), to: .visible, index: 0)
        #expect(l.visible.first == k("n"))
    }
    @Test func hiddenAppends() {
        var l = base(); l.hidden = [k("h")]; l.move(k("n"), to: .hidden)
        #expect(l.hidden == [k("h"), k("n")])
    }
    @Test func trailingBlockHelper() {
        #expect(base().trailingSystemBlock() == [bento, clock])
        #expect(Layout(visible: [k("a")]).trailingSystemBlock().isEmpty)
    }
}

struct TrailingSystemBlockPlanTests {
    private func settle(_ o: ObservedOrder, _ layout: Layout) -> (Plan, ObservedOrder) {
        var o = o
        var last = Reconciler().plan(observed: o, layout: layout, capabilities: caps)
        for _ in 0..<5 where !last.actions.isEmpty {
            for a in last.actions { o = PlanSimulator.apply(a, to: o) }
            last = Reconciler().plan(observed: o, layout: layout, capabilities: caps)
        }
        return (last, o)
    }

    @Test func itemAfterClockIsSkippedAndRelocated() {
        let bar: [ItemKey] = [k("d"), k("x"), k("y"), wifi, k("z"), bento, clock]
        let layout = Layout(visible: [k("x"), k("y"), wifi, k("z"), bento, clock, k("d")])
        let p = Reconciler().plan(observed: ObservedOrder(onBar: bar, parked: []), layout: layout, capabilities: caps)
        #expect(p.skipped.contains { $0.key == k("d") && $0.reason.contains("cannot be placed right of the system items") })
        #expect(p.actions.count == 1)
        for a in p.actions {
            guard case .move(let s, let rel) = a else { Issue.record("non-move"); continue }
            #expect(s == k("d"))
            if case .after(let t) = rel { #expect(t != bento && t != clock) }
            if case .rightmost = rel { Issue.record("rightmost") }
        }
        var o = ObservedOrder(onBar: bar, parked: [])
        for a in p.actions { o = PlanSimulator.apply(a, to: o) }
        let i = o.onBar.firstIndex(of: bento)!
        #expect(o.onBar[i - 1] == k("d"))
        #expect(o.onBar.suffix(2) == [bento, clock])
        #expect(p.desiredOnBar == o.onBar)
        #expect(settle(ObservedOrder(onBar: bar, parked: []), layout).0.actions.isEmpty)
    }

    @Test func itemBetweenNonTrailingAnchorsPlansNormally() {
        let bar: [ItemKey] = [k("d"), k("x"), wifi, k("z"), bento, clock]
        let layout = Layout(visible: [k("x"), wifi, k("d"), k("z"), bento, clock])
        let p = Reconciler().plan(observed: ObservedOrder(onBar: bar, parked: []), layout: layout, capabilities: caps)
        #expect(p.skipped.isEmpty)
        #expect(p.actions.count == 1)
        #expect(p.desiredOnBar == layout.visible)
    }

    @Test func movesPostCondition() {
        let base: [ItemKey] = [k("d"), k("e"), k("x"), wifi, bento, clock]
        let target: [ItemKey] = [k("x"), k("e"), k("d"), wifi, bento, clock]
        let anchors: Set<ItemKey> = [wifi, bento, clock]
        let start = Reconciler.trailingBlockStart(base: base, anchors: anchors)
        #expect(start == 3)
        let acts = Reconciler.moves(from: base, to: target, anchors: anchors)
        #expect(!acts.isEmpty)
        #expect(Reconciler.violations(acts, target: target, anchors: anchors, blockStart: start).isEmpty)
        // A target that places a movable inside the block does violate.
        let bad: [ItemKey] = [k("x"), k("e"), wifi, bento, clock, k("d")]
        let badActs = Reconciler.moves(from: base, to: bad, anchors: anchors)
        #expect(!Reconciler.violations(badActs, target: bad, anchors: anchors, blockStart: start).isEmpty)
    }
}
