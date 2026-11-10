import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// gdu.134: an overfull bar. Nothing is ever aimed across the fold at a folded key (no push-in, no substitute target); a cross-fold move
// that did not hold sets the bar-level hold (one fold-crossing drag per bar state); the hold text leads the status line.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }

// MARK: a. planner (the 08:21:53 observation)

private func obs(_ bar: [String], ovf: [String]) -> ObservedOrder {
    ObservedOrder(onBar: bar.map(k), parked: [], systemOverflow: Set(ovf.map(k)), overflowChevron: k("ch"))
}

@Suite struct NeverAimAtAFoldedKeyTests {
    private func caps(immovable: Set<String> = []) -> @Sendable (ItemKey) -> Capability {
        { key in
            if key == k("ch") || immovable.contains(where: { k($0) == key }) { return Capability(canMove: false, canHide: false) }
            return Capability(canMove: true, canHide: true)
        }
    }
    private let record = Layout(visible: ["gate", "cpu", "weather", "np", "tm"].map(k), hidden: [], alwaysHidden: [])

}

// MARK: c. engine

@MainActor
@Suite struct CrossFoldHoldEngineTests {
    @Test func aCrossFoldDragThatDidNotHoldIsOneActuatorCallThenTheHold() async {
        let r = await holdRig(failCalls: 20, message: ActuationError.stripMoveDidNotHoldMessage)
        for _ in 0..<8 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 1)
        #expect(!r.bar.lines.contains { $0.contains("giving up") })
        #expect(r.bar.lines.contains { $0.contains("a move across the fold did not hold") })
        // gdu.144 rule 5: the user's dropped key says what happened; the hold is the bar's
        guard case .failed(let e)? = r.state.perItem[k("P1")] else { Issue.record("P1 should read failed, got \(String(describing: r.state.perItem[k("P1")]))"); return }
        #expect(ArrangeSections.plainReason(ArrangeSections.describe(e)) == "macOS put it back behind «; hide something to make room")
        // Retry releases the hold; the request was consumed by its one attempt, so nothing is dragged again (gdu.144)
        await r.engine.userRetry()
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 1)
    }

    @Test func aVerifiedCrossFoldMoveThatIsMovedBackSetsTheHoldNotAnAttempt() async {
        let r = await holdRig(failCalls: 0)
        var passes = 0
        while await moveCalls(r.actuator) == 0, passes < 6 { _ = await r.engine.reconcileOnce(); passes += 1 }
        let n = await moveCalls(r.actuator)
        #expect(n >= 1)
        // macOS puts everything back at once: the order the record started from
        for key in [k("P1"), k("P2"), k("P3"), k("D1"), k("D2"), k("D3"), k("D4")].reversed() { await r.actuator.displace(key, toIndex: 0) }
        _ = await r.engine.reconcileOnce()
        #expect(await moveCalls(r.actuator) == n)   // no second drag
        #expect(!r.bar.lines.contains { $0.contains("giving up") })
        // gdu.144: the pull-out request was consumed by its one attempt, so a revert is never planned again (nothing to hold, nothing to strike)
        #expect(!r.bar.lines.contains { $0.contains("planned again") })
    }
}

// MARK: engine rigs (own snapshot: the first `pile` keys of the order are folded behind the chevron)

private let chevKey134 = ItemKey.module(name: MenuBarItem.overflowChevronName)

private func snapshot134(order: [ItemKey], pile: Int) -> MenuBarSnapshot {
    func item(_ key: ItemKey, _ frame: CGRect, chev: Bool = false) -> MenuBarItem {
        MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: key.description, axDescription: "", axIdentifier: chev ? "" : key.description,
                    frame: frame, source: .appExtras, isOnMenuBar: true, isOverflowChevron: chev, joinEvidence: .identifier)
    }
    var items: [MenuBarItem] = []
    for (i, key) in order.enumerated() where key != chevKey134 {
        items.append(i < pile ? item(key, CGRect(x: 772, y: 0, width: 24, height: 24)) : item(key, CGRect(x: 813 + CGFloat(i - pile) * 30, y: 0, width: 24, height: 24)))
    }
    items.append(item(chevKey134, CGRect(x: 786, y: 0, width: 17, height: 24), chev: true))
    return MenuBarSnapshot(items: SystemOverflow.mark(items), capturedAt: Date())
}

private struct Caps134: CapabilityProvider {
    let immovable: Set<ItemKey>
    func capability(for key: ItemKey) -> Capability { immovable.contains(key) ? Capability(canMove: false, canHide: false) : Capability(canMove: true, canHide: true) }
}

private struct Observer134: MenuBarObserver {
    let actuator: FakeActuator
    let pile: Int
    func observe() async throws -> [ResolvedItem] {
        let s = snapshot134(order: await actuator.order, pile: pile)
        return s.items.compactMap { i in ItemKey(storeKey: i.axIdentifier.isEmpty ? i.title : i.axIdentifier).map { ResolvedItem(item: i, key: $0, confidence: .exact) } }
    }
}

/// Delegates to a FakeActuator, but macOS "moves it back" at once: after a verified move the order is restored and the reported snapshot shows it.
private final class RevertingActuator: MenuBarActuator, @unchecked Sendable {
    let inner: FakeActuator
    let pile: Int
    init(_ inner: FakeActuator, pile: Int) { self.inner = inner; self.pile = pile }
    func move(_ key: ItemKey, relation: Relation) async -> ActuationResult {
        let before = await inner.order
        let r = await inner.move(key, relation: relation)
        guard case .verified = r else { return r }
        for (i, kk) in before.enumerated().reversed() { await inner.displace(kk, toIndex: 0); _ = i }
        return .verified(snapshot134(order: await inner.order, pile: pile))
    }
    func setHidden(_ key: ItemKey, _ hidden: Bool) async -> ActuationResult { await inner.setHidden(key, hidden) }
    func applyHiddenBatch(_ changes: [ItemKey: Bool]) async -> ActuationResult { await inner.applyHiddenBatch(changes) }
    var lastBatchRespawned: Bool { get async { await inner.lastBatchRespawned } }
    var lastBatchUnconfirmed: Set<ItemKey> { get async { await inner.lastBatchUnconfirmed } }
    var lastBatchRefused: [ItemKey: String] { get async { await inner.lastBatchRefused } }
    var lastBatchUnsettled: [ItemKey: String] { get async { await inner.lastBatchUnsettled } }
}

private struct Rig134 { let engine: LayoutEngine; let state: EngineState; let fake: FakeActuator; let bar: HoldBar }

@MainActor
private func rig134(order: [ItemKey], pile: Int, layout: Layout, immovable: Set<ItemKey> = [], reverting: Bool = false) async -> Rig134 {
    let fake = FakeActuator(order: order, hidden: [], capabilities: Caps134(immovable: immovable), makeSnapshot: { o, _ in snapshot134(order: o, pile: pile) })
    let actuator: any MenuBarActuator = reverting ? RevertingActuator(fake, pile: pile) : fake
    let state = EngineState()
    let bar = HoldBar()
    let engine = LayoutEngine(observer: Observer134(actuator: fake, pile: pile), actuator: actuator, store: InMemoryLayoutStore(layout), capabilities: Caps134(immovable: immovable),
                              state: state, resolveSnapshot: { s in
                                  s.items.compactMap { i in ItemKey(storeKey: i.axIdentifier.isEmpty ? i.title : i.axIdentifier).map { ResolvedItem(item: i, key: $0, confidence: .exact) } } },
                              sleep: { _ in }, log: { bar.add($0) }, config: .multiMove)
    await engine.start()
    return Rig134(engine: engine, state: state, fake: fake, bar: bar)
}

@MainActor
@Suite struct OverfullEngineTests {
    @Test func theWeatherShapeNeverReadsMovingAndNothingIsDragged() async {
        let (gate, cpu, weather, np, tm) = (k("gate"), k("cpu"), k("weather"), k("np"), k("tm"))
        let r = await rig134(order: [np, gate, cpu, weather, tm], pile: 1, layout: Layout.placedAll(visible: [gate, cpu, weather, np, tm]), immovable: [np])
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        #expect(await r.fake.calls.isEmpty)
        // gdu.144: the fold is macOS's decision; the drawn weather is simply in place (no unsupported verdict for where NowPlaying folded)
        #expect(r.state.perItem[weather] == .inPlace)
        let obs = ObservedOrder(resolved: snapshot134(order: await r.fake.order, pile: 1).items.compactMap { i in
            ItemKey(storeKey: i.axIdentifier.isEmpty ? i.title : i.axIdentifier).map { ResolvedItem(item: i, key: $0, confidence: .exact) } })
        let content = ArrangeSections.make(observed: obs, layout: Layout.placedAll(visible: [gate, cpu, weather, np, tm]), items: [:], perItem: r.state.perItem,
                                           capabilities: { Caps134(immovable: [np]).capability(for: $0) })
        let row = content.visible.rows.first { $0.key == weather }
        if case .cannotPlace? = row?.barState { Issue.record("weather row must not be a warning") }
        let line = CoreStatusText.text(state: r.state, trusted: true, conflicting: nil)   // sommelier-ejb.7: the line is the core's (ArrangeSections.statusLine is gone)
        #expect(!line.hasPrefix("Moving") && !line.contains("Moving"))
        #expect(!line.contains("can't be placed"))
    }

    @Test func aCrossFoldMoveRevertedWithinThePassSetsTheHoldWithNoSecondDragAndNoAttempt() async {
        let (p1, p2, p3, d1, d2, d3, d4) = (k("P1"), k("P2"), k("P3"), k("D1"), k("D2"), k("D3"), k("D4"))
        let layout = Layout.placedAll(visible: [d1, p1, d2, p2, d3, p3, d4])
        let r = await rig134(order: [p1, p2, p3, d1, d2, d3, d4], pile: 3, layout: layout, reverting: true)
        _ = await r.engine.reconcileOnce()
        await r.engine.setLayout(layout, moved: [p1])   // gdu.144: the user drops P1 (the only pull-out there is)
        for _ in 0..<8 { _ = await r.engine.reconcileOnce() }
        let moves = await r.fake.calls.filter { if case .move = $0 { true } else { false } }.count
        #expect(moves == 1)   // one drag; macOS puts it back; the consumed request is not planned again
        #expect(!r.bar.lines.contains { $0.contains("giving up") || $0.contains("was verified but is planned again") })
    }
}
