import Foundation
import Testing
@testable import SommelierCore

// 9o9.17: carried (stale) frames keep pile membership so the overflow set settles on a bar with a stalling AX server (iStat Menus);
// the unsettled log names the difference; a stacked pile key is never "uncorroborated for 60 s".

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private let chevKey = ItemKey.module(name: MenuBarItem.overflowChevronName)
private func entry(_ key: ItemKey, _ x: CGFloat, w: CGFloat = 24, chevron: Bool = false, stale: Bool = false) -> ChurnRead.Entry {
    ChurnRead.Entry(key: key, frame: CGRect(x: x, y: 0, width: w, height: 24), isChevron: chevron, stale: stale)
}
/// 9 pile keys stacked at 772, a chevron at 786, three drawn items; the first `carried` pile keys (from the end) are carried.
private func read(carried: Int, chevronStale: Bool = false) -> ChurnRead {
    let pile = (0..<9).map { k("P\($0)") }
    return ChurnRead(entries: pile.enumerated().map { entry($1, 772, stale: $0 >= 9 - carried) }
                     + [entry(chevKey, 786, w: 17, chevron: true, stale: chevronStale)]
                     + (0..<3).map { entry(k("D\($0)"), 813 + CGFloat($0) * 30) })
}

@Suite("Overflow settle with carried frames (9o9.17)")
struct OverflowSettleRuleTests {
    @Test func carriedPileKeysKeepTheirMembership() {
        let complete = read(carried: 0), stalled = read(carried: 7)
        #expect(complete.overflow.count == 9)
        #expect(stalled.overflow == complete.overflow)
        #expect(stalled.zone == complete.zone)
    }

    @Test func alternatingCompleteAndStalledReadsSettle() {
        let a = read(carried: 0), b = read(carried: 7)
        #expect(SystemOverflowRule.overflowSettled([a, b]))
        #expect(SystemOverflowRule.overflowSettled([b, a]))
        #expect(SystemOverflowRule.overflowSettled([a, b, a, b]))
    }

    @MainActor @Test func completeAndExceptSelfPositioningReadsBothFeedTheGate() async {
        let pile = (0..<3).map { k("P\($0)") }
        func items(_ x: CGFloat) -> [ResolvedItem] {
            func item(_ key: ItemKey, _ x: CGFloat, chevron: Bool = false) -> ResolvedItem {
                ResolvedItem(item: MenuBarItem(ownerPID: 1, ownerBundleID: "com.x", ownerName: "X", title: key.description, axDescription: "", axIdentifier: key.description,
                                               frame: CGRect(x: x, y: 3, width: chevron ? 17 : 24, height: 24), source: .appExtras, isOnMenuBar: true,
                                               isOverflowChevron: chevron), key: key, confidence: .exact)
            }
            return pile.map { item($0, 772) } + [item(chevKey, 786, chevron: true), item(k("D"), x)]
        }
        let engine = LayoutEngine(observer: PileObserver(), actuator: FakeActuator(order: [], hidden: [], capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) }),
                                  store: InMemoryLayoutStore(Layout()), capabilities: Caps(), state: EngineState(), resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, config: .plain())
        await engine.noteChurn(items(813), .complete)
        await engine.noteChurn(items(813), .completeExceptSelfPositioning)
        let reads = await engine.recentReads
        #expect(reads.count == 2)
        #expect(SystemOverflowRule.overflowSettled(reads))
        await engine.noteChurn(items(813), .incomplete)
        #expect(await engine.recentReads.count == 2)   // an incomplete read is not recorded
    }

    @Test func aStaleChevronStillFlagsNothing() {
        let r = read(carried: 7, chevronStale: true)
        #expect(!r.hasChevron && r.overflow.isEmpty)
    }

    @Test func aCarriedDrawnItemRightOfTheChevronIsNotInThePile() {
        let r = ChurnRead(entries: [entry(k("P"), 772), entry(chevKey, 786, w: 17, chevron: true), entry(k("D"), 813, stale: true)])
        #expect(r.overflow == [k("P")])
    }

    @Test func symmetricDifferenceIsNamedWhenUnsettled() {
        let a = read(carried: 0)
        let b = ChurnRead(entries: (0..<7).map { entry(k("P\($0)"), 772) } + [entry(chevKey, 786, w: 17, chevron: true)]
                          + [entry(k("D0"), 813), entry(k("Q"), 843)])
        #expect(!SystemOverflowRule.overflowSettled([a, b]))
        let d = SystemOverflowRule.overflowDifference([a, b])
        #expect(d.added.isEmpty && Set(d.removed) == [k("P7"), k("P8")])
        let t = SystemOverflowRule.unsettledText([a, b])
        #expect(t.hasPrefix("order deferred: overflow set unsettled: +[] -["))
        #expect(t.contains(k("P7").description) && t.contains(k("P8").description))
        let c = SystemOverflowRule.unsettledText([b, a])
        #expect(c.contains("+[") && !c.contains("+[]"))
    }

    @Test func theLogListIsCappedAtTen() {
        let a = ChurnRead(entries: [entry(chevKey, 786, w: 17, chevron: true)])
        let b = ChurnRead(entries: (0..<14).map { entry(k("P\($0)"), 772) } + [entry(chevKey, 786, w: 17, chevron: true)])
        let t = SystemOverflowRule.unsettledText([a, b])
        #expect(t.contains("+4 more"))
    }

    @Test func observedOrderAndVerifierAgreeOnCarriedPileKeys() {
        func item(_ key: ItemKey, _ x: CGFloat, chevron: Bool = false, stale: Bool = false) -> ResolvedItem {
            ResolvedItem(item: MenuBarItem(ownerPID: 1, ownerBundleID: "com.x", ownerName: "X", title: key.description, axDescription: "", axIdentifier: key.description,
                                           frame: CGRect(x: x, y: 3, width: chevron ? 17 : 24, height: 24), source: .appExtras, isOnMenuBar: true,
                                           stale: stale, isOverflowChevron: chevron), key: key, confidence: .exact)
        }
        let items = [item(k("A"), 772), item(k("B"), 772, stale: true), item(k("C"), 772, stale: true), item(chevKey, 786, chevron: true), item(k("D"), 813)]
        let marked = SystemOverflow.mark(items.map(\.item))
        let resolved = zip(items, marked).map { ResolvedItem(item: $1, key: $0.key, confidence: .exact) }
        let o = ObservedOrder(resolved: resolved)
        #expect(o.systemOverflow == [k("A"), k("B"), k("C")])
        #expect(ActuationVerifier.overflowed(resolved) == o.systemOverflow)
        #expect(ChurnRead(resolved: resolved).overflow == o.systemOverflow)
        #expect(o.staleOnBar == [k("B"), k("C")])   // still never a move subject
    }
}

private struct Caps: CapabilityProvider { func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) } }

/// Bar: P1 P2 P3 stacked behind a chevron, D1 D2 drawn. `ambiguous` pile keys carry `frameAmbiguous`; `drawnP3` draws P3 right of the chevron.
private final class PileObserver: MenuBarObserver, @unchecked Sendable {
    private let lock = NSLock(); private var _drawn = false; private var n = 0
    var drawn: Bool { get { lock.lock(); defer { lock.unlock() }; return _drawn } set { lock.lock(); _drawn = newValue; lock.unlock() } }
    private func bump() -> Bool { lock.lock(); defer { lock.unlock() }; n += 1; return n % 2 == 0 }
    func observe() async throws -> [ResolvedItem] {
        func item(_ key: ItemKey, _ x: CGFloat, chevron: Bool = false, ambiguous: Bool = false, stale: Bool = false) -> MenuBarItem {
            MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: key.description, axDescription: "", axIdentifier: key.description,
                        frame: CGRect(x: x, y: 0, width: chevron ? 17 : 24, height: 24), source: .appExtras, isOnMenuBar: true,
                        stale: stale, isOverflowChevron: chevron, joinEvidence: ambiguous ? .frameAmbiguous : .identifier)
        }
        let d = drawn
        let carried = bump()   // every other read P3 is carried (stale) at its stacked frame
        var items = [item(k("P1"), 772), item(k("P2"), 772), item(k("P3"), d ? 843 : 772, ambiguous: !d, stale: carried && !d),
                     item(chevKey, 786, chevron: true), item(k("D1"), 813), item(k("D2"), 873)]
        if d { items.swapAt(2, 5) }
        return FakeMenuBar.resolve(MenuBarSnapshot(items: SystemOverflow.mark(items), capturedAt: Date()))
    }
}

private final class PileLines: @unchecked Sendable {
    private let lock = NSLock(); private var l: [String] = []
    func add(_ s: String) { lock.lock(); l.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return l }
}

@MainActor
@Suite("Stacked pile keys are never unsupported (9o9.17)")
struct StackedPileStatusTests {
    @Test func aStackedPileKeyStaysNotFittingPastTheUncorroboratedTimeout() async {
        let obs = PileObserver(); let sink = PileLines()
        let act = FakeActuator(order: [k("P1"), k("P2"), k("P3"), k("D1"), k("D2")], hidden: [], capabilities: Caps(),
                               makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        var c = LayoutEngine.Config.plain(); c.positionWaitTimeout = .milliseconds(60); c.positionRetryBase = .seconds(60); c.positionRetryCap = .seconds(60)
        let state = EngineState()
        let engine = LayoutEngine(observer: obs, actuator: act, store: InMemoryLayoutStore(Layout(visible: [k("P1"), k("P2"), k("P3"), chevKey, k("D1"), k("D2")])),
                                  capabilities: Caps(), state: state, busy: { false }, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { sink.add($0) }, config: c)
        await engine.start()
        for _ in 0..<6 {
            _ = await engine.reconcileOnce()
            try? await Task.sleep(for: .milliseconds(40))   // 240 ms against a 60 ms timeout: the 60 s path, compressed
            #expect(state.perItem[k("P3")] == .notFitting, "got \(state.perItem) obs=\(String(describing: state.observed.onBar))")
            for key in [k("P1"), k("P2"), k("P3")] {
                if case .unsupported = state.perItem[key] { Issue.record("\(key) unsupported") }
                if case .waitingForPosition = state.perItem[key] { Issue.record("\(key) waiting") }
            }
        }
        #expect(await engine.positionWaitInfo.timedOut == 0)
        // Live symptom path: P3 is carried every other read. Unflagged, the carried pile key read .inPlace
        // (before the fix); flagged it stays in the pile (.notFitting), never starts the timer, and nothing is logged as uncorroborated.
        #expect(!sink.all.contains { $0.contains("position not corroborated") })
        #expect(await engine.positionWaitInfo.waiting == 0)
        // drawn again: it leaves .notFitting
        obs.drawn = true
        _ = await engine.reconcileOnce()
        #expect(state.perItem[k("P3")] != .notFitting)
    }

    @Test func aPileKeyWhoseOwnPositionIsUnreadIsStillPulledOutAndStaysPendingNeverUnsupported() async {
        let act = FakeActuator(order: [k("P1"), k("P2"), k("P3"), k("D1"), k("D2")], hidden: [], capabilities: Caps(),
                               makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        let state = EngineState()
        let engine = LayoutEngine(observer: PileObserver(), actuator: act,
                                  store: InMemoryLayoutStore(Layout(visible: [k("P1"), k("P2"), chevKey, k("D1"), k("P3"), k("D2")])),
                                  capabilities: Caps(), state: state, busy: { false }, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { _ in }, config: .plain())
        await engine.start()
        _ = await engine.reconcileOnce()
        // sommelier-ejb.7, CHANGED because the core decides: the planner-level halves (the pull-out the Reconciler would plan, and the held-key skip reason) are
        // gone with the order planner; the engine-level claim stays: the pile key reads behind « and is never unsupported.
        #expect(state.perItem[k("P3")] == .notFitting, "got \(String(describing: state.perItem[k("P3")]))")
        if case .unsupported = state.perItem[k("P3")] { Issue.record("P3 unsupported") }
    }
}
