import Testing
import Foundation
@testable import SommelierCore

// gdu.47: rapid setLayout calls (hide then show of the same unit) never end in a spurious "not verified".

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }

private struct Caps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
}

private final class Logs: @unchecked Sendable {
    private let lock = NSLock(); private var l: [String] = []
    func add(_ s: String) { lock.lock(); l.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return l }
    func count(_ needle: String) -> Int { all.filter { $0.contains(needle) }.count }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}

private struct ActuatorObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] {
        FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden))
    }
}

/// The first observation waits to be cancelled (as a superseded one is); later ones read the fake bar.
private actor SlowFirstActuatorObserver: MenuBarObserver {
    let actuator: FakeActuator
    private(set) var calls = 0
    init(actuator: FakeActuator) { self.actuator = actuator }
    func observe() async throws -> [ResolvedItem] { try await observeDetailed(progress: nil).items }
    func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> BarObservation {
        calls += 1
        if calls == 1 {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw ObserveError.superseded
        }
        let items = FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden))
        return BarObservation(items: items, settled: true)
    }
}

private func waitUntil(_ cond: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<600 { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
    return false
}

private let A = k("A"), B = k("B"), C = k("C")
private let allVisible = Layout.placedAll(visible: [A, B, C])
private let bHidden = Layout.placedAll(visible: [A, C], hidden: [B])

private struct Rig {
    let engine: LayoutEngine
    let state: EngineState
    let actuator: FakeActuator
    let logs: Logs
    let slow: SlowFirstActuatorObserver?
}

@MainActor
private func rig(layout: Layout, window: Duration, slowFirst: Bool = false,
                 agentPID: @escaping @Sendable () -> pid_t? = { nil }) async -> Rig {
    let act = FakeActuator(order: [A, B, C], capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let logs = Logs()
    var cfg = LayoutEngine.Config.plain()
    cfg.layoutCoalesce = window
    cfg.assumeFullBarAtLaunch = false   // gdu.144: these tests are about coalescing on a plain bar; an assumed-full bar is not converged until proven otherwise
    let state = EngineState()
    let slow = slowFirst ? SlowFirstActuatorObserver(actuator: act) : nil
    let engine = LayoutEngine(observer: slow ?? ActuatorObserver(actuator: act), actuator: act,
                              store: InMemoryLayoutStore(layout), capabilities: Caps(), state: state,
                              resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in },
                              log: { logs.add($0) }, config: cfg, agentPID: agentPID)
    await engine.start()
    return Rig(engine: engine, state: state, actuator: act, logs: logs, slow: slow)
}

@Suite struct SupersedeTests {
    private func neverFailed(_ r: Rig) async -> Bool {
        await MainActor.run { !r.state.perItem.values.contains { if case .failed = $0 { return true } else { return false } } }
    }

    // (i) + (v)
    @Test func twoLayoutsInsideTheWindowAreOnePassForTheFinalLayout() async {
        let r = await rig(layout: allVisible, window: .milliseconds(300))
        await r.engine.setLayout(bHidden)
        await r.engine.setLayout(Layout.placedAll(visible: [B, A, C]))   // the user changed their mind
        #expect(await waitUntil { await MainActor.run { r.state.isConverged && r.state.passesStarted >= 1 } })
        try? await Task.sleep(for: .milliseconds(100))
        // sommelier-ejb.7, CHANGED: the pass for the final layout moves A; one chained pass then reads the moved bar (the core judges it): 2 passes, not 1. Still ONE move, no pass per layout.
        #expect(await MainActor.run { r.state.passesStarted } == 2)
        #expect(await r.actuator.calls.filter { if case .move = $0 { return true } else { return false } }.count == 1)
        #expect(await r.actuator.order == [B, A, C])
        #expect(await r.actuator.hidden.isEmpty)
        #expect(await r.actuator.calls.filter { if case .applyHiddenBatch = $0 { return true } else { return false } }.isEmpty)
        #expect(await neverFailed(r))
        #expect(r.logs.count("coalesced") == 1)
        #expect(r.logs.count("not verified") == 0 && r.logs.count("expected membership change") == 0)
    }

    // (ii) + (v)
    @Test func aPassObservingWhenTheSecondLayoutArrivesEndsSupersededAndTheNextPlansFromIt() async {
        let r = await rig(layout: allVisible, window: .milliseconds(30), slowFirst: true)
        let slow = r.slow!
        await r.engine.setLayout(bHidden)
        #expect(await waitUntil { await slow.calls == 1 })     // the pass for L1 is observing
        await r.engine.setLayout(Layout.placedAll(visible: [B, A, C]))
        #expect(await waitUntil { await MainActor.run { r.state.isConverged && r.state.observed.onBar == [B, A, C] } })
        #expect(await slow.calls >= 2)                         // a fresh scan
        #expect(r.logs.count("pass superseded by setLayout") >= 1)
        #expect(await r.actuator.hidden.isEmpty)
        #expect(await r.actuator.calls.filter { if case .applyHiddenBatch = $0 { return true } else { return false } }.isEmpty)
        #expect(await neverFailed(r))
        #expect(r.logs.count("not verified") == 0)
    }

    // (iii) + (iv) + (v)
    @Test func aBatchInFlightFinishesThenTheShowIsPlannedFromAFreshScan() async {
        let r = await rig(layout: allVisible, window: .milliseconds(30))
        await r.actuator.setBatchDelay(.milliseconds(250))
        await r.engine.setLayout(bHidden)
        #expect(await waitUntil { await r.actuator.batchStarts == 1 })   // the hide is in flight
        await r.engine.setLayout(allVisible)                              // show again while it runs
        let sawFailed = Flag()
        #expect(await waitUntil {
            if await !self.neverFailed(r) { sawFailed.set() }
            return await MainActor.run { r.state.isConverged && r.state.observed.onBar == [A, B, C] } && r.logs.count("pass superseded") >= 1
        })
        try? await Task.sleep(for: .milliseconds(150))
        let batches = await r.actuator.calls.compactMap { c -> [ItemKey: Bool]? in if case .applyHiddenBatch(let b) = c { return b } else { return nil } }
        #expect(batches == [[B: true], [B: false]])                       // one live write per direction
        #expect(await r.actuator.hidden.isEmpty)
        #expect(!sawFailed.value)
        #expect(await neverFailed(r))
        #expect(await MainActor.run { r.state.lastError } == nil)
        #expect(r.logs.count("not verified") == 0 && r.logs.count("expected membership change") == 0)
        #expect(r.logs.count("not judged against the new layout") == 1)
    }

    // (vi) a genuine failure with no supersede is still a failure
    @Test func aGenuineFailureWithoutASupersedeIsStillReported() async {
        let r = await rig(layout: bHidden, window: .milliseconds(30))
        await r.actuator.failOnCall(1, .mechanismFailed("boom"))
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome != .superseded)
        let st = await MainActor.run { r.state.perItem[B] }
        if case .failed? = st {} else { Issue.record("expected .failed, got \(String(describing: st))") }
        #expect(r.logs.count("pass superseded") == 0)
    }

    // gdu.47 corrective: a steady stream of setLayout calls cannot starve the pass past layoutCoalesceMax (1 s).
    @Test func aBurstOfLayoutsIsCappedAtTheCoalesceMax() async {
        let r = await rig(layout: allVisible, window: .milliseconds(300))
        var firstPassAfterCall: Int?
        for i in 0..<8 {
            await r.engine.setLayout(i % 2 == 0 ? Layout.placedAll(visible: [B, A, C]) : allVisible)
            let started = await MainActor.run { r.state.passesStarted }
            if firstPassAfterCall == nil, started >= 1 { firstPassAfterCall = i }
            try? await Task.sleep(for: .milliseconds(200))
        }
        #expect(firstPassAfterCall != nil && firstPassAfterCall! <= 6)   // started while the burst was still going (~1 s), not after call 8 (1.4 s)
        #expect(await waitUntil { await MainActor.run { r.state.isConverged } })
    }

    // The supersede log names the actual source.
    @Test func anObservationCancelledByAnotherSourceLogsItsOwnReason() async {
        let r = await rig(layout: allVisible, window: .milliseconds(30), slowFirst: true)
        await r.engine.requestReconcile()
        #expect(await waitUntil { await r.slow!.calls == 1 })
        await r.engine.requestReconcile(supersede: true, reason: "transient reveal ended")
        #expect(await waitUntil { r.logs.count("pass superseded by transient reveal ended") == 1 })
        #expect(r.logs.count("pass superseded by setLayout") == 0)
    }

    // (b) with a foreign agent respawn during the batch: the gdu.21 outcome, not a plain supersede.
    @Test func aBatchFollowedByAForeignAgentRespawnEndsAgentRestartedNotSuperseded() async {
        let pid = PIDBox()
        let r = await rig(layout: allVisible, window: .milliseconds(30), agentPID: { pid.value })
        await r.actuator.setBatchDelay(.milliseconds(250))
        await r.engine.setLayout(bHidden)
        #expect(await waitUntil { await r.actuator.batchStarts == 1 })
        await r.engine.setLayout(allVisible)   // supersede the batch in flight
        pid.value = 4242                         // and someone else respawns the agent meanwhile
        #expect(await waitUntil { r.logs.count("agent restarted during the pass") >= 1 })
        #expect(r.logs.count("pass superseded by") == 0)
        #expect(r.logs.count("pass delayed") == 0 && r.logs.count("not judged against the new layout") == 0)
    }
}

private final class PIDBox: @unchecked Sendable {
    private let lock = NSLock(); private var v: pid_t = 100
    var value: pid_t { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}
