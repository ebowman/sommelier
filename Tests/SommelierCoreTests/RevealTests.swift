import Foundation
import Testing
@testable import SommelierCore

private func k(_ id: String) -> ItemKey { .status(ownerKey: "app.\(id)", autosaveName: id) }

private func obs(on: [ItemKey], parked: [ItemKey]) -> ObservedOrder { ObservedOrder(onBar: on, parked: parked) }

private func allCaps(_: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }

@Suite("Inline reveal: planner flags")
struct RevealPlannerTests {
    let v = k("v"), h1 = k("h1"), h2 = k("h2"), a = k("a")
    var layout: Layout { Layout(visible: [v], hidden: [h1, h2], alwaysHidden: [a]) }

    @Test func hiddenSectionShownAppendedInLayoutOrderAlwaysHiddenStays() {
        let p = Reconciler().plan(observed: obs(on: [v], parked: [h2, h1, a]), layout: layout, capabilities: allCaps, showHiddenSection: true)
        #expect(Set(p.actions.compactMap { if case .show(let x) = $0 { x } else { nil } }) == [h1, h2])
        #expect(p.desiredOnBar == [v, h1, h2])
    }

    @Test func alwaysHiddenOnlyWithSecondFlag() {
        let o = obs(on: [v], parked: [h1, h2, a])
        let only = Reconciler().plan(observed: o, layout: layout, capabilities: allCaps, showAlwaysHidden: true)
        #expect(only.desiredOnBar == [v, a])
        let both = Reconciler().plan(observed: o, layout: layout, capabilities: allCaps, showHiddenSection: true, showAlwaysHidden: true)
        #expect(both.desiredOnBar == [v, h1, h2, a])
        let none = Reconciler().plan(observed: o, layout: layout, capabilities: allCaps)
        #expect(none.desiredOnBar == [v])
    }

    @Test func clearingTheFlagsRehides() {
        let shown = obs(on: [v, h1, h2, a], parked: [])
        let on = Reconciler().plan(observed: shown, layout: layout, capabilities: allCaps, showHiddenSection: true, showAlwaysHidden: true)
        #expect(on.phase == .converged)
        let off = Reconciler().plan(observed: shown, layout: layout, capabilities: allCaps)
        #expect(Set(off.actions.compactMap { if case .hide(let x) = $0 { x } else { nil } }) == [h1, h2, a])
    }

    @Test func hideUnitsShowAndHideTogether() {
        // h1 and a belong to one app: alwaysHidden pins the unit while only the hidden section is revealed.
        let a1 = ItemKey.status(ownerKey: "app.h1", autosaveName: "second")
        let l = Layout(visible: [v], hidden: [h1], alwaysHidden: [a1])
        let o = obs(on: [v], parked: [h1, a1])
        let hid = Reconciler().plan(observed: o, layout: l, capabilities: allCaps, showHiddenSection: true)
        #expect(hid.desiredOnBar == [v])
        let both = Reconciler().plan(observed: o, layout: l, capabilities: allCaps, showAlwaysHidden: true)
        #expect(Set(both.desiredOnBar) == [v, h1, a1])
    }
}

@Suite("Inline reveal: untracked units")
struct RevealUntrackedTests {
    let v = k("v"), h1 = k("h1"), h2 = k("h2")
    func caps(_ key: ItemKey) -> Capability {
        key == h2 ? Capability(canMove: true, canHide: false, reason: "no Control Center entry") : Capability(canMove: true, canHide: true)
    }

    @Test func anUntrackedHiddenUnitIsSkippedAndTheOthersShow() {
        let l = Layout(visible: [v], hidden: [h1, h2])
        let p = Reconciler().plan(observed: obs(on: [v], parked: [h1, h2]), layout: l, capabilities: caps, showHiddenSection: true)
        #expect(p.actions.compactMap { if case .show(let x) = $0 { x } else { nil } } == [h1])
        #expect(p.skipped.map(\.key) == [h2])
        #expect(p.skipped.first?.reason == "cannot be shown: no Control Center entry")
        #expect(p.desiredOnBar == [v, h1])
        // After the show the plan is converged; the skip does not keep the reveal pending.
        let done = Reconciler().plan(observed: obs(on: [v, h1], parked: [h2]), layout: l, capabilities: caps, showHiddenSection: true)
        #expect(done.phase == .converged && done.actions.isEmpty)
    }

    @Test func aRevealOfOnlyUntrackedUnitsPlansNothing() {
        let l = Layout(visible: [v], hidden: [h2])
        let p = Reconciler().plan(observed: obs(on: [v], parked: [h2]), layout: l, capabilities: caps, showHiddenSection: true)
        #expect(p.phase == .converged && p.skipped.count == 1)
    }
}

@MainActor
@Suite("Inline reveal: click model")
struct RevealControllerTests {
    final class Clock { var t = ContinuousClock.now; func advance(_ ms: Int) { t = t.advanced(by: .milliseconds(ms)) } }

    @Test func clickRevealsThenRehidesAndDebounces() {
        let st = EngineState(); let clock = Clock()
        var calls: [[Bool]] = []
        let c = RevealController(state: st, apply: { h, a in calls.append([h, a]); st.showHiddenSection = h; st.showAlwaysHidden = a }, now: { clock.t })
        #expect(c.click(option: false) == .revealed(alwaysHidden: false))
        clock.advance(100)
        #expect(c.click(option: false) == .ignored)          // inside 300 ms: ignored
        clock.advance(300)
        #expect(c.click(option: false) == .rehidden)         // click while requested/revealed: immediate re-hide
        clock.advance(400)
        #expect(c.click(option: true) == .revealed(alwaysHidden: true))
        #expect(calls == [[true, false], [false, false], [true, true]])
    }

    @Test func iconStateFollowsObservationNotTheRequest() {
        let st = EngineState(); let clock = Clock()
        let c = RevealController(state: st, apply: { h, a in st.showHiddenSection = h; st.showAlwaysHidden = a }, now: { clock.t })
        c.click(option: false)
        #expect(c.requested && !st.revealedObserved)         // requested, not yet observed: icon stays hollow
        c.stateChanged()
        #expect(c.lastConvergeMillis == nil)
        clock.advance(850)
        st.revealedObserved = true                            // the engine's pass ended with the items on the bar
        c.stateChanged()
        #expect(c.lastConvergeMillis == 850)
    }

    @Test func withdrawingARevealSetsTheStatusNotice() {
        let st = EngineState(layout: Layout(visible: [k("v")], hidden: [k("a"), k("b")])); let clock = Clock()
        let c = RevealController(state: st, apply: { h, a in st.showHiddenSection = h; st.showAlwaysHidden = a }, now: { clock.t })
        c.click(option: false)
        c.withdraw(reason: "never converged")
        #expect(st.revealNotice == "Reveal withdrawn: 2 items could not be shown")
        #expect(!st.showHiddenSection)
        clock.advance(400)
        c.click(option: false)
        #expect(st.revealNotice == nil)
    }

    @Test func rehideIsNoOpWhenNothingRevealed() {
        let st = EngineState(); var n = 0
        let c = RevealController(state: st, apply: { _, _ in n += 1 })
        c.rehide(reason: "idle")
        #expect(n == 0)
        st.revealedObserved = true
        c.rehide(reason: "idle")
        #expect(n == 1)
    }
}

private struct RevealObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] {
        let order = await actuator.order, hidden = await actuator.hidden
        return FakeMenuBar.resolve(FakeMenuBar.snapshot(order: order, hidden: hidden))
    }
}

private struct RevealCaps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
}

@MainActor
@Suite("Inline reveal: engine state") struct RevealEngineTests {
    private func make(_ layout: Layout, order: [String]) -> (LayoutEngine, EngineState, FakeActuator) {
        let inner = FakeActuator(order: order.map(k), capabilities: RevealCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        let st = EngineState()
        let e = LayoutEngine(observer: RevealObserver(actuator: inner), actuator: inner, store: InMemoryLayoutStore(layout),
                             capabilities: RevealCaps(), state: st, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in })
        return (e, st, inner)
    }

    @Test func revealedIsSetOnlyAfterThePassConvergesAndClearsAfterRehide() async {
        let (e, st, inner) = make(Layout(visible: [k("A")], hidden: [k("B")], alwaysHidden: [k("C")]), order: ["A", "B", "C"])
        await e.start()
        _ = await e.reconcileOnce()                              // hides B and C
        #expect(await inner.hidden == [k("B"), k("C")])
        #expect(!st.revealedObserved)
        await e.setReveal(hidden: true, alwaysHidden: false)
        #expect(st.showHiddenSection && !st.revealedObserved)    // requested, not observed: no optimistic icon state
        let r = await e.reconcileOnce()
        #expect(r.outcome == .converged)
        #expect(st.revealedObserved)
        #expect(await inner.hidden == [k("C")])                  // always-hidden stays hidden
        await e.setReveal(hidden: true, alwaysHidden: true)
        _ = await e.reconcileOnce()
        #expect(await inner.hidden.isEmpty && st.showAlwaysHidden && st.revealedObserved)
        await e.setReveal(hidden: false, alwaysHidden: false)
        #expect(st.revealedObserved)                             // still observed as shown until the re-hide landed
        _ = await e.reconcileOnce()
        #expect(await inner.hidden == [k("B"), k("C")] && !st.revealedObserved)
    }

    @Test func aFailedRevealIsNeverReportedAsRevealed() async {
        let (e, st, inner) = make(Layout(visible: [k("A")], hidden: [k("B"), k("C")]), order: ["A", "B", "C"])
        await e.start()
        _ = await e.reconcileOnce()
        await e.setReveal(hidden: true, alwaysHidden: false)
        for n in 2...8 { await inner.failOnCall(n, .mechanismFailed("boom")) }   // every actuator call of the reveal pass fails
        _ = await e.reconcileOnce()
        #expect(!st.revealedObserved)                            // items still parked: the icon must not claim "shown"
        #expect(st.lastError != nil || st.perItem.values.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func anUntrackedHiddenKeyDoesNotBlockTheReveal() async {
        let caps = UntrackedCaps(bad: k("C"))
        let inner = FakeActuator(order: ["A", "B", "C"].map(k), hidden: [k("B"), k("C")], capabilities: caps, makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        let st = EngineState()
        let e = LayoutEngine(observer: RevealObserver(actuator: inner), actuator: inner,
                             store: InMemoryLayoutStore(Layout(visible: [k("A")], hidden: [k("B"), k("C")])),
                             capabilities: caps, state: st, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in })
        await e.start()
        await e.setReveal(hidden: true, alwaysHidden: false)
        let r = await e.reconcileOnce()
        #expect(r.outcome == .converged)
        #expect(await inner.hidden == [k("C")])                   // B shown, the untracked C stays parked
        #expect(st.revealedObserved)                              // partial = shown
        if case .unsupported(let why)? = st.perItem[k("C")] { #expect(why.contains("Control Center entry")) } else { Issue.record("C should be .unsupported") }
        #expect(st.lastError == nil)
    }
}

private struct UntrackedCaps: CapabilityProvider {
    let bad: ItemKey
    func capability(for key: ItemKey) -> Capability {
        key == bad ? Capability(canMove: true, canHide: false, reason: "no Control Center entry") : Capability(canMove: true, canHide: true)
    }
}
