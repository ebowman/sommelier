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
    }
    @Test func hiddenOnBarGetsHide() {
        let p = rec.plan(observed: obs(["a", "b"]), layout: lay(v: ["a"], h: ["b"]), capabilities: free)
        #expect(p.phase == .membership); #expect(p.actions == [.hide(k("b"))])
    }
    @Test func parkedVisibleGetsShow() {
        let p = rec.plan(observed: obs(["a"], ["b"]), layout: lay(v: ["a", "b"]), capabilities: free)
        #expect(p.phase == .membership); #expect(p.actions == [.show(k("b"))])
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
        // After applying, membership is done (the order of what is shown is the core's, sommelier-ejb.7).
        var o = obs(["h", "v", "x"], ["h2"])
        for a in p.actions { o = PlanSimulator.apply(a, to: o) }
        let p2 = rec.plan(observed: o, layout: lay(v: ["v"], h: ["h", "h2"], a: ["x"]), capabilities: free, showHiddenSection: true)
        #expect(p2.phase == .converged && p2.actions.isEmpty)
    }
    @Test func unknownOnBarVisibleAtEnd() {
        let p = rec.plan(observed: obs(["n2", "a", "n1"]), layout: lay(v: ["a"]), capabilities: free)
        #expect(p.newItems == [NewItem(k("n2"), .visible), NewItem(k("n1"), .visible)])
        #expect(p.phase == .converged)
    }
    @Test func unknownOnBarHiddenPolicy() {
        let p = rec.plan(observed: obs(["a", "n"]), layout: lay(v: ["a"], policy: .hidden), capabilities: free)
        #expect(p.actions == [.hide(k("n"))]); #expect(p.newItems == [NewItem(k("n"), .hidden)])
    }
    @Test func unknownParkedReportedNotShown() {
        let p = rec.plan(observed: obs(["a"], ["n"]), layout: lay(v: ["a"]), capabilities: free)
        #expect(p.phase == .converged); #expect(p.newItems == [NewItem(k("n"), .hidden)])
    }
    @Test func unhideableHiddenIsSkippedAndAnchored() {
        let u = k("u")
        let caps = { (key: ItemKey) in key == u ? Capability(canMove: true, canHide: false, reason: "no entry") : Capability(canMove: true, canHide: true) }
        let layout = lay(v: ["b", "a"], h: ["u"])
        let p = rec.plan(observed: obs(["a", "u", "b"]), layout: layout, capabilities: caps)
        #expect(p.skipped == [SkippedAction(u, "no entry")])
        #expect(p.phase == .converged && p.actions.isEmpty)
    }
    @Test func absentReportedAndIgnored() {
        let p = rec.plan(observed: obs(["a"]), layout: lay(v: ["a", "gone"], a: ["gone2"]), capabilities: free)
        #expect(p.phase == .converged); #expect(p.absent == [k("gone"), k("gone2")])
    }
    @Test func duplicatesKeepFirst() {
        let p = rec.plan(observed: obs(["a", "b", "a"]), layout: lay(v: ["a", "b"]), capabilities: free)
        #expect(p.phase == .converged)
    }
    private func res(_ n: String, x: CGFloat, stale: Bool = false, onBar: Bool = true, w: CGFloat = 24) -> ResolvedItem {
        ResolvedItem(item: MenuBarItem(ownerPID: 1, ownerBundleID: "com.x", ownerName: "X", title: n, axDescription: "",
                                       axIdentifier: "", frame: CGRect(x: x, y: 3, width: w, height: 24),
                                       source: .appExtras, isOnMenuBar: onBar, stale: stale), key: k(n), confidence: .exact)
    }
    /// gdu.101 (replaces the old exclusion rule): a stale ON-BAR item stays in the observed order, flagged and immovable; a stale PARKED
    /// item and zero-width entries are still excluded.
    @Test func staleOnBarKeptFlagged() {
        let o = ObservedOrder(resolved: [res("b", x: 50), res("a", x: 10), res("s", x: 20, stale: true), res("p", x: 0, onBar: false),
                                         res("sp", x: 0, stale: true, onBar: false), res("w", x: 0, onBar: false, w: 0)])
        #expect(o.onBar == [k("a"), k("s"), k("b")] && o.parked == [k("p")])
        #expect(o.staleOnBar == [k("s")])
        #expect(o.uncorroborated == [k("a"), k("s"), k("b")])
    }
    @Test func staleOnBarHideIsSkipped() {
        let o = ObservedOrder(onBar: [k("a"), k("s")], parked: [], uncorroborated: [k("s")], staleOnBar: [k("s")])
        let p = rec.plan(observed: o, layout: lay(v: ["a"], h: ["s"]), capabilities: free)
        #expect(p.actions.isEmpty)
        #expect(p.skipped.contains(SkippedAction(k("s"), Reconciler.staleSkipReason)))
        #expect(Reconciler.staleSkipReason == "position not refreshed; waiting for a fresh read")
    }

    // MARK: gdu.101 corrective pass
    @Test func staleChevronAndStaleOverflowDoNotFeedOverflowState() {
        func item(_ n: String, x: CGFloat, chevron: Bool = false, ovf: Bool = false, stale: Bool) -> ResolvedItem {
            ResolvedItem(item: MenuBarItem(ownerPID: 1, ownerBundleID: "com.x", ownerName: "X", title: n, axDescription: "", axIdentifier: "",
                                           frame: CGRect(x: x, y: 3, width: 24, height: 24), source: .appExtras, isOnMenuBar: true,
                                           stale: stale, isOverflowChevron: chevron, systemOverflow: ovf), key: k(n), confidence: .exact)
        }
        let o = ObservedOrder(resolved: [item("chev", x: 0, chevron: true, stale: true), item("o", x: 10, ovf: true, stale: true), item("a", x: 50, stale: false)])
        #expect(o.onBar == [k("chev"), k("o"), k("a")] && o.staleOnBar == [k("chev"), k("o")])
        #expect(o.systemOverflow.isEmpty && o.overflowChevron == nil)
        let f = ObservedOrder(resolved: [item("chev", x: 0, chevron: true, stale: false), item("o", x: 10, ovf: true, stale: false)])
        #expect(f.overflowChevron == k("chev") && f.systemOverflow == [k("o")])
    }
}

// MARK: Randomized convergence

/// Independent statement of the unit rule: which observed keys must end up on the bar.
private func unitWantSet(layout: Layout, bar: [ItemKey], parked: [ItemKey], showHidden: Bool, noHide: Set<ItemKey> = []) -> Set<ItemKey> {
    var out = Set<ItemKey>()
    for (_, ks) in hideUnits(bar + parked) {
        var secs = ks.compactMap { layout.section(of: $0) }
        // gdu.44: a unit with no observed listed key is decided by its layout-listed (absent) siblings.
        if secs.isEmpty { secs = layout.allKeys.filter { $0.hideUnit == ks[0].hideUnit }.compactMap { layout.section(of: $0) } }
        let wants: Bool
        if secs.isEmpty { wants = layout.newItemPolicy == .visibleAtEnd && ks.contains { bar.contains($0) } }
        else {
            let revealed = showHidden && secs.contains(.hidden) && !secs.contains(.alwaysHidden)
            // gdu.15: a unit pulled onto the bar only by the reveal is dropped when a parked key of it cannot be shown.
            let unshowable = !secs.contains(.visible) && ks.contains { parked.contains($0) && noHide.contains($0) }
            wants = secs.contains(.visible) || (revealed && !unshowable)
        }
        if wants { out.formUnion(ks) }
    }
    return out
}

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

struct ReconcilerRandomTests {
    @Test func randomizedConvergence() {
        let cases = 600
        for seed in 1...UInt64(cases) {
            var g = SplitMix64(seed: seed)
            func fail(_ m: String) -> Comment { Comment(rawValue: "seed \(seed): \(m)") }
            let n = Int.random(in: 3...25, using: &g)
            // Every third owner or so is a multi-item app (2-3 items): hide granularity is the app.
            var keys: [ItemKey] = []
            var owner = 0
            while keys.count < n {
                let size = Int.random(in: 0..<3, using: &g) == 0 ? Int.random(in: 2...3, using: &g) : 1
                for j in 0..<size where keys.count < n { keys.append(.status(ownerKey: "com.x.o\(owner)", autosaveName: "i\(j)")) }
                owner += 1
            }
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
            let want0 = unitWantSet(layout: layout, bar: bar, parked: parked, showHidden: showHidden, noHide: noHide)

            var converged = false
            var plans = 0
            for _ in 0..<3 {
                let p = rec.plan(observed: o, layout: layout, capabilities: caps, showHiddenSection: showHidden)
                plans += 1
                if p.phase == .converged { converged = true; break }
                #expect(p.phase == .membership, fail("a non-converged plan is a membership plan"))
                // A plan never hides a subset of an app: per unit, either no on-bar key or all of them.
                let hiddenNow = Set(p.actions.compactMap { a -> ItemKey? in if case .hide(let x) = a { x } else { nil } })
                for (unit, ks) in hideUnits(o.onBar) {
                    let n = ks.filter { hiddenNow.contains($0) }.count
                    #expect(n == 0 || n == ks.count, fail("plan hides \(n) of \(ks.count) items of \(unit)"))
                }
                var shown = Int.random(in: 0...1000, using: &g)
                for a in p.actions {
                    switch a {
                    case .move: Issue.record(fail("the Reconciler plans no order move (sommelier-ejb.7)"))
                    case .hide(let key): #expect(caps(key).canHide, fail("hid unhideable \(key)"))
                    case .show: break
                    }
                    let s = shown
                    o = PlanSimulator.apply(a, to: o, showInsertion: { c in s % (c + 1) })
                    shown = shown &* 31 &+ 7
                }
            }
            if !converged {
                let fp = rec.plan(observed: o, layout: layout, capabilities: caps, showHiddenSection: showHidden)
                converged = fp.phase == .converged
                #expect(plans <= 3 && converged, fail("not converged within 3 plans"))
            }
            // Independent oracle: every unit the layout wants shown that can be shown is on the bar at the end.
            let onFinal = Set(o.onBar)
            for key in want0 where !noHide.contains(key) && observedKeys.contains(key) { #expect(onFinal.contains(key), fail("wanted \(key) is not on the bar")) }
        }
    }
}

// gdu.61: iStat (an anchor) at the start of the trailing block must not be named as "the system items" in the skip message.
struct TrailingBlockNameTests {
}
