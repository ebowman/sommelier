import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// gdu.131 / gdu.144: the strip hold has no time expiry and is cleared by Retry and by a layout edit touching a folded key. (gdu.131's two-observation
// release by a changed bar is gone since gdu.144: only user intent or the proof that the bar is not full releases it.)

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }

@MainActor
@Suite struct StripHoldDebounceTests {
    @Test func aHeldBarStaysQuietOverManyPassesWithZeroFurtherSessions() async {
        let r = await holdRig(failCalls: 10)
        for _ in 0..<10 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 1)
// sommelier-ejb.7, CHANGED because the core decides: the hold is the core's, not `stripOpenHold` / the "strip hold cleared" log; asserted through the move count.
        // (nothing is dragged again: the count above)
    }

    // gdu.144 item 2: the two-observation bar-change release (and its debounce state) is gone. A change of the bar, seen once or on any number of
    // consecutive passes, releases NOTHING: only user intent (Retry, Try again, an edit touching a folded key) or the proof that the bar is not full does.
    @Test func aBarChangeSeenOnceOrOftenNeverReleasesTheHold() async {
        let r = await holdRig(failCalls: 10)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 1)
        await r.actuator.removeItem(k("D4"))
        for _ in 0..<20 { _ = await r.engine.reconcileOnce() }     // the drawn count differs on every one of these passes
        #expect(await moveCalls(r.actuator) == 1)   // the changed bar released nothing
        await r.actuator.addItem(k("D4"))
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 1)
    }

    @Test func retryReleasesOnce() async {
        let r = await holdRig(failCalls: 10)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        await r.engine.userRetry()
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        let m3 = await moveCalls(r.actuator)
        #expect(m3 == 1)   // gdu.144: Retry releases the hold; the consumed request is not replayed
    }

    @Test func aLayoutEditReleasesOnce() async {
        let r = await holdRig(failCalls: 10)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        let edited = Layout.placedAll(visible: [k("D1"), k("P2"), k("P1"), k("D2"), k("D3"), k("P3"), k("D4")])
        _ = await r.engine.setLayout(edited, moved: [k("P2")])   // gdu.144: the user drops the folded P2 right of the fold line: its own attempt. gdu.136: an edit releases the hold only when it touches a folded key
        await r.engine.requestReconcile(reason: "trigger")   // gdu.136: a regular pass; a bare reconcileOnce right after an edit is a chained one
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        let m3 = await moveCalls(r.actuator)
        #expect(m3 == 2)
    }
}

// MARK: engine-level flapping through carried chevrons

private final class ScanMode: @unchecked Sendable {
    private let lock = NSLock()
    private var v: (big: Bool, carried: Bool) = (true, false)
    var dropD3 = false   // a real drawn change (D3 leaves the bar), set by the test between passes
    var value: (big: Bool, carried: Bool) { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

private struct AllCaps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
}

/// Big (14 folded): pile P1..P3 plus F1..F11 parked-folded. Small (11 folded): pile P1..P3 + X, F1..F7. Chevron and drawn (D1..D3) never change.
private func flapSnapshot(_ mode: ScanMode) -> MenuBarSnapshot {
    let m = mode.value
    let chev = ItemKey.module(name: MenuBarItem.overflowChevronName)
    func item(_ name: String, _ frame: CGRect, onBar: Bool = true, isChev: Bool = false) -> MenuBarItem {
        var i = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: isChev ? name : k(name).description, axDescription: "",
                            axIdentifier: isChev ? "" : k(name).description, frame: frame, source: .appExtras, isOnMenuBar: onBar, isOverflowChevron: isChev,
                            joinEvidence: .identifier)
        i.controlCenterAllowed = true
        if isChev { i.stale = m.carried; i.recentlyVerified = m.carried }
        return i
    }
    var items: [MenuBarItem] = []
    let pile = m.big ? ["P1", "P2", "P3"] : ["P1", "P2", "P3", "X"]
    for (i, n) in pile.enumerated() { items.append(item(n, CGRect(x: 700 + CGFloat(i) * 20, y: 0, width: 24, height: 24))) }
    for (i, n) in (mode.dropD3 ? ["D1", "D2"] : ["D1", "D2", "D3"]).enumerated() { items.append(item(n, CGRect(x: 813 + CGFloat(i) * 30, y: 0, width: 24, height: 24))) }
    items.append(item(chev.description, CGRect(x: 786, y: 0, width: 17, height: 24), isChev: true))
    for n in (1...(m.big ? 11 : 7)) { items.append(item("F\(n)", CGRect(x: 0, y: 0, width: 24, height: 24), onBar: false)) }
    return MenuBarSnapshot(items: SystemOverflow.mark(items), capturedAt: Date())
}

private func flapResolve(_ s: MenuBarSnapshot) -> [ResolvedItem] {
    s.items.map { i in
        ResolvedItem(item: i, key: i.isOverflowChevron ? .module(name: MenuBarItem.overflowChevronName) : ItemKey(storeKey: i.axIdentifier)!, confidence: .exact)
    }
}

private struct FlapObserver: MenuBarObserver {
    let mode: ScanMode
    func observe() async throws -> [ResolvedItem] { flapResolve(flapSnapshot(mode)) }
}

@MainActor
private func flapRig() async -> (LayoutEngine, FakeActuator, ScanMode, HoldBar, EngineState) {
    let mode = ScanMode()
        let key: (String) -> ItemKey = { k($0) }
        let order = ["P1", "P2", "P3", "D1", "D2", "D3"].map(key)
        // X (folded only in the small scans, absent from the hold's folded set) wants to sit between the drawn keys; D3 / D2 are SWAPPED in the record: a live drawn
        // mismatch that only the hold keeps the engine from dragging (gdu.144: a re-dispatch would show as a second move)
        let layout = Layout.placedAll(visible: ["D1", "X", "P1", "D3", "P2", "D2", "P3"].map(key) + (1...11).map { key("F\($0)") })
        let act = FakeActuator(order: order, hidden: [], capabilities: AllCaps(), makeSnapshot: { _, _ in flapSnapshot(mode) })
        for n in 0..<20 { await act.failOnCall(n + 1, .mechanismFailed(ActuationError.stripOpenFailureMessage)) }
        let state = EngineState(), bar = HoldBar()
        let engine = LayoutEngine(observer: FlapObserver(mode: mode), actuator: act, store: InMemoryLayoutStore(layout), capabilities: AllCaps(),
                                  state: state, resolveSnapshot: flapResolve, sleep: { _ in }, log: { bar.add($0) }, config: .multiMove)
        await engine.start()
        _ = await engine.reconcileOnce()                                     // gdu.144: observe the bar, then the USER drops P1 (the one pull-out attempt)
        await engine.setLayout(layout, moved: [key("P1")])
    return (engine, act, mode, bar, state)
}

@MainActor
@Suite struct StripHoldFlappingEngineTests {
    @Test func foldedFlappingAndCarriedChevronsNeverReleaseOrReDispatch() async {
        let (engine, act, mode, bar, state) = await flapRig()
        let key: (String) -> ItemKey = { k($0) }
        for _ in 0..<4 { _ = await engine.reconcileOnce() }                  // big, fresh chevron: the hold is set at 14 folded
        await regularPasses(engine, state, n: 2)                             // gdu.144: the regular pass plans the live D3 / D2 mismatch; only the hold withholds it
        let first = await moveCalls(act)
        // ejb.19: 1 again (ejb.15 had raised it to 2). The adapter holds the first complete read of a full bar until a second agrees, so the core makes no drag on
        // its first pass; the one drag is the USER's pull-out of P1. The re-dispatch guard is unchanged: no second.
        #expect(first == 1)   // (sommelier-ejb.7: the folded count 14 is the core's pileCount, asserted in CoreStatusTextTests)
        // 10 passes: folded 14 -> 11 -> 14, at least two passes with only a carried chevron, X folded now but not in the hold's set
        let script: [(big: Bool, carried: Bool)] = [(false, false), (true, false), (false, true), (true, true), (false, false), (true, true),
                                                    (false, false), (true, true), (false, true), (false, false)]
        for m in script {
            mode.value = m
            _ = await engine.reconcileOnce()
            #expect(state.coreStatus != .moving)
        }
        let moves = await moveCalls(act)
        #expect(moves == 1)   // a re-dispatch would have been a second drag
        #expect(state.perItem.values.allSatisfy { st in
            switch st { case .pending, .moving, .unsupported: false; default: true }
        })
    }
}
