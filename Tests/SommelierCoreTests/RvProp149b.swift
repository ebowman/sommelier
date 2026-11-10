// ported (unchanged apart from this header) from the independent reviewer's gdu.149 suite: ejb.32 runs it through the Lean gesture path.
import Foundation
import Testing
@testable import SommelierCore

@MainActor @Suite struct Rv149PropGhost {
    @Test func ghostsAndParkedVisibleKeys() {
        var g = Rv9RNG(s: 4242); var fails = 0, moves = 0
        for _ in 0..<3000 {
            let (l, chev, ovf) = rv9rand(&g)
            let parkedVis = l.visible.filter { if case .module = $0 { return false }; return Int.random(in: 0...3, using: &g) == 0 }
            let onBar = l.visible.filter { !parkedVis.contains($0) }.shuffled(using: &g).sorted { a, b in
                // keep modules at their record positions roughly: just use a mild shuffle of non-modules
                (l.visible.firstIndex(of: a) ?? 0) < (l.visible.firstIndex(of: b) ?? 0) }
            let c = ArrangeSections.make(observed: ObservedOrder(onBar: onBar, parked: parkedVis + l.hidden + l.alwaysHidden, systemOverflow: ovf, overflowChevron: chev), layout: l,
                                         items: Dictionary(uniqueKeysWithValues: l.allKeys.map { ($0, rv9info($0)) }), perItem: [:], capabilities: rv9cap, showHiddenSection: true,
                                         awaiting: Set(parkedVis.prefix(1)))
            guard let key = l.allKeys.filter({ rv9cap($0).canMove }).randomElement(using: &g) else { continue }
            for target in LayoutSection.allCases {
                let rows = target == .visible ? c.visible.rows : (target == .hidden ? c.hidden.rows : c.alwaysHidden.rows)
                for slot in 0...rows.count {
                    let o = ArrangeDrop.drop(layout: l, rows: rows, slot: slot, key: key, section: target, capabilities: rv9cap, parked: Set(parkedVis))
                    if case .move = o { moves += 1 }
                    if !rv9check(l, o, key: key, "ghost rows \(target) slot \(slot)") { fails += 1 }
                }
                if !rv9check(l, ArrangeDrop.outcome(layout: l, key: key, to: target, index: nil, capabilities: rv9cap, parked: Set(parkedVis)), key: key, "menu") { fails += 1 }
            }
            for d in [ArrangeDrop.Direction.left, .right] where l.visible.contains(key) {
                if !rv9check(l, ArrangeDrop.step(layout: l, rows: c.visible.rows, key: key, d, capabilities: rv9cap), key: key, "step") { fails += 1 }
            }
        }
        print("RV149GHOST moves=\(moves) fails=\(fails)"); #expect(fails == 0)
    }
}
