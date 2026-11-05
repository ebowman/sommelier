import Testing
import Foundation
@testable import SommelierCore

// 8z5.2: in macOSOwns the engine never plans or dispatches an order move; placedOnly keeps the gdu.89 behaviour.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private struct OpenCaps: CapabilityProvider { func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) } }
private final class Sink: @unchecked Sendable {
    private let lock = NSLock(); private var l: [String] = []
    func add(_ s: String) { lock.lock(); l.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return l }
}
private final class CountingStore: LayoutStore, @unchecked Sendable {
    private let lock = NSLock(); private var layout: Layout; private var n = 0
    init(_ l: Layout) { layout = l }
    func load() throws -> Layout { lock.lock(); defer { lock.unlock() }; return layout }
    func save(_ l: Layout) throws { lock.lock(); defer { lock.unlock() }; layout = l; n += 1 }
    var saves: Int { lock.lock(); defer { lock.unlock() }; return n }
}
/// Observes the fake actuator's truth; the subject's position is never corroborated while `bad` is set.
private final class BadJoinObserver: MenuBarObserver, @unchecked Sendable {
    let actuator: FakeActuator; let subject: ItemKey
    init(actuator: FakeActuator, subject: ItemKey) { self.actuator = actuator; self.subject = subject }
    func observe() async throws -> [ResolvedItem] {
        var items = FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden))
        for j in items.indices where items[j].key == subject { items[j].item.joinEvidence = .frameAmbiguous }
        return items
    }
}
private struct GoodObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] { FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden)) }
}
private func waitUntil(_ cond: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<600 { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
    return false
}

private struct R { let engine: LayoutEngine; let state: EngineState; let actuator: FakeActuator; let store: CountingStore; let sink: Sink }

@MainActor
private func rig(order: [String], hidden: Set<ItemKey> = [], layout: Layout, badSubject: ItemKey? = nil, config: LayoutEngine.Config = .init()) async -> R {
    let act = FakeActuator(order: order.map(k), hidden: hidden, capabilities: OpenCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let store = CountingStore(layout), state = EngineState(), sink = Sink()
    let obs: any MenuBarObserver = badSubject.map { BadJoinObserver(actuator: act, subject: $0) } ?? GoodObserver(actuator: act)
    let engine = LayoutEngine(observer: obs, actuator: act, store: store, capabilities: OpenCaps(), state: state, busy: { false },
                              resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { sink.add($0) }, config: config)
    await engine.start()
    return R(engine: engine, state: state, actuator: act, store: store, sink: sink)
}

@MainActor
@Suite struct OrderModeEngineTests {
    private func layout(_ m: OrderMode) -> Layout { Layout(visible: ["A", "C", "B", "D"].map(k), placed: [k("C")], orderMode: m) }
    private func waiting(_ s: EngineState) -> [ItemKey] { s.perItem.filter { if case .waitingForPosition = $0.value { true } else { false } }.map(\.key) }

    @Test func macOSOwnsPlansNothingForAnOutOfOrderBarWithPlacedKeys() async {
        let r = await rig(order: ["A", "B", "C", "D"], layout: layout(.macOSOwns))
        #expect(r.sink.lines.contains { $0.contains("order mode: macOS owns the order (1 remembered placements, not enforced)") })
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .converged && rep.actionCount == 0)
        #expect(await r.actuator.calls.isEmpty)
        #expect(await r.actuator.order == ["A", "B", "C", "D"].map(k))
        #expect(!r.sink.lines.contains { $0.contains("phase=order") || $0.contains("order: moving") || $0.contains("refusing move") })
        #expect(waiting(r.state).isEmpty && r.state.orderMoveNotice == nil && r.state.orderMoveReasons.isEmpty)
        #expect(r.state.orderMode == .macOSOwns)
        #expect(r.state.layout.placed == [k("C")])   // still recorded
    }

    @Test func macOSOwnsNeverWaitsForAnUncorroboratedPlacedKey() async {
        let r = await rig(order: ["A", "B", "C", "D"], layout: layout(.macOSOwns), badSubject: k("C"))
        _ = await r.engine.reconcileOnce()
        #expect(waiting(r.state).isEmpty)
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func placedOnlyMovesThePlacedKey() async {
        let r = await rig(order: ["A", "B", "C", "D"], layout: layout(.placedOnly))
        #expect(r.sink.lines.contains { $0.contains("order mode: placed items only (1 placed)") })
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .converged)
        #expect(await r.actuator.calls == [.move(k("C"), .after(k("A")))])
        #expect(await r.actuator.order == ["A", "C", "B", "D"].map(k))
    }

    @Test func setOrderModeUnchangedIsANoOp() async {
        let r = await rig(order: ["A", "B"], layout: layout(.macOSOwns))
        let before = await MainActor.run { r.state.layoutRevision }
        let stamp = await r.engine.setOrderMode(.macOSOwns)
        #expect(stamp.revision == before && r.state.layoutRevision == before)
        #expect(r.store.saves == 0)
    }

    @Test func setOrderModeChangePersistsBumpsLogsAndTriggersAPass() async {
        let r = await rig(order: ["A", "B", "C", "D"], layout: layout(.macOSOwns))
        let before = r.state.layoutRevision
        let passes = r.state.passesStarted
        let stamp = await r.engine.setOrderMode(.placedOnly)
        #expect(stamp.revision == before + 1 && r.state.layoutRevision == before + 1)
        #expect(r.store.saves == 1 && r.store.layoutOrderMode == .placedOnly)
        #expect(r.state.layout.placed == [k("C")] && r.state.orderMode == .placedOnly)
        #expect(r.sink.lines.contains { $0.contains("order mode: placed items only (1 placed)") })
        // the re-armed obligation is acted on by the pass the call requested
        #expect(await waitUntil { await r.actuator.order == ["A", "C", "B", "D"].map(k) })
        #expect(r.state.passesStarted > passes)
        // and back: placed stays recorded, nothing more moves
        let back = await r.engine.setOrderMode(.macOSOwns)
        #expect(back.revision == before + 2 && r.state.layout.placed == [k("C")] && r.store.saves == 2)
        #expect(r.sink.lines.contains { $0.contains("order mode: macOS owns the order (1 remembered placements, not enforced)") })
    }

    @Test func switchingToMacOSOwnsEndsAPositionWait() async {
        var c = LayoutEngine.Config(); c.positionRetryBase = .seconds(60); c.positionRetryCap = .seconds(60)
        let r = await rig(order: ["A", "B", "C", "D"], layout: layout(.placedOnly), badSubject: k("C"), config: c)
        _ = await r.engine.reconcileOnce()
        #expect(waiting(r.state) == [k("C")])
        await r.engine.setOrderMode(.macOSOwns)
        #expect(await waitUntil { await MainActor.run { self.waiting(r.state).isEmpty } })
        #expect(r.state.orderMoveNotice == nil && r.state.orderMoveReasons.isEmpty)
        #expect(await r.engine.positionWaitInfo.waiting == 0)
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func setOrderModeOnALayoutThatFailedToLoadChangesAndSavesNothing() async {
        struct BadStore: LayoutStore, Sendable {
            let saved = Counter()
            func load() throws -> Layout { throw CocoaError(.fileReadCorruptFile) }
            func save(_ layout: Layout) throws { saved.bump() }
        }
        final class Counter: @unchecked Sendable { private let l = NSLock(); private var n = 0; func bump() { l.lock(); n += 1; l.unlock() }; var count: Int { l.lock(); defer { l.unlock() }; return n } }
        let act = FakeActuator(order: [k("A")], hidden: [], capabilities: OpenCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        let store = BadStore(), state = EngineState(), sink = Sink()
        let engine = LayoutEngine(observer: GoodObserver(actuator: act), actuator: act, store: store, capabilities: OpenCaps(), state: state, busy: { false },
                                  resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { sink.add($0) })
        await engine.start()
        let before = state.layoutRevision
        let stamp = await engine.setOrderMode(.placedOnly)
        #expect(stamp.revision == before && state.layoutRevision == before)
        #expect(state.orderMode == .macOSOwns)
        #expect(store.saved.count == 0)
        #expect(sink.lines.contains { $0.contains("order mode: ignored, layout not loaded") })
    }

    @Test(arguments: [OrderMode.macOSOwns, .placedOnly]) func membershipIsTheSameInBothModes(_ m: OrderMode) async {
        let r = await rig(order: ["A", "B", "C"], layout: Layout(visible: ["A", "B"].map(k), hidden: [k("C")], placed: [k("A")], orderMode: m))
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .converged)
        #expect(await r.actuator.hidden == [k("C")])
        let order = await r.actuator.order
        #expect(order.contains(k("A")) && order.contains(k("B")))
    }

    @Test(arguments: [OrderMode.macOSOwns, .placedOnly]) func nonUserSetLayoutAndAdoptKeepTheMode(_ m: OrderMode) async {
        let r = await rig(order: ["A", "B"], layout: Layout(visible: ["A", "B"].map(k), placed: [k("A")], orderMode: m))
        // a scan-built layout (default mode) cannot change who owns the order
        await r.engine.setLayout(Layout(visible: ["B", "A"].map(k)), userPlacement: false)
        #expect(r.state.layout.orderMode == m)
        let adopted = ArrangeDrop.adopt(observed: ObservedOrder(onBar: ["B", "A"].map(k), parked: []), current: r.state.layout)
        #expect(adopted.orderMode == m)
    }
}

private extension CountingStore {
    var layoutOrderMode: OrderMode? { try? load().orderMode }
}
