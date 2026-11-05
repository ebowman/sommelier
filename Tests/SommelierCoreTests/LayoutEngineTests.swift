import Testing
import Foundation
@testable import SommelierCore

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private let clock = ItemKey.module(name: "Clock")

private struct Caps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability {
        if case .module = key { return Capability(canMove: false, canHide: false, reason: "system module") }
        return Capability(canMove: true, canHide: true)
    }
}

private final class Sleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var d: [Duration] = []
    func add(_ x: Duration) { lock.lock(); d.append(x); lock.unlock() }
    var all: [Duration] { lock.lock(); defer { lock.unlock() }; return d }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

/// Observes whatever the fake actuator currently holds (the truth the real observer would see).
private struct ActuatorObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] {
        let order = await actuator.order, hidden = await actuator.hidden
        return FakeMenuBar.resolve(FakeMenuBar.snapshot(order: order, hidden: hidden))
    }
}

/// First `observe()` blocks until `release()`; later ones return immediately.
private actor GateObserver: MenuBarObserver {
    let items: [ResolvedItem]
    private(set) var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    init(items: [ResolvedItem]) { self.items = items }
    func observe() async throws -> [ResolvedItem] {
        calls += 1
        if calls == 1, !released { await withCheckedContinuation { gate = $0 } }
        return items
    }
    func release() { released = true; gate?.resume(); gate = nil }
}

/// `observeDetailed` hands the first scan to `progress`, then waits for `release()` before settling.
private actor ProgressGate: MenuBarObserver {
    let items: [ResolvedItem]
    private var released = false
    init(items: [ResolvedItem]) { self.items = items }
    func release() { released = true }
    func observe() async throws -> [ResolvedItem] { items }
    func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> BarObservation {
        progress?(items)
        while !released { try? await Task.sleep(for: .milliseconds(5)) }
        return BarObservation(items: items, settled: true)
    }
}

/// The first observation never ends on its own: it waits to be cancelled (as a superseded observation is) and throws
/// `superseded`; later ones return at once, following the fake actuator-independent fixed bar.
private actor SlowFirstObserver: MenuBarObserver {
    let items: [ResolvedItem]
    private(set) var calls = 0
    private(set) var cancelledCalls = 0
    init(items: [ResolvedItem]) { self.items = items }
    func observe() async throws -> [ResolvedItem] { try await observeDetailed(progress: nil).items }
    func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> BarObservation {
        calls += 1
        if calls == 1 {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            cancelledCalls += 1
            throw ObserveError.superseded
        }
        return BarObservation(items: items, settled: true)
    }
}

/// Wraps the actuator's truth in an observation with a given read level (gdu.51).
private final class ActuatorBox: @unchecked Sendable { var actuator: FakeActuator? }
private struct LevelObserver: MenuBarObserver {
    let box: ActuatorBox
    let level: ReadCompleteness
    func observe() async throws -> [ResolvedItem] { try await ActuatorObserver(actuator: box.actuator!).observe() }
    func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> BarObservation {
        BarObservation(items: try await observe(), settled: true, scans: 2, completeness: level)
    }
}

/// Like `LevelObserver` but the read level can change between passes.
private final class MutableLevelObserver: MenuBarObserver, @unchecked Sendable {
    let box: ActuatorBox
    var level: ReadCompleteness
    init(box: ActuatorBox, level: ReadCompleteness) { self.box = box; self.level = level }
    func observe() async throws -> [ResolvedItem] { try await ActuatorObserver(actuator: box.actuator!).observe() }
    func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> BarObservation {
        BarObservation(items: try await observe(), settled: true, scans: 2, completeness: level)
    }
}

private let istat = ItemKey.status(ownerKey: "com.bjango.istatmenus.status", autosaveName: "cpu")

private struct Rig {
    let engine: LayoutEngine
    let state: EngineState
    let actuator: FakeActuator
    let store: InMemoryLayoutStore
    let sleeps: Sleeps
}

@MainActor
private func rig(order: [ItemKey], hidden: Set<ItemKey> = [], layout: Layout,
                 observer: (any MenuBarObserver)? = nil, busy: @escaping @Sendable () -> Bool = { false },
                 config: LayoutEngine.Config = .init(), failOn: [(Int, ActuationError)] = []) async -> Rig {
    let act = FakeActuator(order: order, hidden: hidden, capabilities: Caps(),
                           makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    for (n, e) in failOn { await act.failOnCall(n, e) }
    let store = InMemoryLayoutStore(layout)
    let state = EngineState()
    let sleeps = Sleeps()
    let engine = LayoutEngine(observer: observer ?? ActuatorObserver(actuator: act), actuator: act, store: store,
                              capabilities: Caps(), state: state, busy: busy,
                              resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { sleeps.add($0) },
                              config: config)
    await engine.start()
    return Rig(engine: engine, state: state, actuator: act, store: store, sleeps: sleeps)
}

private func waitUntil(_ cond: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@MainActor
@Suite struct LayoutEngineTests {
    @Test func setLayoutNormalizesASplitUnitAndReportsIt() async {
        let a1 = ItemKey.status(ownerKey: "com.app.a", autosaveName: "1"), a2 = ItemKey.status(ownerKey: "com.app.a", autosaveName: "2")
        let r = await rig(order: [a1, a2, k("B")], layout: Layout(visible: [a1, a2, k("B")]))
        let split = Layout(visible: [a1, k("B")], hidden: [a2])
        await r.engine.setLayout(split)
        let want = Layout(visible: [a1, k("B"), a2])
        #expect(r.state.layout == want)
        #expect(r.state.lastNormalization == [a2])
        #expect((try? r.store.load()) == want)
        await r.engine.setLayout(want)
        #expect(r.state.lastNormalization.isEmpty)
    }

    // MARK: gdu.55 - applied per the store, confirmation pending; failed live writes

    @Test func unconfirmedHideIsInPlaceWithAMarkerUntilALaterCompleteReadConfirms() async {
        let r = await rig(order: [k("A"), k("B")], layout: Layout(visible: [k("A")], hidden: [k("B")]))
        await r.actuator.scriptUnconfirmed()
        _ = await r.engine.reconcileOnce()
        #expect(r.state.pendingConfirmation == [k("B")] && r.state.perItem[k("B")] == .inPlace)
        #expect(r.state.lastError == nil)
        #expect(ArrangeSections.badge(status: .inPlace, running: true, pendingPlacement: false, isAnchor: false, pendingConfirmation: true) == .inPlacePending)
        #expect(ArrangeBadge.inPlacePending.glyph == "✓" && ArrangeBadge.inPlacePending.tooltip.contains("confirmation pending"))
        _ = await r.engine.reconcileOnce()      // a later settled complete read
        #expect(r.state.pendingConfirmation.isEmpty && r.state.perItem[k("B")] == .inPlace)
    }

    @Test func contradictedUnconfirmedHideIsReplannedNotStruckOut() async {
        let r = await rig(order: [k("A"), k("B")], layout: Layout(visible: [k("A")], hidden: [k("B")]))
        await r.actuator.scriptUnconfirmed(applyChange: false)   // store said applied, the bar still shows B
        _ = await r.engine.reconcileOnce()
        if case .failed? = r.state.perItem[k("B")] { Issue.record("an unconfirmed hide must not be a failure") }
        _ = await r.engine.reconcileOnce()      // next pass re-plans the hide from a fresh read
        #expect(await r.actuator.hidden == [k("B")])
        #expect(await r.actuator.calls.count == 2)
        #expect(r.state.pendingConfirmation.isEmpty)
    }

    @Test func liveWriteFailureIsFailedNotUnsupportedAndNotRetried() async {
        let r = await rig(order: [k("A"), k("B")], layout: Layout(visible: [k("A")], hidden: [k("B")]),
                          failOn: [(1, .liveWriteFailed("readback"))])
        _ = await r.engine.reconcileOnce()
        #expect(r.state.perItem[k("B")] == .failed(.liveWriteFailed("readback")))
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == 1)   // struck out at once: a failing write is not retried by itself
        #expect(ArrangeSections.describe(.liveWriteFailed("readback")).contains("readback"))
    }

    // gdu.33: self-positioning owners are planner anchors, so a layout that lists them "elsewhere" no longer makes the
    // order depend on a complete read (formerly orderInvolvingSelfPositioningOwnerWaitsForACompleteRead): the iStat item
    // is never moved, the others are ordered around it.
    @Test func layoutOrderOfSelfPositioningOwnerIsIgnoredNotWaitedFor() async {
        let order = [istat, k("A"), k("B")]
        let layout = Layout(visible: [k("B"), k("A"), istat])
        let box = ActuatorBox()
        let r = await rig(order: order, layout: layout, observer: LevelObserver(box: box, level: .completeExceptSelfPositioning))
        box.actuator = r.actuator
        _ = await r.engine.reconcileOnce()
        let final = await r.actuator.order
        #expect(final.first == istat)
        #expect(final == [istat, k("B"), k("A")])
    }

    // gdu.61: the gdu.51 gate. A move of an ordinary item whose relation target is a self-positioning item waits for a
    // COMPLETE read (the target's frame is not trusted while its items are stale); it is not a failure and proceeds later.
    @Test func moveNextToSelfPositioningItemWaitsForACompleteRead() async {
        let order = [k("A"), istat, k("B")]
        let layout = Layout(visible: [k("B"), istat, k("A")])   // B is placed before iStat (never dragged); the bar ends [B, A, istat] since anchor slots are kept per pass, not across passes
        let box = ActuatorBox()
        let obs = MutableLevelObserver(box: box, level: .completeExceptSelfPositioning)
        let r = await rig(order: order, layout: layout, observer: obs)
        box.actuator = r.actuator
        let first = await r.engine.reconcileOnce()
        #expect(first.outcome == .unsettled)
        #expect(await r.actuator.calls.isEmpty)
        #expect(await r.actuator.order == order)
        #expect(r.state.perItem.values.allSatisfy { if case .failed = $0 { false } else { true } })
        obs.level = .complete
        let second = await r.engine.reconcileOnce()
        #expect(second.outcome != .unsettled)
        let calls = await r.actuator.calls
        #expect(calls.contains { if case .move(_, .before(let t)) = $0 { t == istat } else if case .move(_, .after(let t)) = $0 { t == istat } else { false } })
        #expect(await r.actuator.order != order)
    }

    // gdu.67: a persisted layout that straddles the self-positioning item is unreachable. The planner still ends [B, A, istat] and
    // converges; the engine then rewrites the layout to that order, records it once, and the next pass has nothing to normalize.
    @Test func aStraddlingLayoutIsNormalizedAroundTheSelfPositioningItemOnce() async {
        let order = [k("A"), istat, k("B")]
        let layout = Layout(visible: [k("B"), istat, k("A")])
        let r = await rig(order: order, layout: layout)
        var passes = 0
        while passes < 4 {
            passes += 1
            if await r.engine.reconcileOnce().outcome == .converged, !r.state.lastNormalization.isEmpty || passes > 1 { break }
        }
        #expect(await r.actuator.order == [k("B"), k("A"), istat])
        #expect(r.state.layout.visible == [k("B"), k("A"), istat])
        #expect((try? r.store.load())?.visible == [k("B"), k("A"), istat])
        #expect(r.state.lastNormalization == [istat])
        let revision = r.state.layoutRevision
        let calls = await r.actuator.calls.count
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .converged)
        #expect(r.state.layoutRevision == revision)           // not re-triggered
        #expect(await r.actuator.calls.count == calls)
    }

    @Test func aLayoutThatAgreesWithTheBarAroundTheSelfPositioningItemIsNotNormalized() async {
        let order = [k("A"), istat, k("B")]
        let r = await rig(order: order, layout: Layout(visible: order))
        let revision = r.state.layoutRevision
        _ = await r.engine.reconcileOnce()
        #expect(r.state.lastNormalization.isEmpty)
        #expect(r.state.layoutRevision == revision)
    }

    @Test func orderAmongOthersProceedsOnAnExceptSelfPositioningRead() async {
        let order = [istat, k("A"), k("B")]
        let layout = Layout(visible: [istat, k("B"), k("A")])
        let box = ActuatorBox()
        let r = await rig(order: order, layout: layout, observer: LevelObserver(box: box, level: .completeExceptSelfPositioning))
        box.actuator = r.actuator
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome != .unsettled)
        #expect(await r.actuator.order != order)
    }

    @Test func convergesInOnePass() async {
        let r = await rig(order: ["A", "B", "C"].map(k), layout: Layout(visible: ["C", "B", "A"].map(k)))
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .converged)
        #expect(rep.actionCount == 2)
        #expect(await r.actuator.order == ["C", "B", "A"].map(k))
        #expect(r.state.observed.onBar == ["C", "B", "A"].map(k))
        #expect(r.state.isConverged)
        #expect(r.state.passCount == 1)
        #expect(r.state.perItem.values.allSatisfy { $0 == .inPlace })
        #expect(r.state.inFlight == nil)
    }

    @Test func anAnchoredFailureOnlyCostsOnePass() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: ["B", "A"].map(k)),
                          failOn: [(1, .mechanismFailed("boom"))])
        let first = await r.engine.reconcileOnce()
        #expect(first.outcome == .incomplete)
        #expect(await r.actuator.order == ["B", "A"].map(k))   // the other item was moved around the failed anchor
        guard case .move(let failedKey, _)? = await r.actuator.calls.first.flatMap({ c -> PlannedAction? in
            if case .move(let key, let rel) = c { return .move(key, rel) } else { return nil } }) else {
            Issue.record("expected a move call"); return
        }
        #expect(r.state.perItem[failedKey] == .failed(.mechanismFailed("boom")))
        #expect(!r.state.isConverged)
        let n = await r.actuator.calls.count
        let second = await r.engine.reconcileOnce()   // the failed key is retried (strike 1 < 3), but there is nothing left to do
        #expect(await r.actuator.calls.count == n)
        #expect(second.outcome == .converged)
        await r.engine.clearFailures()
        let again = await r.engine.reconcileOnce()
        // The failed key was an anchor while suppressed: the other item was moved around it, so nothing is left to retry.
        #expect(await r.actuator.calls.count == n)
        #expect(again.outcome == .converged)
        #expect(r.state.perItem[failedKey] == .inPlace)
    }

    @Test func unknownItemPersistedVisibleAtEnd() async {
        let r = await rig(order: ["A", "B", "C"].map(k), layout: Layout(visible: ["A", "B"].map(k)))
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .converged)
        #expect((try? r.store.load().visible) == ["A", "B", "C"].map(k))
        #expect(r.state.layout.visible == ["A", "B", "C"].map(k))
    }

    @Test func unknownItemPersistedHiddenPolicyThenHidden() async {
        let r = await rig(order: ["A", "B", "C"].map(k),
                          layout: Layout(visible: ["A", "B"].map(k), newItemPolicy: .hidden))
        let rep = await r.engine.reconcileOnce()
        #expect((try? r.store.load().hidden) == [k("C")])
        #expect(rep.outcome == .converged)
        #expect(await r.actuator.hidden == [k("C")])
        #expect(r.state.observed.parked == [k("C")])
    }

    @Test func busyPausesThenRuns() async {
        let c = Counter()
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: ["B", "A"].map(k)), busy: { c.next() <= 5 })
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .converged)
        #expect(r.sleeps.all.contains(.milliseconds(100)))
        #expect(await r.actuator.calls.count == 1)
    }

    @Test func busyForeverSkips() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: ["B", "A"].map(k)), busy: { true })
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .skippedBusy)
        #expect(await r.actuator.calls.isEmpty)
        #expect(r.sleeps.all.count == 30)
    }

    // MARK: gdu.46 unsettled observations and pass latency

    @Test func unsettledObservationIsPublishedAndNothingIsPlanned() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: ["B", "A"].map(k)),
                          observer: FixtureObserver(unsettled: FakeMenuBar.resolved(onBar: ["A", "B"].map(k))))
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .unsettled)
        #expect(r.state.observed.onBar == ["A", "B"].map(k))
        #expect(!r.state.observationSettled)
        #expect(r.state.lastError == nil)
        #expect(await r.actuator.calls.isEmpty)   // would have needed one move on a settled observation
    }

    @Test func settledObservationActsAndClearsTheFlag() async {
        let items = FakeMenuBar.resolved(onBar: ["A", "B"].map(k))
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: ["B", "A"].map(k)),
                          observer: FixtureObserver(steps: [.unsettled(items), .items(items)]))
        #expect(await r.engine.reconcileOnce().outcome == .unsettled)
        #expect(await r.actuator.calls.isEmpty)
        let second = await r.engine.reconcileOnce()
        #expect(second.actionCount == 1)
        #expect(r.state.observationSettled)
        #expect(await r.actuator.calls.count == 1)
    }

    @Test func staleItemKeepsItsInfoUntilACompleteReadDropsIt() async {
        let fresh = FakeMenuBar.resolved(onBar: ["A", "B"].map(k))
        var staleA = fresh
        staleA[0].item.stale = true
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: ["A", "B"].map(k)),
                          observer: FixtureObserver([fresh, staleA, fresh, Array(fresh.dropFirst())]))
        _ = await r.engine.reconcileOnce()
        let before = r.state.items[k("A")]
        #expect(before != nil)
        _ = await r.engine.reconcileOnce()          // a fast scan marks A stale
        #expect(r.state.items[k("A")] == before)
        _ = await r.engine.reconcileOnce()
        _ = await r.engine.reconcileOnce()          // a read without A
        #expect(r.state.items[k("A")] == nil && r.state.items[k("B")] != nil)
    }

    @Test func unsettledObservationClearsAnEarlierObserveError() async {
        let items = FakeMenuBar.resolved(onBar: ["A", "B"].map(k))
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: ["A", "B"].map(k)),
                          observer: FixtureObserver(steps: [.failure(.noAgreement(scans: 6)), .unsettled(items)]))
        _ = await r.engine.reconcileOnce()
        #expect(r.state.lastError == .observe("scans did not agree after 6 attempts"))
        _ = await r.engine.reconcileOnce()
        #expect(r.state.lastError == nil && !r.state.observationSettled)
    }

    @Test func firstCompleteScanIsPublishedBeforeAgreement() async {
        let items = FakeMenuBar.resolved(onBar: ["A", "B"].map(k))
        let gate = ProgressGate(items: items)
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: ["A", "B"].map(k)), observer: gate)
        await r.engine.requestReconcile()
        #expect(await waitUntil { await MainActor.run { r.state.observed.onBar == ["A", "B"].map(k) } })
        #expect(await MainActor.run { !r.state.observationSettled })
        await gate.release()
        #expect(await waitUntil { await MainActor.run { r.state.observationSettled && r.state.isConverged } })
    }

    @Test func setLayoutAbandonsAnObservationInProgressAndStartsAPassAtOnce() async {
        let items = FakeMenuBar.resolved(onBar: ["A", "B"].map(k))
        let slow = SlowFirstObserver(items: items)
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: ["A", "B"].map(k)), observer: slow)
        await r.engine.requestReconcile()                       // a poll-style pass starts observing and blocks
        #expect(await waitUntil { await slow.calls == 1 })
        await r.engine.requestReconcile()                       // a plain trigger must NOT abandon it
        try? await Task.sleep(for: .milliseconds(60))
        #expect(await slow.calls == 1)
        await r.engine.setLayout(Layout(visible: ["B", "A"].map(k)))   // the user's drop abandons it
        #expect(await waitUntil { await MainActor.run { r.state.isConverged && r.state.observed.onBar == ["B", "A"].map(k) } })
        #expect(await slow.calls >= 2)
        #expect(await slow.cancelledCalls == 1)
    }

    @Test func permissionDeniedStopsUntilCleared() async {
        let obs = FixtureObserver(throwing: .permissionDenied)
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: ["B", "A"].map(k)), observer: obs)
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .permissionDenied)
        #expect(r.state.lastError == .permissionDenied)
        #expect(await r.actuator.calls.isEmpty)
        await r.engine.requestReconcile()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(obs.calls == 1)
        await r.engine.clearFailures()
        await r.engine.requestReconcile()
        #expect(await waitUntil { obs.calls == 2 })
    }

    @Test func observeEmptyIsAnErrorWithoutActions() async {
        let r = await rig(order: ["A"].map(k), layout: Layout(visible: [k("A")]), observer: FixtureObserver([[]]))
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .observeFailed)
        if case .observe? = r.state.lastError {} else { Issue.record("expected .observe error") }
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func corruptLayoutStopsEngine() async {
        struct BadStore: LayoutStore {
            func load() throws -> Layout { throw LayoutError.badKey("x") }
            func save(_ layout: Layout) throws {}
        }
        let act = FakeActuator(order: [k("A")])
        let state = EngineState()
        let engine = LayoutEngine(observer: FixtureObserver([[]]), actuator: act, store: BadStore(), capabilities: Caps(),
                                  state: state, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in })
        await engine.start()
        if case .observe? = state.lastError {} else { Issue.record("expected .observe error") }
        #expect(await engine.reconcileOnce().outcome == .stopped)
        #expect(await act.calls.isEmpty)
    }

    @Test func unsupportedCapabilityDoesNotBlockConvergence() async {
        let r = await rig(order: [k("B"), k("A"), clock], layout: Layout(visible: ["A", "B"].map(k), alwaysHidden: [clock]))
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .converged)
        #expect(r.state.isConverged)
        if case .unsupported? = r.state.perItem[clock] {} else { Issue.record("Clock should be unsupported") }
        #expect(r.state.perItem[k("A")] == .inPlace)
        #expect(r.state.observed.onBar == [k("A"), k("B"), clock])
    }

    @Test func membershipBatchThenOrderInSamePass() async {
        let r = await rig(order: ["A", "B", "C"].map(k), hidden: [k("B")],
                          layout: Layout(visible: ["B", "A", "C"].map(k)))
        let rep = await r.engine.reconcileOnce()
        let calls = await r.actuator.calls
        #expect(calls.first == .applyHiddenBatch([k("B"): false]))
        #expect(calls.filter { if case .applyHiddenBatch = $0 { true } else { false } }.count == 1)
        #expect(calls.count >= 2)
        #expect(rep.outcome == .converged)
        #expect(r.state.observed.onBar == ["B", "A", "C"].map(k))
    }

    @Test func mechanismFailedBatchEndsPassWithStickyBatchFailed() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: [k("A")], hidden: [k("B")]),
                          failOn: [(1, .mechanismFailed("restart"))])
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .incomplete)
        #expect(r.state.perItem[k("B")] == .failed(.mechanismFailed("restart")))
        #expect(await r.actuator.calls.count == 1)
        let sticky = r.state.lastError
        guard case .batchFailed? = sticky else { Issue.record("expected batchFailed, got \(String(describing: sticky))"); return }
        // A later successful observe does not clear it; clearFailures does.
        _ = await r.engine.reconcileOnce()
        #expect(r.state.lastError == sticky)
        await r.engine.clearFailures()
        #expect(r.state.lastError == nil)
    }

    @Test func partiallyRefusedBatchConvergesAppliedUnitsAndSkipsTheRefusedOne() async {
        let r = await rig(order: ["A", "B", "C"].map(k), layout: Layout(hidden: ["A", "B", "C"].map(k)))
        await r.actuator.setRefusals([k("C"): "cannot hide: not tracked by Control Center"])
        let rep = await r.engine.reconcileOnce()
        let calls = await r.actuator.calls
        #expect(calls.filter { if case .applyHiddenBatch = $0 { true } else { false } }.count == 1)
        #expect(await r.actuator.hidden == Set(["A", "B"].map(k)))   // one write, the two applicable units
        #expect(rep.outcome == .converged)
        #expect(r.state.perItem[k("A")] == .inPlace && r.state.perItem[k("B")] == .inPlace)
        if case .unsupported(let why)? = r.state.perItem[k("C")] { #expect(why.contains("not tracked")) } else { Issue.record("C should be unsupported, got \(String(describing: r.state.perItem[k("C")]))") }
        #expect(r.state.lastError == nil)
        // Not retried every pass.
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == calls.count)
        #expect(r.state.lastError == nil)
    }

    @Test func allRefusedBatchWritesNothingAndConvergesWithSkips() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(hidden: ["A", "B"].map(k)))
        await r.actuator.setRefusals([k("A"): "cannot hide: not tracked by Control Center", k("B"): "cannot hide: Apple app"])
        let rep = await r.engine.reconcileOnce()
        #expect(await r.actuator.hidden.isEmpty)
        #expect(rep.outcome == .converged)
        #expect(r.state.lastError == nil)
        if case .unsupported(let why)? = r.state.perItem[k("B")] { #expect(why.contains("Apple app")) } else { Issue.record("B should be unsupported") }
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == 1)
    }

    // MARK: gdu.74 - per-pass capability snapshot, refused-unit re-evaluation

    private final class TrackedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: Set<String>
        init(_ k: Set<String>) { keys = k }
        func set(_ k: Set<String>) { lock.lock(); keys = k; lock.unlock() }
        func resolver() -> TrackedEntryResolver { lock.lock(); defer { lock.unlock() }; return TrackedEntryResolver(keys: keys) }
    }

    private func snapshotConfig(_ box: TrackedBox) -> LayoutEngine.Config {
        var c = LayoutEngine.Config()
        c.trackedResolver = { box.resolver() }
        c.capabilitiesFor = { EngineFactory.makeCapabilityRules(resolver: $0, bundleID: { _ in nil }) }
        return c
    }

    private func hideBatches(_ r: Rig) async -> Int {
        await r.actuator.calls.filter { if case .applyHiddenBatch = $0 { true } else { false } }.count
    }

    @Test func planningFollowsATrackedEntryThatAppearsAfterLaunchWithoutRetry() async {
        let box = TrackedBox(["com.x.A"])
        let r = await rig(order: [k("A"), k("B")], layout: Layout(visible: [k("A")], hidden: [k("B")]), config: snapshotConfig(box))
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.hidden.isEmpty)   // B untracked: planner skips it, nothing written
        if case .unsupported? = r.state.perItem[k("B")] {} else { Issue.record("B should be unsupported, got \(String(describing: r.state.perItem[k("B")]))") }
        box.set(["com.x.A", "com.x.B"])
        let rep = await r.engine.reconcileOnce()
        #expect(await r.actuator.hidden == [k("B")])
        #expect(rep.outcome == .converged && r.state.perItem[k("B")] == .inPlace)
    }

    @Test func aRefusedKeyIsRetriedWhenTheEntryReappearsAndNeedsNoRetryButton() async {
        let box = TrackedBox(["com.x.A", "com.x.B", "com.x.C"])
        let r = await rig(order: [k("A"), k("B"), k("C")], layout: Layout(visible: [k("C")], hidden: [k("A"), k("B")]), config: snapshotConfig(box))
        await r.actuator.setRefusals([k("B"): "cannot hide: not tracked by Control Center"])
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.hidden == [k("A")])
        // (c) the snapshot did not change: still refused, no new write, no strike
        let before = await hideBatches(r)
        _ = await r.engine.reconcileOnce()
        #expect(await hideBatches(r) == before)
        if case .unsupported? = r.state.perItem[k("B")] {} else { Issue.record("B should stay unsupported") }
        #expect(r.state.lastError == nil)
        // entry disappears: the rules refuse it now, it stays unsupported (still no write)
        box.set(["com.x.A", "com.x.C"])
        _ = await r.engine.reconcileOnce()
        #expect(await hideBatches(r) == before)
        if case .unsupported? = r.state.perItem[k("B")] {} else { Issue.record("B should stay unsupported while untracked") }
        // entry appears again and the actuator accepts: planned and applied in the next pass
        await r.actuator.setRefusals([:])
        box.set(["com.x.A", "com.x.B", "com.x.C"])
        let rep = await r.engine.reconcileOnce()
        #expect(await r.actuator.hidden == Set([k("A"), k("B")]))
        #expect(rep.outcome == .converged && r.state.perItem[k("B")] == .inPlace)
    }

    @Test func aRefusedKeyThatVanishesIsPrunedWithNoStaleStatus() async {
        let box = TrackedBox(["com.x.A", "com.x.B", "com.x.C"])
        let r = await rig(order: [k("A"), k("B"), k("C")], layout: Layout(visible: [k("C")], hidden: [k("A"), k("B")]), config: snapshotConfig(box))
        await r.actuator.setRefusals([k("B"): "cannot hide: not tracked by Control Center"])
        _ = await r.engine.reconcileOnce()
        if case .unsupported? = r.state.perItem[k("B")] {} else { Issue.record("B should be unsupported") }
        await r.actuator.setRefusals([:])
        await r.actuator.removeItem(k("B"))
        _ = await r.engine.reconcileOnce()
        #expect(r.state.perItem[k("B")] == nil)
        await r.actuator.addItem(k("B"))   // it comes back: not pinned by the old refusal
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.hidden.contains(k("B")))
    }

    @Test func revealSkipReasonFollowsTheCapabilityReason() {
        let apple = ItemKey.status(ownerKey: "com.apple.foo", autosaveName: "a"), untracked = k("U"), v = k("V")
        let rules = EngineFactory.makeCapabilityRules(tracked: ["com.x.V"], bundleID: { _ in nil })
        let l = Layout(visible: [v], hidden: [apple, untracked])
        let p = Reconciler().plan(observed: ObservedOrder(onBar: [v], parked: [apple, untracked]), layout: l,
                                  capabilities: { rules.capability(for: $0) }, showHiddenSection: true)
        let why = Dictionary(uniqueKeysWithValues: p.skipped.map { ($0.key, $0.reason) })
        #expect(why[apple]?.contains("Apple apps") == true)
        #expect(why[untracked]?.contains("no Control Center entry") == true)
    }

    @Test func userBusyBatchIsNotAFailureAndReschedulesThePass() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: [k("A")], hidden: [k("B")]),
                          failOn: [(1, .userBusy)])
        await r.engine.requestReconcile()
        // The rescheduled (second) pass is observable as a second actuator call, which then converges.
        #expect(await waitUntil { await r.actuator.calls.count == 2 })
        #expect(await waitUntil { await MainActor.run { r.state.isConverged } })
        #expect(r.state.lastError == nil)
        #expect(r.state.perItem.values.allSatisfy { if case .failed = $0 { false } else { true } })
        #expect(await r.actuator.hidden == [k("B")])
    }

    @Test func userBusyBatchWithoutDrainDoesNotSuppress() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: [k("A")], hidden: [k("B")]),
                          failOn: [(1, .userBusy)])
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .incomplete)
        #expect(r.state.perItem.values.allSatisfy { if case .failed = $0 { false } else { true } })
        #expect(r.state.perItem[k("B")] == .pending)
        let again = await r.engine.reconcileOnce()
        #expect(again.outcome == .converged)
    }

    @Test func driftedBatchSetsBatchDriftAndNeverDrags() async {
        // H must be hidden; C and A are out of order so an order phase would have run.
        let r = await rig(order: ["A", "H", "B", "C"].map(k), layout: Layout(visible: ["C", "A", "B"].map(k), hidden: [k("H")]))
        await r.actuator.scriptDrift(onCall: 1, expected: "a", observed: "b")
        let rep = await r.engine.reconcileOnce()
        let calls = await r.actuator.calls
        #expect(calls.count == 1)
        #expect(calls.allSatisfy { if case .move = $0 { false } else { true } })
        #expect(rep.outcome == .incomplete)
        #expect(r.state.lastError == .batchDrift(expected: "a", observed: "b"))
        #expect(!r.state.isConverged)
        #expect(r.state.perItem[k("H")] == .inPlace)
        #expect(await r.actuator.hidden == [k("H")])

        // The next pass runs normally and drags, but the error stays until cleared.
        let again = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.contains { if case .move = $0 { true } else { false } })
        #expect(again.outcome == .converged)
        #expect(r.state.lastError == .batchDrift(expected: "a", observed: "b"))
        await r.engine.clearFailures()
        #expect(r.state.lastError == nil)
        _ = await r.engine.reconcileOnce()
        #expect(r.state.lastError == nil)
        #expect(r.state.isConverged)
    }

    @Test func userBusyBatchIsNotBatchDrift() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: [k("A")], hidden: [k("B")]),
                          failOn: [(1, .userBusy)])
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .incomplete)
        #expect(r.state.lastError == nil)
    }

    @Test func concurrentTriggersCoalesce() async {
        let items = FakeMenuBar.resolved(onBar: ["A", "B", "C"].map(k))
        let gate = GateObserver(items: items)
        let r = await rig(order: ["A", "B", "C"].map(k), layout: Layout(visible: ["A", "B", "C"].map(k)), observer: gate)
        await r.engine.requestReconcile()
        #expect(await waitUntil { await gate.calls == 1 })
        await r.engine.requestReconcile()
        await r.engine.requestReconcile()
        await r.engine.requestReconcile()
        await gate.release()
        let state = r.state
        #expect(await waitUntil { await MainActor.run { state.passCount } == 2 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await gate.calls == 2)
        #expect(r.state.passCount == 2)
    }

    @Test func maxActionsPerPassRespected() async {
        var cfg = LayoutEngine.Config()
        cfg.maxActionsPerPass = 1
        let r = await rig(order: ["A", "B", "C", "D"].map(k), layout: Layout(visible: ["D", "C", "B", "A"].map(k)), config: cfg)
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .incomplete)
        #expect(rep.actionCount == 1)
        #expect(await r.actuator.calls.count == 1)
    }

    @Test func userBusyEndsPassWithoutSuppressing() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: ["B", "A"].map(k)),
                          failOn: [(1, .userBusy)])
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .incomplete)
        #expect(r.state.perItem.values.allSatisfy { if case .failed = $0 { false } else { true } })
        let again = await r.engine.reconcileOnce()
        #expect(again.outcome == .converged)
    }

    @Test func stopsAfterThreeConsecutiveFailures() async {
        let names = ["A", "B", "C", "D", "E", "F"]
        let r = await rig(order: names.map(k), layout: Layout(visible: names.reversed().map(k)),
                          failOn: [(1, .mechanismFailed("x")), (2, .mechanismFailed("x")), (3, .mechanismFailed("x"))])
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .incomplete)
        #expect(rep.actionCount == 3)
        #expect(await r.actuator.calls.count == 3)
        #expect(r.state.lastError == nil)   // one pass of failures strikes the keys; the engine stops only after 3 such passes
        let failed = r.state.perItem.values.filter { if case .failed = $0 { true } else { false } }.count
        #expect(failed == 3)
        #expect(r.state.perItem.values.contains(.pending))
        // No chained pass follows.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await r.actuator.calls.count == 3)
    }

    @Test func overflowRefusalsAreSkipsNotStrikes() async {
        // gdu.69: the actuator refuses a drag whose subject or anchor sits in macOS's overflow area. Three such refusals in
        // a row (three passes) must not mark any key failed, and the pass must not count them as failed actions.
        let msg = "A \(ActuationError.overflowRefusalMarker) (hidden by macOS because the bar is full); a drag cannot reach it"
        let names = ["A", "B", "C"]
        let r = await rig(order: names.map(k), layout: Layout(visible: names.reversed().map(k)),
                          failOn: (1...12).map { ($0, ActuationError.mechanismFailed(msg)) })
        for _ in 0..<4 {
            let rep = await r.engine.reconcileOnce()
            #expect(rep.outcome != .stopped)
        }
        #expect(r.state.lastError == nil)
        #expect(r.state.perItem.values.allSatisfy { if case .failed = $0 { false } else { true } })
        #expect(r.state.perItem.values.contains { if case .unsupported(let t) = $0 { t == Reconciler.overflowSkipReason } else { false } })
    }

    @Test func neverRunsWithoutALoadedLayout() async {
        final class CountingStore: LayoutStore, @unchecked Sendable {
            let lock = NSLock(); var saves = 0
            func load() throws -> Layout { throw LayoutError.badKey("x") }
            func save(_ layout: Layout) throws { lock.lock(); saves += 1; lock.unlock() }
        }
        let store = CountingStore()
        let act = FakeActuator(order: [k("A")])
        let obs = FixtureObserver([FakeMenuBar.resolved(onBar: [k("A")])])
        let state = EngineState()
        let engine = LayoutEngine(observer: obs, actuator: act, store: store, capabilities: Caps(), state: state,
                                  resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in })
        await engine.start()
        await engine.clearFailures()
        await engine.requestReconcile()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(obs.calls == 0)
        #expect(store.saves == 0)
        #expect(state.lastError == .observe("layout not loaded"))
        #expect(await engine.reconcileOnce().outcome == .stopped)
        #expect(obs.calls == 0)
        #expect(await act.calls.isEmpty)
    }

    @Test func stoppedAfterFailuresSurvivesObserveAndIsClearedExplicitly() async {
        let names = ["A", "B", "C", "D", "E"]
        let r = await rig(order: names.map(k), layout: Layout(visible: names.reversed().map(k)),
                          failOn: (1...12).map { ($0, ActuationError.mechanismFailed("x")) })
        _ = await r.engine.reconcileOnce(); _ = await r.engine.reconcileOnce()
        #expect(r.state.lastError == nil)
        _ = await r.engine.reconcileOnce()
        #expect(r.state.lastError == .stoppedAfterFailures(3))   // the third pass in a row in which every action failed
        _ = await r.engine.reconcileOnce()   // a successful observe must not clear it
        #expect(r.state.lastError == .stoppedAfterFailures(3))
        await r.engine.clearFailures()
        #expect(r.state.lastError == nil)
        await r.engine.setLayout(Layout(visible: names.map(k)))
        #expect(r.state.lastError == nil)
    }

    @Test func chainedPassesAreCappedAtTwoAndRespectMinInterval() async {
        var cfg = LayoutEngine.Config()
        cfg.maxActionsPerPass = 1
        let names = ["A", "B", "C", "D", "E"]
        let r = await rig(order: names.map(k), layout: Layout(visible: names.reversed().map(k)), config: cfg)
        await r.engine.requestReconcile()
        let state = r.state
        #expect(await waitUntil { await MainActor.run { state.passCount } >= 3 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(r.state.passCount == 3)             // the requested pass plus at most 2 chained ones
        #expect(await r.actuator.calls.count == 3)
        let gaps = r.sleeps.all.filter { $0 > .milliseconds(400) && $0 <= .milliseconds(500) }
        #expect(gaps.count >= 2)                    // 500 ms minimum between pass starts, via the injected sleep
    }

    @Test func suppressedKeyIsDroppedWhenItDisappears() async {
        let both = FakeMenuBar.resolved(onBar: [k("A"), k("B")])
        let onlyA = FakeMenuBar.resolved(onBar: [k("A")])
        let obs = FixtureObserver([both, onlyA, both])
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: [k("A")], hidden: [k("B")]), observer: obs,
                          failOn: [(1, .mechanismFailed("restart"))])
        _ = await r.engine.reconcileOnce()
        #expect(r.state.perItem[k("B")] == .failed(.mechanismFailed("restart")))
        #expect(await r.actuator.calls.count == 1)
        _ = await r.engine.reconcileOnce()           // B gone: its suppression is dropped
        #expect(r.state.perItem[k("B")] == nil)
        _ = await r.engine.reconcileOnce()           // B is back: retried
        #expect(await r.actuator.calls.count == 2)
    }

    @Test func sameKeyFailingThreePassesInARowIsFailedUntilRetry() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: [k("A")], hidden: [k("B")]),
                          failOn: [(1, .mechanismFailed("restart")), (2, .mechanismFailed("restart")), (3, .mechanismFailed("restart"))])
        for expected in 1...3 {
            let rep = await r.engine.reconcileOnce()
            #expect(rep.outcome == .incomplete)
            #expect(await r.actuator.calls.count == expected)   // strikes 1 and 2 are retried by the next pass
            #expect(r.state.perItem[k("B")] == .failed(.mechanismFailed("restart")))
        }
        _ = await r.engine.reconcileOnce()
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == 3)           // strike 3: persistently failed, no more retries
        #expect(r.state.perItem[k("B")] == .failed(.mechanismFailed("restart")))
        #expect(r.state.lastError == .batchFailed("restart"))   // sticky batch error shown, but one bad key never stops the engine
        await r.engine.clearFailures()                       // Retry
        #expect(r.state.lastError == nil)
        let rep = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == 4)
        #expect(rep.outcome == .converged)
    }

    @Test func aKeyThatRecoversBreaksItsStrikeStreak() async {
        // Fails once, succeeds on the retry; later single failures never accumulate to three.
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: [k("A")], hidden: [k("B")]),
                          failOn: [(1, .mechanismFailed("restart"))])
        _ = await r.engine.reconcileOnce()
        let rep = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == 2)
        #expect(rep.outcome == .converged)
        #expect(r.state.perItem[k("B")] == .inPlace)
    }

    @Test func followUpPassesForAFailingKeyNeverExceedTheChainLimit() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: [k("A")], hidden: [k("B")]),
                          failOn: (1...9).map { ($0, ActuationError.mechanismFailed("restart")) })
        await r.engine.requestReconcile()
        let state = r.state
        #expect(await waitUntil { await MainActor.run { state.passCount } >= 1 })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(r.state.passCount <= 3)                   // the requested pass plus at most 2 chained ones
        #expect(await r.actuator.calls.count <= 3)
        // Bounded follow-ups, then explicit passes until the key is struck out: it ends `.failed` and is not retried any more.
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(r.state.perItem[k("B")] == .failed(.mechanismFailed("restart")))
        let settled = await r.actuator.calls.count
        #expect(settled <= 3)
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == settled)   // suppressed
        #expect(r.state.perItem[k("B")] == .failed(.mechanismFailed("restart")))
    }
}

// MARK: - transient reveal (gdu.17)

@MainActor
@Suite struct TransientRevealTests {
    @Test func heldUnitOnTheBarIsNotHiddenThenIsAfterTheHoldEnds() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: [k("A")], hidden: [k("B")]))
        #expect(await r.engine.beginTransientReveal(HideUnit(id: "com.x.B"), timeout: .seconds(60)))
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .converged)
        #expect(await r.actuator.calls.isEmpty)
        #expect(await r.engine.isTransientlyRevealed(HideUnit(id: "com.x.B")))
        await r.engine.endTransientReveal(HideUnit(id: "com.x.B"))
        let rep2 = await r.engine.reconcileOnce()
        #expect(rep2.outcome == .converged)
        #expect(await r.actuator.calls.contains(.applyHiddenBatch([k("B"): true])))
        #expect(await r.actuator.hidden == [k("B")])
    }

    @Test func duringAHoldTheEnginePlansNothingAtAllAndRecordsNoNewItem() async throws {
        // The revealed element can appear as an unknown heuristic item (the engine once dragged it while its menu was open),
        // and another unit that should be hidden is on the bar: with a hold active, zero actions and no persisted new item.
        let h = try #require(ItemKey(storeKey: "heuristic:com.apple.MenuBarAgent::#0"))
        let r = await rig(order: [k("A"), k("B"), h], layout: Layout(visible: [k("B")], hidden: [k("A")]))
        #expect(await r.engine.beginTransientReveal(HideUnit(id: "com.x.B"), timeout: .seconds(60)))
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .converged && rep.actionCount == 0)
        #expect(await r.actuator.calls.isEmpty)
        #expect(try !r.store.load().allKeys.contains(h))
    }

    @Test func heldUnitShowsAsPendingAndSecondHoldIsRefused() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: [k("A")], hidden: [k("B")]))
        _ = await r.engine.reconcileOnce()   // learns the items
        #expect(await r.engine.beginTransientReveal(HideUnit(id: "com.x.B"), timeout: .seconds(60)))
        #expect(await r.engine.beginTransientReveal(HideUnit(id: "com.x.B"), timeout: .seconds(60)) == false)
        #expect(r.state.perItem[k("B")] == .pending)
        #expect(r.state.perItem[k("A")] == .inPlace)
    }

    @Test func holdExpiresByItself() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: [k("A")], hidden: [k("B")]))
        #expect(await r.engine.beginTransientReveal(HideUnit(id: "com.x.B"), timeout: .milliseconds(1)))
        let gone = await waitUntil { await !r.engine.isTransientlyRevealed(HideUnit(id: "com.x.B")) }
        #expect(gone)
    }

    @Test func staleMemberRefusalIsTransientAndTheNextPassRetriesWithoutRetry() async {
        // gdu.76: a unit left alone because a member is stale is neither refused (sticky) nor struck; once the member is fresh
        // the NEXT pass hides it, with no Retry and no setLayout.
        let a = k("A"), b = k("B")
        let r = await rig(order: [a, b], layout: Layout(visible: [b], hidden: [a]))
        await r.actuator.setUnsettled([a: "hides together with X: a member's state is unknown; retrying when the bar settles"])
        for _ in 0..<5 {   // more passes than maxKeyFailures: a strike would stop retrying
            let rep = await r.engine.reconcileOnce()
            #expect(rep.outcome != .stopped)
        }
        #expect(await r.actuator.lastBatchRefused.isEmpty)
        #expect(r.state.perItem.values.allSatisfy { if case .failed = $0 { false } else if case .unsupported = $0 { false } else { true } })
        #expect(await r.actuator.hidden.isEmpty)
        await r.actuator.setUnsettled([:])   // the member is fresh again
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.hidden == [a])
    }

    @Test func capabilityRefusalStaysStickyUntilRetry() async {
        let a = k("A"), b = k("B")
        let r = await rig(order: [a, b], layout: Layout(visible: [b], hidden: [a]))
        await r.actuator.setRefusals([a: "cannot hide"])
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.lastBatchRefused[a] == "cannot hide")
        await r.actuator.setRefusals([:])
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.hidden.isEmpty)   // sticky: the capability refusal is not retried by itself
    }
}
