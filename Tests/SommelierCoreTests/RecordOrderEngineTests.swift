import Testing
import Foundation
@testable import SommelierCore

// 9o9.2: every Visible key is enforced; a legacy (pre-record) layout adopts the bar's order once and moves nothing.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private struct OpenCaps: CapabilityProvider { func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) } }
private final class Sink: @unchecked Sendable {
    private let lock = NSLock(); private var l: [String] = []
    func add(_ s: String) { lock.lock(); l.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return l }
}
private final class CountingStore: LayoutStore, @unchecked Sendable {
    private let lock = NSLock(); private var layout: Layout; private var n = 0
    init(_ l: Layout) { layout = l }
    func load() throws -> Layout { lock.lock(); defer { lock.unlock() }; return layout }
    func save(_ l: Layout) throws { lock.lock(); defer { lock.unlock() }; layout = l; n += 1 }
    var saves: Int { lock.lock(); defer { lock.unlock() }; return n }
}
/// Observes the fake actuator's truth; the subject's position is never corroborated while `bad` is set.
private final class BadJoinObserver: MenuBarObserver, @unchecked Sendable {
    let actuator: FakeActuator; let subject: ItemKey
    init(actuator: FakeActuator, subject: ItemKey) { self.actuator = actuator; self.subject = subject }
    func observe() async throws -> [ResolvedItem] {
        var items = FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden))
        for j in items.indices where items[j].key == subject { items[j].item.joinEvidence = .frameAmbiguous }
        return items
    }
}
/// A settled read whose completeness and stale on-bar key can change between passes.
private final class SteerableObserver: MenuBarObserver, @unchecked Sendable {
    let actuator: FakeActuator
    private let lock = NSLock(); private var _level = ReadCompleteness.complete; private var _stale: ItemKey?
    init(actuator: FakeActuator) { self.actuator = actuator }
    func set(level: ReadCompleteness, stale: ItemKey?) { lock.lock(); _level = level; _stale = stale; lock.unlock() }
    private var stale: ItemKey? { lock.lock(); defer { lock.unlock() }; return _stale }
    private var level: ReadCompleteness { lock.lock(); defer { lock.unlock() }; return _level }
    func observe() async throws -> [ResolvedItem] {
        let st = stale
        var items = FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden))
        for j in items.indices where items[j].key == st { items[j].item.stale = true }
        return items
    }
    func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> BarObservation {
        let items = try await observe()
        return BarObservation(items: items, settled: true, scans: 2, completeness: level)
    }
}
private struct GoodObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] { FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden)) }
}
private struct FrozenObserver: MenuBarObserver {
    let order: [ItemKey]
    func observe() async throws -> [ResolvedItem] { FakeMenuBar.resolve(FakeMenuBar.snapshot(order: order, hidden: [])) }
}
private func waitUntil(_ cond: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<600 { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
    return false
}

private struct R { let engine: LayoutEngine; let state: EngineState; let actuator: FakeActuator; let store: CountingStore; let sink: Sink }

@MainActor
private func rig(order: [String], hidden: Set<ItemKey> = [], layout: Layout, badSubject: ItemKey? = nil, config: LayoutEngine.Config = .plain(), observerFor: (@Sendable (FakeActuator) -> any MenuBarObserver)? = nil) async -> R {
    let act = FakeActuator(order: order.map(k), hidden: hidden, capabilities: OpenCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let store = CountingStore(layout), state = EngineState(), sink = Sink()
    let fallback: any MenuBarObserver = badSubject.map { BadJoinObserver(actuator: act, subject: $0) } ?? GoodObserver(actuator: act)
    let obs: any MenuBarObserver = observerFor?(act) ?? fallback
    let engine = LayoutEngine(observer: obs, actuator: act, store: store, capabilities: OpenCaps(), state: state, busy: { false },
                              resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { sink.add($0) }, config: config)
    await engine.start()
    return R(engine: engine, state: state, actuator: act, store: store, sink: sink)
}

private final class SteerableBox: @unchecked Sendable {
    private var o: SteerableObserver?
    var obs: SteerableObserver { o! }
    func make(_ a: FakeActuator) -> any MenuBarObserver { let x = SteerableObserver(actuator: a); o = x; return x }
}

@MainActor
@Suite struct RecordOrderEngineTests {
    private static let legacyJSON = #"{"schemaVersion":1,"visible":["status:com.x.A::A","status:com.x.C::C","status:com.x.B::B","status:com.x.D::D"],"hidden":[],"newItemPolicy":"visibleAtEnd","orderMode":"macOSOwns","placed":["status:com.x.C::C"]}"#

    @Test func everyVisibleKeyIsEnforced() async {
        let r = await rig(order: ["A", "B", "C", "D"], layout: Layout(visible: ["A", "C", "B", "D"].map(k)))
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .incomplete)   // sommelier-ejb.7, CHANGED: a pass that made a move is `.incomplete`; the core judges the moved bar on the next pass
        #expect(await r.actuator.calls.count == 1)
        #expect(await r.actuator.order == ["A", "C", "B", "D"].map(k))
    }

    @Test func theDefaultIsOneOrderMovePerPassAndTheSecondMoveComesOnAChainedPass() async {
        #expect(LayoutEngine.Config().maxOrderMovesPerPass == 1)
        // direct passes: one move each
        let r = await rig(order: ["A", "B", "C"], layout: Layout(visible: ["C", "B", "A"].map(k)))
        let first = await r.engine.reconcileOnce()
        #expect(first.outcome == .incomplete && first.actionCount == 1)
        #expect(await r.actuator.calls.count == 1)
        let second = await r.engine.reconcileOnce()
        #expect(second.outcome == .incomplete && second.actionCount == 1)   // sommelier-ejb.7, CHANGED: see everyVisibleKeyIsEnforced; the "plan: phase=order" log line is gone
        #expect(await r.actuator.order == ["C", "B", "A"].map(k))
        // one request only: the cap ends the first pass and the engine chains the second by itself
        var c = LayoutEngine.Config.plain(); c.minPassInterval = .zero; c.layoutCoalesce = .zero
        let q = await rig(order: ["A", "B", "C"], layout: Layout(visible: ["C", "B", "A"].map(k)), config: c)
        await q.engine.requestReconcile(reason: "test")
        #expect(await waitUntil { await q.actuator.order == ["C", "B", "A"].map(k) })
        #expect(q.sink.lines.contains { $0.contains("maxOrderMovesPerPass") })
        #expect(await q.actuator.calls.count == 2)
    }

    // A move the actuator verified but the next read still plans is struck, not repeated (default config: one move per pass).
    // ejb.17: the core remembers the last verified engine move and the next usable read that still finds its key misplaced takes a strike for it (given up at the third),
    // as the old engine's `unverifiedStrikes` did: at most 3 drags of that key however many passes follow. (ejb.15 had relaxed this to the budget, 20 on a bar known not full.)
    @Test func aVerifiedMoveThatTheReadStillPlansIsStruckNotRepeated() async {
        let r = await rig(order: ["A", "B", "C"], layout: Layout(visible: ["A", "C", "B"].map(k)),
                          observerFor: { _ in FrozenObserver(order: ["A", "B", "C"].map(k)) })
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == 1)
        _ = await r.engine.reconcileOnce()
        for _ in 0..<30 { _ = await r.engine.reconcileOnce() }
        let settled = await r.actuator.calls.count
        #expect(settled == 3, "drags of the reverted key: \(settled)")   // plain config: bar known not full, so three strikes, not the budget of 20
        for _ in 0..<8 { _ = await r.engine.reconcileOnce() }
        #expect(await r.actuator.calls.count == settled)   // the key is given up: no further drags until the user's intent
    }

    // The same on a bar assumed full (the production default at launch): the strike rule is the same, and the budget of 3 agrees with it.
    @Test func aVerifiedMoveThatTheReadStillPlansIsStruckNotRepeatedOnABarAssumedFull() async {
        var cfg = LayoutEngine.Config.plain(); cfg.assumeFullBarAtLaunch = true
        let r = await rig(order: ["A", "B", "C"], layout: Layout(visible: ["A", "C", "B"].map(k)), config: cfg,
                          observerFor: { _ in FrozenObserver(order: ["A", "B", "C"].map(k)) })
        for _ in 0..<40 { _ = await r.engine.reconcileOnce() }
        let settled = await r.actuator.calls.count
        #expect(settled >= 1 && settled <= 3, "drags of the reverted key on a full bar: \(settled)")
        for _ in 0..<8 { _ = await r.engine.reconcileOnce() }
        #expect(await r.actuator.calls.count == settled)
    }

    // The intent of the old per-minute cap: a key macOS keeps reverting is dragged at most 3 times in all, however many passes run (here 200 passes), and a user's
    // "Try again" on that key gives it exactly one fresh round of at most 3.
    @Test func aKeyMacOSKeepsRevertingIsDraggedAtMostThreeTimesNoMatterHowManyPassesRun() async {
        let r = await rig(order: ["A", "B", "C"], layout: Layout(visible: ["A", "C", "B"].map(k)),
                          observerFor: { _ in FrozenObserver(order: ["A", "B", "C"].map(k)) })
        for _ in 0..<200 { _ = await r.engine.reconcileOnce() }
        let first = await r.actuator.calls.count
        #expect(first <= 3, "drags: \(first)")
        await r.engine.retry(key: k("C"))
        for _ in 0..<200 { _ = await r.engine.reconcileOnce() }
        let second = await r.actuator.calls.count
        #expect(second > first && second <= first + 1 + 3, "after Try again: \(second) (before: \(first))")
    }

    @Test func aLayoutEqualToTheBarDoesNothing() async {
        let r = await rig(order: ["A", "B", "C"], layout: Layout(visible: ["A", "B", "C"].map(k)))
        #expect(await r.engine.reconcileOnce().outcome == .converged)
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func aStaleSubjectIsSkippedAndLogged() async {
        let box = SteerableBox()
        let r = await rig(order: ["B", "A", "C", "D"], layout: Layout(visible: ["A", "C", "D", "B"].map(k)), observerFor: { box.make($0) })
        box.obs.set(level: .complete, stale: k("B"))
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.isEmpty)
        box.obs.set(level: .complete, stale: nil)
        // ejb.15 (Wiring 3), CHANGED because the core decides: ONE move per pass (the first inversion), so the bar reaches the record in three passes
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await r.actuator.order == ["A", "C", "D", "B"].map(k))
    }

    @Test func membershipStillWorks() async {
        let r = await rig(order: ["A", "B", "C"], layout: Layout(visible: ["A", "B"].map(k), hidden: [k("C")]))
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .converged)
        #expect(await r.actuator.hidden == [k("C")])
    }

    @Test func legacyLayoutAdoptsTheBarOrderAndMovesNothing() async throws {
        let decoded = try Layout.decode(Data(Self.legacyJSON.utf8))
        #expect(decoded.adoptBarOrder && decoded.layout.pendingAdoption)
        let r = await rig(order: ["A", "B", "C", "D"], layout: decoded.layout)
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .converged && rep.actionCount == 0)
        #expect(await r.actuator.calls.isEmpty)
        #expect(await r.actuator.order == ["A", "B", "C", "D"].map(k))
        #expect(r.state.layout.visible == ["A", "B", "C", "D"].map(k))
        #expect(!r.state.layout.pendingAdoption)
        #expect(r.sink.lines.contains { $0.contains("layout: adopted bar order on upgrade (4 keys)") })
        let saved = try r.store.load()
        #expect(saved.visible == ["A", "B", "C", "D"].map(k) && !saved.pendingAdoption)
        // a second pass does not adopt again
        _ = await r.engine.reconcileOnce()
        #expect(r.sink.lines.filter { $0.contains("adopted bar order") }.count == 1)
    }

    @Test func adoptionWaitsForACompleteReadAndThenForFreshFramesAndThenAdopts() async throws {
        let decoded = try Layout.decode(Data(Self.legacyJSON.utf8))
        let box = SteerableBox()
        let r = await rig(order: ["A", "B", "C", "D"], layout: decoded.layout, observerFor: { box.make($0) })
        // (a) incomplete read: nothing adopted, nothing moved, flag still set
        box.obs.set(level: .incomplete, stale: nil)
        _ = await r.engine.reconcileOnce()
        #expect(r.state.layout.pendingAdoption && r.state.layout.visible == decoded.layout.visible)
        #expect(await r.actuator.calls.isEmpty)
        #expect(r.sink.lines.contains { $0.contains("layout: adoption waiting:") })
        // (b) complete read with one stale on-bar key: still waiting, logged with the count
        box.obs.set(level: .complete, stale: k("B"))
        _ = await r.engine.reconcileOnce()
        #expect(r.state.layout.pendingAdoption && r.state.layout.visible == decoded.layout.visible)
        #expect(await r.actuator.calls.isEmpty)
        #expect(r.sink.lines.contains { $0.contains("layout: adoption waiting: on-bar frames are not fresh (1 stale frames)") })
        #expect(!r.sink.lines.contains { $0.contains("adopted bar order") })
        // (c) the next clean read adopts
        box.obs.set(level: .complete, stale: nil)
        _ = await r.engine.reconcileOnce()
        #expect(!r.state.layout.pendingAdoption && r.state.layout.visible == ["A", "B", "C", "D"].map(k))
        #expect(await r.actuator.calls.isEmpty)
        #expect(r.sink.lines.filter { $0.contains("adopted bar order") }.count == 1)
    }

    @Test func pendingAdoptionPersistsAcrossARelaunchBeforeItCompletes() throws {
        let decoded = try Layout.decode(Data(Self.legacyJSON.utf8))
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(decoded.layout)
        let again = try Layout.decode(data)
        #expect(again.adoptBarOrder && again.layout.pendingAdoption && again.warnings.isEmpty)
        var done = decoded.layout; done.pendingAdoption = false
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(done)) as? [String: Any]
        #expect(obj?["pendingAdoption"] == nil && obj?["placed"] == nil && obj?["orderMode"] == nil)
        #expect(try Layout.decode(JSONEncoder().encode(done)).adoptBarOrder == false)
    }

    @Test func adoptedVisibleKeepsOffBarKeysAfterTheirPrecedingNeighbour() {
        let (a, b, c, x, y) = (k("A"), k("B"), k("C"), k("X"), k("Y"))
        #expect(LayoutEngine.adoptedVisible([a, x, c, b], bar: [a, b, c]) == [a, x, b, c])
        #expect(LayoutEngine.adoptedVisible([x, a, c, y, b], bar: [a, b, c]) == [x, a, b, c, y])
        #expect(LayoutEngine.adoptedVisible([a, b], bar: [b, a, c]) == [b, a])   // bar keys not in the layout are not invented
    }

    // 9o9.3: a drop while the adoption is pending first adopts the record from the last clean observation, then applies the drop on top.
    @Test func aDropWhileAdoptionIsPendingAdoptsTheBarFirstAndThenAppliesTheDrop() async throws {
        let decoded = try Layout.decode(Data(Self.legacyJSON.utf8))   // legacy record A C B D; the bar is A B C D
        let r = await rig(order: ["A", "B", "C", "D"], layout: decoded.layout)
        await r.engine.setCleanBarForTesting(["A", "B", "C", "D"].map(k))
        // the Arrange window composes the drop (D to the front) on the legacy record
        await r.engine.setLayout(Layout(visible: ["D", "A", "C", "B"].map(k)), moved: [k("D")])
        #expect(!r.state.layout.pendingAdoption)
        #expect(r.state.layout.visible == ["D", "A", "B", "C"].map(k))   // bar order A B C, D dropped first; the legacy C-before-B is not enforced
        #expect(r.sink.lines.contains { $0.contains("adopted bar order before applying the drop") })
    }

    @Test func aDropWhileAdoptionIsPendingWithoutACleanReadIsRefused() async throws {
        let decoded = try Layout.decode(Data(Self.legacyJSON.utf8))
        let r = await rig(order: ["A", "B", "C", "D"], layout: decoded.layout)
        await r.engine.setLayout(Layout(visible: ["D", "A", "C", "B"].map(k)), moved: [k("D")])
        #expect(r.state.layout.pendingAdoption && r.state.layout.visible == decoded.layout.visible)
        #expect(r.sink.lines.contains { $0.contains("setLayout refused") })
        // the Arrange window refuses it up front with the callout text
        #expect(ArrangeDrop.readingOrder == "Reading your menu bar order…")
        #expect(ArrangeDrop.adoptionRefusal(pending: true, cleanObservation: false, current: decoded.layout, proposed: Layout(visible: ["D", "A", "C", "B"].map(k))))
        #expect(!ArrangeDrop.adoptionRefusal(pending: true, cleanObservation: true, current: decoded.layout, proposed: Layout(visible: ["D", "A", "C", "B"].map(k))))
        #expect(!ArrangeDrop.adoptionRefusal(pending: false, cleanObservation: false, current: decoded.layout, proposed: Layout(visible: ["D", "A", "C", "B"].map(k))))
        #expect(!ArrangeDrop.adoptionRefusal(pending: true, cleanObservation: false, current: decoded.layout, proposed: decoded.layout))
        // once a clean read exists the adoption happens by itself and a later drop is an ordinary one
        _ = await r.engine.reconcileOnce()
        #expect(!r.state.layout.pendingAdoption)
    }

    @Test func applyingADropKeepsTheAdoptedOrderOfUnmovedKeys() {
        let (a, b, c, d) = (k("A"), k("B"), k("C"), k("D"))
        #expect(LayoutEngine.applyingDrop(to: [a, b, c, d], requested: [d, a, c, b], moved: [d]) == [d, a, b, c])
        #expect(LayoutEngine.applyingDrop(to: [a, b, c, d], requested: [a, c, b, d], moved: [c]) == [a, c, b, d])
        #expect(LayoutEngine.applyingDrop(to: [a, b, c], requested: [a, c], moved: []) == [a, c])   // a removed key goes
    }
}
