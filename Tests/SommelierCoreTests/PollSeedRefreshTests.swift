import Testing
import Foundation
@testable import SommelierCore

// gdu.77: an unchanged poll refreshes the AGE (never the content) of the engine's adopted observation, so an idle user click can
// still offer it as the first agreeing scan; changed, stale-serial, suppressed and restarted cases refresh nothing.

private func k(_ id: String) -> ItemKey { .status(ownerKey: "app.\(id)", autosaveName: id) }

private struct Caps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
}

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

/// The poll's visible scan: the fake actuator's bar, or an overridden order.
private final class BarScanner: SnapshotScanning, @unchecked Sendable {
    private let lock = NSLock(); private var override: [String]?
    func set(_ o: [String]?) { lock.lock(); override = o; lock.unlock() }
    private func current() -> [String] { lock.lock(); defer { lock.unlock() }; return override ?? ["A", "B", "C"] }
    func scanVisible() async -> MenuBarSnapshot { FakeMenuBar.snapshot(order: current().map(k), hidden: []) }
    func scan() async -> MenuBarSnapshot { await scanVisible() }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var d = Date(timeIntervalSince1970: 2_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return d }
}

@MainActor
private struct Rig {
    let e: LayoutEngine, st: EngineState, rec: SeedRecorder, scanner: BarScanner, t: EngineTriggers
}

@MainActor
private func rig(pollConfig: PollConfig = PollConfig()) async -> Rig {
    let act = FakeActuator(order: ["A", "B", "C"].map(k), capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let rec = SeedRecorder(actuator: act)
    let st = EngineState()
    var c = LayoutEngine.Config.plain(); c.layoutCoalesce = .zero; c.minPassInterval = .zero
    c.assumeFullBarAtLaunch = false   // gdu.144: these tests are about seeds on a plain bar; a poll that PROVES the bar not full requests a pass of its own
    c.userPassReuseWindow = .milliseconds(30)           // a click after the 120 ms pause is "idle"
    let e = LayoutEngine(observer: rec, actuator: act, store: InMemoryLayoutStore(Layout(visible: ["A", "B", "C"].map(k))),
                         capabilities: Caps(), state: st, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, config: c)
    await e.start()
    let scanner = BarScanner(), clock = Clock()
    let t = EngineTriggers(engine: e, state: st, scanner: scanner, resolve: { FakeMenuBar.resolve($0) }, config: pollConfig,
                           trigger: {}, sleep: { _ in }, now: { clock.now })
    await e.requestReconcile()
    _ = await settle(st, passes: 1)
    return Rig(e: e, st: st, rec: rec, scanner: scanner, t: t)
}

private func settle(_ st: EngineState, passes n: Int) async -> Bool {
    for _ in 0..<400 {
        if await MainActor.run(body: { st.passCount >= n }) { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

private func idle() async { try? await Task.sleep(for: .milliseconds(120)) }

@MainActor
@Suite("Poll refreshes the adopted observation's age (gdu.77)") struct PollSeedRefreshTests {
    @Test func unchangedPollLetsTheNextIdleUserPassReuseTheObservation() async {
        let r = await rig()
        await idle()
        await r.t.poll()                                          // the bar still reads as the engine's observation
        await r.e.setLayout(Layout(visible: ["A", "B", "C"].map(k)))   // sommelier-ejb.7: the same order (no move, hence no chained pass to count); the user pass is what is tested
        #expect(await settle(r.st, passes: 2))
        #expect(r.rec.seeds == [false, true])
        #expect(r.st.lastObserveReused)
    }

    @Test func withoutAPollTheIdleObservationIsNotOffered() async {
        let r = await rig()
        await idle()
        await r.e.setLayout(Layout(visible: ["A", "B", "C"].map(k)))   // sommelier-ejb.7: the same order (no move, hence no chained pass to count); the user pass is what is tested
        #expect(await settle(r.st, passes: 2))
        #expect(r.rec.seeds == [false, false])
    }

    @Test func aPollThatSeesAChangedBarRefreshesNothing() async {
        let r = await rig()
        await idle()
        r.scanner.set(["B", "A", "C"])                            // changed (trigger is a no-op here)
        await r.t.poll()
        await r.e.setLayout(Layout(visible: ["A", "B", "C"].map(k)))   // sommelier-ejb.7: the same order (no move, hence no chained pass to count); the user pass is what is tested
        #expect(await settle(r.st, passes: 2))
        #expect(r.rec.seeds == [false, false])
    }

    @Test func aStaleSerialRefreshesNothing() async {
        let r = await rig()
        await idle()
        let serial = await r.e.pollGate().engineSignatureSerial
        await r.e.notePollUnchanged(serial: serial - 1)
        await r.e.setLayout(Layout(visible: ["A", "B", "C"].map(k)))   // sommelier-ejb.7: the same order (no move, hence no chained pass to count); the user pass is what is tested
        #expect(await settle(r.st, passes: 2))
        #expect(r.rec.seeds == [false, false])
    }

    @Test func aSuppressedPollRefreshesNothing() async {
        var pc = PollConfig(); pc.maxPollPassesPerMinute = 0
        let r = await rig(pollConfig: pc)
        await idle()
        r.scanner.set(["B", "A", "C"])
        await r.t.poll()                                          // confirmed change over the cap: suppression starts
        r.scanner.set(nil)                                        // the bar reads as the engine's observation again
        await r.t.poll()                                          // suppressed: scans, triggers and refreshes nothing
        await r.e.setLayout(Layout(visible: ["A", "B", "C"].map(k)))   // sommelier-ejb.7: the same order (no move, hence no chained pass to count); the user pass is what is tested
        #expect(await settle(r.st, passes: 2))
        #expect(r.rec.seeds == [false, false])
    }

    @Test func anAgentRestartClearsTheRefreshedObservation() async {
        let r = await rig()
        await idle()
        await r.t.poll()
        await r.e.agentRestarted(settle: .milliseconds(20))
        #expect(await settle(r.st, passes: 2))                    // the restart pass adopts a fresh observation
        await idle()
        await r.e.setLayout(Layout(visible: ["A", "B", "C"].map(k)))   // sommelier-ejb.7: the same order (no move, hence no chained pass to count); the user pass is what is tested
        #expect(await settle(r.st, passes: 3))
        #expect(r.rec.seeds.last == false)                        // not the refreshed (polled) window
    }
}
