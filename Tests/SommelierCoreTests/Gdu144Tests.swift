import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// gdu.144: on an overfull bar the fold is macOS's decision. The engine orders DRAWN items only and crosses the fold only for the user's own
// drop, once; any failed engine-initiated drag holds the bar; Arrange warns instead of fighting the fold.
// Rig (Gdu126Tests.holdRig): P1..P3 are folded behind «, D1..D4 drawn.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }

@MainActor
@Suite struct OverfullLaunchTests {
    // A record that disagrees with the fold: it wants P1..P3 between the drawn keys. The drawn order D1 D2 D3 D4 is the record's.
    @Test func launchOnAnOverfullBarDragsNothingAndConvergesThenAFreshEngineDoesTheSame() async {
        for _ in 0..<2 {   // second iteration = a restart: a new engine over the same layout
            let r = await holdRig(failCalls: 0, drop: [])
            // a real actuator would open the strip for anything near the fold: here every move touching the pile or the first drawn key does,
            // so ANY such move (not just a counted one) shows up in stripEvents
            await r.actuator.setStripPolicy { _, key, rel in
                let zone: Set<ItemKey> = [k("P1"), k("P2"), k("P3"), k("D1")]
                if zone.contains(key) { return true }
                switch rel { case .before(let t), .after(let t): return zone.contains(t); default: return false }
            }
            for _ in 0..<10 { _ = await r.engine.reconcileOnce() }
            #expect(await moveCalls(r.actuator) == 0)
            #expect(await r.actuator.stripEvents.isEmpty)
            #expect(!r.state.isConverged && r.state.coreStatus != .moving)   // sommelier-ejb.7, CHANGED: `isConverged` follows the core, which says `differs(plain)` here (the record disagrees with the fold); nothing is dragged
            for key in [k("P1"), k("P2"), k("P3")] { #expect(r.state.perItem[key] == .notFitting) }   // « , never pending / unsupported
            for key in [k("D1"), k("D2"), k("D3"), k("D4")] { #expect(r.state.perItem[key] == .inPlace) }
        }
    }

    @Test func aDrawnOrderMismatchIsOneEngineMove() async {
        let r = await holdRig(failCalls: 0, drop: [], record: ["P1", "P2", "P3", "D1", "D2", "D4", "D3"])
        for _ in 0..<10 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 1)
        let flags = await r.actuator.moveSingleDrag
        #expect(flags.count == 1 && flags[0].1)   // engine-initiated on a bar with a chevron: told to post one drag
        #expect(r.state.isConverged)
    }

    @Test func aFailingDrawnMoveIsExactlyOneDragThenTheHoldAndNothingMoreOverTenPasses() async {
        // the drawn order is fully reversed: several moves are wanted; the first one fails
        // ejb.15 (Wiring 3), CHANGED because the core decides: the record is now ONE swap away (D4 / D3) instead of fully reversed. With the reversed record the
        // core's first inversion is `D4 before D1`, and D1 is in the churn zone, i.e. a move that needs the strip: the core withholds every engine move that needs
        // the strip (only the user's drop or Re-apply's grant may), so no drag would be made at all. The property tested (one failing drag, then the hold,
        // nothing more over ten passes) needs a drawn mismatch away from the zone.
        let r = await holdRig(failCalls: 20, message: "the drag did not land", drop: [], record: ["P1", "P2", "P3", "D1", "D2", "D4", "D3"])
        for _ in 0..<10 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 1)
        #expect(!r.bar.lines.contains { $0.contains("giving up") })
        let line = ArrangeSections.barFullText(3)
        #expect(line == "The bar is full: macOS folds 3 items behind «. Hide items to make room.")
        // Retry releases the hold: one more attempt
        await r.engine.userRetry()
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        // gdu.144 D5: the press frees ONE budgeted engine move (call 2, which fails and holds again); the granted strip session finds no move that needs it
        // (the mismatch is away from the zone, see above); nothing more
        #expect(await moveCalls(r.actuator) == 2)
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 2)
    }

    @Test func theUsersOwnDropGetsItsOneAttemptEvenWhileTheBarIsHeld() async {
        // ejb.15 (Wiring 3), CHANGED because the core decides: a one-swap record (D4 / D3), see aFailingDrawnMoveIsExactlyOneDrag...: the engine's first drag is
        // the swap (it fails and holds); a fully reversed record would make no engine drag at all (its first move needs the strip).
        let r = await holdRig(failCalls: 1, message: "the drag did not land", drop: [], record: ["P1", "P2", "P3", "D1", "D2", "D4", "D3"])
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 1)
        // the user drops D4 first of the drawn keys (a drawn-only edit: the hold is kept, the move is the user's own)
        let edited = Layout.placedAll(visible: ["P1", "P2", "P3", "D4", "D1", "D2", "D3"].map(k))
        await r.engine.setLayout(edited, moved: [k("D4")])
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 2)
        let flags = await r.actuator.moveSingleDrag
        #expect(flags.count == 2 && flags[0].1 && flags[1].1)   // gdu.144 D7: the user's own drop is a single drag too on a full bar
    }
}

@MainActor
@Suite struct UserFoldDropTests {
    @Test func aFoldedKeyDroppedRightOfTheFoldLineIsExactlyOneSessionAndIsConsumed() async {
        let r = await holdRig(failCalls: 0)   // the user dropped P1 after D1
        for _ in 0..<10 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 1)
    }

    @Test func aFailedFoldDropIsNotRetriedAndAFreshEngineNeverPullsAnything() async {
        let r = await holdRig(failCalls: 20, message: ActuationError.stripMoveDidNotHoldMessage)
        for _ in 0..<10 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 1)
        // restart: a new engine over the same record
        let again = await holdRig(failCalls: 0, drop: [])
        for _ in 0..<10 { _ = await again.engine.reconcileOnce() }
        #expect(await moveCalls(again.actuator) == 0)
    }

    @Test func aFoldedKeyDroppedLeftOfTheFoldLineIsNoDragAtAllAndTheRowSaysSo() async {
        let record = ["P1", "D1", "D2", "P2", "D3", "P3", "D4"]
        let r = await holdRig(failCalls: 0, drop: ["P1"], record: record)
        for _ in 0..<10 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 0)
        #expect(r.state.perItem[k("P1")] == .notFitting)
        let text = ArrangeBarState.stayBehindText("P1")
        #expect(text == "P1 is in your order, but macOS folds from the left, so it stays behind « until there is room")
    }
    // (the 10:29 replay on the REAL bar shape lives in Gdu144AdversarialTests.theLiveTenTwentyNineDropMovesTimeMachineAtMostOnceAndNeverJumpOrNetwork)
}

@Suite struct ArrangeFoldRowsTests {
    private let chev = ItemKey.module(name: MenuBarItem.overflowChevronName)
    private func caps(_ key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }

    @Test func pileRowsReadChevronNotWarningWhateverTheEngineSaysAboutTheirPosition() {
        let (p1, p2, d1) = (k("P1"), k("P2"), k("D1"))
        let o = ObservedOrder(onBar: [p1, p2, chev, d1], parked: [], systemOverflow: [p1, p2], overflowChevron: chev, uncorroborated: [p1, p2])
        let layout = Layout(visible: [d1, p1, p2])
        let status: [ItemKey: ItemStatus] = [p1: .unsupported("could not corroborate its position on the bar for 60 s: x"), p2: .waitingForPosition("stale"), d1: .inPlace]
        let c = ArrangeSections.make(observed: o, layout: layout, items: [:], perItem: status, capabilities: caps)
        for key in [p1, p2] {
            let r = c.visible.rows.first { $0.key == key }!
            #expect(r.barState == .behindChevron && r.badge == .behindChevron, "\(key)")
        }
    }

    @Test func hideWhatDoesNotFitIncludesTheFoldedParkedKeysToo()  throws {
        let (p1, f1, d1) = (k("P1"), k("F1"), k("D1"))
        var o = ObservedOrder(onBar: [p1, chev, d1], parked: [f1], systemOverflow: [p1], overflowChevron: chev)
        o.foldedParked = [f1]
        let r = try ArrangeDrop.hideNotFitting(layout: Layout(visible: [d1, p1, f1]), observed: o, capabilities: caps)
        #expect(Set(r.moved) == [p1, f1])
        #expect(r.layout.hidden.contains(f1) && r.layout.hidden.contains(p1))
    }

    @Test func theHoldAndPutBackTextsAreExact() {
        #expect(ArrangeSections.barFullText(1) == "The bar is full: macOS folds 1 item behind «. Hide items to make room.")
        #expect(ArrangeBarState.putBackText == "macOS put it back behind «; hide something to make room")
        #expect(ArrangeSections.plainReason(ActuationError.stripMoveDidNotHoldMessage) == ArrangeBarState.putBackText)
    }
}

// MARK: corrective pass (reviewer scenarios): carried chevron, request order, request lifetime, churn zone, budget

private let chevK144 = ItemKey.module(name: MenuBarItem.overflowChevronName)

private final class Mode144: @unchecked Sendable {
    private let lock = NSLock(); private var c = false; private var d = true; private var amb = false; private var g = false
    var carried: Bool { get { lock.lock(); defer { lock.unlock() }; return c } set { lock.lock(); c = newValue; lock.unlock() } }
    var d3: Bool { get { lock.lock(); defer { lock.unlock() }; return d } set { lock.lock(); d = newValue; lock.unlock() } }
    var gone: Bool { get { lock.lock(); defer { lock.unlock() }; return g } set { lock.lock(); g = newValue; lock.unlock() } }   // no chevron at all (the bar no longer overflows)
    var ambiguous: Bool { get { lock.lock(); defer { lock.unlock() }; return amb } set { lock.lock(); amb = newValue; lock.unlock() } }
}
private func snap144(_ m: Mode144) -> MenuBarSnapshot {
    func item(_ name: String, _ f: CGRect, isChev: Bool = false, pile: Bool = false) -> MenuBarItem {
        var i = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: isChev ? name : k(name).description, axDescription: "",
                            axIdentifier: isChev ? "" : k(name).description, frame: f, source: .appExtras, isOnMenuBar: true, isOverflowChevron: isChev,
                            joinEvidence: (pile && m.ambiguous) ? .none : .identifier)
        i.controlCenterAllowed = true
        if isChev { i.stale = m.carried; i.recentlyVerified = m.carried }
        return i
    }
    var items: [MenuBarItem] = []
    if m.gone {   // everything fits: P1..P3 are drawn, no chevron
        for (i, n) in (["P1", "P2", "P3"] + (m.d3 ? ["D1", "D2", "D3", "D4"] : ["D1", "D2", "D4"])).enumerated() { items.append(item(n, CGRect(x: 100 + CGFloat(i) * 60, y: 0, width: 24, height: 24))) }
        return MenuBarSnapshot(items: SystemOverflow.mark(items), capturedAt: Date())
    }
    for (i, n) in ["P1", "P2", "P3"].enumerated() { items.append(item(n, CGRect(x: 700 + CGFloat(i) * 20, y: 0, width: 24, height: 24), pile: true)) }
    items.append(item(chevK144.description, CGRect(x: 786, y: 0, width: 17, height: 24), isChev: true))
    for (i, n) in (m.d3 ? ["D1", "D2", "D3", "D4"] : ["D1", "D2", "D4"]).enumerated() { items.append(item(n, CGRect(x: 813 + CGFloat(i) * 60, y: 0, width: 24, height: 24))) }
    return MenuBarSnapshot(items: SystemOverflow.mark(items), capturedAt: Date())
}
private func res144(_ s: MenuBarSnapshot) -> [ResolvedItem] {
    s.items.map { i in ResolvedItem(item: i, key: i.isOverflowChevron ? chevK144 : ItemKey(storeKey: i.axIdentifier)!, confidence: .exact) }
}
private struct Obs144: MenuBarObserver { let m: Mode144; func observe() async throws -> [ResolvedItem] { res144(snap144(m)) } }
private struct Caps144: CapabilityProvider { func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) } }

@MainActor
private func rig144(_ record: [String], fail: Int, m: Mode144, now: (@Sendable () -> Date)? = nil) async -> (LayoutEngine, FakeActuator, EngineState, HoldBar) {
    let layout = Layout.placedAll(visible: record.map(k))
    let order = ["P1", "P2", "P3", "D1", "D2", "D3", "D4"].map(k)
    let act = FakeActuator(order: order, hidden: [], capabilities: Caps144(), makeSnapshot: { _, _ in snap144(m) })
    for n in 0..<fail { await act.failOnCall(n + 1, .mechanismFailed("the drag did not land")) }
    let st = EngineState(), bar = HoldBar()
    var cfg = LayoutEngine.Config.multiMove
    if let now { cfg.now = now }
    let e = LayoutEngine(observer: Obs144(m: m), actuator: act, store: InMemoryLayoutStore(layout), capabilities: Caps144(), state: st, resolveSnapshot: res144,
                         sleep: { _ in }, log: { bar.add($0) }, config: cfg)
    await e.start()
    return (e, act, st, bar)
}
private func movedKeys144(_ a: FakeActuator) async -> [String] {
    await a.moveSingleDrag.map { String($0.0.description.split(separator: ":").last ?? "?") }
}
@MainActor private func regular144(_ e: LayoutEngine, _ st: EngineState, n: Int = 8) async { await regularPasses(e, st, n: n) }

@MainActor
@Suite struct CarriedChevronNoEngineMovesTests {
    // B1: the chevron is carried on every scan, the record disagrees with the fold AND the drawn order: zero drags
    @Test func aCarriedChevronLaunchMakesNoEngineDrag() async {
        for ambiguous in [false, true] {
            let m = Mode144(); m.carried = true; m.ambiguous = ambiguous
            let (e, a, _, _) = await rig144(["D1", "P1", "D2", "P2", "D4", "P3", "D3"], fail: 0, m: m)
            for _ in 0..<10 { _ = await e.reconcileOnce() }
            #expect(await a.moveSingleDrag.isEmpty, "ambiguous=\(ambiguous)")
        }
    }

    @Test func aFreshScanThenCarriedScansStopsAtTheFreshOnesBudgetAndNeverGrows() async {
        let m = Mode144()
        let (e, a, _, _) = await rig144(["D1", "P1", "D2", "P2", "D4", "P3", "D3"], fail: 0, m: m)
        for _ in 0..<3 { _ = await e.reconcileOnce() }
        let before = await a.moveSingleDrag.count
        #expect(before <= 3)
        m.carried = true
        for _ in 0..<10 { _ = await e.reconcileOnce() }
        #expect(await a.moveSingleDrag.count == before)   // nothing on a carried scan
    }

    @Test func aMismatchOnCarriedScansIsNeverDraggedAndAFailureWhileCarriedSetsNoHold() async {
        let m = Mode144(); m.carried = true
        let (e, a, _, _) = await rig144(["P1", "P2", "P3", "D1", "D2", "D4", "D3"], fail: 50, m: m)
        for _ in 0..<20 { _ = await e.reconcileOnce() }
        #expect(await a.moveSingleDrag.isEmpty)
    }

    @Test func aPileRowIsNeverACheckOnACarriedScan() async {
        let m = Mode144()
        let (e, _, st, _) = await rig144(["P1", "P2", "P3", "D1", "D2", "D3", "D4"], fail: 0, m: m)
        _ = await e.reconcileOnce()
        m.carried = true
        for _ in 0..<3 { _ = await e.reconcileOnce() }
        for key in ["P1", "P2", "P3"].map(k) { #expect(st.observed.systemOverflow.contains(key) && st.perItem[key] == .notFitting, "\(key)") }
    }
}

@MainActor
@Suite struct RequestedPullOutFirstTests {
    // B2: a failing drawn mismatch holds the bar; the user then drops a folded key right of the fold: the folded key moves FIRST, one session
    @Test func aFoldDropWithAPendingFailingDrawnMismatchMovesTheFoldedKeyFirstExactlyOnce() async {
        let m = Mode144()
        let (e, a, _, _) = await rig144(["P1", "P2", "P3", "D1", "D2", "D4", "D3"], fail: 50, m: m)
        for _ in 0..<6 { _ = await e.reconcileOnce() }
        let before = await movedKeys144(a)
        #expect(before.count == 1)   // (sommelier-ejb.7: the hold is the core's; one failed drag, asserted by the count)
        await e.setLayout(Layout.placedAll(visible: ["P1", "P3", "D1", "P2", "D2", "D4", "D3"].map(k)), moved: [k("P2")])
        for _ in 0..<10 { _ = await e.reconcileOnce() }
        let after = await movedKeys144(a)
        #expect(after.count == before.count + 1 && after.last == "P2")   // exactly one more drag, and it is the folded key's
    }

    @Test func aFoldDropWithAVerifyingDrawnMismatchPullsTheFoldedKeyBeforeTheDrawnOne() async {
        let m = Mode144()
        let (e, a, _, _) = await rig144(["P1", "P2", "P3", "D1", "D2", "D3", "D4"], fail: 0, m: m)
        _ = await e.reconcileOnce()   // the record equals the bar: nothing to do, the fold is observed
        #expect(await a.moveSingleDrag.isEmpty)
        // the edit drops P2 right of the fold line AND leaves a drawn mismatch (D4 before D3) pending
        await e.setLayout(Layout.placedAll(visible: ["P1", "P3", "D1", "P2", "D2", "D4", "D3"].map(k)), moved: [k("P2")])
        for _ in 0..<10 { _ = await e.reconcileOnce() }
        let moves = await movedKeys144(a)
        #expect(moves.first == "P2")
        #expect(moves.filter { $0 == "P2" }.count == 1)
    }

    // the same through the real request path (regular passes), as live
    @Test func theRegularPassPathPullsTheFoldedKeyFirstAndOnlyOnce() async {
        let m = Mode144()
        let (e, a, st, _) = await rig144(["P1", "P2", "P3", "D1", "D2", "D4", "D3"], fail: 50, m: m)
        for _ in 0..<6 { _ = await e.reconcileOnce() }
        let before = await a.moveSingleDrag.count
        await e.setLayout(Layout.placedAll(visible: ["P1", "P3", "D1", "P2", "D2", "D4", "D3"].map(k)), moved: [k("P2")])
        await regular144(e, st)
        let after = await movedKeys144(a)
        #expect(after.count > before && after[before] == "P2" && after.filter { $0 == "P2" }.count == 1, "before=\(before) after=\(after)")   // first, once
        #expect(after.count <= before + 1 + 3)   // then at most the engine's budget of drawn moves
    }
}

@MainActor
@Suite struct RequestLifetimeTests {
    // B3: a drop left of the fold line clears the request at once; a later, unrelated drawn drop never makes the folded key move
    @Test func aLeftDropClearsTheRequestAndALaterDrawnDropNeverMovesTheFoldedKey() async {
        for regularPasses in [false, true] {
            let m = Mode144()
            let rec = ["P1", "D1", "D2", "P2", "D3", "P3", "D4"]
            let (e, a, st, _) = await rig144(rec, fail: 0, m: m)
            for _ in 0..<3 { _ = await e.reconcileOnce() }
            await e.setLayout(Layout.placedAll(visible: rec.map(k)), moved: [k("P1")])
            if regularPasses { await regular144(e, st) } else { for _ in 0..<10 { _ = await e.reconcileOnce() } }
            #expect(!(await movedKeys144(a)).contains("P1"))
            // ejb.15 (Wiring 3), CHANGED because the core decides: the user's first edit leaves P1 OWED in the core until the user's chain ends (`passBoundary`: the
            // end of the drained chain, or the start of a regular pass). In production the chain ends by itself; reconcileOnce never ends it, so the harness does.
            if !regularPasses { _ = await e.regularPassForTests() }
            await e.setLayout(Layout.placedAll(visible: ["D1", "P1", "D2", "P2", "D3", "P3", "D4"].map(k)), moved: [k("D1")])
            if regularPasses { await regular144(e, st) } else { for _ in 0..<10 { _ = await e.reconcileOnce() } }
            let moved = await movedKeys144(a)
            #expect(!moved.contains("P1") && !moved.contains("P2") && !moved.contains("P3"), "regular=\(regularPasses) moved=\(moved)")
        }
    }

    // a request that no pass could plan (the strip cannot be reached on a carried scan) ends with the user's pass
    @Test func aRequestNoPassCouldActOnDoesNotFireOnALaterPass() async {
        let m = Mode144()
        let rec = ["P1", "P2", "P3", "D1", "D2", "D3", "D4"]
        let (e, a, st, _) = await rig144(rec, fail: 0, m: m)
        _ = await e.reconcileOnce()
        m.carried = true
        await e.setLayout(Layout.placedAll(visible: ["P1", "P3", "D1", "P2", "D2", "D3", "D4"].map(k)), moved: [k("P2")])
        _ = await e.reconcileOnce()
        // the user's pull-out was withheld (carried scan): the drawn keys are in order, so ONLY the gate flag says the bar still differs from the record
        // (sommelier-ejb.7: `lastPlan.stoppedWhileDiffering` etc. are gone; the core's status below is the display)
        // ejb.16 CHANGED (display source): the menu/Arrange text is the core's status, not the old plan's. The core has not proven the bar not full, so it says "checking"; it never says matches.
        #expect(!st.isConverged && StatusLine.text(state: st, trusted: true, conflicting: nil) == ArrangeSections.checkingMenuBar)
        for _ in 0..<2 { _ = await e.reconcileOnce() }
        // ejb.15 (Wiring 3), CHANGED because the core decides: the user's chain ends here (production: `passBoundary` at the end of the drained chain; reconcileOnce
        // never ends it), which is what makes the request "end with the user's pass": the key is no longer owed, so a later fresh scan does not pull it out.
        _ = await e.regularPassForTests()
        m.carried = false
        for _ in 0..<10 { _ = await e.reconcileOnce() }
        #expect(!(await movedKeys144(a)).contains("P2"))
    }

    // a key merely dropped NEXT to is not the user's: only the subject (or a flipped-pair neighbour move) is exempt from the hold
    @Test func theTargetOfTheUsersDropIsNotExemptFromTheHold() async {
        let m = Mode144()
        let (e, a, _, _) = await rig144(["P1", "P2", "P3", "D1", "D2", "D4", "D3"], fail: 1, m: m)
        for _ in 0..<6 { _ = await e.reconcileOnce() }
        let calls1 = await a.moveSingleDrag.count
        #expect(calls1 == 1)
        // the user drops D1 (already first) beside the still-mismatched D4/D3 pair: D4 / D3 are not D1
        await e.setLayout(Layout.placedAll(visible: ["P1", "P2", "P3", "D1", "D2", "D4", "D3"].map(k)), moved: [k("D1")])
        for _ in 0..<10 { _ = await e.reconcileOnce() }
        #expect(await a.moveSingleDrag.count == 1)
    }
}

@MainActor
@Suite struct EngineBudgetTests {
    // B5: a hold with a live mismatch and a flapping fingerprint: at most 3 engine drags in total over 30 passes
    @Test func aFlappingFingerprintNeverGetsMoreThanThreeEngineDrags() async {
        let m = Mode144()
        let (e, a, _, bar) = await rig144(["P1", "P2", "P3", "D1", "D3", "D2", "D4"], fail: 200, m: m)
        for i in 0..<60 { m.d3 = (i / 3) % 2 == 0; _ = await e.reconcileOnce() }
        #expect(await a.moveSingleDrag.count <= 3)
        _ = bar   // gdu.144 item 2: the flap releases NOTHING (the core's hold, then its budget, stop it): the count above
    }

    // every engine drag counts, verified or failed; exhausted means quiet; a user edit gives the budget back
    @Test func theBudgetIsExactlyThreeVerifiedDragsAndAUserEditOrRetryResetsIt() async {
        let order = ["P1", "P2", "P3", "D1", "D2", "D3", "D4", "D5", "D6"].map(k)
        let record = Layout.placedAll(visible: order)
        let barOrder = ["P1", "P2", "P3", "D1", "D2", "D4", "D3", "D5", "D6"].map(k)   // the bar starts out disagreeing with the record
        let inner = FakeActuator(order: barOrder, hidden: [], capabilities: Caps144(), makeSnapshot: { o, _ in budgetSnapshot144(o) })
        let act = ScramblingActuator144(inner)
        let st = EngineState(), bar = HoldBar()
        var cfg = LayoutEngine.Config.multiMove
        cfg.maxKeyFailures = 1000; cfg.maxConsecutiveFailures = 1000
        let e = LayoutEngine(observer: BudgetObserver144(inner: inner), actuator: act, store: InMemoryLayoutStore(record), capabilities: Caps144(), state: st,
                             resolveSnapshot: { s in s.items.compactMap { i in ItemKey(storeKey: i.axIdentifier.isEmpty ? i.title : i.axIdentifier).map { ResolvedItem(item: i, key: $0, confidence: .exact) } } },
                             sleep: { _ in }, log: { bar.add($0) }, config: cfg)
        await e.start()
        for _ in 0..<50 { _ = await e.reconcileOnce() }
        let first = await act.moveCalls
        #expect(first == 3)
        for key in order { if case .moving? = st.perItem[key] { Issue.record("\(key) reads moving") } }
        // a user edit gives the budget back: the user's own move, then (on the regular passes that follow) up to three more engine drags
        await e.setLayout(Layout.placedAll(visible: ["P1", "P2", "P3", "D2", "D1", "D3", "D4", "D5", "D6"].map(k)), moved: [k("D2")])
        await regular144(e, st, n: 12)
        let total = await act.moveCalls
        #expect(total > 3 && total <= 3 + 1 + 3, "total=\(total)")
        // Retry also gives it back (up to 3 engine drags, plus the ONE user-authorised strip session it grants)
        await e.userRetry()
        await regular144(e, st, n: 12)
        let afterRetry = await act.moveCalls
        #expect(afterRetry > total && afterRetry <= total + 3 + 1, "total=\(total) afterRetry=\(afterRetry)")
    }
}

@MainActor
@Suite struct EngineBudgetMixedResultsTests {
    // failures hold the bar (so fewer than 3 may happen); never MORE than 3 whatever the mix, however the hold is released
    @Test func anyMixOfVerifiedAndFailedNeverExceedsThree() async {
        for failEvery in [2, 3, 4] {
            let order = ["P1", "P2", "P3", "D1", "D2", "D3", "D4", "D5", "D6"].map(k)
            let barOrder = ["P1", "P2", "P3", "D1", "D2", "D4", "D3", "D5", "D6"].map(k)
            let inner = FakeActuator(order: barOrder, hidden: [], capabilities: Caps144(), makeSnapshot: { o, _ in budgetSnapshot144(o) })
            let act = ScramblingActuator144(inner)
            await act.setFailEvery(failEvery)
            let st = EngineState(), bar = HoldBar()
            var cfg = LayoutEngine.Config.multiMove
            cfg.maxKeyFailures = 1000; cfg.maxConsecutiveFailures = 1000
            let e = LayoutEngine(observer: BudgetObserver144(inner: inner), actuator: act, store: InMemoryLayoutStore(Layout.placedAll(visible: order)), capabilities: Caps144(),
                                 state: st, resolveSnapshot: { s in s.items.compactMap { i in ItemKey(storeKey: i.axIdentifier.isEmpty ? i.title : i.axIdentifier).map { ResolvedItem(item: i, key: $0, confidence: .exact) } } },
                                 sleep: { _ in }, log: { bar.add($0) }, config: cfg)
            await e.start()
            for _ in 0..<50 { _ = await e.reconcileOnce() }
            let calls = await act.moveCalls
            #expect(calls <= 3 && calls >= 1, "failEvery=\(failEvery) calls=\(calls)")
        }
    }
}

private func budgetSnapshot144(_ order: [ItemKey]) -> MenuBarSnapshot {
    func item(_ key: ItemKey, _ frame: CGRect, chev: Bool = false) -> MenuBarItem {
        MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: key.description, axDescription: "", axIdentifier: chev ? "" : key.description,
                    frame: frame, source: .appExtras, isOnMenuBar: true, isOverflowChevron: chev, joinEvidence: .identifier)
    }
    var items: [MenuBarItem] = []
    let bar = order.filter { $0 != chevK144 }
    for (i, key) in bar.enumerated() {
        items.append(i < 3 ? item(key, CGRect(x: 772, y: 0, width: 24, height: 24)) : item(key, CGRect(x: 813 + CGFloat(i - 3) * 70, y: 0, width: 24, height: 24)))
    }
    items.append(item(chevK144, CGRect(x: 786, y: 0, width: 17, height: 24), chev: true))
    return MenuBarSnapshot(items: SystemOverflow.mark(items), capturedAt: Date())
}
private struct BudgetObserver144: MenuBarObserver {
    let inner: FakeActuator
    func observe() async throws -> [ResolvedItem] {
        budgetSnapshot144(await inner.order).items.compactMap { i in ItemKey(storeKey: i.axIdentifier.isEmpty ? i.title : i.axIdentifier).map { ResolvedItem(item: i, key: $0, confidence: .exact) } }
    }
}
/// Reports each drag as verified or failed in turn, then scrambles the drawn keys D3..D6 so the next pass finds a DIFFERENT mismatch: the
/// record is never realised, whatever the engine does.
private actor ScramblingActuator144: MenuBarActuator {
    let inner: FakeActuator
    private(set) var moveCalls = 0
    var failEvery = 0
    func setFailEvery(_ n: Int) { failEvery = n }
    private let perms: [[String]] = [["D4", "D3", "D5", "D6"], ["D5", "D6", "D3", "D4"], ["D6", "D5", "D4", "D3"], ["D3", "D5", "D4", "D6"], ["D4", "D6", "D5", "D3"]]
    init(_ inner: FakeActuator) { self.inner = inner }
    func move(_ key: ItemKey, relation: Relation) async -> ActuationResult {
        moveCalls += 1
        let n = moveCalls
        for (i, name) in perms[n % perms.count].enumerated() { await inner.displace(k(name), toIndex: 5 + i) }
        let snap = budgetSnapshot144(await inner.order)
        return failEvery > 0 && n % failEvery == 0 ? .failed(.mechanismFailed("the drag did not land"), snap) : .verified(snap)
    }
    func setHidden(_ key: ItemKey, _ hidden: Bool) async -> ActuationResult { await inner.setHidden(key, hidden) }
    var lastMoveTouchedMouse: Bool { get async { true } }   // every scripted move is a posted drag
    func applyHiddenBatch(_ changes: [ItemKey: Bool]) async -> ActuationResult { await inner.applyHiddenBatch(changes) }
    var lastBatchRespawned: Bool { get async { await inner.lastBatchRespawned } }
    var lastBatchUnconfirmed: Set<ItemKey> { get async { await inner.lastBatchUnconfirmed } }
    var lastBatchRefused: [ItemKey: String] { get async { await inner.lastBatchRefused } }
    var lastBatchUnsettled: [ItemKey: String] { get async { await inner.lastBatchUnsettled } }
}
