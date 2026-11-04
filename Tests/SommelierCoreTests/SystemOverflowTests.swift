import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// gdu.45: Apple's own overflow area (items behind the "Show Hidden Menu Bar Items" chevron).

private let agent = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
private func bar(_ x: CGFloat, w: CGFloat = 30, y: CGFloat = 3, h: CGFloat = 24) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private func free(_: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
private func lay(v: [String], h: [String] = []) -> Layout { Layout(visible: v.map(k), hidden: h.map(k), alwaysHidden: []) }
private func obs(_ bar: [String], ovf: [String] = [], parked: [String] = [], chevron: String? = "ch") -> ObservedOrder {
    ObservedOrder(onBar: bar.map(k), parked: parked.map(k), systemOverflow: Set(ovf.map(k)), overflowChevron: chevron.map(k))
}
private let anchorCh: @Sendable (ItemKey) -> Capability = { $0 == k("ch") ? Capability(canMove: false, canHide: false) : Capability(canMove: true, canHide: true) }

/// A full bar as the agent reports it: three stacked, clipped items, the chevron (direct window child, no identifier,
/// description in a LOCALE other than English), then two drawn items.
private func fullBarSource(chevronDescription: String = "Ausgeblendete Menüleistenobjekte einblenden") -> FixtureSource {
    var s = FixtureSource(apps: [agent])
    s.tree = AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [
        AXElementInfo(title: "A", axDescription: "A", identifier: "A", frame: bar(560, w: 40)),
        AXElementInfo(title: "B", axDescription: "B", identifier: "B", frame: bar(562, w: 38)),
        AXElementInfo(title: "C", axDescription: "C", identifier: "C", frame: bar(565, w: 35)),
        AXElementInfo(axDescription: chevronDescription, frame: bar(590, w: 18, y: 1, h: 27), directWindowChild: true),
        AXElementInfo(title: "D", axDescription: "D", identifier: "D", frame: bar(620)),
        AXElementInfo(title: "E", axDescription: "E", identifier: "E", frame: bar(660)),
    ])
    return s
}

@Test func scannerFlagsItemsLeftOfALocalizedChevron() {
    let snap = MenuBarScanner(source: fullBarSource()).scan()
    let byName = Dictionary(uniqueKeysWithValues: snap.items.map { ($0.axIdentifier.isEmpty ? "chevron" : $0.axIdentifier, $0) })
    #expect(byName["chevron"]?.isOverflowChevron == true)
    #expect(byName["chevron"]?.systemOverflow == false)
    #expect(["A", "B", "C"].allSatisfy { byName[$0]?.systemOverflow == true })
    #expect(["D", "E"].allSatisfy { byName[$0]?.systemOverflow == false })
    #expect(snap.items.filter(\.isOnMenuBar).count == 6)        // still "on the bar per the agent"
}

@Test func chevronKeyIsTheSameUnderAnyLocale() {
    let de = IdentityResolver().resolve(snapshot: MenuBarScanner(source: fullBarSource()).scan())
    let en = IdentityResolver().resolve(snapshot: MenuBarScanner(source: fullBarSource(chevronDescription: "Show Hidden Menu Bar Items")).scan())
    let want = ItemKey.module(name: "Show Hidden Menu Bar Items")
    #expect(de.contains { $0.key == want } && en.contains { $0.key == want })
}

@Test func englishDescriptionIsOnlyAFallbackAndAnItemWithAnIdentifierIsNotTheChevron() {
    #expect(AXElementInfo(axDescription: "Show Hidden Menu Bar Items", frame: bar(1)).isOverflowChevron)
    #expect(AXElementInfo(axDescription: "x", frame: bar(1), directWindowChild: true).isOverflowChevron)
    #expect(!AXElementInfo(axDescription: "x", identifier: "id", frame: bar(1), directWindowChild: true).isOverflowChevron)
    #expect(!AXElementInfo(axDescription: "x", frame: bar(1)).isOverflowChevron)
}

@Test func identicalFramesOnANormalBarFlagNothingInTheScannerButTheActuatorGuardRefusesThatPair() {
    var s = FixtureSource(apps: [agent])
    s.tree = AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [
        AXElementInfo(title: "A", axDescription: "A", identifier: "A", frame: bar(100)),
        AXElementInfo(title: "B", axDescription: "B", identifier: "B", frame: bar(300)),
        AXElementInfo(title: "C", axDescription: "C", identifier: "C", frame: bar(300)),     // coincidental twin of B
        AXElementInfo(title: "D", axDescription: "D", identifier: "D", frame: bar(340)),
    ])
    let snap = MenuBarScanner(source: s).scan()
    #expect(snap.items.allSatisfy { !$0.systemOverflow })
    let over = ActuationVerifier.overflowed(IdentityResolver().resolve(snapshot: snap))
    #expect(over.count == 2)                                            // B and C only, no cascade to A or D
}

@Test func aStaleChevronFlagsNothing() {
    func entry(_ x: CGFloat, chevron: Bool = false, stale: Bool = false) -> SystemOverflow.Entry {
        .init(frame: bar(x), stale: stale, isChevron: chevron)
    }
    #expect(SystemOverflow.indices(order: [entry(1), entry(40), entry(80, chevron: true, stale: true), entry(120)]).isEmpty)
    #expect(SystemOverflow.indices(order: [entry(1), entry(40), entry(120)]).isEmpty)
    #expect(SystemOverflow.indices(order: [entry(1), entry(40, stale: true), entry(80, chevron: true), entry(120)]) == [0])
}

@Test func aMissedChevronYieldsNoFlagsEvenWithStackedFrames() {
    var s = FixtureSource(apps: [agent])
    s.tree = AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [
        AXElementInfo(title: "A", axDescription: "A", identifier: "A", frame: bar(560, w: 40)),
        AXElementInfo(title: "B", axDescription: "B", identifier: "B", frame: bar(562, w: 38)),
        AXElementInfo(title: "C", axDescription: "C", identifier: "C", frame: bar(640)),
    ])
    #expect(MenuBarScanner(source: s).scan().items.allSatisfy { !$0.systemOverflow })
}

@Test func aNormalBarFlagsNothing() {
    var s = FixtureSource(apps: [agent])
    s.tree = AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [
        AXElementInfo(axDescription: "A", identifier: "A", frame: bar(100)),
        AXElementInfo(axDescription: "B", identifier: "B", frame: bar(132)),
        AXElementInfo(axDescription: "C", identifier: "C", frame: bar(164)),
    ])
    #expect(MenuBarScanner(source: s).scan().items.allSatisfy { !$0.systemOverflow })
}

@Test func menuBarItemCodableDefaultsAndRoundTrip() throws {
    var it = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "o", title: "", axDescription: "", axIdentifier: "i",
                         frame: bar(1), source: .appExtras, isOnMenuBar: true)
    let plain = try JSONEncoder().encode(it)
    #expect(try JSONDecoder().decode(MenuBarItem.self, from: plain).systemOverflow == false)
    var obj = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
    obj["systemOverflow"] = nil; obj["overflowChevron"] = nil          // an old cache file
    let old = try JSONDecoder().decode(MenuBarItem.self, from: JSONSerialization.data(withJSONObject: obj))
    #expect(!old.systemOverflow && !old.isOverflowChevron)
    it.systemOverflow = true; it.isOverflowChevron = true
    let back = try JSONDecoder().decode(MenuBarItem.self, from: JSONEncoder().encode(it))
    #expect(back.systemOverflow && back.isOverflowChevron)
}

@Test func actuationVerifierDelegatesToTheScannerFlag() {
    var a = MenuBarItem(ownerPID: 1, ownerBundleID: "app.A", ownerName: "A", title: "", axDescription: "", axIdentifier: "A",
                        frame: bar(100), source: .appExtras, isOnMenuBar: true)
    var b = a; b.axIdentifier = "B"; b.frame = bar(300)
    a.systemOverflow = true                                            // flagged although geometry alone shows nothing
    let ra = ResolvedItem(item: a, key: k("A"), confidence: .exact), rb = ResolvedItem(item: b, key: k("B"), confidence: .exact)
    #expect(ActuationVerifier.overflowed([ra, rb]) == [k("A")])
}

@Test func observedOrderCarriesTheFlag() {
    func r(_ n: String, x: CGFloat, ovf: Bool) -> ResolvedItem {
        var i = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: n, title: "", axDescription: "", axIdentifier: n,
                            frame: bar(x), source: .appExtras, isOnMenuBar: true)
        i.systemOverflow = ovf
        return ResolvedItem(item: i, key: k(n), confidence: .exact)
    }
    let o = ObservedOrder(resolved: [r("a", x: 10, ovf: true), r("b", x: 80, ovf: false)])
    #expect(o.onBar == [k("a"), k("b")] && o.systemOverflow == [k("a")])
}

// MARK: planner

@Test func plannerNeverMovesAnOverflowedItemOrTargetsItOrLandsLeftOfTheChevron() {
    // Overflow o1 o2 | chevron | drawn a b c. The layout keeps the overflow first and wants c first of the drawn items.
    let o = obs(["o1", "o2", "ch", "a", "b", "c"], ovf: ["o1", "o2"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["o1", "o2", "c", "a", "b"]), capabilities: anchorCh)
    #expect(p.actions == [.move(k("c"), .before(k("a")))])               // never .leftmost, never relative to ch/o1/o2
    #expect(p.skipped.isEmpty)
    #expect(Reconciler.overflowViolations(p.actions, forbidden: [k("o1"), k("o2"), k("ch")], boundary: true).isEmpty)
    // a rightmost-style rearrangement stays clear of the boundary too
    let q = Reconciler().plan(observed: o, layout: lay(v: ["o1", "o2", "c", "b", "a"]), capabilities: anchorCh)
    #expect(Reconciler.overflowViolations(q.actions, forbidden: [k("o1"), k("o2"), k("ch")], boundary: true).isEmpty)
    #expect(!q.actions.isEmpty)
}

@Test func theBoundaryPostConditionCatchesBadActions() {
    let bad: [PlannedAction] = [.move(k("a"), .before(k("ch"))), .move(k("o1"), .rightmost), .move(k("a"), .leftmost), .move(k("a"), .after(k("b")))]
    let v = Reconciler.overflowViolations(bad, forbidden: [k("o1"), k("ch")], boundary: true)
    #expect(v == Array(bad.prefix(3)))
}

@Test func planWithTheTailInSystemOverflowIsConvergedAndSilent() {
    let o = obs(["o1", "o2", "ch", "a", "b"], ovf: ["o1", "o2"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["o1", "o2", "ch", "a", "b"]), capabilities: anchorCh)
    #expect(p.phase == .converged && p.actions.isEmpty && p.skipped.isEmpty)
    #expect(p.desiredOnBar == ["o1", "o2", "ch", "a", "b"].map(k))
    // the order among overflowed items carries no information (stacked frames): swapping them is not a request
    let q = Reconciler().plan(observed: o, layout: lay(v: ["o2", "o1", "ch", "a", "b"]), capabilities: anchorCh)
    #expect(q.phase == .converged && q.skipped.isEmpty)
}

@Test func aWantedButParkedKeyFirstInTheLayoutCausesNoSpuriousSkips() {
    let o = obs(["o1", "o2", "ch", "a", "b"], ovf: ["o1", "o2"], parked: ["p"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["p", "o1", "o2", "ch", "a", "b"]), capabilities: anchorCh)
    #expect(p.skipped.isEmpty)
    #expect(p.actions == [.show(k("p"))])
}

@Test func aDrawnKeyPlacedLeftOfTheOverflowRunIsOrderedAmongDrawnKeysOnly() {
    let o = obs(["o1", "ch", "a", "b", "c"], ovf: ["o1"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["c", "o1", "ch", "a", "b"]), capabilities: anchorCh)
    #expect(p.skipped.isEmpty)
    #expect(p.actions == [.move(k("c"), .before(k("a")))])              // never a slot left of the first drawn item
    #expect(Reconciler.overflowViolations(p.actions, forbidden: [k("o1"), k("ch")], boundary: true).isEmpty)
}

@Test func anOverflowedItemMayStillBeHidden() {
    let p = Reconciler().plan(observed: obs(["o1", "ch", "a"], ovf: ["o1"]), layout: lay(v: ["ch", "a"], h: ["o1"]), capabilities: anchorCh)
    #expect(p.phase == .membership && p.actions == [.hide(k("o1"))])
}

// MARK: state, panel, layout helper

@Test func overflowEntriesListNotFittingItemsAfterTheHiddenOnes() {
    func info(_ key: ItemKey, ovf: Bool) -> ItemInfo {
        ItemInfo(key: key, title: "", axDescription: "n", ownerPID: 1, ownerBundleID: "x", ownerName: "n", width: 30, isOnBar: true, systemOverflow: ovf)
    }
    let l = lay(v: ["o1", "a", "o2"], h: ["h"])
    let items = [k("o1"): info(k("o1"), ovf: true), k("a"): info(k("a"), ovf: false), k("o2"): info(k("o2"), ovf: true), k("h"): info(k("h"), ovf: false)]
    let e = OverflowEntries.make(layout: l, items: items)
    #expect(e.map(\.key) == [k("h"), k("o1"), k("o2")])
    #expect(e.map(\.kind) == [.hiddenByUs, .notFitting, .notFitting])
}

@Test func hideNotFittingMovesTheKeysAndTheirUnitsToHidden() {
    var l = lay(v: ["a", "o1", "b", "o2"], h: ["h"])
    let moved = l.hideNotFitting([k("o1"), k("o2"), k("h"), k("zz")])   // h is already hidden, zz unknown: ignored
    #expect(moved == [k("o1"), k("o2")])
    #expect(l.visible == [k("a"), k("b")] && l.hidden == [k("h"), k("o1"), k("o2")])
    #expect(l.hideNotFitting([]).isEmpty)
}

// MARK: overflowed keys never influence drawn keys (third corrective pass)

@Test func anUnknownNewItemInTheOverflowCausesNoSkipsAndNoActions() {
    let o = obs(["u", "ch", "a", "b", "c"], ovf: ["u"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["a", "b", "c"]), capabilities: anchorCh)
    #expect(p.phase == .converged && p.actions.isEmpty && p.skipped.isEmpty)
}

@Test func aSiblingPulledOnBarByLayoutDecodeNormalizationCausesNoSkipsAndNoActions() throws {
    func kk(_ n: String) -> ItemKey { .status(ownerKey: "com.x.app", autosaveName: n) }
    // "o" (overflowed) is hidden-listed, but its app also has visible items: decode moves it to visible, after every drawn key.
    let json = Data(#"{"schemaVersion":1,"visible":["status:com.x.app::a","status:com.x.z::z","status:com.x.app::b"],"hidden":["status:com.x.app::o"],"alwaysHidden":[],"newItemPolicy":"visibleAtEnd"}"#.utf8)
    let (l, warnings) = try Layout.decode(json)
    #expect(!warnings.isEmpty && l.visible.last == kk("o"))              // normalization ran
    let o = ObservedOrder(onBar: [kk("o"), k("ch"), kk("a"), .status(ownerKey: "com.x.z", autosaveName: "z"), kk("b")], parked: [],
                          systemOverflow: [kk("o")], overflowChevron: k("ch"))
    let p = Reconciler().plan(observed: o, layout: l, capabilities: anchorCh)
    #expect(p.skipped.isEmpty && p.actions.isEmpty && p.phase == .converged)
}

@Test func churnInWhichItemsOverflowCausesNoSkipsAndNoActions() {
    // At init O was overflowed and 28 drawn; later O is drawn and 28 overflowed.
    let o = obs(["28", "ch", "O", "M", "N"], ovf: ["28"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["O", "28", "ch", "M", "N"]), capabilities: anchorCh)
    #expect(p.phase == .converged && p.skipped.isEmpty && p.actions.isEmpty)
}

@Test func aRealBarShapedFixtureWithTheLayoutEqualToTheObservedOrderIsConverged() {
    let ovf = (1...14).map { "o\($0)" }, drawn = (1...30).map { "d\($0)" }
    let o = obs(ovf + ["ch"] + drawn, ovf: ovf)
    let p = Reconciler().plan(observed: o, layout: lay(v: ovf + ["ch"] + drawn), capabilities: anchorCh)
    #expect(p.phase == .converged && p.actions.isEmpty && p.skipped.isEmpty)
}

@Test func swappingTwoDrawnKeysWithTheOverflowPresentIsExactlyOneDrawnMove() {
    let ovf = ["o1", "o2", "o3"], drawn = ["a", "b", "c", "d"]
    let o = obs(ovf + ["ch"] + drawn, ovf: ovf)
    let p = Reconciler().plan(observed: o, layout: lay(v: ovf + ["ch", "a", "c", "b", "d"]), capabilities: anchorCh)
    #expect(p.skipped.isEmpty)
    #expect(p.actions.count == 1)
    if case .move(let s, let rel)? = p.actions.first {
        #expect([k("b"), k("c")].contains(s))
        switch rel { case .before(let t), .after(let t): #expect(drawn.map(k).contains(t)); default: Issue.record("unexpected \(rel)") }
    } else { Issue.record("expected a move") }
}
