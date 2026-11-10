import Testing
import Foundation
@testable import SommelierCore

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private func s(_ n: String) -> ItemKey { .status(ownerKey: "com.bjango.istatmenus.status", autosaveName: n) }
private func free(_: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }

struct SelfPositioningAnchorTests {
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
