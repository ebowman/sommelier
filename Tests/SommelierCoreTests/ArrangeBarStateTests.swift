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
/// What the engine would publish after planning `o` against `layout`: the REAL planner's partition (the tests never hand-write one).
private func summary(_ o: ObservedOrder, _ layout: Layout, held: Set<ItemKey> = [], unsteady: Set<ItemKey> = []) -> PlanSummary {
    PlanSummary(plan: Reconciler().plan(observed: o, layout: layout, capabilities: caps, held: held, unsteady: unsteady), held: held)
}
private func make(_ o: ObservedOrder, _ layout: Layout, status: [ItemKey: ItemStatus] = [:], awaiting: Set<ItemKey> = [], suppressed: Set<ItemKey> = [],
                  timedOut: Set<ItemKey> = [], unverified: Set<ItemKey> = [], extra: [ItemKey] = [], held: Set<ItemKey> = [],
                  unsteady: Set<ItemKey> = [], plan: PlanSummary? = nil) -> ArrangeContent {
    ArrangeSections.make(observed: o, layout: layout, items: Dictionary(uniqueKeysWithValues: (o.onBar + o.parked + extra).map { ($0, info($0)) }),
                         perItem: status, capabilities: caps, awaiting: awaiting, timedOut: timedOut, suppressedStatus: suppressed,
                         unverifiedAfterHandDrag: unverified,
                         lastPlan: plan ?? summary(o, layout, held: held.union(unverified), unsteady: unsteady))
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

    @Test func aSingleMisplacedKeyIsTheOnlyMovingRow() {
        let (a, b, cK, d, e) = (k("a"), k("b"), k("c"), k("d"), k("e"))
        let rec = Layout(visible: [a, b, cK, d, e, clock])
        let o = ObservedOrder(onBar: [a, cK, b, d, e, clock], parked: [])
        let st = allInPlace(o.onBar)
        let c = make(o, rec, status: st)
        // the planner plans exactly one move; the rows around it disagree with the record but are not planned: no check, no arrows
        let plan = Reconciler().plan(observed: o, layout: rec, capabilities: caps)
        #expect(plan.actions.count == 1)
        let moved: Set<ItemKey> = Set(plan.actions.compactMap { if case .move(let key, _) = $0 { key } else { nil } })
        let moving = Set(c.visible.rows.filter { $0.barState == .moving }.map(\.key))
        #expect(moving == moved && moving.count == 1)
        #expect(row(c, e).barState == .matches && row(c, clock).barState == .matches)      // their neighbours are the record's
        for key in [a, b, cK, d] where !moving.contains(key) { #expect(row(c, key).barState == .notConfirmed && row(c, key).badge != .inPlace, "\(key)") }
        let text = line(c, perItem: st)
        #expect(text.hasPrefix("Moving ") && !text.contains("6 items"))
    }

    @Test func cannotPlaceShowsTheWarningWithThePlainReason() {
        let bar = [k("a"), k("b"), k("c"), clock]
        let layout = Layout(visible: bar)
        let o = ObservedOrder(onBar: bar, parked: [])
        let f = make(o, layout, status: [k("a"): .failed(.mechanismFailed("drag did not start"))])
        #expect(row(f, k("a")).barState == .cannotPlace("drag did not start") && row(f, k("a")).badge == .cannotPlace("drag did not start"))
        #expect(row(f, k("a")).badge.glyph == "⚠" && row(f, k("a")).badgeTooltip == "drag did not start")
        let u = make(o, layout, status: [k("b"): .unsupported("could not corroborate its position on the bar for 60 s: stale")])
        #expect(row(u, k("b")).barState == .cannotPlace("Sommelier can't pin down where this item is on the bar for a minute — right-click to try again"))
        let g = make(o, layout, status: [k("c"): .cannotPlace(reason: "moved 3 times in a minute", attempts: 3)])
        #expect(row(g, k("c")).barState == .cannotPlace("moved 3 times in a minute"))
        let t = make(o, layout, status: allInPlace(bar), timedOut: [k("a")])
        #expect(row(t, k("a")).barState == .cannotPlace(ArrangeTracker.timeoutText))
    }

    @Test func plainReasonsAreMappedAndOtherReasonsPassThrough() {
        #expect(ArrangeSections.plainReason(Reconciler.uncorroboratedSkipReason) == "Sommelier can't pin down where this item is on the bar")
        #expect(ArrangeSections.plainReason("could not corroborate its position on the bar for 60 s: x") == ArrangeSections.uncorroboratedTimeoutText)
        #expect(ArrangeSections.plainReason(Reconciler.staleFrameSkipReason) == "Position being re-read")
        #expect(ArrangeSections.plainReason(Reconciler.staleSkipReason) == "Position being re-read")
        #expect(ArrangeSections.plainReason(Reconciler.noCrossingSkipReason) == "Behind «; the item it should follow can't be located on the bar yet")
        #expect(ArrangeSections.plainReason(Reconciler.noCrossingOwnPositionSkipReason) == "Behind «; its position hasn't been read yet")
        #expect(ArrangeSections.plainReason(Reconciler.overflowSkipReason) == "Behind «; macOS decides what fits")
        #expect(ArrangeSections.plainReason(SystemOverflowRule.churnSkipReason) == "Behind «; macOS decides what fits")
    }

    @Test func notOnBarIsAGhostAtItsRecordSlot() {
        let layout = Layout(visible: [k("a"), k("h"), k("b"), clock])
        let c = make(ObservedOrder(onBar: [k("a"), k("b"), clock], parked: [k("h")]), layout, status: [k("h"): .inPlace], plan: PlanSummary())   // the engine skipped it (e.g. hidden in Control Center)
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
        #expect(r.badgeTooltip == "Behind «: macOS hides it because the bar is full. Drag it right of the fold line to bring it out.")
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
        let c = make(o, layout, status: [k("p1"): .notFitting, k("p2"): .pending, k("d1"): .pending, k("d2"): .inPlace])
        #expect(c.visible.rows.map(\.key) == [k("p1"), k("d1"), k("p2"), chev, k("d2"), clock])
        #expect(c.visible.boundaryIndex == 3)
        // the drawn key the record places left of the line is moving: it will go behind «
        let d1 = row(c, k("d1"))
        #expect(d1.barState == .moving && d1.badge == .moving && d1.badgeTooltip == "It will go behind « when the engine moves it")
        #expect(d1.moveReason == ArrangeBarState.willGoBehindText)
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

    private func line(_ c: ArrangeContent?, perItem: [ItemKey: ItemStatus] = [:], converged: Bool = true, inFlight: Bool = false, err: EngineError? = nil,
                      settled: Bool = true, awaiting: Int = 0, ctx: ArrangeSections.StatusContext = .init()) -> String {
        ArrangeSections.statusLine(perItem: perItem, lastError: err, isConverged: converged, inFlight: inFlight, pendingAwaiting: awaiting,
                                   observationSettled: settled, content: c, context: ctx)
    }
    private let bar = [ItemKey.status(ownerKey: "com.x.a", autosaveName: "a"), ItemKey.status(ownerKey: "com.x.b", autosaveName: "b"), clock]
    private var good: ArrangeContent { make(ObservedOrder(onBar: bar, parked: []), Layout(visible: bar), status: allInPlace(bar)) }

    @Test func menuBarMatchesOnlyWhenEveryRowMatches() {
        #expect(line(good, perItem: allInPlace(bar)) == "Menu bar matches")
        #expect(line(good, converged: false) == "Working…")
        #expect(line(good, settled: false) == "Observing (unsettled)")
        #expect(line(nil) == ArrangeSections.checkingMenuBar)
        // behind « and not-on-bar rows still count as matching
        let o = ObservedOrder(onBar: [k("p"), chev, k("a"), clock], parked: [k("h")], systemOverflow: [k("p")], overflowChevron: chev)
        let c = make(o, Layout(visible: [k("p"), k("h"), k("a"), clock]), status: [k("p"): .notFitting, k("a"): .inPlace, k("h"): .inPlace], plan: PlanSummary())
        #expect(line(c) == "Menu bar matches")
        // an error is never "matches"
        #expect(line(good, err: .observe("boom")) == "Error: boom")
    }

    @Test func movingWhileAMoveIsInFlightOrPlanned() {
        let o = ObservedOrder(onBar: bar, parked: []), rec = Layout(visible: [bar[1], bar[0], clock])
        let mover = summary(o, rec).moving.first!
        let c = make(o, rec, status: [mover: .pending])
        #expect(line(c, perItem: [mover: .pending], converged: false) == "Moving \(row(c, mover).title)…")
        var ctx = ArrangeSections.StatusContext(); ctx.movingName = "Shield"
        #expect(line(c, converged: false, inFlight: true, ctx: ctx) == "Moving Shield…")
        #expect(line(good, inFlight: true) == "Moving…")
        #expect(line(good, awaiting: 2) == "Moving…")
    }

    @Test func cannotPlaceCountsAndPluralises() {
        let one = make(ObservedOrder(onBar: bar, parked: []), Layout(visible: bar), status: [bar[0]: .unsupported("x"), bar[1]: .inPlace])
        #expect(line(one) == "1 item can't be placed — right-click one for why")
        let two = make(ObservedOrder(onBar: bar, parked: []), Layout(visible: bar), status: [bar[0]: .unsupported("x"), bar[1]: .failed(.timeout)])
        #expect(line(two) == "2 items can't be placed — right-click one for why")
    }

    @Test func waitingToReadCountsStaleAndHandDraggedRows() {
        let o = ObservedOrder(onBar: bar, parked: [], uncorroborated: [bar[0]], staleOnBar: [bar[0]])
        let c = make(o, Layout(visible: bar), status: allInPlace(bar), unverified: [bar[1]])
        #expect(line(c) == "Waiting to read 2 items")
        let c1 = make(o, Layout(visible: bar), status: allInPlace(bar))
        #expect(line(c1) == "Waiting to read 1 item")
    }

    @Test func pausedAndCapAndAdoptionAndHandDragTexts() {
        var ctx = ArrangeSections.StatusContext(); ctx.userPaused = true
        #expect(line(good, ctx: ctx) == "Paused")
        ctx = .init(); ctx.pauseReason = "a menu is open"
        #expect(line(good, ctx: ctx) == "Paused: a menu is open")
        ctx = .init(); ctx.orderCapActive = true
        #expect(line(good, ctx: ctx) == "Pausing order moves for a minute")
        ctx = .init(); ctx.adoptionPending = true
        #expect(line(good, ctx: ctx) == "Reading your menu bar order…")
        ctx = .init(); ctx.handDragNotice = "Adopted your menu bar drag"
        #expect(line(good, ctx: ctx) == "Adopted your menu bar drag")
    }

    @Test func precedenceIsPausedThenCannotPlaceThenMovingThenWaitingThenAdoptedThenMatches() {
        let o = ObservedOrder(onBar: bar, parked: [], uncorroborated: [bar[0]], staleOnBar: [bar[0]])
        let all = make(o, Layout(visible: [bar[1], bar[0], clock]), status: [bar[1]: .unsupported("x"), bar[0]: .pending])      // cannotPlace + moving + (stale)
        var ctx = ArrangeSections.StatusContext(); ctx.handDragNotice = "Adopted your menu bar drag"
        #expect(line(all, perItem: [bar[0]: .pending], converged: false, ctx: ctx) == "1 item can't be placed — right-click one for why")
        ctx.userPaused = true
        #expect(line(all, converged: false, ctx: ctx) == "Paused")
        let moving = make(ObservedOrder(onBar: bar, parked: []), Layout(visible: [bar[1], bar[0], clock]), status: [bar[1]: .pending])
        ctx = .init(); ctx.handDragNotice = "Adopted your menu bar drag"
        #expect(line(moving, converged: false, ctx: ctx).hasPrefix("Moving"))
        let waiting = make(o, Layout(visible: bar), status: allInPlace(bar))
        #expect(line(waiting, ctx: ctx) == "Waiting to read 1 item")
        #expect(line(good, ctx: ctx) == "Adopted your menu bar drag")
        #expect(line(good) == "Menu bar matches")
    }

    @Test func aPrefixNoticeAndThePollPauseStillCompose() {
        let s = ArrangeSections.statusLine(perItem: [:], lastError: nil, isConverged: true, inFlight: false, notice: "New item: X placed in Visible",
                                           pollPausedNames: ["Y"], content: good)
        #expect(s == "New item: X placed in Visible · Menu bar matches · Poll paused 5 min: Y flapping")
    }

    // MARK: the live shape (2026-11-07 build 282): Corsair unsupported while the bar does NOT match

    @Test func theLiveCorsairShapeSaysOneItemCannotBePlacedNeverMatches() {
        let shield = k("shield"), corsair = k("corsair"), mcp = k("mcp")
        // record: Shield Corsair MCP; the bar still has Corsair elsewhere
        let layout = Layout(visible: [shield, corsair, mcp, clock])
        let o = ObservedOrder(onBar: [corsair, shield, mcp, clock], parked: [])
        let st: [ItemKey: ItemStatus] = [shield: .inPlace, mcp: .inPlace, clock: .inPlace,
                                         corsair: .unsupported("could not corroborate its position on the bar for 60 s: " + Reconciler.uncorroboratedSkipReason)]
        let c = make(o, layout, status: st)
        let r = row(c, corsair)
        #expect(r.barState == .cannotPlace(ArrangeSections.uncorroboratedTimeoutText) && r.badge.glyph == "⚠")
        #expect(r.badge != .inPlace)
        let text = line(c, perItem: st)
        #expect(text == "1 item can't be placed — right-click one for why")
        #expect(!text.contains("matches"))
        // the rows the planner keeps in place show the check
        for key in [shield, mcp, clock] { #expect(row(c, key).badge != .inPlace || row(c, key).barState == .matches) }
        #expect(ArrangeMenuRules.showsTryAgain(r))
    }

    @Test func aHeldKeyOutOfOrderLeavesItsNeighbourWithTheCheck() {
        let a = k("a"), b = k("b"), c = k("c"), d = k("d")
        let rec = Layout(visible: [a, b, c, d, clock])
        let o = ObservedOrder(onBar: [a, c, b, d, clock], parked: [])
        let sum = summary(o, rec, held: [b])
        #expect(sum.moving.isEmpty && sum.held == [b])
        let st: [ItemKey: ItemStatus] = [a: .inPlace, c: .inPlace, d: .inPlace, b: .cannotPlace(reason: "gave up", attempts: 3)]
        let cnt = make(o, rec, status: st, plan: sum)
        #expect(row(cnt, c).barState == .matches && row(cnt, c).badge == .inPlace)
        #expect(row(cnt, b).badge.glyph == "⚠")
    }

    @Test func aKeyBothGivenUpAndFailedAtTheLimitShowsWarningAndItsNeighbourStillGetsTheCheck() {
        let a = k("a"), b = k("b"), c = k("c"), d = k("d")
        let rec = Layout(visible: [a, b, c, d, clock])
        let o = ObservedOrder(onBar: [a, c, b, d, clock], parked: [])
        let sum = summary(o, rec, held: [b])
        let st: [ItemKey: ItemStatus] = [a: .inPlace, c: .inPlace, d: .inPlace, b: .failed(.timeout)]
        let cnt = make(o, rec, status: st, plan: sum)
        #expect(row(cnt, b).badge.glyph == "⚠")
        #expect(row(cnt, c).barState == .matches && row(cnt, c).badge == .inPlace)      // not a stuck arrows row
        #expect(!cnt.visible.rows.contains { $0.barState == .moving })
        #expect(line(cnt, perItem: st) == "1 item can't be placed — right-click one for why")
    }

    // MARK: Arrange displays the engine's plan (it never re-derives it)

    @Test func theEngineMovesOneKeyAndOnlyThatRowShowsArrows() {
        let (a, b, cK, d, e) = (k("a"), k("b"), k("c"), k("d"), k("e"))
        let rec = Layout(visible: [a, b, cK, d, e, clock])
        let o = ObservedOrder(onBar: [a, cK, b, d, e, clock], parked: [])
        let sum = summary(o, rec)
        #expect(sum.moving.count == 1)
        var st = allInPlace(o.onBar)
        for key in sum.moving { st[key] = .pending }
        let c = make(o, rec, status: st, plan: sum)
        #expect(Set(c.visible.rows.filter { $0.barState == .moving }.map(\.key)) == sum.moving)
        let text = line(c, perItem: st)
        #expect(text == "Moving \(row(c, sum.moving.first!).title)…")
    }

    @Test func aWallOfAnUncorroboratedKeyShowsWaitingForItToSettleNeverMoving() {
        // record p0 p1 p2 p3 Clock, bar p3 p2 p1 p0 Clock, p3 uncorroborated: the engine plans nothing and skips only p3.
        let ks = (0..<4).map { k("p\($0)") }
        let rec = Layout(visible: ks + [clock])
        let o = ObservedOrder(onBar: [ks[3], ks[2], ks[1], ks[0], clock], parked: [], uncorroborated: [ks[3]])
        let plan = Reconciler().plan(observed: o, layout: rec, capabilities: caps)
        #expect(plan.actions.isEmpty)
        let sum = summary(o, rec)
        #expect(sum.moving.isEmpty)
        #expect(Set(sum.blocked.keys) == [ks[0], ks[1], ks[2]] && Set(sum.blocked.values) == [ks[3]])
        var st = allInPlace(o.onBar)
        st[ks[3]] = .waitingForPosition(Reconciler.uncorroboratedSkipReason)
        let c = make(o, rec, status: st, plan: sum)
        let wall = row(c, ks[3]).title
        for key in ks[0..<3] {
            #expect(row(c, key).barState == .moving && row(c, key).badge.glyph == "⟳", "\(key)")
            #expect(row(c, key).badgeTooltip == "Waiting for \(wall) to settle")
        }
        #expect(row(c, ks[3]).badge.glyph == "~")
        let text = line(c, perItem: st)
        #expect(!text.contains("Moving") && text == "Waiting to read 1 item")
    }

    @Test func aMovingNeighbourHoldIsWaitingNotReRead() {
        let a = k("a"), b = k("b")
        let rec = Layout(visible: [b, a, clock])
        let o = ObservedOrder(onBar: [a, b, clock], parked: [], uncorroborated: [a])
        let sum = summary(o, rec, unsteady: [a])
        #expect(sum.blocked[b] == a)
        let r = row(make(o, rec, status: [b: .waitingForPosition("r"), a: .waitingForPosition("r")], plan: sum), b)
        #expect(r.barState == .moving && r.badge.glyph == "⟳")
        #expect(r.badgeTooltip == "Waiting for \(OverflowEntries.displayName(info(a))) to settle")
        #expect(r.badgeTooltip != ArrangeBarState.staleText)
    }

    @Test func aRowNeitherPlannedNorAgreeingWithTheRecordIsNeverTheCheck() {
        // The engine moves c (or b); the other one disagrees with the record but is not planned: no check, no arrows.
        let (a, b, cK, d) = (k("a"), k("b"), k("c"), k("d"))
        let rec = Layout(visible: [a, b, cK, d, clock])
        let o = ObservedOrder(onBar: [a, cK, b, d, clock], parked: [])
        let sum = summary(o, rec)
        let c = make(o, rec, status: allInPlace(o.onBar), plan: sum)
        for key in [a, b, cK, d] where !sum.moving.contains(key) && row(c, key).barState != .matches {
            #expect(row(c, key).badge.glyph != "✓" && row(c, key).barState == .notConfirmed)
        }
        #expect(c.visible.rows.filter { $0.barState == .moving }.count == 1)
    }

    // MARK: right after a drop the tracker speaks, then the engine takes over

    @Test func afterADropTheDroppedKeyShowsArrowsFromTheTrackerThenTheEngineTakesOver() {
        let a = k("a"), b = k("b"), c = k("c")
        let bar = [a, b, c, clock]
        let o = ObservedOrder(onBar: bar, parked: [])
        let old = Layout(visible: bar), new = Layout(visible: [c, a, b, clock])
        // before any pass: the last plan is the old one (empty); the tracker marks c
        let oldPlan = summary(o, old)
        let during = make(o, new, status: allInPlace(bar), awaiting: [c], suppressed: [c], plan: oldPlan)
        #expect(row(during, c).barState == .moving && row(during, c).badge.glyph == "⟳")
        #expect(row(during, a).badge == .none || row(during, a).barState != .moving)
        #expect(!during.visible.rows.contains { $0.barState == .moving && $0.key != c })
        // a pass has judged it: the engine's partition (c moves) is shown, not the tracker's
        let newPlan = summary(o, new)
        var st = allInPlace(bar); for key in newPlan.moving { st[key] = .pending }
        let after = make(o, new, status: st, awaiting: [c], suppressed: [], plan: newPlan)
        #expect(Set(after.visible.rows.filter { $0.barState == .moving }.map(\.key)) == newPlan.moving)
        // and when the engine judged it already in place the awaiting key is not shown moving on the tracker's word
        let settled = make(o, old, status: allInPlace(bar), awaiting: [c], suppressed: [], plan: oldPlan)
        #expect(row(settled, c).barState == .matches)
    }

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

    @Test func aWallThatIsGivenUpMakesTheBlockedRowAWarningNotAWait() {
        let ks = (0..<5).map { k("p\($0)") }
        let rec = Layout(visible: ks + [clock])
        let o = ObservedOrder(onBar: [ks[1], ks[2], ks[0], ks[3], ks[4], clock], parked: [])
        let status: [ItemKey: ItemStatus] = [ks[2]: .cannotPlace(reason: "tried", attempts: 3)]
        let plan = summary(o, rec, held: [ks[2]])
        let c = make(o, rec, status: status, plan: plan)
        let blocked = plan.blocked.filter { $0.value == ks[2] }.keys
        #expect(!blocked.isEmpty)
        let name = OverflowEntries.displayName(info(ks[2]))
        for key in blocked {
            #expect(row(c, key).badge.glyph == "⚠" && row(c, key).barState == .cannotPlace(ArrangeSections.blockedByGivenUpText(name)))
            #expect(row(c, key).badgeTooltip == "Blocked by \(name), which Sommelier can't place — right-click it to try again")
        }
        #expect(row(c, ks[2]).badge.glyph == "⚠")
        let n = blocked.count + 1
        #expect(ArrangeSections.statusLine(perItem: status, lastError: nil, isConverged: true, inFlight: false, content: c) == "\(n) items can't be placed — right-click one for why")
    }

    @Test func aWallThatIsOnlyUnverifiedAfterAHandDragStillWaits() {
        let ks = (0..<5).map { k("p\($0)") }
        let rec = Layout(visible: ks + [clock])
        let o = ObservedOrder(onBar: [ks[1], ks[2], ks[0], ks[3], ks[4], clock], parked: [])
        let plan = summary(o, rec, held: [ks[2]])
        let c = make(o, rec, plan: plan)
        for key in plan.blocked.filter({ $0.value == ks[2] }).keys { #expect(row(c, key).badge.glyph == "⟳" && row(c, key).waitingOn != nil) }
    }

    @Test func aBlockedKeyWithNoWallWaitsForTheBarAndIsNotCountedAsUnread() {
        let ks = (0..<5).map { k("p\($0)") }
        let rec = Layout(visible: ks + [clock])
        let o = ObservedOrder(onBar: [ks[1], ks[3], ks[4], ks[2], ks[0], clock], parked: [], uncorroborated: [ks[0], ks[4]])
        let plan = summary(o, rec)
        #expect(plan.blockedNoWall.contains(ks[2]))
        let status: [ItemKey: ItemStatus] = [ks[0]: .waitingForPosition("x"), ks[4]: .waitingForPosition("x"), ks[2]: .waitingForPosition(Reconciler.noSafeMoveSkipReason)]
        let c = make(o, rec, status: status, plan: plan)
        let r = row(c, ks[2])
        #expect(r.badge.glyph == "⟳" && r.badgeTooltip == "Waiting for the bar to settle" && r.badge != .stale)
        #expect(ArrangeSections.statusLine(perItem: status, lastError: nil, isConverged: true, inFlight: false, content: c) == "Waiting to read 2 items")
    }

    @Test func theReconcilerGivesNoWallBlockedKeysTheHonestSkipReason() {
        let ks = (0..<5).map { k("p\($0)") }
        let o = ObservedOrder(onBar: [ks[1], ks[3], ks[4], ks[2], ks[0], clock], parked: [], uncorroborated: [ks[0], ks[4]])
        let p = Reconciler().plan(observed: o, layout: Layout(visible: ks + [clock]), capabilities: caps)
        #expect(p.skipped.first { $0.key == ks[2] }?.reason == "no safe move this pass; waiting for the bar to settle")
    }

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

    @Test func aBlankRowCarriesTheNotConfirmedTooltipAndStatusNeverSaysConverged() {
        let a = k("a"), b = k("b")
        let o = ObservedOrder(onBar: [b, a, clock], parked: [])
        let rec = Layout(visible: [a, b, clock])
        let c = make(o, rec, status: allInPlace([a, b, clock]), plan: PlanSummary(held: [a]))
        let blank = c.visible.rows.filter { $0.barState == .notConfirmed }
        #expect(!blank.isEmpty)
        for r in blank { #expect(r.badge == .none && ArrangeMenuRules.whyText(r) == ArrangeBarState.notConfirmedText) }
        let text = ArrangeSections.statusLine(perItem: allInPlace([a, b, clock]), lastError: nil, isConverged: true, inFlight: false, content: c)
        #expect(text != "Converged" && text == ArrangeSections.checkingMenuBar)
    }

    // MARK: 9o9.24 wording follow-ups

    @Test func theNoSafeMoveTimeoutReadsNoSafeMoveWithTryAgainNotCantPinDown() {
        let timeout = "could not corroborate its position on the bar for 60 s: " + Reconciler.noSafeMoveSkipReason
        #expect(ArrangeSections.plainReason(timeout) == "No safe move found; the bar hasn't settled")
        #expect(ArrangeSections.plainReason(Reconciler.noSafeMoveSkipReason) == "No safe move found; the bar hasn't settled")
        let bar = [k("a"), k("b"), k("c"), clock]
        let o = ObservedOrder(onBar: bar, parked: [])
        let c = make(o, Layout(visible: bar), status: [k("b"): .unsupported(timeout)])
        let r = row(c, k("b"))
        #expect(r.barState == .cannotPlace("No safe move found; the bar hasn't settled") && r.badge.glyph == "⚠")
        #expect(ArrangeMenuRules.showsTryAgain(r))
    }

    @Test func uncorroboratedRowsReadTheSameTextWithOrWithoutASkipOfTheirOwn() {
        let a = k("a"), b = k("b"), c = k("c")
        let rec = Layout(visible: [a, b, c, clock])
        let o = ObservedOrder(onBar: [a, b, c, clock], parked: [], uncorroborated: [b])
        let plain = make(o, rec, status: allInPlace([a, b, c, clock]))
        let waiting = make(o, rec, status: { var s = allInPlace([a, b, c, clock]); s[b] = .waitingForPosition(Reconciler.uncorroboratedSkipReason); return s }())
        for content in [plain, waiting] {
            #expect(row(content, b).badge.glyph == "~")
            #expect(row(content, b).badgeTooltip == "Sommelier can't pin down where this item is on the bar (it looks in place)")
        }
        // neighbours disagree
        let o2 = ObservedOrder(onBar: [b, a, c, clock], parked: [], uncorroborated: [a])
        let w2 = make(o2, rec, status: { var s = allInPlace([a, b, c, clock]); s[a] = .waitingForPosition(Reconciler.uncorroboratedSkipReason); return s }())
        #expect(row(w2, a).badgeTooltip == "Sommelier can't pin down where this item is on the bar")
        // "Position being re-read" stays for STALE frames
        let o3 = ObservedOrder(onBar: [a, b, c, clock], parked: [], uncorroborated: [b], staleOnBar: [b])
        let w3 = make(o3, rec, status: { var s = allInPlace([a, b, c, clock]); s[b] = .waitingForPosition(Reconciler.staleFrameSkipReason); return s }())
        #expect(row(w3, b).badgeTooltip == "Position being re-read")
    }

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
        #expect(row(u, p1).badgeTooltip == ArrangeBarState.behindChevronText)
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
