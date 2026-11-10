import CoreGraphics
import Foundation
import Testing
import DecisionCore
@testable import SommelierCore

// ejb.15 (Wiring 3): the engine's order path is driven by `DecisionCore.step`. These tests prove the three obligations of the bead:
//  1. every Action the core emits gets exactly one moveResult, on every path (verified, failed, refused, busy, and the vetoes after the step);
//  2. no order move reaches the actuator except from a core Action (an actuator spy, in a world where the OLD planner wants moves the core does not);
//  3. the poll path feeds the step (kind poll) and never moves;
// plus the DecisionError path (a failing step stops actuation, shows lastError, never "converged") and the timing of step + rows.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private struct OpenCaps: CapabilityProvider { func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) } }
private final class Sink: @unchecked Sendable {
    private let lock = NSLock(); private var l: [String] = []
    func add(_ s: String) { lock.lock(); l.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return l }
}
private struct ActuatorObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] { FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden)) }
}
/// Clear for the engine's first three checks (pass start twice, pre-step), blocking from the fourth (the post-step `awaitQuiet` right before the drag).
private final class LateInteraction: InteractionSource, @unchecked Sendable {
    private let lock = NSLock(); private var calls = 0; private var armed = false
    var onFirst: (@Sendable () -> Void)?
    func arm() { lock.lock(); armed = true; calls = 0; lock.unlock() }
    func blockingReason() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard armed else { return nil }
        calls += 1
        if calls <= 3 { if calls == 3 { onFirst?() }; return nil }   // calls 1, 2: the pass start; call 3: the pre-step quiet check; call 4 on: right before the drag
        return "a menu is open"
    }
}

private struct World {
    let engine: LayoutEngine; let actuator: FakeActuator; let state: EngineState; let sink: Sink
}

@MainActor
private func world(order: [String], record: [String], configure: (inout LayoutEngine.Config) -> Void = { _ in },
                   interaction: (any InteractionSource)? = nil, failOn: [(Int, ActuationError)] = []) async -> World {
    let act = FakeActuator(order: order.map(k), hidden: [], capabilities: OpenCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    for (n, e) in failOn { await act.failOnCall(n, e) }
    var c = LayoutEngine.Config.plain()
    c.recordCoreTrace = true; c.minPassInterval = .zero; c.layoutCoalesce = .zero; c.interactionRetry = .seconds(3600)
    configure(&c)
    let sink = Sink(), state = EngineState()
    let engine = LayoutEngine(observer: ActuatorObserver(actuator: act), actuator: act, store: InMemoryLayoutStore(Layout.placedAll(visible: record.map(k))), capabilities: OpenCaps(),
                              state: state, interaction: interaction, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { sink.add($0) }, config: c)
    await engine.start()
    return World(engine: engine, actuator: act, state: state, sink: sink)
}

/// The audit says: every emitted action was answered once, in order (emitted, result, emitted, result...), and nothing is left waiting.
private func expectOneResultPerAction(_ w: World, _ why: String, minEmitted: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) async {
    let a = await w.engine.coreAudit()
    #expect(a.emitted >= minEmitted, "\(why): the core emitted nothing", sourceLocation: sourceLocation)
    #expect(a.emitted == a.resolved && a.violations == 0 && !a.awaiting, "\(why): emitted \(a.emitted) resolved \(a.resolved) violations \(a.violations) awaiting \(a.awaiting)", sourceLocation: sourceLocation)
    var open = false
    for t in a.trace {
        switch t {
        case .emitted: #expect(!open, "\(why): an action was emitted while another awaited its result", sourceLocation: sourceLocation); open = true
        case .result: #expect(open, "\(why): a result without an action", sourceLocation: sourceLocation); open = false
        default: break
        }
    }
    #expect(!open, "\(why): the last action has no result", sourceLocation: sourceLocation)
}

private func resultSites(_ trace: [CoreTraceEntry]) -> [String] {
    trace.compactMap { if case .result(_, _, _, let s) = $0 { return s } else { return nil } }
}

private func results(_ trace: [CoreTraceEntry]) -> [(Outcome, Bool)] {
    trace.compactMap { if case .result(_, let o, let p, _) = $0 { return (o, p) } else { return nil } }
}

/// Every moveResult of a normal veto path comes from a veto site, never from the end-of-pass safety net.
private func expectVetoSites(_ w: World, contains: String, sourceLocation: SourceLocation = #_sourceLocation) async {
    let sites = resultSites(await w.engine.coreAudit().trace)
    #expect(!sites.isEmpty, sourceLocation: sourceLocation)
    #expect(sites.allSatisfy { $0.contains("(veto)") && $0.contains(contains) }, "veto answered from \(sites)", sourceLocation: sourceLocation)
    #expect(!sites.contains { $0.contains("end of pass") }, "the end-of-pass net answered: \(sites)", sourceLocation: sourceLocation)
}

@MainActor
@Suite struct CoreMoveResultTests {
    static let record = ["A", "B", "C", "D"]
    static let reversed = ["D", "C", "B", "A"]

    @Test func verifiedMovesGetOneResultEach() async {
        let w = await world(order: Self.reversed, record: Self.record, configure: { $0.maxOrderMovesPerPass = .max })
        _ = await w.engine.reconcileOnce()
        #expect(await w.actuator.order == Self.record.map(k))
        await expectOneResultPerAction(w, "verified", minEmitted: 3)
        #expect(results(await w.engine.coreAudit().trace).allSatisfy { $0 == (.verified, true) })
    }

    @Test func aFailedDragGetsFailedPosted() async {
        let w = await world(order: Self.reversed, record: Self.record, failOn: [(1, .mechanismFailed("boom"))])
        _ = await w.engine.reconcileOnce()
        await expectOneResultPerAction(w, "failed")
        #expect(results(await w.engine.coreAudit().trace).first! == (.failed, true))
    }

    @Test func anOverflowRefusalGetsRefusedNotPosted() async {
        let msg = "D \(ActuationError.overflowRefusalMarker) (hidden by macOS because the bar is full); a drag cannot reach it"
        let w = await world(order: Self.reversed, record: Self.record, failOn: [(1, .mechanismFailed(msg))])
        _ = await w.engine.reconcileOnce()
        await expectOneResultPerAction(w, "refused")
        #expect(results(await w.engine.coreAudit().trace).first! == (.refused, false))
    }

    @Test func aBusyMouseGetsBusy() async {
        let w = await world(order: Self.reversed, record: Self.record, failOn: [(1, .userBusy)])
        _ = await w.engine.reconcileOnce()
        await expectOneResultPerAction(w, "busy")
        #expect(results(await w.engine.coreAudit().trace).first!.0 == .busy)
    }

    // Vetoes known only AFTER the step: each answers `busy` with posted:false, and no drag is made.
    @Test func aVetoAfterTheStepAnswersBusyNotPosted_maxActionsPerPass() async {
        let w = await world(order: Self.reversed, record: Self.record, configure: { $0.maxActionsPerPass = 0 })
        _ = await w.engine.reconcileOnce()
        await expectOneResultPerAction(w, "maxActionsPerPass")
        #expect(results(await w.engine.coreAudit().trace).first! == (.busy, false))
        await expectVetoSites(w, contains: "maxActionsPerPass (veto)")
        #expect(await w.actuator.calls.isEmpty)
    }

    @Test func aVetoAfterTheStepAnswersBusyNotPosted_awaitQuietBlocked() async {
        let late = LateInteraction()
        let w = await world(order: Self.reversed, record: Self.record, interaction: late)
        late.arm()   // the user touches the menu bar between the engine's first check (clear) and its check right before the drag
        let rep = await w.engine.reconcileOnce()
        #expect(rep.outcome == .paused)
        await expectOneResultPerAction(w, "awaitQuiet blocked")
        #expect(results(await w.engine.coreAudit().trace).first! == (.busy, false))
        await expectVetoSites(w, contains: "awaitQuiet")
        #expect(await w.actuator.calls.isEmpty)
    }

    @Test func aVetoAfterTheStepAnswersBusyNotPosted_conflictAppears() async {
        let late = LateInteraction()
        let w = await world(order: Self.reversed, record: Self.record, interaction: late)
        let engine = w.engine
        late.onFirst = { engine.setConflict("Bartender 7") }   // a conflicting manager appears after the pass's own conflict check, before the drag
        late.arm()
        let rep = await w.engine.reconcileOnce()
        #expect(rep.outcome == .paused)
        await expectOneResultPerAction(w, "conflict")
        #expect(results(await w.engine.coreAudit().trace).first! == (.busy, false))
        await expectVetoSites(w, contains: "(veto)")
        #expect(await w.actuator.calls.isEmpty)
    }

    // A step that throws on the moveResult must not lose the answer: the action stays awaiting, is answered once overall, and the order path resumes.
    @Test func aFailingMoveResultStepKeepsTheActionAwaitingAndDoesNotStallOrderMoves() async {
        let w = await world(order: Self.reversed, record: Self.record, failOn: [(1, .userBusy)])
        let engine = w.engine
        await engine.injectCoreFailureForTests(.undecodableOutput, onMoveResultOnly: true)
        let rep = await engine.reconcileOnce()
        _ = rep
        let a = await engine.coreAudit()
        let sites = resultSites(a.trace)
        #expect(a.emitted == 1 && a.resolved == 0 && a.awaiting, "failed answer must leave the action awaiting: emitted \(a.emitted) resolved \(a.resolved) awaiting \(a.awaiting)")
        #expect(sites.isEmpty)
        guard case .decision? = w.state.lastError else { Issue.record("lastError must be .decision, was \(String(describing: w.state.lastError))"); return }
        // the error clears: the next pass answers the straggler (the net, or the retry) once, then the core issues a new order move
        await engine.injectCoreFailureForTests(nil)
        _ = await engine.reconcileOnce()
        await engine.userRetry()   // a busy answer skips the key until a user event
        _ = await engine.reconcileOnce()
        let b = await engine.coreAudit()
        #expect(w.state.lastError == nil)
        #expect(b.violations == 0, "no double answer: violations \(b.violations)")
        #expect(b.emitted >= 2, "the core must issue a new order move after the error clears (no permanent stall): emitted \(b.emitted)")
        #expect(b.emitted == b.resolved && !b.awaiting, "every action answered exactly once: emitted \(b.emitted) resolved \(b.resolved)")
        // each emitted action has exactly one result in the trace
        let emittedCount = b.trace.filter { if case .emitted = $0 { return true } else { return false } }.count
        #expect(resultSites(b.trace).count == emittedCount)
    }

    // The core is asked again after a veto: the vetoed key is `skipped` (an unposted drag is not an attempt) until a user event; nothing is left awaiting.
    @Test func nothingStaysAwaitingAcrossManyMixedPasses() async {
        let msg = "D \(ActuationError.overflowRefusalMarker) (hidden by macOS because the bar is full); a drag cannot reach it"
        let w = await world(order: Self.reversed, record: Self.record, configure: { $0.maxOrderMovesPerPass = .max },
                            failOn: [(1, .mechanismFailed("boom")), (2, .userBusy), (3, .mechanismFailed(msg))])
        for i in 0..<12 {
            if i % 3 == 0 { await w.actuator.displace(k("A"), toIndex: 3) }
            _ = await w.engine.reconcileOnce()
            if i % 4 == 3 { await w.engine.userRetry() }
        }
        await expectOneResultPerAction(w, "mixed", minEmitted: 4)
    }
}

@MainActor
@Suite struct NoOrderMoveWithoutACoreActionTests {
    private func moves(_ calls: [FakeActuator.Call]) -> [(ItemKey, Relation)] {
        calls.compactMap { if case .move(let k, let r) = $0 { return (k, r) } else { return nil } }
    }

    // The actuator spy: the moves it saw are EXACTLY the moves the core emitted, in order, with the strip flag the core gave and single-drag on.
    @Test func everyActuatorMoveIsACoreActionOverRandomWorlds() async {
        var g = SystemRandomNumberGenerator()
        for seed in 0..<12 {
            var rng = SplitMix64(seed: UInt64(seed) &+ 11)
            let names = (0..<7).map { "K\($0)" }
            let w = await world(order: names.shuffled(using: &rng), record: names.shuffled(using: &rng), configure: { $0.maxOrderMovesPerPass = Int.random(in: 1...3, using: &g) })
            for i in 0..<25 {
                if i % 4 == 0 { await w.actuator.displace(k(names.randomElement(using: &rng)!), toIndex: Int.random(in: 0..<7, using: &rng)) }
                if i == 9 { await w.engine.userRetry() }
                if i == 14 {
                    var l = await w.state.layout
                    l.visible = l.visible.shuffled(using: &rng)
                    await w.engine.setLayout(l, moved: Set(l.visible.prefix(2)))
                }
                _ = await w.engine.regularPassForTests()
            }
            let a = await w.engine.coreAudit()
            let emitted: [(ItemKey, Relation, Bool)] = a.trace.compactMap { if case .emitted(let s, let r, let strip, _) = $0 { return (s, r, strip) } else { return nil } }
            let seen = moves(await w.actuator.calls)
            // an emitted action is vetoed after the step only by the vetoes of the engine (none in this world), so the lists are equal one to one
            #expect(seen.count == emitted.count, "seed \(seed): actuator saw \(seen.count) moves, the core emitted \(emitted.count)")
            for (x, y) in zip(seen, emitted) { #expect(x.0 == y.0 && x.1 == y.1, "seed \(seed): \(x) is not the core's \(y)") }
            let strip = await w.actuator.moveStripAllowed
            #expect(strip.map(\.1) == emitted.map(\.2), "seed \(seed): setStripAllowed must carry the core's strip flag")
            #expect(await w.actuator.moveSingleDrag.allSatisfy(\.1), "seed \(seed): every move is a single drag")
            #expect(a.violations == 0 && !a.awaiting && a.emitted == a.resolved)
        }
    }

    // A world where the OLD planner has an order move and the core has none (the subject is UNREAD, its frame being ambiguous): the actuator sees nothing.
    @Test func aMoveTheOldPlannerWantsButTheCoreDoesNotMakeNeverReachesTheActuator() async {
        final class Ambiguous: MenuBarObserver, @unchecked Sendable {
            let actuator: FakeActuator; let subject: ItemKey
            init(_ a: FakeActuator, _ s: ItemKey) { actuator = a; subject = s }
            func observe() async throws -> [ResolvedItem] {
                var items = FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden))
                for j in items.indices where items[j].key == subject { items[j].item.joinEvidence = .frameAmbiguous }
                return items
            }
        }
        let act = FakeActuator(order: ["X", "S", "A", "B"].map(k), hidden: [], capabilities: OpenCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        var c = LayoutEngine.Config.plain(); c.recordCoreTrace = true; c.minPassInterval = .zero
        let engine = LayoutEngine(observer: Ambiguous(act, k("S")), actuator: act, store: InMemoryLayoutStore(Layout.placedAll(visible: ["X", "A", "B", "S"].map(k))), capabilities: OpenCaps(),
                                  state: EngineState(), resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, config: c)
        await engine.start()
        for _ in 0..<8 { _ = await engine.regularPassForTests() }
        #expect(await act.calls.isEmpty)
        #expect(await engine.coreAudit().emitted == 0)
    }
}

@MainActor
@Suite struct CorePollPathTests {
    @Test func aQuietPollFeedsTheStepAsAPollReadAndNeverMoves() async {
        let w = await world(order: ["D", "C", "B", "A"], record: ["A", "B", "C", "D"])
        let items = FakeMenuBar.resolve(FakeMenuBar.snapshot(order: ["D", "C", "B", "A"].map(k), hidden: []))
        await w.engine.notePollScan(items, completeness: .complete)
        let a = await w.engine.coreAudit()
        let polls = a.trace.filter { if case .event("read", let site) = $0 { return site.contains("notePollScan") } else { return false } }
        #expect(polls.count == 1)
        #expect(await w.engine.coreLastRead()?.kind == .poll)
        let calls1 = await w.actuator.calls
        #expect(a.emitted == 0 && calls1.isEmpty)
        // many polls, still no move: a poll is evidence only, whatever the bar looks like
        for _ in 0..<5 { await w.engine.notePollScan(items, completeness: .complete) }
        let calls2 = await w.actuator.calls, emitted2 = await w.engine.coreAudit().emitted
        #expect(calls2.isEmpty && emitted2 == 0)
        // and the next PASS read, from the same state, does decide
        _ = await w.engine.regularPassForTests()
        let emitted3 = await w.engine.coreAudit().emitted
        #expect(emitted3 == 1)
    }

    @Test func aPollWhileAPassIsRequestedIsNotFed() async {
        let w = await world(order: ["D", "C", "B", "A"], record: ["A", "B", "C", "D"])
        await w.engine.requestReconcile(reason: "test")   // a pass is requested: the poll leaves the evidence to it (unchanged rule)
        let items = FakeMenuBar.resolve(FakeMenuBar.snapshot(order: ["D", "C", "B", "A"].map(k), hidden: []))
        await w.engine.notePollScan(items, completeness: .complete)
        let polls = await w.engine.coreAudit().trace.filter { if case .event("read", let site) = $0 { return site.contains("notePollScan") } else { return false } }
        #expect(polls.isEmpty)
    }
}

@MainActor
@Suite struct CoreDecisionErrorTests {
    @Test func aFailingStepStopsActuationShowsLastErrorAndNeverConverges() async {
        let w = await world(order: ["A", "B", "C", "D"], record: ["A", "B", "C", "D"])
        _ = await w.engine.reconcileOnce()                       // a clean pass first (the core is created and seeded)
        await w.actuator.displace(k("A"), toIndex: 3)
        await w.engine.injectCoreFailureForTests(.undecodableOutput)
        let rep = await w.engine.reconcileOnce()
        #expect((await w.actuator.calls).isEmpty)
        #expect(rep.outcome != .converged && !w.state.isConverged)
        guard case .decision? = w.state.lastError else { Issue.record("lastError must be .decision, was \(String(describing: w.state.lastError))"); return }
        #expect(StatusLine.text(state: w.state, trusted: true, conflicting: nil).hasPrefix("Error:"))
        #expect(!StatusLine.text(state: w.state, trusted: true, conflicting: nil).contains("matches"))
        // the next successful step resumes: the error clears and the move is made
        await w.engine.injectCoreFailureForTests(nil)
        _ = await w.engine.reconcileOnce()
        #expect(w.state.lastError == nil)
        #expect(!(await w.actuator.calls).isEmpty)
    }
}

// MARK: timing (plan section 5, bead step 7)

private let timingChevron = ItemKey.module(name: MenuBarItem.overflowChevronName)

/// 36-key record K00...K35: K00-K04 folded behind the chevron, K05-K29 drawn (25 keys on the bar besides the pile... see `drawn`), K30-K35 off the bar (unread: no owner evidence),
/// K10 and K11 drawn with an ambiguous frame (unread). A fresh chevron. So the read has pile, drawn, trusted, unread and free keys.
private func timingSnapshot(order: [ItemKey]) -> MenuBarSnapshot {
    func item(_ key: ItemKey, _ f: CGRect, chev: Bool = false) -> MenuBarItem {
        var i = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: chev ? key.description : key.description, axDescription: "", axIdentifier: chev ? "" : key.description,
                            frame: f, source: .appExtras, isOnMenuBar: true, isOverflowChevron: chev, joinEvidence: .identifier)
        i.controlCenterAllowed = true
        if k("K10") == key || k("K11") == key { i.joinEvidence = .frameAmbiguous }
        return i
    }
    var items: [MenuBarItem] = []
    for (i, key) in order.enumerated() {
        items.append(i < 5 ? item(key, CGRect(x: 700 + CGFloat(i) * 20, y: 0, width: 24, height: 24)) : item(key, CGRect(x: 813 + CGFloat(i - 5) * 30, y: 0, width: 24, height: 24)))
    }
    items.append(item(timingChevron, CGRect(x: 786, y: 0, width: 17, height: 24), chev: true))
    return MenuBarSnapshot(items: SystemOverflow.mark(items), capturedAt: Date())
}

@MainActor
@Suite struct CoreTimingTests {
    @Test func stepAndRowsFor36KeysAnd25OnTheBarWithUnreadAndFreeKeysPresent() async {
        let all = (0..<36).map { String(format: "K%02d", $0) }
        let onBar = Array(all[0..<25])                       // 5 folded + 20 drawn = 25 keys on the bar; K25...K35 are off the bar (unread)
        let act = FakeActuator(order: onBar.map(k), hidden: [], capabilities: OpenCaps(), makeSnapshot: { o, _ in timingSnapshot(order: o) })
        struct Obs: MenuBarObserver {
            let actuator: FakeActuator
            func observe() async throws -> [ResolvedItem] {
                timingSnapshot(order: await actuator.order).items.map { i in ResolvedItem(item: i, key: i.isOverflowChevron ? timingChevron : ItemKey(storeKey: i.axIdentifier)!, confidence: .exact) }
            }
        }
        var c = LayoutEngine.Config.plain(); c.minPassInterval = .zero
        let engine = LayoutEngine(observer: Obs(actuator: act), actuator: act, store: InMemoryLayoutStore(Layout.placedAll(visible: all.map(k))), capabilities: OpenCaps(),
                                  state: EngineState(), resolveSnapshot: { s in s.items.map { i in ResolvedItem(item: i, key: i.isOverflowChevron ? timingChevron : ItemKey(storeKey: i.axIdentifier)!, confidence: .exact) } },
                                  sleep: { _ in }, config: c)
        await engine.start()
        var moves = 0
        for i in 0..<40 {
            if i % 2 == 0 { await act.displace(k("K\(String(format: "%02d", 20 + i % 5))"), toIndex: 12) }   // drawn keys, away from the folded ones and from the first drawn key
            if i % 6 == 0 { await engine.userRetry() }   // gives the engine's budget (3 on this full bar) back, so the planner keeps deciding
            let before = await act.calls.count
            _ = await engine.regularPassForTests()
            moves += await act.calls.count - before
        }
        let t = await engine.coreReadStepTiming()
        let read = await engine.coreLastRead()
        #expect(t.count >= 40 && moves >= 5, "the engine really decided (moves=\(moves))")
        guard let read, let state = await engine.coreStateForTests() else { Issue.record("no core state"); return }
        #expect(!read.unread.isEmpty && read.chevron == .fresh && !read.pile.isEmpty)
        let keys = await engine.coreKeysForTests()
        let ids = all.compactMap { keys.id(for: k($0)) }
        #expect(ids.count == 36)
        // rows + status + notes, once per step (plan section 5)
        let clock = ContinuousClock()
        var rowsMs: [Double] = []
        for _ in 0..<20 {
            let t0 = clock.now
            _ = try? DecisionCore.status(state, read)
            for id in ids { _ = try? DecisionCore.row(state, read, id); _ = try? DecisionCore.rowNote(state, read, id) }
            let d = t0.duration(to: clock.now).components
            rowsMs.append(Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
        }
        rowsMs.sort()
        let avgStepMs = Double(t.totalNanos) / Double(t.count) / 1e6, worstStepMs = Double(t.worstNanos) / 1e6
        print("PERF core read step (36-key record, \(read.drawn.count + read.pile.count) listed, unread \(read.unread.count), free keys present): avg \(String(format: "%.2f", avgStepMs)) ms, worst \(String(format: "%.2f", worstStepMs)) ms over \(t.count) reads")
        let ad = await engine.coreAdaptTiming()
        print("PERF ReadAdapter.adapt: avg \(String(format: "%.2f", Double(ad.totalNanos) / Double(max(1, ad.count)) / 1e6)) ms, worst \(String(format: "%.2f", Double(ad.worstNanos) / 1e6)) ms over \(ad.count) reads")
        print("PERF status + 36 rows + 36 notes: median \(String(format: "%.2f", rowsMs[rowsMs.count / 2])) ms, worst \(String(format: "%.2f", rowsMs.last!)) ms")
        #expect(avgStepMs < 100 && rowsMs[rowsMs.count / 2] < 200, "the step and the rows must stay far below a pass")
    }
}
