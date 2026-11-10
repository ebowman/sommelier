import Testing
import Foundation
@testable import SommelierCore

// sommelier-gdu.44: hide-unit follow-ups.

private func s(_ owner: String, _ name: String) -> ItemKey { .status(ownerKey: owner, autosaveName: name) }
private func k(_ n: String) -> ItemKey { s("com.x.\(n)", n) }
private let wifi = ItemKey.module(name: "WiFi"), bento = ItemKey.module(name: "BentoBox"), clock = ItemKey.module(name: "Clock")
private func caps(_ key: ItemKey) -> Capability {
    if case .module = key { return Capability(canMove: false, canHide: false, reason: "system module") }
    return Capability(canMove: true, canHide: true)
}
private func obs(_ bar: [ItemKey], _ parked: [ItemKey] = []) -> ObservedOrder { ObservedOrder(onBar: bar, parked: parked) }
private let rec = Reconciler()

struct AbsentSiblingPlacementTests {
    private let a1 = s("com.app.a", "1"), a2 = s("com.app.a", "2"), b = k("b")

    @Test func newItemOfHiddenUnitJoinsHiddenEvenWhenListedSiblingIsAbsent() {
        // a1 is listed hidden but not observed; a2 is unknown. Without the sibling it would follow visibleAtEnd and split the unit.
        let layout = Layout(visible: [b], hidden: [a1], newItemPolicy: .visibleAtEnd)
        let p = rec.plan(observed: obs([b, a2]), layout: layout, capabilities: caps)
        #expect(p.newItems == [NewItem(a2, .hidden)])
        #expect(p.actions == [.hide(a2)])
        #expect(p.absent == [a1])
    }
    @Test func newItemOfAlwaysHiddenUnitJoinsAlwaysHiddenAndStaysPinned() {
        let layout = Layout(visible: [b], alwaysHidden: [a1])
        let p = rec.plan(observed: obs([b, a2]), layout: layout, capabilities: caps, showHiddenSection: true)
        #expect(p.newItems == [NewItem(a2, .alwaysHidden)])
        #expect(p.actions == [.hide(a2)])
    }
    @Test func parkedNewItemOfVisibleUnitIsShownDespiteHiddenPolicy() {
        let layout = Layout(visible: [b, a1], newItemPolicy: .hidden)
        let p = rec.plan(observed: obs([b], [a2]), layout: layout, capabilities: caps)
        #expect(p.newItems == [NewItem(a2, .visible)])
        #expect(p.actions == [.show(a2)])
    }
    @Test func wholeUnknownUnitStillFollowsPolicy() {
        let layout = Layout(visible: [b], newItemPolicy: .hidden)
        let p = rec.plan(observed: obs([b, a2]), layout: layout, capabilities: caps)
        #expect(p.newItems == [NewItem(a2, .hidden)])
        #expect(p.actions == [.hide(a2)])
    }
    @Test func appendingTheNewItemsNeverSplitsTheUnit() {
        let layout = Layout(visible: [b], hidden: [a1])
        let p = rec.plan(observed: obs([b, a2]), layout: layout, capabilities: caps)
        var l = layout
        for n in p.newItems { l.append(n.key, to: n.section) }
        let n = l.normalizedHideUnits()
        #expect(n.moved.isEmpty)
        #expect(l.hidden == [a1, a2])
    }
}

struct NormalizationReportingTests {
    private func r(_ key: ItemKey, x: CGFloat, onBar: Bool) -> ResolvedItem {
        ResolvedItem(item: MenuBarItem(ownerPID: 1, ownerBundleID: "com.x", ownerName: "X", title: "", axDescription: "",
                                       axIdentifier: "", frame: CGRect(x: x, y: 3, width: 24, height: 24),
                                       source: .appExtras, isOnMenuBar: onBar),
                     key: key, confidence: .exact)
    }
    @Test func builderNormalizesAndReportsASplitUnit() {
        let a1 = s("com.app.a", "1"), a2 = s("com.app.a", "2"), b = k("b")
        let res = [r(a1, x: 100, onBar: true), r(b, x: 130, onBar: true), r(a2, x: 2, onBar: false)]
        let out = LayoutBuilder.buildReportingNormalization(from: res)
        #expect(out.normalized == [a2])
        #expect(out.layout.visible == [a1, b, a2])
        #expect(out.layout.hidden.isEmpty)
        #expect(LayoutBuilder.build(from: res).layout == out.layout)
    }
    @Test func builderReportsNothingForAWholeUnit() {
        let a1 = s("com.app.a", "1"), a2 = s("com.app.a", "2")
        let out = LayoutBuilder.buildReportingNormalization(from: [r(a1, x: 2, onBar: false), r(a2, x: 3, onBar: false)])
        #expect(out.normalized.isEmpty)
        #expect(out.layout.hidden == [a1, a2])
    }
}

struct TrailingBlockHonestyTests {
    @Test func membershipPassShowLeftOfTheClockIsNotSkipped() {
        let layout = Layout(visible: [k("a"), k("b"), clock])
        let p = rec.plan(observed: obs([k("a"), clock], [k("b")]), layout: layout, capabilities: caps)
        #expect(p.phase == .membership)
        #expect(p.actions == [.show(k("b"))])
        #expect(p.skipped.isEmpty)
    }
    @Test func membershipPassWithoutABlockIsUnchanged() {
        let layout = Layout(visible: [k("a"), k("b")])
        let p = rec.plan(observed: obs([k("a")], [k("b")]), layout: layout, capabilities: caps)
        #expect(p.skipped.isEmpty)
    }
}

struct TransientAnchorSkipTests {
    private let layout = Layout(visible: [bento, wifi, k("p"), clock])
    @Test func membershipPhaseDoesNotReportAnchorsOutOfOrder() {
        let p = rec.plan(observed: obs([wifi, bento, clock], [k("p")]), layout: layout, capabilities: caps)
        #expect(p.phase == .membership)
        #expect(!p.skipped.contains { $0.reason == "immovable item is out of layout order" })
    }
}
