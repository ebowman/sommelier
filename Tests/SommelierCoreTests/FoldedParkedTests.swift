import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// gdu.121: on a full bar macOS folds Visible items behind the chevron; the agent hosts only part of that pile. A parked, allowed, running
// item while the chevron is fresh is "folded for width": never a membership show, rendered « in Arrange, no wait entry in the engine.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private let clockKey = ItemKey.module(name: "Clock")
private let ccKey = ItemKey.module(name: "com.apple.menuextra.controlcenter")
private let chevronKey = ItemKey.module(name: MenuBarItem.overflowChevronName)

private func caps(_ key: ItemKey) -> Capability {
    if case .module = key { return Capability(canMove: false, canHide: false, reason: "system module") }
    return Capability(canMove: true, canHide: true)
}

private func entry(_ key: ItemKey, x: CGFloat, y: CGFloat = 3, onBar: Bool, stale: Bool = false, allowed: Bool? = nil, hiddenCC: Bool = false,
                   unknown: Bool = false, overflow: Bool = false, notHosted: Bool = false, chevron: Bool = false, expanded: Bool = false,
                   w: CGFloat = 24) -> ResolvedItem {
    var m = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: key.description, axDescription: chevron ? MenuBarItem.overflowChevronName : "",
                        axIdentifier: chevron ? "" : key.description, frame: CGRect(x: x, y: y, width: w, height: 24), source: .appExtras, isOnMenuBar: onBar,
                        stale: stale, notHostedByAgent: notHosted, isOverflowChevron: chevron, systemOverflow: overflow, joinEvidence: .identifier,
                        hiddenInControlCenter: hiddenCC, placementUnknown: unknown, controlCenterAllowed: allowed)
    m.stripExpanded = expanded
    return ResolvedItem(item: m, key: key, confidence: .exact)
}

// MARK: - ObservedOrder classification
// NOTE: these items set controlCenterAllowed by hand; the scanner populates it for parked/not-hosted items (gdu.121 corrective) and ScannerFoldedParkedTests.swift covers that.

/// One drawn item, a chevron (configurable), one parked item (configurable).
private func small(chevron: Bool = true, chevronStale: Bool = false, expanded: Bool = false, parkedStale: Bool = false, allowed: Bool? = true,
                   hiddenCC: Bool = false, unknown: Bool = false) -> ObservedOrder {
    var r = [entry(k("d"), x: 600, onBar: true)]
    if chevron { r.append(entry(chevronKey, x: 483, onBar: true, stale: chevronStale, chevron: true, expanded: expanded, w: 17.5)) }
    r.append(entry(k("p"), x: 563, y: 749, onBar: false, stale: parkedStale, allowed: allowed, hiddenCC: hiddenCC, unknown: unknown))
    return ObservedOrder(resolved: r)
}

@Suite struct FoldedParkedObservedTests {
    @Test func parkedAllowedWithAFreshChevronIsFoldedAndStaysParked() {
        let o = small()
        #expect(o.foldedParked == [k("p")])
        #expect(o.parked == [k("p")])
    }
    @Test func noChevronMeansNotFolded() { #expect(small(chevron: false).foldedParked.isEmpty) }
    @Test func aStaleChevronMeansNotFolded() { #expect(small(chevronStale: true).foldedParked.isEmpty) }
    @Test func anOpenStripMeansNotFolded() { #expect(small(expanded: true).foldedParked.isEmpty) }
    @Test func unknownAllowanceMeansNotFolded() { #expect(small(allowed: nil).foldedParked.isEmpty) }
    @Test func disallowedMeansNotFolded() { #expect(small(allowed: false).foldedParked.isEmpty) }
    @Test func hiddenInControlCenterMeansNotFolded() { #expect(small(hiddenCC: true).foldedParked.isEmpty) }
    @Test func placementUnknownMeansNotFolded() { #expect(small(unknown: true).foldedParked.isEmpty) }
    @Test func aStaleParkedItemIsExcludedEntirely() {
        let o = small(parkedStale: true)
        #expect(o.foldedParked.isEmpty && o.parked.isEmpty)
    }
}

// MARK: - The 2026-11-08 incident shape

private struct Incident {
    var resolved: [ResolvedItem]
    var drawn: [ItemKey]
    var pile: [ItemKey]
    var folded: [ItemKey]
    /// Record: folded keys, then the pile, then the drawn keys (a fold-consistent record).
    var layout: Layout { Layout(visible: folded + pile + drawn) }
}

private func incident(chevron: Bool = true) -> Incident {
    let drawn = (0..<7).map { k("d\($0)") } + [ccKey, clockKey]
    let pile = (0..<4).map { k("pile\($0)") }
    let folded = (0..<26).map { k("f\($0)") }
    var r: [ResolvedItem] = []
    for (i, d) in drawn.enumerated() { r.append(entry(d, x: 510 + CGFloat(i) * 15, onBar: true)) }
    if chevron { r.append(entry(chevronKey, x: 483, onBar: true, chevron: true, w: 17.5)) }
    for p in pile { r.append(entry(p, x: 483, onBar: true, overflow: chevron)) }
    for (i, f) in folded.enumerated() {
        if i % 2 == 0 { r.append(entry(f, x: 563, y: 749, onBar: false, allowed: true)) }                       // parkedFrame
        else { r.append(entry(f, x: 595, y: 3, onBar: false, allowed: true, notHosted: true)) }                // notHosted, on-strip-looking frame
    }
    return Incident(resolved: r, drawn: drawn, pile: pile, folded: folded)
}

@Suite struct FoldedParkedPlannerTests {
    @Test func theIncidentPlansNoShowAndSkipsEveryFoldedKeyWithTheReason() {
        let inc = incident()
        let o = ObservedOrder(resolved: inc.resolved)
        #expect(Set(o.foldedParked) == Set(inc.folded))
        #expect(o.systemOverflow == Set(inc.pile))
        for layout in [inc.layout, Layout(visible: Array(inc.folded.prefix(10)) + inc.pile + Array(inc.drawn.prefix(5)) + Array(inc.folded.dropFirst(10)) + Array(inc.drawn.dropFirst(5)))] {
            let plan = Reconciler().plan(observed: o, layout: layout, capabilities: caps)
            #expect(!plan.actions.contains { if case .show = $0 { true } else { false } })
            for f in inc.folded {
                #expect(plan.skipped.contains { $0.key == f && $0.reason == Reconciler.foldedParkedSkipReason })
            }
            let folded = Set(inc.folded)
            for a in plan.actions {
                switch a {
                case .hide(let x), .show(let x): #expect(!folded.contains(x))
                case .move(let x, let rel):
                    #expect(!folded.contains(x))
                    switch rel { case .before(let t), .after(let t): #expect(!folded.contains(t)); default: break }
                }
            }
        }
    }

    @Test func theIncidentWithAFoldConsistentRecordConverges() {
        let inc = incident()
        let plan = Reconciler().plan(observed: ObservedOrder(resolved: inc.resolved), layout: inc.layout, capabilities: caps)
        #expect(plan.phase == .converged && plan.actions.isEmpty)
    }

    @Test func withoutTheChevronTheShowsAreStillPlanned() {
        let inc = incident(chevron: false)
        let o = ObservedOrder(resolved: inc.resolved)
        #expect(o.foldedParked.isEmpty)
        let plan = Reconciler().plan(observed: o, layout: inc.layout, capabilities: caps)
        let shown = Set(plan.actions.compactMap { a -> ItemKey? in if case .show(let x) = a { x } else { nil } })
        #expect(shown == Set(inc.folded))
        #expect(plan.phase == .membership)
    }

    @Test func aFoldedKeyThatTheLayoutHidesIsNotAffected() {
        let inc = incident()
        let hiddenOne = inc.folded[0]
        var l = inc.layout
        l.visible.removeAll { $0 == hiddenOne }
        l.hidden = [hiddenOne]
        let plan = Reconciler().plan(observed: ObservedOrder(resolved: inc.resolved), layout: l, capabilities: caps)
        #expect(!plan.skipped.contains { $0.key == hiddenOne && $0.reason == Reconciler.foldedParkedSkipReason })
        #expect(!plan.actions.contains { if case .show = $0 { true } else { false } })
    }
}

// MARK: - Arrange

@Suite struct FoldedParkedArrangeTests {
    private func content(_ inc: Incident, layout: Layout? = nil) -> (ArrangeContent, ObservedOrder, [ItemKey: ItemStatus]) {
        let o = ObservedOrder(resolved: inc.resolved)
        let l = layout ?? inc.layout
        var st: [ItemKey: ItemStatus] = [:]
        for key in o.onBar + o.parked { st[key] = ArrangeSections.foldBaseStatus(key, layout: l, observed: o) }
        let plan = Reconciler().plan(observed: o, layout: l, capabilities: caps)
        let items = Dictionary(uniqueKeysWithValues: (o.onBar + o.parked).map {
            ($0, ItemInfo(key: $0, title: "", axDescription: "\($0)", ownerPID: 1, ownerBundleID: "com.x", ownerName: "Owner", width: 24, isOnBar: o.onBar.contains($0), systemOverflow: false))
        })
        let c = ArrangeSections.make(observed: o, layout: l, items: items, perItem: st, capabilities: caps, lastPlan: PlanSummary(plan: plan, held: []))
        return (c, o, st)
    }

    @Test func everyFoldedRowIsBehindTheChevronAndTheFoldLineFollowsTheLastOverflowedKey() throws {
        let inc = incident()
        let (c, _, _) = content(inc)
        for f in inc.folded {
            let r = try #require(c.visible.rows.first { $0.key == f })
            #expect(r.barState == .behindChevron)
            #expect(r.badge == .behindChevron)
            #expect(!r.isGhost)
        }
        #expect(!c.visible.rows.contains { $0.barState == .moving || $0.barState == .notOnBar })
        let line = try #require(c.visible.rows.firstIndex { $0.isBoundary })
        let lastOverflowed = try #require(c.visible.rows.lastIndex { Set(inc.folded + inc.pile).contains($0.key) })
        #expect(line == lastOverflowed + 1)
    }

    @Test func foldedKeysDoNotMakeTheStatusLineWaitOrMove() {
        let inc = incident()
        let (c, _, st) = content(inc)
        let line = ArrangeSections.statusLine(perItem: st, lastError: nil, isConverged: true, inFlight: false, content: c)
        #expect(!line.contains("Waiting") && !line.contains("Moving"))
    }

    @Test func whereTheFoldFallsNeverMakesAKeyPendingWhateverTheRecord() {
        // gdu.144: the fold is macOS's decision; no record makes a drawn key wait for a folded one or the reverse.
        let inc = incident()
        let o = ObservedOrder(resolved: inc.resolved)
        for l in [inc.layout, Layout(visible: inc.drawn + inc.folded + inc.pile), Layout(visible: inc.pile + inc.drawn + inc.folded)] {
            for key in inc.folded + inc.pile { #expect(ArrangeSections.foldBaseStatus(key, layout: l, observed: o) == .notFitting) }
            for key in inc.drawn { #expect(ArrangeSections.foldBaseStatus(key, layout: l, observed: o) == .inPlace) }
        }
    }
}

// MARK: - Engine

private struct IncidentObserver: MenuBarObserver {
    func observe() async throws -> [ResolvedItem] {
        var r = (0..<4).map { entry(k("d\($0)"), x: 510 + CGFloat($0) * 15, onBar: true) }
        r.append(entry(chevronKey, x: 483, onBar: true, chevron: true, w: 17.5))
        r += (0..<2).map { entry(k("pile\($0)"), x: 483, onBar: true, overflow: true) }
        r += (0..<6).map { i in i % 2 == 0 ? entry(k("f\(i)"), x: 563, y: 749, onBar: false, allowed: true)
                                           : entry(k("f\(i)"), x: 595, y: 3, onBar: false, allowed: true, notHosted: true) }
        return r
    }
}
private struct AllCaps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
}
private final class Lines: @unchecked Sendable {
    private let l = NSLock(); private var v: [String] = []
    func add(_ s: String) { l.lock(); v.append(s); l.unlock() }
    var all: [String] { l.lock(); defer { l.unlock() }; return v }
}

@MainActor
@Suite struct FoldedParkedEngineTests {
    @Test func threePassesOnTheIncidentWriteNothingAndNeverPlanAMembershipPhase() async {
        let lines = Lines()
        let folded = (0..<6).map { k("f\($0)") }
        let order = folded + (0..<2).map { k("pile\($0)") } + (0..<4).map { k("d\($0)") }
        let act = FakeActuator(order: order, hidden: Set(folded), capabilities: AllCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        var cfg = LayoutEngine.Config()
        cfg.layoutCoalesce = .zero
        cfg.trackedAllowed = { _ in true }
        let state = EngineState()
        let e = LayoutEngine(observer: IncidentObserver(), actuator: act, store: InMemoryLayoutStore(Layout(visible: order)), capabilities: AllCaps(), state: state,
                             resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { lines.add($0) }, config: cfg)
        await e.start()
        for _ in 0..<3 { _ = await e.reconcileOnce() }
        #expect(await act.calls.isEmpty)
        #expect(!lines.all.contains { $0.contains("phase=membership") })
        #expect(!lines.all.contains { $0.contains("membership write") })
        for f in folded {
            switch state.perItem[f] {
            case .notFitting?: break
            default: Issue.record("\(f): expected .notFitting, got \(String(describing: state.perItem[f]))")
            }
        }
    }
}
