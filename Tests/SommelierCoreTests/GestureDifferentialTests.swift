import Foundation
import Testing
@testable import SommelierCore

/// sommelier-ejb.32: the proved Lean core (`Layout.move` / `hideNotFitting` / `ArrangeDrop.outcome`) against the old pure-Swift implementation (the oracle in GestureOracle.swift) on
/// seeded random layouts: multi-key units (incl. a nine-key unit), modules in the middle and a trailing system block, all three sections, index nil / in range / out of range / negative,
/// keys absent from the layout, split units and (rarely) duplicate keys. Layout AND moved keys must be identical.
private struct LCG {
    var s: UInt64
    mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    mutating func coin(_ pct: Int) -> Bool { below(100) < pct }
    mutating func shuffled<T>(_ a: [T]) -> [T] { var r = a; for i in stride(from: r.count - 1, to: 0, by: -1) { r.swapAt(i, below(i + 1)) }; return r }
}

private func st(_ owner: Int, _ n: Int) -> ItemKey { .status(ownerKey: "com.o\(owner)", autosaveName: "i\(n)") }
/// owners 0 (nine keys), 1 (three), 2 (two), 3...5 (one each)
private let pool: [ItemKey] = (0..<9).map { st(0, $0) } + (0..<3).map { st(1, $0) } + (0..<2).map { st(2, $0) } + (3...5).map { st($0, 0) }
private let mods: [ItemKey] = [.module(name: "Clock"), .module(name: "WiFi"), .module(name: "Battery"), .module(name: "Siri")]
private let outsiders: [ItemKey] = [st(7, 0), st(7, 1), st(8, 0)]

private func randomLayout(_ g: inout LCG) -> Layout {
    var all = pool.filter { _ in g.coin(85) }
    if g.coin(10) { all += outsiders.prefix(1) }   // an item the layout lists in one place only
    all = g.shuffled(all)
    var v: [ItemKey] = [], h: [ItemKey] = [], a: [ItemKey] = []
    let split = g.coin(40)   // units split across sections (a layout normalization would not leave one, but the gesture must still agree)
    var secOfOwner: [String: Int] = [:]
    for k in all {
        let owner = k.hideUnit.id
        let s: Int
        if split { s = g.below(3) } else { if secOfOwner[owner] == nil { secOfOwner[owner] = g.below(3) }; s = secOfOwner[owner]! }
        if s == 0 { v.append(k) } else if s == 1 { h.append(k) } else { a.append(k) }
    }
    // a module in the middle of Visible (an anchor) sometimes, a trailing block of 0...4 modules
    if g.coin(25), !v.isEmpty { v.insert(mods[g.below(mods.count)], at: g.below(v.count + 1)) }
    let ms = g.shuffled(mods)
    v += ms.prefix(g.below(5)).filter { !v.contains($0) }
    if g.coin(3), let d = v.first { h.append(d) }   // a duplicate key (a corrupt file): both implementations must still agree
    return Layout(visible: v, hidden: h, alwaysHidden: a)
}

private func randomIndex(_ g: inout LCG) -> Int? {
    switch g.below(10) {
    case 0..<3: return nil
    case 3..<8: return g.below(10)
    case 8: return 50 + g.below(50)      // out of range
    default: return -1 - g.below(5)      // negative
    }
}

private func caps(_ key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }

@Suite struct GestureDifferentialTests {
    @Test func dropsAgreeWithTheOracle() throws {
        var g = LCG(s: 20261110)
        var n = 0, same = 0, cross = 0, absent = 0, big = 0, none = 0, oor = 0, neg = 0, trailing = 0
        for _ in 0..<6000 {
            let l = randomLayout(&g)
            let section = LayoutSection.allCases[g.below(3)]
            let key: ItemKey = g.coin(8) ? outsiders[g.below(outsiders.count)] : (g.coin(10) ? mods[g.below(mods.count)] : pool[g.below(pool.count)])
            let idx = randomIndex(&g)
            var o = l
            let group = o.oracleMove(key, to: section, index: idx)
            var x = l
            let moved = try x.move(key, to: section, index: idx)
            #expect(x == o, "layout \(l) drop \(key) -> \(section) \(String(describing: idx))\n lean: \(x)\n swift: \(o)")
            #expect(moved == [key], "moved \(moved)")
            #expect(group.first == key)
            // the full UI path: ArrangeDrop.outcome returns the same layout (or noop when nothing changed)
            switch ArrangeDrop.outcome(layout: l, key: key, to: section, index: idx, capabilities: caps) {
            case .move(let nl, let mv, _): #expect(nl == o); #expect(mv == [key])
            case .noop: #expect(o.visible == l.visible && o.hidden == l.hidden && o.alwaysHidden == l.alwaysHidden)
            case .rejected(let why): Issue.record("rejected: \(why)")
            }
            n += 1
            if l.section(of: key) == nil { absent += 1 } else if l.section(of: key) == section { same += 1 } else { cross += 1 }
            if key.hideUnit.id == "com.o0" { big += 1 }
            if idx == nil { none += 1 } else if idx! >= 50 { oor += 1 } else if idx! < 0 { neg += 1 }
            if !l.trailingSystemBlock().isEmpty { trailing += 1 }
        }
        print("gesture differential drops: \(n) (same-section \(same), cross \(cross), absent \(absent), nine-key unit \(big), nil index \(none), out of range \(oor), negative \(neg), trailing block \(trailing))")
        #expect(n >= 5000 && same > 500 && cross > 500 && absent > 100 && big > 500 && none > 500 && oor > 100 && neg > 100 && trailing > 1000)
    }

    @Test func hideNotFittingAgreesWithTheOracle() throws {
        var g = LCG(s: 4711)
        var n = 0, nonEmpty = 0
        for _ in 0..<3000 {
            let l = randomLayout(&g)
            let ks = g.shuffled((pool + mods + outsiders).filter { _ in g.coin(25) })
            var o = l
            let om = o.oracleHideNotFitting(ks)
            var x = l
            let xm = try x.hideNotFitting(ks)
            #expect(x == o, "layout \(l) hide \(ks)")
            #expect(xm == om, "moved lean \(xm) swift \(om)")
            n += 1; if !om.isEmpty { nonEmpty += 1 }
        }
        print("gesture differential hides: \(n), moving something: \(nonEmpty)")
        #expect(n >= 3000 && nonEmpty > 1000)
    }

    /// ArrangeDrop.step / drop (UI row -> index -> Lean) agree with the oracle composed on the same index.
    @Test func hideNotFittingThroughArrangeDropAgreesWithTheOracle() throws {
        var g = LCG(s: 99)
        for _ in 0..<500 {
            let l = randomLayout(&g)
            let over = g.shuffled(l.visible.filter { _ in g.coin(30) })
            let obs = ObservedOrder(onBar: l.visible, parked: [], systemOverflow: Set(over), overflowChevron: nil)
            let r = try ArrangeDrop.hideNotFitting(layout: l, observed: obs, capabilities: caps)
            var o = l
            let om = o.oracleHideNotFitting(l.visible.filter { over.contains($0) && $0 != obs.overflowChevron })
            #expect(r.layout == o)
            #expect(r.moved == om)
        }
    }
}
