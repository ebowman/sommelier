import Testing
import Foundation
@testable import SommelierCore

// gdu.105: the gdu.94 uncorroborated-position skip is a transient wait, not a terminal "unsupported".

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private struct OpenCaps: CapabilityProvider { func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) } }

/// Observes the fake actuator's truth; `subject` has a non-corroborated join for the first `badScans` scans (or always when nil).
private final class JoinObserver: MenuBarObserver, @unchecked Sendable {
    let actuator: FakeActuator
    let subject: ItemKey
    let badScans: Int?
    private let lock = NSLock()
    private var n = 0
    init(actuator: FakeActuator, subject: ItemKey, badScans: Int?) { self.actuator = actuator; self.subject = subject; self.badScans = badScans }
    private func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var scans: Int { lock.lock(); defer { lock.unlock() }; return n }
    func observe() async throws -> [ResolvedItem] {
        let i = bump()
        let order = await actuator.order, hidden = await actuator.hidden
        var items = FakeMenuBar.resolve(FakeMenuBar.snapshot(order: order, hidden: hidden))
        if badScans.map({ i <= $0 }) ?? true {
            for j in items.indices where items[j].key == subject { items[j].item.joinEvidence = .frameAmbiguous }
        }
        return items
    }
}

private struct PRig { let engine: LayoutEngine; let state: EngineState; let actuator: FakeActuator; let observer: JoinObserver }

@MainActor
private func prig(badScans: Int?, config: LayoutEngine.Config = .init()) async -> PRig {
    // bar a b c; the layout wants c first, so c is the order-move subject.
    let a = k("a"), b = k("b"), c = k("c")
    let act = FakeActuator(order: [a, b, c], hidden: [], capabilities: OpenCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let obs = JoinObserver(actuator: act, subject: c, badScans: badScans)
    let state = EngineState()
    let engine = LayoutEngine(observer: obs, actuator: act, store: InMemoryLayoutStore(Layout(visible: [c, a, b])),
                              capabilities: OpenCaps(), state: state, busy: { false },
                              resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, config: config)
    await engine.start()
    return PRig(engine: engine, state: state, actuator: act, observer: obs)
}

private func waitUntil(_ cond: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<600 { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
    return false
}

@MainActor
@Suite struct PositionWaitTests {
    private func waitingKeys(_ s: EngineState) -> [ItemKey] { s.perItem.filter { if case .waitingForPosition = $0.value { true } else { false } }.map(\.key) }
    private func unsupported(_ s: EngineState) -> [ItemKey] { s.perItem.filter { if case .unsupported = $0.value { true } else { false } }.map(\.key) }

    @Test func uncorroboratedSubjectWaitsThenMovesOnACorroboratedScan() async {
        var c = LayoutEngine.Config(); c.positionRetryBase = .seconds(60); c.positionRetryCap = .seconds(60)   // no timer interference
        let r = await prig(badScans: 2, config: c)
        let before = await r.actuator.order
        for _ in 0..<2 {
            _ = await r.engine.reconcileOnce()
            #expect(waitingKeys(r.state) == [k("c")])
            #expect(unsupported(r.state).isEmpty)   // 9o9.3: the uncorroborated c is not the "system block"; a and b are not unplaceable
            #expect(await r.actuator.order == before)   // never dragged
        }
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.order.first == k("c"))
        #expect(waitingKeys(r.state).isEmpty && unsupported(r.state).isEmpty)
        #expect(await r.engine.positionWaitInfo.waiting == 0)
    }

    @Test func retryIsScheduledWithoutATriggerAndMovesWhenCorroborated() async {
        var c = LayoutEngine.Config(); c.positionRetryBase = .milliseconds(30); c.positionRetryCap = .milliseconds(60)
        let r = await prig(badScans: 2, config: c)
        _ = await r.engine.reconcileOnce()   // the only explicit pass
        #expect(await waitUntil { await r.actuator.order.first == k("c") })   // later passes came from the retry timer alone
        #expect(r.observer.scans >= 3)
        #expect(await waitUntil { let i = await r.engine.positionWaitInfo; return i.waiting == 0 && i.attempts == 0 })
    }

    @Test func retryDelayDoublesAndIsCapped() {
        let c = LayoutEngine.Config()
        #expect(c.positionRetryBase == .seconds(2) && c.positionRetryCap == .seconds(15) && c.positionWaitTimeout == .seconds(60))
        #expect((0..<6).map { LayoutEngine.positionRetryDelay(attempt: $0, config: c) } == [2, 4, 8, 15, 15, 15].map { Duration.seconds($0) })
        #expect(LayoutEngine.positionRetryDelay(attempt: 500, config: c) == .seconds(15))
    }

    @Test func staysWaitingWithOneRetryAtATimeAndTimesOutToUnsupported() async {
        var c = LayoutEngine.Config()
        c.positionRetryBase = .milliseconds(100); c.positionRetryCap = .milliseconds(200); c.positionWaitTimeout = .seconds(1)
        let r = await prig(badScans: nil, config: c)
        _ = await r.engine.reconcileOnce()
        #expect(waitingKeys(r.state) == [k("c")])
        let ok = await waitUntil { await MainActor.run { self.unsupported(r.state).contains(k("c")) } }
        #expect(ok)
        guard case .unsupported(let why)? = r.state.perItem[k("c")] else { Issue.record("not unsupported"); return }
        #expect(why.hasPrefix("could not corroborate its position on the bar for 1 s: "))
        #expect(why.hasSuffix(Reconciler.uncorroboratedSkipReason))
        #expect(await r.engine.positionWaitInfo.timedOut == 1)
        #expect(await r.actuator.order == [k("a"), k("b"), k("c")])
        // terminal: no further retry is scheduled; Retry (clearFailures) starts a fresh wait
        let scans = r.observer.scans
        try? await Task.sleep(for: .milliseconds(500))
        #expect(r.observer.scans == scans)
        await r.engine.clearFailures()
        #expect(await r.engine.positionWaitInfo == (0, 0, 0))
    }

    // MARK: tracker

    @Test func trackerKeepsWaitingOnWaitingForPositionAndFinishesOnTheRealOutcome() {
        let a = k("a"), c = k("c")
        let layout = Layout(visible: [c, a])
        let wrong = ObservedOrder(resolved: FakeMenuBar.resolved(onBar: [a, c]))
        let right = ObservedOrder(resolved: FakeMenuBar.resolved(onBar: [c, a]))
        var t = ArrangeTracker()
        let t0 = Date()
        t.record([c], passesStarted: 0, now: t0, dropID: 1)
        for i in 1...3 {
            let log = t.update(observed: wrong, layout: layout, perItem: [c: .waitingForPosition("r"), a: .inPlace], passSequence: i,
                               showHiddenSection: false, now: t0.addingTimeInterval(Double(i)))
            #expect(log.isEmpty)
            #expect(t.awaiting == [c])
        }
        let log = t.update(observed: right, layout: layout, perItem: [c: .inPlace, a: .inPlace], passSequence: 4, showHiddenSection: false, now: t0.addingTimeInterval(4))
        #expect(log.count == 1 && log[0].contains("verified in place") && log[0].hasPrefix("drop#1 done"))
        #expect(t.isEmpty)
        // the 60 s timeout status is terminal
        t.record([c], passesStarted: 4, now: t0, dropID: 2)
        let end = t.update(observed: wrong, layout: layout, perItem: [c: .unsupported("could not corroborate its position on the bar for 60 s: r")], passSequence: 5,
                           showHiddenSection: false, now: t0.addingTimeInterval(61))
        #expect(end.count == 1 && end[0].contains("unsupported") && t.isEmpty)
    }

    @Test func badgeAndStatusLineForWaitingForPosition() {
        let b = ArrangeSections.badge(status: .waitingForPosition("r"), running: true, pendingPlacement: false, isAnchor: false)
        #expect(b == .waitingForPosition && b.glyph == "⟳")
        #expect(b.tooltip == "Waiting for a trustworthy read of its position (the last scan could not corroborate where it is)")
        let line = ArrangeSections.statusLine(perItem: [k("c"): .waitingForPosition("r")], lastError: nil, isConverged: false, inFlight: false)
        #expect(line == "Waiting to read 1 item")
    }
}
