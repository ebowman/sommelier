import Testing
import Foundation
import CoreGraphics
@testable import SommelierCore

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private func free(_: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
private let rec = Reconciler()  // Sendable value type

private func obs(_ bar: [String], _ parked: [String] = []) -> ObservedOrder {
    ObservedOrder(onBar: bar.map(k), parked: parked.map(k))
}
private func lay(v: [String] = [], h: [String] = [], a: [String] = [], policy: NewItemPolicy = .visibleAtEnd) -> Layout {
    Layout(visible: v.map(k), hidden: h.map(k), alwaysHidden: a.map(k), newItemPolicy: policy)
}

struct ReconcilerTests {
    @Test func converged() {
        let p = rec.plan(observed: obs(["a", "b"], ["c"]), layout: lay(v: ["a", "b"], h: ["c"]), capabilities: free)
        #expect(p.phase == .converged); #expect(p.actions.isEmpty)
        #expect(p.desiredOnBar == [k("a"), k("b")])
    }
    @Test func oneSwapIsOneMove() {
        let p = rec.plan(observed: obs(["a", "b", "c"]), layout: lay(v: ["b", "a", "c"]), capabilities: free)
        #expect(p.phase == .order); #expect(p.actions.count == 1)
    }
    @Test func hiddenOnBarGetsHide() {
        let p = rec.plan(observed: obs(["a", "b"]), layout: lay(v: ["a"], h: ["b"]), capabilities: free)
        #expect(p.phase == .membership); #expect(p.actions == [.hide(k("b"))])
    }
    @Test func parkedVisibleGetsShow() {
        let p = rec.plan(observed: obs(["a"], ["b"]), layout: lay(v: ["a", "b"]), capabilities: free)
        #expect(p.phase == .membership); #expect(p.actions == [.show(k("b"))])
        #expect(p.desiredOnBar == [k("a"), k("b")])
    }
    @Test func hidesPrecedeShows() {
        let p = rec.plan(observed: obs(["a", "b"], ["c"]), layout: lay(v: ["a", "c"], h: ["b"]), capabilities: free)
        #expect(p.actions == [.hide(k("b")), .show(k("c"))])
    }
    @Test func showHiddenSection() {
        let p = rec.plan(observed: obs(["h", "v", "x"], ["h2"]), layout: lay(v: ["v"], h: ["h", "h2"], a: ["x"]),
                         capabilities: free, showHiddenSection: true)
        #expect(p.phase == .membership)
        #expect(p.actions == [.hide(k("x")), .show(k("h2"))])
        // After applying, order phase puts hidden after visible.
        var o = obs(["h", "v", "x"], ["h2"])
        for a in p.actions { o = PlanSimulator.apply(a, to: o) }
        let p2 = rec.plan(observed: o, layout: lay(v: ["v"], h: ["h", "h2"], a: ["x"]), capabilities: free, showHiddenSection: true)
        #expect(p2.phase == .order)
        #expect(p2.desiredOnBar == [k("v"), k("h"), k("h2")])
    }
    @Test func unknownOnBarVisibleAtEnd() {
        let p = rec.plan(observed: obs(["n2", "a", "n1"]), layout: lay(v: ["a"]), capabilities: free)
        #expect(p.desiredOnBar == [k("a"), k("n2"), k("n1")])
        #expect(p.newItems == [NewItem(k("n2"), .visible), NewItem(k("n1"), .visible)])
        #expect(p.phase == .order)
    }
    @Test func unknownOnBarHiddenPolicy() {
        let p = rec.plan(observed: obs(["a", "n"]), layout: lay(v: ["a"], policy: .hidden), capabilities: free)
        #expect(p.actions == [.hide(k("n"))]); #expect(p.newItems == [NewItem(k("n"), .hidden)])
    }
    @Test func unknownParkedReportedNotShown() {
        let p = rec.plan(observed: obs(["a"], ["n"]), layout: lay(v: ["a"]), capabilities: free)
        #expect(p.phase == .converged); #expect(p.newItems == [NewItem(k("n"), .hidden)])
    }
    @Test func immovableAnchorInMiddle() {
        let anchor = k("m")
        let caps = { (key: ItemKey) in key == anchor ? Capability(canMove: false, canHide: false, reason: "r") : Capability(canMove: true, canHide: true) }
        let layout = lay(v: ["d", "c", "m", "b", "a"])
        var o = obs(["a", "b", "m", "c", "d"])
        var moved: [ItemKey] = []
        for _ in 0..<3 {
            let p = rec.plan(observed: o, layout: layout, capabilities: caps)
            if p.phase == .converged { break }
            for a in p.actions { if case .move(let key, _) = a { moved.append(key) }; o = PlanSimulator.apply(a, to: o) }
        }
        #expect(!moved.contains(anchor))
        #expect(rec.plan(observed: o, layout: layout, capabilities: caps).phase == .converged)
        #expect(o.onBar.firstIndex(of: anchor) == 2)
    }
    /// Regression (gdu.12 live): the agent re-showed two items at the left end, next to immovable modules. The planner
    /// must move those two right, not drag every other item left past the modules.
    @Test func anchorsArePartOfTheTarget() {
        let mods: Set<ItemKey> = [k("wifi"), k("focus"), k("av")]
        let caps = { (key: ItemKey) in mods.contains(key) ? Capability(canMove: false, canHide: false, reason: "module") : Capability(canMove: true, canHide: true) }
        let target = ["wifi", "tm", "focus", "av", "x", "y", "z", "a", "b"]
        let layout = lay(v: target)
        var o = obs(["wifi", "a", "b", "tm", "focus", "av", "x", "y", "z"])
        let p = rec.plan(observed: o, layout: layout, capabilities: caps)
        #expect(p.phase == .order)
        #expect(p.actions.count == 2)
        #expect(p.skipped.isEmpty)
        #expect(p.desiredOnBar == target.map(k))
        for a in p.actions { o = PlanSimulator.apply(a, to: o) }
        #expect(o.onBar == target.map(k))
        #expect(rec.plan(observed: o, layout: layout, capabilities: caps).phase == .converged)
    }

    @Test func anchorsInWrongRelativeOrderAreReportedAndRestConverges() {
        let mods: Set<ItemKey> = [k("m1"), k("m2")]
        let caps = { (key: ItemKey) in mods.contains(key) ? Capability(canMove: false, canHide: false, reason: "module") : Capability(canMove: true, canHide: true) }
        // Layout wants m2 before m1; the bar has m1 before m2 and cannot be changed.
        let layout = lay(v: ["c", "m2", "a", "m1", "b"])
        var o = obs(["a", "m1", "b", "m2", "c"])
        let p = rec.plan(observed: o, layout: layout, capabilities: caps)
        #expect(!p.skipped.isEmpty)
        #expect(p.skipped.allSatisfy { $0.reason == "immovable item is out of layout order" && mods.contains($0.key) })
        for _ in 0..<3 {
            let q = rec.plan(observed: o, layout: layout, capabilities: caps)
            for a in q.actions { if case .move(let key, _) = a { #expect(!mods.contains(key)) }; o = PlanSimulator.apply(a, to: o) }
        }
        #expect(rec.plan(observed: o, layout: layout, capabilities: caps).phase == .converged)
        #expect(o.onBar.firstIndex(of: k("m1"))! < o.onBar.firstIndex(of: k("m2"))!)
        // Movables keep their desired relative order: c, a, b.
        #expect(o.onBar.filter { !mods.contains($0) } == ["c", "a", "b"].map(k))
    }

    @Test func unhideableHiddenIsSkippedAndAnchored() {
        let u = k("u")
        let caps = { (key: ItemKey) in key == u ? Capability(canMove: true, canHide: false, reason: "no entry") : Capability(canMove: true, canHide: true) }
        let layout = lay(v: ["b", "a"], h: ["u"])
        let p = rec.plan(observed: obs(["a", "u", "b"]), layout: layout, capabilities: caps)
        #expect(p.skipped == [SkippedAction(u, "no entry")])
        #expect(p.phase == .order)
        #expect(!p.actions.contains { if case .move(u, _) = $0 { true } else { false } })
        #expect(p.desiredOnBar == [k("b"), u, k("a")])
    }
    @Test func absentReportedAndIgnored() {
        let p = rec.plan(observed: obs(["a"]), layout: lay(v: ["a", "gone"], a: ["gone2"]), capabilities: free)
        #expect(p.phase == .converged); #expect(p.absent == [k("gone"), k("gone2")])
    }
    @Test func duplicatesKeepFirst() {
        let p = rec.plan(observed: obs(["a", "b", "a"]), layout: lay(v: ["a", "b"]), capabilities: free)
        #expect(p.phase == .converged)
    }
    @Test func staleExcluded() {
        func r(_ n: String, x: CGFloat, stale: Bool = false, onBar: Bool = true, w: CGFloat = 24) -> ResolvedItem {
            ResolvedItem(item: MenuBarItem(ownerPID: 1, ownerBundleID: "com.x", ownerName: "X", title: n, axDescription: "",
                                           axIdentifier: "", frame: CGRect(x: x, y: 3, width: w, height: 24),
                                           source: .appExtras, isOnMenuBar: onBar, stale: stale), key: k(n), confidence: .exact)
        }
        let o = ObservedOrder(resolved: [r("b", x: 50), r("a", x: 10), r("s", x: 20, stale: true), r("p", x: 0, onBar: false),
                                         r("w", x: 0, onBar: false, w: 0)])
        #expect(o == obs(["a", "b"], ["p"]))
    }
}

// MARK: Randomized convergence

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Independent bound: N - (max chain through all anchors, by target index), O(n^2) DP with anchor weight 1000.
private func bound(current: [ItemKey], target: [ItemKey], anchors: Set<ItemKey>) -> Int {
    let t = Dictionary(uniqueKeysWithValues: target.enumerated().map { ($1, $0) })
    let n = current.count
    var best = [Int](repeating: 0, count: n)
    for i in 0..<n {
        let w = anchors.contains(current[i]) ? 1000 : 1
        best[i] = w
        for j in 0..<i where t[current[j]]! < t[current[i]]! { best[i] = max(best[i], best[j] + w) }
    }
    let m = best.max() ?? 0
    return n - (m % 1000 + m / 1000)   // kept movables + kept anchors (all anchors are on every max chain)
}

struct ReconcilerRandomTests {
    @Test func randomizedConvergence() {
        let cases = 600
        for seed in 1...UInt64(cases) {
            var g = SplitMix64(seed: seed)
            func fail(_ m: String) -> Comment { Comment(rawValue: "seed \(seed): \(m)") }
            let n = Int.random(in: 3...25, using: &g)
            let keys = (0..<n).map { k("k\($0)") }
            // Layout: a random subset (some absent), random sections; a few unknown observed.
            var layout = Layout(newItemPolicy: Bool.random(using: &g) ? .visibleAtEnd : .hidden)
            var observedKeys: [ItemKey] = []
            for key in keys.shuffled(using: &g) {
                let r = Int.random(in: 0..<10, using: &g)
                switch r {
                case 0: layout.append(key, to: .visible)            // absent: in layout, not observed
                case 1: observedKeys.append(key)                     // unknown
                default:
                    layout.append(key, to: LayoutSection.allCases[Int.random(in: 0..<3, using: &g)])
                    observedKeys.append(key)
                }
            }
            var bar: [ItemKey] = [], parked: [ItemKey] = []
            for key in observedKeys { if Bool.random(using: &g) { bar.append(key) } else { parked.append(key) } }
            var o = ObservedOrder(onBar: bar, parked: parked)
            // Anchors: 0...3 immovable keys; some of them also unhideable.
            var anchorSet = Set<ItemKey>(), noHide = Set<ItemKey>()
            for key in observedKeys.shuffled(using: &g).prefix(Int.random(in: 0...3, using: &g)) {
                anchorSet.insert(key); if Bool.random(using: &g) { noHide.insert(key) }
            }
            for key in observedKeys where !anchorSet.contains(key) && Int.random(in: 0..<8, using: &g) == 0 { noHide.insert(key) }
            let caps = { (key: ItemKey) in Capability(canMove: !anchorSet.contains(key), canHide: !noHide.contains(key)) }
            let showHidden = Bool.random(using: &g)

            var converged = false
            var plans = 0
            for _ in 0..<3 {
                let p = rec.plan(observed: o, layout: layout, capabilities: caps, showHiddenSection: showHidden)
                plans += 1
                if p.phase == .converged { converged = true; break }
                if p.phase == .order {
                    // Anchors for the bound: immovable, or unhideable-but-should-be-hidden (unknown under .hidden policy too).
                    var a2 = Set(o.onBar.filter { anchorSet.contains($0) })
                    for key in o.onBar where noHide.contains(key) && !p.desiredOnBar.isEmpty {
                        let sec = layout.section(of: key)
                        let want = sec == .visible || (sec == .hidden && showHidden) || (sec == nil && layout.newItemPolicy == .visibleAtEnd)
                        if !want { a2.insert(key) }
                    }
                    let b = bound(current: o.onBar, target: p.desiredOnBar, anchors: a2)
                    #expect(p.actions.count <= b, fail("moves \(p.actions.count) > bound \(b)"))
                }
                var shown = Int.random(in: 0...1000, using: &g)
                for a in p.actions {
                    switch a {
                    case .move(let key, let rel):
                        if case .before(let t) = rel, case let idx = p.actions.firstIndex(of: a)!, p.actions[(idx + 1)...].contains(where: { if case .move(t, _) = $0 { true } else { false } }) {
                            Issue.record(fail("relation target \(t) is not yet in its final place"))
                        }
                        if case .after(let t) = rel, case let idx = p.actions.firstIndex(of: a)!, p.actions[(idx + 1)...].contains(where: { if case .move(t, _) = $0 { true } else { false } }) {
                            Issue.record(fail("relation target \(t) is not yet in its final place"))
                        }
                        #expect(caps(key).canMove, fail("moved immovable \(key)"))
                        #expect(p.phase == .order, fail("move outside order phase"))
                        switch rel {
                        case .before(let t), .after(let t): #expect(o.onBar.contains(t), fail("relation target \(t) not on bar"))
                        default: break
                        }
                    case .hide(let key): #expect(caps(key).canHide, fail("hid unhideable \(key)"))
                    case .show: break
                    }
                    let s = shown
                    o = PlanSimulator.apply(a, to: o, showInsertion: { c in s % (c + 1) })
                    shown = shown &* 31 &+ 7
                }
            }
            if converged {
                // Independent oracle: the layout-derived order of the keys now on the bar.
                var want = layout.visible + (showHidden ? layout.hidden : [])
                if layout.newItemPolicy == .visibleAtEnd { want += observedKeys.filter { layout.section(of: $0) == nil } }
                let onFinal = Set(o.onBar)
                want = want.filter { onFinal.contains($0) }
                let last = rec.plan(observed: o, layout: layout, capabilities: caps, showHiddenSection: showHidden)
                let reachable = last.skipped.allSatisfy { $0.reason != "immovable item is out of layout order" }
                let movables = o.onBar.filter { !anchorSet.contains($0) && Set(want).contains($0) }
                #expect(movables == want.filter { !anchorSet.contains($0) }, fail("movable order differs from layout"))
                if reachable {
                    // Everything the layout places (anchors included) is in layout order; unplaced anchors sit in between.
                    #expect(o.onBar.filter { Set(want).contains($0) } == want, fail("final order differs from layout"))
                }
                #expect(last.desiredOnBar == o.onBar, fail("final order differs from the planner's target"))
            }
            if !converged {
                converged = rec.plan(observed: o, layout: layout, capabilities: caps, showHiddenSection: showHidden).phase == .converged
                #expect(plans <= 3 && converged, fail("not converged within 3 plans"))
            }
        }
    }
}
