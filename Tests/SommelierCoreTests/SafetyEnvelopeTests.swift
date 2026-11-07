import Testing
import Foundation
@testable import SommelierCore

// 9o9.4: the safety envelope. Per-item give-up, user-interaction pause, per-minute order cap, user pause.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private struct OpenCaps: CapabilityProvider { func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) } }
private final class Sink: @unchecked Sendable {
    private let lock = NSLock(); private var l: [String] = []
    func add(_ s: String) { lock.lock(); l.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return l }
}
private final class MemStore: LayoutStore, @unchecked Sendable {
    private let lock = NSLock(); private var layout: Layout
    init(_ l: Layout) { layout = l }
    func load() throws -> Layout { lock.lock(); defer { lock.unlock() }; return layout }
    func save(_ l: Layout) throws { lock.lock(); defer { lock.unlock() }; layout = l }
}
private struct GoodObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] { FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden)) }
}
private final class FakeInteraction: InteractionSource, @unchecked Sendable {
    private let lock = NSLock(); private var r: String?
    var reason: String? { get { lock.lock(); defer { lock.unlock() }; return r } set { lock.lock(); r = newValue; lock.unlock() } }
    func blockingReason() -> String? { reason }
}
private final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var t = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}
private func waitUntil(_ cond: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<600 { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
    return false
}

private struct R {
    let engine: LayoutEngine; let state: EngineState; let actuator: FakeActuator; let sink: Sink
    let interaction: FakeInteraction; let clock: Clock
}

private func config() -> LayoutEngine.Config {
    var c = LayoutEngine.Config()
    c.maxOrderMovesPerPass = .max
    c.minPassInterval = .zero
    c.layoutCoalesce = .zero
    c.interactionRetry = .seconds(3600)   // the retry timer never fires inside a test
    return c
}

@MainActor
private func rig(order: [String], hidden: Set<ItemKey> = [], layout: Layout, configure: (inout LayoutEngine.Config) -> Void = { _ in }) async -> R {
    let act = FakeActuator(order: order.map(k), hidden: hidden, capabilities: OpenCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let store = MemStore(layout), state = EngineState(), sink = Sink(), interaction = FakeInteraction(), clock = Clock()
    var c = config()
    c.now = { clock.now }
    configure(&c)
    let engine = LayoutEngine(observer: GoodObserver(actuator: act), actuator: act, store: store, capabilities: OpenCaps(), state: state,
                              busy: { false }, interaction: interaction,
                              resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { sink.add($0) }, config: c)
    await engine.start()
    return R(engine: engine, state: state, actuator: act, sink: sink, interaction: interaction, clock: clock)
}

private let names = ["A", "B", "C", "D", "E"]
private func layoutABCDE() -> Layout { Layout(visible: names.map(k)) }

/// Drives A through three different displacements; each pass moves A once (the revert watch expires in between, so only moves count).
@MainActor
private func thrashA(_ r: R, passes: Int = 3) async {
    let spots = [4, 3, 2, 1, 0]
    for i in 0..<passes {
        await r.actuator.displace(k("A"), toIndex: spots[i % spots.count])
        _ = await r.engine.reconcileOnce()
        _ = await r.engine.reconcileOnce(); _ = await r.engine.reconcileOnce()   // idle passes: the revert watch (2 passes) expires
    }
}

@MainActor
@Suite struct SafetyEnvelopeTests {
    // MARK: per-item give-up

    @Test func defaults() {
        let c = LayoutEngine.Config()
        #expect(c.maxAttemptsPerItem == 3 && c.attemptWindow == .seconds(600))
        #expect(c.maxOrderMovesPerMinute == 6 && c.orderCapWindow == .seconds(60))
        #expect(c.busyWait == .seconds(3))
    }

    @Test func givesUpAfterThreeMovesOfOneKeyWhateverTheRelation() async {
        let r = await rig(order: names, layout: layoutABCDE())
        await thrashA(r)
        #expect(await r.actuator.calls.count == 3)
        #expect(r.sink.lines.contains { $0.hasPrefix("engine: giving up on ") && $0.contains("after 3 attempts: ") })
        // a fourth displacement: no drag, A keeps the slot it was observed in, the rest of the plan is unaffected
        await r.actuator.displace(k("A"), toIndex: 4)
        let before = await r.actuator.calls.count
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == before)
        #expect(await r.actuator.order.last == k("A"))
        guard case .cannotPlace(let why, let n)? = r.state.perItem[k("A")] else { Issue.record("expected cannotPlace, got \(String(describing: r.state.perItem[k("A")]))"); return }
        #expect(n == 3 && !why.isEmpty)
    }

    @Test func otherKeysAreStillPlacedWhileOneIsHeld() async {
        let r = await rig(order: names, layout: layoutABCDE())
        await thrashA(r)
        await r.actuator.displace(k("A"), toIndex: 4)       // A out of place and held
        await r.actuator.displace(k("C"), toIndex: 0)       // C out of place too
        _ = await r.engine.reconcileOnce()
        let order = await r.actuator.order
        #expect(order.last == k("A"))
        #expect(order.firstIndex(of: k("B"))! < order.firstIndex(of: k("C"))!)
    }

    @Test func aRevertedVerifiedMoveCountsAsAnAttempt() async {
        let r = await rig(order: names, layout: layoutABCDE(), configure: { $0.maxAttemptsPerItem = 2 })
        await r.actuator.displace(k("A"), toIndex: 4)
        _ = await r.engine.reconcileOnce()                  // verified move: attempt 1
        #expect(await r.actuator.calls.count == 1)
        await r.actuator.displace(k("A"), toIndex: 4)       // macOS puts it back
        _ = await r.engine.reconcileOnce()                  // seen reverted: attempt 2 -> give up, no second drag
        #expect(await r.actuator.calls.count == 1)
        guard case .cannotPlace(let why, _)? = r.state.perItem[k("A")] else { Issue.record("expected cannotPlace"); return }
        #expect(why == "the menu bar moved it back")
    }

    @Test func aFailedActuatorCallCountsAsAnAttempt() async {
        let r = await rig(order: names, layout: layoutABCDE(), configure: { $0.maxAttemptsPerItem = 1 })
        await r.actuator.failOnCall(1, .mechanismFailed("boom"))
        await r.actuator.displace(k("A"), toIndex: 4)
        _ = await r.engine.reconcileOnce()
        // the per-pass strike shows the failure itself as the row status; the give-up is logged with the cause either way
        #expect(r.sink.lines.contains { $0.hasPrefix("engine: giving up on ") && $0.contains("after 1 attempts: ") && $0.contains("boom") })
    }

    @Test func movesOutsideTheWindowDoNotAccumulate() async {
        let r = await rig(order: names, layout: layoutABCDE())
        for spot in [4, 3, 2, 4] {
            await r.actuator.displace(k("A"), toIndex: spot)
            _ = await r.engine.reconcileOnce()
            _ = await r.engine.reconcileOnce(); _ = await r.engine.reconcileOnce()
            r.clock.advance(400)    // each attempt is 400 s after the last: at most 2 fall inside 600 s
        }
        #expect(await r.actuator.calls.count == 4)
        #expect(!r.sink.lines.contains { $0.contains("giving up on") })
    }

    @Test func retryKeyClearsTheGiveUpAndPlansAgain() async {
        let r = await rig(order: names, layout: layoutABCDE())
        await thrashA(r)
        await r.actuator.displace(k("A"), toIndex: 4)
        await r.engine.retry(key: k("A"))
        #expect(await waitUntil { await r.actuator.order.first == k("A") })
        #expect(await r.actuator.calls.count >= 4)
    }

    @Test func aLayoutChangeTouchingTheKeyClearsTheGiveUp() async {
        let r = await rig(order: names, layout: layoutABCDE())
        await thrashA(r)
        await r.actuator.displace(k("A"), toIndex: 4)
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.order.last == k("A"))
        // the user drops A again (same place): a fresh start for A
        await r.engine.setLayout(layoutABCDE(), moved: [k("A")])
        #expect(await waitUntil { await r.actuator.order.first == k("A") })
    }

    @Test func aLayoutChangeNotTouchingTheKeyKeepsTheGiveUp() async {
        let r = await rig(order: names, layout: layoutABCDE())
        await thrashA(r)
        await r.actuator.displace(k("A"), toIndex: 4)
        await r.engine.setLayout(Layout(visible: ["A", "C", "B", "D", "E"].map(k)), moved: [k("B")])
        #expect(await waitUntil { await r.actuator.order != names.map(k) })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await r.actuator.order.last == k("A"))
    }

    @Test func theOwningAppRelaunchingClearsTheGiveUp() async {
        let r = await rig(order: names, layout: layoutABCDE())
        await thrashA(r)
        await r.actuator.displace(k("A"), toIndex: 4)
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.order.last == k("A"))
        await r.engine.appsChanged(bundleIDs: ["com.x.A"], pids: [])
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.order.first == k("A"))
    }

    @Test func aRetryDragsOnItsFirstPlanAfterClearFailures() async {
        let r = await rig(order: names, layout: layoutABCDE(), configure: { $0.maxAttemptsPerItem = 99; $0.maxOrderMovesPerMinute = 99 })
        await r.actuator.displace(k("A"), toIndex: 4)
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == 1)
        await r.actuator.displace(k("A"), toIndex: 4)       // the same plan again
        await r.engine.clearFailures()
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == 2)           // dragged, not struck as "verified but planned again"
    }

    // MARK: user-interaction pause

    @Test(arguments: ["a menu is open", "the mouse button is down", "a modifier key is held", "the screen is locked", "the display is asleep"])
    func eachInteractionReasonBlocksOrderActuation(_ why: String) async {
        let r = await rig(order: names, layout: Layout(visible: names.reversed().map(k)))
        r.interaction.reason = why
        let a = await r.engine.reconcileOnce()
        let b = await r.engine.reconcileOnce()
        #expect(a.outcome == .paused && b.outcome == .paused)
        #expect(await r.actuator.calls.isEmpty)
        #expect(r.sink.lines.filter { $0 == "engine: paused: \(why)" }.count == 1)   // logged once per episode
        #expect(r.state.pauseReason == why)
        r.interaction.reason = nil
        let c = await r.engine.reconcileOnce()
        let callsAfter = await r.actuator.calls.count
        #expect(c.outcome != .paused && callsAfter > 0)
        #expect(r.state.pauseReason == nil)
    }

    @Test func interactionBlocksMembershipBatchesToo() async {
        let r = await rig(order: ["A", "B"], layout: Layout(visible: [k("A")], hidden: [k("B")]))
        r.interaction.reason = "a menu is open"
        let a = await r.engine.reconcileOnce()
        #expect(a.outcome == .paused)
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func anArrangeDragInFlightBlocksActuation() async {
        let r = await rig(order: names, layout: Layout(visible: names.reversed().map(k)))
        r.engine.setArrangeDragInFlight(true)
        let a = await r.engine.reconcileOnce()
        let blockedCalls = await r.actuator.calls.count
        #expect(a.outcome == .paused && blockedCalls == 0)
        #expect(r.sink.lines.contains("engine: paused: an Arrange drag is in flight"))
        r.engine.setArrangeDragInFlight(false)
        _ = await r.engine.reconcileOnce()
        let freeCalls = await r.actuator.calls.count
        #expect(freeCalls > 0)
    }

    // MARK: per-minute cap

    @Test func theCapSkipsOnlyTheOrderPhase() async {
        let r = await rig(order: names, layout: Layout(visible: names.reversed().map(k)), configure: { $0.maxOrderMovesPerMinute = 2; $0.maxAttemptsPerItem = 99 })
        let a = await r.engine.reconcileOnce()
        #expect(a.outcome == .incomplete)
        #expect(await r.actuator.calls.count == 2)
        #expect(r.sink.lines.filter { $0 == "engine: order moves capped for 60 s" }.count == 1)
        #expect(r.state.orderCapUntil != nil)
        _ = await r.engine.reconcileOnce()                  // still capped: no order move, no second log line inside the window
        #expect(await r.actuator.calls.count == 2)
        #expect(r.sink.lines.filter { $0 == "engine: order moves capped for 60 s" }.count == 1)
        // membership still runs while capped
        var l = r.state.layout
        l.visible.removeAll { $0 == k("E") }
        l.hidden = [k("E")]
        await r.engine.setLayout(l)
        #expect(await waitUntil { await r.actuator.hidden.contains(k("E")) })
        #expect(await r.actuator.calls.count == 3)          // the membership batch only
        // the cap lifts after the window
        r.clock.advance(61)
        _ = await r.engine.reconcileOnce()
        #expect(r.state.orderCapUntil == nil)
        #expect(await r.actuator.calls.count > 3)
    }

    // MARK: Pause Sommelier

    @Test func userPauseBlocksEveryActuatorCall() async {
        let r = await rig(order: ["A", "B", "C"], layout: Layout(visible: ["C", "B", "A"].map(k)))
        await r.engine.setUserPaused(true)
        #expect(r.state.userPaused)
        #expect(await r.engine.reconcileOnce().outcome == .paused)
        await r.engine.setLayout(Layout(visible: [k("A"), k("C")], hidden: [k("B")]))   // a membership change is not actuated either
        #expect(await r.engine.reconcileOnce().outcome == .paused)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await r.actuator.calls.isEmpty)
        await r.engine.setUserPaused(false)
        #expect(!r.state.userPaused)
        #expect(await waitUntil { await r.actuator.hidden.contains(k("B")) })
    }
}
