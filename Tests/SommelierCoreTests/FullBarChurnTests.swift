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

    /// 9o9.12: the planner no longer keeps the churn zone out of the plan; the actuator performs such a move inside a strip session.
    @Test func plannerPlansAMoveOfAChurnZoneItemBecauseTheActuatorOpensTheStrip() {
        let read = rv65Read()
        let churn = SystemOverflowRule.churnZone([read])
        let on = [k("P1"), k("P2"), k("P3"), chevKey, k("D1"), k("D2"), k("D3"), k("D4")]
        let observed = ObservedOrder(onBar: on, parked: [], systemOverflow: read.overflow, overflowChevron: chevKey)
        // The layout wants D1 last and D4 first: D1 is in the churn zone (the first drawn key).
        let layout = Layout.placedAll(visible: [k("P1"), k("P2"), k("P3"), k("D4"), k("D2"), k("D3"), k("D1")])
        let caps: (ItemKey) -> Capability = { _ in Capability(canMove: true, canHide: true) }
        let plan = Reconciler().plan(observed: observed, layout: layout, capabilities: caps)
        func involved(_ p: Plan) -> Set<ItemKey> {
            Set(p.actions.flatMap { a -> [ItemKey] in
                guard case .move(let s, let rel) = a else { return [] }
                switch rel { case .before(let t), .after(let t): return [s, t]; default: return [s] }
            })
        }
        #expect(churn.contains(k("D1")))
        #expect(!involved(plan).isDisjoint(with: churn))
        #expect(!plan.skipped.contains { $0.reason == SystemOverflowRule.churnSkipReason })
    }

    @Test func anOrdinaryBarStillPlansItsMoveWithoutAnyChurnInput() {
        let on = [k("A"), k("B"), k("C")]
        let observed = ObservedOrder(onBar: on, parked: [])
        let layout = Layout.placedAll(visible: [k("C"), k("B"), k("A")])
        let caps: (ItemKey) -> Capability = { _ in Capability(canMove: true, canHide: true) }
        let plain = Reconciler().plan(observed: observed, layout: layout, capabilities: caps)
        #expect(!plain.actions.isEmpty)
    }
}

/// Mutable bar geometry shared by the fake actuator's snapshots and the observer.
private final class Geometry: @unchecked Sendable {
    private let lock = NSLock()
    private var _pile = 3
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
        MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: key.description, axDescription: "", axIdentifier: key.description,
                    frame: frame, source: .appExtras, isOnMenuBar: onBar, isOverflowChevron: chev, joinEvidence: .identifier)
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
        return FakeMenuBar.resolve(snapshot(geo, order: order, hidden: hidden))
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
                     reveal: Bool = false, mode: Geometry.Chevron? = nil) async -> ChevRig {
    let geo = Geometry()
    let lines = Lines()
    geo.chevron = mode ?? .fixed(chevron)
    let act = FakeActuator(order: order, hidden: hidden, capabilities: Caps(),
                           makeSnapshot: { snapshot(geo, order: $0, hidden: $1) })
    let state = EngineState()
    let engine = LayoutEngine(observer: GeoObserver(actuator: act, geo: geo), actuator: act,
                              store: InMemoryLayoutStore(layout), capabilities: Caps(), state: state,
                              resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { lines.add($0) },
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
        #expect(r.lines.has("order deferred: overflow set unsettled"))
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

    @Test func anOrdinaryOrderPassOnABarWithoutAChevronIsUnchanged() async {
        let order = [k("A"), k("B"), k("C")]
        let r = await chevRig(order: order, layout: Layout.placedAll(visible: [k("C"), k("B"), k("A")]), chevron: false)
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .converged)
        #expect(!moves(await r.actuator.calls).isEmpty)
        #expect(r.state.orderNotAppliedNotice == nil)
        #expect(!r.lines.has("order deferred"))
    }

    @Test func aMembershipThenOrderPassOnABarWithoutAChevronStillOrdersInOnePass() async {
        let order = [k("A"), k("B"), k("C"), k("D")]
        let r = await chevRig(order: order, layout: Layout.placedAll(visible: [k("C"), k("B"), k("A")], hidden: [k("D")]), chevron: false)
        let rep = await r.engine.reconcileOnce()
        let calls = await r.actuator.calls
        #expect(rep.outcome == .converged)
        #expect(calls.contains { if case .applyHiddenBatch = $0 { true } else { false } })
        #expect(!moves(calls).isEmpty)
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
        #expect(!moves(await r.actuator.calls).isEmpty)
    }

    @Test func theChurnZoneNoLongerExcludesThePlannerWhenTheChevronVanishes() {
        let on = [k("P1"), k("P2"), k("P3"), k("D1"), k("D2"), k("D3")]
        let observed = ObservedOrder(onBar: on, parked: [])
        let layout = Layout.placedAll(visible: [k("P3"), k("P2"), k("P1"), k("D1"), k("D3"), k("D2")])
        let zone = SystemOverflowRule.churnZone([rv65Read(), ChurnRead(entries: [])])
        #expect(zone.contains(k("P3")) && zone.contains(k("D1")))
        let caps: (ItemKey) -> Capability = { _ in Capability(canMove: true, canHide: true) }
        let open = Reconciler().plan(observed: observed, layout: layout, capabilities: caps)
        func ks(_ p: Plan) -> Set<ItemKey> {
            Set(p.actions.flatMap { a -> [ItemKey] in
                guard case .move(let s, let rel) = a else { return [] }
                switch rel { case .before(let t), .after(let t): return [s, t]; default: return [s] }
            })
        }
        #expect(!ks(open).isDisjoint(with: zone))   // the zone is the ACTUATOR's guard now (it opens the strip, or finds no chevron and drags)
    }
}

@Suite("Full-bar churn (gdu.80): actuator guard")
struct FullBarChurnGuardTests {
    @Test func theChurnRefusalCountsAsAnOverflowRefusal() {
        #expect(ActuationError.mechanismFailed("X \(SystemOverflowRule.churnRefusalMarker); a drag cannot be trusted there").isOverflowRefusal)
    }
}
