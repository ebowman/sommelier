import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// gdu.131: the strip hold compares chevron + drawn only (never the folded set), releases a change only when seen on two consecutive
// observations, has no time expiry, and is cleared by Retry and by a layout edit.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }

private func clearedLines(_ r: HoldRig) -> Int { r.bar.lines.filter { $0.contains("strip hold cleared") }.count }

@MainActor
@Suite struct StripHoldDebounceTests {
    @Test func theFingerprintIgnoresTheFoldedSetAndKeepsTheChevronAndDrawn() {
        func obs(pile: [String]) -> ObservedOrder {
            let c = ItemKey.module(name: MenuBarItem.overflowChevronName)
            return ObservedOrder(onBar: pile.map(k) + [k("D1"), k("D2"), k("D3"), c], parked: [], systemOverflow: Set(pile.map(k)), overflowChevron: c)
        }
        let a = BarFingerprint(obs(pile: ["P1", "P2", "P3"]))
        // 14 -> 11 folded flapping with the same drawn count and chevron
        let big = obs(pile: (1...14).map { "P\($0)" }), small = obs(pile: (1...11).map { "P\($0)" })
        #expect(BarFingerprint(big) == BarFingerprint(small))
        #expect(BarFingerprint.folded(big).count == 14 && BarFingerprint.folded(small).count == 11)
        #expect(a == BarFingerprint(hasChevron: true, drawn: 3))
        #expect(a != BarFingerprint(hasChevron: true, drawn: 4) && a != BarFingerprint(hasChevron: false, drawn: 3))
    }

    @Test func aHeldBarStaysQuietOverManyPassesWithZeroFurtherSessions() async {
        let r = await holdRig(failCalls: 10)
        for _ in 0..<10 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 1)
        let held = await r.engine.stripOpenHold != nil
        #expect(held && clearedLines(r) == 0)
    }

    @Test func aSinglePassDrawnBlipDoesNotRelease() async {
        let r = await holdRig(failCalls: 10)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 1)
        await r.actuator.removeItem(k("D4"))
        var seen = false
        for _ in 0..<6 where !seen { _ = await r.engine.reconcileOnce(); seen = await r.engine.stripPending != nil }
        #expect(seen)                                              // one plan saw the changed bar
        let c1 = await r.engine.stripPending?.count, h1 = await r.engine.stripOpenHold != nil
        #expect(c1 == 1 && h1)
        await r.actuator.addItem(k("D4"))                          // ... and the next one sees the old bar again
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        let p2 = await r.engine.stripPending == nil, h2 = await r.engine.stripOpenHold != nil, m2 = await moveCalls(r.actuator)
        #expect(p2 && h2 && m2 == 1 && clearedLines(r) == 0)
    }

    @Test func aDrawnChangeOnTwoConsecutiveObservationsReleasesExactlyOnce() async {
        let r = await holdRig(failCalls: 10)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 1)
        await r.actuator.removeItem(k("D4"))
        for _ in 0..<8 { _ = await r.engine.reconcileOnce() }
        #expect(r.bar.lines.filter { $0.contains("strip hold cleared (the bar changed: drawn 4->3, chevron true->true)") }.count == 1)
        #expect(await moveCalls(r.actuator) == 2)                  // one more session, then held again on the new bar
    }

    @Test func retryReleasesOnce() async {
        let r = await holdRig(failCalls: 10)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        await r.engine.clearFailures()
        let h3 = await r.engine.stripOpenHold == nil
        #expect(h3 && clearedLines(r) == 1)
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        let m3 = await moveCalls(r.actuator)
        #expect(m3 == 2 && clearedLines(r) == 1)
    }

    @Test func aLayoutEditReleasesOnce() async {
        let r = await holdRig(failCalls: 10)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await r.engine.stripOpenHold != nil)
        let edited = Layout.placedAll(visible: [k("P1"), k("D1"), k("D2"), k("P2"), k("D3"), k("P3"), k("D4")])
        _ = await r.engine.setLayout(edited)
        #expect(r.bar.lines.contains { $0.contains("strip hold cleared (layout edit)") } && !r.bar.lines.contains { $0.contains("strip hold cleared (retry)") })
        let h3 = await r.engine.stripOpenHold == nil
        #expect(h3 && clearedLines(r) == 1)
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        let m3 = await moveCalls(r.actuator)
        #expect(m3 == 2 && clearedLines(r) == 1)
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
        // X (folded only in the small scans, absent from the hold's folded set) wants to sit between the drawn keys
        let layout = Layout.placedAll(visible: ["D1", "X", "P1", "D2", "P2", "D3", "P3"].map(key) + (1...11).map { key("F\($0)") })
        let act = FakeActuator(order: order, hidden: [], capabilities: AllCaps(), makeSnapshot: { _, _ in flapSnapshot(mode) })
        for n in 0..<20 { await act.failOnCall(n + 1, .mechanismFailed(ActuationError.stripOpenFailureMessage)) }
        let state = EngineState(), bar = HoldBar()
        let engine = LayoutEngine(observer: FlapObserver(mode: mode), actuator: act, store: InMemoryLayoutStore(layout), capabilities: AllCaps(),
                                  state: state, resolveSnapshot: flapResolve, sleep: { _ in }, log: { bar.add($0) }, config: .multiMove)
        await engine.start()
    return (engine, act, mode, bar, state)
}

@MainActor
@Suite struct StripHoldFlappingEngineTests {
    @Test func aCarriedChevronNeitherCountsNorResetsAPendingDrawnChange() async {
        let (engine, act, mode, bar, _) = await flapRig()
        for _ in 0..<4 { _ = await engine.reconcileOnce() }
        mode.dropD3 = true                                                    // a real drawn change, 3 -> 2 ...
        var seen = false
        for _ in 0..<6 where !seen { _ = await engine.reconcileOnce(); seen = await engine.stripPending != nil }
        #expect(seen)
        mode.value = (false, true)                                            // ... a carried-chevron scan in between ...
        for _ in 0..<2 { _ = await engine.reconcileOnce() }
        let pendingKept = await engine.stripPending?.count == 1
        #expect(pendingKept)
        mode.value = (true, false)                                            // ... then the same change again: second consecutive sighting
        for _ in 0..<2 { _ = await engine.reconcileOnce() }
        #expect(bar.lines.filter { $0.contains("strip hold cleared (the bar changed: drawn 3->2") }.count == 1)
        _ = act
    }

    @Test func foldedFlappingAndCarriedChevronsNeverReleaseOrReDispatch() async {
        let (engine, act, mode, bar, state) = await flapRig()
        let key: (String) -> ItemKey = { k($0) }
        for _ in 0..<4 { _ = await engine.reconcileOnce() }                  // big, fresh chevron: the hold is set at 14 folded
        let set = await engine.stripOpenHold != nil, first = await moveCalls(act)
        #expect(set && first == 1 && state.lastPlan.stripHoldFolded == 14)
        // 10 passes: folded 14 -> 11 -> 14, at least two passes with only a carried chevron, X folded now but not in the hold's set
        let script: [(big: Bool, carried: Bool)] = [(false, false), (true, false), (false, true), (true, true), (false, false), (true, true),
                                                    (false, false), (true, true), (false, true), (false, false)]
        var heldX = 0
        for m in script {
            mode.value = m
            _ = await engine.reconcileOnce()
            if !m.carried, !m.big, state.lastPlan.stripHeld.contains(key("X")) { heldX += 1 }
            #expect(state.lastPlan.moving.isEmpty)
        }
        let stillHeld = await engine.stripOpenHold != nil, moves = await moveCalls(act)
        #expect(stillHeld && moves == 1)
        #expect(!bar.lines.contains { $0.contains("strip hold cleared") })
        #expect(bar.lines.contains { $0.contains(Reconciler.stripUnavailableSkipReason) })
        #expect(heldX >= 1)                                                   // the fold move of X was recognised as held and skipped
        #expect(state.lastPlan.stripHeld.allSatisfy { state.perItem[$0] == .notFitting })
    }
}
