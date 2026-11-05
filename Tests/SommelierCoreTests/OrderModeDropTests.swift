import Testing
import Foundation
@testable import SommelierCore

// sommelier-8z5.3: drop rules per order mode.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private func free(_: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
private func lay(_ mode: OrderMode, v: [String], h: [String] = [], placed: [String] = []) -> Layout {
    Layout(visible: v.map(k), hidden: h.map(k), placed: placed.map(k), orderMode: mode)
}
private func rows(_ l: Layout, mode: OrderMode? = nil) -> [ArrangeRow] {
    ArrangeSections.make(observed: ObservedOrder(onBar: l.visible, parked: l.hidden), layout: l, items: [:], perItem: [:],
                         capabilities: free).visible.rows
}

struct OrderModeDropTests {
    @Test func reorderRefusedInMacOSOwns() {
        let l = lay(.macOSOwns, v: ["A", "B", "C"])
        for idx in [0, 1, 2, nil] as [Int?] {
            #expect(ArrangeDrop.outcome(layout: l, key: k("A"), to: .visible, index: idx, capabilities: free) == .rejected(ArrangeDrop.orderFollowsMacOS))
        }
        #expect(ArrangeDrop.orderFollowsMacOS == "Order follows macOS here. Command-drag the item in the menu bar to move it, or turn on \"Let Sommelier keep an order for items I place\".")
        let r = rows(l)
        #expect(ArrangeDrop.drop(layout: l, rows: r, slot: 3, key: k("A"), section: .visible, capabilities: free) == .rejected(ArrangeDrop.orderFollowsMacOS))
        #expect(ArrangeDrop.step(layout: l, rows: r, key: k("A"), .right, capabilities: free) == .rejected(ArrangeDrop.orderFollowsMacOS))
        #expect(ArrangeDrop.step(layout: l, rows: r, key: k("C"), .left, capabilities: free) == .rejected(ArrangeDrop.orderFollowsMacOS))
    }

    @Test func crossSectionDropIntoVisibleKeepsPlacedInMacOSOwns() {
        let l = lay(.macOSOwns, v: ["A", "B"], h: ["H"], placed: ["B"])
        guard case .move(let out, let moved, _) = ArrangeDrop.outcome(layout: l, key: k("H"), to: .visible, index: 0, capabilities: free) else { Issue.record("expected move"); return }
        #expect(moved.contains(k("H")))
        #expect(out.visible.contains(k("H")))
        #expect(out.placed == l.placed)
        // hide out of Visible also fine
        guard case .move(let out2, _, _) = ArrangeDrop.outcome(layout: l, key: k("A"), to: .hidden, index: nil, capabilities: free) else { Issue.record("expected move"); return }
        #expect(out2.hidden.contains(k("A")))
    }

    @Test func placedOnlyIsAsBefore() {
        let l = lay(.placedOnly, v: ["A", "B", "C"], h: ["H"])
        guard case .move(let out, _, _) = ArrangeDrop.outcome(layout: l, key: k("A"), to: .visible, index: 2, capabilities: free) else { Issue.record("expected move"); return }
        #expect(out.visible == [k("B"), k("C"), k("A")]); #expect(out.placed.contains(k("A")))
        guard case .move(let out2, _, _) = ArrangeDrop.outcome(layout: l, key: k("H"), to: .visible, index: 0, capabilities: free) else { Issue.record("expected move"); return }
        #expect(out2.placed.contains(k("H")))
        guard case .move(let out3, _, _) = ArrangeDrop.step(layout: l, rows: rows(l), key: k("A"), .right, capabilities: free) else { Issue.record("expected move"); return }
        #expect(out3.placed.contains(k("A")))
    }

    @Test func unplaceClearsKeyAndMates() {
        let a = ItemKey.status(ownerKey: "com.x.o", autosaveName: "a"), b = ItemKey.status(ownerKey: "com.x.o", autosaveName: "b")
        let c = k("C")
        let l = Layout(visible: [a, b, c], placed: [a, b, c], orderMode: .placedOnly)
        guard case .unplaced(let out, let keys) = ArrangeDrop.unplace(layout: l, key: a) else { Issue.record("expected unplaced"); return }
        #expect(Set(keys) == [a, b])
        #expect(out.placed == [c]); #expect(out.visible == l.visible)
        #expect(ArrangeDrop.unplace(layout: lay(.macOSOwns, v: ["A"]), key: k("A")) == .noop)
        #expect(ArrangeDrop.unplace(layout: out, key: a) == .noop)
    }

    @Test func rowFlagsPerMode() {
        let p = lay(.placedOnly, v: ["A", "B"], placed: ["A"])
        let rp = rows(p)
        #expect(rp[0].isPlaced && !rp[0].placementInert && rp[0].placementNote == "Sommelier keeps this item here")
        #expect(!rp[1].isPlaced && !rp[1].placementInert && rp[1].placementNote == nil)
        let m = lay(.macOSOwns, v: ["A", "B"], placed: ["A"])
        let rm = rows(m)
        #expect(rm[0].isPlaced && rm[0].placementInert && rm[0].placementNote == "Placement remembered, not enforced (order follows macOS)")
        #expect(!rm[1].isPlaced && !rm[1].placementInert && rm[1].placementNote == nil)
    }

    @Test func otherRefusalsWinInMacOSOwns() {
        let l = lay(.macOSOwns, v: ["A", "B"])
        #expect(ArrangeDrop.outcome(layout: l, key: k("A"), to: .visible, index: 1, capabilities: free, observationAvailable: false) == .rejected(ArrangeDrop.noObservation))
        let none = { (_: ItemKey) in Capability(canMove: false, canHide: false, reason: "no way") }
        #expect(ArrangeDrop.outcome(layout: l, key: k("A"), to: .visible, index: 1, capabilities: none) == .rejected("no way"))
    }
}
