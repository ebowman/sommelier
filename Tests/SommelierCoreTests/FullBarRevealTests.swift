import Testing
import Foundation
@testable import SommelierCore

// gdu.111: on a full bar (overflow chevron present) a reveal is panel-only: no shows are planned for hidden-listed keys.
private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private struct AllCaps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
}
private struct StaticObserver: MenuBarObserver {
    let chevron: Bool
    func observe() async throws -> [ResolvedItem] {
        var r = FakeMenuBar.resolved(onBar: [k("A"), k("B")], parked: [k("H1"), k("H2")])
        if chevron {
            let item = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: MenuBarItem.overflowChevronName, axDescription: MenuBarItem.overflowChevronName,
                                   axIdentifier: "", frame: CGRect(x: 400, y: 0, width: 24, height: 24), source: .appExtras, isOnMenuBar: true,
                                   isOverflowChevron: true, joinEvidence: .identifier)
            r.append(ResolvedItem(item: item, key: .module(name: MenuBarItem.overflowChevronName), confidence: .exact))
        }
        return r
    }
}
private final class Lines: @unchecked Sendable {
    private let l = NSLock(); private var v: [String] = []
    func add(_ s: String) { l.lock(); v.append(s); l.unlock() }
    var all: [String] { l.lock(); defer { l.unlock() }; return v }
}

@MainActor
private func rig(chevron: Bool, lines: Lines = Lines()) async -> (LayoutEngine, FakeActuator, EngineState) {
    let act = FakeActuator(order: [k("A"), k("B"), k("H1"), k("H2")], hidden: [k("H1"), k("H2")], capabilities: AllCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    var cfg = LayoutEngine.Config.plain()
    cfg.layoutCoalesce = .zero
    cfg.trackedAllowed = { _ in true }
    let state = EngineState()
    let layout = Layout(visible: [k("A"), k("B")], hidden: [k("H1"), k("H2")])
    let e = LayoutEngine(observer: StaticObserver(chevron: chevron), actuator: act, store: InMemoryLayoutStore(layout), capabilities: AllCaps(), state: state,
                         resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { lines.add($0) }, config: cfg)
    await e.start()
    return (e, act, state)
}

@MainActor
@Suite struct FullBarRevealTests {
    @Test func fullBarRevealPlansNoShowsAndSkipsWithTheBarFullReason() async {
        let lines = Lines()
        let (e, act, state) = await rig(chevron: true, lines: lines)
        await e.setShowHiddenSection(true)
        _ = await e.reconcileOnce()
        #expect(await act.calls.isEmpty)
        for h in [k("H1"), k("H2")] {
            if case .unsupported(let why)? = state.perItem[h] { #expect(why.hasPrefix("cannot be shown: the bar is full")) }
            else { Issue.record("expected the cannot-be-shown skip, got \(String(describing: state.perItem[h]))") }
        }
        #expect(ArrangeSections.revealSkipNotice(state: state) == "2 items could not be shown")
        #expect(lines.all.contains { $0.contains("reveal: bar is full (chevron): 2 hidden items stay in the panel, none shown") })
        #expect(!lines.all.contains { $0.contains("plan: phase=order") })
    }

    @Test func withoutTheChevronTheRevealShowsAsBefore() async {
        let (e, act, state) = await rig(chevron: false)
        await e.setShowHiddenSection(true)
        _ = await e.reconcileOnce()
        #expect(await act.hidden.isEmpty)
        #expect(!(await act.calls.isEmpty))
        #expect(ArrangeSections.revealSkipNotice(state: state) == nil)
    }

    @Test func fullBarWithoutARevealStillPlansNothingAndNoNotice() async {
        let (e, act, state) = await rig(chevron: true)
        _ = await e.reconcileOnce()
        #expect(await act.calls.isEmpty)
        #expect(ArrangeSections.revealSkipNotice(state: state) == nil)
    }
}
