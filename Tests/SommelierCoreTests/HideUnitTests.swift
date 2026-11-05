import Testing
import Foundation
import CoreGraphics
@testable import SommelierCore

private func s(_ owner: String, _ name: String) -> ItemKey { .status(ownerKey: owner, autosaveName: name) }
private let a1 = s("com.a", "1"), a2 = s("com.a", "2"), a3 = s("com.a", "3")
private let b1 = s("com.b", "1"), c1 = s("com.c", "1")
private let clock = ItemKey.module(name: "Clock"), wifi = ItemKey.module(name: "WiFi")
private func free(_: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
private let rec = Reconciler()

struct HideUnitTests {
    @Test func unitIdentity() {
        #expect(a1.hideUnit == a2.hideUnit)
        #expect(a1.hideUnit.id == "com.a")
        #expect(clock.hideUnit.id == "module:Clock")
        #expect(clock.hideUnit != wifi.hideUnit)
        #expect(ItemKey.heuristic(bundleID: "com.h", fingerprint: "f", ordinal: 0).hideUnit.id == "com.h")
    }

    @Test func groupingKeepsFirstSeenOrder() {
        let g = hideUnits([a1, b1, a2, clock, a3])
        #expect(g.map(\.unit.id) == ["com.a", "com.b", "module:Clock"])
        #expect(g[0].keys == [a1, a2, a3])
    }

    @Test func splitUnitNormalizesToVisible() {
        let l = Layout(visible: [a1, b1, clock], hidden: [c1, a2], alwaysHidden: [a3])
        let n = l.normalizedHideUnits()
        #expect(n.moved == [a2, a3])
        #expect(n.layout.visible == [a1, b1, a2, a3, clock])   // before the trailing system block
        #expect(n.layout.hidden == [c1]); #expect(n.layout.alwaysHidden.isEmpty)
        let v = l.validatedReportingNormalization()
        #expect(v.0 == n.layout); #expect(v.moved == n.moved); #expect(l.validated() == n.layout)
    }

    @Test func hiddenAndAlwaysHiddenSplitUntouched() {
        let l = Layout(visible: [b1], hidden: [a1], alwaysHidden: [a2])
        let n = l.normalizedHideUnits()
        #expect(n.moved.isEmpty); #expect(n.layout == l)
    }

    @Test func modulesAreIndependentUnits() {
        let l = Layout(visible: [wifi], hidden: [clock])
        #expect(l.normalizedHideUnits().moved.isEmpty)
    }

    @Test func decodeReportsNormalization() throws {
        let json = #"{"visible":["status:com.a::1"],"hidden":["status:com.a::2"]}"#
        let (l, w) = try Layout.decode(Data(json.utf8))
        #expect(l.visible == [a1, a2]); #expect(l.hidden.isEmpty)
        #expect(w.contains { $0.contains("hide units normalized") && $0.contains("status:com.a::2") })
    }

    @Test func moveBringsSiblingsAlong() {
        var l = Layout(visible: [a1, b1, a2, c1])
        let moved = l.move(a1, to: .hidden)
        #expect(moved == [a1, a2])
        #expect(l.hidden == [a1, a2]); #expect(l.visible == [b1, c1])
    }

    @Test func moveIndexPlacementAndOrder() {
        var l = Layout(visible: [b1], hidden: [c1, a2], alwaysHidden: [a3])
        let moved = l.move(a1, to: .hidden, index: 0)   // a1 is not in the layout yet; a2/a3 follow it
        #expect(moved == [a1, a2, a3])
        #expect(l.hidden == [a1, a2, a3, c1]); #expect(l.alwaysHidden.isEmpty)
        let back = l.move(a2, to: .visible, index: 0)
        #expect(back == [a2, a1, a3])
        #expect(l.visible == [a2, a1, a3, b1]); #expect(l.hidden == [c1])
    }

    @Test func moveSingleItemReturnsItself() {
        var l = Layout(visible: [a1, b1])
        #expect(l.move(b1, to: .hidden) == [b1])
    }

    @Test func overflowEntriesKeepUnitsAdjacent() {
        func info(_ k: ItemKey) -> ItemInfo {
            ItemInfo(key: k, title: "", axDescription: "\(k)", ownerPID: 1, ownerBundleID: "x", ownerName: "o", width: 30, isOnBar: false)
        }
        let l = Layout(hidden: [a1, b1, a2, c1])
        let e = OverflowEntries.make(layout: l, items: Dictionary(uniqueKeysWithValues: l.hidden.map { ($0, info($0)) }))
        #expect(e.map(\.key) == [a1, a2, b1, c1])
        #expect(e.map(\.unitSize) == [2, 2, 1, 1])
        #expect(e[0].unit == e[1].unit); #expect(e[1].unit != e[2].unit)
    }

    // MARK: Reconciler

    private func obs(_ bar: [ItemKey], _ parked: [ItemKey] = []) -> ObservedOrder { ObservedOrder(onBar: bar, parked: parked) }

    @Test func splitLayoutHidesNothingAndReports() {
        let p = rec.plan(observed: obs([a1, a2]), layout: Layout(visible: [a1], hidden: [a2]), capabilities: free)
        #expect(p.actions.isEmpty); #expect(p.phase == .converged)
        #expect(p.skipped.map(\.key) == [a2])
        #expect(p.skipped[0].reason == "hidden together with com.a: all items governed by one Control Center entry hide or show at once")
        #expect(p.desiredOnBar == [a1, a2])
    }

    @Test func wholeUnitHiddenIsOneMembershipPhase() {
        let p = rec.plan(observed: obs([a1, b1, a2]), layout: Layout(visible: [b1], hidden: [a1, a2]), capabilities: free)
        #expect(p.phase == .membership); #expect(p.actions == [.hide(a1), .hide(a2)])
    }

    @Test func showHiddenSectionShowsBoth() {
        let p = rec.plan(observed: obs([b1], [a1, a2]), layout: Layout(visible: [b1], hidden: [a1, a2]),
                         capabilities: free, showHiddenSection: true)
        #expect(p.actions == [.show(a1), .show(a2)])
    }

    @Test func unknownSiblingFollowsItsUnit() {
        // a2 is not in the layout; its sibling a1 is hidden -> a2 is hidden with it, and recorded as hidden.
        let p = rec.plan(observed: obs([a1, a2, b1]), layout: Layout(visible: [b1], hidden: [a1]), capabilities: free)
        #expect(p.actions == [.hide(a1), .hide(a2)]); #expect(p.newItems == [NewItem(a2, .hidden)])
    }

    @Test func unhideableSiblingBlocksTheWholeUnit() {
        let caps = { (k: ItemKey) in k == a2 ? Capability(canMove: true, canHide: false, reason: "system") : Capability(canMove: true, canHide: true) }
        let p = rec.plan(observed: obs([a1, a2]), layout: Layout(hidden: [a1, a2]), capabilities: caps)
        #expect(!p.actions.contains { if case .hide = $0 { true } else { false } })
        #expect(p.skipped.map(\.key).sorted { "\($0)" < "\($1)" } == [a1, a2])
    }

    @Test func alwaysHiddenSiblingKeepsUnitHiddenWhileRevealing() {
        let l = Layout(visible: [b1], hidden: [a1], alwaysHidden: [a2])
        let p = rec.plan(observed: obs([b1], [a1, a2]), layout: l, capabilities: free, showHiddenSection: true)
        #expect(!p.actions.contains { if case .show = $0 { true } else { false } })
        #expect(p.skipped.map(\.key) == [a1])
        #expect(p.skipped[0].reason == "kept hidden together with \(a2): an always-hidden item keeps its app hidden")
        // On the bar, the whole unit is hidden even though the hidden section is revealed.
        let q = rec.plan(observed: obs([b1, a1, a2]), layout: l, capabilities: free, showHiddenSection: true)
        #expect(q.actions == [.hide(a1), .hide(a2)])
    }

    @Test func pinnedHiddenEntriesAreMarked() {
        func info(_ k: ItemKey) -> ItemInfo {
            ItemInfo(key: k, title: "", axDescription: "\(k)", ownerPID: 1, ownerBundleID: "x", ownerName: "o", width: 30, isOnBar: false)
        }
        let l = Layout(hidden: [a1, b1], alwaysHidden: [a2])
        let items = [a1: info(a1), b1: info(b1), a2: info(a2)]
        let e = OverflowEntries.make(layout: l, items: items)
        #expect(e.map(\.key) == [a1, b1])
        #expect(e.map(\.pinnedHidden) == [true, false])
    }
}
