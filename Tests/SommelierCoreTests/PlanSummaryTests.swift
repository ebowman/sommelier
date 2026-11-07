import Testing
import Foundation
@testable import SommelierCore

// 9o9.5: the engine publishes its last plan's partition (`EngineState.lastPlan`) and Arrange displays it; it never reconstructs it.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private struct OpenCaps: CapabilityProvider { func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) } }

/// Observes the fake actuator's truth; `subject` has a non-corroborated join for the first `badScans` scans.
private final class BadJoinObserver: MenuBarObserver, @unchecked Sendable {
    let actuator: FakeActuator
    let subject: ItemKey
    let badScans: Int
    private let lock = NSLock()
    private var n = 0
    init(actuator: FakeActuator, subject: ItemKey, badScans: Int) { self.actuator = actuator; self.subject = subject; self.badScans = badScans }
    private func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    func observe() async throws -> [ResolvedItem] {
        let i = bump()
        let order = await actuator.order, hidden = await actuator.hidden
        var items = FakeMenuBar.resolve(FakeMenuBar.snapshot(order: order, hidden: hidden))
        if i <= badScans { for j in items.indices where items[j].key == subject { items[j].item.joinEvidence = .frameAmbiguous } }
        return items
    }
}

@MainActor
private func rig(bar: [ItemKey], record: [ItemKey], subject: ItemKey, badScans: Int) async -> (LayoutEngine, EngineState) {
    var cfg = LayoutEngine.Config(); cfg.positionRetryBase = .seconds(60); cfg.positionRetryCap = .seconds(60)   // no timer interference
    let act = FakeActuator(order: bar, hidden: [], capabilities: OpenCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let state = EngineState()
    let engine = LayoutEngine(observer: BadJoinObserver(actuator: act, subject: subject, badScans: badScans), actuator: act,
                              store: InMemoryLayoutStore(Layout(visible: record)), capabilities: OpenCaps(), state: state, busy: { false },
                              resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, config: cfg)
    await engine.start()
    return (engine, state)
}

@MainActor
private func arrows(_ s: EngineState) -> Set<ItemKey> {
    let c = ArrangeSections.make(observed: s.observed, layout: s.layout, items: s.items, perItem: s.perItem, capabilities: { _ in Capability(canMove: true, canHide: true) },
                                 unverifiedAfterHandDrag: s.unverifiedAfterHandDrag, lastPlan: s.lastPlan)
    return Set(c.visible.rows.filter { $0.barState == .moving }.map(\.key))
}

@MainActor
@Suite struct PlanSummaryTests {
    private func pending(_ s: EngineState) -> Set<ItemKey> { Set(s.perItem.filter { $0.value == .pending || $0.value == .moving }.map(\.key)) }

    @Test func afterAPassTheArrowRowsAreExactlyThePlansMovingBlockedAndPendingKeys() async {
        let (a, b, c) = (k("a"), k("b"), k("c"))
        for bad in [0, 100] {
            let (engine, state) = await rig(bar: [a, b, c], record: [c, a, b], subject: c, badScans: bad)
            for _ in 0..<3 {
                _ = await engine.reconcileOnce()
                let expected = state.lastPlan.moving.union(state.lastPlan.blocked.keys).union(pending(state))
                    .subtracting(state.perItem.filter { if case .failed = $0.value { true } else { false } }.map(\.key))
                #expect(arrows(state) == expected.intersection(state.layout.visible), "bad=\(bad)")
            }
        }
    }

    @Test func theEnginePublishesItsPlanAndClearsItOnceConverged() async {
        let (a, b, c) = (k("a"), k("b"), k("c"))
        let (engine, state) = await rig(bar: [a, b, c], record: [c, a, b], subject: c, badScans: 0)
        _ = await engine.reconcileOnce()
        #expect(state.lastPlan.moving.isEmpty && state.lastPlan.blocked.isEmpty && state.lastPlan.held.isEmpty)
        #expect(arrows(state).isEmpty)
    }

    @Test func anUncorroboratedKeyThatBlocksAMoveIsPublishedAsTheWall() async {
        let (a, b, c) = (k("a"), k("b"), k("c"))
        let (engine, state) = await rig(bar: [a, b, c], record: [c, a, b], subject: c, badScans: 100)
        _ = await engine.reconcileOnce()
        #expect(state.lastPlan.moving.isEmpty)           // nothing may be dragged against an uncorroborated c
        #expect(!arrows(state).contains(c))
        #expect(Set(state.lastPlan.blocked.keys) == [a, b])
        #expect(arrows(state) == [a, b])   // "Waiting for c to settle", while c itself shows the tilde
        for (key, wall) in state.lastPlan.blocked { #expect(wall == c && key != c) }
    }

    @Test func planSummaryTakesTheSubjectsOfEveryActionAndTheWalls() {
        let plan = Plan(phase: .order, actions: [.move(k("a"), .leftmost), .hide(k("b")), .show(k("c"))], newItems: [], absent: [], skipped: [],
                        desiredOnBar: [], blockedBy: [k("d"): k("e")])
        let s = PlanSummary(plan: plan, held: [k("f")])
        #expect(s.moving == [k("a"), k("b"), k("c")] && s.blocked == [k("d"): k("e")] && s.held == [k("f")])
    }
}
