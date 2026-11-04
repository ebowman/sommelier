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
                 logs: Logs = Logs()) async -> (engine: LayoutEngine, state: EngineState, actuator: FakeActuator, store: InMemoryLayoutStore) {
    let act = FakeActuator(order: order, hidden: hidden, capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let store = InMemoryLayoutStore(layout)
    let state = EngineState()
    let engine = LayoutEngine(observer: observer ?? ActuatorObserver(actuator: act), actuator: act, store: store, capabilities: Caps(),
                              state: state, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { logs.add($0) })
    await engine.start()
    return (engine, state, act, store)
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
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: ["B", "A"].map(k), hidden: []),
                          observer: FixtureObserver(steps: [.failure(.empty), .failure(.empty)]))
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .observeFailed)
        #expect(await r.actuator.calls.isEmpty)
        #expect(r.state.observed.onBar.isEmpty)
    }

    @Test func anIncompleteOrUnsettledReadNeverCausesAnAction() async {
        let partial = FakeMenuBar.resolved(onBar: [k("B")])   // a post-respawn read that lacks A
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: ["B", "A"].map(k)),
                          observer: FixtureObserver(steps: [.unsettled(partial), .failure(.noAgreement(scans: 6))]))
        #expect(await r.engine.reconcileOnce().outcome == .unsettled)
        #expect(await r.engine.reconcileOnce().outcome == .observeFailed)
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func settledObservationsAreNotActedOnRightAfterAnAgentRestart() async {
        let logs = Logs()
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: ["B", "A"].map(k)), logs: logs)
        await r.engine.agentRestarted(settle: .milliseconds(150))
        let early = await r.engine.reconcileOnce()
        #expect(early.outcome == .unsettled)
        #expect(await r.actuator.calls.isEmpty)
        #expect(logs.all.contains { $0.contains("agent restarted moments ago") })
        // The single delayed reconcile fires after the settle and the engine then converges.
        let state = r.state
        #expect(await waitUntil { await MainActor.run { state.isConverged } })
        #expect(await r.actuator.order == ["B", "A"].map(k))
        #expect(logs.all.contains { $0.contains("pass started") && $0.contains("after agent restarted") })
    }

    @Test func anAgentRestartDropsTransientRevealHolds() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: [k("A")], hidden: [k("B")]))
        _ = await r.engine.reconcileOnce()
        #expect(await r.engine.beginTransientReveal(HideUnit(id: "com.x.B"), timeout: .seconds(60)))
        await r.engine.agentRestarted(settle: .milliseconds(10))
        #expect(await r.engine.isTransientlyRevealed(HideUnit(id: "com.x.B")) == false)
    }

    @Test func nothingRunsAcrossSleepAndWakeReconcilesAfterTheSettle() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: ["B", "A"].map(k)))
        await r.engine.willSleep()
        await r.engine.requestReconcile()
        await r.engine.setLayout(Layout(visible: ["B", "A"].map(k)))
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
        let r = await rig(order: names.map(k), layout: Layout(visible: names.reversed().map(k)))
        // Sleep is announced before the pass: the pass must not start any action.
        await r.engine.willSleep()
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.isEmpty)
        await r.engine.resumeFromSleep()
        #expect(await r.engine.isSleeping == false)
        #expect(await r.engine.reconcileOnce().outcome == .converged)
    }

    @Test func burstsWithTheSameReasonBecomeOnePass() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: ["B", "A"].map(k)))
        for _ in 0..<8 { await r.engine.scheduleReconcile(after: .milliseconds(60), reason: "display change") }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(r.state.passCount == 0)
        let state = r.state
        #expect(await waitUntil { await MainActor.run { state.passCount >= 1 } })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(r.state.passCount == 1)
    }

    @Test func aNewUnknownItemSurfacesATransientNoticeAndALogLine() async throws {
        let logs = Logs()
        let r = await rig(order: ["A", "B"].map(k), layout: Layout(visible: [k("A")]), logs: logs)
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
        let line = ArrangeSections.statusLine(perItem: [:], lastError: nil, isConverged: true, inFlight: false, notice: "New item: Foo placed in Visible")
        #expect(line == "New item: Foo placed in Visible · Converged")
        #expect(ArrangeSections.statusLine(perItem: [:], lastError: nil, isConverged: true, inFlight: false) == "Converged")
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
        let store = InMemoryLayoutStore(Layout(visible: [k("A")], hidden: [k("B")]))
        let state = EngineState()
        let engine = LayoutEngine(observer: ActuatorObserver(actuator: inner), actuator: ToggleDuringBatch(inner: inner, box: box), store: store,
                                  capabilities: Caps(), state: state, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in })
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
