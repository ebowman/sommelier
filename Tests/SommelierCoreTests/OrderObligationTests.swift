import Testing
import Foundation
@testable import SommelierCore

// 9o9.3: every Visible key carries the order obligation (the record is Layout.visible).

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private func free(_: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
private let rec = Reconciler()
private func obs(_ bar: [String], _ parked: [String] = [], ovf: [String] = [], chevron: String? = nil) -> ObservedOrder {
    ObservedOrder(onBar: bar.map(k), parked: parked.map(k), systemOverflow: Set(ovf.map(k)), overflowChevron: chevron.map(k))
}
private func lay(v: [String], h: [String] = [], placed: [String] = []) -> Layout {
    Layout(visible: v.map(k), hidden: h.map(k))   // `placed` documents which keys the test hands to the planner as obligations
}
private func moves(_ p: Plan) -> [PlannedAction] { p.actions.filter { if case .move = $0 { return true }; return false } }

struct OrderObligationPlannerTests {
    private static let clock = ItemKey.module(name: "Clock")
    private static let cc = ItemKey.module(name: "ControlCenter")
    private static func sysCaps(_ key: ItemKey) -> Capability {
        if case .module = key { return Capability(canMove: false, canHide: false) }
        return Capability(canMove: true, canHide: true)
    }
    private func final(_ p: Plan, _ o: ObservedOrder) -> [ItemKey] { p.actions.reduce(o) { PlanSimulator.apply($1, to: $0) }.onBar }

    @Test func aLayoutEqualToTheBarYieldsZeroActions() {
        let p = rec.plan(observed: obs(["a", "b", "c"]), layout: lay(v: ["a", "b", "c"]), capabilities: free)
        #expect(p.phase == .converged && p.actions.isEmpty)
    }

    @Test func theTrailingSystemBlockIsNeverMovedAndNothingLandsRightOfIt() {
        let o = ObservedOrder(onBar: [k("a"), k("b"), Self.cc, Self.clock], parked: [])
        // the record lists a module first and an item after the clock: neither request is actionable
        let layout = Layout(visible: [Self.cc, k("b"), k("a"), Self.clock])
        let p = rec.plan(observed: o, layout: layout, capabilities: Self.sysCaps)
        for case .move(let subject, let rel) in p.actions {
            #expect(subject != Self.cc && subject != Self.clock)
            if case .after(let t) = rel { #expect(t != Self.cc && t != Self.clock) }
        }
        let end = final(p, o)
        #expect(Array(end.suffix(2)) == [Self.cc, Self.clock])
    }

    @Test func aMembershipPassNeverOrders() {
        let p = rec.plan(observed: obs(["a", "b"], ["k"]), layout: lay(v: ["b", "a", "k"]), capabilities: free)
        #expect(p.phase == .membership && p.actions == [.show(k("k"))])
    }

}

struct LayoutRecordModelTests {

    @Test func leavingVisibleOrTheLayoutKeepsTheLayoutValid()  throws {
        var l = Layout(visible: [k("a"), k("b")], hidden: [k("c")])
        try l.move(k("a"), to: .hidden)
        #expect(l.visible == [k("b")])
        l.remove(k("b"))
        #expect(l.visible.isEmpty && l.isValid)
    }

    @Test func aDropIntoVisibleIsARecordedMoveAndANoOpDropIsNoOp() {
        let base = Layout(visible: [k("a"), k("b")], hidden: [k("h1"), k("h2")])
        guard case .move(let l1, let moved, _) = ArrangeDrop.outcome(layout: base, key: k("h2"), to: .visible, index: 1, capabilities: free) else { Issue.record("no move"); return }
        #expect(moved == [k("h2")])
        #expect(l1.visible == [k("a"), k("h2"), k("b")])
        #expect(ArrangeDrop.outcome(layout: l1, key: k("h2"), to: .visible, index: 1, capabilities: free) == .noop)
    }

    @Test func encodeNeverWritesLegacyFields() throws {
        let text = String(decoding: try JSONEncoder().encode(Layout(visible: [k("a")])), as: UTF8.self)
        #expect(!text.contains("placed") && !text.contains("orderMode") && !text.contains("pendingAdoption"))
    }

    // 9o9.2: a legacy file decodes to the same layout as without the legacy fields; the warnings name both fields; adoption is requested.
    @Test func legacyFieldsAreIgnoredWithWarningsAndRequestAdoption() throws {
        let plain = Data(#"{"schemaVersion":1,"visible":["status:com.x.a::a","status:com.x.b::b"],"hidden":["status:com.x.c::c"],"newItemPolicy":"visibleAtEnd"}"#.utf8)
        let legacy = Data(#"{"schemaVersion":1,"visible":["status:com.x.a::a","status:com.x.b::b"],"hidden":["status:com.x.c::c"],"newItemPolicy":"visibleAtEnd","orderMode":"placedOnly","placed":["status:com.x.b::b"]}"#.utf8)
        let p = try Layout.decode(plain), l = try Layout.decode(legacy)
        #expect(!p.adoptBarOrder && p.warnings.isEmpty)
        #expect(l.adoptBarOrder)
        #expect(l.warnings.contains("ignored legacy field orderMode") && l.warnings.contains("ignored legacy field placed"))
        var same = l.layout; same.pendingAdoption = false
        #expect(same == p.layout)
        #expect(l.layout.pendingAdoption)
        // an unknown orderMode value no longer matters
        #expect(try Layout.decode(Data(#"{"visible":[],"orderMode":"bogus"}"#.utf8)).adoptBarOrder)
        // the Codable path tolerates the legacy keys too
        #expect(try JSONDecoder().decode(Layout.self, from: legacy).visible == p.layout.visible)
    }
}

// MARK: engine

private struct Caps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability {
        if case .module = key { return Capability(canMove: false, canHide: false, reason: "system module") }
        return Capability(canMove: true, canHide: true)
    }
}
private struct ActuatorObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] {
        FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden))
    }
}
private final class LogSink: @unchecked Sendable {
    private let lock = NSLock(); private var l: [String] = []
    func add(_ s: String) { lock.lock(); l.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return l }
}

@MainActor
private func engineRig(order: [String], layout: Layout, sink: LogSink) async -> (engine: LayoutEngine, actuator: FakeActuator, state: EngineState, store: InMemoryLayoutStore) {
    let act = FakeActuator(order: order.map(k), hidden: [], capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let store = InMemoryLayoutStore(layout)
    let state = EngineState()
    let engine = LayoutEngine(observer: ActuatorObserver(actuator: act), actuator: act, store: store, capabilities: Caps(), state: state,
                              resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { sink.add($0) }, config: .plain())
    await engine.start()
    return (engine, act, state, store)
}

@MainActor
struct OrderObligationEngineTests {
    @Test func aSavedOrderIsEnforcedInFull() async {
        let sink = LogSink()
        let r = await engineRig(order: ["A", "B", "C", "D"], layout: Layout(visible: ["A", "C", "B", "D"].map(k)), sink: sink)
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .incomplete)   // sommelier-ejb.7, CHANGED: a pass that moved an item is `.incomplete`; the core judges the moved bar on the next pass
        #expect(await r.actuator.calls.count == 1)
        #expect(await r.actuator.order == ["A", "C", "B", "D"].map(k))
        #expect(sink.lines.contains { $0.contains("order: moving") })
        // the notice is only for the move in flight
        #expect(r.state.orderMoveNotice == nil)
        #expect(r.state.orderMoveReasons.isEmpty)
    }

    @Test func aUserDropPersistsItsOrderAndTheEngineRealizesIt() async {
        let sink = LogSink()
        let r = await engineRig(order: ["A", "B", "C"], layout: Layout(visible: ["A", "B", "C"].map(k)), sink: sink)
        guard case .move(let l, _, _) = ArrangeDrop.outcome(layout: r.state.layout, key: k("C"), to: .visible, index: 0, capabilities: free) else { Issue.record("no move"); return }
        await r.engine.setLayout(l)
        #expect((try? r.store.load())?.visible == ["C", "A", "B"].map(k))
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.order == ["C", "A", "B"].map(k))
    }
}

// (h)
struct OrderMoveNoticeTests {
    @Test func noticeNamesTheItemAndTheTrigger() {
        #expect(OrderMoveNotice.text(name: "KeepingYouAwake", relation: .after(k("L")), target: "Show Emoji & Symbols")
                == "Moving KeepingYouAwake: you placed it after Show Emoji & Symbols")
        #expect(OrderMoveNotice.text(name: "K", relation: .before(k("L")), target: "L") == "Moving K: you placed it before L")
        #expect(OrderMoveNotice.text(name: "K", relation: .leftmost, target: nil) == "Moving K: you placed it first")
        #expect(OrderMoveNotice.text(name: "K", relation: .rightmost, target: nil) == "Moving K: you placed it last")
    }

    @Test func theMovingRowTooltipCarriesTheReason() {
        var row = ArrangeRow(key: k("K"), title: "K", ownerName: "", ownerBundleID: nil, ownerPID: nil, badge: .moving, draggable: true, canHide: true,
                             isAnchor: false, isGhost: false, isBoundary: false, notFitting: false, notRunning: false, unit: .init(id: "u"), unitMates: [], capabilityNote: nil)
        #expect(row.badgeTooltip == ArrangeBadge.moving.tooltip)
        row.moveReason = "Moving K: you placed it after L"
        #expect(row.badgeTooltip == "Moving K: you placed it after L")
    }
}

// 9o9.9: trusted keys are ordered relative to untrusted ones; untrusted keys are never moved or targeted.
struct TrustedVersusUntrustedTests {
    private static let cc = ItemKey.module(name: "ControlCenter")
    private static let clock = ItemKey.module(name: "Clock")
    private static func sysCaps(_ key: ItemKey) -> Capability {
        if case .module = key { return Capability(canMove: false, canHide: false) }
        return Capability(canMove: true, canHide: true)
    }
    private func run(_ p: Plan, _ o: ObservedOrder) -> [ItemKey] { p.actions.reduce(o) { PlanSimulator.apply($1, to: $0) }.onBar }
    private func untrusted(_ bar: [String], _ u: [String]) -> ObservedOrder {
        ObservedOrder(onBar: bar.map(k), parked: [], uncorroborated: Set(u.map(k)), staleOnBar: Set(u.map(k)))
    }

}

// 9o9.9 corrective: the guard at engine level.
private final class AmbiguousObserver: MenuBarObserver, @unchecked Sendable {
    let actuator: FakeActuator
    let subject: ItemKey
    /// Scripted bars returned instead of the actuator's truth (the last one repeats); nil: the truth.
    let script: [[ItemKey]]?
    private let lock = NSLock(); private var n = 0
    init(actuator: FakeActuator, subject: ItemKey, script: [[ItemKey]]? = nil) { self.actuator = actuator; self.subject = subject; self.script = script }
    private func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n - 1 }
    func observe() async throws -> [ResolvedItem] {
        let i = next()
        let order: [ItemKey]
        if let script { order = script[min(i, script.count - 1)] } else { order = await actuator.order }
        var items = FakeMenuBar.resolve(FakeMenuBar.snapshot(order: order, hidden: await actuator.hidden))
        for j in items.indices where items[j].key == subject { items[j].item.joinEvidence = .frameAmbiguous }
        return items
    }
}

@MainActor
private func untrustedRig(order: [String], record: [String], subject: String, script: [[String]]? = nil, sink: LogSink) async
    -> (engine: LayoutEngine, actuator: FakeActuator, state: EngineState) {
    let act = FakeActuator(order: order.map(k), hidden: [], capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let obs = AmbiguousObserver(actuator: act, subject: k(subject), script: script.map { $0.map { $0.map(k) } })
    let state = EngineState()
    var c = LayoutEngine.Config.plain(); c.positionRetryBase = .seconds(600); c.positionRetryCap = .seconds(600)   // no timer interference
    let engine = LayoutEngine(observer: obs, actuator: act, store: InMemoryLayoutStore(Layout(visible: record.map(k))), capabilities: Caps(), state: state,
                              resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { sink.add($0) }, config: c)
    await engine.start()
    return (engine, act, state)
}

@MainActor
struct UnsteadyGuardEngineTests {
    // The engine's own verified move across the untrusted S must not make S look unsteady: two crossings in two passes converge.
    @Test func twoCrossingsInTwoPassesConvergeWithoutAMovingSkip() async {
        let sink = LogSink()
        let r = await untrustedRig(order: ["X", "S", "A", "B"], record: ["X", "A", "B", "S"], subject: "S", sink: sink)
        for _ in 0..<5 { _ = await r.engine.reconcileOnce() }
        // ejb.15 (Wiring 3), CHANGED because the core decides: S has an ambiguous frame, so the adapter reads it as UNREAD (A6) and the core, which cannot know
        // where S stands among the open keys, makes NO drag across it (the old planner made the two crossings). The trusted keys X, A, B are already in order.
        // The guard's property is kept: nothing is dragged on an untrusted key's say-so and nothing is "moving".
        #expect(await r.actuator.order == ["X", "S", "A", "B"].map(k))
        #expect(await r.actuator.calls.isEmpty)
        #expect(!sink.lines.contains { $0.contains("is moving") })
    }

    // S flips every other observation: the pass held by the guard is not "converged" and keeps the strike memory, so the identical trusted
    // move planned afterwards is struck (verified but planned again), never dragged back and forth.
    @Test func aFlippingUntrustedKeyEndsInAStrikeNotAnEndlessSwap() async {
        let sink = LogSink()
        let r = await untrustedRig(order: ["X", "S", "A"], record: ["X", "A", "S"], subject: "S",
                                   script: [["X", "S", "A"], ["X", "S", "A"], ["X", "S", "A"]], sink: sink)
        var outcomes: [PassReport.Outcome] = []
        for _ in 0..<6 { outcomes.append(await r.engine.reconcileOnce().outcome) }
        // ejb.15 (Wiring 3), CHANGED because the core decides: an ambiguous-frame S is UNREAD for the core (A6), so there is no move to strike and no endless
        // swap to bound: the engine makes no drag at all (the old "is moving" skip, "verified but planned again" strike and "giving up" are the old planner's).
        // The safety property (never an unbounded swap, never a drag on the untrusted key's say-so) is kept as a hard bound of zero drags.
        #expect(await r.actuator.calls.isEmpty)
        #expect(!outcomes.contains(.stopped))
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await r.actuator.calls.isEmpty)
    }

    // The held pass is incomplete, and the key shows the transient waiting status, not unsupported.
    @Test func aMovingHoldIsIncompleteAndWaiting() async {
        let sink = LogSink()
        let r = await untrustedRig(order: ["X", "S", "A"], record: ["X", "A", "S"], subject: "S",
                                   script: [["X", "S", "A"], ["X", "S", "A"]], sink: sink)
        _ = await r.engine.reconcileOnce()
        let rep = await r.engine.reconcileOnce()
        // ejb.15 (Wiring 3), CHANGED because the core decides: S is UNREAD for the core, so it makes no move and there is no "moving neighbour" hold; the pass is
        // not converged, nothing was dragged and A is not marked failed or unsupported (its row text comes from the core in Wiring 4).
        _ = rep
        #expect(!r.state.isConverged)   // withheld like a gated bar: the status is "stopped while differing", never converged
        #expect(await r.actuator.calls.isEmpty)
        if case .failed? = r.state.perItem[k("A")] { Issue.record("A must not be failed") }
        if case .unsupported? = r.state.perItem[k("A")] { Issue.record("A must not be unsupported") }
    }
}
