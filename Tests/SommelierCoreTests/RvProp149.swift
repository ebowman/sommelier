// ported (unchanged apart from this header) from the independent reviewer's gdu.149 suite: ejb.32 runs it through the Lean gesture path.
import Foundation
import Testing
@testable import SommelierCore

struct Rv9RNG: RandomNumberGenerator { var s: UInt64; mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) } }

func rv9rand(_ g: inout Rv9RNG) -> (Layout, chev: ItemKey?, ovf: Set<ItemKey>) {
    let n = Int.random(in: 4...14, using: &g)
    var keys: [ItemKey] = []
    for i in 0..<n {
        switch Int.random(in: 0...3, using: &g) {
        case 0: keys.append(rv9i("i\(i)"))
        case 1: keys.append(.status(ownerKey: "com.o\(i % 2)", autosaveName: "m\(i)"))
        case 2: keys.append(rv9m("mod\(i)"))
        default: keys.append(rv9k("s\(i)"))
        }
    }
    var vis: [ItemKey] = [], hid: [ItemKey] = [], ah: [ItemKey] = []
    for key in keys {
        if case .module = key { vis.append(key); continue }
        switch Int.random(in: 0...4, using: &g) { case 0: hid.append(key); case 1: ah.append(key); default: vis.append(key) }
    }
    if Bool.random(using: &g) { vis.insert(rv9m("Wi-Fi"), at: 0) }
    vis += [rv9m("com.apple.menuextra.controlcenter"), rv9m("Clock")]
    var chev: ItemKey? = nil; var ovf = Set<ItemKey>()
    if Bool.random(using: &g), vis.count > 4 { let c = rv9m("Show Hidden Menu Bar Items"); let at = Int.random(in: 1..<(vis.count - 2), using: &g); vis.insert(c, at: at); chev = c; ovf = Set(vis[..<at].filter { if case .module = $0 { return false }; return true }) }
    return (Layout(visible: vis, hidden: hid, alwaysHidden: ah), chev, ovf)
}

func rv9check(_ old: Layout, _ out: ArrangeDrop.Outcome, key: ItemKey, _ what: String) -> Bool {
    guard case .move(let n, let moved, _) = out else { return true }
    var ok = moved == [key]
    if old.section(of: key) == n.section(of: key) {
        for s in LayoutSection.allCases {
            if Set(old.keys(in: s)) != Set(n.keys(in: s)) { ok = false }
            if old.keys(in: s).filter({ $0 != key }) != n.keys(in: s).filter({ $0 != key }) { ok = false }
        }
    } else {
        // cross-section: non-unit keys keep relative order everywhere
        for s in LayoutSection.allCases {
            let unitless = { (l: Layout) in l.keys(in: s).filter { HideUnitRule.ownerKeys.unit(of: $0) != HideUnitRule.ownerKeys.unit(of: key) } }
            if unitless(old) != unitless(n) { ok = false }
        }
    }
    if !ok { print("RV149PROP FAIL \(what) key=\(key)\n old=\(old.visible) | \(old.hidden) | \(old.alwaysHidden)\n new=\(n.visible) | \(n.hidden) | \(n.alwaysHidden) moved=\(moved)") }
    return ok
}

@MainActor @Suite struct Rv149Prop {
    @Test func everyGestureMovesOnlyTheGesturedKey() {
        var g = Rv9RNG(s: 149)
        var fails = 0, moves = 0
        for _ in 0..<3000 {
            let (l, chev, ovf) = rv9rand(&g)
            let parked = l.hidden + l.alwaysHidden
            let c = ArrangeSections.make(observed: ObservedOrder(onBar: l.visible, parked: parked, systemOverflow: ovf, overflowChevron: chev), layout: l,
                                         items: Dictionary(uniqueKeysWithValues: l.allKeys.map { ($0, rv9info($0)) }), perItem: [:], capabilities: rv9cap, showHiddenSection: true)
            let movable = l.allKeys.filter { rv9cap($0).canMove }
            guard let key = movable.randomElement(using: &g) else { continue }
            let sec = l.section(of: key)!
            for target in LayoutSection.allCases {
                let rows = target == .visible ? c.visible.rows : (target == .hidden ? c.hidden.rows : c.alwaysHidden.rows)
                for slot in 0...rows.count {
                    let o = ArrangeDrop.drop(layout: l, rows: rows, slot: slot, key: key, section: target, capabilities: rv9cap)
                    if case .move = o { moves += 1 }
                    if !rv9check(l, o, key: key, "rows \(target) slot \(slot) rows=\(rows.map { "\($0.key)\($0.isBoundary ? "|B" : "")\($0.isGhost ? "|G" : "")" })") { fails += 1 }
                }
                if !rv9check(l, ArrangeDrop.outcome(layout: l, key: key, to: target, index: nil, capabilities: rv9cap), key: key, "menu \(target)") { fails += 1 }
                for m in 0..<(l.keys(in: target).count + 1) {
                    if !rv9check(l, ArrangeDrop.drop(layout: l, key: key, section: target, movableIndex: m, capabilities: rv9cap), key: key, "hook \(target) \(m)") { fails += 1 }
                }
            }
            if sec == .visible {
                for d in [ArrangeDrop.Direction.left, .right] {
                    if !rv9check(l, ArrangeDrop.step(layout: l, rows: c.visible.rows, key: key, d, capabilities: rv9cap), key: key, "step \(d)") { fails += 1 }
                }
            }
        }
        print("RV149PROP moves=\(moves) fails=\(fails)")
        #expect(fails == 0)
    }

    @Test func engineSameSectionDropsDragOnlyTheKey() async {
        var g = Rv9RNG(s: 7)
        var bad = 0, total = 0, dragged = 0
        for _ in 0..<60 {
            var (l, _, _) = rv9rand(&g); l.hidden = []; l.alwaysHidden = []
            let c = ArrangeSections.make(observed: ObservedOrder(onBar: l.visible, parked: []), layout: l,
                                         items: Dictionary(uniqueKeysWithValues: l.allKeys.map { ($0, rv9info($0)) }), perItem: [:], capabilities: rv9cap)
            guard let key = l.visible.filter({ rv9cap($0).canMove }).randomElement(using: &g) else { continue }
            let slot = Int.random(in: 0...c.visible.rows.count, using: &g)
            guard case .move(let n, let moved, _) = ArrangeDrop.drop(layout: l, rows: c.visible.rows, slot: slot, key: key, section: .visible, capabilities: rv9cap) else { continue }
            total += 1
            let (e, act, _, clock, _) = await rv9engine(record: l, bar: l.visible)
            _ = await e.setLayout(n, basedOn: nil, moved: Set(moved))
            for _ in 0..<8 { _ = await e.reconcileOnce(); clock.adv(20) }
            let ms = await act.calls.compactMap { if case .move(let k, _) = $0 { k } else { nil } }
            dragged += ms.count
            if ms.contains(where: { $0 != key }) { bad += 1; print("RV149ENG FAIL key=\(key) moves=\(ms) old=\(l.visible) new=\(n.visible)") }
        }
        print("RV149ENG total=\(total) drags=\(dragged) bad=\(bad)")
        #expect(bad == 0)
    }

    @Test func backstopProbe() {
        let A = rv9k("A"), B = rv9k("B"), x = rv9i("x"), y = rv9i("y"), z = rv9i("z")
        // x jumps over sibling y; caller over-reports y
        let old = Layout(visible: [A, x, y, B]), new = Layout(visible: [A, y, B, x])
        print("RV149BS jumped-over sibling named: \(LayoutEngine.effectiveUserMoved(named: [x, y], old: old, new: new))")
        // key not in layout
        print("RV149BS absent key: \(LayoutEngine.effectiveUserMoved(named: [z], old: old, new: new))")
        // unchanged layout keeps everything named (incl absent)
        print("RV149BS unchanged: \(LayoutEngine.effectiveUserMoved(named: [x, y, z], old: old, new: old))")
        // cross section
        let h = Layout(visible: [A, B], hidden: [x, y])
        print("RV149BS cross: \(LayoutEngine.effectiveUserMoved(named: [x, y, A], old: old, new: h))")
    }
}
