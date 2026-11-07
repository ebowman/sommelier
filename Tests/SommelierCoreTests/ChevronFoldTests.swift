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

@Test func aPullOutPlansExactlyOneMoveAfterTheNearestDrawnKeyLeftOfItInTheRecord() {
    // x1 is behind the chevron; the record wants it after a (and before b, c).
    let o = obs(["x1", "ch", "a", "b", "c"], ovf: ["x1"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["a", "x1", "b", "c"]), capabilities: anchorCh)
    #expect(p.phase == .order && p.actions == [.move(k("x1"), .after(k("a")))])
    #expect(p.skipped.isEmpty)
    #expect(Reconciler.crossesFold(p.actions[0], overflow: [k("x1")]))
}

@Test func aPullOutIsPreferredToAPushInEvenWhenThePileIsLarger() {
    // 9o9.22: the record puts a before both pile keys. The pull-out moves the key the user dragged (x1 after a), never the push-in.
    let o = obs(["x1", "x2", "ch", "a", "b"], ovf: ["x1", "x2"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["a", "x1", "x2", "b"]), capabilities: anchorCh)
    #expect(p.phase == .order && p.actions == [.move(k("x1"), .after(k("a")))])
    #expect(Reconciler.crossesFold(p.actions[0], overflow: [k("x1"), k("x2")]))
}

@Test func aPushInIsTheFallbackWhenThePileKeyCannotBePulledOut() {
    let rec = ["a", "x1", "b"].map(k)
    let m = Reconciler.crossFoldMove(record: rec, drawn: [k("a"), k("b")], pile: [k("x1")], excluded: [], canMove: { $0 != k("x1") }, blockStart: 2)
    #expect(m == .move(k("a"), .before(k("x1"))))
    let both = Reconciler.crossFoldMove(record: rec, drawn: [k("a"), k("b")], pile: [k("x1")], excluded: [], canMove: { _ in true }, blockStart: 2)
    #expect(both == .move(k("x1"), .after(k("a"))))
}

@Test func anAmbiguousPileKeyIsPulledOutAfterTheLiveDrawnKey() {
    // 9o9.22 live shape: record [KYA(pile), Jump(drawn), TimeMachine(pile, uncorroborated), ..., GateOpener]: exactly TimeMachine after Jump.
    let o = obs(["kya", "tm", "focus", "ch", "jump", "gate"], ovf: ["kya", "tm", "focus"], uncorroborated: ["tm", "focus"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["kya", "jump", "tm", "focus", "gate"]), capabilities: anchorCh)
    #expect(p.phase == .order && p.actions == [.move(k("tm"), .after(k("jump")))], "actions=\(p.actions) skipped=\(p.skipped)")
    #expect(!p.skipped.contains { $0.key == k("tm") })
}

@Test func anAmbiguousPileKeyThatIsTheRecordSlotAfterADrawnKeyComesOut() {
    // The first live shape: Jump ambiguous in the pile, the record puts it after KYA (drawn).
    let o = obs(["jump", "ch", "kya", "b"], ovf: ["jump"], uncorroborated: ["jump"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["kya", "jump", "b"]), capabilities: anchorCh)
    #expect(p.actions == [.move(k("jump"), .after(k("kya")))])
}

@Test func aHeldPileKeyIsNeverCrossedAndSaysItsOwnPositionIsUnread() {
    let o = obs(["x1", "ch", "a", "b"], ovf: ["x1"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["a", "x1", "b"]), capabilities: anchorCh, held: [k("x1")])
    #expect(p.actions.isEmpty)
    #expect(p.skipped.filter { $0.key == k("x1") }.map(\.reason) == [Reconciler.noCrossingOwnPositionSkipReason])
}

@Test func theDrawnOrderIsSettledBeforeAnyMoveAcrossTheFold() {
    let o = obs(["x1", "ch", "a", "b", "c"], ovf: ["x1"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["a", "x1", "c", "b"]), capabilities: anchorCh)
    #expect(p.actions.count == 1)
    if case .move(let s, _)? = p.actions.first { #expect([k("b"), k("c")].contains(s)) } else { Issue.record("expected a drawn move") }
    #expect(!Reconciler.crossesFold(p.actions[0], overflow: [k("x1")]))
}

@Test func anAmongPileReorderIsNeverPlannedAndIsSkippedWithTheNewReason() {
    let o = obs(["x1", "x2", "x3", "ch", "a", "b"], ovf: ["x1", "x2", "x3"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["x3", "x1", "x2", "a", "b"]), capabilities: anchorCh)
    #expect(p.phase == .converged && p.actions.isEmpty)
    #expect(!p.skipped.isEmpty && p.skipped.allSatisfy { $0.reason == foldWording && $0.reason == Reconciler.overflowSkipReason })
    #expect(p.skipped.allSatisfy { [k("x1"), k("x2"), k("x3")].contains($0.key) })
}

@Test func aFoldThatIsAPrefixOfTheRecordPlansNothingAndSaysNothing() {
    let o = obs(["x1", "x2", "ch", "a", "b"], ovf: ["x1", "x2"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["x1", "x2", "a", "b"]), capabilities: anchorCh)
    #expect(p.phase == .converged && p.actions.isEmpty && p.skipped.isEmpty)
}

@Test func anUntrustedOrStaleDrawnKeyIsNeverTheSubjectOrTheTargetOfACrossFoldMoveButAPileKeyMayBe() {
    // a is the only drawn key left of x1 in the record. Stale (a carried frame): no pull-out target, no push-in subject.
    let stale = obs(["x1", "ch", "a", "b"], ovf: ["x1"], stale: ["a"])
    let p = Reconciler().plan(observed: stale, layout: lay(v: ["a", "x1", "b"]), capabilities: anchorCh)
    #expect(p.actions.isEmpty)
    #expect(p.skipped.filter { $0.key == k("x1") }.map(\.reason) == [Reconciler.noCrossingSkipReason])
    let unc = obs(["x1", "ch", "a", "b"], ovf: ["x1"], uncorroborated: ["a"])
    let up = Reconciler().plan(observed: unc, layout: lay(v: ["a", "x1", "b"]), capabilities: anchorCh)
    #expect(up.actions.isEmpty)
    #expect(up.skipped.filter { $0.key == k("x1") }.map(\.reason) == [Reconciler.noCrossingSkipReason])
    // 9o9.22: an uncorroborated PILE key is a legal pull-out subject (its stacked frame is ambiguous by construction); only a held one is not.
    let ux = obs(["x1", "ch", "a", "b"], ovf: ["x1"], uncorroborated: ["x1"])
    let uxp = Reconciler().plan(observed: ux, layout: lay(v: ["a", "x1", "b"]), capabilities: anchorCh)
    #expect(uxp.actions == [.move(k("x1"), .after(k("a")))])
    // Only the order among pile keys differs (fold-consistent): the gdu.69 wording stays, never the no-crossing one.
    let among = obs(["x1", "x2", "ch", "a"], ovf: ["x1", "x2"])
    let ap = Reconciler().plan(observed: among, layout: lay(v: ["x2", "x1", "a"]), capabilities: anchorCh)
    #expect(ap.actions.isEmpty)
    #expect(ap.skipped.contains { $0.reason == Reconciler.overflowSkipReason })
    #expect(!ap.skipped.contains { $0.reason == Reconciler.noCrossingSkipReason || $0.reason == Reconciler.noCrossingOwnPositionSkipReason })
    // With a trusted drawn key the stale one is passed over: x1 goes after the trusted b, never after the stale a.
    let two = obs(["x1", "ch", "a", "b", "c"], ovf: ["x1"], stale: ["a"])
    let q = Reconciler().plan(observed: two, layout: lay(v: ["a", "b", "x1", "c"]), capabilities: anchorCh)
    #expect(q.actions == [.move(k("x1"), .after(k("b")))])
}

@Test func aKeyTheLayoutDoesNotListYetIsNeverPulledOut() {
    let o = obs(["u", "ch", "a", "b"], ovf: ["u"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["a", "b"]), capabilities: anchorCh)
    #expect(p.phase == .converged && p.actions.isEmpty)
}

@Test func aPullOutNeverLandsRightOfTheTrailingSystemBlock() {
    // clock is pinned at the right end; the only drawn key left of x1 in the record is the clock itself: no legal pull-out.
    let caps: @Sendable (ItemKey) -> Capability = { [k("ch"), k("clock")].contains($0) ? Capability(canMove: false, canHide: false) : Capability(canMove: true, canHide: true) }
    let o = obs(["x1", "ch", "a", "clock"], ovf: ["x1"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["a", "clock", "x1"]), capabilities: caps)
    #expect(!p.actions.contains { if case .move(_, .after(let t)) = $0 { return t == k("clock") }; return false })
}

// MARK: step 3, expanded strip

@Test func anOpenStripAllowsMovesAcrossTheChevronButNeverOfIt() {
    // e1 e2 are drawn LEFT of the chevron (strip open); the record interleaves them with the keys right of it.
    let o = obs(["e1", "e2", "ch", "a", "b"], expanded: true)
    let p = Reconciler().plan(observed: o, layout: lay(v: ["e1", "a", "e2", "b"]), capabilities: anchorCh)
    #expect(p.phase == .order && p.actions.count == 1)
    #expect(p.skipped.isEmpty)
    #expect(Reconciler.overflowViolations(p.actions, forbidden: [k("ch")], boundary: false).isEmpty)
    if case .move(let s, let rel)? = p.actions.first {
        #expect(s != k("ch"))
        switch rel { case .before(let t), .after(let t): #expect(t != k("ch")); default: Issue.record("edge drop \(rel)") }
    }
    #expect(!Reconciler.crossesFold(p.actions[0], overflow: []))   // nothing is behind the chevron
}

// MARK: step 5, convergence rule

@Test func theFoldMustBeAPrefixOfTheRecordToMatch() {
    let o = obs(["x1", "x2", "ch", "a", "b"], ovf: ["x1", "x2"])
    func match(_ rec: [String], _ key: String) -> Bool { ArrangeSections.placementMatches(k(key), layout: lay(v: rec), observed: o) }
    // prefix: matches, and the order among pile keys is not tracked
    #expect(["x1", "x2", "a", "b"].allSatisfy { match(["x1", "x2", "a", "b"], $0) })
    #expect(["x1", "x2", "a", "b"].allSatisfy { match(["x2", "x1", "a", "b"], $0) })
    // a drawn key the record places left of a pile key: neither the drawn key nor the pile key matches; the others do
    #expect(!match(["a", "x1", "x2", "b"], "a") && !match(["a", "x1", "x2", "b"], "x1"))
    #expect(match(["a", "x1", "x2", "b"], "b"))
    // an open strip has no fold at all
    let open = obs(["a", "x1", "x2", "ch", "b"], expanded: true)   // drawn at real frames: ordinary order check, no prefix rule
    #expect(["a", "x1", "x2", "b"].allSatisfy { ArrangeSections.placementMatches(k($0), layout: lay(v: ["a", "x1", "x2", "b"]), observed: open) })
}

@Test func statusIsNotFittingOnlyWhileTheRecordLeavesTheKeyBehindTheChevron() {
    let o = obs(["x1", "x2", "ch", "a", "b"], ovf: ["x1", "x2"])
    #expect(ArrangeSections.foldConsistent(k("x1"), layout: lay(v: ["x1", "x2", "a", "b"]), observed: o))
    #expect(!ArrangeSections.foldConsistent(k("x2"), layout: lay(v: ["a", "x1", "x2", "b"]), observed: o))
    #expect(ArrangeSections.foldConsistent(k("zz"), layout: lay(v: ["a", "x1", "x2", "b"]), observed: o))   // not in the record
}

// MARK: churn does not exclude crossings or (9o9.12) any other move

@Test func aChurnZoneDrawnKeyIsTheTargetOfAPullOutOnAFullBar() {
    let o = obs(["p1", "x", "ch", "d1", "d2", "d3", "d4"], ovf: ["p1", "x"])
    let l = lay(v: ["p1", "d1", "d2", "x", "d3", "d4"])
    let p = Reconciler().plan(observed: o, layout: l, capabilities: anchorCh)
    #expect(p.phase == .order && p.actions == [.move(k("x"), .after(k("d2")))])
}

@Test func aChurnZoneKeyMayBeTheTargetOfANonCrossingMoveBecauseTheStripSessionCoversIt() {
    let o = obs(["ch", "a", "b", "c"])
    let p = Reconciler().plan(observed: o, layout: lay(v: ["c", "a", "b"]), capabilities: anchorCh)
    var touchesA = false
    for case .move(let s, let rel) in p.actions {
        if s == k("a") { touchesA = true }
        switch rel { case .before(let t), .after(let t): if t == k("a") { touchesA = true }; default: break }
    }
    #expect(touchesA)
}

@Test func keysInconsistentWithTheFoldAreNeverInPlace() {
    let o = obs(["p1", "x", "ch", "d1", "d2", "d3", "d4"], ovf: ["p1", "x"])
    let l = lay(v: ["p1", "d1", "d2", "x", "d3", "d4"])
    for n in ["x", "d1", "d2"] { #expect(ArrangeSections.foldBaseStatus(k(n), layout: l, observed: o) == .pending) }
    #expect(ArrangeSections.foldBaseStatus(k("p1"), layout: l, observed: o) == .notFitting)
    #expect(ArrangeSections.foldBaseStatus(k("d3"), layout: l, observed: o) == .inPlace)
    let line = ArrangeSections.statusLine(perItem: [k("x"): .pending, k("d1"): .pending], lastError: nil, isConverged: true, inFlight: false, showsBarMatch: true)
    #expect(!line.contains("matches"))
}
