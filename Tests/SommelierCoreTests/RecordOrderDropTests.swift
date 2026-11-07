import Testing
import Foundation
@testable import SommelierCore

// 9o9.2: Layout.visible is the ordered record; every reorder inside Visible is a legitimate drop (no modes, no placed set).

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private func free(_: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
private func lay(v: [String], h: [String] = []) -> Layout { Layout(visible: v.map(k), hidden: h.map(k)) }
private func rows(_ l: Layout) -> [ArrangeRow] {
    ArrangeSections.make(observed: ObservedOrder(onBar: l.visible, parked: l.hidden), layout: l, items: [:], perItem: [:],
                         capabilities: free).visible.rows
}

struct RecordOrderDropTests {
    @Test func reorderInsideVisibleIsAMove() {
        let l = lay(v: ["A", "B", "C"], h: ["H"])
        guard case .move(let out, let moved, _) = ArrangeDrop.outcome(layout: l, key: k("A"), to: .visible, index: 2, capabilities: free) else { Issue.record("expected move"); return }
        #expect(out.visible == [k("B"), k("C"), k("A")]); #expect(moved == [k("A")])
        guard case .move(let out2, _, _) = ArrangeDrop.outcome(layout: l, key: k("H"), to: .visible, index: 0, capabilities: free) else { Issue.record("expected move"); return }
        #expect(out2.visible.first == k("H"))
        let r = rows(l)
        guard case .move(let out3, _, _) = ArrangeDrop.step(layout: l, rows: r, key: k("A"), .right, capabilities: free) else { Issue.record("expected move"); return }
        #expect(out3.visible == [k("B"), k("A"), k("C")])
        guard case .move(let out4, _, _) = ArrangeDrop.drop(layout: l, rows: r, slot: 3, key: k("A"), section: .visible, capabilities: free) else { Issue.record("expected move"); return }
        #expect(out4.visible == [k("B"), k("C"), k("A")])
    }

    @Test func otherRefusalsStillApply() {
        let l = lay(v: ["A", "B"])
        // a Visible reorder needs no observation (9o9.5); a section change still does
        if case .move = ArrangeDrop.outcome(layout: l, key: k("A"), to: .visible, index: 1, capabilities: free, observationAvailable: false) {} else { Issue.record("reorder refused") }
        if case .move = ArrangeDrop.outcome(layout: l, key: k("A"), to: .hidden, index: nil, capabilities: free, observationAvailable: false) {} else { Issue.record("visible -> hidden refused") }
        let h = Layout(visible: [k("A")], hidden: [k("H")])
        #expect(ArrangeDrop.outcome(layout: h, key: k("H"), to: .visible, index: 0, capabilities: free, observationAvailable: false) == .rejected(ArrangeDrop.noObservation))
        let none = { (_: ItemKey) in Capability(canMove: false, canHide: false, reason: "no way") }
        #expect(ArrangeDrop.outcome(layout: l, key: k("A"), to: .visible, index: 1, capabilities: none) == .rejected("no way"))
    }

    // gdu.110: a key listed Visible but parked (hidden in Control Center): a drop inside Visible is a show request.
    @Test func parkedVisibleKeyDropInsideVisibleIsShowRequest() {
        let l = lay(v: ["A", "B", "C"])
        guard case .move(let same, let moved, _) = ArrangeDrop.outcome(layout: l, key: k("B"), to: .visible, index: 1, capabilities: free, parked: [k("B")]) else { Issue.record("expected move"); return }
        #expect(moved == [k("B")])
        #expect(same.visible == [k("A"), k("B"), k("C")])
        guard case .move(let first, let moved0, _) = ArrangeDrop.outcome(layout: l, key: k("B"), to: .visible, index: 0, capabilities: free, parked: [k("B")]) else { Issue.record("expected move"); return }
        #expect(moved0 == [k("B")])
        #expect(first.visible == [k("B"), k("A"), k("C")])
    }

    @Test func parkedSelfPositioningKeyShowIsAccepted() {
        let istat = ItemKey.status(ownerKey: "com.bjango.istatmenus.status", autosaveName: "cpu")
        #expect(SelfPositioning.isSelfPositioning(istat))
        let l = Layout(visible: [k("A"), istat, k("C")])
        guard case .move(_, let moved, _) = ArrangeDrop.outcome(layout: l, key: istat, to: .visible, index: 0, capabilities: free, parked: [istat]) else { Issue.record("expected move"); return }
        #expect(moved.contains(istat))
        // gdu.120: iStat is no special case; a plain reorder of it is a move too
        guard case .move = ArrangeDrop.outcome(layout: l, key: istat, to: .visible, index: 0, capabilities: free) else { Issue.record("expected move"); return }
    }

    @Test func movableIndexOverloadForwardsParked() {
        let l = lay(v: ["A", "B", "C"])
        guard case .move = ArrangeDrop.drop(layout: l, key: k("B"), section: .visible, movableIndex: 0, capabilities: free, parked: [k("B")]) else { Issue.record("expected move"); return }
        guard case .move = ArrangeDrop.drop(layout: l, key: k("B"), section: .visible, movableIndex: 0, capabilities: free, parked: []) else { Issue.record("expected move"); return }
    }

    @Test func dropOnGhostRowResolves() {
        let l = lay(v: ["A", "B", "C"])
        let sec = ArrangeSections.make(observed: ObservedOrder(onBar: [k("A"), k("C")], parked: [k("B")]), layout: l, items: [:], perItem: [:], capabilities: free)
        let r = sec.visible.rows
        guard let g = r.firstIndex(where: { $0.isGhost && $0.key == k("B") }) else { Issue.record("no ghost row"); return }
        for slot in [g, g + 1] {
            guard case .move = ArrangeDrop.drop(layout: l, rows: r, slot: slot, key: k("B"), section: .visible, capabilities: free, parked: [k("B")]) else {
                Issue.record("expected move at slot \(slot)"); continue
            }
        }
        // a different key dropped on the ghost: no crash, a defined outcome
        _ = ArrangeDrop.drop(layout: l, rows: r, slot: g, key: k("A"), section: .visible, capabilities: free)
    }
}
