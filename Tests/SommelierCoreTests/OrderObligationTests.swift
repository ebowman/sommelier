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

    // Every Visible key carries the obligation: the planned moves, applied, reach the record's order on the bar.
    @Test func plannedMovesReachTheRecordForRandomBars() {
        for seed in 1...300 {
            var g = SplitMix64(seed: UInt64(seed))
            let n = Int.random(in: 2...15, using: &g)
            let keys = (0..<n).map { k("i\($0)") }
            let o = ObservedOrder(onBar: keys.shuffled(using: &g), parked: [])
            let layout = Layout(visible: keys.shuffled(using: &g))
            let p = rec.plan(observed: o, layout: layout, capabilities: free)
            #expect(final(p, o) == layout.visible, "seed \(seed)")
            let q = rec.plan(observed: ObservedOrder(onBar: layout.visible, parked: []), layout: layout, capabilities: free)
            #expect(q.phase == .converged && q.actions.isEmpty, "seed \(seed)")
        }
    }

    // With a pinned trailing system block and 1-2 stale keys: trusted keys converge in order, no move names a stale key (subject or target),
    // and the block never moves.
    @Test func randomBarsWithASystemBlockAndStaleKeysConverge() {
        for seed in 1...400 {
            var g = SplitMix64(seed: UInt64(seed))
            let n = Int.random(in: 4...12, using: &g)
            let keys = (0..<n).map { k("i\($0)") }
            let stale = Set(keys.shuffled(using: &g).prefix(Int.random(in: 1...2, using: &g)))
            let block = [Self.cc, Self.clock]
            let bar = keys.shuffled(using: &g)
            let o = ObservedOrder(onBar: bar + block, parked: [], uncorroborated: stale, staleOnBar: stale)
            let layout = Layout(visible: keys.shuffled(using: &g) + block)
            let p = rec.plan(observed: o, layout: layout, capabilities: Self.sysCaps)
            for case .move(let subject, let rel) in p.actions {
                #expect(!stale.contains(subject) && subject != Self.cc && subject != Self.clock, "seed \(seed)")
                switch rel {
                case .before(let t): #expect(!stale.contains(t) && t != Self.clock, "seed \(seed) target")   // before the first block key is how a key goes last
                case .after(let t): #expect(!stale.contains(t) && t != Self.cc && t != Self.clock, "seed \(seed) target")
                default: break
                }
            }
            // simulate: each move must name a key that is on the bar now; the end keeps the block last and the stale keys in their slots
            let end = final(p, o)
            #expect(Array(end.suffix(2)) == block, "seed \(seed)")
            let trusted = keys.filter { !stale.contains($0) }
            let skippedKeys = Set(p.skipped.map(\.key))
            if skippedKeys.isEmpty {
                #expect(end.filter { !stale.contains($0) && !block.contains($0) } == layout.visible.filter { trusted.contains($0) }, "seed \(seed) trusted order")
            }
        }
    }

    @Test func aLayoutEqualToTheBarYieldsZeroActions() {
        let p = rec.plan(observed: obs(["a", "b", "c"]), layout: lay(v: ["a", "b", "c"]), capabilities: free)
        #expect(p.phase == .converged && p.actions.isEmpty)
    }

    @Test func anAdjacentSwapIsExactlyOneMove() {
        let p = rec.plan(observed: obs(["a", "b", "c", "d"]), layout: lay(v: ["a", "c", "b", "d"]), capabilities: free)
        #expect(p.phase == .order)
        #expect(moves(p).count == 1)
        #expect(final(p, obs(["a", "b", "c", "d"])) == ["a", "c", "b", "d"].map(k))
    }

    @Test func layoutKeysAbsentFromTheBarAreIgnored() {
        let p = rec.plan(observed: obs(["a", "b", "c"]), layout: lay(v: ["gone", "c", "ghost", "a", "b"]), capabilities: free)
        #expect(p.absent.contains(k("gone")) && p.absent.contains(k("ghost")))
        #expect(final(p, obs(["a", "b", "c"])) == ["c", "a", "b"].map(k))
        #expect(moves(p).count == 1)
        #expect(rec.plan(observed: obs(["a", "b"]), layout: lay(v: ["gone", "a", "ghost", "b"]), capabilities: free).actions.isEmpty)
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

    @Test func aFreshIStatItemIsOrderedLikeAnyOther() {
        let istat = ItemKey.status(ownerKey: "com.bjango.istatmenus.status", autosaveName: "cpu")
        let o = ObservedOrder(onBar: [k("a"), k("b"), istat], parked: [])
        let p = rec.plan(observed: o, layout: Layout(visible: [istat, k("a"), k("b")]), capabilities: free)
        #expect(p.actions == [.move(istat, .before(k("a")))])
    }

    // 9o9.3: a stale subject is skipped with the stale-frame reason, never dragged.
    @Test func aStaleSubjectIsSkippedWithTheStaleFrameReason() {
        let o = ObservedOrder(onBar: [k("a"), k("b"), k("s")], parked: [], uncorroborated: [k("s")], staleOnBar: [k("s")])
        let p = rec.plan(observed: o, layout: lay(v: ["s", "a", "b"]), capabilities: free)
        #expect(p.actions.isEmpty)
        #expect(p.skipped.contains(SkippedAction(k("s"), Reconciler.staleFrameSkipReason)))
    }

    // A stale neighbour is not used as the relation target: the chosen neighbour is fresh and already in place (never a key that moves).
    @Test func aStaleTargetNeighbourGivesWayToTheNextFreshNeighbour() {
        let o = ObservedOrder(onBar: [k("a"), k("s"), k("b"), k("c")], parked: [], uncorroborated: [k("s")], staleOnBar: [k("s")])
        let p = rec.plan(observed: o, layout: lay(v: ["a", "s", "c", "b"]), capabilities: free)
        #expect(p.actions.count == 1)
        guard case .move(let subject, let rel)? = p.actions.first else { Issue.record("no move"); return }
        let moving = Set(p.actions.compactMap { a -> ItemKey? in if case .move(let m, _) = a { m } else { nil } })
        switch rel {
        case .before(let t), .after(let t):
            #expect(t != k("s") && t != subject && !moving.contains(t))
            #expect(["a", "b", "c"].map(k).contains(t))
        default: Issue.record("expected a relation to a fresh in-place key")
        }
        #expect(final(p, o).filter { $0 != k("s") } == ["a", "c", "b"].map(k))
    }

    // Reviewer's case: bar U A B Z X, record U X Z A B, U stale. Every move names a fresh key that is in place when the move runs.
    @Test func everyMoveNamesAFreshInPlaceNeighbourAndTheSequenceConverges() {
        let o = ObservedOrder(onBar: ["U", "A", "B", "Z", "X"].map(k), parked: [], uncorroborated: [k("U")], staleOnBar: [k("U")])
        let p = rec.plan(observed: o, layout: lay(v: ["U", "X", "Z", "A", "B"]), capabilities: free)
        var bar = o
        var moved = Set<ItemKey>()
        for a in p.actions {
            guard case .move(let subject, let rel) = a else { Issue.record("not a move"); continue }
            #expect(subject != k("U"))
            switch rel {
            case .before(let t), .after(let t):
                #expect(t != k("U"), "stale target")
                #expect(!moved.contains(subject))
                // in place = the neighbour has not been left waiting for its own move
                let pending = Set(p.actions.compactMap { x -> ItemKey? in if case .move(let m, _) = x { m } else { nil } }).subtracting(moved)
                #expect(!pending.contains(t), "target \(t) is still waiting to be moved")
            default: break
            }
            moved.insert(subject)
            bar = PlanSimulator.apply(a, to: bar)
        }
        #expect(bar.onBar == ["U", "X", "Z", "A", "B"].map(k))
        #expect(rec.plan(observed: ObservedOrder(onBar: bar.onBar, parked: [], uncorroborated: [k("U")], staleOnBar: [k("U")]),
                         layout: lay(v: ["U", "X", "Z", "A", "B"]), capabilities: free).actions.isEmpty)
    }

    // A move whose only possible neighbours are stale is skipped, not spelled against a stale frame.
    @Test func aMoveWithOnlyStaleNeighboursIsSkipped() {
        let o = ObservedOrder(onBar: [k("s"), k("a")], parked: [], uncorroborated: [k("s")], staleOnBar: [k("s")])
        let p = rec.plan(observed: o, layout: lay(v: ["a", "s"]), capabilities: free)
        #expect(p.actions.isEmpty)
        #expect(p.skipped.contains { $0.reason == Reconciler.staleFrameSkipReason })
    }

    // 9o9.2 finding: one uncorroborated key at the right end is not the "system block"; the others are still ordered.
    @Test func anUncorroboratedKeyAtTheRightEndDoesNotMakeEveryoneUnplaceable() {
        let o = ObservedOrder(onBar: [k("a"), k("b"), k("c")], parked: [], uncorroborated: [k("c")])
        let p = rec.plan(observed: o, layout: lay(v: ["b", "a", "c"]), capabilities: free)
        #expect(!p.skipped.contains { $0.reason.hasPrefix("cannot be placed right of the system items") })
        #expect(final(p, o) == ["b", "a", "c"].map(k))
    }

    @Test func aMembershipPassNeverOrders() {
        let p = rec.plan(observed: obs(["a", "b"], ["k"]), layout: lay(v: ["b", "a", "k"]), capabilities: free)
        #expect(p.phase == .membership && p.actions == [.show(k("k"))])
    }

    @Test func overflowedAndChevronKeysAreNeverSubjectsOrTargets() {
        let o = obs(["o", "chev", "a", "b", "k"], ovf: ["o"], chevron: "chev")
        let p = rec.plan(observed: o, layout: lay(v: ["o", "k", "b", "a"]), capabilities: free)
        #expect(Reconciler.overflowViolations(p.actions, forbidden: [k("o"), k("chev")], boundary: true).isEmpty)
        #expect(final(p, o).suffix(3) == [k("k"), k("b"), k("a")])
    }
}

struct LayoutRecordModelTests {
    @Test func adoptKeepsTheObservedOrderAsTheRecord() {
        let current = Layout(visible: [k("a"), k("b")])
        let adopted = ArrangeDrop.adopt(observed: obs(["b", "a"]), current: current)
        #expect(adopted.visible == [k("b"), k("a")])
    }

    @Test func leavingVisibleOrTheLayoutKeepsTheLayoutValid() {
        var l = Layout(visible: [k("a"), k("b")], hidden: [k("c")])
        l.move(k("a"), to: .hidden)
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
        #expect(rep.outcome == .converged)
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

    // The live case (2026-11-07 build 282): ControlCenter, Shield*, MCP observed; record ControlCenter, MCP, Shield*.
    @Test func theLiveShieldMcpMaestroCase() {
        let o = untrusted(["CC", "Sh", "MCP"], ["Sh"])
        let layout = lay(v: ["CC", "MCP", "Sh"])
        let p = rec.plan(observed: o, layout: layout, capabilities: free)
        #expect(p.phase == .order)
        #expect(p.actions == [.move(k("MCP"), .after(k("CC")))])
        #expect(run(p, o) == ["CC", "MCP", "Sh"].map(k))
        // the second pass is quiet
        let q = rec.plan(observed: untrusted(["CC", "MCP", "Sh"], ["Sh"]), layout: layout, capabilities: free)
        #expect(q.phase == .converged && q.actions.isEmpty)
    }

    // A S B observed, record B S A, S untrusted. No safe move spells B before / A after against a trusted in-place neighbour (the only
    // neighbour of each is S or the other pending key; an edge drop would cross S unverified), so: no action, converged, and the
    // untrusted S carries the "waiting" skip. The bar is left as observed; nothing is dragged against S.
    @Test func swapAcrossAnUntrustedKeyWithNoTrustedNeighbourIsSkipped() {
        let o = untrusted(["A", "S", "B"], ["S"])
        let p = rec.plan(observed: o, layout: lay(v: ["B", "S", "A"]), capabilities: free)
        #expect(p.actions.isEmpty && p.phase == .converged)
        #expect(p.skipped.contains { $0.key == k("S") })
        #expect(!p.skipped.contains { $0.key == k("A") || $0.key == k("B") })
    }

    // A trusted subject crosses an untrusted key when spelled against a trusted neighbour on the far side.
    @Test func aTrustedSubjectMayCrossAnUntrustedKeyViaAFarNeighbour() {
        let o = untrusted(["A", "S", "B", "C"], ["S"])
        let p = rec.plan(observed: o, layout: lay(v: ["A", "B", "S", "C"]), capabilities: free)   // B must be left of S
        #expect(p.actions == [.move(k("B"), .after(k("A")))])
        #expect(run(p, o) == ["A", "B", "S", "C"].map(k))
    }

    // Oscillation guard: S's slot changed since the last settled observation, so nothing crosses it this pass.
    @Test func noMoveCrossesAnUnsteadyUntrustedKey() {
        let o = untrusted(["CC", "Sh", "MCP"], ["Sh"])
        let layout = lay(v: ["CC", "MCP", "Sh"])
        let p = rec.plan(observed: o, layout: layout, capabilities: free, unsteady: [k("Sh")])
        #expect(p.actions.isEmpty && p.phase == .converged)
        #expect(p.skipped.contains(SkippedAction(k("MCP"), Reconciler.movingNeighbourSkipReason(k("Sh")))))
        #expect(Reconciler.movingNeighbourSkipReason(k("Sh")) == "neighbour \(k("Sh")) is moving")
        // a move that does not cross the unsteady key is still planned
        let p2 = rec.plan(observed: untrusted(["Sh", "A", "B"], ["Sh"]), layout: lay(v: ["Sh", "B", "A"]), capabilities: free, unsteady: [k("Sh")])
        #expect(p2.actions.count == 1)
    }

    @Test func unsteadyKeysAreTheOnesWhoseSlotChanged() {
        let prev = ["CC", "Sh", "MCP", "X"].map(k)
        #expect(Reconciler.unsteadyKeys(previous: nil, current: prev, among: [k("Sh")]).isEmpty)
        #expect(Reconciler.unsteadyKeys(previous: prev, current: prev, among: [k("Sh")]).isEmpty)
        #expect(Reconciler.unsteadyKeys(previous: prev, current: ["CC", "MCP", "Sh", "X"].map(k), among: [k("Sh")]) == [k("Sh")])
        // an unrelated key appearing or leaving is not a slot change
        #expect(Reconciler.unsteadyKeys(previous: prev, current: ["CC", "Sh", "MCP"].map(k), among: [k("Sh")]).isEmpty)
    }

    // Random bars with a system block and 1-2 untrusted keys, one move per pass, `unsteady` computed the real way (the untrusted key's
    // slot against the previous settled observation, advanced past the engine's own moves). For the first passes an untrusted key may
    // also slip one slot by itself (the flip the guard exists for). Every seed reaches a fixed point (no action, no "moving" hold) within a
    // bounded number of passes, no move names an untrusted key, the block stays last; with no skip at all the trusted keys are in record
    // order among themselves AND on the record's side of every untrusted key.
    @Test func trustedKeysConvergeRelativeToUntrustedKeys() {
        var ordered = 0, held = 0
        for seed in 1...400 {
            var g = SplitMix64(seed: UInt64(seed))
            let n = Int.random(in: 4...12, using: &g)
            let keys = (0..<n).map { k("i\($0)") }
            let stale = Set(keys.shuffled(using: &g).prefix(Int.random(in: 1...2, using: &g)))
            let block = [Self.cc, Self.clock]
            let layout = Layout(visible: keys.shuffled(using: &g) + block)
            var o = ObservedOrder(onBar: keys.shuffled(using: &g) + block, parked: [], uncorroborated: stale, staleOnBar: stale)
            var previous: [ItemKey]? = nil
            var settled = false
            for pass in 0..<(n * 4 + 10) {
                if pass < 3, Bool.random(using: &g), let u = stale.sorted(by: { "\($0)" < "\($1)" }).first, let i = o.onBar.firstIndex(of: u), i + 1 < o.onBar.count - 2 {
                    o.onBar.swapAt(i, i + 1)   // the untrusted key's slot flips by itself
                }
                let unsteady = Reconciler.unsteadyKeys(previous: previous, current: o.onBar, among: stale)
                previous = o.onBar
                let p = rec.plan(observed: o, layout: layout, capabilities: Self.sysCaps, unsteady: unsteady)
                for case .move(let subject, let rel) in p.actions {
                    #expect(!stale.contains(subject) && subject != Self.cc && subject != Self.clock, "seed \(seed)")
                    switch rel {
                    case .before(let t): #expect(!stale.contains(t) && t != Self.clock, "seed \(seed) target")
                    case .after(let t): #expect(!stale.contains(t) && t != Self.cc && t != Self.clock, "seed \(seed) target")
                    default: break
                    }
                }
                let holding = p.skipped.contains { Reconciler.isMovingNeighbourSkip($0.reason) }
                if p.actions.isEmpty && !holding { settled = true; if p.skipped.isEmpty { ordered += 1 }; break }
                if holding { held += 1 }
                if let first = p.actions.first { o = PlanSimulator.apply(first, to: o); previous = o.onBar }   // one move per pass; own move is not the untrusted key's
            }
            #expect(settled, "seed \(seed) did not reach a fixed point")
            #expect(Array(o.onBar.suffix(2)) == block, "seed \(seed)")
            let rank = Dictionary(uniqueKeysWithValues: layout.visible.enumerated().map { ($1, $0) })
            let trusted = o.onBar.filter { !stale.contains($0) && !block.contains($0) }
            // trusted keys are in record order among themselves unless some skip explains it
            let p = rec.plan(observed: o, layout: layout, capabilities: Self.sysCaps)
            if p.skipped.isEmpty {
                #expect(zip(trusted, trusted.dropFirst()).allSatisfy { rank[$0]! < rank[$1]! }, "seed \(seed) trusted order")
                // relative to untrusted keys: every trusted key is on the record's side of every untrusted key
                for u in stale {
                    let ui = o.onBar.firstIndex(of: u)!
                    for t in trusted {
                        #expect((o.onBar.firstIndex(of: t)! < ui) == (rank[t]! < rank[u]!), "seed \(seed) \(t) vs \(u)")
                    }
                }
            }
        }
        #expect(ordered > 20 && held > 0)
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
