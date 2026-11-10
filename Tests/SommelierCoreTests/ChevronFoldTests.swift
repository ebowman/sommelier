import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// 9o9.11: items behind the « chevron are ordered. Observation (stripExpanded), cross-fold planning, convergence rule.

private let agent = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private func lay(v: [String]) -> Layout { Layout(visible: v.map(k), hidden: [], alwaysHidden: []) }
private let anchorCh: @Sendable (ItemKey) -> Capability = { $0 == k("ch") ? Capability(canMove: false, canHide: false) : Capability(canMove: true, canHide: true) }
private func obs(_ bar: [String], ovf: [String] = [], stale: [String] = [], uncorroborated: [String] = [], expanded: Bool = false) -> ObservedOrder {
    var o = ObservedOrder(onBar: bar.map(k), parked: [], systemOverflow: Set(ovf.map(k)), overflowChevron: k("ch"),
                          uncorroborated: Set((uncorroborated + stale).map(k)), staleOnBar: Set(stale.map(k)))
    o.stripExpanded = expanded
    return o
}
private let foldWording = "behind the « chevron; its order there is set when the strip is next opened"

// MARK: step 1, observation

private let chevronFrame = CGRect(x: 600, y: 1, width: 18, height: 27)
private func nineItemSource(stacked: Bool, menuBarMinX: CGFloat?) -> FixtureSource {
    var s = FixtureSource(apps: [agent])
    var els: [AXElementInfo] = (0..<9).map { i in
        let x = stacked ? 560 + CGFloat(i) * 0.2 : 270 + CGFloat(i) * 34
        return AXElementInfo(title: "I\(i)", axDescription: "I\(i)", identifier: "I\(i)", frame: CGRect(x: x, y: 3, width: 30, height: 24))
    }
    els.append(AXElementInfo(axDescription: "Show Hidden Menu Bar Items", frame: chevronFrame, directWindowChild: true))
    els.append(AXElementInfo(title: "D", axDescription: "D", identifier: "D", frame: CGRect(x: 640, y: 3, width: 30, height: 24)))
    var t = AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: els)
    t.menuBarMinX = menuBarMinX
    s.tree = t
    return s
}

@Test func anOpenStripFlagsNothingAndTheSameFramesStackedFlagTheNine() {
    let open = MenuBarScanner(source: nineItemSource(stacked: false, menuBarMinX: 260)).scan()
    #expect(open.stripExpanded)
    #expect(open.items.filter(\.systemOverflow).isEmpty)
    #expect(open.items.filter { $0.isOverflowChevron }.count == 1)
    let closed = MenuBarScanner(source: nineItemSource(stacked: true, menuBarMinX: 604)).scan()
    #expect(!closed.stripExpanded)
    #expect(Set(closed.items.filter(\.systemOverflow).map(\.axIdentifier)) == Set((0..<9).map { "I\($0)" }))
}

@Test func theStripIsNotExpandedWithoutTheAgentMenuBarRead() {
    // The same real-looking frames, but the read did not see the agent's AXMenuBar: never assumed open (left-of-chevron rule applies).
    let s = MenuBarScanner(source: nineItemSource(stacked: false, menuBarMinX: nil)).scan()
    #expect(!s.stripExpanded)
    #expect(s.items.filter(\.systemOverflow).count == 9)
}

@Test func aStaleChevronNeverSaysTheStripIsOpen() {
    var chev = MenuBarItem(ownerPID: 99, ownerBundleID: nil, ownerName: "x", title: "", axDescription: "", axIdentifier: "",
                           frame: chevronFrame, source: .agentHostedOnly, isOnMenuBar: true, stale: true, isOverflowChevron: true)
    chev.stripExpanded = true
    var a = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "a", title: "", axDescription: "", axIdentifier: "a",
                        frame: CGRect(x: 500, y: 3, width: 30, height: 24), source: .appExtras, isOnMenuBar: true)
    a.systemOverflow = false
    let snap = MenuBarSnapshot(items: [a, chev], capturedAt: Date())
    #expect(!snap.stripExpanded)
    #expect(SystemOverflow.mark([a, chev]).allSatisfy { !$0.systemOverflow })   // a stale chevron flags nothing either
}

@Test func theObservedOrderCarriesStripExpandedFromTheFreshChevronOnly() {
    func resolved(chevronStale: Bool) -> [ResolvedItem] {
        var chev = MenuBarItem(ownerPID: 99, ownerBundleID: nil, ownerName: "ch", title: "", axDescription: "", axIdentifier: "",
                               frame: chevronFrame, source: .agentHostedOnly, isOnMenuBar: true, stale: chevronStale, isOverflowChevron: true)
        chev.stripExpanded = true
        var a = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "a", title: "", axDescription: "", axIdentifier: "a",
                            frame: CGRect(x: 300, y: 3, width: 30, height: 24), source: .appExtras, isOnMenuBar: true)
        a.systemOverflow = true   // even a (wrongly) flagged item is not overflowed in an open strip
        return [ResolvedItem(item: a, key: k("a"), confidence: .exact), ResolvedItem(item: chev, key: k("ch"), confidence: .inferred)]
    }
    let open = ObservedOrder(resolved: resolved(chevronStale: false))
    #expect(open.stripExpanded && open.systemOverflow.isEmpty && open.overflowChevron == k("ch"))
    #expect(!ObservedOrder(resolved: resolved(chevronStale: true)).stripExpanded)
}

// MARK: step 2, collapsed strip

// MARK: step 3, expanded strip

// MARK: step 5, convergence rule

@Test func theFoldNeedNotBeAPrefixOfTheRecordToMatch() {
    let o = obs(["x1", "x2", "ch", "a", "b"], ovf: ["x1", "x2"])
    func match(_ rec: [String], _ key: String) -> Bool { ArrangeSections.placementMatches(k(key), layout: lay(v: rec), observed: o) }
    // prefix: matches, and the order among pile keys is not tracked
    #expect(["x1", "x2", "a", "b"].allSatisfy { match(["x1", "x2", "a", "b"], $0) })
    #expect(["x1", "x2", "a", "b"].allSatisfy { match(["x2", "x1", "a", "b"], $0) })
    // gdu.144: a drawn key the record places left of a pile key matches all the same: the fold is macOS's decision, only the drawn order counts
    #expect(["a", "x1", "x2", "b"].allSatisfy { match(["a", "x1", "x2", "b"], $0) })
    #expect(!match(["b", "x1", "x2", "a"], "a") && !match(["b", "x1", "x2", "a"], "b"))   // a drawn order mismatch still does not match
    // an open strip has no fold at all
    let open = obs(["a", "x1", "x2", "ch", "b"], expanded: true)   // drawn at real frames: ordinary order check, no prefix rule
    #expect(["a", "x1", "x2", "b"].allSatisfy { ArrangeSections.placementMatches(k($0), layout: lay(v: ["a", "x1", "x2", "b"]), observed: open) })
}

@Test func aFoldedKeyIsNotFittingWhateverTheRecordSaysAndADrawnKeyIsNeverPendingForIt() {
    // gdu.144: the fold is macOS's decision, so the record's position never makes a key pending.
    let o = obs(["x1", "x2", "ch", "a", "b"], ovf: ["x1", "x2"])
    for rec in [["x1", "x2", "a", "b"], ["a", "x1", "x2", "b"]] {
        #expect(ArrangeSections.foldBaseStatus(k("x1"), layout: lay(v: rec), observed: o) == .notFitting)
        #expect(ArrangeSections.foldBaseStatus(k("x2"), layout: lay(v: rec), observed: o) == .notFitting)
        #expect(ArrangeSections.foldBaseStatus(k("a"), layout: lay(v: rec), observed: o) == .inPlace)
    }
}

// MARK: churn does not exclude crossings or (9o9.12) any other move

@Test func theFoldNeverMakesAKeyPendingAndAFoldedKeyIsNeverInPlace() {
    let o = obs(["p1", "x", "ch", "d1", "d2", "d3", "d4"], ovf: ["p1", "x"])
    let l = lay(v: ["p1", "d1", "d2", "x", "d3", "d4"])
    for n in ["d1", "d2"] { #expect(ArrangeSections.foldBaseStatus(k(n), layout: l, observed: o) == .inPlace) }   // gdu.144: was .pending
    for n in ["x", "p1"] { #expect(ArrangeSections.foldBaseStatus(k(n), layout: l, observed: o) == .notFitting) }
    #expect(ArrangeSections.foldBaseStatus(k("d3"), layout: l, observed: o) == .inPlace)
}

// MARK: 9o9.28: a pull-out may be spelled `.before(B)` with B the nearest trusted drawn key RIGHT of X when none is trusted on the left
