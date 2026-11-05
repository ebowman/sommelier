import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// Bead sommelier-gdu.75: a hide unit is a Control Center tracked ENTRY. A helper listed in its parent's `menuItemLocations`
// and the parent's own item form ONE unit for the planner, Layout, Arrange and the engine (the actuator groups the same way).
private typealias E = ControlCenterTrackedAppsStore.Entry
private let helperOwner = "86Z3GCJ4MF.com.noodlesoft.HazelHelper"
private let parentOwner = "com.noodlesoft.Hazel"
private let helper = ItemKey.status(ownerKey: helperOwner, autosaveName: "Item-0")
private let parent = ItemKey.status(ownerKey: parentOwner, autosaveName: "Item-0")
private let other = ItemKey.status(ownerKey: "com.other.app", autosaveName: "Item-0")
private let ord1 = ItemKey.status(ownerKey: "com.ordinary", autosaveName: "one"), ord2 = ItemKey.status(ownerKey: "com.ordinary", autosaveName: "two")
private let untracked1 = ItemKey.status(ownerKey: "com.untracked", autosaveName: "one"), untracked2 = ItemKey.status(ownerKey: "com.untracked", autosaveName: "two")
private let resolver = TrackedEntryResolver(entries: [
    E(key: parentOwner, isAllowed: true, menuItemKeys: [helperOwner, parentOwner]),
    E(key: "com.other.app", isAllowed: true, menuItemKeys: []),
    E(key: "com.ordinary", isAllowed: true, menuItemKeys: []),
])
private let rule = HideUnitRule(resolver: resolver)
private let free: @Sendable (ItemKey) -> Capability = { _ in Capability(canMove: true, canHide: true) }
private let clock = ItemKey.module(name: "Clock")

@Test func helperAndParentFormOneUnitIdentifiedByTheEntry() {
    #expect(rule.unit(of: helper) == rule.unit(of: parent))
    #expect(rule.unit(of: helper).id == parentOwner)
    #expect(rule.unit(of: other).id == "com.other.app")
    #expect(rule.unit(of: clock).id == "module:Clock")
    #expect(helper.hideUnit != parent.hideUnit)   // the owner-key fallback alone would split them
    #expect(hideUnits([helper, other, parent], rule: rule).map(\.keys) == [[helper, parent], [other]])
}

@Test func ordinaryAppsAndUntrackedKeysKeepTheOwnerKeyUnit() {
    #expect(rule.unit(of: ord1) == rule.unit(of: ord2))
    #expect(rule.unit(of: ord1).id == "com.ordinary")
    #expect(rule.unit(of: untracked1) == rule.unit(of: untracked2))
    #expect(rule.unit(of: untracked1).id == "com.untracked")
    #expect(HideUnitRule.ownerKeys.unit(of: helper).id == helperOwner)
    let g = hideUnits([ord1, other, ord2], rule: rule)
    #expect(g.map(\.keys) == [[ord1, ord2], [other]])
}

@Test func layoutMovesTheWholeEntryUnitFromEitherMember() {
    let l = Layout(visible: [other, helper, parent])
    for member in [helper, parent] {
        var m = l
        let moved = m.move(member, to: .hidden, units: rule)
        #expect(Set(moved) == [helper, parent] && moved.first == member)
        #expect(Set(m.hidden) == [helper, parent] && m.visible == [other])
    }
    var owner = l   // without the rule the helper moves alone (the pre-gdu.75 bug shape)
    #expect(owner.move(helper, to: .hidden) == [helper])
    // A split unit normalizes to visible.
    let split = Layout(visible: [parent, other], hidden: [helper])
    let n = split.normalizedHideUnits(units: rule)
    #expect(n.moved == [helper] && Set(n.layout.visible) == [parent, other, helper] && n.layout.hidden.isEmpty)
    #expect(split.normalizedHideUnits().moved.isEmpty)
}

@Test func plannerHidesTheUnitTogetherWhenTheLayoutHidesIt() {
    let l = Layout(visible: [other], hidden: [helper, parent])
    let p = Reconciler().plan(observed: ObservedOrder(onBar: [other, helper, parent], parked: []), layout: l, capabilities: free, units: rule)
    #expect(p.phase == .membership)
    #expect(p.actions.count == 2 && p.actions.contains(.hide(helper)) && p.actions.contains(.hide(parent)))
}

@Test func plannerNeverHidesOnlyTheHelperAndNamesTheUnit() {
    // A split layout (parent visible, helper hidden), as an older layout.json could hold: the unit stays visible; no hide at all.
    let l = Layout(visible: [other, parent], hidden: [helper])
    let p = Reconciler().plan(observed: ObservedOrder(onBar: [other, helper, parent], parked: []), layout: l, capabilities: free, units: rule)
    #expect(p.actions.allSatisfy { if case .hide = $0 { false } else { true } })
    #expect(p.skipped.map(\.key) == [helper])
    #expect(p.skipped[0].reason == "hidden together with \(parentOwner): all items governed by one Control Center entry hide or show at once")
    // The same layout under the owner-key rule would plan hide(helper): the loop shape this bead removes.
    let old = Reconciler().plan(observed: ObservedOrder(onBar: [other, helper, parent], parked: []), layout: l, capabilities: free)
    #expect(old.actions.contains(.hide(helper)))
}

@Test func plannerShowsTheWholeUnitWhenRevealing() {
    let l = Layout(visible: [other], hidden: [helper, parent])
    let p = Reconciler().plan(observed: ObservedOrder(onBar: [other], parked: [helper, parent]), layout: l, capabilities: free,
                              showHiddenSection: true, units: rule)
    #expect(p.actions.count == 2 && p.actions.contains(.show(helper)) && p.actions.contains(.show(parent)))
}

private func info(_ key: ItemKey, _ title: String) -> ItemInfo {
    ItemInfo(key: key, title: title, axDescription: title, ownerPID: 1, ownerBundleID: nil, ownerName: title, width: 30, isOnBar: true)
}

@Test func arrangeShowsTheUnitNoteAndADropMovesBothMembers() {
    let layout = Layout(visible: [other, helper, parent, clock])
    let items = [other: info(other, "Other"), helper: info(helper, "Hazel Helper"), parent: info(parent, "Hazel"), clock: info(clock, "Clock")]
    let c = ArrangeSections.make(observed: ObservedOrder(onBar: [other, helper, parent, clock], parked: []), layout: layout, items: items,
                                 perItem: [:], capabilities: free, units: rule)
    let h = c.visible.rows.first { $0.key == helper }!, p = c.visible.rows.first { $0.key == parent }!
    #expect(h.unit == p.unit)
    #expect(h.unitTooltip == "Hides together with Hazel")
    #expect(p.unitTooltip == "Hides together with Hazel Helper")
    #expect(c.visible.rows.first { $0.key == other }!.unitTooltip == nil)
    for member in [helper, parent] {
        guard case .move(let l, let moved, _) = ArrangeDrop.outcome(layout: layout, key: member, to: .hidden, index: nil, capabilities: free, units: rule)
        else { Issue.record("no move for \(member)"); continue }
        #expect(Set(moved) == [helper, parent])
        #expect(Set(l.hidden) == [helper, parent])
    }
    // Moving within Visible keeps the unit adjacent and does not treat the mate as a drop target.
    guard case .move(let l, _, _) = ArrangeDrop.outcome(layout: layout, key: helper, to: .visible, index: 0, capabilities: free, units: rule)
    else { Issue.record("no reorder"); return }
    #expect(l.visible == [helper, parent, other, clock])
}

@Test func overflowPanelGroupsTheUnitAndPinsItAsOne() {
    let layout = Layout(visible: [other], hidden: [helper], alwaysHidden: [parent])
    let items = [helper: info(helper, "Hazel Helper"), parent: info(parent, "Hazel")]
    let e = OverflowEntries.make(layout: layout, items: items, includeAlwaysHidden: true, units: rule)
    #expect(e.map(\.unitSize) == [2, 2])
    #expect(e[0].unit == e[1].unit)
    let pinned = OverflowEntries.make(layout: layout, items: items, units: rule)
    #expect(pinned.first { $0.key == helper }?.pinnedHidden == true)
}

private struct EntryActuatorObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] {
        let order = await actuator.order, hidden = await actuator.hidden
        return FakeMenuBar.resolve(FakeMenuBar.snapshot(order: order, hidden: hidden))
    }
}

@MainActor
@Test func engineAdoptsAndPublishesTheEntryRule() async {
    let order = [other, helper, parent]
    let act = FakeActuator(order: order, hidden: [], capabilities: CapabilityRules(hasTrackedEntry: { _ in true }),
                           makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let state = EngineState()
    var cfg = LayoutEngine.Config()
    cfg.trackedResolver = { resolver }
    let engine = LayoutEngine(observer: EntryActuatorObserver(actuator: act), actuator: act, store: InMemoryLayoutStore(Layout(visible: order)),
                              capabilities: CapabilityRules(hasTrackedEntry: { _ in true }), state: state,
                              resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, config: cfg)
    await engine.start()
    // A split unit (helper hidden alone) is normalized by the entry rule on adoption, and the state carries the rule.
    await engine.setLayout(Layout(visible: [other, parent], hidden: [helper]))
    #expect(state.lastNormalization == [helper])
    #expect(Set(state.layout.visible) == [other, parent, helper] && state.layout.hidden.isEmpty)
}
