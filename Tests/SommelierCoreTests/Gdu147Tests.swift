import CoreGraphics
import Foundation
import Testing
import DecisionCore
@testable import SommelierCore

// gdu.147: Sommelier's own menu bar item is orderable (Visible only), never hidden.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private let own = ItemKey.sommelierStatusItem
private let clock = ItemKey.module(name: "Clock")
private let rules = CapabilityRules(hasTrackedEntry: { _ in true })

private final class Lines147: @unchecked Sendable {
    private let l = NSLock(); private var v: [String] = []
    func add(_ s: String) { l.lock(); v.append(s); l.unlock() }
    var lines: [String] { l.lock(); defer { l.unlock() }; return v }
}
private final class Store147: LayoutStore, @unchecked Sendable {
    private let l = NSLock(); private var layout: Layout; private var n = 0
    init(_ x: Layout) { layout = x }
    func load() throws -> Layout { l.lock(); defer { l.unlock() }; return layout }
    func save(_ x: Layout) throws { l.lock(); defer { l.unlock() }; layout = x; n += 1 }
    var saves: Int { l.lock(); defer { l.unlock() }; return n }
}
private struct Good147: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] { FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden)) }
}
private struct Rig147 { let engine: LayoutEngine; let state: EngineState; let actuator: FakeActuator; let store: Store147; let sink: Lines147 }

@MainActor
private func rig(order: [ItemKey], layout: Layout, observe: Bool = false) async -> Rig147 {
    let act = FakeActuator(order: order, hidden: [], capabilities: rules, makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let store = Store147(layout), state = EngineState(), sink = Lines147()
    var cfg = LayoutEngine.Config.plain()
    cfg.observeGate = ObserveOnlyGate(fixed: observe)
    let engine = LayoutEngine(observer: Good147(actuator: act), actuator: act, store: store, capabilities: rules, state: state, busy: { false },
                              resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { sink.add($0) }, config: cfg)
    await engine.start()
    return Rig147(engine: engine, state: state, actuator: act, store: store, sink: sink)
}

@MainActor
@Suite struct Gdu147Tests {
    // MARK: key and capability

    @Test func oneStableKeyAndNeverHideable() {
        #expect(own.isSommelierStatusItem && !k("a").isSommelierStatusItem && !clock.isSommelierStatusItem)
        #expect(ItemKey(storeKey: own.description) == own)
        for r in [rules, CapabilityRules(hasTrackedEntry: { _ in false })] {
            let c = r.capability(for: own)
            #expect(c.canMove && !c.canHide && c.reason == "Sommelier stays visible so you can always reach it")
        }
        // Arrange resolves it that way before it is observed too.
        #expect(!ArrangeCapabilities.resolve(own, items: [:], rules: rules).canHide)
        // And a look-alike is an ordinary item.
        #expect(rules.capability(for: .status(ownerKey: "ie.boboco.sommelier", autosaveName: "Other")).canHide)
    }

    // MARK: record insertion

    /// The record gets the key at the bar's CURRENT slot, so the upgrade pass and every later one make zero actuator calls.
    private func lacking(_ bar: [ItemKey], _ layout: [ItemKey], expect: [ItemKey]) async {
        let r = await rig(order: bar, layout: Layout(visible: layout))
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        let l = r.state.layout
        #expect(l.visible == expect)
        #expect(l.hidden.isEmpty && l.alwaysHidden.isEmpty)
        #expect(await r.actuator.calls.isEmpty)
        #expect(await r.actuator.order == bar)
        #expect(r.state.layout.visible.filter { $0 == own }.count == 1)   // added once
        #expect(r.sink.lines.filter { $0.contains("adding Sommelier's own status item at its observed position") }.count == 1)
        #expect(r.state.newItemNotice == nil)   // not announced as someone else's new item
        #expect(r.store.saves >= 1)
    }

    @Test func aLayoutLackingTheKeyGetsItAtItsObservedSlotWithZeroActuatorCalls() async {
        await lacking([k("a"), own, k("b"), clock], [k("a"), k("b"), clock], expect: [k("a"), own, k("b"), clock])   // mid-bar (reviewer's world)
    }
    @Test func ownItemFirstOnTheBar() async {
        await lacking([own, k("a"), k("b"), clock], [k("a"), k("b"), clock], expect: [own, k("a"), k("b"), clock])
    }
    @Test func ownItemLastBeforeTheSystemBlock() async {
        await lacking([k("a"), k("b"), own, clock], [k("a"), k("b"), clock], expect: [k("a"), k("b"), own, clock])
    }

    @Test func candidateSlotCountsEveryRecordedKeyTheScanShows() {
        func slot(_ bar: [ItemKey], _ rec: [ItemKey], stale: [ItemKey] = [], pile: [ItemKey] = []) -> Int? {
            LayoutEngine.ownCandidateSlot(ObservedOrder(onBar: bar, parked: [], systemOverflow: Set(pile), uncorroborated: Set(stale), staleOnBar: Set(stale)),
                                          layout: Layout(visible: rec))
        }
        let a = k("a"), b = k("b"), c = k("c")
        #expect(slot([a, own, b, clock], [a, b, clock]) == 1)
        #expect(slot([own, a, b, clock], [a, b, clock]) == 0)
        #expect(slot([a, b, own, clock], [a, b, clock]) == 2)
        #expect(slot([a, own, b, clock], [a, b, clock], stale: [a]) == 1)          // a stale neighbour still bounds the slot
        #expect(slot([a, b, own, c, clock], [a, b, c, clock], stale: [b]) == 2)
        #expect(slot([a, own, clock], [a, clock], stale: [own]) == nil)            // own on a stale frame: wait
        #expect(slot([a, clock, own], [a, clock]) == 1)                            // never inside/after the system block
        #expect(LayoutEngine.ownCandidateSlot(ObservedOrder(onBar: [a], parked: [own]), layout: Layout(visible: [a])) == nil)   // parked-only
        // folded keys come first, then the drawn ones by x: own is after every folded recorded key
        #expect(slot([b, a, own, c, clock], [a, b, c, clock], pile: [b, a]) == 1)
        #expect(slot([own, a], [a], pile: [own]) == nil)                           // own folded: wait
    }

    @Test func foldedOwnItemIsRecordedBesideItsNeighboursWithoutDrags() async {
        // The own item is on the bar list but undrawn (folded): recorded relative to the trusted neighbours, no actuator call.
        let r = await rig(order: [own, k("a"), k("b"), clock], layout: Layout(visible: [k("a"), k("b"), clock]))
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(r.state.layout.visible.firstIndex(of: own) != nil)
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func neverObservedMeansNothingInsertedYet() async {
        // Own item absent from the bar: no guess at the right-most slot, no save, no calls.
        let r = await rig(order: [k("a"), k("b"), clock], layout: Layout(visible: [k("a"), k("b"), clock]))
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(!r.state.layout.visible.contains(own))
        #expect(await r.actuator.calls.isEmpty)
        #expect(r.state.layout.visible == [k("a"), k("b"), clock])
    }

    @Test func theNewItemPolicyHiddenDoesNotHideIt() async {
        let r = await rig(order: [k("a"), own, clock], layout: Layout(visible: [k("a"), clock], newItemPolicy: .hidden))
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(r.state.layout.visible.contains(own) && !r.state.layout.hidden.contains(own))
        let calls = await r.actuator.calls
        #expect(!calls.contains { if case .move = $0 { return false } else { return true } })   // no membership call
    }

    @Test func underObserveOnlyNothingIsSavedAndItIsShownAsItWouldBe() async {
        let r = await rig(order: [k("a"), own, k("b"), clock], layout: Layout(visible: [k("a"), k("b"), clock]), observe: true)
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(r.store.saves == 0)
        #expect(await r.actuator.calls.isEmpty)
        #expect(r.state.layout.visible == [k("a"), own, k("b"), clock])
        #expect(r.sink.lines.contains { $0.contains("would add Sommelier's own status item") })
        #expect(r.sink.lines.contains { $0.contains("observe-only: would save layout") })
    }

    // MARK: order, never membership

    @Test func theEnginePlansAnOrderMoveOfTheOwnKeyLikeAnyOtherAndNeverAMembershipAction() async {
        let r = await rig(order: [k("a"), k("b"), own, clock], layout: Layout(visible: [own, k("a"), k("b"), clock]))
        _ = await r.engine.reconcileOnce()
        let calls = await r.actuator.calls
        #expect(calls.count == 1)
        if case .move(let moved, _)? = calls.first { #expect(moved == own) } else { Issue.record("expected a move of the own key, got \(calls)") }
        #expect(await r.actuator.hidden.isEmpty)
        #expect(await r.actuator.order == [own, k("a"), k("b"), clock])
    }

    @Test func thePlannerNeverHidesOrShowsIt() {
        // Listed in Hidden by a stale in-memory layout while drawn: still no hide; parked: still no show; unlisted under policy hidden: Visible.
        let hiddenListed = Layout(visible: [k("a")], hidden: [own])
        let p1 = Reconciler().plan(observed: ObservedOrder(onBar: [k("a"), own], parked: []), layout: hiddenListed, capabilities: rules.capability(for:))
        #expect(p1.actions.isEmpty)
        let p2 = Reconciler().plan(observed: ObservedOrder(onBar: [k("a")], parked: [own]), layout: hiddenListed, capabilities: rules.capability(for:), showHiddenSection: true)
        #expect(p2.actions.isEmpty)
        let p3 = Reconciler().plan(observed: ObservedOrder(onBar: [k("a"), own], parked: []), layout: Layout(visible: [k("a")], newItemPolicy: .hidden), capabilities: rules.capability(for:))
        #expect(p3.newItems == [NewItem(own, .visible)] && p3.actions.isEmpty)
    }

    // MARK: layout healing

    @Test func decodeHealsALayoutHoldingItOutsideVisible() throws {
        let json = #"{"visible":["status:com.x.a::a","module:Clock"],"hidden":["status:ie.boboco.sommelier::Sommelier"],"alwaysHidden":["status:ie.boboco.sommelier::Sommelier","status:com.x.b::b"]}"#
        let r = try Layout.decode(Data(json.utf8))
        #expect(r.layout.visible == [k("a"), own, clock])
        #expect(r.layout.hidden.isEmpty && r.layout.alwaysHidden == [k("b")])
        #expect(r.warnings.contains { $0.contains("never hidden") })
        let c = try JSONDecoder().decode(Layout.self, from: Data(json.utf8))   // the Codable path heals the same way
        #expect(c.visible.contains(own) && !c.hidden.contains(own) && !c.alwaysHidden.contains(own))
    }

    @Test func setLayoutNeverStoresItHidden() async throws {
        let r = await rig(order: [k("a"), own, clock], layout: Layout(visible: [k("a"), own, clock]))
        _ = await r.engine.reconcileOnce()
        var l = r.state.layout
        try l.move(own, to: .hidden)
        _ = await r.engine.setLayout(l)
        #expect(r.state.layout.section(of: own) == .visible)
    }

    @Test func buildFromAScanPutsItInVisibleEvenIfReportedParked() {
        let item = MenuBarItem(ownerPID: 9, ownerBundleID: menuBarAgentBundleID, ownerName: "Sommelier", title: "", axDescription: "Sommelier",
                               axIdentifier: MenuBarScanner.ownStatusItemIdentifier, frame: CGRect(x: 0, y: 0, width: 24, height: 24),
                               source: .agentHostedOnly, isOnMenuBar: false)
        let l = LayoutBuilder.build(from: [ResolvedItem(item: item, key: own, confidence: .exact)]).layout
        #expect(l.visible == [own] && l.hidden.isEmpty)
    }

    // MARK: Arrange

    @Test func arrangeShowsADraggableRowInVisibleAndRefusesHiding()  throws {
        let items: [ItemKey: ItemInfo] = [
            k("a"): ItemInfo(key: k("a"), title: "", axDescription: "A", ownerPID: 1, ownerBundleID: "com.x", ownerName: "A", width: 30, isOnBar: true),
            own: ItemInfo(key: own, title: " Observe", axDescription: "Sommelier", ownerPID: 99, ownerBundleID: menuBarAgentBundleID, ownerName: "Sommelier", width: 70, isOnBar: true),
        ]
        let layout = Layout(visible: [k("a"), own, clock])
        let caps: (ItemKey) -> Capability = { ArrangeCapabilities.resolve($0, items: items, rules: rules) }
        let c = ArrangeSections.make(observed: ObservedOrder(onBar: [k("a"), own, clock], parked: []), layout: layout, items: items, perItem: [:], capabilities: caps)
        let row = try! #require(c.visible.rows.first { $0.key == own })
        #expect(row.draggable && !row.canHide && row.title == "Sommelier")
        #expect(!row.movableTo.contains(.hidden) && !row.movableTo.contains(.alwaysHidden))
        // A drop inside Visible reorders it.
        if case .move(let l, _, _) = ArrangeDrop.outcome(layout: layout, key: own, to: .visible, index: 0, capabilities: caps) {
            #expect(l.visible == [own, k("a"), clock])
        } else { Issue.record("a Visible reorder must be accepted") }
        // Hidden and Always hidden are refused with the one line.
        for s in [LayoutSection.hidden, .alwaysHidden] {
            #expect(ArrangeDrop.outcome(layout: layout, key: own, to: s, index: nil, capabilities: caps) == .rejected("Sommelier stays visible so you can always reach it"))
            #expect(!ArrangeDrop.canMove(layout: layout, key: own, to: s, capabilities: caps))
        }
        // "Hide what does not fit" never takes it.
        let hnf = try ArrangeDrop.hideNotFitting(layout: layout, observed: ObservedOrder(onBar: [k("a"), own, clock], parked: [], systemOverflow: [own]), capabilities: caps, units: .ownerKeys)
        #expect(!hnf.layout.hidden.contains(own))
    }

    // MARK: overflow panel

    @Test func theOverflowPanelNeverOffersItEvenIfALayoutListsItHidden() {
        let info = ItemInfo(key: own, title: "", axDescription: "Sommelier", ownerPID: 99, ownerBundleID: menuBarAgentBundleID, ownerName: "Sommelier", width: 30, isOnBar: false)
        let healed = Layout(visible: [own], hidden: []).healingSommelierItem().layout
        #expect(OverflowEntries.make(layout: healed, items: [own: info], includeAlwaysHidden: true).isEmpty)
        let stale = Layout(visible: [], hidden: [own, k("h")])
        let entries = OverflowEntries.make(layout: stale, items: [own: info], includeAlwaysHidden: true)
        #expect(!entries.contains { $0.key == own })
    }

    // MARK: ReadAdapter

    @Test func theReadAdapterTrustsItWhenItIsDrawnFreshAndRecorded() throws {
        let o = ObservedOrder(onBar: [k("a"), own, k("b"), clock], parked: [])
        // The own process is running and fully read: running evidence lists it, no unread owner names it.
        let ev = OwnerEvidence(running: [UnreadOwner(pid: 99, bundleID: "ie.boboco.sommelier")])
        var keys = CoreKeys()
        let a = try ReadAdapter.adapt(o, context: ReadContext(kind: .pass, ownerEvidence: ev), record: [k("a"), own, k("b")], keys: &keys)
        let id = try #require(keys.id(for: own))
        #expect(a.read.drawn.contains(id) && a.read.trusted.contains(id) && !a.read.unread.contains(id))
        #expect(a.record.contains(id))
    }
}

// MARK: hand drag on the own item (both event sources feed one tracker)

@Suite struct Gdu147HandDragTests {
    private final class Rec: @unchecked Sendable {
        private let l = NSLock(); private var v: [HandDragEvent] = []
        func add(_ e: HandDragEvent) { l.lock(); v.append(e); l.unlock() }
        var events: [HandDragEvent] { l.lock(); defer { l.unlock() }; return v }
    }
    private let bar = [CGRect(x: 0, y: 0, width: 1000, height: 24)]
    private let on = CGPoint(x: 500, y: 10)

    @Test func aCommandDragIsSeenAndAPlainClickIsNot() {
        let rec = Rec(); let t = HandDragTracker { rec.add($0) }
        t.handle(.down, commandHeld: false, point: on, rects: bar)   // plain click opening our menu
        t.handle(.up, commandHeld: false, point: on, rects: bar)
        #expect(rec.events.isEmpty)
        t.handle(.down, commandHeld: true, point: on, rects: bar)
        t.handle(.up, commandHeld: false, point: .zero, rects: [])
        #expect(rec.events == [.began, .ended])
    }

    @Test func aCommandClickOutsideTheBarIsIgnored() {
        let rec = Rec(); let t = HandDragTracker { rec.add($0) }
        t.handle(.down, commandHeld: true, point: CGPoint(x: 500, y: 400), rects: bar)
        t.handle(.up, commandHeld: false, point: .zero, rects: [])
        #expect(rec.events.isEmpty)
    }

    @Test func aDragSeenByBothMonitorsBeginsAndEndsOnceEach() {
        let rec = Rec(); let t = HandDragTracker { rec.add($0) }
        t.handle(.down, commandHeld: true, point: on, rects: bar)   // global source
        t.handle(.up, commandHeld: false, point: .zero, rects: [])  // local source
        t.handle(.up, commandHeld: false, point: .zero, rects: [])  // global source, duplicate
        #expect(rec.events == [.began, .ended])
    }
}


// MARK: world rig (gdu.147 corrective 2): reviewer worlds, R5 property, adoption

private let chevKey147 = ItemKey.module(name: MenuBarItem.overflowChevronName)
private final class WStore147: LayoutStore, @unchecked Sendable { private let l = NSLock(); private var x: Layout; init(_ x: Layout) { self.x = x }
    func load() throws -> Layout { l.lock(); defer { l.unlock() }; return x }; func save(_ y: Layout) throws { l.lock(); x = y; l.unlock() } }

/// A bar built from the FakeActuator order, with optional stale / frame-ambiguous keys and a chevron before index `chevAt`.
private struct WObs147: MenuBarObserver {
    let act: FakeActuator; let stale: Set<ItemKey>; let ambiguous: Set<ItemKey>; let chevAt: Int?
    func observe() async throws -> [ResolvedItem] {
        let order = await act.order
        var items: [MenuBarItem] = []
        var x: CGFloat = 100
        for (i, key) in order.enumerated() {
            if let c = chevAt, c == i {
                var ch = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: "chev", axDescription: "", axIdentifier: "", frame: CGRect(x: x, y: 0, width: 17, height: 24), source: .appExtras, isOnMenuBar: true, isOverflowChevron: true, joinEvidence: .identifier)
                ch.controlCenterAllowed = true; items.append(ch); x += 30
            }
            var it = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: key.description, axDescription: "", axIdentifier: key.description,
                                 frame: CGRect(x: x, y: 0, width: 24, height: 24), source: key == own ? .agentHostedOnly : .appExtras, isOnMenuBar: true,
                                 joinEvidence: ambiguous.contains(key) ? .frameAmbiguous : .identifier)
            it.controlCenterAllowed = true
            if stale.contains(key) { it.stale = true }
            items.append(it); x += 30
        }
        let s = MenuBarSnapshot(items: SystemOverflow.mark(items), capturedAt: Date())
        return s.items.map { i in ResolvedItem(item: i, key: i.isOverflowChevron ? chevKey147 : ItemKey(storeKey: i.axIdentifier)!, confidence: .exact) }
    }
}

private struct WorldResult { let calls: [FakeActuator.Call]; let layout: Layout; let lines: [String]; let engine: LayoutEngine; let actuator: FakeActuator; let state: EngineState }

@MainActor private func world(bar: [ItemKey], rec: [ItemKey], stale: Set<ItemKey> = [], amb: Set<ItemKey> = [], chevAt: Int? = nil,
                              passes: Int = 5, observe: Bool = false) async -> WorldResult {
    let act = FakeActuator(order: bar, hidden: [], capabilities: rules, makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let st = EngineState(), sink = Lines147()
    var cfg = LayoutEngine.Config.plain()
    cfg.observeGate = ObserveOnlyGate(fixed: observe)
    let e = LayoutEngine(observer: WObs147(act: act, stale: stale, ambiguous: amb, chevAt: chevAt), actuator: act, store: WStore147(Layout(visible: rec)), capabilities: rules,
                         state: st, busy: { false }, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { sink.add($0) }, config: cfg)
    await e.start()
    for _ in 0..<passes { _ = await e.reconcileOnce() }
    return WorldResult(calls: await act.calls, layout: st.layout, lines: sink.lines, engine: e, actuator: act, state: st)
}

/// Calls that name the own key as subject or as anchor.
private func ownCalls(_ c: [FakeActuator.Call]) -> [FakeActuator.Call] {
    c.filter { call in
        guard case .move(let m, let r) = call else { return false }
        if m == own { return true }
        switch r { case .before(let t), .after(let t): return t == own; default: return false }
    }
}

private struct SplitMix147 { var s: UInt64
    mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    mutating func chance(_ pct: Int) -> Bool { below(100) < pct }
    mutating func shuffled<T>(_ a: [T]) -> [T] { var a = a; if a.count > 1 { for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, below(i + 1)) } }; return a }
}

@MainActor
@Suite struct Gdu147PlacementTests {
    /// Reviewer worlds: the insertion must not create an inversion, so the own key is never a subject or an anchor and the call count is unchanged.
    @Test(arguments: [
        ("e6", [k("b"), k("a"), own, clock], [k("a"), k("b"), clock]),
        ("e4", [k("c"), k("b"), own, k("a"), clock], [k("a"), k("b"), k("c"), clock]),
        ("b-new-item", [k("a"), k("u"), own, k("b"), clock], [k("a"), k("b"), clock]),
        ("e1", [k("a"), own, k("c"), k("b"), clock], [k("a"), k("b"), k("c"), clock]),
        ("e2", [k("b"), own, k("a"), k("c"), clock], [k("a"), k("b"), k("c"), clock]),
        ("e5", [own, k("b"), k("a"), clock], [k("a"), k("b"), clock]),
    ] as [(String, [ItemKey], [ItemKey])])
    func reviewerWorldsAddNoDragOfTheOwnKey(_ w: (String, [ItemKey], [ItemKey])) async {
        let with = await world(bar: w.1, rec: w.2)
        let without = await world(bar: w.1.filter { $0 != own }, rec: w.2)
        #expect(ownCalls(with.calls).isEmpty, "\(w.0): \(with.calls)")
        #expect(with.calls.count == without.calls.count, "\(w.0): with \(with.calls) without \(without.calls)")
    }

    @Test func e4IsNotPlacedYetAndLogsOncePerLaunch() async {
        let r = await world(bar: [k("c"), k("b"), own, k("a"), clock], rec: [k("a"), k("b"), k("c"), clock], passes: 6, observe: true)
        #expect(!r.layout.visible.contains(own))
        #expect(r.lines.filter { $0.contains("Sommelier's own item is not placed yet: the bar differs from your saved order around it") }.count == 1)
    }

    @Test func matchingWorldsRecordItAtTheirSlotWithZeroCalls() async {
        for (bar, rec, expect) in [
            ([k("a"), own, k("b"), clock], [k("a"), k("b"), clock], [k("a"), own, k("b"), clock]),
            ([own, k("a"), k("b"), clock], [k("a"), k("b"), clock], [own, k("a"), k("b"), clock]),
            ([k("a"), k("b"), own, clock], [k("a"), k("b"), clock], [k("a"), k("b"), own, clock]),
            ([k("p"), own, k("q"), k("a"), clock], [k("p"), k("q"), k("a"), clock], nil as [ItemKey]?),   // own folded behind a chevron: not recorded (no candidate), no call
        ] as [([ItemKey], [ItemKey], [ItemKey]?)] {
            let r = await world(bar: bar, rec: rec, chevAt: expect == nil ? 3 : nil)
            #expect(r.calls.isEmpty, "\(bar)")
            if let expect { #expect(r.layout.visible == expect, "\(bar)") } else { #expect(!r.layout.visible.contains(own), "\(bar)") }
        }
    }

    /// R6: unrecorded own key (the bar disagrees around it) + "Use the bar's current order" (a user edit that adopts the bar) -> placed next pass.
    @Test func adoptingTheBarsOrderLetsItBePlacedOnTheNextPass() async {
        let bar = [k("c"), k("b"), own, k("a"), clock]
        let r = await world(bar: bar, rec: [k("a"), k("b"), k("c"), clock], passes: 3, observe: true)
        #expect(!r.layout.visible.contains(own))
        // Arrange with the own key unrecorded: rows build, no crash, it is not offered a hide.
        let caps: (ItemKey) -> Capability = { ArrangeCapabilities.resolve($0, items: [:], rules: rules) }
        let c = ArrangeSections.make(observed: ObservedOrder(onBar: bar, parked: []), layout: r.layout, items: [:], perItem: [:], capabilities: caps)
        #expect(!c.hidden.rows.contains { $0.key == own } && !c.alwaysHidden.rows.contains { $0.key == own })
        #expect(!caps(own).canHide)
        // Adopt: record := the bar's order (no own key in it, as the proposal never lists an unrecorded key).
        _ = await r.engine.setLayout(Layout(visible: [k("c"), k("b"), k("a"), clock]), userPlacement: true)
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(r.state.layout.visible == [k("c"), k("b"), own, k("a"), clock])
    }

    /// R5 property over random worlds: with the own item present, no actuator call names it, and the number of calls equals the world without it;
    /// when the bar already agrees with the record the own key ends up recorded.
    @Test func propertyOwnKeyNeverCausesADragAndIsPlacedWhenTheBarAgrees() async {
        var rng = SplitMix147(s: 0x147_5EED)
        let pool = ["a", "b", "c", "d"].map(k)
        var recordedWhenAgreeing = 0, agreeing = 0
        for n in 0..<360 {
            let onBar = rng.shuffled(pool).prefix(1 + rng.below(4)).map { $0 }
            let hasNew = rng.chance(25)
            let u = k("u")
            var rec = onBar.isEmpty ? [] : rng.shuffled(onBar)
            if rng.chance(20) { rec.insert(k("x"), at: rng.below(rec.count + 1)) }   // a recorded key that is off the bar
            let agree = rng.chance(35)
            var bar: [ItemKey] = agree ? rec.filter { onBar.contains($0) } : onBar
            if hasNew { bar.insert(u, at: rng.below(bar.count + 1)) }
            var withOwn = bar
            let at = rng.below(withOwn.count + 1)
            withOwn.insert(own, at: at)
            let stale = Set(onBar.filter { _ in rng.chance(12) })
            let amb = Set(onBar.filter { _ in rng.chance(12) })
            let recFull = rec + [clock], bar1 = bar + [clock], bar2 = withOwn + [clock]
            let with = await world(bar: bar2, rec: recFull, stale: stale, amb: amb)
            let without = await world(bar: bar1, rec: recFull, stale: stale, amb: amb)
            #expect(ownCalls(with.calls).isEmpty, "case \(n): bar \(bar2) rec \(recFull): \(with.calls)")
            #expect(with.calls.count == without.calls.count, "case \(n): bar \(bar2) rec \(recFull): with \(with.calls) without \(without.calls)")
            #expect(with.layout.visible.filter { $0 == own }.count <= 1 && !with.layout.hidden.contains(own))
            if agree && !hasNew && stale.isEmpty && amb.isEmpty {
                agreeing += 1
                if with.layout.visible.contains(own) { recordedWhenAgreeing += 1 }
                #expect(with.layout.visible.contains(own), "case \(n): matching world left the own key unrecorded: bar \(bar2) rec \(recFull)")
            }
        }
        #expect(agreeing >= 30)
        _ = recordedWhenAgreeing
    }
}


// ===== gdu.147 J3: the proved core judges the insertion; the own key never changes what the engine does =====
private final class Sched147: @unchecked Sendable {
    private let l = NSLock(); var pass = 0; let staleUntil: [ItemKey: Int]
    init(_ s: [ItemKey: Int]) { staleUntil = s }
    func staleNow() -> Set<ItemKey> { l.lock(); defer { l.unlock() }; return Set(staleUntil.filter { pass < $0.value }.keys) }
    func tick() { l.lock(); pass += 1; l.unlock() }
}
private struct SObs147: MenuBarObserver {
    let act: FakeActuator; let sched: Sched147; let chevAt: Int?; let omitOwn: Bool
    func observe() async throws -> [ResolvedItem] {
        let order = await act.order
        let stale = sched.staleNow()
        var items: [MenuBarItem] = []
        var x: CGFloat = 100
        for (i, key) in order.enumerated() {
            if let c = chevAt, c == i {
                var ch = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: "chev", axDescription: "", axIdentifier: "", frame: CGRect(x: x, y: 0, width: 17, height: 24), source: .appExtras, isOnMenuBar: true, isOverflowChevron: true, joinEvidence: .identifier)
                ch.controlCenterAllowed = true; items.append(ch); x += 30
            }
            var it = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: key.description, axDescription: "", axIdentifier: key.description,
                                 frame: CGRect(x: x, y: 0, width: 24, height: 24), source: key == own ? .agentHostedOnly : .appExtras, isOnMenuBar: true, joinEvidence: .identifier)
            it.controlCenterAllowed = true
            if stale.contains(key) { it.stale = true }
            if !(omitOwn && key == own) { items.append(it) }   // omitted: physically there (it takes its slot), but the scan does not return it (the old dropSelf)
            x += 30
        }
        let s = MenuBarSnapshot(items: SystemOverflow.mark(items), capturedAt: Date())
        return s.items.map { i in ResolvedItem(item: i, key: i.isOverflowChevron ? chevKey147 : ItemKey(storeKey: i.axIdentifier)!, confidence: .exact) }
    }
}
@MainActor private func sworld(bar: [ItemKey], rec: [ItemKey], staleUntil: [ItemKey: Int], chevAt: Int?, passes: Int = 7, omitOwn: Bool = false) async -> ([FakeActuator.Call], Layout, EngineState) {
    let act = FakeActuator(order: bar, hidden: [], capabilities: rules, makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let st = EngineState(), sink = Lines147(), sch = Sched147(staleUntil)
    var cfg = LayoutEngine.Config.plain(); cfg.observeGate = ObserveOnlyGate(fixed: false)
    let e = LayoutEngine(observer: SObs147(act: act, sched: sch, chevAt: chevAt, omitOwn: omitOwn), actuator: act, store: WStore147(Layout(visible: rec)), capabilities: rules,
                         state: st, busy: { false }, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { sink.add($0) }, config: cfg)
    await e.start()
    for _ in 0..<passes { _ = await e.reconcileOnce(); sch.tick() }
    return (await act.calls, st.layout, st)
}

@MainActor @Suite struct Gdu147JudgeTests {
    /// Named worlds: with the own item present the actuator calls are IDENTICAL to the world without it, and none names the own key.
    @Test(arguments: [
        ("A", "a,o,b,Z", "a,b,Z", "a:3", -1),
        ("B", "a,b,o,c,Z", "a,b,c,Z", "b:3", -1),
        ("C", "a,o,b,c,Z", "a,b,c,Z", "b:3", -1),
        ("e4", "c,b,o,a,Z", "a,b,c,Z", "", -1),
        ("e6", "b,a,o,Z", "a,b,Z", "", -1),
        ("b-new-item", "a,u,o,b,Z", "a,b,Z", "", -1),
        ("folded", "d,o,c,e,Z", "d,e,c,x,Z", "", 1),    // chevron after d: reviewer's folded example
    ])
    func namedWorlds(_ w: (String, String, String, String, Int)) async {
        func keys(_ s: String) -> [ItemKey] { s.split(separator: ",").map { $0 == "o" ? own : $0 == "Z" ? clock : k(String($0)) } }
        let su: [ItemKey: Int] = Dictionary(uniqueKeysWithValues: w.3.split(separator: ",").map { p in let q = p.split(separator: ":"); return (k(String(q[0])), Int(q[1])!) })
        let bar = keys(w.1), rec = keys(w.2)
        let ch: Int? = w.4 < 0 ? nil : w.4
        let with = await sworld(bar: bar, rec: rec, staleUntil: su, chevAt: ch)
        let without = await sworld(bar: bar, rec: rec, staleUntil: su, chevAt: ch, omitOwn: true)   // same physical bar, own item not scanned
        #expect(ownCalls(with.0).isEmpty, "\(w.0): \(with.0)")
        #expect(with.0 == without.0, "\(w.0): with \(with.0) without \(without.0)")
    }

    @Test func aFullyReadMatchingScanRecordsItAndShowsNoWaitingLine() async {
        let r = await sworld(bar: [k("a"), own, k("b"), clock], rec: [k("a"), k("b"), clock], staleUntil: [:], chevAt: nil)
        #expect(r.1.visible == [k("a"), own, k("b"), clock])
        #expect(r.0.isEmpty)
        #expect(r.2.ownItemWaitingNotice == nil)
    }

    @Test func whileWaitingArrangeShowsOneExplanatoryLine() async {
        let r = await world(bar: [k("c"), k("b"), own, k("a"), clock], rec: [k("a"), k("b"), k("c"), clock], passes: 3, observe: true)
        #expect(!r.layout.visible.contains(own))
        #expect(r.state.ownItemWaitingNotice == "Sommelier's own item will appear here once the menu bar matches your saved order around it")
        let c = CoreStatusText.context(state: r.state, trusted: true, conflicting: nil)
        #expect(c.notices.filter { $0 == OwnItemNotice.waiting }.count == 1)
    }

    @Test func aSetLayoutThatRecordsTheKeyClearsTheWaitingNotice() async {
        let r = await world(bar: [k("c"), k("b"), own, k("a"), clock], rec: [k("a"), k("b"), k("c"), clock], passes: 3, observe: true)
        #expect(r.state.ownItemWaitingNotice != nil)
        _ = await r.engine.setLayout(Layout(visible: [k("c"), k("b"), own, k("a"), clock]), userPlacement: true)
        #expect(r.state.ownItemWaitingNotice == nil)
    }

    @Test func staleNeighbourDelaysButNeverDragsTheOwnKey() async {
        let r = await sworld(bar: [k("a"), own, k("b"), k("c"), clock], rec: [k("a"), k("b"), k("c"), clock], staleUntil: [k("a"): 3], chevAt: nil)
        #expect(ownCalls(r.0).isEmpty && r.0.isEmpty)
        #expect(r.1.visible == [k("a"), own, k("b"), k("c"), clock])   // placed on the first fully read scan
    }

    @Test func extendedProperty() async {
        var rng = SplitMix147(s: 0xBEEF_147)
        let pool = ["a", "b", "c", "d", "e"].map(k)
        var viol = 0, placed = 0, agreeingFull = 0, agreeingPlaced = 0, cases = 0
        for n in 0..<2600 {
            let onBar = Array(rng.shuffled(pool).prefix(1 + rng.below(5)))
            var rec = rng.shuffled(onBar)
            if rng.chance(20) { rec.insert(k("x"), at: rng.below(rec.count + 1)) }
            let agree = rng.chance(50)
            var bar: [ItemKey] = agree ? rec.filter { onBar.contains($0) } : onBar
            let nNew = rng.below(3)
            for nm in ["u", "v"].prefix(nNew) { bar.insert(k(nm), at: rng.below(bar.count + 1)) }
            var withOwn = bar; withOwn.insert(own, at: rng.below(withOwn.count + 1))
            var su: [ItemKey: Int] = [:]
            for key in onBar where rng.chance(25) { su[key] = 1 + rng.below(3) }
            let chevAtW: Int? = rng.chance(35) ? rng.below(withOwn.count + 1) : nil
            let with = await sworld(bar: withOwn + [clock], rec: rec + [clock], staleUntil: su, chevAt: chevAtW)
            let without = await sworld(bar: withOwn + [clock], rec: rec + [clock], staleUntil: su, chevAt: chevAtW, omitOwn: true)   // same physical bar and fold geometry; own not scanned
            cases += 1
            if with.1.visible.contains(own) { placed += 1 }
            // The proved core's final verdict must not get worse because the own key was recorded: matching without it => matching with it.
            func matchLike(_ x: EngineState) -> Bool { switch x.coreDisplay?.status { case .matches?, .matchesExcept?: return true; default: return false } }
            let worse = matchLike(without.2) && !matchLike(with.2)
            if !ownCalls(with.0).isEmpty || with.0 != without.0 || worse {
                viol += 1
                if viol <= 8 { print("JUDGE VIOL case \(n): bar \(withOwn + [clock]) rec \(rec + [clock]) stale \(su) chevAt \(String(describing: chevAtW)) finalRec \(with.1.visible) with \(with.0) without \(without.0)") }
            }
            if agree && nNew == 0 && su.isEmpty && chevAtW == nil {
                agreeingFull += 1
                if with.1.visible.contains(own) { agreeingPlaced += 1 } else { print("JUDGE NOT PLACED case \(n): bar \(withOwn + [clock]) rec \(rec + [clock])") }
            }
        }
        print("JUDGE SUMMARY cases=\(cases) violations=\(viol) foldAdjacentExempt=0 placed=\(placed) agreeingFull=\(agreeingFull) agreeingPlaced=\(agreeingPlaced)")
        #expect(cases >= 2500)
        #expect(viol == 0)
        #expect(agreeingFull >= 100 && agreeingPlaced == agreeingFull)
    }
}

// ===== gdu.147: events (hand-drag adoption, Re-apply, user drops) =====
private enum RevEv: Int { case plain = 0, hand, reapply, drop }
@MainActor private func rworld(bar: [ItemKey], rec: [ItemKey], staleUntil: [ItemKey: Int], chevAt: Int?, omitOwn: Bool, ev: RevEv, evKey: ItemKey?, evIdx: Int, passes: Int = 8) async -> ([FakeActuator.Call], Layout, EngineState, Bool, [ItemKey]) {
    let act = FakeActuator(order: bar, hidden: [], capabilities: rules, makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let st = EngineState(), sink = Lines147(), sch = Sched147(staleUntil)
    var cfg = LayoutEngine.Config.plain(); cfg.observeGate = ObserveOnlyGate(fixed: false)
    cfg.delaySleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
    cfg.handDragAdoptWait = .zero
    let e = LayoutEngine(observer: SObs147(act: act, sched: sch, chevAt: chevAt, omitOwn: omitOwn), actuator: act, store: WStore147(Layout(visible: rec)), capabilities: rules,
                         state: st, busy: { false }, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { sink.add($0) }, config: cfg)
    await e.start()
    var ownUnrecordedAtEv = false
    for p in 0..<passes {
        if p == 3 {
            ownUnrecordedAtEv = !st.layout.allKeys.contains(own)
            switch ev {
            case .plain: break
            case .hand:
                e.handDragEvent(.began)
                if let key = evKey { await act.displace(key, toIndex: evIdx) }
                e.handDragEvent(.ended)
                for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(15))
            case .reapply: await e.userRetry()
            case .drop:
                if let key = evKey {
                    var vis = st.layout.visible
                    let ownAt = vis.firstIndex(of: own)
                    var non = vis.filter { $0 != own }
                    if let i = non.firstIndex(of: key) { non.remove(at: i); let lim = non.firstIndex(of: clock) ?? non.count; non.insert(key, at: min(evIdx, lim)) }
                    vis = non
                    if let o = ownAt { vis.insert(own, at: min(o, vis.count)) }
                    var l = st.layout; l.visible = vis
                    _ = await e.setLayout(l, userPlacement: true, moved: [key])
                }
            }
        }
        _ = await e.reconcileOnce(); sch.tick()
    }
    return (await act.calls, st.layout, st, ownUnrecordedAtEv, await act.order)
}
private func moveSet(_ c: [FakeActuator.Call]) -> [String] { c.compactMap { if case .move = $0 { return "\($0)" } else { return nil } } }

@MainActor @Suite struct Gdu147EventTests {
    private func gen(_ rng: inout SplitMix147, pool: [ItemKey]) -> (rec: [ItemKey], withOwn: [ItemKey], su: [ItemKey: Int], chevAt: Int?, onBarCount: Int) {
        let onBar = Array(rng.shuffled(pool).prefix(1 + rng.below(5)))
        var rec = rng.shuffled(onBar)
        if rng.chance(20) { rec.insert(k("x"), at: rng.below(rec.count + 1)) }
        let agree = rng.chance(50)
        var bar: [ItemKey] = agree ? rec.filter { onBar.contains($0) } : onBar
        let nNew = rng.below(3)
        for nm in ["u", "v"].prefix(nNew) { bar.insert(k(nm), at: rng.below(bar.count + 1)) }
        var withOwn = bar; withOwn.insert(own, at: rng.below(withOwn.count + 1))
        var su: [ItemKey: Int] = [:]
        for key in onBar where rng.chance(25) { su[key] = 1 + rng.below(3) }
        let chevAtW: Int? = rng.chance(35) ? rng.below(withOwn.count + 1) : nil
        return (rec, withOwn, su, chevAtW, onBar.count)
    }

    /// Near-chevron worlds (the own item in the first three slots after the chevron) were the old exemption: now IDENTICAL calls, no exemption.
    /// Named worlds 277 and 613 of the review are included.
    @Test func namedNearChevronWorlds() async {
        func keys(_ s: String) -> [ItemKey] { s.split(separator: ",").map { $0 == "o" ? own : $0 == "Z" ? clock : k(String($0)) } }
        for (bar, rec, su, ch) in [
            ("v,a,o,u,c,Z", "c,a,Z", [k("c"): 2], 2),   // case 277
            ("o,u,a,Z", "a,Z", [:], 0),                  // case 613
        ] as [(String, String, [ItemKey: Int], Int)] {
            let w = await sworld(bar: keys(bar), rec: keys(rec), staleUntil: su, chevAt: ch)
            let wo = await sworld(bar: keys(bar), rec: keys(rec), staleUntil: su, chevAt: ch, omitOwn: true)
            #expect(w.0 == wo.0, "\(bar): with \(w.0) without \(wo.0)")
            #expect(ownCalls(w.0).isEmpty)
        }
    }

    @Test func everyNearChevronCaseIsIdentical() async {
        var rng = SplitMix147(s: 0xBEEF_147)
        let pool = ["a", "b", "c", "d", "e"].map(k)
        var near = 0, bad = 0
        for n in 0..<2600 {
            let g = gen(&rng, pool: pool)
            guard let c = g.chevAt, (0...2).contains(g.withOwn.firstIndex(of: own)! - c) else { continue }
            near += 1
            let w = await sworld(bar: g.withOwn + [clock], rec: g.rec + [clock], staleUntil: g.su, chevAt: c)
            let wo = await sworld(bar: g.withOwn + [clock], rec: g.rec + [clock], staleUntil: g.su, chevAt: c, omitOwn: true)
            if w.0 != wo.0 || !ownCalls(w.0).isEmpty { bad += 1; print("NEAR VIOL case \(n)") }
        }
        print("NEAR SUMMARY near=\(near) violations=\(bad)")
        #expect(near >= 300 && bad == 0)
    }

    @Test func eventGenerator() async {
        var rng = SplitMix147(s: 0x5EED_4147)
        let pool = ["a", "b", "c", "d", "e"].map(k)
        var cases = 0, ownDrags = 0, hides = 0, dup = 0, worse = 0, unrecAtEv = 0, unrecDiff = 0, progressEq = 0
        for n in 0..<3200 {
            let g = gen(&rng, pool: pool)
            let ev = RevEv(rawValue: rng.below(4))!
            var evKey: ItemKey? = nil; var evIdx = 0
            switch ev {
            case .hand: evKey = g.withOwn[rng.below(g.withOwn.count)]; evIdx = rng.below(g.withOwn.count)
            case .drop: evKey = g.rec.isEmpty ? nil : g.rec[rng.below(g.rec.count)]; evIdx = rng.below(g.rec.count + 1)
            default: break
            }
            let with = await rworld(bar: g.withOwn + [clock], rec: g.rec + [clock], staleUntil: g.su, chevAt: g.chevAt, omitOwn: false, ev: ev, evKey: evKey, evIdx: evIdx)
            let without = await rworld(bar: g.withOwn + [clock], rec: g.rec + [clock], staleUntil: g.su, chevAt: g.chevAt, omitOwn: true, ev: ev, evKey: evKey, evIdx: evIdx)
            cases += 1
            let drag = with.0.contains { if case .move(let m, _) = $0 { return m == own }; return false }
            let hid = with.1.hidden.contains(own) || with.1.alwaysHidden.contains(own) || with.0.contains { if case .move = $0 { return false }; return "\($0)".contains("Sommelier") }
            let d = with.1.visible.filter { $0 == own }.count > 1
            func matchLike(_ x: EngineState) -> Bool { switch x.coreDisplay?.status { case .matches?, .matchesExcept?: return true; default: return false } }
            if drag { ownDrags += 1 }; if hid { hides += 1 }; if d { dup += 1 }
            if ev != .drop, matchLike(without.2), !matchLike(with.2) { worse += 1 }
            if with.3 {   // the own key was still unrecorded when the event came: until then both worlds are the same; a hand drag may legitimately record it afterwards
                unrecAtEv += 1
                if with.0 != without.0 && ev != .hand { unrecDiff += 1; if unrecDiff <= 6 { print("EVT DIFF case \(n) ev \(ev): with \(with.0) without \(without.0)") } }
            }
            if with.0 == without.0 { progressEq += 1 }
        }
        print("EVT SUMMARY cases=\(cases) ownDrags=\(ownDrags) hides=\(hides) doubleRecords=\(dup) worse=\(worse) unrecordedAtEvent=\(unrecAtEv) unrecordedDiff=\(unrecDiff) identical=\(progressEq)")
        #expect(cases >= 3000)
        #expect(ownDrags == 0 && hides == 0 && dup == 0 && worse == 0 && unrecDiff == 0)
    }

    /// The reviewer's progress worlds (own folded behind the chevron and unrecorded): the new build made fewer moves than the old one; now equal.
    @Test func foldedUnrecordedOwnMakesTheOldBuildsCalls() async {
        var rng = SplitMix147(s: 0x5EED_4147)
        let pool = ["a", "b", "c", "d", "e"].map(k)
        var checked = 0
        for n in 0..<3200 {
            let g = gen(&rng, pool: pool)
            let ev = RevEv(rawValue: rng.below(4))!
            var evKey: ItemKey? = nil; var evIdx = 0
            switch ev {
            case .hand: evKey = g.withOwn[rng.below(g.withOwn.count)]; evIdx = rng.below(g.withOwn.count)
            case .drop: evKey = g.rec.isEmpty ? nil : g.rec[rng.below(g.rec.count)]; evIdx = rng.below(g.rec.count + 1)
            default: break
            }
            guard n == 2848 || n == 3162 else { continue }
            let w = await rworld(bar: g.withOwn + [clock], rec: g.rec + [clock], staleUntil: g.su, chevAt: g.chevAt, omitOwn: false, ev: ev, evKey: evKey, evIdx: evIdx)
            let wo = await rworld(bar: g.withOwn + [clock], rec: g.rec + [clock], staleUntil: g.su, chevAt: g.chevAt, omitOwn: true, ev: ev, evKey: evKey, evIdx: evIdx)
            checked += 1
            #expect(w.0 == wo.0, "case \(n): with \(w.0) without \(wo.0)")
        }
        #expect(checked == 2)
    }
}
