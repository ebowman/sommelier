import Foundation
import Testing
@testable import SommelierCore

// gdu.48: engine-stamped layout revisions, revision-based pending layout, failure clearing, on-demand capabilities.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private let t0 = Date(timeIntervalSince1970: 1_000_000)

private struct Caps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability {
        if case .module = key { return Capability(canMove: false, canHide: false, reason: "system module") }
        return Capability(canMove: true, canHide: true)
    }
}

private struct ActuatorObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] {
        let order = await actuator.order, hidden = await actuator.hidden
        return FakeMenuBar.resolve(FakeMenuBar.snapshot(order: order, hidden: hidden))
    }
}

private final class Logs: @unchecked Sendable {
    private let lock = NSLock(); private var l: [String] = []
    func add(_ s: String) { lock.lock(); l.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return l }
}

@MainActor
private func rig(order: [ItemKey], layout: Layout, failOn: [(Int, ActuationError)] = [], logs: Logs = Logs())
    async -> (engine: LayoutEngine, state: EngineState, actuator: FakeActuator, store: InMemoryLayoutStore) {
    let act = FakeActuator(order: order, hidden: [], capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    for (n, e) in failOn { await act.failOnCall(n, e) }
    let store = InMemoryLayoutStore(layout)
    let state = EngineState()
    let engine = LayoutEngine(observer: ActuatorObserver(actuator: act), actuator: act, store: store, capabilities: Caps(), state: state,
                              resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { logs.add($0) }, config: .multiMove)   // gdu.144: plain bar, not assumed full
    await engine.start()
    return (engine, state, act, store)
}

@MainActor
@Suite struct ArrangeRevisionTests {
    // MARK: 1. engine-stamped drops

    @Test func setLayoutReturnsAMonotonicRevisionStampedWithThePassesStarted() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout.placedAll(visible: ["A", "B"].map(k)))
        let r0 = r.state.layoutRevision
        #expect(r0 >= 1)   // start() published the loaded layout
        let s1 = await r.engine.setLayout(Layout.placedAll(visible: ["B", "A"].map(k)))
        #expect(s1.revision == r0 + 1 && r.state.layoutRevision == s1.revision)
        #expect(s1.passesStarted == r.state.passesStartedAtRevision)
        _ = await r.engine.reconcileOnce()
        let s2 = await r.engine.setLayout(Layout.placedAll(visible: ["A", "B"].map(k)))
        #expect(s2.revision == s1.revision + 1 && s2.passesStarted >= s1.passesStarted + 1)
    }

    @Test func aPassStartedRightAfterPublicationJudgesTheDropBeforeAnyUITick() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout.placedAll(visible: ["A", "B"].map(k)))
        _ = await r.engine.reconcileOnce()
        var t = ArrangeTracker()
        let target = Layout.placedAll(visible: ["B", "A"].map(k))
        let ticket = t.record([k("B")], passesStarted: r.state.passesStarted, now: t0, awaitingStamp: true)
        let stamp = await r.engine.setLayout(target)
        t.stamp(ticket: ticket, passesStartedAtRevision: stamp.passesStarted)
        _ = await r.engine.reconcileOnce()   // starts right after publication, with no tick in between
        #expect(r.state.passSequence > stamp.passesStarted)
        let log = t.update(observed: r.state.observed, layout: r.state.layout, perItem: r.state.perItem, passSequence: r.state.passSequence,
                           showHiddenSection: false, now: t0 + 1)
        #expect(t.isEmpty && log.count == 1 && log[0].contains("verified in place"))
    }

    @Test func aPassAlreadyRunningAtPublicationNeverJudgesTheDrop() {
        var t = ArrangeTracker()
        let ticket = t.record([k("b")], passesStarted: 4, now: t0, awaitingStamp: true)
        // before the stamp arrives nothing is judged, however many passes finish
        #expect(t.suppressed(passSequence: 9) == [k("b")])
        let layout = Layout.placedAll(visible: [k("b")])
        let obs = ObservedOrder(onBar: [k("b")], parked: [])
        #expect(t.update(observed: obs, layout: layout, perItem: [k("b"): .inPlace], passSequence: 9, showHiddenSection: false, now: t0 + 1).isEmpty)
        t.stamp(ticket: ticket, passesStartedAtRevision: 5)   // pass 5 was in flight when the layout was published
        #expect(t.update(observed: obs, layout: layout, perItem: [k("b"): .inPlace], passSequence: 5, showHiddenSection: false, now: t0 + 2).isEmpty)
        #expect(t.awaiting == [k("b")])
        #expect(t.update(observed: obs, layout: layout, perItem: [k("b"): .inPlace], passSequence: 6, showHiddenSection: false, now: t0 + 3).count == 1)
    }

    @Test func aStampOfAnOlderSubmissionDoesNotTouchAReRecordedKey() {
        var t = ArrangeTracker()
        let first = t.record([k("b")], passesStarted: 1, now: t0, awaitingStamp: true)
        let second = t.record([k("b")], passesStarted: 2, now: t0 + 1, awaitingStamp: true)
        t.stamp(ticket: first, passesStartedAtRevision: 3)
        #expect(t.entries[k("b")]?.awaitingStamp == true)
        t.stamp(ticket: second, passesStartedAtRevision: 4)
        #expect(t.entries[k("b")]?.awaitingStamp == false && t.entries[k("b")]?.dropSequence == 4)
    }

    @Test func theUnsettledGateStillHoldsWithStamps() {
        var t = ArrangeTracker()
        let ticket = t.record([k("b")], passesStarted: 0, now: t0, awaitingStamp: true)
        t.stamp(ticket: ticket, passesStartedAtRevision: 1)
        let layout = Layout.placedAll(visible: [k("b")])
        let obs = ObservedOrder(onBar: [k("b")], parked: [])
        #expect(t.update(observed: obs, layout: layout, perItem: [k("b"): .inPlace], passSequence: 2, showHiddenSection: false, now: t0 + 1,
                         observationSettled: false).isEmpty)
        #expect(t.suppressed(passSequence: 2, observationSettled: false) == [k("b")] && t.awaiting == [k("b")])
        #expect(t.update(observed: obs, layout: layout, perItem: [k("b"): .inPlace], passSequence: 2, showHiddenSection: false, now: t0 + 2).count == 1)
    }

    @Test func engineAppendedItemsPublishANewRevisionStampedWithTheRunningPass() async {
        let r = await rig(order: ["A", "B"].map(k), layout: Layout.placedAll(visible: [k("A")]))
        let before = r.state.layoutRevision
        _ = await r.engine.reconcileOnce()   // B is new: the pass appends it to the layout
        #expect(r.state.layout.allKeys.contains(k("B")))
        #expect(r.state.layoutRevision == before + 1)
        #expect(r.state.passesStartedAtRevision == 1 && r.state.passesStarted == 1)
    }

    // MARK: 2. revision-based pending layout

    @Test func pendingResolvesByRevisionEvenWhenTheEngineAppendedAnItem() {
        var p = PendingLayout()
        let submitted = Layout.placedAll(visible: [k("A"), k("B")])
        p.submit(submitted)
        let early = p.resolve(stateRevision: 5)                         // revision unknown yet
        #expect(p.isActive && !early)
        p.submitted(revision: 7)
        let notYet = p.resolve(stateRevision: 6)                        // not published yet
        #expect(!notYet)
        // the engine appended N before publishing: its layout is not equal to the submitted one, but its revision is >= ours
        let done = p.resolve(stateRevision: 8)
        #expect(done && !p.isActive)
    }

    @Test func furtherDropsRebaseOntoTheEngineLayoutAndKeepItsAdditions() {
        var p = PendingLayout()
        p.submit(Layout.placedAll(visible: [k("B"), k("A")]))
        let engineLayout = Layout.placedAll(visible: [k("A"), k("B"), k("N")])   // the engine appended N meanwhile
        let eff = p.effective(over: engineLayout)
        #expect(eff.visible == [k("B"), k("A"), k("N")])               // our order, plus the engine's addition
        p.submitted(revision: 3)
        _ = p.resolve(stateRevision: 4)
        #expect(p.effective(over: engineLayout) == engineLayout)
    }

    @Test func concurrentSubmissionsResolveOnlyAfterTheLastRevision() {
        var p = PendingLayout()
        p.submit(Layout.placedAll(visible: [k("A")])); p.submit(Layout.placedAll(visible: [k("B")]))
        p.submitted(revision: 2)
        let early = p.resolve(stateRevision: 2)   // the second submission has not returned yet
        p.submitted(revision: 3)
        let stale = p.resolve(stateRevision: 2)
        let done = p.resolve(stateRevision: 3)
        #expect(!early && !stale && done)
    }

    @Test func anItemAppendedBetweenDropAndPublicationSurvivesInTheNextDrop() async {
        // The engine's own layout (with N, revision r+1) races the user's drop; the next drop must be computed from the rebased copy.
        let r = await rig(order: ["A", "B", "N"].map(k), layout: Layout.placedAll(visible: ["A", "B"].map(k)))
        var p = PendingLayout()
        let drop1 = Layout.placedAll(visible: ["B", "A"].map(k))
        p.submit(drop1)
        _ = await r.engine.reconcileOnce()                       // appends N (new revision) before drop1 is published
        #expect(r.state.layout.allKeys.contains(k("N")))
        let nextDropBase = p.effective(over: r.state.layout)
        #expect(nextDropBase.allKeys.contains(k("N")) && nextDropBase.visible.prefix(2) == [k("B"), k("A")])
        let stamp = await r.engine.setLayout(nextDropBase)       // the submission of the following drop keeps N
        p.submitted(revision: stamp.revision - 1)   // drop1's (older) revision
        p.submit(nextDropBase); p.submitted(revision: stamp.revision)
        let done = p.resolve(stateRevision: r.state.layoutRevision)
        #expect(done && r.state.layout.allKeys.contains(k("N")) && r.state.layout.visible.prefix(2) == [k("B"), k("A")])
    }

    // MARK: 3. failed badges clear

    @Test func aFailedKeyWhoseSettledObservationMatchesTheLayoutBecomesInPlace() async {
        let logs = Logs()
        let r = await rig(order: ["A", "B"].map(k), layout: Layout.placedAll(visible: ["B", "A"].map(k)),
                          failOn: (1...9).map { ($0, ActuationError.mechanismFailed("boom")) }, logs: logs)
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }   // struck out: failed until the layout changes or Retry
        let failed = r.state.perItem.filter { if case .failed = $0.value { return true }; return false }.keys
        #expect(!failed.isEmpty)
        #expect(ArrangeSections.statusLine(perItem: r.state.perItem, lastError: r.state.lastError, isConverged: r.state.isConverged,
                                           inFlight: false).contains("failed"))
        await r.actuator.displace(k("B"), toIndex: 0)           // something else fixed the bar
        _ = await r.engine.reconcileOnce()
        #expect(r.state.perItem.values.allSatisfy { $0 == .inPlace })
        #expect(!ArrangeSections.statusLine(perItem: r.state.perItem, lastError: r.state.lastError, isConverged: r.state.isConverged,
                                            inFlight: false).contains("failed"))
        #expect(r.state.isConverged)
        #expect(logs.all.contains { $0.contains("cleared failure for") && $0.contains("now in place") })
    }

    @Test func aTimedOutKeyClearsWhenALaterPassFindsItInPlace() {
        var t = ArrangeTracker()
        let layout = Layout.placedAll(visible: [k("a"), k("b")])
        let wrong = ObservedOrder(onBar: [k("b"), k("a")], parked: [])
        let right = ObservedOrder(onBar: [k("a"), k("b")], parked: [])
        t.record([k("b")], passesStarted: 0, now: t0)
        t.update(observed: wrong, layout: layout, perItem: [k("b"): .inPlace], passSequence: 1, showHiddenSection: false, now: t0 + 91)
        #expect(t.timedOut == [k("b")])
        t.update(observed: right, layout: layout, perItem: [k("b"): .inPlace], passSequence: 2, showHiddenSection: false, now: t0 + 100)
        #expect(t.isEmpty && t.timedOut.isEmpty)
    }

    // MARK: 4. headless capabilities

    @Test func capabilitiesResolveFromStateItemsLikeAUIDropWithoutAWindow() {
        let dummy = ItemKey.status(ownerKey: "MBDummy", autosaveName: "Dummy-A")
        let info = ItemInfo(key: dummy, title: "A", axDescription: "A", ownerPID: 1, ownerBundleID: "ie.boboco.mbdummy",
                            ownerName: "MBDummy", width: 20, isOnBar: true)
        // fake state: the tracked set holds the bundle id, not the owner key
        let rules = ArrangeCapabilities.rules(items: [dummy: info], tracked: ["ie.boboco.mbdummy"])
        let cap = ArrangeCapabilities.resolve(dummy, items: [dummy: info], rules: rules)
        #expect(cap.canMove && cap.canHide)
        // the same key without ItemInfo and an untracked owner would be rejected by the rules, which is what the bug looked like
        let blind = ArrangeCapabilities.rules(items: [:], tracked: ["ie.boboco.mbdummy"])
        #expect(!blind.capability(for: dummy).canHide)
    }

    // MARK: 5. engine-side merge of engine additions (gdu.52)

    @Test func anItemTheEngineAppendedAfterComposeSurvivesTheSubmittedDrop() async {
        let logs = Logs()
        let r = await rig(order: ["A", "B", "N"].map(k), layout: Layout.placedAll(visible: ["A", "B"].map(k)), logs: logs)
        let base = r.state.layoutRevision                      // the drop is composed here
        let drop = Layout.placedAll(visible: ["B", "A"].map(k))
        _ = await r.engine.reconcileOnce()                     // the engine appends N (new revision) before the drop arrives
        #expect(r.state.layoutRevision == base + 1)
        _ = await r.engine.setLayout(drop, basedOn: base)
        #expect(r.state.layout.visible == ["B", "A", "N"].map(k))
        #expect(logs.all.filter { $0.contains("setLayout merged 1 engine-added key(s) composed on revision \(base)") }.count == 1)
        _ = await r.engine.reconcileOnce()
        _ = await r.engine.reconcileOnce()
        #expect(logs.all.filter { $0.hasPrefix("New item") || $0.contains("New item:") }.count == 1)   // no second notice
        #expect(r.state.layout.allKeys.filter { $0 == k("N") }.count == 1)
        #expect(((try? r.store.load()) ?? .empty).allKeys.contains(k("N")))
    }

    @Test func aKeyTheUserPlacedExplicitlyKeepsTheUsersPosition() async {
        let r = await rig(order: ["A", "B", "N"].map(k), layout: Layout.placedAll(visible: ["A", "B"].map(k)))
        let base = r.state.layoutRevision
        _ = await r.engine.reconcileOnce()
        _ = await r.engine.setLayout(Layout.placedAll(visible: ["A"].map(k), hidden: ["N", "B"].map(k)), basedOn: base)
        #expect(r.state.layout.hidden == ["N", "B"].map(k) && r.state.layout.visible == [k("A")])
    }

    @Test func withoutABaseRevisionTheLayoutIsReplacedWholesale() async {
        let r = await rig(order: ["A", "B", "N"].map(k), layout: Layout.placedAll(visible: ["A", "B"].map(k)))
        _ = await r.engine.reconcileOnce()
        _ = await r.engine.setLayout(Layout.placedAll(visible: ["B", "A"].map(k)))
        #expect(r.state.layout.visible == ["B", "A"].map(k))
    }

    @Test func aDropComposedOnTheCurrentRevisionAddsNothing() async {
        let logs = Logs()
        let r = await rig(order: ["A", "B", "N"].map(k), layout: Layout.placedAll(visible: ["A", "B"].map(k)), logs: logs)
        _ = await r.engine.reconcileOnce()
        let base = r.state.layoutRevision
        _ = await r.engine.setLayout(Layout.placedAll(visible: ["B", "A", "N"].map(k)), basedOn: base)
        #expect(!logs.all.contains { $0.contains("setLayout merged") })
    }

    @Test func aConfirmDialogsComposeRevisionSurvivesAnAppendWhileItIsOpen() async {
        let r = await rig(order: ["A", "B", "N"].map(k), layout: Layout.placedAll(visible: ["A", "B"].map(k)))
        let composedAt = r.state.layoutRevision                  // dialog opens: layout composed here
        let composed = Layout.placedAll(visible: ["B", "A"].map(k))
        _ = await r.engine.reconcileOnce()                       // N appended while the dialog is open
        #expect(r.state.layoutRevision == composedAt + 1)
        _ = await r.engine.setLayout(composed, basedOn: composedAt)   // confirm passes the revision from when it opened
        #expect(r.state.layout.visible == ["B", "A", "N"].map(k))
    }

    @Test func anUnsupportedStatusIsNotTouchedByFailureClearing() async {
        let r = await rig(order: [.module(name: "clock"), k("A")], layout: Layout.placedAll(visible: [k("A")], hidden: [.module(name: "clock")]))
        for _ in 0..<2 { _ = await r.engine.reconcileOnce() }
        #expect(r.state.perItem[.module(name: "clock")] != nil)
        if case .unsupported? = r.state.perItem[.module(name: "clock")] {} else { Issue.record("expected .unsupported") }
    }

    @Test func aFailureRecordedInThisPassStaysEvenWhenThePassObservationMatchesUntilALaterPass() async {
        let logs = Logs()
        let act = FakeActuator(order: ["A", "B"].map(k), hidden: [], capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        let liar = LyingMover(inner: act)                        // performs the move but reports failure
        let store = InMemoryLayoutStore(Layout.placedAll(visible: ["B", "A"].map(k)))
        let state = EngineState()
        let engine = LayoutEngine(observer: ActuatorObserver(actuator: act), actuator: liar, store: store, capabilities: Caps(), state: state,
                                  resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { logs.add($0) }, config: .plain())
        await engine.start()
        _ = await engine.reconcileOnce()
        #expect(await act.order == ["B", "A"].map(k))            // the bar now matches the layout ...
        let failedNow = state.perItem.values.contains { if case .failed = $0 { return true }; return false }
        #expect(failedNow)                                       // still .failed after the pass that recorded it
        _ = await engine.reconcileOnce()                         // a LATER settled pass finds it realized
        #expect(state.perItem.values.allSatisfy { $0 == .inPlace })
    }
}

private struct LyingMover: MenuBarActuator {
    let inner: FakeActuator
    func move(_ key: ItemKey, relation: Relation) async -> ActuationResult {
        let r = await inner.move(key, relation: relation)
        if case .verified(let s) = r { return .failed(.mechanismFailed("reported failure"), s) }
        return r
    }
    func setHidden(_ key: ItemKey, _ hidden: Bool) async -> ActuationResult { await inner.setHidden(key, hidden) }
    func applyHiddenBatch(_ changes: [ItemKey: Bool]) async -> ActuationResult { await inner.applyHiddenBatch(changes) }
}
