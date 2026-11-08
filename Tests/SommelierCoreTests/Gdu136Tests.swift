import Foundation
import Testing
@testable import SommelierCore

// gdu.136: one surprise at a time. After the user's edit (a drop in Arrange) the pass for it, and the passes chained from it, perform only
// the edit's own move; any other pending order move waits for the next regular pass and the status line announces it first. A drawn-only
// edit keeps the bar-level strip hold; an edit of a folded key releases it.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }

private struct AllCaps136: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
}

private struct Obs136: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] {
        FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden))
    }
}

private final class Lines136: @unchecked Sendable {
    private let l = NSLock(); private var v: [String] = []
    func add(_ s: String) { l.lock(); v.append(s); l.unlock() }
    var all: [String] { l.lock(); defer { l.unlock() }; return v }
}

@MainActor private func waitUntil136(_ cond: @escaping @MainActor @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<600 {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

private func moves136(_ a: FakeActuator) async -> [ItemKey] {
    await a.calls.compactMap { if case .move(let key, _) = $0 { key } else { nil } }
}

/// Bar A B C D E F; the record already wants D before C (a pending order move) when the user drops F after A.
@MainActor
private func dropRig() async -> (engine: LayoutEngine, act: FakeActuator, state: EngineState, lines: Lines136) {
    let act = FakeActuator(order: ["A", "B", "C", "D", "E", "F"].map(k), hidden: [], capabilities: AllCaps136(),
                           makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    var cfg = LayoutEngine.Config()
    cfg.layoutCoalesce = .zero
    cfg.delaySleep = { _ in try? await Task.sleep(for: .seconds(3600)) }   // the follow-up is released by the test, not by the clock
    let state = EngineState(), lines = Lines136()
    let engine = LayoutEngine(observer: Obs136(actuator: act), actuator: act,
                              store: InMemoryLayoutStore(Layout.placedAll(visible: ["A", "B", "D", "C", "E", "F"].map(k))),
                              capabilities: AllCaps136(), state: state, resolveSnapshot: { FakeMenuBar.resolve($0) },
                              sleep: { _ in }, log: { lines.add($0) }, config: cfg)
    await engine.start()
    return (engine, act, state, lines)
}

@MainActor
@Suite struct OneSurpriseAtATimeTests {
    @Test func aUserDropPerformsOnlyItsOwnMoveThenTheNextRegularPassPerformsTheRest() async {
        let r = await dropRig()
        _ = await r.engine.setLayout(Layout.placedAll(visible: ["A", "F", "B", "D", "C", "E"].map(k)), moved: [k("F")])
        // pass 1 (the drop's) moves F and plans the C/D swap too, but defers it; the chained pass 2 only reports the deferral
        #expect(await waitUntil136 { r.state.passesStarted >= 2 && !r.state.lastPlan.deferredAfterUserEdit.isEmpty && !(r.state.perItem[k("F")] == .pending) })
        for _ in 0..<30 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await moves136(r.act) == [k("F")])
        #expect(r.state.passesStarted == 2)
        #expect(r.state.lastPlan.userEditMoved == [k("F")])
        let deferred = r.state.lastPlan.deferredAfterUserEdit
        #expect(deferred.count == 1 && [k("C"), k("D")].contains(deferred[0]))
        #expect(r.lines.all.contains { $0.contains("deferred after your change") })
        // the next REGULAR pass (a trigger: not chained, not the user's) performs it
        await r.engine.requestReconcile(reason: "trigger")
        #expect(await waitUntil136 { await moves136(r.act).count == 2 })
        let after = await moves136(r.act)
        #expect(after[0] == k("F") && [k("C"), k("D")].contains(after[1]))
        #expect(r.lines.all.contains { $0.contains("user-edit restriction ended") })
        #expect(r.state.lastPlan.deferredAfterUserEdit.isEmpty)
    }

    /// The user shows a hidden key X while a swap of C and D is pending: pass 1 writes the membership, the CHAINED pass 2 (no request of its own)
    /// would swap C and D; it must not. The swap waits for the next regular pass.
    @Test func aChainedPassAfterTheUsersPassPerformsNoOtherMove() async {
        let act = FakeActuator(order: ["A", "B", "C", "D"].map(k), hidden: [k("X")], capabilities: AllCaps136(),
                               makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        var cfg = LayoutEngine.Config()
        cfg.layoutCoalesce = .zero
        cfg.delaySleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        let state = EngineState(), lines = Lines136()
        let engine = LayoutEngine(observer: Obs136(actuator: act), actuator: act,
                                  store: InMemoryLayoutStore(Layout.placedAll(visible: ["A", "B", "D", "C"].map(k), hidden: [k("X")])),
                                  capabilities: AllCaps136(), state: state, resolveSnapshot: { FakeMenuBar.resolve($0) },
                                  sleep: { _ in }, log: { lines.add($0) }, config: cfg)
        await engine.start()
        _ = await engine.setLayout(Layout.placedAll(visible: ["X", "A", "B", "D", "C"].map(k)), moved: [k("X")])
        #expect(await waitUntil136 { state.passesStarted >= 2 && !state.lastPlan.deferredAfterUserEdit.isEmpty })
        for _ in 0..<30 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await act.calls.contains { if case .applyHiddenBatch = $0 { true } else { false } })   // pass 1: the user's membership change
        #expect(await moves136(act).isEmpty)                                                             // the chained pass: no other move
        #expect(state.passesStarted == 2)
        #expect(lines.all.contains { $0.contains("deferred after your change") })
        await engine.requestReconcile(reason: "trigger")
        #expect(await waitUntil136 { await moves136(act).count == 1 })
        let after = await moves136(act)
        #expect([k("C"), k("D")].contains(after[0]))
    }

    @Test func theDeferredMoveIsReportedSkippedWithTheReasonNotUnsupported() async {
        let r = await dropRig()
        _ = await r.engine.setLayout(Layout.placedAll(visible: ["A", "F", "B", "D", "C", "E"].map(k)), moved: [k("F")])
        #expect(await waitUntil136 { r.state.passesStarted >= 1 && !r.state.lastPlan.deferredAfterUserEdit.isEmpty })
        for key in r.state.lastPlan.deferredAfterUserEdit {
            if case .unsupported? = r.state.perItem[key] { Issue.record("deferred \(key) must not read unsupported") }
        }
        #expect(Reconciler.deferredAfterUserEditReason == "waiting a moment after your change")
    }

    @Test func aPlanWithoutAUserEditDefersNothing() async {
        let r = await dropRig()   // the record's C/D swap is pending, nobody edited anything
        _ = await r.engine.reconcileOnce()
        #expect(await moves136(r.act).count == 1)
        #expect(r.state.lastPlan.deferredAfterUserEdit.isEmpty)
        #expect(!r.lines.all.contains { $0.contains("deferred after your change") })
    }

    @Test func theStatusLineAnnouncesDoneAndNextBetweenThePasses() {
        #expect(ArrangeSections.userEditDeferredText(done: ["GateOpener"], next: ["WiFi Signal"]) == "Done: GateOpener. Next: WiFi Signal")
        #expect(ArrangeSections.userEditDeferredText(done: ["GateOpener"], next: ["WiFi Signal", "B", "C"])
                == "Done: GateOpener. Next: WiFi Signal (2 more to match your order)")
        var ctx = ArrangeSections.StatusContext()
        ctx.userEditDone = ["GateOpener"]; ctx.userEditNext = ["WiFi Signal", "B"]
        let line = ArrangeSections.statusLine(perItem: [:], lastError: nil, isConverged: true, inFlight: false, context: ctx)
        #expect(line.contains("Done: GateOpener. Next: WiFi Signal (1 more to match your order)"))
        // while the engine is dragging, the Moving text wins
        let moving = ArrangeSections.statusLine(perItem: [:], lastError: nil, isConverged: false, inFlight: true, context: ctx)
        #expect(!moving.contains("Done:"))
    }
}

@MainActor
@Suite struct StripHoldSurvivesADrawnEditTests {
    @Test func aDrawnOnlyEditKeepsTheHoldAndDispatchesNoNewFoldMove() async {
        let r = await holdRig(failCalls: 10)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await r.engine.stripOpenHold != nil)
        let before = await moveCalls(r.actuator)
        _ = await r.engine.setLayout(Layout.placedAll(visible: [k("D1"), k("P1"), k("D3"), k("D2"), k("P2"), k("P3"), k("D4")]), moved: [k("D2")])
        #expect(await r.engine.stripOpenHold != nil)
        #expect(r.bar.lines.contains { $0.contains("strip hold kept: the edit did not touch folded items") })
        #expect(!r.bar.lines.contains { $0.contains("strip hold cleared") })
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        // any further move is a drawn key's (no strip session: nothing was dispatched across the fold)
        let later = await moves136(r.actuator).dropFirst(before)
        #expect(later.allSatisfy { ![k("P1"), k("P2"), k("P3")].contains($0) })
    }

    @Test func anEditWithoutMovedKeysKeepsTheHoldToo() async {
        let r = await holdRig(failCalls: 10)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        _ = await r.engine.setLayout(Layout.placedAll(visible: [k("P1"), k("D1"), k("D2"), k("P2"), k("D3"), k("P3"), k("D4")]))
        #expect(await r.engine.stripOpenHold != nil)
    }

    @Test func anEditOfAFoldedKeyReleasesTheHold() async {
        let r = await holdRig(failCalls: 10)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        _ = await r.engine.setLayout(Layout.placedAll(visible: [k("D1"), k("P2"), k("D2"), k("P1"), k("D3"), k("P3"), k("D4")]), moved: [k("P2")])
        #expect(await r.engine.stripOpenHold == nil)
        #expect(r.bar.lines.contains { $0.contains("strip hold cleared (layout edit)") })
    }

    @Test func retryStillReleasesTheHold() async {
        let r = await holdRig(failCalls: 10)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        await r.engine.userRetry()
        #expect(await r.engine.stripOpenHold == nil)
    }
}
