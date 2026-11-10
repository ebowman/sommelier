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
    var c = LayoutEngine.Config.plain()
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
        let c = LayoutEngine.Config.plain()
        #expect(c.maxAttemptsPerItem == 3 && c.attemptWindow == .seconds(600))
        #expect(c.maxOrderMovesPerMinute == 6 && c.orderCapWindow == .seconds(60))
        #expect(c.busyWait == .seconds(3))
    }

    // ejb.15 (Wiring 3), CHANGED because the core decides: the per-key give-up (3 attempts in 10 minutes, `maxAttemptsPerItem`) is no longer what bounds a
    // thrashing key. The core's budget is: 20 engine drags on a bar known not full (3 on a full one) until a user edit or Retry. The safety property
    // (a key macOS keeps displacing cannot be dragged forever) is kept, with the core's bound.
    @Test func aKeyMacOSKeepsDisplacingIsDraggedAtMostTheCoreBudgetTimes() async {
        let r = await rig(order: names, layout: layoutABCDE())
        for i in 0..<30 {
            await r.actuator.displace(k("A"), toIndex: [4, 3, 2, 1][i % 4])
            _ = await r.engine.reconcileOnce()
            _ = await r.engine.reconcileOnce(); _ = await r.engine.reconcileOnce()
        }
        #expect(await r.actuator.calls.count == 20)         // exactly the budget: it was reached, and nothing more is dragged
        #expect(await r.actuator.order.first != k("A"))
        await r.engine.userRetry()                           // only the user's intent gives the budget back
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == 21)
    }

    // ejb.15 (Wiring 3), CHANGED because the core decides: there is no per-key hold for a key whose VERIFIED moves were undone (that was `cannotPlace`);
    // the core strikes a key only for failed, posted drags. So the displaced key is placed again, then the other one, one move per read.
    @Test func aDisplacedKeyAndAnotherAreBothPlacedByTheCore() async {
        let r = await rig(order: names, layout: layoutABCDE())
        await thrashA(r)
        await r.actuator.displace(k("A"), toIndex: 4)
        await r.actuator.displace(k("C"), toIndex: 0)
        _ = await r.engine.reconcileOnce(); _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.order == names.map(k))
    }

    // ejb.15 (Wiring 3), CHANGED because the core decides: a verified move that macOS undoes is not an attempt in the core (only the budget bounds it, see
    // `aKeyMacOSKeepsDisplacingIsDraggedAtMostTheCoreBudgetTimes`): the key is dragged again and the row is not `cannotPlace`.
    @Test func aRevertedVerifiedMoveIsDraggedAgainWithinTheBudget() async {
        let r = await rig(order: names, layout: layoutABCDE())
        await r.actuator.displace(k("A"), toIndex: 4)
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == 1)
        await r.actuator.displace(k("A"), toIndex: 4)       // macOS puts it back
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == 2)
        if case .cannotPlace? = r.state.perItem[k("A")] { Issue.record("the core has no per-key give-up for verified moves") }
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
        // (ejb.15, CHANGED because the core decides: no per-key give-up, so no "A stays last" step here)
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
        // (ejb.15, CHANGED because the core decides: no per-key give-up, so no "A stays last" step here)
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
        // ejb.15 (Wiring 3), CHANGED because the core decides: the per-minute cap (`maxOrderMovesPerMinute`, `orderCapUntil`) no longer gates an order move; the
        // core's budget (3 on a full bar, 20 on one known not full) does (see `aKeyMacOSKeepsDisplacingIsDraggedAtMostTheCoreBudgetTimes`). Kept: membership
        // runs while no order move is made, and an order move is made only from a core Action.
        let r = await rig(order: names, layout: Layout(visible: names.reversed().map(k)), configure: { $0.maxOrderMovesPerMinute = 2; $0.maxAttemptsPerItem = 99 })
        let a = await r.engine.reconcileOnce()
        #expect(a.outcome == .converged)
        #expect(await r.actuator.calls.count == 4)          // the core sorts the reversed bar of 5 in 4 moves, however many the old cap allowed
        #expect(r.state.orderCapUntil == nil)
        var l = r.state.layout
        l.visible.removeAll { $0 == k("E") }
        l.hidden = [k("E")]
        await r.engine.setLayout(l)
        #expect(await waitUntil { await r.actuator.hidden.contains(k("E")) })
        #expect(await r.actuator.calls.count == 5)          // the membership batch only
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

    // MARK: 9o9.8 paused-retry backoff, wake signal, menu staleness

    @Test func pausedRetryDelaysDoubleAndCap() async {
        let r = await rig(order: names, layout: Layout(visible: names.reversed().map(k))) { $0.interactionRetry = .seconds(2); $0.interactionRetryMax = .seconds(60) }
        r.interaction.reason = "the mouse button is down"
        var seen: [Duration] = []
        for _ in 0..<8 {
            _ = await r.engine.reconcileOnce()
            if let d = await r.engine.lastPauseRetryDelay { seen.append(d) }
        }
        #expect(seen == [2, 4, 8, 16, 32, 60, 60, 60].map { Duration.seconds($0) })
    }

    @Test func anUnpausedPassResetsTheBackoff() async {
        let r = await rig(order: names, layout: Layout(visible: names.reversed().map(k))) { $0.interactionRetry = .seconds(2) }
        r.interaction.reason = "a modifier key is held"
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(await r.engine.lastPauseRetryDelay == .seconds(8))
        r.interaction.reason = nil
        _ = await r.engine.reconcileOnce()   // converges
        await r.actuator.displace(k("A"), toIndex: 0)   // new work, so the next paused pass reaches the gate again
        r.interaction.reason = "a modifier key is held"
        _ = await r.engine.reconcileOnce()
        #expect(await r.engine.lastPauseRetryDelay == .seconds(2))
    }

    @Test func lockedWaitsTheLongRetryAndWakeRunsAPassAtOnce() async {
        let r = await rig(order: names, layout: Layout(visible: names.reversed().map(k))) { $0.interactionRetry = .seconds(2) }
        r.interaction.reason = "the screen is locked"
        let a = await r.engine.reconcileOnce()
        #expect(a.outcome == .paused && a.actionCount == 0)
        #expect(await r.engine.lastPauseRetryDelay == .seconds(60))
        #expect(await r.actuator.calls.isEmpty)
        r.interaction.reason = nil
        await r.engine.interactionResumed()
        #expect(await waitUntil { await r.actuator.calls.count > 0 })
    }

    @Test func aMenuOpenPastTheBoundIsIgnoredUntilItClearsAndReappears() async {
        let r = await rig(order: names, layout: Layout(visible: names.reversed().map(k))) { $0.menuOpenMaxWait = .seconds(120) }
        r.interaction.reason = "a menu is open"
        #expect(await r.engine.reconcileOnce().outcome == .paused)
        r.clock.advance(100)
        #expect(await r.engine.reconcileOnce().outcome == .paused)
        #expect(!r.sink.lines.contains { $0.contains("pop-up window has been open") })
        r.clock.advance(30)   // 130 s since first seen
        #expect(await r.engine.reconcileOnce().outcome != .paused)
        #expect(r.sink.lines.filter { $0 == "engine: a pop-up window has been open for 2 min; ignoring it for ordering" }.count == 1)
        _ = await r.engine.reconcileOnce()
        #expect(r.sink.lines.filter { $0.contains("pop-up window has been open") }.count == 1)   // logged once
        r.interaction.reason = nil
        _ = await r.engine.reconcileOnce()
        await r.actuator.displace(k("A"), toIndex: 0)
        r.interaction.reason = "a menu is open"   // reappears: blocking again
        #expect(await r.engine.reconcileOnce().outcome == .paused)
    }

    @Test func otherReasonsAreNeverIgnoredByTheMenuBound() async {
        let r = await rig(order: names, layout: Layout(visible: names.reversed().map(k))) { $0.menuOpenMaxWait = .seconds(1) }
        r.interaction.reason = "the mouse button is down"
        _ = await r.engine.reconcileOnce()
        r.clock.advance(500)
        #expect(await r.engine.reconcileOnce().outcome == .paused)
    }
}
