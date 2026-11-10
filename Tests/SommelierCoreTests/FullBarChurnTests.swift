import Foundation
import Testing
@testable import SommelierCore

// gdu.80: a membership change on a full bar (chevron, system-overflow pile) must never be followed by an order drag in the same
// pass, the order phase waits for a settled overflow set, and the churn zone is never a move subject or anchor.
// Fixture numbers come from the rv65/r68 snapshots: chevron 786..803, pile at 772-803, first drawn item at 813.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private let chevKey = ItemKey.module(name: MenuBarItem.overflowChevronName)

private func entry(_ key: ItemKey, _ x: CGFloat, w: CGFloat = 24, chevron: Bool = false) -> ChurnRead.Entry {
    ChurnRead.Entry(key: key, frame: CGRect(x: x, y: 0, width: w, height: 24), isChevron: chevron)
}

/// P1..P3 in the pile, chevron, D1..D4 drawn from 813 (spacing 30).
private func rv65Read(pile: [String] = ["P1", "P2", "P3"], drawn: [String] = ["D1", "D2", "D3", "D4"]) -> ChurnRead {
    ChurnRead(entries: pile.map { entry(k($0), 772) } + [entry(chevKey, 786, w: 17, chevron: true)]
              + drawn.enumerated().map { entry(k($1), 813 + CGFloat($0) * 30) })
}

private struct Caps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability {
        if case .module = key { return Capability(canMove: false, canHide: false, reason: "system module") }
        return Capability(canMove: true, canHide: true)
    }
}

@Suite("Full-bar churn (gdu.80): rule and planner")
struct FullBarChurnRuleTests {
    @Test func churnZoneIsThePileAndTheFirstDrawnNeighbourhood() {
        let r = rv65Read()
        #expect(r.hasChevron)
        #expect(r.overflow == [k("P1"), k("P2"), k("P3")])
        // widest hosted item is 24: D1 (813) is the first drawn item; D2 starts at 843 > 813 + 24.
        #expect(r.zone == [k("P1"), k("P2"), k("P3"), k("D1")])
        #expect(SystemOverflowRule.churnZone([r]) == r.zone)
    }

    @Test func zoneIsTheUnionOfTheLastTwoReads() {
        let before = rv65Read()                                        // P3 piled
        let after = rv65Read(pile: ["P1", "P2"], drawn: ["P3", "D1", "D2", "D3", "D4"])   // P3 now drawn first
        let z = SystemOverflowRule.churnZone([before, after])
        #expect(z.contains(k("P3")) && z.contains(k("D1")))
        #expect(!z.contains(k("D4")))
        // only the last two reads count
        #expect(SystemOverflowRule.churnZone([before, after, after]).contains(k("P3")))   // P3 is the first drawn item of `after`
        #expect(SystemOverflowRule.churnZone([rv65Read(pile: ["X"]), after, after]).contains(k("X")) == false)
    }

    @Test func noChevronMeansNoZoneAndASettledBar() {
        let plain = ChurnRead(entries: (0..<4).map { entry(k("D\($0)"), 100 + CGFloat($0) * 30) })
        #expect(!plain.hasChevron && plain.zone.isEmpty && plain.overflow.isEmpty)
        #expect(SystemOverflowRule.overflowSettled([plain, plain]))
    }

    @Test func overflowSettledNeedsTwoAgreeingReads() {
        let a = rv65Read(), b = rv65Read(pile: ["P1", "P2", "P3", "D1"], drawn: ["D2", "D3", "D4"])
        #expect(!SystemOverflowRule.overflowSettled([a]))
        #expect(!SystemOverflowRule.overflowSettled([a, b]))
        #expect(SystemOverflowRule.overflowSettled([a, b, b]))
        #expect(SystemOverflowRule.overflowSettled([a, a]))
    }

}

/// Mutable bar geometry shared by the fake actuator's snapshots and the observer.
private final class Geometry: @unchecked Sendable {
    private let lock = NSLock()
    private var _pile = 3
    /// 9o9.28: keys whose identity is heuristic (no AX identifier): uncorroborated for the planner.
    nonisolated(unsafe) var blind: Set<String> = []
    private var _alternate = false
    private var reads = 0
    enum Chevron { case fixed(Bool), dropsOnceSomethingIsHidden, appearsOnceSomethingIsHidden }
    private var _chevron = Chevron.fixed(true)
    var chevron: Chevron {
        get { lock.lock(); defer { lock.unlock() }; return _chevron }
        set { lock.lock(); _chevron = newValue; lock.unlock() }
    }
    func hasChevron(hidden: Set<ItemKey>) -> Bool {
        switch chevron {
        case .fixed(let b): return b
        case .dropsOnceSomethingIsHidden: return hidden.isEmpty
        case .appearsOnceSomethingIsHidden: return !hidden.isEmpty
        }
    }
    var pile: Int {
        get { lock.lock(); defer { lock.unlock() }; return _pile }
        set { lock.lock(); _pile = newValue; lock.unlock() }
    }
    /// While true every read flips the pile size between 3 and 4 (an unsettled overflow set).
    var alternate: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _alternate }
        set { lock.lock(); _alternate = newValue; lock.unlock() }
    }
    func nextPile() -> Int {
        lock.lock(); defer { lock.unlock() }
        if _alternate { reads += 1; _pile = reads % 2 == 0 ? 3 : 4 }
        return _pile
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock(); private var l: [String] = []
    func add(_ s: String) { lock.lock(); l.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return l }
    func has(_ s: String) -> Bool { all.contains { $0.contains(s) } }
}

private func snapshot(_ g: Geometry, order: [ItemKey], hidden: Set<ItemKey>) -> MenuBarSnapshot {
    let chevron = g.hasChevron(hidden: hidden)
    func item(_ key: ItemKey, _ frame: CGRect, onBar: Bool, chev: Bool = false) -> MenuBarItem {
        MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: key.description, axDescription: "", axIdentifier: g.blind.contains(key.description) ? "" : key.description,
                    frame: frame, source: .appExtras, isOnMenuBar: onBar, isOverflowChevron: chev,
                    joinEvidence: g.blind.contains(key.description) ? JoinEvidence.none : .identifier)
    }
    var items: [MenuBarItem] = []
    let bar = order.filter { !hidden.contains($0) && $0 != chevKey }
    let pile = chevron ? g.nextPile() : 0
    for (i, key) in bar.enumerated() {
        if i < pile { items.append(item(key, CGRect(x: 772, y: 0, width: 24, height: 24), onBar: true)) }
        else { items.append(item(key, CGRect(x: 813 + CGFloat(i - pile) * 30, y: 0, width: 24, height: 24), onBar: true)) }
    }
    if chevron { items.append(item(chevKey, CGRect(x: 786, y: 0, width: 17, height: 24), onBar: true, chev: true)) }
    for key in hidden.sorted(by: { $0.description < $1.description }) {
        items.append(item(key, CGRect(x: -1000, y: 0, width: 24, height: 24), onBar: false))
    }
    return MenuBarSnapshot(items: SystemOverflow.mark(items), capturedAt: Date())
}

private struct GeoObserver: MenuBarObserver {
    let actuator: FakeActuator
    let geo: Geometry
    func observe() async throws -> [ResolvedItem] {
        let order = await actuator.order, hidden = await actuator.hidden
        return resolveBlind(snapshot(geo, order: order, hidden: hidden))
    }
}

/// `FakeMenuBar.resolve`, except an item with no AX identifier keeps its key (from the title) at heuristic confidence.
private func resolveBlind(_ s: MenuBarSnapshot) -> [ResolvedItem] {
    s.items.compactMap { i in
        if i.axIdentifier.isEmpty { return ItemKey(storeKey: i.title).map { ResolvedItem(item: i, key: $0, confidence: .heuristic) } }
        return ItemKey(storeKey: i.axIdentifier).map { ResolvedItem(item: i, key: $0, confidence: .exact) }
    }
}

private struct ChevRig {
    let engine: LayoutEngine
    let state: EngineState
    let actuator: FakeActuator
    let geo: Geometry
    let lines: Lines
}

@MainActor
private func chevRig(order: [ItemKey], hidden: Set<ItemKey> = [], layout: Layout, chevron: Bool = true,
                     reveal: Bool = false, mode: Geometry.Chevron? = nil, blind: Set<String> = []) async -> ChevRig {
    let geo = Geometry()
    geo.blind = blind
    let lines = Lines()
    geo.chevron = mode ?? .fixed(chevron)
    let act = FakeActuator(order: order, hidden: hidden, capabilities: Caps(),
                           makeSnapshot: { snapshot(geo, order: $0, hidden: $1) })
    let state = EngineState()
    let engine = LayoutEngine(observer: GeoObserver(actuator: act, geo: geo), actuator: act,
                              store: InMemoryLayoutStore(layout), capabilities: Caps(), state: state,
                              resolveSnapshot: { resolveBlind($0) }, sleep: { _ in }, log: { lines.add($0) },
                              showHiddenSection: reveal, config: .multiMove)
    await engine.start()
    return ChevRig(engine: engine, state: state, actuator: act, geo: geo, lines: lines)
}

private func moves(_ calls: [FakeActuator.Call]) -> [FakeActuator.Call] {
    calls.filter { if case .move = $0 { true } else { false } }
}

@MainActor
@Suite("Full-bar churn (gdu.80): engine")
struct FullBarChurnEngineTests {
    static let order = [k("P1"), k("P2"), k("P3"), k("D1"), k("D2"), k("D3"), k("D4"), k("D5")]
    /// Hides D5 (membership) and wants D4/D3 swapped (order): without the rule the SAME pass would drag.
    static let layout = Layout.placedAll(visible: [k("P1"), k("P2"), k("P3"), k("D1"), k("D2"), k("D4"), k("D3")], hidden: [k("D5")])

    @Test func aMembershipPassOnAFullBarNeverMovesInTheSamePass() async {
        let r = await chevRig(order: Self.order, layout: Self.layout)
        let rep = await r.engine.reconcileOnce()
        let calls = await r.actuator.calls
        #expect(calls.contains { if case .applyHiddenBatch = $0 { true } else { false } })
        #expect(moves(calls).isEmpty)
        #expect(rep.outcome != .converged || r.state.isConverged == false)
        #expect(r.state.isConverged == false)
        #expect(r.lines.has("order deferred: membership changed this pass"))
    }

    @Test func theFollowUpOrderPassRunsOnlyAfterTwoCompleteReadsAgree() async {
        let r = await chevRig(order: Self.order, layout: Self.layout)
        _ = await r.engine.reconcileOnce()                       // membership pass; deferred
        r.geo.alternate = true                                   // the pile keeps changing between reads
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(moves(await r.actuator.calls).isEmpty)
        #expect(r.lines.has("order deferred: overflow set unsettled: +["))   // 9o9.17: names the symmetric difference
        r.geo.alternate = false                                  // the bar settles
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(!moves(await r.actuator.calls).isEmpty)
    }

    // gdu.111 supersedes the gdu.80 membership-only reveal: on a full bar the reveal plans NO show (the panel is the reveal).
    @Test func revealOnAFullBarShowsNothingNeverDragsAndSurfacesTheNotice() async {
        let hidden = k("H1")
        let order = [k("P1"), k("P2"), k("P3"), k("D1"), k("D2"), k("D3"), k("D4")]
        // The layout order differs from the bar (D4 before D3); a reveal must not drag for it.
        let layout = Layout.placedAll(visible: [k("P1"), k("P2"), k("P3"), k("D1"), k("D2"), k("D4"), k("D3")], hidden: [hidden])
        let r = await chevRig(order: order, hidden: [hidden], layout: layout, reveal: true)
        let rep = await r.engine.reconcileOnce()
        let calls = await r.actuator.calls
        #expect(!calls.contains { if case .applyHiddenBatch(let c) = $0 { c[hidden] == false } else { false } })
        #expect(moves(calls).isEmpty)
        #expect(rep.outcome == .converged)
        #expect(ArrangeSections.revealSkipNotice(state: r.state) == "1 item could not be shown")
        // a second reveal pass (already shown) still drags nothing
        _ = await r.engine.reconcileOnce()
        #expect(moves(await r.actuator.calls).isEmpty)
    }

    /// 9o9.19: a crossing that makes macOS re-fold (the relation target D1 falls into the pile) is verified, not struck, and the tracker reports applied.
    @Test func aCrossingWhoseTargetRefoldsIntoThePileIsNotStruckAndTheTrackerReportsApplied() async {
        let order = [k("P1"), k("P2"), k("P3"), k("D1"), k("D2"), k("D3"), k("D4")]
        // P3 belongs after D1: pull it out; the fixed three-key pile then re-folds D1 behind the chevron.
        let layout = Layout.placedAll(visible: [k("P1"), k("P2"), k("D1"), k("P3"), k("D2"), k("D3"), k("D4")])
        let r = await chevRig(order: order, layout: layout)
        _ = await r.engine.reconcileOnce()
        #expect(moves(await r.actuator.calls).isEmpty)   // gdu.144: nothing is pulled out until the user drops P3
        await r.engine.setLayout(layout, moved: [k("P3")])
        for _ in 0..<5 { _ = await r.engine.reconcileOnce() }
        let ms = moves(await r.actuator.calls)
        #expect(ms == [.move(k("P3"), .after(k("D1")))])
        #expect(await r.actuator.recordOrder.filter { $0 != chevKey } == layout.visible)   // the record order, as the engine holds it
        #expect(!r.lines.has("planned again"))
        #expect(!r.lines.has("struck"))
        let after = await r.actuator.order
        let pile: Set<ItemKey> = Set(after.prefix(3))
        #expect(pile.contains(k("D1")))   // the target really did re-fold
        let observed = ObservedOrder(onBar: after + [chevKey], parked: [], systemOverflow: pile, overflowChevron: chevKey)
        var t = ArrangeTracker()
        let now = Date()
        t.record([k("P3")], passesStarted: 1, now: now, awaitingStamp: false, dropID: 9, intent: DropIntent(key: k("P3"), left: k("D1"), right: k("D2")))
        _ = t.update(observed: observed, layout: layout, perItem: [k("P3"): .inPlace], passSequence: 1, showHiddenSection: false, now: now)
        #expect(t.timedOut.isEmpty)
    }

    /// 9o9.28: the live 21:03 drop. D1 (drawn, first) is uncorroborated, so the pull-out is `P3 .before(D2)`; the tracker reports applied.
    @Test func aBeforeSpelledPullOutPastAnUntrustedDrawnKeyIsPlannedOnceAndTheTrackerReportsApplied() async {
        let order = [k("P1"), k("P2"), k("P3"), k("D1"), k("D2"), k("D3"), k("D4")]
        let layout = Layout.placedAll(visible: [k("P1"), k("P2"), k("D1"), k("P3"), k("D2"), k("D3"), k("D4")])
        let r = await chevRig(order: order, layout: layout, blind: [k("D1").description])
        _ = await r.engine.reconcileOnce()
        await r.engine.setLayout(layout, moved: [k("P3")])   // gdu.144: the user drops P3
        for _ in 0..<5 { _ = await r.engine.reconcileOnce() }
        // ejb.15 (Wiring 3), CHANGED because the core decides: D1, the only drawn key left of P3 in the record, has an untrusted frame (blind), so the core is told
        // it is UNREAD (A6). It cannot place P3 against a key it cannot judge: it makes NO pull-out (the old planner re-spelled it `P3 before D2`, relative to a key
        // it trusted). Safety kept: no drag names the untrusted D1, nothing is struck, and P3 stays behind the chevron until D1 can be read.
        let ms = moves(await r.actuator.calls)
        #expect(ms.isEmpty, "moves=\(ms)")
        #expect(!r.lines.has("struck"))
        let after = await r.actuator.order
        let pile: Set<ItemKey> = Set(after.prefix(3))
        #expect(pile.contains(k("P3")))
    }

    @Test func anOrdinaryOrderPassOnABarWithoutAChevronIsUnchanged() async {
        let order = [k("A"), k("B"), k("C")]
        let r = await chevRig(order: order, layout: Layout.placedAll(visible: [k("C"), k("B"), k("A")]), chevron: false)
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .converged)
        #expect(!moves(await r.actuator.calls).isEmpty)
        #expect(!r.lines.has("order deferred"))
    }

    // ejb.15 (Wiring 3), CHANGED because the core decides (plan assumption 4): a pass that wrote membership feeds its read as settled:false and makes no order
    // move in that pass, chevron or not; the order follows on the next pass (it used to follow in the same pass on a bar without a chevron).
    @Test func aMembershipThenOrderPassOnABarWithoutAChevronOrdersOnTheNextPass() async {
        let order = [k("A"), k("B"), k("C"), k("D")]
        let r = await chevRig(order: order, layout: Layout.placedAll(visible: [k("C"), k("B"), k("A")], hidden: [k("D")]), chevron: false)
        let rep = await r.engine.reconcileOnce()
        let calls = await r.actuator.calls
        #expect(rep.outcome == .converged)   // sommelier-ejb.7, CHANGED: a hide on a bar with no chevron leaves nothing to read; the pass is converged (no order is planned in Swift)
        #expect(r.state.coreStatus != .matches && r.state.coreStatus != .moving, "nothing was read: the core must not claim the bar matches; got \(String(describing: r.state.coreStatus))")
        #expect(calls.contains { if case .applyHiddenBatch = $0 { true } else { false } })
        #expect(moves(calls).isEmpty)
        let next = await r.engine.reconcileOnce()
        #expect(next.outcome == .converged)
        #expect(!moves(await r.actuator.calls).isEmpty)
    }

    /// 9o9.12: touching the churn zone is no longer refused; the move is performed inside ONE strip session (open, drag, close).
    @Test func theEngineDragsAChurnZoneItemInsideExactlyOneStripSession() async {
        // settled full bar: D1 is the first drawn item (churn zone); the layout wants it last.
        let order = [k("P1"), k("P2"), k("P3"), k("D1"), k("D2"), k("D3"), k("D4")]
        let layout = Layout.placedAll(visible: [k("P1"), k("P2"), k("P3"), k("D2"), k("D3"), k("D4"), k("D1")])
        let r = await chevRig(order: order, layout: layout)
        await r.actuator.setStripPolicy { _, key, rel in
            if key == k("D1") { return true }
            switch rel { case .before(let t), .after(let t): return t == k("D1"); default: return false }
        }
        for _ in 0..<5 { _ = await r.engine.reconcileOnce() }   // (the full-bar gate needs two agreeing reads before any drag)
        #expect(moves(await r.actuator.calls).isEmpty)   // gdu.144 B4: the engine never opens the strip on its own
        #expect(await r.actuator.stripEvents.isEmpty)
        await r.engine.setLayout(layout, moved: [k("D1")])   // ... only the user's own drop of D1 may
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        let touched = moves(await r.actuator.calls).flatMap { c -> [ItemKey] in
            guard case .move(let s, let rel) = c else { return [] }
            switch rel { case .before(let t), .after(let t): return [s, t]; default: return [s] }
        }
        #expect(touched.contains(k("D1")))
        #expect(!touched.contains(k("P3")))
        let events = await r.actuator.stripEvents
        #expect(events.filter { $0 == .expanded }.count == 1)
        #expect(events.filter { $0 == .collapsed }.count == 1)
        #expect(events.first == .expanded && events.last == .collapsed && events.count == 3)
    }

    @Test func aFailedStripDragStillClosesTheStripExactlyOnce() async {
        let order = [k("P1"), k("P2"), k("P3"), k("D1"), k("D2"), k("D3"), k("D4")]
        let layout = Layout.placedAll(visible: [k("P1"), k("P2"), k("P3"), k("D2"), k("D3"), k("D4"), k("D1")])
        let r = await chevRig(order: order, layout: layout)
        await r.actuator.setStripPolicy { _, _, _ in true }
        await r.actuator.failOnCall(1, .mechanismFailed("injected drag failure"))
        _ = await r.engine.reconcileOnce()
        await r.engine.setLayout(layout, moved: [k("D1")])   // gdu.144 B4: only the user's own drop opens the strip
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }   // the full-bar gate needs two agreeing reads before the first drag
        let events = await r.actuator.stripEvents
        #expect(events.count >= 3)
        #expect(events.first == .expanded)
        #expect(events.filter { $0 == .expanded }.count == events.filter { $0 == .collapsed }.count)   // every open has its close
        if case .moved? = events.dropFirst().first {} else { Issue.record("expected the drag between open and close: \(events)") }
        #expect(events.dropFirst(2).first == .collapsed)
    }

    @Test func aMoveInsideTheDrawnRegionOpensNoStripSession() async {
        let order = [k("P1"), k("P2"), k("P3"), k("D1"), k("D2"), k("D3"), k("D4")]
        let layout = Layout.placedAll(visible: [k("P1"), k("P2"), k("P3"), k("D1"), k("D2"), k("D4"), k("D3")])
        let r = await chevRig(order: order, layout: layout)
        await r.actuator.setStripPolicy { _, key, rel in
            // the policy a real actuator applies: only the fold/churn neighbourhood needs the strip
            let zone: Set<ItemKey> = [k("P1"), k("P2"), k("P3"), k("D1")]
            if zone.contains(key) { return true }
            switch rel { case .before(let t), .after(let t): return zone.contains(t); default: return false }
        }
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(!moves(await r.actuator.calls).isEmpty)
        #expect(await r.actuator.stripEvents.isEmpty)
    }
}

@MainActor
@Suite("Full-bar churn (gdu.80): chevron changes across the write")
struct FullBarChevronChangeTests {
    static let layout = FullBarChurnEngineTests.layout
    static let order = FullBarChurnEngineTests.order
    static func touched(_ calls: [FakeActuator.Call]) -> [ItemKey] {
        moves(calls).flatMap { c -> [ItemKey] in
            guard case .move(let s, let rel) = c else { return [] }
            switch rel { case .before(let t), .after(let t): return [s, t]; default: return [s] }
        }
    }

    @Test func noChevronBeforeChevronAfterDefersTheOrderPhase() async {
        let r = await chevRig(order: Self.order, layout: Self.layout, mode: .appearsOnceSomethingIsHidden)
        let rep = await r.engine.reconcileOnce()
        let calls = await r.actuator.calls
        #expect(calls.contains { if case .applyHiddenBatch = $0 { true } else { false } })
        #expect(moves(calls).isEmpty)
        #expect(rep.outcome == .incomplete && r.state.isConverged == false)
        #expect(r.lines.has("order deferred: membership changed this pass"))
    }

    @Test func chevronBeforeNoneAfterAReHideDefersAndOrdersOnlyAfterTwoAgreeingReads() async {
        let r = await chevRig(order: Self.order, layout: Self.layout, mode: .dropsOnceSomethingIsHidden)
        let rep = await r.engine.reconcileOnce()
        let calls = await r.actuator.calls
        #expect(calls.contains { if case .applyHiddenBatch = $0 { true } else { false } })
        #expect(moves(calls).isEmpty)                      // the incident pattern: no drag right after the write
        #expect(rep.outcome == .incomplete && r.state.isConverged == false)
        #expect(r.lines.has("order deferred: membership changed this pass"))
        // the post-write read (no chevron) does not agree with the pre-write one (chevron); the follow-up pass's own read agrees
        // with the post-write read, so ordering happens there and only there
        _ = await r.engine.reconcileOnce()
        // ejb.15 (Wiring 3), CHANGED because the core decides: the chevron was fresh in the pre-write read, so the core no longer knows the bar is not full and
        // makes no move on the chevronless read that follows (the old engine ordered here, capped at 3). It orders once chevronless complete reads prove the
        // bar not full (gdu.144 D1: three in a row, the proof taking effect from the next pass read).
        #expect(moves(await r.actuator.calls).isEmpty)
        for _ in 0..<8 { _ = await r.engine.reconcileOnce() }
        #expect(!moves(await r.actuator.calls).isEmpty)
    }

}

@Suite("Full-bar churn (gdu.80): actuator guard")
struct FullBarChurnGuardTests {
    @Test func theChurnRefusalCountsAsAnOverflowRefusal() {
        #expect(ActuationError.mechanismFailed("X \(SystemOverflowRule.churnRefusalMarker); a drag cannot be trusted there").isOverflowRefusal)
    }
}
