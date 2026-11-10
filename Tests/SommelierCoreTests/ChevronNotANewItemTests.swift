import Testing
import Foundation
@testable import SommelierCore

// 9o9.21: after 9o9.14 strips the chevron from the record, the new-item policy must not see it as an unknown on-bar key.
private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private let chev = ItemKey.module(name: MenuBarItem.overflowChevronName)
private struct AllCaps: CapabilityProvider { func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) } }
private struct ChevObserver: MenuBarObserver {
    let bar: [ItemKey]; let flagged: Bool
    func observe() async throws -> [ResolvedItem] {
        var r = FakeMenuBar.resolved(onBar: bar)
        let item = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: MenuBarItem.overflowChevronName, axDescription: MenuBarItem.overflowChevronName,
                               axIdentifier: "", frame: CGRect(x: 60, y: 0, width: 24, height: 24), source: .appExtras, isOnMenuBar: true,
                               isOverflowChevron: flagged, joinEvidence: .identifier)
        r.append(ResolvedItem(item: item, key: chev, confidence: .exact))
        return r
    }
}
private final class Lines: @unchecked Sendable {
    private let l = NSLock(); private var v: [String] = []
    func add(_ s: String) { l.lock(); v.append(s); l.unlock() }
    var all: [String] { l.lock(); defer { l.unlock() }; return v }
}

@MainActor
private func rig(bar: [ItemKey], layout: Layout, flagged: Bool = true, lines: Lines) async -> (LayoutEngine, FakeActuator, EngineState, InMemoryLayoutStore) {
    let act = FakeActuator(order: bar, hidden: [], capabilities: AllCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    var cfg = LayoutEngine.Config.plain(); cfg.layoutCoalesce = .zero
    let state = EngineState(), store = InMemoryLayoutStore(layout)
    let e = LayoutEngine(observer: ChevObserver(bar: bar, flagged: flagged), actuator: act, store: store, capabilities: AllCaps(), state: state,
                         resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { lines.add($0) }, config: cfg)
    await e.start()
    return (e, act, state, store)
}

@MainActor
@Suite struct ChevronNotANewItemTests {
    private let caps: (ItemKey) -> Capability = { _ in Capability(canMove: true, canHide: true) }

    @Test(arguments: [NewItemPolicy.visibleAtEnd, .hidden])
    func plannerNeverTreatsTheChevronAsNew(policy: NewItemPolicy) {
        let layout = Layout(visible: [k("A"), k("B")], newItemPolicy: policy)
        for flagged in [true, false] {
            let obs = ObservedOrder(onBar: [chev, k("A"), k("B")], parked: [], overflowChevron: flagged ? chev : nil)
            let plan = Reconciler().plan(observed: obs, layout: layout, capabilities: caps)
            #expect(plan.newItems.isEmpty && plan.actions.isEmpty && plan.phase == .converged)
        }
    }

    @Test(arguments: [NewItemPolicy.visibleAtEnd, .hidden])
    func aParkedChevronIsSkippedNeitherShownNorNew(policy: NewItemPolicy) {
        let layout = Layout(visible: [k("A")], newItemPolicy: policy)
        for flagged in [true, false] {
            let obs = ObservedOrder(onBar: [k("A")], parked: [chev], overflowChevron: flagged ? chev : nil)
            let plan = Reconciler().plan(observed: obs, layout: layout, capabilities: caps)
            #expect(plan.newItems.isEmpty && plan.actions.isEmpty)
        }
    }

    @Test func aStaleKeyOnlyChevronIsNoFoldBoundaryAndPlansNoCrossing() {
        let layout = Layout(visible: [k("A"), k("X")])
        let obs = ObservedOrder(onBar: [chev, k("X"), k("A")], parked: [], systemOverflow: [k("X")], overflowChevron: nil)
        let plan = Reconciler().plan(observed: obs, layout: layout, capabilities: caps)
        #expect(plan.newItems.isEmpty)
        let touchesChevron = plan.actions.contains { String(describing: $0).contains(MenuBarItem.overflowChevronName) }
        #expect(!touchesChevron)
    }

    @Test func aRealNewItemBesideTheChevronIsStillPlacedPerPolicy() {
        for (policy, section) in [(NewItemPolicy.visibleAtEnd, LayoutSection.visible), (.hidden, .hidden)] {
            let layout = Layout(visible: [k("A")], newItemPolicy: policy)
            let obs = ObservedOrder(onBar: [chev, k("A"), k("N")], parked: [], overflowChevron: chev)
            let plan = Reconciler().plan(observed: obs, layout: layout, capabilities: caps)
            #expect(plan.newItems == [NewItem(k("N"), section)])
        }
    }

    @Test func enginePassWithChevronObservedAndNotRecordedPlacesNothingAndSaysNothing() async {
        let lines = Lines()
        let layout = Layout(visible: [k("A"), k("B")])
        let (e, act, state, store) = await rig(bar: [k("A"), k("B")], layout: layout, lines: lines)
        _ = await e.reconcileOnce()
        #expect(await act.calls.isEmpty)
        #expect(state.newItemNotice == nil)
        #expect(!lines.all.contains { $0.contains("New item") })
        let after = try? store.load()
        #expect(after?.visible == [k("A"), k("B")] && after?.visible.contains(chev) == false)
        #expect(after == layout)
        #expect(state.layout.visible == [k("A"), k("B")])
    }

    @Test func enginePassStillPlacesARealNewItemAndKeepsTheChevronOut() async {
        let lines = Lines()
        let (e, _, state, store) = await rig(bar: [k("A"), k("N")], layout: Layout(visible: [k("A")]), lines: lines)
        _ = await e.reconcileOnce()
        let after = try? store.load()
        #expect(after?.visible == [k("A"), k("N")])
        #expect(after?.keys(in: .visible).contains(chev) == false)
        #expect(state.newItemNotice != nil)
        #expect(lines.all.contains { $0.contains("New item") })
    }
}
