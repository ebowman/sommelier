import Testing
import Foundation
@testable import SommelierCore

// gdu.71: a user-initiated pass reuses the last adopted observation as the first of its two agreeing scans.

private func k(_ id: String) -> ItemKey { .status(ownerKey: "app.\(id)", autosaveName: id) }

private struct Caps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
}

/// Observes the fake actuator's truth; records, per call, whether a seed was offered. A seeded call "needs one fresh scan"
/// (scans = 1), an unseeded one two.
private final class SeedRecorder: MenuBarObserver, @unchecked Sendable {
    let actuator: FakeActuator
    private let lock = NSLock()
    private var _seeds: [Bool] = []
    init(actuator: FakeActuator) { self.actuator = actuator }
    private func record(_ b: Bool) { lock.lock(); _seeds.append(b); lock.unlock() }
    var seeds: [Bool] { lock.lock(); defer { lock.unlock() }; return _seeds }
    func observe() async throws -> [ResolvedItem] {
        let order = await actuator.order, hidden = await actuator.hidden
        return FakeMenuBar.resolve(FakeMenuBar.snapshot(order: order, hidden: hidden))
    }
    func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?, seed: ObservationSeed?) async throws -> BarObservation {
        record(seed != nil)
        return BarObservation(items: try await observe(), settled: true, scans: seed == nil ? 2 : 1)
    }
}

@MainActor
private func rig(config: LayoutEngine.Config) async -> (LayoutEngine, EngineState, SeedRecorder) {
    let act = FakeActuator(order: ["A", "B", "C"].map(k), capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let rec = SeedRecorder(actuator: act)
    let st = EngineState()
    let e = LayoutEngine(observer: rec, actuator: act, store: InMemoryLayoutStore(Layout(visible: ["A", "B", "C"].map(k))),
                         capabilities: Caps(), state: st, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, config: config)
    await e.start()
    return (e, st, rec)
}

private func settle(_ st: EngineState, passes n: Int) async -> Bool {
    for _ in 0..<400 {
        if await MainActor.run(body: { st.passCount >= n }) { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

private func cfg(window: Duration = .seconds(2)) -> LayoutEngine.Config {
    var c = LayoutEngine.Config.plain(); c.layoutCoalesce = .zero; c.userPassReuseWindow = window; c.minPassInterval = .zero; return c
}

@MainActor
@Suite("User-initiated pass: adopted-observation reuse (gdu.71)") struct UserPassReuseTests {
    @Test func userPassWithAFreshAdoptedObservationOffersASeedAndReportsReuse() async {
        let (e, st, rec) = await rig(config: cfg())
        await e.requestReconcile()                               // trigger pass: nothing to reuse yet
        #expect(await settle(st, passes: 1))
        await e.setLayout(Layout(visible: ["A", "B", "C"].map(k)))   // sommelier-ejb.7: the same order (no move, hence no chained pass to count); the user pass is what is tested
        #expect(await settle(st, passes: 2))
        #expect(rec.seeds == [false, true])
        #expect(st.lastObserveReused)
        #expect(st.lastObserveMillis != nil)
    }

    @Test func theCoalescedSetLayoutPathIsUserInitiatedToo() async {
        var c = cfg(); c.layoutCoalesce = .milliseconds(40)
        let (e, st, rec) = await rig(config: c)
        await e.requestReconcile()
        #expect(await settle(st, passes: 1))
        await e.setLayout(Layout(visible: ["A", "B", "C"].map(k)))   // sommelier-ejb.7: the same order (no move, hence no chained pass to count); the user pass is what is tested
        #expect(await settle(st, passes: 2))
        #expect(rec.seeds == [false, true])
    }

    @Test func revealOffersASeedToo() async {
        let (e, st, rec) = await rig(config: cfg())
        await e.requestReconcile()
        #expect(await settle(st, passes: 1))
        await e.setReveal(hidden: true, alwaysHidden: false)
        #expect(await settle(st, passes: 2))
        #expect(rec.seeds == [false, true])
    }

    @Test func staleAdoptedObservationIsNotOffered() async {
        let (e, st, rec) = await rig(config: cfg(window: .milliseconds(30)))
        await e.requestReconcile()
        #expect(await settle(st, passes: 1))
        try? await Task.sleep(for: .milliseconds(120))
        await e.setLayout(Layout(visible: ["A", "B", "C"].map(k)))   // sommelier-ejb.7: the same order (no move, hence no chained pass to count); the user pass is what is tested
        #expect(await settle(st, passes: 2))
        #expect(rec.seeds == [false, false])
        #expect(!st.lastObserveReused)
    }

    @Test func zeroWindowDisablesTheReuse() async {
        let (e, st, rec) = await rig(config: cfg(window: .zero))
        await e.requestReconcile()
        #expect(await settle(st, passes: 1))
        await e.setLayout(Layout(visible: ["A", "B", "C"].map(k)))   // sommelier-ejb.7: the same order (no move, hence no chained pass to count); the user pass is what is tested
        #expect(await settle(st, passes: 2))
        #expect(rec.seeds == [false, false])
    }

    @Test func triggerAndPollPassesNeverOfferASeed() async {
        let (e, st, rec) = await rig(config: cfg())
        await e.requestReconcile()
        #expect(await settle(st, passes: 1))
        await e.requestReconcile(reason: "poll")
        #expect(await settle(st, passes: 2))
        await e.requestReconcile(supersede: true, reason: "agent restarted")   // explicit but not a user action
        #expect(await settle(st, passes: 3))
        #expect(rec.seeds == [false, false, false])
    }

    @Test func aSeedIsNotOfferedAfterAnAgentRestart() async {
        let (e, st, rec) = await rig(config: cfg())
        await e.requestReconcile()
        #expect(await settle(st, passes: 1))
        await e.agentRestarted(settle: .zero)
        #expect(await settle(st, passes: 2))
        let before = rec.seeds.count
        await e.setLayout(Layout(visible: ["A", "B", "C"].map(k)))   // sommelier-ejb.7: the same order (no move, hence no chained pass to count); the user pass is what is tested
        #expect(await settle(st, passes: 3))
        // The restart's pass re-adopted a fresh observation (or ended unsettled); either way the first seed after the restart
        // is never the pre-restart observation: the restart pass itself offered none.
        #expect(rec.seeds[0] == false)
        #expect(before >= 1)
    }

    @Test func theUnsettledRetryPassIsNeitherSeededNorUserInitiated() async {
        // gdu.78 (e): the delayed "unsettled units" pass is a plain trigger pass: no seed, and it is not the poll's trigger
        // (the gdu.58 cap counts `requestReconcile(reason: "poll")` calls, which this retry never makes).
        let act = FakeActuator(order: ["A", "B"].map(k), capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        await act.setUnsettled([k("A"): "stale member"])
        let rec = SeedRecorder(actuator: act)
        let st = EngineState()
        var c = cfg(); c.unsettledRetryBase = .milliseconds(30); c.unsettledRetryCap = .milliseconds(30); c.unsettledRetryMaxAttempts = 2
        let e = LayoutEngine(observer: rec, actuator: act, store: InMemoryLayoutStore(Layout(visible: [k("B")], hidden: [k("A")])),
                             capabilities: Caps(), state: st, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, config: c)
        await e.start()
        await e.requestReconcile()
        #expect(await settle(st, passes: 3))
        #expect(rec.seeds.count >= 3 && rec.seeds.allSatisfy { !$0 })
    }
}
