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
    @Test func visibleInsertsBeforeTrailingModules()  throws {
        var l = base(); try l.move(k("n"), to: .visible)
        #expect(l.visible == [k("a"), k("b"), wifi, k("c"), k("n"), bento, clock])
        #expect(l.visible.firstIndex(of: k("n")) == 4)
    }
    @Test func noModulesAppends()  throws {
        var l = Layout(visible: [k("a"), k("b")]); try l.move(k("n"), to: .visible)
        #expect(l.visible == [k("a"), k("b"), k("n")])
    }
    @Test func explicitIndexUnchanged()  throws {
        var l = base(); try l.move(k("n"), to: .visible, index: 99)
        #expect(l.visible.last == k("n"))
        try l.move(k("n"), to: .visible, index: 0)
        #expect(l.visible.first == k("n"))
    }
    @Test func hiddenAppends()  throws {
        var l = base(); l.hidden = [k("h")]; try l.move(k("n"), to: .hidden)
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

}
