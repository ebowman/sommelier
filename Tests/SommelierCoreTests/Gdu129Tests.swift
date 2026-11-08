import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// gdu.129: a fold move refused inside the open « strip holds the bar (one session per bar state); the refusal text never says "hidden"
// for a folded subject; folded rows survive carried-chevron scans; the corroboration failure is logged once.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }

// MARK: a. engine hold

@MainActor
@Suite struct StripUnplaceableHoldTests {
    @Test func aStripThatOpensButCannotPlaceTheSubjectIsOneSessionPerBarState() async {
        let r = await holdRig(failCalls: 20, message: ActuationError.stripUnplaceableMessage)
        for _ in 0..<8 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 1)
        #expect(await r.engine.stripOpenHold != nil)
        #expect(!r.bar.lines.contains { $0.contains("giving up") })
        #expect(r.bar.lines.contains { $0.contains("could not be pinned down inside it") })
        let plan = r.state.lastPlan
        #expect(!plan.stripHeld.isEmpty && plan.stripHoldFolded == 3 && plan.stripHoldUnplaceable)
        #expect(plan.moving.isEmpty)
        #expect(r.bar.lines.contains { $0.contains("plan:") && $0.contains(Reconciler.stripUnavailableSkipReason) })
        #expect(!r.bar.lines.contains { $0.contains("phase=membership") || $0.contains("membership") && $0.contains("phase") })
        for key in plan.stripHeld {
            #expect(r.state.perItem[key] == .notFitting)
            if case .unsupported = r.state.perItem[key] { Issue.record("unsupported") }
        }
        // a changed bar: exactly one more session; Retry: one more
        await r.actuator.removeItem(k("D4"))
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 2)
        await r.engine.clearFailures()
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 3)
    }

    @Test func theOpenFailureHoldKeepsItsOwnFlag() async {
        let r = await holdRig(failCalls: 20)
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        #expect(!r.state.lastPlan.stripHoldUnplaceable && r.state.lastPlan.stripHoldFolded == 3)
    }
}

// MARK: b. refusal text

@Suite struct ParkedRefusalTextTests {
    private func item(_ n: String, onBar: Bool, frame: CGRect, chev: Bool = false, expanded: Bool = false, overflow: Bool = false) -> MenuBarItem {
        var i = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: n, axDescription: "", axIdentifier: chev ? "" : n, frame: frame,
                            source: .appExtras, isOnMenuBar: onBar, isOverflowChevron: chev, joinEvidence: .identifier)
        i.systemOverflow = overflow; i.stripExpanded = expanded
        i.controlCenterAllowed = true
        return i
    }
    private func resolved(_ s: MenuBarSnapshot) -> [ResolvedItem] {
        s.items.map { ResolvedItem(item: $0, key: $0.isOverflowChevron ? .module(name: MenuBarItem.overflowChevronName) : k($0.title), confidence: .exact) }
    }
    private let bar = CGRect(x: 800, y: 0, width: 24, height: 24)

    @Test func pileFoldedAndOpenStripSubjectsGetTheFoldedText() {
        let chev = item("c", onBar: true, frame: CGRect(x: 786, y: 0, width: 17, height: 24), chev: true)
        let pile = item("P", onBar: true, frame: CGRect(x: 772, y: 0, width: 24, height: 24), overflow: true)
        var s = MenuBarSnapshot(items: [pile, chev, item("D", onBar: true, frame: bar)], capturedAt: Date())
        s.items[0].systemOverflow = true
        #expect(LiveActuator.parkedRefusalText(k("P"), s, resolved: resolved(s)) == LiveActuator.foldedRefusalText)
        // folded for width: parked, allowed, fresh chevron
        let s2 = MenuBarSnapshot(items: [chev, item("D", onBar: true, frame: bar), item("F", onBar: false, frame: CGRect(x: 0, y: 0, width: 24, height: 24))], capturedAt: Date())
        #expect(LiveActuator.parkedRefusalText(k("F"), s2, resolved: resolved(s2)) == LiveActuator.foldedRefusalText)
        // open strip: any parked subject
        var open = chev; open.stripExpanded = true
        let s3 = MenuBarSnapshot(items: [open, item("D", onBar: true, frame: bar), item("F", onBar: false, frame: CGRect(x: 0, y: 0, width: 24, height: 24))], capturedAt: Date())
        #expect(s3.stripExpanded)
        #expect(LiveActuator.parkedRefusalText(k("F"), s3, resolved: resolved(s3)) == LiveActuator.foldedRefusalText)
        #expect(!LiveActuator.foldedRefusalText.contains("hidden"))
    }

    @Test func aCollapsedNoChevronOffBarSubjectKeepsTheOldText() {
        let s = MenuBarSnapshot(items: [item("D", onBar: true, frame: bar), item("F", onBar: false, frame: CGRect(x: 0, y: 0, width: 24, height: 24))], capturedAt: Date())
        #expect(LiveActuator.parkedRefusalText(k("F"), s, resolved: resolved(s)) == "The item is hidden (off the bar); show it before moving it.")
    }
}

// MARK: c. status line

@Suite struct StripHoldStatusTests {
    @Test func theNewHoldAndTheOpenFailureHoldReadDifferently() {
        let (p1, d1) = (k("P1"), k("D1"))
        let o = ObservedOrder(onBar: [p1, d1], parked: [], systemOverflow: [p1], overflowChevron: .module(name: MenuBarItem.overflowChevronName))
        let c = ArrangeSections.make(observed: o, layout: Layout(visible: [d1, p1]), items: [:], perItem: [:], capabilities: { _ in Capability(canMove: true, canHide: true) }, lastPlan: PlanSummary())
        var ctx = ArrangeSections.StatusContext(); ctx.stripHoldFolded = 5; ctx.stripHoldUnplaceable = true
        #expect(ArrangeSections.statusLine(perItem: [:], lastError: nil, isConverged: true, inFlight: false, content: c, context: ctx)
                == "The bar is too narrow for this order: macOS folds 5 items behind « and Sommelier could not place an item inside the strip.")
        ctx.stripHoldUnplaceable = false
        #expect(ArrangeSections.statusLine(perItem: [:], lastError: nil, isConverged: true, inFlight: false, content: c, context: ctx)
                == "The bar is too narrow for this order: macOS folds 5 items behind « and the strip would not open")
    }
}

// MARK: d. ObservedOrder through carried chevrons

@Suite struct CarriedChevronFoldTests {
    private func scan(stale: Bool, recent: Bool) -> ObservedOrder {
        func mk(_ n: String, _ f: CGRect, onBar: Bool, chev: Bool = false) -> ResolvedItem {
            var i = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: n, axDescription: "", axIdentifier: chev ? "" : n, frame: f,
                                source: .appExtras, isOnMenuBar: onBar, isOverflowChevron: chev, joinEvidence: .identifier)
            i.controlCenterAllowed = true
            if chev { i.stale = stale; i.recentlyVerified = recent }
            return ResolvedItem(item: i, key: chev ? .module(name: MenuBarItem.overflowChevronName) : k(n), confidence: .exact)
        }
        return ObservedOrder(resolved: [mk("c", CGRect(x: 453, y: 0, width: 18, height: 24), onBar: true, chev: true),
                                        mk("D", CGRect(x: 480, y: 0, width: 24, height: 24), onBar: true),
                                        mk("F", CGRect(x: 0, y: 0, width: 24, height: 24), onBar: false)])
    }

    @Test func alternatingFreshAndCarriedChevronKeepsTheFold() {
        for i in 0..<6 {
            let o = i % 2 == 0 ? scan(stale: false, recent: false) : scan(stale: true, recent: true)
            #expect(o.foldedParked == [k("F")])
            #expect(i % 2 == 0 ? o.overflowChevron != nil : (o.overflowChevron == nil && o.chevronRecent))
        }
    }

    @Test func aChevronStaleBeyondTheWindowDropsTheFold() {
        let o = scan(stale: true, recent: false)
        #expect(o.foldedParked.isEmpty && !o.chevronRecent && o.overflowChevron == nil)
    }

    @Test func theCarriedChevronNeverPlansAFoldMoveAndTheFingerprintIsStable() {
        let o = scan(stale: true, recent: true)
        #expect(o.systemOverflow.isEmpty && o.overflowChevron == nil)
        let plan = Reconciler().plan(observed: o, layout: Layout(visible: [k("D")]), capabilities: { _ in Capability(canMove: true, canHide: true) }, held: [])
        #expect(plan.actions.isEmpty)
        #expect(BarFingerprint(o) == BarFingerprint(scan(stale: false, recent: false)))
    }
}
