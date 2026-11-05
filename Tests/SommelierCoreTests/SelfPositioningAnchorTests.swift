import Testing
import Foundation
@testable import SommelierCore

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private func s(_ n: String) -> ItemKey { .status(ownerKey: "com.bjango.istatmenus.status", autosaveName: n) }
private func free(_: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }

struct SelfPositioningAnchorTests {
    @Test func selfPositioningKeyIsNeverMovedAndOrderIsIgnored() {
        // Observed: s1 a s2 b. Layout wants b s2 a s1 (iStat items in the "wrong" slots).
        let o = ObservedOrder(onBar: [s("1"), k("a"), s("2"), k("b")], parked: [])
        let l = Layout(visible: [k("b"), s("2"), k("a"), s("1")], hidden: [], alwaysHidden: [], newItemPolicy: .visibleAtEnd)
        let p = Reconciler().plan(observed: o, layout: l, capabilities: free)
        for a in p.actions {
            guard case .move(let subject, let rel) = a else { continue }
            #expect(!SelfPositioning.isSelfPositioning(subject))
            _ = rel   // a relation TARGET may be an anchor: it stays put, so the drop slot is stable
        }
        #expect(p.actions.contains { if case .move(let x, _) = $0 { return x == k("a") || x == k("b") } else { return false } })
        #expect(p.skipped.isEmpty)
        #expect(p.desiredOnBar.first == s("1")); #expect(p.desiredOnBar[2] == s("2"))
    }
    @Test func onlySelfPositioningOutOfOrderIsConverged() {
        let o = ObservedOrder(onBar: [s("1"), s("2"), k("a")], parked: [])
        let l = Layout(visible: [s("2"), s("1"), k("a")], hidden: [], alwaysHidden: [], newItemPolicy: .visibleAtEnd)
        let p = Reconciler().plan(observed: o, layout: l, capabilities: free)
        #expect(p.phase == .converged); #expect(p.actions.isEmpty); #expect(p.skipped.isEmpty)
    }
    @Test func hidingASelfPositioningItemStillWorks() {
        let o = ObservedOrder(onBar: [k("a"), s("1")], parked: [])
        let l = Layout(visible: [k("a")], hidden: [s("1")], alwaysHidden: [], newItemPolicy: .visibleAtEnd)
        let p = Reconciler().plan(observed: o, layout: l, capabilities: free)
        #expect(p.actions == [.hide(s("1"))])
    }
    @Test func showingAParkedSelfPositioningItemStillWorks() {
        let o = ObservedOrder(onBar: [k("a")], parked: [s("1")])
        let l = Layout(visible: [s("1"), k("a")], hidden: [], alwaysHidden: [], newItemPolicy: .visibleAtEnd)
        let p = Reconciler().plan(observed: o, layout: l, capabilities: free)
        #expect(p.actions == [.show(s("1"))])
    }
    @Test func sharedSetIsTheSingleSource() {
        #expect(LiveActuator.Config().selfPositioningOwners == SelfPositioning.defaultOwners)
        #expect(LayoutEngine.Config().selfPositioningOwners == SelfPositioning.defaultOwners)
        #expect(BarSignature().selfPositioningOwners == SelfPositioning.defaultOwners)
    }
}
