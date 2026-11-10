import Foundation
import Testing
@testable import SommelierCore

// 9o9.5: the Visible strip is the RECORD in record order; every row carries how the real bar stands against it. The status line
// never claims "Menu bar matches" when it doesn't.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private let clock = ItemKey.module(name: "Clock")
private let cc = ItemKey.module(name: "com.apple.menuextra.controlcenter")
private let chev = ItemKey.overflowChevron
private func caps(_ key: ItemKey) -> Capability {
    if case .module = key { return Capability(canMove: false, canHide: false, reason: "system module") }
    return Capability(canMove: true, canHide: true)
}
private func info(_ key: ItemKey) -> ItemInfo {
    ItemInfo(key: key, title: "", axDescription: "\(key)".split(separator: ":").last.map(String.init) ?? "", ownerPID: 1, ownerBundleID: "com.x",
             ownerName: "Owner", width: 30, isOnBar: true, systemOverflow: false)
}
private func make(_ o: ObservedOrder, _ layout: Layout, status: [ItemKey: ItemStatus] = [:], awaiting: Set<ItemKey> = [], suppressed: Set<ItemKey> = [],
                  timedOut: Set<ItemKey> = [], unverified: Set<ItemKey> = [], extra: [ItemKey] = []) -> ArrangeContent {
    ArrangeSections.make(observed: o, layout: layout, items: Dictionary(uniqueKeysWithValues: (o.onBar + o.parked + extra).map { ($0, info($0)) }),
                         perItem: status, capabilities: caps, awaiting: awaiting, timedOut: timedOut, suppressedStatus: suppressed,
                         unverifiedAfterHandDrag: unverified)
}
private func row(_ c: ArrangeContent, _ key: ItemKey) -> ArrangeRow { c.visible.rows.first { $0.key == key }! }
private func allInPlace(_ keys: [ItemKey]) -> [ItemKey: ItemStatus] { Dictionary(uniqueKeysWithValues: keys.map { ($0, ItemStatus.inPlace) }) }

@Suite struct ArrangeBarStateTests {
    // MARK: row order is the record

    @Test func rowOrderIsTheRecordRegardlessOfTheObservedOrder() {
        let rec = Layout(visible: [k("c"), k("a"), k("b"), cc, clock])
        for bar in [[k("a"), k("b"), k("c"), cc, clock], [k("b"), k("c"), k("a"), cc, clock], [clock, cc, k("c"), k("b"), k("a")]] {
            let c = make(ObservedOrder(onBar: bar, parked: []), rec, status: allInPlace(bar))
            #expect(c.visible.rows.map(\.key) == rec.visible)
        }
    }

    @Test func keysOnTheBarButNotInTheRecordAreNotVisibleRows() {
        let c = make(ObservedOrder(onBar: [k("a"), k("x"), clock], parked: []), Layout(visible: [k("a"), clock]))
        #expect(c.visible.rows.map(\.key) == [k("a"), clock])
    }

    // MARK: each barState -> badge and text

    @Test func matchesShowsTheCheck() {
        let bar = [k("a"), k("b"), clock]
        let c = make(ObservedOrder(onBar: bar, parked: []), Layout(visible: bar), status: allInPlace(bar))
        let r = row(c, k("a"))
        #expect(r.barState == .matches && r.badge == .inPlace && r.badge.glyph == "✓" && r.badgeTooltip == ArrangeBarState.matchesText)
        #expect(row(c, clock).badge == .none)       // anchors carry no tick
    }

    @Test func movingShowsArrowsOnlyOnKeysThePlannerWillDrag() {
        let bar = [k("a"), k("b"), clock]
        let c = make(ObservedOrder(onBar: bar, parked: []), Layout(visible: [k("b"), k("a"), clock]), status: [k("b"): .pending, k("a"): .inPlace])
        let r = row(c, k("b"))
        #expect(r.barState == .moving && r.badge == .moving && r.badge.glyph == "⟳" && r.badgeTooltip == ArrangeBarState.movingText)
        #expect(row(c, clock).barState != .moving)     // an anchor never shows arrows
    }

    @Test func cannotPlaceShowsTheWarningWithThePlainReason() {
        let bar = [k("a"), k("b"), k("c"), clock]
        let layout = Layout(visible: bar)
        let o = ObservedOrder(onBar: bar, parked: [])
        let f = make(o, layout, status: [k("a"): .failed(.mechanismFailed("drag did not start"))])
        #expect(row(f, k("a")).barState == .cannotPlace("drag did not start") && row(f, k("a")).badge == .cannotPlace("drag did not start"))
        #expect(row(f, k("a")).badge.glyph == "⚠" && row(f, k("a")).badgeTooltip == "drag did not start")
        // 9o9.29: only an uncorroborated key the record wants ELSEWHERE (neighbours disagree) is a warning after the minute.
        let o2 = ObservedOrder(onBar: [k("a"), k("c"), k("b"), clock], parked: [])
        let u = make(o2, layout, status: [k("b"): .unsupported("could not corroborate its position on the bar for 60 s: stale")])
        #expect(row(u, k("b")).barState == .cannotPlace("Sommelier can't pin down where this item is on the bar for a minute — right-click to try again"))
        let g = make(o, layout, status: [k("c"): .cannotPlace(reason: "moved 3 times in a minute", attempts: 3)])
        #expect(row(g, k("c")).barState == .cannotPlace("moved 3 times in a minute"))
        let t = make(o, layout, status: allInPlace(bar), timedOut: [k("a")])
        #expect(row(t, k("a")).barState == .cannotPlace(ArrangeTracker.timeoutText))
    }

    @Test func plainReasonsAreMappedAndOtherReasonsPassThrough() {
        #expect(ArrangeSections.plainReason(Reconciler.uncorroboratedSkipReason) == "Sommelier can't pin down where this item is on the bar")
        #expect(ArrangeSections.plainReason("could not corroborate its position on the bar for 60 s: x") == ArrangeSections.uncorroboratedTimeoutText)
        #expect(ArrangeSections.plainReason(Reconciler.staleSkipReason) == "Position being re-read")
        #expect(ArrangeSections.plainReason(Reconciler.overflowSkipReason) == "Behind «; macOS decides what fits")
        #expect(ArrangeSections.plainReason(SystemOverflowRule.churnSkipReason) == "Behind «; macOS decides what fits")
    }

    @Test func notOnBarIsAGhostAtItsRecordSlot() {
        let layout = Layout(visible: [k("a"), k("h"), k("b"), clock])
        let c = make(ObservedOrder(onBar: [k("a"), k("b"), clock], parked: [k("h")]), layout, status: [k("h"): .inPlace])   // the engine skipped it (e.g. hidden in Control Center)
        #expect(c.visible.rows.map(\.key) == [k("a"), k("h"), k("b"), clock])
        let r = row(c, k("h"))
        #expect(r.isGhost && r.barState == .notOnBar && r.badge == .ghost && r.badge.glyph == "◌" && r.badgeTooltip == ArrangeBarState.notOnBarText)
        // with a show planned it is moving, not a ghost claim
        let m = make(ObservedOrder(onBar: [k("a"), k("b"), clock], parked: [k("h")]), layout, status: [k("h"): .pending])
        #expect(row(m, k("h")).barState == .moving)
    }

    @Test func staleFrameShowsTildeAndPositionBeingReRead() {
        let bar = [k("a"), k("s"), k("b"), clock]
        let o = ObservedOrder(onBar: bar, parked: [], uncorroborated: [k("s")], staleOnBar: [k("s")])
        let c = make(o, Layout(visible: bar), status: allInPlace(bar))
        let r = row(c, k("s"))
        #expect(r.barState == .staleFrame && r.badge == .stale && r.badge.glyph == "~" && r.badgeTooltip == "Position being re-read" && r.draggable)
        // waiting for a corroborated read is the same state
        let w = make(ObservedOrder(onBar: bar, parked: []), Layout(visible: bar), status: [k("b"): .waitingForPosition("r")])
        #expect(row(w, k("b")).barState == .staleFrame)
    }

    @Test func behindChevronShowsTheOrangeChevronBadgeAndText() {
        let o = ObservedOrder(onBar: [k("p"), chev, k("a"), clock], parked: [], systemOverflow: [k("p")], overflowChevron: chev)
        let c = make(o, Layout(visible: [k("p"), k("a"), clock]), status: [k("p"): .notFitting, k("a"): .inPlace])
        let r = row(c, k("p"))
        #expect(r.barState == .behindChevron && r.badge == .behindChevron && r.badge.glyph == "«")
        #expect(r.badgeTooltip == ArrangeBarState.stayBehindText(r.title))   // gdu.144 rule 5: the row note is the drop warning's text
        #expect(r.badgeTooltip == "\(r.title) is in your order, but macOS folds from the left, so it stays behind « until there is room")
        #expect(r.draggable && !r.isBoundary)
    }

    @Test func unreadAfterHandDragShowsTheHourglassAndNeverTheCheck() {
        let bar = [k("a"), k("b"), clock]
        let c = make(ObservedOrder(onBar: bar, parked: []), Layout(visible: bar), status: allInPlace(bar), unverified: [k("b")])
        let r = row(c, k("b"))
        #expect(r.barState == .unreadAfterHandDrag && r.badge == .unreadAfterHandDrag && r.badge.glyph == "⏳")
        #expect(r.badgeTooltip == "Moved by you in the menu bar; waiting to read its new position")
        #expect(row(c, k("a")).badge == .inPlace)
    }

    // MARK: never a check for a held / unverified / unsupported row

    @Test func neverTheCheckForAHeldUnverifiedOrUnsupportedRow() {
        let bar = [k("a"), k("b"), k("c"), k("d"), clock]
        let layout = Layout(visible: bar)
        let o = ObservedOrder(onBar: bar, parked: [])
        let c = make(o, layout, status: [k("a"): .inPlace, k("b"): .unsupported("x"), k("c"): .cannotPlace(reason: "r", attempts: 3), k("d"): .inPlace],
                     unverified: [k("d")])
        #expect(row(c, k("a")).badge == .inPlace)
        for n in ["b", "c", "d"] { #expect(row(c, k(n)).badge != .inPlace && row(c, k(n)).badge != .inPlacePending, "\(n)") }
    }

    @Test func aMatchingRowStillHasNoCheckWithoutAnEngineStatus() {
        let bar = [k("a"), clock]
        let c = make(ObservedOrder(onBar: bar, parked: []), Layout(visible: bar))
        #expect(row(c, k("a")).badge == .none)
    }

    // MARK: the fold line

    @Test func theFoldLineSitsAfterTheLastOverflowedKeyInRecordOrder() {
        // record: p1 d1 p2 d2 -- the bar has p1 p2 behind « and d1 d2 drawn (d1 is out of fold order against the record)
        let o = ObservedOrder(onBar: [k("p1"), k("p2"), chev, k("d1"), k("d2"), clock], parked: [], systemOverflow: [k("p1"), k("p2")], overflowChevron: chev)
        let layout = Layout(visible: [k("p1"), k("d1"), k("p2"), k("d2"), clock])
        let c = make(o, layout, status: [k("p1"): .notFitting, k("p2"): .notFitting, k("d1"): .inPlace, k("d2"): .inPlace])
        #expect(c.visible.rows.map(\.key) == [k("p1"), k("d1"), k("p2"), chev, k("d2"), clock])
        #expect(c.visible.boundaryIndex == 3)
        // gdu.144: the drawn key the record places left of the line is NOT moving (the fold is macOS's decision); drawn order matches
        let d1 = row(c, k("d1"))
        #expect(d1.barState == .matches && d1.moveReason == nil)
        // the chevron is a fold line, never a capsule row
        #expect(c.visible.rows.filter(\.isBoundary).count == 1 && !c.visible.rows[3].draggable)
    }

    @Test func noFoldLineWithoutAnOverflowedRecordKeyOrWithAnOpenStrip() {
        let none = ObservedOrder(onBar: [k("a"), chev, k("b"), clock], parked: [], overflowChevron: chev)
        #expect(make(none, Layout(visible: [k("a"), k("b"), clock])).visible.boundaryIndex == nil)
        var open = ObservedOrder(onBar: [k("a"), chev, k("b"), clock], parked: [], systemOverflow: [k("a")], overflowChevron: chev)
        open.stripExpanded = true
        #expect(make(open, Layout(visible: [k("a"), k("b"), clock])).visible.boundaryIndex == nil)
    }

    @Test func aConsistentFoldMatchesAndOverflowedRowsAreNeverCannotPlace() {
        let o = ObservedOrder(onBar: [k("p"), chev, k("a"), clock], parked: [], systemOverflow: [k("p")], overflowChevron: chev)
        let c = make(o, Layout(visible: [k("p"), k("a"), clock]), status: [k("p"): .notFitting, k("a"): .inPlace])
        #expect(row(c, k("a")).barState == .matches && row(c, k("p")).barState == .behindChevron)
    }

    // MARK: drops

    private func rows(_ layout: Layout) -> [ArrangeRow] {
        make(ObservedOrder(onBar: layout.visible, parked: []), layout, status: allInPlace(layout.visible)).visible.rows
    }

    @Test func aDropInsideVisibleIsAcceptedWithoutAnObservation() {
        let layout = Layout(visible: [k("a"), k("b"), k("c"), clock])
        let r = rows(layout)
        let out = ArrangeDrop.drop(layout: layout, rows: r, slot: 0, key: k("c"), section: .visible, capabilities: caps, observationAvailable: false)
        guard case .move(let l, _, _) = out else { Issue.record("not a move: \(out)"); return }
        #expect(l.visible == [k("c"), k("a"), k("b"), clock])
    }

    @Test func aDropIntoTheSystemBlockIsRefusedWithTheCalloutText() {
        let layout = Layout(visible: [k("a"), k("b"), cc, clock])
        let r = rows(layout)
        #expect(ArrangeDrop.drop(layout: layout, rows: r, slot: 4, key: k("a"), section: .visible, capabilities: caps) == .rejected("macOS keeps the system items at the right end"))
        #expect(ArrangeDrop.systemItemsAtRightEnd == "macOS keeps the system items at the right end")
        let cb = RefusalCallout.show(nil, key: k("a"), why: ArrangeDrop.systemItemsAtRightEnd, now: Date())
        #expect(cb.text == "macOS keeps the system items at the right end" && RefusalCallout.anchor(for: k("a"), in: r) == k("a"))
    }

    @Test func aDropOntoTheItemsOwnSlotIsANoop() {
        let layout = Layout(visible: [k("a"), k("b"), k("c"), clock])
        let r = rows(layout)
        for slot in [1, 2] { #expect(ArrangeDrop.drop(layout: layout, rows: r, slot: slot, key: k("b"), section: .visible, capabilities: caps) == .noop, "slot \(slot)") }
    }

    @Test func aDropLeftOfTheFoldLineIsFlaggedAsStayingBehindTheChevron() {
        let o = ObservedOrder(onBar: [k("p"), chev, k("a"), k("b"), clock], parked: [], systemOverflow: [k("p")], overflowChevron: chev)
        let layout = Layout(visible: [k("p"), k("a"), k("b"), clock])
        let r = make(o, layout, status: [k("p"): .notFitting, k("a"): .inPlace, k("b"): .inPlace]).visible.rows
        guard case .move(let l, _, let willNotFit) = ArrangeDrop.drop(layout: layout, rows: r, slot: 0, key: k("b"), section: .visible, capabilities: caps) else { Issue.record("no move"); return }
        #expect(willNotFit && l.visible == [k("b"), k("p"), k("a"), clock])
        guard case .move(_, _, let right) = ArrangeDrop.drop(layout: layout, rows: r, slot: 4, key: k("a"), section: .visible, capabilities: caps) else { Issue.record("no move"); return }
        #expect(!right)
    }

    @Test func aStaleRowIsDraggableAndAnythingWithCanMoveIs() {
        let bar = [k("a"), k("s"), clock]
        let o = ObservedOrder(onBar: bar, parked: [], uncorroborated: [k("s")], staleOnBar: [k("s")])
        let c = make(o, Layout(visible: bar), status: allInPlace(bar))
        #expect(row(c, k("s")).draggable)
        #expect(ArrangeDrop.sourceRefusal(key: k("s"), fromGhost: false, rows: c.visible.rows) == nil)
        #expect(!row(c, clock).draggable)
    }

    @Test func moveLeftAndRightArePresentForEveryVisibleRowAndStepsNeedNoObservation() {
        #expect(ArrangeMenuRules.showsStepItems())
        let layout = Layout(visible: [k("a"), k("b"), clock])
        let r = rows(layout)
        guard case .move(let l, _, _) = ArrangeDrop.step(layout: layout, rows: r, key: k("a"), .right, capabilities: caps, observationAvailable: false) else { Issue.record("no step"); return }
        #expect(l.visible == [k("b"), k("a"), clock])
    }

    @Test func tryAgainAndWhyOnlyForTheRowsThatNeedThem() {
        let bar = [k("a"), k("b"), clock]
        let c = make(ObservedOrder(onBar: bar, parked: []), Layout(visible: bar), status: [k("a"): .unsupported("nope"), k("b"): .inPlace])
        #expect(ArrangeMenuRules.showsTryAgain(row(c, k("a"))) && !ArrangeMenuRules.showsTryAgain(row(c, k("b"))))
        #expect(ArrangeMenuRules.whyText(row(c, k("a"))) == "nope" && ArrangeMenuRules.whyText(row(c, k("b"))) == nil)
    }

    // MARK: the status line

    private let bar = [ItemKey.status(ownerKey: "com.x.a", autosaveName: "a"), ItemKey.status(ownerKey: "com.x.b", autosaveName: "b"), clock]
    private var good: ArrangeContent { make(ObservedOrder(onBar: bar, parked: []), Layout(visible: bar), status: allInPlace(bar)) }

    // MARK: the live shape (2026-11-07 build 282): Corsair unsupported while the bar does NOT match

    // MARK: 9o9.29 an in-place key the scan cannot corroborate is "can't be pinned down", not "can't be placed"

    // MARK: Arrange displays the engine's plan (it never re-derives it)

    // MARK: right after a drop the tracker speaks, then the engine takes over

    @Test func anUncorroboratedKeyNeverShowsTheCheck() {
        let a = k("a"), b = k("b"), c = k("c")
        let rec = Layout(visible: [a, b, c, clock])
        // neighbours disagree with the record
        let o1 = ObservedOrder(onBar: [b, a, c, clock], parked: [], uncorroborated: [a])
        let c1 = make(o1, rec, status: allInPlace([a, b, c, clock]))
        #expect(row(c1, a).badge.glyph == "~" && row(c1, a).barState != .matches)
        #expect(row(c1, a).badgeTooltip == "Sommelier can't pin down where this item is on the bar")
        // neighbours agree
        let o2 = ObservedOrder(onBar: [a, b, c, clock], parked: [], uncorroborated: [b])
        let c2 = make(o2, rec, status: allInPlace([a, b, c, clock]))
        #expect(row(c2, b).badge.glyph == "~" && row(c2, b).barState != .matches)
        #expect(row(c2, b).badgeTooltip == "Sommelier can't pin down where this item is on the bar (it looks in place)")
    }


    // MARK: 9o9.5 fourth corrective pass

    @Test func aBusySkippedPassDoesNotReleaseADroppedRow() {
        var t = ArrangeTracker()
        let a = k("a")
        t.record([a], passesStarted: 4, now: Date())
        // pass 5 started after the drop but was busy-skipped: passSequence advanced, no plan published (lastPlan still from pass 3)
        #expect(t.suppressed(passSequence: 5, planPass: 3) == [a])
        // pass 6 published a plan
        #expect(t.suppressed(passSequence: 6, planPass: 6).isEmpty)
        // without plan information the old rule applies
        #expect(t.suppressed(passSequence: 5).isEmpty)
        // update() does not judge on the busy-skipped pass either
        let o = ObservedOrder(onBar: [a], parked: [])
        _ = t.update(observed: o, layout: Layout(visible: [a]), perItem: [a: .failed(.timeout)], passSequence: 5, showHiddenSection: false, now: Date(), planPass: 3)
        #expect(t.awaiting == [a])
        _ = t.update(observed: o, layout: Layout(visible: [a]), perItem: [a: .failed(.timeout)], passSequence: 6, showHiddenSection: false, now: Date(), planPass: 6)
        #expect(t.awaiting.isEmpty)
    }

    // MARK: 9o9.24 wording follow-ups

    @Test func aStaleOrUncorroboratedPileKeyShowsTheChevronNotTheTilde() {
        let p1 = k("p1"), p2 = k("p2"), d = k("d")
        let rec = Layout(visible: [p1, p2, chev, d, clock])
        let stale = ObservedOrder(onBar: [p1, p2, chev, d, clock], parked: [], systemOverflow: [p1, p2], overflowChevron: chev,
                                  uncorroborated: [p2], staleOnBar: [p2])
        let c = make(stale, rec, status: [p1: .notFitting, p2: .notFitting, d: .inPlace, clock: .inPlace])
        #expect(row(c, p2).badge.glyph == "«" && row(c, p2).barState == .behindChevron)
        #expect(row(c, p2).badgeTooltip == ArrangeBarState.behindChevronText + "\nPosition being re-read")
        let unc = ObservedOrder(onBar: [p1, p2, chev, d, clock], parked: [], systemOverflow: [p1, p2], overflowChevron: chev, uncorroborated: [p2])
        let u = make(unc, rec, status: [p1: .notFitting, p2: .notFitting, d: .inPlace, clock: .inPlace])
        #expect(row(u, p2).badge.glyph == "«")
        #expect(row(u, p2).badgeTooltip == ArrangeBarState.behindChevronText + "\nSommelier can't pin down where this item is on the bar")
        #expect(row(u, p1).badgeTooltip == ArrangeBarState.stayBehindText(row(u, p1).title))   // gdu.144 rule 5
    }

    @Test func theNoSignGlyphMeansACapabilityLimitAndSaysSoInWords() {
        // Time Machine: a movable Apple item that cannot be HIDDEN by Sommelier
        let tm = ItemKey.status(ownerKey: "com.apple.systemuiserver", autosaveName: "com.apple.menuextra.TimeMachine")
        let cap = CapabilityRules(hasTrackedEntry: { _ in false }).capability(for: tm)
        #expect(cap.canMove && !cap.canHide)
        let o = ObservedOrder(onBar: [tm, clock], parked: [])
        let c = ArrangeSections.make(observed: o, layout: Layout(visible: [tm, clock]), items: [tm: info(tm)], perItem: [:],
                                     capabilities: { CapabilityRules(hasTrackedEntry: { _ in false }).capability(for: $0) })
        let r = row(c, tm)
        #expect(r.draggable)
        #expect(r.capabilityTooltip == "Can't be hidden by Sommelier: Apple apps are hidden only in System Settings > Menu Bar.")
    }
}
