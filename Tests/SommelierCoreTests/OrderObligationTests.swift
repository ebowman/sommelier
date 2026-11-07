import Testing
import Foundation
@testable import SommelierCore

// gdu.89: only an explicit user placement (Layout.placed) creates an order obligation on the real bar.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private func free(_: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
private let rec = Reconciler()
private func obs(_ bar: [String], _ parked: [String] = [], ovf: [String] = [], chevron: String? = nil) -> ObservedOrder {
    ObservedOrder(onBar: bar.map(k), parked: parked.map(k), systemOverflow: Set(ovf.map(k)), overflowChevron: chevron.map(k))
}
private func lay(v: [String], h: [String] = [], placed: [String] = []) -> Layout {
    Layout(visible: v.map(k), hidden: h.map(k), placed: placed.map(k))
}
private func moves(_ p: Plan) -> [PlannedAction] { p.actions.filter { if case .move = $0 { return true }; return false } }

struct OrderObligationPlannerTests {
    // (a) no placement, no order action, whatever the saved order and the bar
    @Test func unplacedLayoutPlansNoMovesForRandomBars() {
        for seed in 1...300 {
            var g = SplitMix64(seed: UInt64(seed))
            let n = Int.random(in: 2...20, using: &g)
            let keys = (0..<n).map { k("i\($0)") }
            let bar = keys.shuffled(using: &g)
            let saved = keys.shuffled(using: &g)
            let anchors = Set(keys.shuffled(using: &g).prefix(Int.random(in: 0...3, using: &g)))
            let caps = { (key: ItemKey) in Capability(canMove: !anchors.contains(key), canHide: true) }
            let layout = Layout(visible: saved)
            let p = rec.plan(observed: ObservedOrder(onBar: bar, parked: []), layout: layout, capabilities: caps, placed: layout.placedSet)
            #expect(p.phase == .converged, "seed \(seed)")
            #expect(p.actions.isEmpty, "seed \(seed)")
        }
    }

    // keep the full-order rule reachable: placed == Set(visible) plans like the legacy (nil) full order
    @Test func fullyPlacedEqualsLegacyFullOrder() {
        for seed in 1...300 {
            var g = SplitMix64(seed: UInt64(seed))
            let n = Int.random(in: 2...15, using: &g)
            let keys = (0..<n).map { k("i\($0)") }
            let bar = keys.shuffled(using: &g)
            let layout = Layout(visible: keys.shuffled(using: &g))
            let anchors = Set<ItemKey>()   // with immovable keys the legacy rule reorders around them differently (it places anchors by the layout); see docs
            let caps = { (key: ItemKey) in Capability(canMove: !anchors.contains(key), canHide: true) }
            let o = ObservedOrder(onBar: bar, parked: [])
            let legacy = rec.plan(observed: o, layout: layout, capabilities: caps)
            let full = rec.plan(observed: o, layout: layout, capabilities: caps, placed: Set(layout.visible))
            // Both reach the same final order when applied (moves may be spelled differently).
            func final(_ p: Plan) -> [ItemKey] { p.actions.reduce(o) { PlanSimulator.apply($1, to: $0) }.onBar }
            #expect(final(full) == final(legacy), "seed \(seed) bar \(bar.map(\.description)) layout \(layout.visible.map(\.description)) anchors \(anchors.map(\.description)) full \(final(full).map(\.description)) legacy \(final(legacy).map(\.description))")
        }
    }

    // (b) one placed key: only it moves, next to its layout neighbour
    @Test func onePlacedKeyMovesNextToItsLeftNeighbour() {
        let p = rec.plan(observed: obs(["a", "b", "c", "d"]), layout: lay(v: ["a", "b", "d", "c"], placed: ["d"]), capabilities: free, placed: [k("d")])
        #expect(p.phase == .order)
        #expect(p.actions == [.move(k("d"), .after(k("b")))])
    }

    @Test func nonPlacedKeysAreNeverTheSubjectOfAMove() {
        // Layout wants K first; LIS ambiguity must not move the neighbour instead of K.
        let p = rec.plan(observed: obs(["a", "k"]), layout: lay(v: ["k", "a"], placed: ["k"]), capabilities: free, placed: [k("k")])
        #expect(p.actions == [.move(k("k"), .before(k("a")))])
        for seed in 1...200 {
            var g = SplitMix64(seed: UInt64(seed))
            let keys = (0..<Int.random(in: 3...14, using: &g)).map { k("i\($0)") }
            let placed = Set(keys.shuffled(using: &g).prefix(Int.random(in: 1...3, using: &g)))
            let layout = Layout(visible: keys.shuffled(using: &g), placed: Array(placed))
            let anchors = Set(keys.shuffled(using: &g).prefix(Int.random(in: 0...3, using: &g)))
            let caps = { (key: ItemKey) in Capability(canMove: !anchors.contains(key), canHide: true) }
            let plan = rec.plan(observed: ObservedOrder(onBar: keys.shuffled(using: &g), parked: []), layout: layout, capabilities: caps, placed: placed)
            for case .move(let subject, _) in plan.actions { #expect(placed.contains(subject) && !anchors.contains(subject), "seed \(seed)") }
        }
    }

    // (c) neighbour fallbacks
    @Test func leftNeighbourNotOnTheBarFallsBackToTheRightNeighbour() {
        // h (left neighbour) is hidden/absent: K goes before its right neighbour b.
        let p = rec.plan(observed: obs(["a", "b", "k"]), layout: lay(v: ["h", "k", "b", "a"], placed: ["k"]), capabilities: free, placed: [k("k")])
        // target [a, k, b]: k sits before b (its right neighbour); the drag is spelled relative to the kept key on its left
        #expect(p.actions == [.move(k("k"), .after(k("a")))])
    }

    @Test func overflowedLeftNeighbourIsNotUsed() {
        let o = obs(["o", "chev", "a", "b", "k"], ovf: ["o"], chevron: "chev")
        let p = rec.plan(observed: o, layout: lay(v: ["o", "k", "b", "a"], placed: ["k"]), capabilities: free, placed: [k("k")])
        #expect(p.actions == [.move(k("k"), .after(k("a")))])
    }

    @Test func noNeighbourAtAllGoesLeftmostWithTheChevronRule() {
        let o = obs(["o", "chev", "a", "b", "k"], ovf: ["o"], chevron: "chev")
        let p = rec.plan(observed: o, layout: lay(v: ["k"], placed: ["k"]), capabilities: free, placed: [k("k")])
        #expect(p.actions == [.move(k("k"), .before(k("a")))])   // never left of the chevron
        let q = rec.plan(observed: obs(["a", "b", "k"]), layout: lay(v: ["k"], placed: ["k"]), capabilities: free, placed: [k("k")])
        #expect(q.actions == [.move(k("k"), .before(k("a")))])
    }

    @Test func noNeighbourAndNotFirstInTheLayoutGoesRightmost() {
        let p = rec.plan(observed: obs(["k", "a", "b"]), layout: lay(v: ["gone", "k"], placed: ["k"]), capabilities: free, placed: [k("k")])
        #expect(p.actions == [.move(k("k"), .after(k("b")))])
    }

    @Test func placedKeyNeverLandsRightOfTheSystemBlock() {
        let clock = ItemKey.module(name: "Clock")
        let caps = { (key: ItemKey) in key == clock ? Capability(canMove: false, canHide: false) : Capability(canMove: true, canHide: true) }
        let o = ObservedOrder(onBar: [k("k"), k("a"), clock], parked: [])
        let p = rec.plan(observed: o, layout: Layout(visible: [k("gone"), k("k")], placed: [k("k")]), capabilities: caps, placed: [k("k")])
        #expect(p.actions == [.move(k("k"), .after(k("a")))])
    }

    // (d) dropped from Hidden into Visible: show first, move in the follow-up order pass
    @Test func placedKeyFromHiddenIsShownThenMoved() {
        let layout = lay(v: ["a", "k", "b"], placed: ["k"])
        var o = obs(["a", "b"], ["k"])
        let p1 = rec.plan(observed: o, layout: layout, capabilities: free, placed: layout.placedSet)
        #expect(p1.phase == .membership)
        #expect(p1.actions == [.show(k("k"))])
        for a in p1.actions { o = PlanSimulator.apply(a, to: o) }
        #expect(o.onBar == ["a", "b", "k"].map(k))
        let p2 = rec.plan(observed: o, layout: layout, capabilities: free, placed: layout.placedSet)
        #expect(p2.phase == .order)
        #expect(p2.actions == [.move(k("k"), .after(k("a")))])
    }

    @Test func aShownUnplacedKeyIsNotOrdered() {
        let layout = lay(v: ["k", "a", "b"])
        var o = obs(["a", "b"], ["k"])
        let p1 = rec.plan(observed: o, layout: layout, capabilities: free, placed: layout.placedSet)
        for a in p1.actions { o = PlanSimulator.apply(a, to: o) }
        let p2 = rec.plan(observed: o, layout: layout, capabilities: free, placed: layout.placedSet)
        #expect(p2.phase == .converged)
    }

    // 3: a satisfied placement stays an obligation
    @Test func aSatisfiedPlacementIsEnforcedAgainAfterMacOSMovesTheKey() {
        let layout = lay(v: ["a", "k", "b"], placed: ["k"])
        #expect(rec.plan(observed: obs(["a", "k", "b"]), layout: layout, capabilities: free, placed: layout.placedSet).phase == .converged)
        let p = rec.plan(observed: obs(["k", "a", "b"]), layout: layout, capabilities: free, placed: layout.placedSet)
        #expect(p.actions == [.move(k("k"), .after(k("a")))])
    }
}

struct LayoutPlacedModelTests {
    // (e)
    @Test func adoptClearsPlaced() {
        let current = Layout(visible: [k("a"), k("b")], placed: [k("a")])
        let adopted = ArrangeDrop.adopt(observed: obs(["b", "a"]), current: current)
        #expect(adopted.placed.isEmpty)
        #expect(adopted.visible == [k("b"), k("a")])
    }

    @Test func builderAndFirstLaunchProduceNoPlaced() {
        let res = FakeMenuBar.resolve(FakeMenuBar.snapshot(order: ["A", "B", "C"].map(k), hidden: [k("C")]))
        #expect(LayoutBuilder.build(from: res).layout.placed.isEmpty)
    }

    @Test func leavingTheLayoutOrVisibleDropsThePlacement() {
        var l = Layout(visible: [k("a"), k("b")], hidden: [k("c")], placed: [k("a"), k("b")])
        l.move(k("a"), to: .hidden)
        #expect(l.placed == [k("b")])
        l.remove(k("b"))
        #expect(l.placed.isEmpty)
        #expect(l.isValid)
        #expect(!Layout(visible: [k("a")], placed: [k("zzz")]).isValid)
    }

    @Test func hideNotFittingNeverAddsPlaced() {
        var l = Layout(visible: [k("a"), k("b"), k("c")], placed: [k("a")])
        l.hideNotFitting([k("b")])
        #expect(l.placed == [k("a")])
    }

    // the Arrange drop is the only thing that marks keys
    @Test func aDropIntoVisibleMarksTheMovedKeysAndOrderOnlyHiddenDropsDoNot() {
        let base = Layout(visible: [k("a"), k("b")], hidden: [k("h1"), k("h2")], orderMode: .placedOnly)
        guard case .move(let l1, let moved, _) = ArrangeDrop.outcome(layout: base, key: k("h2"), to: .visible, index: 1, capabilities: free) else { Issue.record("no move"); return }
        #expect(moved == [k("h2")])
        #expect(l1.placed == [k("h2")])
        guard case .move(let l2, _, _) = ArrangeDrop.outcome(layout: base, key: k("h2"), to: .hidden, index: 0, capabilities: free) else { Issue.record("no move"); return }
        #expect(l2.placed.isEmpty)
        guard case .move(let l3, _, _) = ArrangeDrop.outcome(layout: l1, key: k("a"), to: .visible, index: 2, capabilities: free) else { Issue.record("no move"); return }
        #expect(Set(l3.placed) == [k("h2"), k("a")])
        // dropping a placed key on its own position is no drop
        #expect(ArrangeDrop.outcome(layout: l1, key: k("h2"), to: .visible, index: 1, capabilities: free) == .noop)
    }

    // (f)
    @Test func decodeWithoutThePlacedFieldIsEmptyAndItRoundTrips() throws {
        let old = Data(#"{"schemaVersion":1,"visible":["status:com.x.a::a"],"hidden":[],"alwaysHidden":[],"newItemPolicy":"visibleAtEnd"}"#.utf8)
        #expect(try JSONDecoder().decode(Layout.self, from: old).placed.isEmpty)
        #expect(try Layout.decode(old).layout.placed.isEmpty)
        let l = Layout(visible: [k("a"), k("b")], placed: [k("b")])
        let data = try JSONEncoder().encode(l)
        #expect(try JSONDecoder().decode(Layout.self, from: data) == l)
        #expect(try Layout.decode(data).layout.placed == [k("b")])
        #expect(!String(decoding: try JSONEncoder().encode(Layout(visible: [k("a")])), as: UTF8.self).contains("placed"))
        // a placed key that is not in the layout is dropped on load
        let bad = Data(#"{"visible":["status:com.x.a::a"],"placed":["status:com.x.q::q"]}"#.utf8)
        #expect(try Layout.decode(bad).layout.placed.isEmpty)
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
                              resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { sink.add($0) })
    await engine.start()
    return (engine, act, state, store)
}

@MainActor
struct OrderObligationEngineTests {
    // (g)
    @Test func aLayoutFromDiskWithoutPlacedProducesZeroOrderActions() async {
        let sink = LogSink()
        let r = await engineRig(order: ["A", "B", "C", "D"], layout: Layout(visible: ["D", "C", "B", "A"].map(k), orderMode: .placedOnly), sink: sink)
        #expect(sink.lines.contains { $0.contains("no order obligations exist") })
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .converged)
        #expect(rep.actionCount == 0)
        #expect(await r.actuator.calls.isEmpty)
        #expect(await r.actuator.order == ["A", "B", "C", "D"].map(k))
        #expect(!sink.lines.contains { $0.contains("order: moving") })
    }

    @Test func aPlacedKeyIsTheOnlyThingTheEngineMovesAndSaysWhy() async {
        let sink = LogSink()
        let layout = Layout(visible: ["A", "C", "B", "D"].map(k), placed: [k("C")], orderMode: .placedOnly)
        let r = await engineRig(order: ["A", "B", "C", "D"], layout: layout, sink: sink)
        #expect(!sink.lines.contains { $0.contains("no order obligations exist") })
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .converged)
        #expect(await r.actuator.calls == [.move(k("C"), .after(k("A")))])
        #expect(await r.actuator.order == ["A", "C", "B", "D"].map(k))
        #expect(sink.lines.contains { $0.contains("order: moving") && $0.contains("(user placement)") })
        // the notice is only for the move in flight
        #expect(r.state.orderMoveNotice == nil)
        #expect(r.state.orderMoveReasons.isEmpty)
    }

    @Test func aFirstLaunchLayoutAndAnAdoptNeverCreateObligations() async {
        let sink = LogSink()
        let r = await engineRig(order: ["A", "B"], layout: Layout(visible: ["B", "A"].map(k), placed: [k("B")]), sink: sink)
        await r.engine.setLayout(Layout(visible: ["B", "A"].map(k)))   // adopt (no placed in the requested layout)
        #expect(r.state.layout.placed.isEmpty)
        await r.engine.setLayout(Layout(visible: ["B", "A"].map(k), placed: [k("B")]), userPlacement: false)   // built from a scan
        #expect(r.state.layout.placed.isEmpty)
        let rep = await r.engine.reconcileOnce()
        #expect(rep.actionCount == 0)
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func aUserDropPersistsItsPlacement() async {
        let sink = LogSink()
        let r = await engineRig(order: ["A", "B", "C"], layout: Layout(visible: ["A", "B", "C"].map(k), orderMode: .placedOnly), sink: sink)
        guard case .move(let l, _, _) = ArrangeDrop.outcome(layout: r.state.layout, key: k("C"), to: .visible, index: 0, capabilities: free) else { Issue.record("no move"); return }
        await r.engine.setLayout(l)
        #expect(r.state.layout.placed == [k("C")])
        #expect((try? r.store.load())?.placed == [k("C")])
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
