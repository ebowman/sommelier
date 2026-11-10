import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }

private struct Caps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
}

private struct ActuatorObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] {
        FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden))
    }
}

private final class Logs: @unchecked Sendable {
    private let lock = NSLock(); private var l: [String] = []
    func add(_ s: String) { lock.lock(); l.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return l }
}

@MainActor
private func rig(order: [ItemKey], hidden: Set<ItemKey> = [], layout: Layout, observer: (any MenuBarObserver)? = nil,
                 logs: Logs = Logs(), configure: (inout LayoutEngine.Config) -> Void = { _ in }) async -> (engine: LayoutEngine, state: EngineState, actuator: FakeActuator, store: InMemoryLayoutStore) {
    let act = FakeActuator(order: order, hidden: hidden, capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let store = InMemoryLayoutStore(layout)
    let state = EngineState()
    var cfg = LayoutEngine.Config.multiMove
    configure(&cfg)
    let engine = LayoutEngine(observer: observer ?? ActuatorObserver(actuator: act), actuator: act, store: store, capabilities: Caps(),
                              state: state, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { logs.add($0) }, config: cfg)
    await engine.start()
    return (engine, state, act, store)
}

/// 9o9.27: holds every `scheduleReconcile` delay until the test releases it (injected as `Config.delaySleep`), so no test sleeps on the wall clock.
private final class DelayGate: @unchecked Sendable {
    private let lock = NSLock(); private var open = false; private var n = 0
    var requested: Int { lock.lock(); defer { lock.unlock() }; return n }
    func release() { lock.lock(); open = true; lock.unlock() }
    private var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    private func note() { lock.lock(); n += 1; lock.unlock() }
    func sleep(_ d: Duration) async {
        note()
        while !isOpen && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
    }
}
/// 9o9.27: a monotonic clock the test advances by hand (injected as `Config.instant`).
private final class ManualInstant: @unchecked Sendable {
    private let lock = NSLock(); private var t = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ d: Duration) { lock.lock(); t = t.advanced(by: d); lock.unlock() }
}

private func waitUntil(_ cond: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<400 { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
    return false
}

// MARK: - MenuBarAgentWatcher

private final class PIDBox: @unchecked Sendable {
    private let lock = NSLock(); private var p: pid_t?
    init(_ p: pid_t?) { self.p = p }
    var value: pid_t? { get { lock.lock(); defer { lock.unlock() }; return p } set { lock.lock(); p = newValue; lock.unlock() } }
}

@MainActor
@Suite struct AgentWatcherTests {
    @Test func reportsAPidChangeOnceAndNotAnAbsence() async {
        let pid = PIDBox(100)
        var changes: [(pid_t, pid_t)] = []
        let logs = Logs()
        let w = MenuBarAgentWatcher(currentPID: { pid.value }, log: { logs.add($0) }, onChange: { changes.append(($0, $1)) })
        w.start(); defer { w.stop() }
        #expect(w.knownPID == 100)
        #expect(await w.check() == false)
        pid.value = nil                       // between terminate and launch
        #expect(await w.check() == false)
        pid.value = 200
        #expect(await w.check() == true)
        #expect(await w.check() == false)     // reported once
        #expect(changes.count == 1 && changes[0] == (100, 200))
        #expect(logs.all.contains("agent restarted: pid 100 -> 200"))
        pid.value = 300
        #expect(await w.check() == true)
        #expect(changes.map(\.1) == [200, 300])
    }

    @Test func aFirstSightingIsNotARestart() async {
        let pid = PIDBox(nil)
        var n = 0
        let w = MenuBarAgentWatcher(currentPID: { pid.value }, onChange: { _, _ in n += 1 })
        w.start(); defer { w.stop() }
        pid.value = 5
        #expect(await w.check() == false)
        #expect(n == 0 && w.knownPID == 5)
    }
}

// MARK: - Engine: not-ready guard, sleep, scheduling, notice

@MainActor
@Suite struct EngineRobustnessTests {
    @Test func anEmptyObservationNeverCausesAnAction() async {
        // The first scans after a respawn are empty: not "everything is hidden", never a basis for hides or moves.
        let r = await rig(order: ["A", "B"].map(k), layout: Layout.placedAll(visible: ["B", "A"].map(k), hidden: []),
                          observer: FixtureObserver(steps: [.failure(.empty), .failure(.empty)]))
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .observeFailed)
        #expect(await r.actuator.calls.isEmpty)
        #expect(r.state.observed.onBar.isEmpty)
    }

    @Test func anIncompleteOrUnsettledReadNeverCausesAnAction() async {
        let partial = FakeMenuBar.resolved(onBar: [k("B")])   // a post-respawn read that lacks A
        let r = await rig(order: ["A", "B"].map(k), layout: Layout.placedAll(visible: ["B", "A"].map(k)),
                          observer: FixtureObserver(steps: [.unsettled(partial), .failure(.noAgreement(scans: 6))]))
        #expect(await r.engine.reconcileOnce().outcome == .unsettled)
        #expect(await r.engine.reconcileOnce().outcome == .observeFailed)
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func settledObservationsAreNotActedOnRightAfterAnAgentRestart() async {
        let logs = Logs()
        let gate = DelayGate(), clock = ManualInstant()
        let r = await rig(order: ["A", "B"].map(k), layout: Layout.placedAll(visible: ["B", "A"].map(k)), logs: logs,
                          configure: { $0.delaySleep = { await gate.sleep($0) }; $0.instant = { clock.now } })
        await r.engine.agentRestarted(settle: .milliseconds(150))
        let early = await r.engine.reconcileOnce()
        #expect(early.outcome == .unsettled)
        #expect(await r.actuator.calls.isEmpty)
        #expect(logs.all.contains { $0.contains("agent restarted moments ago") })
        // The single delayed reconcile fires after the settle and the engine then converges.
        clock.advance(.milliseconds(150)); gate.release()
        let state = r.state
        #expect(await waitUntil { await MainActor.run { state.isConverged } })
        #expect(await r.actuator.order == ["B", "A"].map(k))
        #expect(logs.all.contains { $0.contains("pass started") && $0.contains("after agent restarted") })
    }

    @Test func anAgentRestartDropsTransientRevealHolds() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout.placedAll(visible: [k("A")], hidden: [k("B")]))
        _ = await r.engine.reconcileOnce()
        #expect(await r.engine.beginTransientReveal(HideUnit(id: "com.x.B"), timeout: .seconds(60)))
        await r.engine.agentRestarted(settle: .milliseconds(10))
        #expect(await r.engine.isTransientlyRevealed(HideUnit(id: "com.x.B")) == false)
    }

    @Test func nothingRunsAcrossSleepAndWakeReconcilesAfterTheSettle() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout.placedAll(visible: ["B", "A"].map(k)))
        await r.engine.willSleep()
        await r.engine.requestReconcile()
        await r.engine.setLayout(Layout.placedAll(visible: ["B", "A"].map(k)))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await r.actuator.calls.isEmpty)
        #expect(await r.engine.reconcileOnce().outcome == .incomplete)   // a direct pass is refused too
        #expect(await r.actuator.calls.isEmpty)
        await r.engine.didWake(settle: .milliseconds(30))
        let state = r.state
        #expect(await waitUntil { await MainActor.run { state.isConverged } })
        #expect(await r.actuator.order == ["B", "A"].map(k))
    }

    @Test func aPassStartedWhileAsleepDoesNothingAndResumeClearsTheFlag() async {
        let names = ["A", "B", "C", "D"]
        let r = await rig(order: names.map(k), layout: Layout.placedAll(visible: names.reversed().map(k)))
        // Sleep is announced before the pass: the pass must not start any action.
        await r.engine.willSleep()
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.isEmpty)
        await r.engine.resumeFromSleep()
        #expect(await r.engine.isSleeping == false)
        #expect(await r.engine.reconcileOnce().outcome == .converged)
    }

    @Test func burstsWithTheSameReasonBecomeOnePass() async {
        let gate = DelayGate()
        let r = await rig(order: ["A", "B"].map(k), layout: Layout.placedAll(visible: ["B", "A"].map(k)),
                          configure: { $0.delaySleep = { await gate.sleep($0) } })
        for _ in 0..<8 { await r.engine.scheduleReconcile(after: .milliseconds(60), reason: "display change") }
        #expect(r.state.passCount == 0)      // the delay has not elapsed: the gate is closed
        gate.release()
        let state = r.state
        #expect(await waitUntil { await MainActor.run { state.passCount >= 1 } })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(r.state.passCount == 1)
    }

    @Test func aNewUnknownItemSurfacesATransientNoticeAndALogLine() async throws {
        let logs = Logs()
        let r = await rig(order: ["A", "B"].map(k), layout: Layout.placedAll(visible: [k("A")]), logs: logs)
        _ = await r.engine.reconcileOnce()
        #expect(r.state.newItemNotice?.hasPrefix("New item: ") == true)
        #expect(r.state.newItemNotice?.hasSuffix("placed in Visible") == true)
        #expect(logs.all.contains { $0.hasPrefix("New item: ") })
        #expect(try r.store.load().allKeys.contains(k("B")))
    }

    @Test func noticeWording() {
        #expect(NewItemNotice.text([]) == nil)
        #expect(NewItemNotice.text([("Foo", .visible)]) == "New item: Foo placed in Visible")
        #expect(NewItemNotice.text([("Foo", .hidden)]) == "New item: Foo placed in Hidden")
        #expect(NewItemNotice.text([("A", .visible), ("B", .hidden), ("C", .visible)]) == "New items: A, C placed in Visible; B placed in Hidden")
    }
}

// MARK: - A desire changed while a membership batch ran is not a failure

private final class EngineBox: @unchecked Sendable { var engine: LayoutEngine? }

/// Applies the batch, then (once) toggles the reveal state as a user click would while the batch is still in flight.
private struct ToggleDuringBatch: MenuBarActuator {
    let inner: FakeActuator
    let box: EngineBox
    let fired = Counter()
    func move(_ key: ItemKey, relation: Relation) async -> ActuationResult { await inner.move(key, relation: relation) }
    func setHidden(_ key: ItemKey, _ hidden: Bool) async -> ActuationResult { await inner.setHidden(key, hidden) }
    func applyHiddenBatch(_ changes: [ItemKey: Bool]) async -> ActuationResult {
        let r = await inner.applyHiddenBatch(changes)
        if fired.next() == 1 { await box.engine?.setShowHiddenSection(true) }
        return r
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

@MainActor
@Suite struct DesireChangeDuringBatchTests {
    @Test func aRevealToggledWhileAHideBatchRunsIsNotAFailureAndNeverStrikes() async {
        let inner = FakeActuator(order: ["A", "B"].map(k), capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        let box = EngineBox()
        let store = InMemoryLayoutStore(Layout.placedAll(visible: [k("A")], hidden: [k("B")]))
        let state = EngineState()
        let engine = LayoutEngine(observer: ActuatorObserver(actuator: inner), actuator: ToggleDuringBatch(inner: inner, box: box), store: store,
                                  capabilities: Caps(), state: state, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, config: .plain())
        box.engine = engine
        await engine.start()
        let first = await engine.reconcileOnce()          // hides B; the reveal flips to "show" meanwhile
        #expect(first.outcome != .stopped)
        #expect(state.perItem[k("B")] != nil)
        #expect(!state.perItem.values.contains { if case .failed = $0 { true } else { false } })
        #expect(state.lastError == nil)
        let second = await engine.reconcileOnce()         // shows B
        #expect(second.outcome == .converged)
        #expect(await inner.hidden.isEmpty)
    }
}

// MARK: - Respawn strike-out, foreign vs own respawns inside a pass

private struct RespawningBatch: MenuBarActuator {
    let inner: FakeActuator
    var onBatch: @Sendable () -> Void = {}
    func move(_ key: ItemKey, relation: Relation) async -> ActuationResult { await inner.move(key, relation: relation) }
    func setHidden(_ key: ItemKey, _ hidden: Bool) async -> ActuationResult { await inner.setHidden(key, hidden) }
    func applyHiddenBatch(_ changes: [ItemKey: Bool]) async -> ActuationResult { onBatch(); return await inner.applyHiddenBatch(changes) }
    var lastBatchRespawned: Bool { get async { true } }
}

/// Changes the agent pid while an observation is in progress (a respawn the watcher has not reported yet).
private struct PidChangingObserver: MenuBarObserver {
    let inner: any MenuBarObserver
    let pid: PIDBox
    let newPID: pid_t
    func observe() async throws -> [ResolvedItem] { pid.value = newPID; return try await inner.observe() }
}

@MainActor
@Suite struct RespawnAccountingTests {
    @Test func aBatchThatEndedInARespawnStrikesItsKeysOutAtOnce() async {
        let inner = FakeActuator(order: ["A", "B"].map(k), capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        await inner.failOnCall(1, .mechanismFailed("restart"))
        let logs = Logs()
        let engine = LayoutEngine(observer: ActuatorObserver(actuator: inner), actuator: RespawningBatch(inner: inner),
                                  store: InMemoryLayoutStore(Layout.placedAll(visible: [k("A")], hidden: [k("B")])), capabilities: Caps(),
                                  state: EngineState(), resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { logs.add($0) }, config: .plain())
        await engine.start()
        _ = await engine.reconcileOnce()
        _ = await engine.reconcileOnce()
        _ = await engine.reconcileOnce()
        #expect(await inner.calls.count == 1)        // ONE respawn for the key, not three
        #expect(logs.all.contains { $0.contains("after an agent respawn") })
        await engine.clearFailures()                  // Retry
        _ = await engine.reconcileOnce()
        #expect(await inner.calls.count == 2)
    }

    @Test func aForeignRespawnDuringTheObservationDiscardsItAndActuatesNothing() async {
        let inner = FakeActuator(order: ["A", "B"].map(k), capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        let pid = PIDBox(100)
        let state = EngineState()
        let engine = LayoutEngine(observer: PidChangingObserver(inner: ActuatorObserver(actuator: inner), pid: pid, newPID: 200), actuator: inner,
                                  store: InMemoryLayoutStore(Layout.placedAll(visible: ["B", "A"].map(k))), capabilities: Caps(), state: state,
                                  resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in },
                                  config: .plain(), agentPID: { pid.value }, isOwnAgentPID: { _ in false })
        await engine.start()
        let rep = await engine.reconcileOnce()
        #expect(rep.outcome == .agentRestarted)
        #expect(await inner.calls.isEmpty)
        #expect(state.observed.onBar.isEmpty)         // the new agent's read was not published either
        #expect(await engine.reconcileOnce().outcome == .unsettled)   // inside the not-ready window
        #expect(await inner.calls.isEmpty)
    }

    @Test func ourOwnRespawnDoesNotDiscardTheObservation() async {
        let inner = FakeActuator(order: ["A", "B"].map(k), capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        let pid = PIDBox(100)
        let engine = LayoutEngine(observer: PidChangingObserver(inner: ActuatorObserver(actuator: inner), pid: pid, newPID: 200), actuator: inner,
                                  store: InMemoryLayoutStore(Layout.placedAll(visible: ["B", "A"].map(k))), capabilities: Caps(), state: EngineState(),
                                  resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in },
                                  config: .plain(), agentPID: { pid.value }, isOwnAgentPID: { $0 == 200 })
        await engine.start()
        #expect(await engine.reconcileOnce().outcome == .incomplete)   // sommelier-ejb.7, CHANGED: a pass that moved an item is `.incomplete`; the core judges the moved bar on the next pass
        #expect(await inner.order == ["B", "A"].map(k))
    }

    @Test func aRespawnDuringAnActionEndsThePassWithoutFurtherActuation() async {
        let names = ["A", "B", "C", "D"]
        let inner = FakeActuator(order: names.map(k), capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        let pid = PIDBox(100)
        let act = RespawningBatchlessMove(inner: inner, pid: pid)
        let engine = LayoutEngine(observer: ActuatorObserver(actuator: inner), actuator: act,
                                  store: InMemoryLayoutStore(Layout.placedAll(visible: names.reversed().map(k))), capabilities: Caps(), state: EngineState(),
                                  resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in },
                                  config: .plain(), agentPID: { pid.value }, isOwnAgentPID: { _ in false })
        await engine.start()
        let rep = await engine.reconcileOnce()
        #expect(rep.outcome == .agentRestarted)
        #expect(await inner.calls.count == 1)         // the first move ran; the snapshot after it came from a new agent
    }

    @Test func theWatcherAbsorbsOurOwnRespawnAndKeepsItsPidAcrossAPause() async {
        let pid = PIDBox(100)
        let own = PIDBox(nil)
        let busy = PIDBox(nil)
        var changes = 0
        let w = MenuBarAgentWatcher(currentPID: { pid.value }, busy: { busy.value != nil }, isExpected: { own.value == $0 }, onChange: { _, _ in changes += 1 })
        w.start()
        busy.value = 1; pid.value = 150                // our restart is running: nothing reported, nothing remembered
        #expect(await w.check() == false)
        busy.value = nil; own.value = 150              // finished: the new pid is ours
        #expect(await w.check() == false)
        #expect(changes == 0 && w.knownPID == 150)
        w.stop()                                       // pause (Bartender, permission loss)
        pid.value = 300                                // a foreign respawn meanwhile
        w.start()                                      // resume compares with the last KNOWN pid
        try? await Task.sleep(for: .milliseconds(50))
        #expect(changes == 1 && w.knownPID == 300)
        w.stop()
    }
}

private struct RespawningBatchlessMove: MenuBarActuator {
    let inner: FakeActuator
    let pid: PIDBox
    func move(_ key: ItemKey, relation: Relation) async -> ActuationResult { let r = await inner.move(key, relation: relation); pid.value = 999; return r }
    func setHidden(_ key: ItemKey, _ hidden: Bool) async -> ActuationResult { await inner.setHidden(key, hidden) }
    func applyHiddenBatch(_ changes: [ItemKey: Bool]) async -> ActuationResult { await inner.applyHiddenBatch(changes) }
}

// MARK: - Scanner invalidation on an agent respawn

private struct OneItemSource: AccessibilitySource {
    var currentPID: pid_t = 1
    let agent = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
    func runningApps() -> [RunningAppInfo] { [agent] }
    func extrasItems(for app: RunningAppInfo) -> [AXElementInfo] { [] }
    func agentHostedTree(for agent: RunningAppInfo) -> AgentHostedTree {
        AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30),
                        elements: [AXElementInfo(axDescription: "Clock", identifier: "com.apple.menuextra.clock", frame: CGRect(x: 100, y: 3, width: 24, height: 24))],
                        failedReads: 0, timedOut: [], unnamedTimeouts: 0)
    }
}

@Suite struct ScannerInvalidationTests {
    @Test func invalidateForgetsTheOldAgentButKeepsAssumedHidden() {
        let scanner = MenuBarScanner(source: OneItemSource())
        _ = scanner.scan()
        #expect(scanner.recentCompleteHostedLayout(maxAge: 60) != nil)
        scanner.recordAssumedHidden(pid: 42, bundleID: "a.b", items: 1, hostedAfter: 3)
        scanner.invalidateAgentState()
        #expect(scanner.recentCompleteHostedLayout(maxAge: 60) == nil)
        #expect(scanner.assumedHiddenPIDs == [42])   // the Control Center store still says hidden
    }
}

// MARK: - Conflicting manager during a pass (gdu.35)


@MainActor
@Suite struct ConflictDuringPassTests {
    @Test func aPassStopsBeforeTheNextActuatorCallOnceBartenderIsDetected() async {
        let names = ["A", "B", "C", "D"]
        let r = await rig(order: names.map(k), layout: Layout.placedAll(visible: names.reversed().map(k)))
        let engine = r.engine
        await r.actuator.setAfterCall { n in if n == 1 { engine.setConflict("Bartender 7") } }
        let rep = await engine.reconcileOnce()
        #expect(rep.outcome == .paused)
        #expect(await r.actuator.calls.count == 1)
        #expect(rep.actionCount == 1)
        let st = r.state
        #expect(!st.perItem.values.contains { if case .failed = $0 { return true } else { return false } })
        #expect(st.inFlight == nil)
        #expect(st.lastError == nil)
        // Nothing was suppressed: once Bartender quits the next pass converges.
        await r.actuator.setAfterCall(nil)
        engine.setConflict(nil)
        #expect(await engine.reconcileOnce().outcome == .converged)
        #expect(await r.actuator.order == names.reversed().map(k))
    }

    @Test func aPassStartedWhileConflictedMakesNoCalls() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout.placedAll(visible: ["B", "A"].map(k)))
        r.engine.setConflict("Bartender 7")
        #expect(await r.engine.reconcileOnce().outcome == .paused)
        await r.engine.requestReconcile()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await r.actuator.calls.isEmpty)
    }
}
