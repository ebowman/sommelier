import Testing
import Foundation
@testable import SommelierCore

// 9o9.7: a hand Command-drag in the menu bar is adopted into the record; any other bar change is enforced against.

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
    var saved: Layout { lock.lock(); defer { lock.unlock() }; return layout }
}
private struct GoodObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] { FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden)) }
}
/// Observer whose read quality the test switches: a clean read, a complete-but-not-fresh one (one stale on-bar frame), or no agreement.
private final class ModeObserver: MenuBarObserver, @unchecked Sendable {
    enum Mode { case good, staleComplete(ItemKey), unsettled
        /// A read at `level` whose `stale` keys carry an old frame (stale + uncorroborated); the rest are fresh.
        case carried(Set<ItemKey>, ReadCompleteness)
        /// A complete read whose listed keys are FRESH but uncorroborated (frameAmbiguous), each reporting the frame of the given slot index.
        case ambiguous([ItemKey: Int]) }
    private let lock = NSLock(); private var m: Mode = .good
    let actuator: FakeActuator
    init(_ a: FakeActuator) { actuator = a }
    var mode: Mode { get { lock.lock(); defer { lock.unlock() }; return m } set { lock.lock(); m = newValue; lock.unlock() } }
    func observe() async throws -> [ResolvedItem] { try await observeDetailed(progress: nil).items }
    func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> BarObservation {
        var items = FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden))
        switch mode {
        case .good: break
        case .staleComplete(let key):
            for i in items.indices where items[i].key == key {
                items[i].item.stale = true
                if items[i].item.isOnMenuBar, let idx = names.map(k).firstIndex(of: key) { items[i].item.frame.origin.x = 100 + CGFloat(idx) * 30 - 1 }   // carried: its old slot
            }
        case .unsettled: throw ObserveError.noAgreement(scans: 2)
        case .ambiguous(let slots):
            for i in items.indices { if let idx = slots[items[i].key], items[i].item.isOnMenuBar {
                items[i].item.frame.origin.x = 100 + CGFloat(idx) * 30 - 1
                items[i].item.joinEvidence = .frameAmbiguous
            } }
            return BarObservation(items: items, settled: true, scans: 2, completeness: .complete)
        case .carried(let keys, let level):
            // A carried frame is the key's LAST real position: its slot in the pre-drag order (a hair left of that slot's occupant).
            let pre = names.map(k)
            for i in items.indices where keys.contains(items[i].key) {
                items[i].item.stale = true
                if items[i].item.isOnMenuBar, let idx = pre.firstIndex(of: items[i].key) { items[i].item.frame.origin.x = 100 + CGFloat(idx) * 30 - 1 }
            }
            return BarObservation(items: items, settled: true, scans: 2, completeness: level)
        }
        return BarObservation(items: items, settled: true, scans: 2, completeness: .complete)
    }
}
/// Decorator that runs a hook in the gap between the interaction gate and the actuator call (the engine hands the churn zone over there).
private final class GapActuator: MenuBarActuator, @unchecked Sendable {
    let inner: FakeActuator
    private let lock = NSLock(); private var hook: (@Sendable () -> Void)?
    init(_ i: FakeActuator) { inner = i }
    func setGapHook(_ h: (@Sendable () -> Void)?) { lock.lock(); hook = h; lock.unlock() }
    func move(_ key: ItemKey, relation: Relation) async -> ActuationResult { await inner.move(key, relation: relation) }
    func setHidden(_ key: ItemKey, _ hidden: Bool) async -> ActuationResult { await inner.setHidden(key, hidden) }
    func applyHiddenBatch(_ changes: [ItemKey: Bool]) async -> ActuationResult { await inner.applyHiddenBatch(changes) }
    var lastBatchRespawned: Bool { get async { await inner.lastBatchRespawned } }
    var lastBatchUnconfirmed: Set<ItemKey> { get async { await inner.lastBatchUnconfirmed } }
    var lastBatchRefused: [ItemKey: String] { get async { await inner.lastBatchRefused } }
    var lastBatchUnsettled: [ItemKey: String] { get async { await inner.lastBatchUnsettled } }
    private func takeHook() -> (@Sendable () -> Void)? { lock.lock(); defer { lock.unlock() }; return hook }
    func setChurnZone(_ keys: Set<ItemKey>) async {
        takeHook()?()
        await inner.setChurnZone(keys)
    }
}
private final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var t = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}
private final class FakeHandDrags: HandDragMonitor, @unchecked Sendable {
    private let lock = NSLock(); private var h: (@Sendable (HandDragEvent) -> Void)?
    func start(_ handler: @escaping @Sendable (HandDragEvent) -> Void) { lock.lock(); h = handler; lock.unlock() }
    func stop() { lock.lock(); h = nil; lock.unlock() }
    func fire(_ e: HandDragEvent) { lock.lock(); let f = h; lock.unlock(); f?(e) }
}
private final class NoWake: WakeSignalSource { func start(_ handler: @escaping @Sendable () -> Void) {}; func stop() {} }
private func waitUntil(_ cond: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<600 { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
    return false
}

private struct R {
    let engine: LayoutEngine; let state: EngineState; let actuator: FakeActuator; let sink: Sink; let store: MemStore; let drags: FakeHandDrags
    let observer: ModeObserver; let gap: GapActuator
    func layoutVisible() async -> [ItemKey] { await MainActor.run { state.layout.visible } }
}

@MainActor
private func rig(order: [String], layout: Layout, modes: Bool = false, gap: Bool = false,
                 configure: (inout LayoutEngine.Config) -> Void = { _ in }) async -> R {
    let act = FakeActuator(order: order.map(k), capabilities: OpenCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let store = MemStore(layout), state = EngineState(), sink = Sink(), drags = FakeHandDrags()
    var c = LayoutEngine.Config()
    c.maxOrderMovesPerPass = .max
    c.minPassInterval = .zero
    c.layoutCoalesce = .zero
    c.interactionRetry = .seconds(3600)
    configure(&c)
    let modeObs = ModeObserver(act), gapAct = GapActuator(act)
    let engine = LayoutEngine(observer: modes ? modeObs : GoodObserver(actuator: act), actuator: gap ? gapAct : act, store: store, capabilities: OpenCaps(), state: state,
                              busy: { false }, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { sink.add($0) }, config: c)
    await engine.start()
    drags.start { engine.handDragEvent($0) }
    return R(engine: engine, state: state, actuator: act, sink: sink, store: store, drags: drags, observer: modeObs, gap: gapAct)
}

private let names = ["A", "B", "C", "D", "E"]
private func abcde() -> Layout { Layout(visible: names.map(k)) }

@MainActor
@Suite struct HandDragTests {
    @Test func defaultWaitIsTenSeconds() {
        #expect(LayoutEngine.Config().handDragAdoptWait == .seconds(10))
    }

    // MARK: detection rule

    @Test func ruleNeedsCommandAndAPointInsideAMenuBarRect() {
        let rects = HandDragRule.menuBarRects(screens: [(CGRect(x: 0, y: 0, width: 1000, height: 800), 0)], thickness: 24)
        #expect(rects == [CGRect(x: 0, y: 776, width: 1000, height: 24)])
        #expect(HandDragRule.isHandDragStart(commandHeld: true, point: CGPoint(x: 500, y: 790), rects: rects))
        #expect(HandDragRule.isHandDragStart(commandHeld: true, point: CGPoint(x: 0, y: 800), rects: rects))   // the very top row
        #expect(!HandDragRule.isHandDragStart(commandHeld: false, point: CGPoint(x: 500, y: 790), rects: rects))
        #expect(!HandDragRule.isHandDragStart(commandHeld: true, point: CGPoint(x: 500, y: 700), rects: rects))
        #expect(!HandDragRule.isHandDragStart(commandHeld: true, point: CGPoint(x: 1200, y: 790), rects: rects))
    }

    @Test func ruleCoversEveryScreenAndTheNotchHeight() {
        let rects = HandDragRule.menuBarRects(screens: [(CGRect(x: 0, y: 0, width: 1000, height: 800), 37),
                                                        (CGRect(x: 1000, y: -200, width: 1200, height: 1000), 0)], thickness: 24)
        #expect(rects[0].height == 37 && rects[1].height == 24 && rects[1].minY == 776)
        #expect(HandDragRule.isHandDragStart(commandHeld: true, point: CGPoint(x: 100, y: 770), rects: rects))
        #expect(HandDragRule.isHandDragStart(commandHeld: true, point: CGPoint(x: 1500, y: 790), rects: rects))
    }

    // MARK: engine

    @Test func noMovesWhileTheDragLasts() async {
        let r = await rig(order: names, layout: abcde())
        await r.actuator.displace(k("A"), toIndex: 4)
        r.drags.fire(.began)
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .paused)
        #expect(await r.actuator.calls.isEmpty)
        #expect(r.state.pauseReason == "you are dragging in the menu bar")
        #expect(r.sink.lines.contains("engine: paused: you are dragging in the menu bar"))
    }

    @Test func theResultingOrderIsAdoptedAfterTheDrag() async {
        let r = await rig(order: names, layout: abcde())
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 4)   // the user's drag
        r.drags.fire(.ended)
        #expect(await waitUntil { await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k) })
        _ = await r.engine.reconcileOnce()
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.isEmpty)                         // never undone
        #expect(await r.actuator.order == ["B", "C", "D", "E", "A"].map(k))
        #expect(r.store.saved.visible == ["B", "C", "D", "E", "A"].map(k))
        #expect(r.state.pauseReason == nil)
    }

    @Test func logLineAndNotice() async {
        let r = await rig(order: names, layout: abcde())
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 4)
        r.drags.fire(.ended)
        #expect(await waitUntil { await MainActor.run { r.state.handDragNotice != nil } })
        #expect(r.state.handDragNotice == "Adopted your menu bar drag")
        let line = r.sink.lines.first { $0.hasPrefix("layout: adopted your menu bar drag: ") }
        #expect(line != nil && line!.contains(" now after "))
    }

    @Test func aMoveToTheLeftEndReadsNowFirst() async {
        let r = await rig(order: names, layout: abcde())
        r.drags.fire(.began)
        await r.actuator.displace(k("E"), toIndex: 0)
        r.drags.fire(.ended)
        #expect(await waitUntil { await r.layoutVisible() == ["E", "A", "B", "C", "D"].map(k) })
        #expect(r.sink.lines.contains { $0.hasPrefix("layout: adopted your menu bar drag: ") && $0.hasSuffix(" now first") })
    }

    @Test func withoutAHandDragAChangedOrderIsEnforced() async {
        let r = await rig(order: names, layout: abcde())
        await r.actuator.displace(k("A"), toIndex: 4)   // macOS's doing
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == 1)
        #expect(await r.actuator.order == names.map(k))
        #expect(r.state.layout.visible == names.map(k))
        #expect(r.state.handDragNotice == nil)
        #expect(!r.sink.lines.contains { $0.contains("adopted your menu bar drag") })
    }

    @Test func aSyntheticDragOfOursIsNotAHandDrag() async {
        let r = await rig(order: names, layout: abcde())
        let drags = r.drags
        // The actuator's own Command-drag shows up in the global monitor while its call is in flight.
        await r.actuator.setAfterCall { _ in drags.fire(.began); drags.fire(.ended) }
        await r.actuator.displace(k("A"), toIndex: 4)
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == 1)
        #expect(r.state.layout.visible == names.map(k))
        #expect(!r.sink.lines.contains { $0.contains("you started dragging") || $0.contains("adopted your menu bar drag") })
        // and nothing is left pending or paused
        await r.actuator.setAfterCall(nil)
        await r.actuator.displace(k("C"), toIndex: 0)
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == 2)
        #expect(await r.actuator.order == names.map(k))
    }

    @Test func aMoveBeforeTheDragDoesNotBlockItsAdoption() async {
        let r = await rig(order: names, layout: abcde())
        await r.actuator.displace(k("C"), toIndex: 0)
        _ = await r.engine.reconcileOnce()                         // our own move, finished
        #expect(await r.actuator.calls.count == 1)
        r.drags.fire(.began)
        await r.actuator.displace(k("B"), toIndex: 4)
        r.drags.fire(.ended)
        #expect(await waitUntil { await r.layoutVisible() == ["A", "C", "D", "E", "B"].map(k) })
    }

    @Test func offBarKeysKeepTheirRelativePosition() async {
        let layout = Layout(visible: ["A", "B", "X", "C", "D"].map(k))   // X is not on the bar
        let r = await rig(order: ["A", "B", "C", "D"], layout: layout)
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 3)
        r.drags.fire(.ended)
        #expect(await waitUntil { await r.layoutVisible() == ["B", "X", "C", "D", "A"].map(k) })
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func anUnsettledWaitNeverEndsInEnforcingTheOldRecordSilently() async {
        // A zero wait: the deadline has passed, no clean read ever comes. The engine keeps waiting; the old record is never enforced.
        let clock = Clock()
        let r = await rig(order: names, layout: abcde(), modes: true, configure: { $0.handDragAdoptWait = .zero; $0.now = { clock.now } })
        r.observer.mode = .unsettled
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 4)
        r.drags.fire(.ended)
        #expect(await waitUntil { r.sink.lines.contains("hand drag: still waiting for a clean read") })
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await r.actuator.calls.isEmpty)
        #expect(await r.actuator.order == ["B", "C", "D", "E", "A"].map(k))
        #expect(r.state.layout.visible == names.map(k))
        #expect(!r.sink.lines.contains { $0.contains("order: moving") })
        #expect(r.sink.lines.filter { $0 == "hand drag: still waiting for a clean read" }.count == 1)   // at most once a minute
        // a clean read finally arrives: the drag is adopted, still nothing was undone
        r.observer.mode = .good
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k) })
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func theBarsNormalReadLevelIsAdoptedOnTheFirstPassAndAPendingHideRunsNext() async {
        let clock = Clock()
        let layout = Layout(visible: ["A", "B", "C", "D"].map(k), hidden: [k("E")])
        let r = await rig(order: names, layout: layout, modes: true, configure: { $0.now = { clock.now } })
        r.observer.mode = .carried([], .completeExceptSelfPositioning)
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 3)   // bar: B C D A E
        r.drags.fire(.ended)
        #expect(await waitUntil { await r.layoutVisible() == ["B", "C", "D", "A"].map(k) })
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await r.actuator.hidden.contains(k("E")) })
        #expect(await !r.actuator.calls.contains { if case .move = $0 { return true }; return false })
        #expect(await r.layoutVisible() == ["B", "C", "D", "A"].map(k))
        #expect(await r.actuator.order == ["B", "C", "D", "A", "E"].map(k))   // no order move undid the drag
    }

    @Test func aStaleDraggedKeyIsNotAdoptedAsUnchangedBeforeTheDeadlineThenReadLate() async {
        let clock = Clock()
        let r = await rig(order: names, layout: abcde(), modes: true, configure: { $0.now = { clock.now } })
        r.observer.mode = .carried([k("A")], .completeExceptSelfPositioning)   // A's frame is carried at its old slot
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 4)
        r.drags.fire(.ended)
        #expect(await waitUntil { r.sink.lines.contains { $0.hasPrefix("layout: hand drag adoption waiting") } })
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(r.state.layout.visible == names.map(k))                         // not adopted as unchanged
        #expect(!r.sink.lines.contains { $0.contains("left the order unchanged") })
        clock.advance(11)
        _ = await r.engine.reconcileOnce()
        #expect(r.sink.lines.contains("hand drag: left the order unchanged as far as Sommelier can see; 1 item(s) still unread"))
        #expect(await r.actuator.calls.isEmpty)
        // iStat finally answers: A's fresh frame is at the end
        r.observer.mode = .good
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k) })
        #expect(r.sink.lines.contains("layout: adopted your menu bar drag of \(k("A")) (read late)"))
        #expect(await r.actuator.calls.isEmpty)
        #expect(await r.actuator.order == ["B", "C", "D", "E", "A"].map(k))
    }

    @Test func unverifiedEntriesNeverExpireAndAreClearedBySetLayout() async {
        let clock = Clock()
        let r = await rig(order: names, layout: abcde(), modes: true, configure: { $0.now = { clock.now } })
        r.observer.mode = .carried([k("A")], .completeExceptSelfPositioning)
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 4)
        r.drags.fire(.ended)
        #expect(await waitUntil { r.sink.lines.contains { $0.hasPrefix("layout: hand drag adoption waiting") } })
        clock.advance(11)
        _ = await r.engine.reconcileOnce()
        #expect(r.sink.lines.contains { $0.contains("still unread") })
        clock.advance(100_000)                               // no expiry
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.isEmpty)
        // the user changes the record from Arrange: the unread drag is superseded
        _ = await r.engine.setLayout(Layout(visible: ["B", "A", "C", "D", "E"].map(k)), userPlacement: true, moved: [k("A")])
        r.observer.mode = .good
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(!r.sink.lines.contains { $0.contains("(read late)") })
        #expect(await r.layoutVisible() == ["B", "A", "C", "D", "E"].map(k))
    }

    @Test func staleKeysAreAdoptedAtTheirObservedSlot() async {
        let r = await rig(order: names, layout: abcde(), modes: true)
        r.observer.mode = .carried([k("C")], .completeExceptSelfPositioning)
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 4)   // bar: B C D E A, C carried
        r.drags.fire(.ended)
        #expect(await waitUntil { await r.layoutVisible().last == k("A") })
        #expect(await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k))
        #expect(!r.sink.lines.contains { $0.contains("kept in place") || $0.contains("not adopted") })
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func aFreshDragPastACarriedKeyDoesNotAttachTheStaleKeyToItsRecordPredecessor() async {
        // record A B C D E, C carried at its true slot; the user drags fresh B to the end: A C D E B.
        let r = await rig(order: names, layout: abcde(), modes: true)
        r.observer.mode = .carried([k("C")], .completeExceptSelfPositioning)
        r.drags.fire(.began)
        await r.actuator.displace(k("B"), toIndex: 4)
        r.drags.fire(.ended)
        #expect(await waitUntil { await r.layoutVisible() == ["A", "C", "D", "E", "B"].map(k) })
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(await r.layoutVisible() == ["A", "C", "D", "E", "B"].map(k))
        #expect(await r.actuator.calls.isEmpty)
        #expect(await r.actuator.order == ["A", "C", "D", "E", "B"].map(k))
        #expect(!r.sink.lines.contains { $0.contains("not trusted") || $0.contains("not adopted") })
    }

    @Test func aLateReadPlacesTheKeyRelativeToStaleNeighboursToo() async {
        // A and E stale at the deadline; the bar is B C D E A. Only A is read fresh first: it must land after E (stale), not after D.
        let clock = Clock()
        let r = await rig(order: names, layout: abcde(), modes: true, configure: { $0.now = { clock.now } })
        r.observer.mode = .carried([k("A"), k("E")], .completeExceptSelfPositioning)
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 4)
        r.drags.fire(.ended)
        #expect(await waitUntil { r.sink.lines.contains { $0.hasPrefix("layout: hand drag adoption waiting") } })
        clock.advance(11)
        _ = await r.engine.reconcileOnce()
        r.observer.mode = .carried([k("E")], .completeExceptSelfPositioning)   // A is fresh now, E still carried
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k) })
        r.observer.mode = .good                                                // E leaves the stale set
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k))
        #expect(await r.actuator.calls.isEmpty)
        #expect(await r.actuator.order == ["B", "C", "D", "E", "A"].map(k))
    }

    /// Drags A to the end with A carried until the deadline passes, leaving A unverified (record unchanged).
    private func unverifiedA(_ clock: Clock, hide: Bool = false, positionWait: Duration? = nil) async -> R {
        let r = await rig(order: names, layout: abcde(), modes: true, configure: { $0.now = { clock.now }; if let w = positionWait { $0.positionWaitTimeout = w } })
        r.observer.mode = .carried([k("A")], .completeExceptSelfPositioning)
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 4)
        r.drags.fire(.ended)
        _ = await waitUntil { r.sink.lines.contains { $0.hasPrefix("layout: hand drag adoption waiting") } }
        clock.advance(11)
        _ = await r.engine.reconcileOnce()
        return r
    }

    @Test func anAmbiguousReadAtTheOldSlotNeitherPlacesNorClearsAnUnverifiedKey() async {
        let clock = Clock()
        let r = await unverifiedA(clock)
        #expect(r.sink.lines.contains { $0.contains("still unread") })
        r.observer.mode = .ambiguous([k("A"): 0])       // fresh but frameAmbiguous, at its OLD slot
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(r.state.layout.visible == names.map(k))
        #expect(!r.sink.lines.contains { $0.contains("(read late)") })
        #expect(await r.actuator.calls.isEmpty)
        r.observer.mode = .good                          // corroborated at the new slot
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k) })
        #expect(r.sink.lines.contains("layout: adopted your menu bar drag of \(k("A")) (read late)"))
        #expect(await !r.actuator.calls.contains { if case .move = $0 { return true }; return false })
    }

    // 9o9.24: a hand-dragged key unread past the position-wait timeout stays held (hourglass), never the "could not corroborate" warning.
    @Test func anUnreadHandDraggedKeyNeverTimesOutToTheUncorroboratedWarning() async {
        let clock = Clock()
        let r = await unverifiedA(clock, positionWait: .milliseconds(30))
        #expect(await waitUntil { await MainActor.run { r.state.unverifiedAfterHandDrag == [k("A")] } })
        r.observer.mode = .ambiguous([k("A"): 0])
        for _ in 0..<6 { _ = await r.engine.reconcileOnce(); try? await Task.sleep(for: .milliseconds(20)) }
        let st = await MainActor.run { r.state.perItem[k("A")] }
        if case .unsupported? = st { Issue.record("A became unsupported: \(String(describing: st))") }
        #expect(await MainActor.run { r.state.unverifiedAfterHandDrag == [k("A")] })
        #expect(await r.engine.positionWaitInfo.timedOut == 0)
    }

    // 9o9.5: the engine publishes the unread hand-dragged keys so Arrange can say so (never a check for them).
    @Test func unverifiedHandDraggedKeysArePublishedToTheStateAndClearedWhenRead() async {
        let clock = Clock()
        let r = await unverifiedA(clock)
        #expect(await waitUntil { await MainActor.run { r.state.unverifiedAfterHandDrag == [k("A")] } })
        r.observer.mode = .good                          // corroborated at the new slot
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await MainActor.run { r.state.unverifiedAfterHandDrag.isEmpty } })
        #expect(await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k))
    }

    @Test func settingTheLayoutFromArrangeClearsThePublishedUnverifiedKey() async {
        let clock = Clock()
        let r = await unverifiedA(clock)
        #expect(await waitUntil { await MainActor.run { r.state.unverifiedAfterHandDrag == [k("A")] } })
        _ = await r.engine.setLayout(Layout(visible: ["B", "A", "C", "D", "E"].map(k)), userPlacement: true, moved: [k("A")])
        #expect(await waitUntil { await MainActor.run { r.state.unverifiedAfterHandDrag.isEmpty } })
    }

    @Test func anAmbiguousReadAtTheWrongSlotIsNotPlaced() async {
        let clock = Clock()
        let r = await unverifiedA(clock)
        r.observer.mode = .ambiguous([k("A"): 2])       // between B and C: wrong
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(r.state.layout.visible == names.map(k))
        #expect(!r.sink.lines.contains { $0.contains("(read late)") })
        r.observer.mode = .good
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k) })
        #expect(await !r.actuator.calls.contains { if case .move = $0 { return true }; return false })
    }

    @Test func twoAmbiguousKeysWithSwappedLabelsKeepTheirRecordOrderThroughADrag() async {
        let r = await rig(order: names, layout: abcde(), modes: true)
        r.observer.mode = .ambiguous([k("C"): 2, k("D"): 1])   // C and D read at each other's slots
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 4)   // bar B C D E A
        r.drags.fire(.ended)
        #expect(await waitUntil { await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k) })
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k))
        r.observer.mode = .good                          // corroborated now
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k))
        #expect(await r.actuator.calls.isEmpty)
        #expect(await r.actuator.order == ["B", "C", "D", "E", "A"].map(k))
    }

    @Test func hidingAnUnrelatedItemFromArrangeKeepsAnUnreadDragUnverified() async {
        let clock = Clock()
        let r = await unverifiedA(clock)
        _ = await r.engine.setLayout(Layout(visible: ["A", "B", "C", "D"].map(k), hidden: [k("E")]), userPlacement: true, moved: [k("E")])
        r.observer.mode = .good                          // A is read fresh and corroborated at the new slot
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await r.layoutVisible() == ["B", "C", "D", "A"].map(k) })
        #expect(r.sink.lines.contains("layout: adopted your menu bar drag of \(k("A")) (read late)"))
        #expect(await !r.actuator.calls.contains { if case .move = $0 { return true }; return false })
    }

    private func noMoves(_ r: R) async -> Bool { await !r.actuator.calls.contains { if case .move = $0 { return true }; return false } }

    @Test func aLateReadBesideAnAmbiguousKeyWaitsInsteadOfPlacing() async {
        // A dragged between C and D (bar B C A D E), unverified past the deadline; then A is fresh while C is ambiguous at its true slot.
        let clock = Clock()
        let r = await rig(order: names, layout: abcde(), modes: true, configure: { $0.now = { clock.now } })
        r.observer.mode = .carried([k("A")], .completeExceptSelfPositioning)
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 2)
        r.drags.fire(.ended)
        #expect(await waitUntil { r.sink.lines.contains { $0.hasPrefix("layout: hand drag adoption waiting") } })
        clock.advance(11)
        _ = await r.engine.reconcileOnce()
        r.observer.mode = .ambiguous([k("C"): 1])
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await r.layoutVisible() == names.map(k))
        #expect(!r.sink.lines.contains { $0.contains("(read late)") })
        #expect(await noMoves(r))
        r.observer.mode = .good
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await r.layoutVisible() == ["B", "C", "A", "D", "E"].map(k) })
        #expect(await noMoves(r))
    }

    // MARK: 9o9.18 persistence across relaunch

    @Test func theHandDragMarkersRoundTripAndAreAbsentWhileUnset() throws {
        let enc = JSONEncoder()
        let plain = String(decoding: try enc.encode(abcde()), as: UTF8.self)
        #expect(!plain.contains("pendingHandDrag") && !plain.contains("unreadAfterHandDrag"))
        let when = Date(timeIntervalSince1970: 1_234_567.25)
        let l = Layout(visible: names.map(k), pendingHandDrag: when, unreadAfterHandDrag: [k("A"), k("C")])
        let data = try enc.encode(l)
        #expect(String(decoding: data, as: UTF8.self).contains("pendingHandDrag"))
        let back = try Layout.decode(data).layout
        #expect(back.pendingHandDrag == when)
        #expect(back.unreadAfterHandDrag == [k("A"), k("C")])
        #expect(try JSONDecoder().decode(Layout.self, from: data) == l)
    }

    @Test func aRelaunchDuringTheAdoptionWaitAdoptsTheDragInsteadOfEnforcingTheOldRecord() async {
        let clock = Clock()
        var l = abcde(); l.pendingHandDrag = clock.now.addingTimeInterval(-5)
        let r = await rig(order: ["B", "C", "D", "E", "A"], layout: l, configure: { $0.now = { clock.now } })
        #expect(r.sink.lines.contains { $0.hasPrefix("hand drag: resumed adoption after relaunch (age 5s)") })
        _ = await r.engine.reconcileOnce()
        #expect(await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k))
        #expect(await r.actuator.calls.isEmpty)
        #expect(r.store.saved.pendingHandDrag == nil)
        #expect(r.store.saved.visible == ["B", "C", "D", "E", "A"].map(k))
    }

    @Test func aStaleHandDragMarkerStillAdoptsTheFirstAdoptableReadAndNeverEnforces() async {
        let clock = Clock()
        var l = abcde(); l.pendingHandDrag = clock.now.addingTimeInterval(-3600)
        let r = await rig(order: ["B", "C", "D", "E", "A"], layout: l, configure: { $0.now = { clock.now } })
        #expect(r.sink.lines.contains { $0.hasPrefix("hand drag: resumed adoption after relaunch (age 3600s)") })
        _ = await r.engine.reconcileOnce()
        #expect(await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k))
        #expect(await r.actuator.calls.isEmpty)
        #expect(r.store.saved.pendingHandDrag == nil)
    }

    @Test func theMarkerIsSavedAtMouseUpAndClearedByTheAdoption() async {
        let r = await rig(order: names, layout: abcde(), modes: true)
        r.observer.mode = .unsettled
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 4)
        r.drags.fire(.ended)
        #expect(await waitUntil { r.store.saved.pendingHandDrag != nil })
        #expect(r.store.saved.visible == names.map(k))
        r.observer.mode = .good
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return r.store.saved.visible == ["B", "C", "D", "E", "A"].map(k) })
        #expect(r.store.saved.pendingHandDrag == nil)
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func theMarkerIsClearedByTheDeadlineUnchangedAdoption() async {
        let clock = Clock()
        let r = await rig(order: names, layout: abcde(), modes: true, configure: { $0.now = { clock.now } })
        r.observer.mode = .staleComplete(k("A"))
        r.drags.fire(.began)
        r.drags.fire(.ended)
        #expect(await waitUntil { r.store.saved.pendingHandDrag != nil })
        clock.advance(11)
        _ = await r.engine.reconcileOnce()
        #expect(await waitUntil { r.store.saved.pendingHandDrag == nil })
    }

    @Test func unreadKeysArePersistedAndARelaunchDoesNotEnforceTheRecordAgainstThem() async {
        let clock = Clock()
        let r = await rig(order: names, layout: abcde(), modes: true, configure: { $0.now = { clock.now } })
        r.observer.mode = .carried([k("A")], .completeExceptSelfPositioning)
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 4)
        r.drags.fire(.ended)
        #expect(await waitUntil { r.sink.lines.contains { $0.hasPrefix("layout: hand drag adoption waiting") } })
        clock.advance(11)
        _ = await r.engine.reconcileOnce()
        #expect(r.sink.lines.contains { $0.contains("still unread") })
        #expect(await waitUntil { r.store.saved.unreadAfterHandDrag == [k("A")] })
        #expect(r.store.saved.pendingHandDrag == nil)
        // relaunch: a second engine over the saved layout and the same bar, A still unread
        let r2 = await rig(order: ["B", "C", "D", "E", "A"], layout: r.store.saved, modes: true, configure: { $0.now = { clock.now } })
        r2.observer.mode = .carried([k("A")], .completeExceptSelfPositioning)
        for _ in 0..<4 { _ = await r2.engine.reconcileOnce() }
        #expect(await r2.actuator.calls.isEmpty)
        r2.observer.mode = .good
        #expect(await waitUntil { _ = await r2.engine.reconcileOnce(); return await r2.layoutVisible() == ["B", "C", "D", "E", "A"].map(k) })
        #expect(await r2.actuator.calls.isEmpty)
        #expect(r2.store.saved.unreadAfterHandDrag.isEmpty)
    }

    // MARK: 9o9.18 held-back keys

    @Test func aLateKeyWaitsWhenAnAmbiguousKeyOfItsRecordSlotIsMisreadAtADistantSlot() async {
        // A dragged between C and D (true bar B C A D E), unverified past the deadline; then C reads ambiguous at a DISTANT slot.
        let clock = Clock()
        let r = await rig(order: names, layout: abcde(), modes: true, configure: { $0.now = { clock.now } })
        r.observer.mode = .carried([k("A")], .completeExceptSelfPositioning)
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 2)
        r.drags.fire(.ended)
        #expect(await waitUntil { r.sink.lines.contains { $0.hasPrefix("layout: hand drag adoption waiting") } })
        clock.advance(11)
        _ = await r.engine.reconcileOnce()
        // record is A B C D E; the late read misplaces C at slot 3 (between D and E), not beside A
        r.observer.mode = .ambiguous([k("C"): 3])
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await r.layoutVisible() == names.map(k))
        #expect(!r.sink.lines.contains { $0.contains("(read late)") })
        #expect(await noMoves(r))
        r.observer.mode = .good
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await r.layoutVisible() == ["B", "C", "A", "D", "E"].map(k) })
        #expect(await noMoves(r))
    }

    private func twoMoves(_ build: @escaping @Sendable (FakeActuator) async -> Void, bar: [String], cSlot: Int) async {
        let clock = Clock()
        let r = await rig(order: names, layout: abcde(), modes: true, configure: { $0.now = { clock.now } })
        r.observer.mode = .ambiguous([k("C"): cSlot])
        r.drags.fire(.began)
        await build(r.actuator)
        r.drags.fire(.ended)
        #expect(await waitUntil { await r.layoutVisible() != names.map(k) })
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await r.actuator.order == bar.map(k))
        #expect(await noMoves(r))
        let held = await r.layoutVisible()
        #expect(held.first == k(bar[0]))                       // the held-back key is never put at the front
        r.observer.mode = .good
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await r.layoutVisible() == bar.map(k) })
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(await r.layoutVisible() == bar.map(k))
        #expect(await noMoves(r))
        #expect(await r.state.unverifiedAfterHandDrag.isEmpty)
    }

    @Test func twoMovesBeforeOneAdoptableReadPlaceTheAmbiguousKeyOnlyAfterACleanRead() async {
        await twoMoves({ a in await a.displace(k("B"), toIndex: 4); await a.displace(k("D"), toIndex: 0) }, bar: ["D", "A", "C", "E", "B"], cSlot: 2)
    }

    /// 9o9.26: the same two-move drags with C (ambiguous) misread at ANY slot: nothing planned while C is ambiguous, the user's bar is the record after a clean read.
    private func twoMovesMisread(_ build: @escaping @Sendable (FakeActuator) async -> Void, bar: [String], cSlot: Int) async {
        let clock = Clock()
        let r = await rig(order: names, layout: abcde(), modes: true, configure: { $0.now = { clock.now } })
        r.observer.mode = .ambiguous([k("C"): cSlot])
        r.drags.fire(.began)
        await build(r.actuator)
        r.drags.fire(.ended)
        #expect(await waitUntil { await r.layoutVisible() != names.map(k) })
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await r.actuator.order == bar.map(k), "slot \(cSlot)")
        #expect(await noMoves(r), "slot \(cSlot)")
        r.observer.mode = .good
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await r.layoutVisible() == bar.map(k) }, "slot \(cSlot)")
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(await r.layoutVisible() == bar.map(k), "slot \(cSlot)")
        #expect(await noMoves(r), "slot \(cSlot)")
        #expect(await r.state.unverifiedAfterHandDrag.isEmpty, "slot \(cSlot)")
    }

    @Test func theSwapWithTheAmbiguousKeyMisreadAtEverySlotPlansNothingAndEndsCorrect() async {
        for slot in 0..<5 {
            await twoMovesMisread({ a in await a.displace(k("D"), toIndex: 1); await a.displace(k("B"), toIndex: 3) }, bar: ["A", "D", "C", "B", "E"], cSlot: slot)
        }
    }

    @Test func theDACEBShapeWithTheAmbiguousKeyMisreadAtEverySlotPlansNothingAndEndsCorrect() async {
        for slot in 0..<5 {
            await twoMovesMisread({ a in await a.displace(k("B"), toIndex: 4); await a.displace(k("D"), toIndex: 0) }, bar: ["D", "A", "C", "E", "B"], cSlot: slot)
        }
    }

    // MARK: 9o9.26 an Arrange drop during the adoption wait

    private func movesOf(_ r: R, _ key: String) async -> Int {
        await r.actuator.calls.filter { if case .move(let kk, _) = $0 { return kk == k(key) }; return false }.count
    }

    /// A is dragged by hand to the end (B C D E A) but the read stays unsettled; `drop` is made in Arrange meanwhile; then the bar reads clean.
    private func dropDuringTheWait(_ drop: [String], moved: String) async -> R {
        let clock = Clock()
        let r = await rig(order: names, layout: abcde(), modes: true, configure: { $0.now = { clock.now } })
        r.observer.mode = .unsettled
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 4)
        r.drags.fire(.ended)
        _ = await r.engine.reconcileOnce()
        _ = await r.engine.setLayout(Layout(visible: drop.map(k)), userPlacement: true, moved: [k(moved)])
        r.observer.mode = .good
        return r
    }

    @Test func anArrangeDropDuringTheWaitIsReappliedOnTopOfTheAdoptedHandDrag() async {
        let r = await dropDuringTheWait(["E", "A", "B", "C", "D"], moved: "E")      // E to the front
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return r.sink.lines.contains { $0.contains("re-applied your Arrange drop of") } })
        // the record holds the hand drag (A last) AND the drop (E first)
        #expect(await r.layoutVisible() == ["E", "B", "C", "D", "A"].map(k))
        #expect(r.sink.lines.contains { $0.hasPrefix("layout: re-applied your Arrange drop of ") && $0.hasSuffix(" after the menu bar drag was adopted") })
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        #expect(await r.layoutVisible() == ["E", "B", "C", "D", "A"].map(k))
        #expect(await movesOf(r, "A") == 0)                                          // the hand-dragged key is never moved back
        #expect(await r.actuator.order == ["E", "B", "C", "D", "A"].map(k))          // the drop is carried out
    }

    @Test func anArrangeDropOfTheKeyTheUserDraggedByHandWins() async {
        let r = await dropDuringTheWait(["B", "A", "C", "D", "E"], moved: "A")      // A dropped after B, later than its hand drag to the end
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return r.sink.lines.contains { $0.contains("re-applied your Arrange drop of") } })
        #expect(await r.layoutVisible() == ["B", "A", "C", "D", "E"].map(k))
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        #expect(await r.layoutVisible() == ["B", "A", "C", "D", "E"].map(k))
        #expect(await r.actuator.order == ["B", "A", "C", "D", "E"].map(k))
    }

    @Test func aDropDuringTheWaitWithNoHandDragChangeKeepsTheDropWithoutClaimingADrag() async {
        let clock = Clock()
        let r = await rig(order: names, layout: abcde(), modes: true, configure: { $0.now = { clock.now } })
        r.observer.mode = .unsettled
        r.drags.fire(.began); r.drags.fire(.ended)
        _ = await r.engine.reconcileOnce()
        _ = await r.engine.setLayout(Layout(visible: ["B", "A", "C", "D", "E"].map(k)), userPlacement: true, moved: [k("B")])
        r.observer.mode = .good
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        #expect(await r.layoutVisible() == ["B", "A", "C", "D", "E"].map(k))
        #expect(!r.sink.lines.contains { $0.contains("adopted your menu bar drag") })
        #expect(await r.actuator.order == ["B", "A", "C", "D", "E"].map(k))
    }

    @Test func theSwapVariantOfTwoMovesLikewise() async {
        await twoMoves({ a in await a.displace(k("D"), toIndex: 1); await a.displace(k("B"), toIndex: 3) }, bar: ["A", "D", "C", "B", "E"], cSlot: 2)
    }

    /// 9o9.26: swap A D C B E with C ambiguous; during the wait the user drops C (the held-back key) to the front in Arrange: the drop is kept.
    @Test func aDropOfTheHeldBackKeyDuringTheWaitIsKeptAfterTheCleanRead() async {
        for slot in 0..<5 {
            let clock = Clock()
            let r = await rig(order: names, layout: abcde(), modes: true, configure: { $0.now = { clock.now } })
            r.observer.mode = .unsettled
            r.drags.fire(.began)
            await r.actuator.displace(k("D"), toIndex: 1); await r.actuator.displace(k("B"), toIndex: 3)
            r.drags.fire(.ended)
            _ = await r.engine.reconcileOnce()
            _ = await r.engine.setLayout(Layout(visible: ["C", "A", "B", "D", "E"].map(k)), userPlacement: true, moved: [k("C")])
            r.observer.mode = .ambiguous([k("C"): slot])
            #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return r.sink.lines.contains { $0.contains("re-applied your Arrange drop of") } }, "slot \(slot)")
            let want = ["C", "A", "D", "B", "E"].map(k)
            #expect(await r.layoutVisible() == want, "slot \(slot)")
            r.observer.mode = .good
            for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
            #expect(await r.layoutVisible() == want, "slot \(slot)")
            #expect(await r.actuator.order == want, "slot \(slot)")
            #expect(await r.state.unverifiedAfterHandDrag.isEmpty, "slot \(slot)")
        }
    }

    @Test func anArrangeDropNextToAnUnverifiedKeyDoesNotClearIt() async {
        let clock = Clock()
        let r = await unverifiedA(clock)               // record A B C D E, bar B C D E A, A unverified
        _ = await r.engine.setLayout(Layout(visible: ["A", "E", "B", "C", "D"].map(k)), userPlacement: true, moved: [k("E")])
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await !r.actuator.calls.contains { if case .move(let key, _) = $0 { return key == k("A") }; return false })
        r.observer.mode = .good                          // A read fresh at its slot: the late adoption must still be available
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return r.sink.lines.contains { $0.contains("(read late)") } })
        #expect(await !r.actuator.calls.contains { if case .move(let key, _) = $0 { return key == k("A") }; return false })
    }

    @Test func movedOrRemovedIgnoresNeighboursOfADrop() {
        let o = ["A", "B", "C", "D", "E"].map(k)
        #expect(LayoutEngine.movedOrRemoved(old: ["B", "C", "D", "E", "A"].map(k), new: ["B", "C", "D", "A", "E"].map(k)) == [k("E")])
        #expect(LayoutEngine.movedOrRemoved(old: o, new: ["A", "B", "C", "D"].map(k)) == [k("E")])
    }

    @Test func anAmbiguousKeyMovedByMacOSAfterADragIsNotAdoptedLaterAsTheUsers() async {
        let r = await rig(order: names, layout: abcde(), modes: true)
        r.observer.mode = .ambiguous([k("C"): 1])        // bar B C D E A: C ambiguous at its true slot
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 4)
        r.drags.fire(.ended)
        #expect(await waitUntil { await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k) })
        await r.actuator.displace(k("C"), toIndex: 0)    // macOS moves C to the front
        r.observer.mode = .good                          // C reads cleanly at the front
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await r.actuator.order == ["B", "C", "D", "E", "A"].map(k) })
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k))
        #expect(!r.sink.lines.contains { $0.contains("(read late)") })
        #expect(await r.actuator.calls.count == 1)
    }

    @Test func aHeldBackAmbiguousKeyIsPlacedAfterItsRecordPredecessorNotAtTheFront() async {
        let six = ["A", "B", "C", "D", "E", "F"]
        let r = await rig(order: six, layout: Layout(visible: six.map(k)), modes: true)
        r.observer.mode = .ambiguous([k("C"): 1])
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 5)    // B C D E F A
        await r.actuator.displace(k("E"), toIndex: 4)    // B C D F E A
        r.drags.fire(.ended)
        #expect(await waitUntil { await r.layoutVisible() == ["B", "C", "D", "F", "E", "A"].map(k) })
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func aDragLandingLeftOfAnAmbiguousKeyIsNotUndone() async {
        let r = await rig(order: names, layout: abcde(), modes: true)
        r.observer.mode = .ambiguous([k("C"): 3])        // C ambiguous at its true slot (A B E C D)
        r.drags.fire(.began)
        await r.actuator.displace(k("E"), toIndex: 2)    // A B E C D
        r.drags.fire(.ended)
        #expect(await waitUntil { await r.layoutVisible() == ["A", "B", "E", "C", "D"].map(k) })
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        r.observer.mode = .good
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(await r.layoutVisible() == ["A", "B", "E", "C", "D"].map(k))
        #expect(await r.actuator.calls.isEmpty)
    }

    /// Record A B C D E; E is dragged to just left of C (true bar A B E C D) while C's read is wrong (it sits at its old slot).
    private func dropLeftOfUnreadC(_ mode: ModeObserver.Mode) async {
        let r = await rig(order: names, layout: abcde(), modes: true)
        r.observer.mode = mode
        r.drags.fire(.began)
        await r.actuator.displace(k("E"), toIndex: 2)    // true bar A B E C D
        r.drags.fire(.ended)
        let adoptedAsRead = ["A", "B", "C", "E", "D"].map(k)
        #expect(await waitUntil { await r.layoutVisible() == adoptedAsRead })
        #expect(r.sink.lines.contains { $0.contains("next to the drop is unread and will be placed when read") })
        #expect(!r.sink.lines.contains { $0.contains("D now after E") })
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(await r.layoutVisible() == adoptedAsRead)   // C is held back: the record is not enforced against it
        #expect(await r.actuator.calls.isEmpty)
        r.observer.mode = .good                              // C answers at its true slot
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await r.layoutVisible() == ["A", "B", "E", "C", "D"].map(k) })
        #expect(r.sink.lines.contains("layout: adopted your menu bar drag of \(k("C")) (read late)"))
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(await r.layoutVisible() == ["A", "B", "E", "C", "D"].map(k))
        #expect(await r.actuator.calls.isEmpty)
        #expect(await r.actuator.order == ["A", "B", "E", "C", "D"].map(k))
    }

    @Test func aDropLeftOfAStaleKeyAtItsOldSlotIsNotReversedWhenItRefreshes() async {
        await dropLeftOfUnreadC(.carried([k("C")], .completeExceptSelfPositioning))
    }

    @Test func aDropLeftOfAnAmbiguousKeyAtItsOldSlotIsNotReversedWhenItRefreshes() async {
        await dropLeftOfUnreadC(.ambiguous([k("C"): 2]))
    }

    @Test func aDropLeftOfAnAmbiguousKeyAtIndexZeroIsNotReversedWhenItRefreshes() async {
        await dropLeftOfUnreadC(.ambiguous([k("C"): 0]))
    }

    @Test func aDragNotNextToAnUnreadKeyLeavesNothingUnverified() async {
        // C is ambiguous at its true slot, but the drag (A to the end) is nowhere near it.
        let r = await rig(order: names, layout: abcde(), modes: true)
        r.observer.mode = .ambiguous([k("C"): 1])        // bar B C D E A: C's true slot is 1
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 4)
        r.drags.fire(.ended)
        #expect(await waitUntil { await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k) })
        #expect(!r.sink.lines.contains { $0.contains("next to the drop is unread") })
        #expect(!r.sink.lines.contains { $0.contains("(read late)") })
        r.observer.mode = .good
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(!r.sink.lines.contains { $0.contains("(read late)") })   // nothing was waiting to be placed
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func unreadNearDropPicksOnlyNeighboursOfAPossibleMover() {
        let o = ["A", "B", "C", "D", "E"].map(k), n = ["A", "B", "C", "E", "D"].map(k)
        #expect(LayoutEngine.unreadNearDrop(old: o, new: n, bar: n, unread: [k("C")]) == [k("C")])
        #expect(LayoutEngine.unreadNearDrop(old: o, new: n, bar: n, unread: [k("A")]).isEmpty)
        #expect(LayoutEngine.unreadNearDrop(old: o, new: o, bar: o, unread: [k("C")]).isEmpty)
    }

    @Test func aDragLandingRightOfAnAmbiguousKeyIsAdopted() async {
        let r = await rig(order: names, layout: abcde(), modes: true)
        r.observer.mode = .ambiguous([k("C"): 2])
        r.drags.fire(.began)
        await r.actuator.displace(k("E"), toIndex: 3)    // A B C E D
        r.drags.fire(.ended)
        #expect(await waitUntil { await r.layoutVisible() == ["A", "B", "C", "E", "D"].map(k) })
        r.observer.mode = .good
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(await r.layoutVisible() == ["A", "B", "C", "E", "D"].map(k))
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func aHeldBackKeyBetweenTwoMovedKeysLandsAmongTheirObservedPositions() {
        // record A B C D E F; C held back; the user moved A to the end and F to the front: F B C D E A -> C stays after B.
        let rec = ["A", "B", "C", "D", "E", "F"].map(k)
        let bar = ["F", "B", "C", "D", "E", "A"].map(k)
        let obs = ObservedOrder(onBar: bar, parked: [], uncorroborated: [k("C")])
        #expect(LayoutEngine.handDragAdopted(obs, record: rec).visible == bar)
        // two-key drag: B and D both moved to the end, C (held back) sat between them: A C E F B D keeps C after A, before the moved pair.
        let bar2 = ["A", "C", "E", "F", "B", "D"].map(k)
        let obs2 = ObservedOrder(onBar: bar2, parked: [], uncorroborated: [k("C")])
        #expect(LayoutEngine.handDragAdopted(obs2, record: rec).visible == bar2)
    }

    @Test func tieBreakNeverCountsAnUnverifiedKeyAsMoved() {
        let abc = ["A", "B", "C"].map(k), acb = ["A", "C", "B"].map(k)
        #expect(LayoutEngine.movedOrRemoved(old: abc, new: acb, unverified: [k("B")]) == [k("C")])
        #expect(LayoutEngine.movedOrRemoved(old: abc, new: acb, unverified: [k("C")]) == [k("B")])
        let o = ["A", "B", "C", "D", "E"].map(k), n = ["B", "A", "C", "D", "E"].map(k)
        #expect(LayoutEngine.movedOrRemoved(old: o, new: n, unverified: [k("A")]) == [k("B")])
        #expect(LayoutEngine.movedOrRemoved(old: o, new: n, unverified: [k("B")]) == [k("A")])
        // two movers, LCS tie: A B C D -> C D A B can keep {A,B} or {C,D}
        let m = LayoutEngine.keptInOrder(["A", "B", "C", "D"].map(k), ["C", "D", "A", "B"].map(k), prefer: [k("C")])
        #expect(m == [k("C"), k("D")])
    }

    @Test func aFreshButAmbiguousDraggedKeyIsNotAdoptedAsUnchangedBeforeTheDeadline() async {
        let clock = Clock()
        let r = await rig(order: names, layout: abcde(), modes: true, configure: { $0.now = { clock.now } })
        r.observer.mode = .ambiguous([k("A"): 0])       // the dragged key reads fresh but ambiguous, at its old slot
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 4)
        r.drags.fire(.ended)
        #expect(await waitUntil { r.sink.lines.contains { $0.hasPrefix("layout: hand drag adoption waiting") } })
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(r.state.layout.visible == names.map(k))
        #expect(!r.sink.lines.contains { $0.contains("left the order unchanged") })
        #expect(await r.actuator.calls.isEmpty)
        clock.advance(11)
        _ = await r.engine.reconcileOnce()
        #expect(r.sink.lines.contains("hand drag: left the order unchanged as far as Sommelier can see; 1 item(s) still unread"))
        r.observer.mode = .good
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await r.layoutVisible() == ["B", "C", "D", "E", "A"].map(k) })
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func aMembershipChangePendingDuringAdoptionIsDeferredAndDoesNotSpoilIt() async {
        // E is to be hidden (membership), and the drag moves A; the read stays "not fresh" for a while.
        let clock = Clock()
        let layout = Layout(visible: ["A", "B", "C", "D"].map(k), hidden: [k("E")])
        let r = await rig(order: names, layout: layout, modes: true, configure: { $0.now = { clock.now } })
        r.observer.mode = .staleComplete(k("A"))        // the dragged key's frame is carried: the read cannot say it was not moved
        r.drags.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 3)   // bar: B C D A E
        r.drags.fire(.ended)
        #expect(await waitUntil { r.sink.lines.contains("engine: you finished a menu bar drag; adopting the resulting order") })
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(await r.actuator.calls.isEmpty)                                   // the hide waits
        #expect(r.sink.lines.contains("engine: membership change deferred until the menu bar drag is adopted"))
        #expect(!r.sink.lines.contains { $0.contains("was not adopted") })
        r.observer.mode = .good
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await r.layoutVisible().last == k("A") })
        #expect(!r.sink.lines.contains { $0.contains("was not adopted") })
        // now that adoption is done the membership change proceeds
        #expect(await waitUntil { _ = await r.engine.reconcileOnce(); return await r.actuator.hidden.contains(k("E")) })
    }

    @Test func aMouseDownBetweenTheGateAndTheActuatorCallDoesNotReverseAnything() async {
        let r = await rig(order: names, layout: abcde(), gap: true)
        let drags = r.drags
        // The engine hands the churn zone over AFTER the interaction gate said clear and BEFORE the call: the user's mouse goes down there.
        r.gap.setGapHook { drags.fire(.began); drags.fire(.ended) }
        await r.actuator.displace(k("A"), toIndex: 4)
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == 1)
        r.gap.setGapHook(nil)
        // The flight flag was already up: the event is ours, so no adoption is pending and nothing says "not adopted".
        #expect(!r.sink.lines.contains { $0.contains("was not adopted") || $0.contains("adopting the resulting order") })
        _ = await r.engine.reconcileOnce()
        #expect(await r.actuator.calls.count == 1)
        #expect(await r.actuator.order == names.map(k))
        #expect(r.state.layout.visible == names.map(k))
    }

    @Test func triggersForwardMonitorEventsToTheEngine() async {
        let r = await rig(order: names, layout: abcde())
        let monitor = FakeHandDrags()
        let t = EngineTriggers(engine: r.engine, state: r.state, scanner: StubScanner(), resolve: { FakeMenuBar.resolve($0) },
                               wakeSignals: NoWake(), handDrags: monitor)
        t.start()
        defer { t.stop() }
        monitor.fire(.began)
        await r.actuator.displace(k("A"), toIndex: 4)
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .paused)
    }

    // MARK: pure helpers

    @Test func collapsedPileKeepsRecordOrderAmongItself() {
        // bar (left to right): pile P1 P2 P3 (stacked, order meaningless), then drawn A B. The record has P3 P1 P2.
        let obs = ObservedOrder(onBar: ["P2", "P1", "P3", "B", "A"].map(k), parked: [], systemOverflow: Set(["P1", "P2", "P3"].map(k)))
        let bar = LayoutEngine.handDragBar(obs, record: ["P3", "P1", "P2", "A", "B"].map(k))
        #expect(bar == ["P3", "P1", "P2", "B", "A"].map(k))
    }

    @Test func collapsedPileKeepsRecordOrderWhileUntrustedAndStaleKeysAreAdoptedAtTheirSlot() {
        // stacked pile P2 P1 (record P1 P2), then C (uncorroborated), B (stale), A: all kept at their observed slots.
        let obs = ObservedOrder(onBar: ["P2", "P1", "C", "B", "A"].map(k), parked: [], systemOverflow: Set(["P1", "P2"].map(k)),
                                uncorroborated: [k("C"), k("B")], staleOnBar: [k("B")])
        let rec = ["P1", "P2", "A", "B", "C"].map(k)
        let bar = LayoutEngine.handDragBar(obs, record: rec)
        #expect(bar == ["P1", "P2", "C", "B", "A"].map(k))
        #expect(LayoutEngine.adoptedVisible(rec, bar: bar) == bar)
    }

    @Test func openStripUsesTheObservedOrderAndTheChevronIsNeverAdopted() {
        var obs = ObservedOrder(onBar: ["P2", "P1", "B", "A"].map(k) + [k("chev")], parked: [], overflowChevron: k("chev"))
        obs.stripExpanded = true
        let bar = LayoutEngine.handDragBar(obs, record: ["P1", "P2", "A", "B"].map(k))
        #expect(bar == ["P2", "P1", "B", "A"].map(k))
        #expect(!LayoutEngine.adoptedVisible(["P1", "P2", "A", "B"].map(k), bar: bar).contains(k("chev")))
    }

    @Test func movedByDragPicksTheTravellingKey() {
        let m = LayoutEngine.movedByDrag(old: names.map(k), new: ["B", "C", "D", "E", "A"].map(k))
        #expect(m?.key == k("A") && m?.after == k("E"))
        #expect(LayoutEngine.movedByDrag(old: names.map(k), new: ["E", "A", "B", "C", "D"].map(k))?.after == nil)
    }
}

private struct StubScanner: SnapshotScanning {
    func scanVisible() async -> MenuBarSnapshot { MenuBarSnapshot(items: [], capturedAt: Date(timeIntervalSince1970: 0)) }
    func scan() async -> MenuBarSnapshot { MenuBarSnapshot(items: [], capturedAt: Date(timeIntervalSince1970: 0)) }
}
