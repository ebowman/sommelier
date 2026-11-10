import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// gdu.126: the expanded strip on a narrow display. Fixtures are the live AX dumps of MenuBarAgent taken 2026-11-08 on the 644 x 1346 pt
// portrait display (collapsed vs expanded; the chevron stays at x 453, w 18).

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private let chevFrame = CGRect(x: 453, y: 1, width: 18, height: 27)
/// Collapsed dump, the hosted [Agent] rows left of the chevron: x 405/63, 427/41, 443/24, 443/24, 444/24, 447/24 (stacked).
private let collapsedPile: [CGRect] = [(405, 63), (427, 41), (443, 24), (443, 24), (444, 24), (447, 24)].map { CGRect(x: $0.0, y: 4, width: $0.1, height: 24) }
/// Expanded dump: x 141/51, 197/24, 226/41, 302/24, 331/24, 356/24, 381/63 (de-stacked, 141...444).
private let expandedPile: [CGRect] = [(141, 51), (197, 24), (226, 41), (302, 24), (331, 24), (356, 24), (381, 63)].map { CGRect(x: $0.0, y: 4, width: $0.1, height: 24) }
private let showName = MenuBarItem.overflowChevronName
private let hideName = MenuBarItem.overflowChevronOpenName

// MARK: A: the shared rule

@Suite struct StripExpansionRuleTests {
    @Test func theCollapsedNarrowDumpIsNotExpanded() {
        let p = OverflowProbe(chevron: chevFrame, hosted: collapsedPile, chevronDescription: showName, stripMinX: 455)
        #expect(p.expansionClause == nil && !p.isOpen)
    }

    @Test func theExpandedNarrowDumpIsExpandedByTheDescriptionAndByTheDeStackedPileAlone() {
        let both = OverflowProbe(chevron: chevFrame, hosted: expandedPile, chevronDescription: hideName, stripMinX: 455)
        #expect(both.expansionClause == .description && both.isOpen)
        let descOnly = OverflowProbe(chevron: chevFrame, hosted: collapsedPile, chevronDescription: hideName, stripMinX: 455)
        #expect(descOnly.expansionClause == .description)
        let stackOnly = OverflowProbe(chevron: chevFrame, hosted: expandedPile, chevronDescription: showName, stripMinX: 455)
        #expect(stackOnly.expansionClause == .deStacked)
    }

    @Test func theWideDisplayGeometricRuleStillFires() {
        let wide = OverflowProbe(chevron: CGRect(x: 786, y: 1, width: 17, height: 24), hosted: collapsedPile, chevronDescription: showName, stripMinX: 300)
        #expect(wide.expansionClause == .geometric && wide.isOpen)
        let closed = OverflowProbe(chevron: CGRect(x: 786, y: 1, width: 17, height: 24), hosted: collapsedPile, chevronDescription: showName, stripMinX: 788)
        #expect(!closed.isOpen)
    }

    @Test func singleSignalEdgeCases() {
        #expect(StripExpansionRule.clause(chevron: nil, chevronDescription: hideName, stripMinX: 0, hosted: expandedPile) == nil)   // no chevron: nothing
        // one hosted frame, or two de-stacked ones narrower than 60 pt, are not a de-stacked pile
        #expect(StripExpansionRule.clause(chevron: chevFrame, chevronDescription: showName, stripMinX: nil, hosted: [expandedPile[0]]) == nil)
        let tiny = [CGRect(x: 400, y: 4, width: 20, height: 24), CGRect(x: 425, y: 4, width: 20, height: 24)]
        #expect(StripExpansionRule.clause(chevron: chevFrame, chevronDescription: showName, stripMinX: nil, hosted: tiny) == nil)
        // frames right of the chevron (the drawn items) never count
        let right = expandedPile.map { $0.offsetBy(dx: 400, dy: 0) }
        #expect(StripExpansionRule.clause(chevron: chevFrame, chevronDescription: showName, stripMinX: nil, hosted: right) == nil)
        // an unrecognised description never says open
        #expect(StripExpansionRule.clause(chevron: chevFrame, chevronDescription: "Boop", stripMinX: nil, hosted: collapsedPile) == nil)
    }

    @Test func theChevronIsRecognisedUnderBothDescriptions() {
        for d in [showName, hideName] {
            #expect(AXElementInfo(axDescription: d, frame: chevFrame).isOverflowChevron)
        }
    }

    // The scanner reads the same rule.
    private func scan(pile: [CGRect], chevronName: String, menuBarMinX: CGFloat?) -> MenuBarSnapshot {
        var s = FixtureSource(apps: [RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")])
        var els = pile.enumerated().map { AXElementInfo(title: "I\($0.offset)", axDescription: "I\($0.offset)", identifier: "I\($0.offset)", frame: $0.element) }
        els.append(AXElementInfo(axDescription: chevronName, frame: chevFrame, directWindowChild: true))
        var t = AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 644, height: 30), elements: els)
        t.menuBarMinX = menuBarMinX
        s.tree = t
        return MenuBarScanner(source: s).scan()
    }

    @Test func theScannerReadsTheNarrowDumpsLikeTheProbe() {
        let collapsed = scan(pile: collapsedPile, chevronName: showName, menuBarMinX: 455)
        #expect(!collapsed.stripExpanded)
        let expanded = scan(pile: expandedPile, chevronName: hideName, menuBarMinX: 455)
        #expect(expanded.stripExpanded)
        #expect(expanded.items.filter(\.systemOverflow).isEmpty)
        // description alone, de-stacked pile alone
        #expect(scan(pile: collapsedPile, chevronName: hideName, menuBarMinX: 455).stripExpanded)
        #expect(scan(pile: expandedPile, chevronName: showName, menuBarMinX: 455).stripExpanded)
        // a read that did not see the agent's AXMenuBar never infers "open" from frames alone
        #expect(!scan(pile: expandedPile, chevronName: showName, menuBarMinX: nil).stripExpanded)
    }
}

// MARK: B: StripController

private final class StripFake: @unchecked Sendable {
    private let lock = NSLock()
    private var _clicks: [CGPoint] = []
    private var t = Date(timeIntervalSince1970: 5000)
    /// Called after every click with the click count; mutates `desc` / `pile` to model what the click did.
    var onClick: ((StripFake, Int) -> Void)?
    var desc = showName
    var pile = collapsedPile
    var probes = 0
    var clicks: Int { lock.withLock { _clicks.count } }
    func controller(expand: TimeInterval = 0.3, collapse: TimeInterval = 0.3) -> StripController {
        StripController(click: { [self] p in
            lock.lock(); _clicks.append(p); let n = _clicks.count; lock.unlock()
            onClick?(self, n); return true
        }, probe: { [self] in
            lock.withLock { probes += 1 }
            return OverflowProbe(chevron: chevFrame, expanded: false, hosted: pile, chevronDescription: desc, stripMinX: 455)
        }, pressedButtons: { 0 }, sleep: { [self] s in lock.withLock { t = t.addingTimeInterval(s) } },
        now: { [self] in lock.lock(); defer { lock.unlock() }; return t },
        timing: .init(expandTimeout: expand, collapseTimeout: collapse, poll: 0.05))
    }
}

@Suite struct StripControllerRuleTests {
    @Test func anOpenStripDetectedByTheDescriptionAloneIsReady() async {
        let f = StripFake()
        f.onClick = { f, _ in f.desc = hideName }
        let out = await f.controller().openSteady(chevron: chevFrame, say: { _ in })
        guard case .ready(let s) = out else { Issue.record("not ready: \(out)"); return }
        #expect(s.openedByUs && f.clicks == 1)
    }

    @Test func anOpenStripThatNeverSettlesButShowsAsOpenIsTreatedAsOpenNotTimedOut() async {
        let f = StripFake()
        f.onClick = { f, _ in f.desc = hideName }
        // the caller's readiness never comes true; the last probe says open (description, geometry false)
        let out = await f.controller().open(chevron: chevFrame, checkAlreadyExpanded: true, acceptOpenOnTimeout: true, ready: { false }, say: { _ in })
        guard case .ready(let s) = out else { Issue.record("not ready: \(out)"); return }
        #expect(s.openedByUs && f.clicks == 1)
        // without the flag the caller's own readiness still decides
        let g = StripFake(); g.onClick = { f, _ in f.desc = hideName }
        let out2 = await g.controller().open(chevron: chevFrame, checkAlreadyExpanded: true, ready: { false }, say: { _ in })
        guard case .timedOut(let s2) = out2 else { Issue.record("not timed out: \(out2)"); return }
        #expect(s2?.openedByUs == true && g.clicks == 1)
    }

    @Test func anOpenThatIsNeverDetectedAndChangedNothingTimesOutWithoutAClosingClick() async {
        let f = StripFake()   // the click does nothing visible
        let out = await f.controller().openSteady(chevron: chevFrame, say: { _ in })
        guard case .timedOut(let s) = out else { Issue.record("not timed out: \(out)"); return }
        #expect(f.clicks == 1)   // the opening click only
        // the caller closes the session: nothing is open per the rule, so no click is posted
        let note = await f.controller().close(s, say: { _ in })
        #expect(note == nil && f.clicks == 1)
    }

    @Test func aChangedButUnrecognisedStripGetsExactlyOneVerifiedClosingClick() async {
        let f = StripFake()
        let before = f.pile
        f.onClick = { f, n in
            // click 1 (ours): two items shift apart a little (de-stack narrower than 60 pt); click 2: back to the stack
            f.pile = n == 1 ? Array(before.dropLast(2)) + [CGRect(x: 420, y: 4, width: 20, height: 24)] : before
        }
        let out = await f.controller().openSteady(chevron: chevFrame, say: { _ in })
        guard case .timedOut(let s) = out else { Issue.record("not timed out: \(out)"); return }
        #expect(s == nil)          // the strip was closed again: nothing for the caller to close
        #expect(f.clicks == 2)
        #expect(f.pile == before)
    }

    @Test func closingAStripWhoseDescriptionIsOpenClicksUntilShowHiddenReturns() async {
        let f = StripFake()
        f.desc = hideName
        f.onClick = { f, n in if n == 2 { f.desc = showName } }   // the first closing click is eaten
        let session = StripController.Session(chevronPoint: CGPoint(x: 462, y: 14), openedByUs: true, openedAt: Date())
        var said: [String] = []
        let note = await f.controller().close(session, say: { said.append($0) })
        #expect(note == nil && f.clicks == 2)
        #expect(said.contains { $0.contains("open per description") })
    }

    @Test func closingAStripThatNeverClosesReportsItAfterTwoClicks() async {
        let f = StripFake()
        f.desc = hideName
        let session = StripController.Session(chevronPoint: CGPoint(x: 462, y: 14), openedByUs: true, openedAt: Date())
        let note = await f.controller().close(session, say: { _ in })
        #expect(note == "overflowStripStillExpanded" && f.clicks == 2)
    }
}

// MARK: C: the bar-level hold

private let chevKey = ItemKey.module(name: MenuBarItem.overflowChevronName)

final class HoldBar: @unchecked Sendable {
    let lock = NSLock()
    var logs: [String] = []
    func add(_ s: String) { lock.lock(); logs.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return logs }
}

private struct HoldCaps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
}

/// Pile of 3 behind the chevron (P1..P3), D1.. drawn from x 813.
private func holdSnapshot(order: [ItemKey], hidden: Set<ItemKey>) -> MenuBarSnapshot {
    func item(_ key: ItemKey, _ frame: CGRect, chev: Bool = false) -> MenuBarItem {
        MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: key.description, axDescription: "", axIdentifier: chev ? "" : key.description,
                    frame: frame, source: .appExtras, isOnMenuBar: true, isOverflowChevron: chev, joinEvidence: .identifier)
    }
    var items: [MenuBarItem] = []
    let bar = order.filter { !hidden.contains($0) && $0 != chevKey }
    for (i, key) in bar.enumerated() {
        items.append(i < 3 ? item(key, CGRect(x: 772, y: 0, width: 24, height: 24)) : item(key, CGRect(x: 813 + CGFloat(i - 3) * 30, y: 0, width: 24, height: 24)))
    }
    items.append(item(chevKey, CGRect(x: 786, y: 0, width: 17, height: 24), chev: true))
    return MenuBarSnapshot(items: SystemOverflow.mark(items), capturedAt: Date())
}

private struct HoldObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] {
        let s = holdSnapshot(order: await actuator.order, hidden: await actuator.hidden)
        return s.items.compactMap { i in ItemKey(storeKey: i.axIdentifier.isEmpty ? i.title : i.axIdentifier).map { ResolvedItem(item: i, key: $0, confidence: .exact) } }
    }
}

struct HoldRig { let engine: LayoutEngine; let state: EngineState; let actuator: FakeActuator; let bar: HoldBar; let layout: Layout }

@MainActor
func holdRig(failCalls: Int, message: String = ActuationError.stripOpenFailureMessage, drop: [String] = ["P1"], record: [String]? = nil, configure: (inout LayoutEngine.Config) -> Void = { _ in }) async -> HoldRig {
    // P1..P3 folded behind «; the record wants each of them out between the drawn keys. gdu.144: nothing is pulled out on the engine's own
    // initiative; `drop` lists the folded keys the USER drops (after one observing pass), each of which gets exactly one pull-out attempt.
    let (p1, p2, p3, d1, d2, d3, d4) = (k("P1"), k("P2"), k("P3"), k("D1"), k("D2"), k("D3"), k("D4"))
    let order = [p1, p2, p3, d1, d2, d3, d4]
    let layout = Layout.placedAll(visible: record.map { $0.map(k) } ?? [d1, p1, d2, p2, d3, p3, d4])
    let act = FakeActuator(order: order, hidden: [], capabilities: HoldCaps(), makeSnapshot: { holdSnapshot(order: $0, hidden: $1) })
    // The strip never opens: every move across the fold the engine dispatches fails like the live actuator's failed strip open.
    for n in 0..<failCalls { await act.failOnCall(n + 1, .mechanismFailed(message)) }
    let state = EngineState()
    let bar = HoldBar()
    var cfg = LayoutEngine.Config.multiMove
    configure(&cfg)
    let engine = LayoutEngine(observer: HoldObserver(actuator: act), actuator: act, store: InMemoryLayoutStore(layout), capabilities: HoldCaps(),
                              state: state, resolveSnapshot: { s in
                                  s.items.compactMap { i in ItemKey(storeKey: i.axIdentifier.isEmpty ? i.title : i.axIdentifier).map { ResolvedItem(item: i, key: $0, confidence: .exact) } } },
                              sleep: { _ in }, log: { bar.add($0) }, config: cfg)
    await engine.start()
    _ = await engine.reconcileOnce()   // observes the bar (the folded set), plans nothing: the drawn order is the record's
    if !drop.isEmpty { await engine.setLayout(layout, moved: Set(drop.map(k))) }
    return HoldRig(engine: engine, state: state, actuator: act, bar: bar, layout: layout)
}

/// Regular (non-user) passes through the real request path, like the live poll: they end a user-edit restriction (gdu.136 / gdu.144 D5).
@MainActor
func regularPasses(_ e: LayoutEngine, _ st: EngineState, n: Int = 8) async {
    for _ in 0..<n {
        let b = st.passesStarted
        await e.requestReconcile(reason: "trigger")
        for _ in 0..<200 where st.passesStarted == b { try? await Task.sleep(for: .milliseconds(2)) }
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(2)) }
    }
}

func moveCalls(_ a: FakeActuator) async -> Int {
    await a.calls.filter { if case .move = $0 { true } else { false } }.count
}

@MainActor
@Suite struct StripOpenHoldTests {
    @Test func aFailedStripOpenIsOneClickPerBarStateNotThreePerKey() async {
        // a LIVE drawn mismatch (D4 / D3 swapped in the record) is pending the whole time: only the hold keeps it from being dragged
        let r = await holdRig(failCalls: 10, record: ["D1", "P1", "D2", "P2", "D4", "P3", "D3"])
        for _ in 0..<8 { _ = await r.engine.reconcileOnce() }
        await regularPasses(r.engine, r.state)   // the regular pass plans the D3 / D4 mismatch; only the hold keeps it from being dragged
        let n = await moveCalls(r.actuator)
        // ejb.15 (Wiring 3), CHANGED because the core decides: 2 drags, not 1. The core's FIRST pass (in `holdRig`) already drags the live drawn D4 / D3 mismatch (a
        // budgeted engine move; the old engine made no drag in its first pass), it fails and holds the bar; the second is the USER's drop of P1, which the hold never
        // blocks (its one attempt). The assertion that guards safety is kept: nothing is dragged again over the 16 further passes (n stays 2).
        #expect(n == 2)
        // sommelier-ejb.7, CHANGED because the core decides: the hold is the core's (`hold`), not `stripOpenHold` / `lastPlan.stripHeld`. The property is kept through
        // what the core shows: the bar differs, no drag is moving, and the move count above did not grow. (The "N folded" text is CoreStatusTextTests'.)
        #expect(r.state.coreStatus != .moving && r.state.coreStatus != .matches)
        for key in r.state.perItem.keys {   // held: a neutral row, never pending / moving / unsupported (the user's own failed pull-out reads failed, display only)
            switch r.state.perItem[key] { case .pending?, .moving?, .unsupported?: Issue.record("held \(key) reads \(String(describing: r.state.perItem[key]))"); default: break }
        }
        #expect(!r.bar.lines.contains { $0.contains("giving up") })
    }

    @Test func aChangedBarReleasesNothingTheUsersDropAndRetryDo() async {
        // gdu.144 item 2: a changed bar releases nothing; each further drag is the user's own drop of a folded key (which clears the hold), or Retry
        let r = await holdRig(failCalls: 10)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 1)
        await r.actuator.removeItem(k("D4"))        // the drawn count changes, on every one of these passes
        for _ in 0..<8 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 1)   // NOT released (sommelier-ejb.7: asserted through the move count; the hold is the core's)
        await r.engine.setLayout(r.layout, moved: [k("P2")])   // the user drops the next folded key: its one attempt
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        #expect(await moveCalls(r.actuator) == 2)
        await r.engine.userRetry()               // Retry releases the hold; the folded requests are spent, so only the engine's budgeted moves may follow
        #expect(await moveCalls(r.actuator) == 2)
    }

    @Test func withoutTheHoldTheSameWorldWouldDragAgainEveryPass() async {
        // control: a world whose strip opens fine (no failures scripted) performs a move on the first pass
        let r = await holdRig(failCalls: 0)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }   // the full-bar gate needs two agreeing reads before the first drag
        #expect(await moveCalls(r.actuator) >= 1)
    }
}

// MARK: D: Arrange

@Suite struct StripHoldArrangeTests {
    private func caps(_ key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
    private func info(_ key: ItemKey) -> ItemInfo {
        ItemInfo(key: key, title: "", axDescription: "\(key)", ownerPID: 1, ownerBundleID: "com.x", ownerName: "Owner", width: 30, isOnBar: true, systemOverflow: false)
    }

}
