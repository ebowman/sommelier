import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// gdu.144 corrective pass 3: the fresh reviewer's adversary, kept as the permanent one. The REAL LayoutEngine on the REAL LiveActuator over a fake platform
// (RvWorld), PHYSICAL drags counted at the platform, no user input unless a test says so. Limits are strict: 3 whenever the bar is full (a chevron or an
// unreadable window in every three consecutive reads), 20 in total always, zero automatic chevron clicks everywhere.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "app.\(n)", autosaveName: n) }
private let chevKey = ItemKey.module(name: MenuBarItem.overflowChevronName)
private struct RvRNG: RandomNumberGenerator { var s: UInt64; mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) } }
private enum RvCM: String, Sendable { case fresh, recent, stale, absent }

fileprivate final class RvWorld: ActuatorPlatform, MenuBarObserver, @unchecked Sendable {
    private let l = NSRecursiveLock()
    func sync<T>(_ f: () -> T) -> T { l.lock(); defer { l.unlock() }; return f() }
    var pile: [String]; var drawn: [String]
    var mode: RvCM = .fresh; var level: ReadCompleteness = .complete; var staleKeys: Set<String> = []
    var rng: RvRNG; var settledReads = true; var busyOnDrag = false; var busyThrown = false; var applyProb = 1.0; var scramble = false; var flipScans = false; var expanded = false
    var reads: [(RvCM, ReadCompleteness)] = []; var drags: [String] = []; var clicks = 0; var events: [String] = []
    var clock = Date(timeIntervalSince1970: 1000)
    init(pile: [String], drawn: [String], seed: UInt64 = 1) { self.pile = pile; self.drawn = drawn; rng = RvRNG(s: seed) }

    func frames() -> [(String, CGRect)] {
        var out: [(String, CGRect)] = []
        for (i, n) in pile.enumerated() { out.append((n, expanded ? CGRect(x: 400 + CGFloat(i) * 40, y: 0, width: 30, height: 24) : CGRect(x: 815 + CGFloat(i) * 2, y: 0, width: 24, height: 24))) }
        for (i, n) in drawn.enumerated() { out.append((n, CGRect(x: 880 + CGFloat(i) * 40, y: 0, width: 30, height: 24))) }
        return out
    }
    func snap(_ m: RvCM) -> MenuBarSnapshot {
        sync {
            var items: [MenuBarItem] = frames().map { f in
                var i = MenuBarItem(ownerPID: pid_t(100 + abs(f.0.utf8.reduce(0) { $0 &* 31 &+ Int($1) }) % 30000), ownerBundleID: "app.\(f.0)", ownerName: f.0, title: "", axDescription: "", axIdentifier: f.0,
                                    frame: f.1, source: .appExtras, isOnMenuBar: true, isOverflowChevron: false, joinEvidence: .identifier)
                i.controlCenterAllowed = true
                if staleKeys.contains(f.0) { i.stale = true }
                return i
            }
            if m != .absent {
                var c = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "agent", title: "", axDescription: MenuBarItem.overflowChevronName, axIdentifier: "",
                                    frame: CGRect(x: 845, y: 0, width: 17, height: 24), source: .agentHostedOnly, isOnMenuBar: true, isOverflowChevron: true, joinEvidence: .identifier)
                c.controlCenterAllowed = true
                if m == .recent { c.stale = true; c.recentlyVerified = true }
                if m == .stale { c.stale = true }
                c.stripExpanded = (m == .fresh) && expanded
                items.append(c)
            }
            items.sort { $0.frame.minX < $1.frame.minX }
            return MenuBarSnapshot(items: SystemOverflow.mark(items), capturedAt: clock)
        }
    }
    func res(_ s: MenuBarSnapshot) -> [ResolvedItem] { s.items.map { ResolvedItem(item: $0, key: $0.isOverflowChevron ? chevKey : k($0.ownerName), confidence: .exact) } }
    // observer
    func observe() async throws -> [ResolvedItem] { res(snap(sync { mode })) }
    func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> BarObservation {
        let (m, c) = sync { reads.append((mode, level)); return (mode, level) }
        return BarObservation(items: res(snap(m)), settled: sync { settledReads }, scans: 2, completeness: c)
    }
    // platform
    func scanMode() -> RvCM { sync { flipScans ? [RvCM.fresh, .recent, .stale, .absent].randomElement(using: &rng)! : mode } }
    func scanVisible() async -> MenuBarSnapshot { snap(scanMode()) }
    func scan() async -> MenuBarSnapshot { var s = snap(scanMode()); s.hostedLayout = []; return s }
    func accessibilityTrusted() -> Bool { true }
    func pressedMouseButtons() -> Int { 0 }
    func conflictingManager() -> String? { nil }
    func resolve(_ s: MenuBarSnapshot) -> [ResolvedItem] { res(s) }
    func trackedKey(for item: ResolvedItem) -> String? { "tracked.\(item.item.ownerName)" }
    func beginTrackedSnapshot() {}
    func endTrackedSnapshot() {}
    func displayName(forTrackedKey key: String) -> String { key }
    func drag(itemFrame: CGRect, toX: CGFloat, steps: Int) async throws -> Date {
        let busy = sync { busyOnDrag }
        if busy { sync { let name = frames().first { abs($0.1.midX - itemFrame.midX) < 1 }?.0 ?? "?"; drags.append(name); events.append("drag:\(name)") }; throw DragError.userBusy }
        return sync {
            let name = frames().first { abs($0.1.midX - itemFrame.midX) < 1 }?.0 ?? "?"
            drags.append(name); events.append("drag:\(name)")
            if busyOnDrag { busyThrown = true }
            if Double.random(in: 0..<1, using: &rng) < applyProb, name != "?" {
                let inPile = pile.contains(name)
                let before = frames()   // the frames the drop was aimed at (the dragged item still in its slot)
                pile.removeAll { $0 == name }; drawn.removeAll { $0 == name }
                let idx = before.filter { $0.0 != name && $0.1.midX < toX && drawn.contains($0.0) }.count
                drawn.insert(name, at: min(idx, drawn.count))
                if inPile, !drawn.isEmpty, drawn.first != name { let x = drawn.removeFirst(); pile.append(x) }   // the fold keeps its width
            }
            if scramble { drawn.shuffle(using: &rng) }
            return clock
        }
    }
    func menuProbe(for item: MenuBarItem) -> MenuProbe { MenuProbe(hasMenu: false, windowCount: 0) }
    func menuOpenByAnotherApp() -> Bool { false }
    func pressEscape() {}
    func readOrderStore() throws -> [String: Double] { [:] }
    func writeOrderStore(_ updates: [String: Double], allowModules: Bool) throws {}
    func waitForOrderStoreQuiet() async {}
    func writeAllowed(_ changes: [String: Bool]) throws {}
    func readAllowed(_ keys: [String]) throws -> [String: Bool] { [:] }
    var liveHideShowAvailable: Bool { false }
    func setAllowedLive(_ changes: [String: Bool]) throws {}
    func restartAgent(timeout: TimeInterval, expectedChange: Int) async -> AgentRestartOutcome { AgentRestartOutcome(recovered: true, elapsedMS: 1) }
    func sleep(_ seconds: TimeInterval) async { sync { clock = clock.addingTimeInterval(seconds) } }
    func now() -> Date { sync { clock } }
    func overflowProbe() async -> OverflowProbe? {
        sync { mode == .absent ? OverflowProbe(chevron: nil) : OverflowProbe(chevron: CGRect(x: 845, y: 0, width: 17, height: 24), expanded: expanded, hosted: frames().map(\.1)) }
    }
    func clickChevron(at point: CGPoint) -> Bool { sync { clicks += 1; events.append(expanded ? "close" : "open"); expanded.toggle(); return true } }
    func interactionBlockingReason() -> String? { nil }
    // the window property of the orchestrator's assertion, from the ACTUAL read log
    func everyWindowHasChevronOrIncomplete() -> Bool {
        sync {
            guard reads.count >= 3 else { return true }
            for i in 0...(reads.count - 3) where reads[i..<(i + 3)].allSatisfy({ $0.0 == .absent && $0.1 != .incomplete }) { return false }   // three chevronless reads of a fully read tree
            return true
        }
    }
}
private struct RvCapsX: CapabilityProvider { func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) } }
private final class RvClock: @unchecked Sendable { private let l = NSLock(); private var t = Date(timeIntervalSince1970: 5000); func read() -> Date { l.lock(); defer { l.unlock() }; return t }; func adv(_ s: TimeInterval) { l.lock(); t = t.addingTimeInterval(s); l.unlock() } }

@MainActor fileprivate func rvRig(_ w: RvWorld, record: [String], assumeFull: Bool = true, logs: RvLogs? = nil, followUp: Duration = .seconds(3)) async -> (LayoutEngine, EngineState, RvClock) {
    var lc = LiveActuator.Config(); lc.allowFallback = false   // production (EngineFactory.makeLive)
    let a = LiveActuator(platform: w, config: lc)
    let st = EngineState(); let clock = RvClock()
    var c = LayoutEngine.Config(); c.now = { clock.read() }; c.layoutCoalesce = .zero; c.userEditFollowUp = followUp; c.assumeFullBarAtLaunch = assumeFull
    let e = LayoutEngine(observer: w, actuator: a, store: InMemoryLayoutStore(Layout.placedAll(visible: record.map(k))), capabilities: RvCapsX(), state: st,
                         resolveSnapshot: { w.res($0) }, sleep: { _ in }, log: { logs?.add($0) }, config: c)
    await e.start(); return (e, st, clock)
}
fileprivate final class RvLogs: @unchecked Sendable { private let l = NSLock(); var v: [String] = []; func add(_ s: String) { l.lock(); v.append(s); l.unlock() } }
private func rvInfo(_ key: ItemKey) -> ItemInfo { ItemInfo(key: key, title: "\(key)", axDescription: "", ownerPID: 1, ownerBundleID: nil, ownerName: "x", width: 24, isOnBar: true) }
@MainActor fileprivate func rvRowsOf(_ st: EngineState) -> ArrangeContent {
    ArrangeSections.make(observed: st.observed, layout: st.layout, items: Dictionary(uniqueKeysWithValues: (st.observed.onBar + st.observed.parked).map { ($0, rvInfo($0)) }),
                         perItem: st.perItem, capabilities: { _ in Capability(canMove: true, canHide: true) })   // Swift's own rows (no core rows): the stricter legacy invariant
}
/// The rows the window really shows: the core's rows lead (as ArrangeViewModel passes them). sommelier-ejb.7: the legacy rows had `lastPlan.checkingBar` to suppress checks.
@MainActor fileprivate func rvCoreRowsOf(_ st: EngineState) -> ArrangeContent {
    ArrangeSections.make(observed: st.observed, layout: st.layout, items: Dictionary(uniqueKeysWithValues: (st.observed.onBar + st.observed.parked).map { ($0, rvInfo($0)) }),
                         perItem: st.perItem, capabilities: { _ in Capability(canMove: true, canHide: true) },
                         coreRows: st.coreDisplay == nil ? nil : st.coreRows, coreNotes: st.coreNotes)
}
private let rvP = ["P1", "P2", "P3"], rvD: [String] = ["D1", "D2", "D3", "D4", "D5", "D6"]

@MainActor private func rvMenu(_ st: EngineState) -> String { StatusLine.text(state: st, trusted: true, conflicting: nil) }
/// ejb.16 CHANGED (display source): the Arrange line is `CoreStatusText` (the same renderer the menu uses, D10); it was `ArrangeSections.statusLine` over the old plan.
@MainActor private func rvArrangeLine(_ st: EngineState) -> String { CoreStatusText.text(state: st, trusted: true, conflicting: nil) }
private let rvScrambled = ["D6", "D5", "D4", "D3", "D2", "D1"]
/// ejb.15: a scramble away from the churn zone (the first drawn key): one swap, so the core's first move (`D4 before D5`) needs no strip session.
private let rvSwapped = ["D1", "D2", "D3", "D5", "D4", "D6"]
private func rvFalseChecks(_ rows: [ArrangeRow], record: [String], bar: [String]) -> [String] {
    var out: [String] = []
    for r in rows where r.barState == .matches {
        guard let i = record.firstIndex(where: { k($0) == r.key }), let at = bar.firstIndex(of: record[i]) else { continue }
        if record[..<i].contains(where: { bar.firstIndex(of: $0).map { $0 > at } ?? false }) || record[(i + 1)...].contains(where: { bar.firstIndex(of: $0).map { $0 < at } ?? false }) { out.append(record[i]) }
    }
    return out
}

@MainActor @Suite struct RvDirected {
    // D2: a launch with no chevron and FAILING drags: at most 3 PHYSICAL drags in all, the hold is set after the first, no chevron click
    @Test func aChevronlessLaunchWithFailingDragsIsAtMostThreePhysicalDragsAndHolds() async {
        let w = RvWorld(pile: rvP, drawn: rvScrambled); w.mode = .absent; w.applyProb = 0
        let (e, _, c) = await rvRig(w, record: rvP + rvD)
        _ = await e.reconcileOnce(); c.adv(120)
        // ejb.15 (Wiring 3), CHANGED because the core decides: NO drag at launch (0, was 1). A chevronless bar is "checking" for the core until a fresh chevron or
        // the proof (three complete chevronless reads) says what it is; the old engine dragged once on the assumed-full bar, failed, and held. No drag means no
        // hold either (the old assertion `stripOpenHold != nil` is gone with it). The safety bound below (<= 3 physical drags, no chevron click) is unchanged.
        #expect(w.drags.count == 0)
        w.sync { w.mode = .fresh }
        for _ in 0..<30 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.drags.count <= 3 && w.clicks == 0, "physical=\(w.drags.count) clicks=\(w.clicks)")
    }
    // D1: complete reads alternating with INCOMPLETE ones never prove anything: every window of three holds an unreadable tree
    @Test func completeIncompleteAlternationNeverProves() async {
        let w = RvWorld(pile: rvP, drawn: rvScrambled); w.mode = .absent
        let (e, _, c) = await rvRig(w, record: rvP + rvD)
        var complete = true
        for _ in 0..<40 { w.level = complete ? .complete : .incomplete; complete.toggle(); w.drawn = w.drawn.shuffled(using: &w.rng); _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.everyWindowHasChevronOrIncomplete())
        #expect(w.drags.count <= 3 && w.clicks == 0, "physical=\(w.drags.count)")
    }
    @Test func onlyIncompleteReadsNeverProve() async {
        let w = RvWorld(pile: rvP, drawn: rvScrambled); w.mode = .absent; w.level = .incomplete
        let (e, _, c) = await rvRig(w, record: rvP + rvD)
        for _ in 0..<40 { w.drawn = w.drawn.shuffled(using: &w.rng); _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.drags.count <= 3 && w.clicks == 0)
    }
    // D1: `complete` and `completeExceptSelfPositioning` (the chevron is the agent's own element) DO prove: the cap becomes 20 PHYSICAL drags, never more
    @Test func completeAndExceptSelfPositioningReadsAlternatingDoProveNotFull() async {
        let rec = (1...40).map { "D\($0)" }
        let w = RvWorld(pile: [], drawn: rec.reversed()); w.mode = .absent
        let (e, st, c) = await rvRig(w, record: rec)
        var even = true
        for _ in 0..<80 { w.level = even ? .complete : .completeExceptSelfPositioning; even.toggle(); _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.drags.count == 20 && w.clicks == 0, "physical=\(w.drags.count)")
        #expect(!st.isConverged && rvMenu(st) == rvArrangeLine(st))
    }
    // a failing not-full bar: 20 is on physical drags
    @Test func aNotFullBarWithFailingDragsStaysUnderTwentyPhysical() async {
        let rec = (1...12).map { "D\($0)" }
        let w = RvWorld(pile: [], drawn: rec.reversed()); w.mode = .absent; w.applyProb = 0
        let (e, st, c) = await rvRig(w, record: rec)
        for _ in 0..<200 { w.drawn = w.drawn.shuffled(using: &w.rng); _ = await e.reconcileOnce(); c.adv(120); await e.clearFailures() }
        #expect(w.drags.count <= 20 && w.clicks == 0, "physical=\(w.drags.count)")
        // ejb.16 CHANGED (display source): the menu/Arrange text is the core's status, not the old plan's. The core's `differs plain`.
        #expect(!st.isConverged && rvMenu(st) == CoreStatusText.noMoveToMake)
    }
    // a not-full bar with more than 3 moves converges (the proving reads cost three passes)
    @Test func aNotFullBarConvergesAndOnlyThenSaysConverged() async {
        let rec = (1...10).map { "D\($0)" }
        let w = RvWorld(pile: [], drawn: rec.reversed()); w.mode = .absent
        let (e, st, c) = await rvRig(w, record: rec)
        for i in 0..<30 {
            _ = await e.reconcileOnce(); c.adv(120)
            if w.drawn != rec { #expect(!st.isConverged && rvMenu(st) != ArrangeSections.menuBarMatches, "pass \(i)") }
        }
        #expect(w.drawn == rec && st.isConverged && rvMenu(st) == ArrangeSections.menuBarMatches)
        #expect(w.drags.count <= 20 && w.clicks == 0)
    }
    // more than 20 needed: exactly 20, stopped, the SAME honest text in Arrange and in the menu, no false check anywhere
    @Test func aNotFullBarNeedingMoreThanTwentyStopsAtTwentyAndSaysSo() async {
        let rec = (1...40).map { "D\($0)" }
        let w = RvWorld(pile: [], drawn: rec.reversed()); w.mode = .absent
        let (e, st, c) = await rvRig(w, record: rec)
        for _ in 0..<80 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.drags.count == 20 && w.clicks == 0)
        #expect(!st.isConverged && rvMenu(st) == ArrangeBarState.stoppedWhileDifferingText && rvArrangeLine(st) == ArrangeBarState.stoppedWhileDifferingText)
        #expect(rvFalseChecks(rvRowsOf(st).visible.rows, record: rec, bar: w.drawn).isEmpty)   // Swift's own fallback rows (the stricter legacy invariant)
        #expect(rvFalseChecks(rvCoreRowsOf(st).visible.rows, record: rec, bar: w.drawn).isEmpty)   // the rows the window really shows (the core's lead)
        // sommelier-ejb.7, CHANGED: the window's rows come from the core (only rvCoreRowsOf passes them, as ArrangeViewModel does; rvRowsOf is Swift's fallback rows), and the
        // core ticks a key that is in record order; the property is no FALSE check in either, not 'no tick at all' as under the old plan-led fallback rows.
    }
    // the cap of 20 spent on the reviewer's exact bar: D40 ... D22 D1 ... D21
    @Test func theTwentySpentBarHasNoFalseChecks() async {
        let rec = (1...40).map { "D\($0)" }
        let w = RvWorld(pile: [], drawn: rec.reversed()); w.mode = .absent
        let (e, st, c) = await rvRig(w, record: rec)
        for _ in 0..<80 { _ = await e.reconcileOnce(); c.adv(120) }
        // exactly the 20 allowed drags were made and the bar is NOT in record order.
        // ejb.15 (Wiring 3), CHANGED because the core decides: the bar the 20 drags leave is not the old planner's `D40 ... D22 D1 ... D21` (the core moves the first
        // inversion each time, the old planner a different, minimal-move choice), so only the property is asserted: 20 drags, not in record order.
        #expect(w.drags.count == 20 && w.drawn != rec)
        #expect(rvFalseChecks(rvRowsOf(st).visible.rows, record: rec, bar: w.drawn).isEmpty)
    }
    // chevronless read of a real full bar with D1 and D2 misplaced: no row is a check
    @Test func aChevronlessReadWithTwoMisplacedKeysHasNoFalseChecks() async {
        let bar = ["D3", "D4", "D5", "D6", "D1", "D2"]
        let w = RvWorld(pile: rvP, drawn: bar); w.mode = .absent; w.applyProb = 0
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        for _ in 0..<8 { w.drawn = bar; _ = await e.reconcileOnce(); c.adv(120) }
        #expect(rvFalseChecks(rvRowsOf(st).visible.rows, record: rvP + rvD, bar: bar).isEmpty)
        // (sommelier-ejb.7, CHANGED: see aNotFullBarNeedingMoreThanTwenty...: rvFalseChecks above is the property)
        #expect(!st.isConverged && rvMenu(st) != ArrangeSections.menuBarMatches)
    }
    // the 10:29 Time Machine drop through the REAL actuator: the DROP (not the engine) opens the strip: open, one drag of TM, close
    @Test func timeMachineReplayIsOneUserSessionAndOneDrag() async {
        let pile = ["Net", "Sens", "Astro", "Batt", "Mem", "WiFi"], drawn = ["Jump", "TM", "Sig", "CPU", "Weather", "CC", "Gate"]
        let w = RvWorld(pile: pile, drawn: drawn)
        let (e, st, c) = await rvRig(w, record: pile + drawn)
        for _ in 0..<2 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.events.isEmpty)   // no automatic click, no automatic drag, before the drop
        await e.setLayout(Layout.placedAll(visible: (["TM"] + pile + ["Jump", "Sig", "CPU", "Weather", "CC", "Gate"]).map(k)), moved: [k("TM"), k("TMsibling")])
        for _ in 0..<10 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.drags == ["TM"] && w.events == ["open", "drag:TM", "close"], "events=\(w.events)")
// ejb.16 CHANGED (display source): the menu/Arrange text is the core's status, not the old plan's. The core says `differs plain` (the record puts TM left of the folded keys, which macOS cannot do): never matches.
        #expect(!st.isConverged && rvMenu(st) == CoreStatusText.noMoveToMake)   // sommelier-ejb.7, CHANGED: `isConverged` follows the core, which says `differs` (never matches)
    }
    // D7: a drawn key dropped (beside the fold AND mid-bar) whose drag does not land is ONE physical drag
    @Test func aFailingDrawnDropIsOnePhysicalDrag() async {
        for (name, record, moved) in [("beside the fold", ["D5"] + rvP + ["D1", "D2", "D3", "D4", "D6"], "D5"),
                                      ("mid-bar", rvP + ["D1", "D2", "D5", "D3", "D4", "D6"], "D5")] {
            let w = RvWorld(pile: rvP, drawn: rvD); w.applyProb = 0
            let (e, st, c) = await rvRig(w, record: rvP + rvD)
            for _ in 0..<2 { _ = await e.reconcileOnce(); c.adv(120) }
            await e.setLayout(Layout.placedAll(visible: record.map(k)), moved: [k(moved)])
            for _ in 0..<10 { _ = await e.reconcileOnce(); c.adv(120) }
            #expect(w.drags.count == 1, "\(name): events=\(w.events)")
            #expect(!st.isConverged && rvMenu(st) == rvArrangeLine(st))
        }
    }
    // a folded key dropped right of the fold: ONE session, consumed; the failure reads the same in the menu and in Arrange
    @Test func aFailedFoldedDropIsOneSessionAndTheMenuMatchesArrange() async {
        let w = RvWorld(pile: rvP, drawn: rvD); w.applyProb = 0
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        for _ in 0..<2 { _ = await e.reconcileOnce(); c.adv(120) }
        await e.setLayout(Layout.placedAll(visible: ["P1", "P3", "D1", "P2", "D2", "D3", "D4", "D5", "D6"].map(k)), moved: [k("P2")])
        for _ in 0..<30 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.events.filter { $0 == "open" }.count == 1 && w.drags == ["P2"], "events=\(w.events)")
        let row = rvRowsOf(st).visible.rows.first { $0.key == k("P2") }
        #expect(row?.barState == .cannotPlace(ArrangeBarState.putBackText))
        // ejb.16 CHANGED (display source): the menu/Arrange text is the core's status, not the old plan's. The failed row leads ("1 failed"), then the core's bar-full text.
        #expect(rvMenu(st) == rvArrangeLine(st) && rvMenu(st) == "1 failed · " + ArrangeSections.barFullText(3))   // the hold leads in BOTH; "Working…" never stays
    }
}

@MainActor @Suite struct RvRandom {
    fileprivate func honesty(_ w: RvWorld, _ st: EngineState, _ rec: [String], seed: UInt64, _ bad: inout [String]) {
        let o = st.observed
        guard !o.onBar.isEmpty else { return }
        let c = rvRowsOf(st)
        let drawn = o.onBar.filter { !o.systemOverflow.contains($0) && !$0.isOverflowChevron && !o.foldedParked.contains($0) && $0 != o.overflowChevron }
        let trusted = drawn.filter { !o.uncorroborated.contains($0) && !o.staleOnBar.contains($0) }
        let want = rec.map(k).filter { trusted.contains($0) }
        let inOrder = want == trusted
        for r in c.visible.rows where r.barState == .matches {
            if !inOrder { bad.append("seed \(seed): false check \(r.key) with the drawn order wrong") }
            if o.systemOverflow.contains(r.key) || o.foldedParked.contains(r.key) { bad.append("seed \(seed): pile check \(r.key)") }
        }
        for key in o.systemOverflow.union(o.foldedParked) where st.perItem[key] == .inPlace { bad.append("seed \(seed): pile inPlace \(key)") }
        let menu = StatusLine.text(state: st, trusted: true, conflicting: nil)
        if !inOrder, st.isConverged { bad.append("seed \(seed): isConverged while differing, mode=\(w.mode) drawn=\(trusted) want=\(want)") }
        if !inOrder, menu == "Converged" { bad.append("seed \(seed): menu Converged while differing") }
    }
    fileprivate func run(seeds: Range<UInt64>, reads: Int, tag: String, script: (inout RvRNG, Int, inout Int) -> (RvCM, ReadCompleteness), maxCap: Int, chevronWindowsHold: Bool) async {
        var worst = (0, UInt64(0)); var clicks = 0; var over: [String] = []; var bad: [String] = []
        for seed in seeds {
            var r = RvRNG(s: seed &* 104729 &+ 11)
            let w = RvWorld(pile: rvP, drawn: rvD.shuffled(using: &r), seed: seed)
            w.applyProb = [0.0, 0.5, 1.0].randomElement(using: &r)!; w.scramble = Bool.random(using: &r); w.flipScans = Bool.random(using: &r)
            let (e, st, c) = await rvRig(w, record: rvP + rvD)
            var runLen = 0
            for i in 0..<reads {
                let (m, lvl) = script(&r, i, &runLen)
                w.sync { w.mode = m; w.level = lvl }
                if Int.random(in: 0..<3, using: &r) == 0 { w.sync { w.drawn.shuffle(using: &r) } }
                let staleSet: Set<String> = Int.random(in: 0..<4, using: &r) == 0 ? [rvD.randomElement(using: &r)!] : []
                w.sync { w.staleKeys = staleSet }
                _ = await e.reconcileOnce(); c.adv(120)
                honesty(w, st, rvP + rvD, seed: seed, &bad)
            }
            let n = w.drags.count; clicks += w.clicks
            if n > worst.0 { worst = (n, seed) }
            if chevronWindowsHold { if !w.everyWindowHasChevronOrIncomplete() { over.append("seed \(seed): the script broke its own window property") } }
            if n > maxCap { over.append("seed \(seed) physical drags \(n) > \(maxCap)") }
        }
        print("RAND \(tag): seeds=\(seeds.count) reads=\(reads) worst physical drags=\(worst.0) at seed \(worst.1) clicks=\(clicks)")
        #expect(over.isEmpty, "\(tag): worst \(worst) \(over.prefix(5))")
        #expect(clicks == 0, "\(tag): automatic clicks")
        #expect(bad.isEmpty, "\(tag): \(bad.prefix(5))")
    }
    // A: a chevron (fresh, carried or stale) in every window of three reads
    @Test func chevronInEveryWindowIsAtMostThreePhysicalDrags() async {
        await run(seeds: 0..<400, reads: 14, tag: "chevWindow", script: { r, _, run in
            var m: RvCM = [.fresh, .recent, .stale, .absent, .absent].randomElement(using: &r)!
            if m == .absent { run += 1; if run >= 3 { m = .stale; run = 0 } } else { run = 0 }
            return (m, .complete)
        }, maxCap: 3, chevronWindowsHold: true)
    }
    // B: a chevron OR an unreadable tree in every window (chevronless reads alternate with incomplete ones)
    @Test func chevronOrIncompleteInEveryWindowIsAtMostThreePhysicalDrags() async {
        await run(seeds: 1000..<1400, reads: 14, tag: "incomplete", script: { r, _, run in
            let m: RvCM = [.fresh, .stale, .absent, .absent, .absent, .absent].randomElement(using: &r)!
            if m != .absent { run = 0; return (m, [ReadCompleteness.complete, .incomplete, .completeExceptSelfPositioning].randomElement(using: &r)!) }
            run += 1
            if run >= 3 { run = 0; return (.absent, .incomplete) }
            return (.absent, [ReadCompleteness.complete, .completeExceptSelfPositioning, .incomplete].randomElement(using: &r)!)
        }, maxCap: 3, chevronWindowsHold: true)
    }
    // C: anything at all: at most 20 physical drags, zero clicks
    @Test func anythingAtAllIsAtMostTwentyPhysicalDrags() async {
        await run(seeds: 2000..<2400, reads: 30, tag: "anything", script: { r, _, _ in
            ([.fresh, .recent, .stale, .absent, .absent, .absent].randomElement(using: &r)!, [ReadCompleteness.complete, .complete, .complete, .completeExceptSelfPositioning, .incomplete].randomElement(using: &r)!)
        }, maxCap: 20, chevronWindowsHold: false)
    }
}

@MainActor @Suite struct RvMore {
    // the PRODUCTION loop (requestReconcile, the engine's own chaining) on a not-full bar converges
    @Test func notFullProductionLoopConverges() async throws {
        let rec = (1...10).map { "D\($0)" }
        let w = RvWorld(pile: [], drawn: rec.reversed()); w.mode = .absent
        let (e, st, clk) = await rvRig(w, record: rec)
        await e.requestReconcile(reason: "launch")
        // the production loop: the engine chains a few passes by itself, then waits for the next poll / trigger; the poll is simulated by a request per round
        for round in 0..<30 where w.sync({ w.drawn }) != rec {
            var last = -1, quiet = 0
            for _ in 0..<200 { try await Task.sleep(for: .milliseconds(5)); let n = w.sync { w.drags.count }; if n == last { quiet += 1 } else { quiet = 0; last = n }; if quiet > 12 { break } }
            clk.adv(120)   // the per-minute cap runs on the injected clock
            await e.requestReconcile(reason: "poll \(round)")
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(w.drawn == rec && st.isConverged && w.clicks == 0 && w.drags.count <= 20, "bar=\(w.drawn) drags=\(w.drags.count)")
    }
    // D4: the three "Converged while differing" paths
    @Test func aChevronlessReadWithAStaleKeyAndAReversedBarIsNotConverged() async {
        let w = RvWorld(pile: [], drawn: rvScrambled); w.mode = .absent; w.staleKeys = ["D1"]
        let (e, st, c) = await rvRig(w, record: rvD)
        for _ in 0..<6 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(!st.isConverged && rvMenu(st) != ArrangeSections.menuBarMatches)
        #expect(rvRowsOf(st).visible.rows.filter { $0.barState == .matches }.isEmpty)
    }
    @Test func aFreshChevronWithAStaleKeyAndAReversedBarIsNotConverged() async {
        let w = RvWorld(pile: rvP, drawn: rvScrambled); w.mode = .fresh; w.staleKeys = ["D1"]
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        for _ in 0..<6 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(!st.isConverged && rvMenu(st) != ArrangeSections.menuBarMatches)
        #expect(rvRowsOf(st).visible.rows.filter { $0.barState == .matches }.isEmpty)
    }
    @Test func aFreshChevronWithoutAStaleKeyAndAReversedBarIsNotConverged() async {
        let w = RvWorld(pile: rvP, drawn: rvScrambled); w.mode = .fresh
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        for _ in 0..<6 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(!st.isConverged && rvMenu(st) != ArrangeSections.menuBarMatches)
    }
    // a stale key is why the order cannot be judged: the menu says so rather than Converged
    @Test func aStaleKeyThatMakesTheOrderUnjudgeableIsNamedNotConverged() async {
        // trusted keys D2..D6 are in order; D1 (stale) is the only key out of place and cannot be judged
        let w = RvWorld(pile: [], drawn: ["D2", "D3", "D4", "D5", "D6", "D1"]); w.mode = .absent; w.staleKeys = ["D1"]
        let (e, st, c) = await rvRig(w, record: rvD)
        for _ in 0..<4 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(!st.isConverged)
        // ejb.16 CHANGED (display source): the menu/Arrange text is the core's status, not the old plan's. The core says checking (unread key, no proof); menu and Arrange agree.
        #expect(rvMenu(st) == ArrangeSections.checkingMenuBar && rvArrangeLine(st) == ArrangeSections.checkingMenuBar, "menu=\(rvMenu(st)) arrange=\(rvArrangeLine(st))")
    }
    // ...but a stale key that SITS where the record says does not keep the bar from converging (iStat's stale items are ordinary)
    @Test func aStaleKeyInItsPlaceDoesNotKeepTheBarFromConverging() async {
        let w = RvWorld(pile: [], drawn: rvD); w.mode = .absent; w.staleKeys = ["D6"]
        let (e, st, c) = await rvRig(w, record: rvD)
        for _ in 0..<4 { _ = await e.reconcileOnce(); c.adv(120) }
        // ejb.16 CHANGED (display source): the menu/Arrange text is the core's status, not the old plan's. The core has not proven the bar not full after 4 passes: checking, never matches.
        #expect(!st.isConverged && rvMenu(st) == ArrangeSections.checkingMenuBar, "menu=\(rvMenu(st))")   // sommelier-ejb.7, CHANGED: `isConverged` follows the core, which is still checking (no proof of a not-full bar)
    }
    // launch replay of live-136 on the real actuator: failing and landing drags with alternating incomplete reads and stale iStat items
    @Test func theLaunchReplayNeverClicksAndNeverExceedsThreePhysicalDrags() async {
        let pile = ["Net", "Sens", "Astro", "Batt", "Mem", "WiFi", "Disks", "Focus", "KYA"]
        let rec = pile + ["Jump", "TM", "Signal", "CPU", "Weather", "CC", "Gate", "MCP", "VPN", "FloTile", "Time"]
        let bar = ["Jump", "TM", "Signal", "Weather", "CC", "Gate", "MCP", "FloTile", "VPN", "CPU", "Time"]
        for prob in [0.0, 1.0] {
            let w = RvWorld(pile: pile, drawn: bar); w.applyProb = prob
            let (e, _, c) = await rvRig(w, record: rec)
            for i in 0..<20 { w.level = i % 2 == 0 ? .complete : .incomplete; w.staleKeys = i % 2 == 0 ? [] : ["CPU", "Weather", "Time"]; _ = await e.reconcileOnce(); c.adv(120) }
            #expect(w.clicks == 0 && w.drags.count <= 3, "applyProb=\(prob) physical=\(w.drags.count) events=\(w.events)")
        }
    }
}

@MainActor @Suite struct RvUserActions {
    fileprivate func held(_ bar: [String]) async -> (RvWorld, LayoutEngine, EngineState, RvClock) {
        let w = RvWorld(pile: rvP, drawn: bar); w.applyProb = 0
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        for _ in 0..<6 { _ = await e.reconcileOnce(); c.adv(120) }
        return (w, e, st, c)
    }
    // the budget spent: Re-apply is no dead end (one budget, plus ONE user-authorised strip session), clearFailures (permission) gives nothing back
    @Test func reApplyIsNotADeadEndAndAPermissionResumeGivesNothingBack() async {
        // ejb.15 (Wiring 3), CHANGED because the core decides: a scramble the core can act on (D4 / D5 swapped, away from the churn zone). The fully reversed bar made
        // the old planner spend 3 drags; the core's first move there needs the strip and is withheld, so it would make none. Budget and honesty are asserted as before.
        let w = RvWorld(pile: rvP, drawn: rvSwapped)
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        for _ in 0..<12 { w.drawn = rvSwapped; _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.drags.count == 3 && w.clicks == 0)
        #expect(rvMenu(st) == ArrangeBarState.stoppedWhileDifferingText && rvArrangeLine(st) == rvMenu(st))
        w.events = []; w.drags = []
        await e.clearFailures(); for _ in 0..<6 { w.drawn = rvSwapped; _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.events.isEmpty)   // Accessibility granted / permission resume: nothing
        await e.userRetry(); for _ in 0..<6 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(!w.drags.isEmpty && w.drags.count <= 3 + 1, "re-apply: \(w.events)")
        #expect(w.events.filter { $0 == "open" }.count <= 1)   // at most the ONE granted session
    }
    // a drawn drop with the budget spent: one session, one drag
    @Test func aDrawnDropWithTheBudgetSpentIsOneSessionOneDrag() async {
        let w = RvWorld(pile: rvP, drawn: rvScrambled)
        let (e, _, c) = await rvRig(w, record: rvP + rvD)
        for _ in 0..<12 { w.drawn = rvScrambled; _ = await e.reconcileOnce(); c.adv(120) }
        w.events = []; w.drags = []
        await e.setLayout(Layout.placedAll(visible: (rvP + ["D5", "D1", "D2", "D3", "D4", "D6"]).map(k)), moved: [k("D5")])
        _ = await e.reconcileOnce(); c.adv(120)
        #expect(w.drags == ["D5"] && w.events.filter { $0 == "open" }.count <= 1, "events=\(w.events)")
    }
    // while held: the menu says what Arrange says (the hold text may follow after " · "), the user's own actions still work, one drag each
    @Test func whileHeldTheMenuMatchesArrangeAndUserActionsStillWork() async {
        var (w, e, st, c) = await held(["D1", "D2", "D4", "D3", "D5", "D6"])
        #expect(w.drags.count >= 1 && w.drags.count <= 3)
        // ejb.16 CHANGED (display source): the menu/Arrange text is the core's status, not the old plan's. The core's bar-full text (no separate hold text).
        #expect(rvMenu(st) == rvArrangeLine(st) && rvMenu(st) == ArrangeSections.barFullText(3))
        // a drawn drop while held: its own single drag
        w.drags = []; w.events = []; w.applyProb = 1
        await e.setLayout(Layout.placedAll(visible: (rvP + ["D1", "D2", "D4", "D3", "D6", "D5"]).map(k)), moved: [k("D6")])
        for _ in 0..<3 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.drags.count == 1 && w.drags.first == "D6", "events=\(w.events)")
        // a folded drop right of the fold while held: one session, one drag
        (w, e, st, c) = await held(["D1", "D2", "D4", "D3", "D5", "D6"]); w.drags = []; w.events = []; w.applyProb = 1
        await e.setLayout(Layout.placedAll(visible: ["P1", "P3", "D1", "P2", "D2", "D3", "D4", "D5", "D6"].map(k)), moved: [k("P2")])
        for _ in 0..<3 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.drags == ["P2"] && w.events.filter { $0 == "open" }.count == 1, "events=\(w.events)")
        // Re-apply while held: not a dead end, still one session and one granted drag at most beyond the engine's budget
        (w, e, st, c) = await held(["D1", "D2", "D4", "D3", "D5", "D6"]); w.drags = []; w.events = []; w.applyProb = 1
        await e.userRetry(); for _ in 0..<3 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(!w.drags.isEmpty && w.events.filter { $0 == "open" }.count <= 1, "events=\(w.events)")
        // Try again on a row, and a permission resume
        (w, e, st, c) = await held(["D1", "D2", "D4", "D3", "D5", "D6"]); w.drags = []; w.events = []
        await e.clearFailures(); for _ in 0..<3 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.drags.isEmpty)
    }
    // (D6, the busy re-arm, is pinned in Gdu144AdversarialTests.AdversarialBusyTests)
    // D5: a mismatch BESIDE the fold (the first drawn keys swapped) is never fixed by the engine itself; Re-apply grants ONE strip session for it
    @Test func reApplyFixesAMismatchBesideTheFoldWithExactlyOneSessionAndOneDrag() async {
        let w = RvWorld(pile: rvP, drawn: ["D2", "D1", "D3", "D4", "D5", "D6"])
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        for _ in 0..<8 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.drags.isEmpty && w.clicks == 0)   // beside the fold: the engine never opens the strip by itself
        // ejb.16 CHANGED (display source): the menu/Arrange text is the core's status, not the old plan's. The core's `differs plain`.
        #expect(!st.isConverged && rvMenu(st) == CoreStatusText.noMoveToMake)
        await e.userRetry()
        for _ in 0..<4 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.events.filter { $0 == "open" }.count == 1 && w.drags.count == 1, "events=\(w.events)")
        #expect(w.drawn == rvD && st.isConverged && rvMenu(st) == ArrangeSections.menuBarMatches)
        // the grant is gone: a second mismatch beside the fold is NOT fixed without another press
        w.sync { w.drawn = ["D2", "D1", "D3", "D4", "D5", "D6"] }; w.events = []; w.drags = []
        for _ in 0..<6 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.events.isEmpty)
    }
}

@MainActor @Suite struct RvHeld2 {
    // D4: no read, stale key or chevron mode ever ends "Converged" with the trusted drawn keys out of record order
    @Test func neverConvergedWhileTheTrustedDrawnKeysDiffer() async {
        var bad: [String] = []
        for seed in 0..<100 as Range<UInt64> {
            var r = RvRNG(s: seed &* 7 &+ 3)
            let w = RvWorld(pile: rvP, drawn: rvD.shuffled(using: &r), seed: seed); w.applyProb = 0.5
            let (e, st, c) = await rvRig(w, record: rvP + rvD)
            for _ in 0..<20 {
                let m: RvCM = [.fresh, .recent, .stale, .absent].randomElement(using: &r)!
                let stale = Bool.random(using: &r)
                w.sync { w.mode = m; w.level = .complete; w.staleKeys = stale ? [rvD.randomElement(using: &r)!] : []; if Bool.random(using: &r) { w.drawn.shuffle(using: &r) } }
                _ = await e.reconcileOnce(); c.adv(120)
                let o = st.observed
                let tr = o.onBar.filter { !o.systemOverflow.contains($0) && !$0.isOverflowChevron && !o.foldedParked.contains($0) && !o.uncorroborated.contains($0) && !o.staleOnBar.contains($0) }
                let want = (rvP + rvD).map(k).filter { tr.contains($0) }
                if want != tr, st.isConverged { bad.append("seed \(seed) \(m.rawValue) staleKey=\(!w.staleKeys.isEmpty)") }
            }
        }
        #expect(bad.isEmpty, "\(bad.prefix(5))")
    }
}

// MARK: corrective pass 4

@MainActor @Suite struct RvPassFour {
    // BLOCKER: a user's owed attempt ends with the first regular pass. One edit moves a UNIT with folded and drawn members; the folded drop fails and stays
    // failed (no pass converges); 40 quiet polls later macOS shifts a drawn member: NOTHING happens (no chevron click, no drag) without user input.
    @Test func aUnitEditsOwedAttemptsEndWithTheFirstRegularPass() async {
        for prob in [0.0, 1.0] {
            let pile = ["Net", "Sens", "Mem", "KYA"], drawn = ["Jump", "CPU", "TM", "Weather", "Gate", "VPN", "Time"]
            let w = RvWorld(pile: pile, drawn: drawn); w.applyProb = prob
            let (e, st, c) = await rvRig(w, record: pile + drawn)
            for _ in 0..<2 { _ = await e.regularPassForTests(); c.adv(120) }
            let unit = ["Net", "Sens", "Mem", "CPU", "Weather", "Time"]   // Layout.move returns the whole unit as moved
            await e.setLayout(Layout.placedAll(visible: (["KYA", "Jump"] + unit + ["TM", "Gate", "VPN"]).map(k)), moved: Set(unit.map(k)))
            for _ in 0..<3 { _ = await e.reconcileOnce(); c.adv(120) }   // the user's pass and its chained passes
            #expect(w.events.filter { $0 == "open" }.count <= 1, "one edit, one strip session: \(w.events)")
            _ = await e.regularPassForTests(); c.adv(120)                // the first regular pass ends every owed attempt
            // (sommelier-ejb.7: the owed-attempt state is the core's, `owedExpires`; what is asserted here is its effect, below: nothing acts on a quiet poll)
            let quiet = w.events.count
            for _ in 0..<40 { _ = await e.regularPassForTests(); c.adv(120) }
            #expect(w.events.count == quiet, "prob=\(prob): a quiet poll acted: \(w.events.dropFirst(quiet))")
            // macOS shifts a drawn unit member: still no user input, so no click and no user-exempt drag
            w.sync { w.applyProb = 1; if let i = w.drawn.firstIndex(of: "CPU") { w.drawn.remove(at: i); w.drawn.insert("CPU", at: 0) } }
            let before = w.events.count
            for _ in 0..<8 { _ = await e.regularPassForTests(); c.adv(120) }
            #expect(!w.events.dropFirst(before).contains("open") && w.clicks == w.events.filter { $0 == "open" || $0 == "close" }.count)
            #expect(w.events.dropFirst(before).filter { $0.hasPrefix("drag") }.count <= 3)   // at most the engine's own budget, never a click
            #expect(w.events.dropFirst(quiet).filter { $0 == "open" }.isEmpty)
            // a mid-bar unit member shifts (no strip involved): while the failed pull-out HOLDS the bar, no standing user exemption lets it be dragged
            if prob == 0 {
                w.sync { if let i = w.drawn.firstIndex(of: "Weather") { w.drawn.remove(at: i); w.drawn.append("Weather") } }
                let mid = w.events.count
                for _ in 0..<8 { _ = await e.regularPassForTests(); c.adv(120) }
                #expect(w.events.count == mid, "a held bar was moved by a stale user exemption: \(w.events.dropFirst(mid))")
            }
            _ = st
        }
    }
    // BLOCKER: the same with a two-item unit (a folded and a drawn key) whose folded drop fails
    @Test func aFailedFoldedDropLeavesTheDrawnMembersAttemptNoStandingExemption() async {
        for variant in 0..<4 {
            let w = RvWorld(pile: rvP, drawn: rvD); w.applyProb = 0
            let (e, _, c) = await rvRig(w, record: rvP + rvD)
            for _ in 0..<2 { _ = await e.regularPassForTests(); c.adv(120) }
            await e.setLayout(Layout.placedAll(visible: ["P1", "P3", "D1", "P2", "D2", "D3", "D4", "D5", "D6"].map(k)), moved: [k("P2"), k("D3")])
            for _ in 0..<3 { _ = await e.reconcileOnce(); c.adv(120) }
            for _ in 0..<60 { _ = await e.regularPassForTests(); c.adv(120) }
            let quiet = w.events.count
            w.sync { w.applyProb = 1
                switch variant {
                case 0: w.drawn = ["D3", "D1", "D2", "D4", "D5", "D6"]
                case 1: w.drawn = ["D1", "D3", "D2", "D4", "D5", "D6"]
                case 2: w.drawn = ["D1", "D2", "D4", "D5", "D3", "D6"]
                default: w.drawn = ["D3", "D4", "D5", "D6", "D1", "D2"]
                } }
            for _ in 0..<6 { _ = await e.regularPassForTests(); c.adv(120) }
            #expect(!w.events.dropFirst(quiet).contains("open"), "variant \(variant): a chevron click with no user input: \(w.events.dropFirst(quiet))")
        }
    }
    // item 1: a user's failed drag on a full bar holds it: the same drag is never made twice (drag:D5, drag:D5)
    @Test func aFailedMidBarUserDropIsOneDragAndHoldsTheBar() async {
        let w = RvWorld(pile: rvP, drawn: rvD); w.applyProb = 0
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        for _ in 0..<2 { _ = await e.regularPassForTests(); c.adv(120) }
        await e.setLayout(Layout.placedAll(visible: (rvP + ["D1", "D2", "D5", "D3", "D4", "D6"]).map(k)), moved: [k("D5")])   // mid-bar, not beside the fold
        for _ in 0..<3 { _ = await e.reconcileOnce(); c.adv(120) }
        for _ in 0..<10 { _ = await e.regularPassForTests(); c.adv(120) }
        #expect(w.drags == ["D5"] && w.clicks == 0, "events=\(w.events)")
        _ = st
    }
    // item 2: the hold is released by the proof that the bar is not full
    @Test func theHoldIsReleasedByTheProofThatTheBarIsNotFull() async {
        // ejb.15 (Wiring 3), CHANGED because the core decides: the hold is now set on a bar with a FRESH chevron (the core makes no drag on a chevronless bar that is not
        // yet proven not full), by a failing drag of the one swapped pair; then the chevron goes and three chevronless complete reads release it.
        let rec = (1...6).map { "D\($0)" }
        let w = RvWorld(pile: [], drawn: ["D1", "D2", "D4", "D3", "D5", "D6"]); w.mode = .fresh; w.applyProb = 0
        let (e, st, c) = await rvRig(w, record: rec)
        _ = await e.regularPassForTests(); c.adv(120)   // ejb.19: the first complete read of a full bar is held (settled:false); no drag yet
        #expect(w.drags.isEmpty, "the first complete read of a full bar makes no drag: \(w.events)")
        _ = await e.regularPassForTests(); c.adv(120)   // the second, agreeing read lets the core drag
        let held = w.drags.count
        #expect(held == 1, "the fresh-chevron bar's one failing drag sets the hold: \(w.events)")
        w.sync { w.mode = .absent }
        // chevronless reads 1 and 2: the proof is not complete, so the core still cannot tell (checking); no move
        for _ in 0..<2 { _ = await e.regularPassForTests(); c.adv(120) }
        #expect(st.coreStatus != .differs(.plain) && w.drags.count == held, "before the proof: status=\(String(describing: st.coreStatus)) \(w.events)")
        // the third read arms the proof and the next settled one gains it: the hold is released, the bar is known not full, and the core now says plainly that it has no
        // move to make (the failed key is given up, so no further drag is expected: the release is seen through the status, which stays 'checking' while the hold holds)
        for _ in 0..<6 { _ = await e.regularPassForTests(); c.adv(120) }
        #expect(st.coreStatus == .differs(.plain) && rvMenu(st) == CoreStatusText.noMoveToMake,
                "three chevronless reads (the proof of a not-full bar) released the hold: status=\(String(describing: st.coreStatus)) menu=\(rvMenu(st))")
        #expect(w.drags.count == held, "the released hold makes no drag of the given-up key: \(w.events)")
        #expect(w.clicks == 0, "\(w.events)")
    }
    // item 3: ONE strip session per edit across all moved keys: the folded P2 is pulled out (session), and D3, dropped before the first drawn key (churn zone),
    // would need a second one: it is not made
    @Test func oneEditOpensAtMostOneStripSessionAcrossAMixedUnit() async {
        let w = RvWorld(pile: rvP, drawn: rvD)
        let (e, _, c) = await rvRig(w, record: rvP + rvD)
        for _ in 0..<2 { _ = await e.regularPassForTests(); c.adv(120) }
        await e.setLayout(Layout.placedAll(visible: ["P1", "P3", "D3", "D1", "P2", "D2", "D4", "D5", "D6"].map(k)), moved: [k("P2"), k("D3")])
        for _ in 0..<4 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.events.filter { $0 == "open" }.count == 1, "events=\(w.events)")
        for _ in 0..<6 { _ = await e.regularPassForTests(); c.adv(120) }
        #expect(w.events.filter { $0 == "open" }.count == 1, "events=\(w.events)")
    }
    // item 4: Re-apply clears given-up keys and failures on any bar, so the advice of the stopped text works
    @Test func reApplyClearsGivenUpKeysSoTheAdviceWorks() async {
        let names = ["A", "B", "C", "D", "E", "F", "G", "H"]
        let w = RvWorld(pile: [], drawn: ["A", "B", "C", "F", "D", "E", "G", "H"]); w.mode = .absent; w.applyProb = 0
        let (e, st, c) = await rvRig(w, record: names, assumeFull: false)
        for _ in 0..<40 { _ = await e.regularPassForTests(); c.adv(120) }
        #expect(!st.isConverged)
        w.sync { w.applyProb = 1 }
        await e.userRetry(); for _ in 0..<4 { _ = await e.regularPassForTests(); c.adv(120) }
        #expect(w.drawn == names && st.isConverged && rvMenu(st) == ArrangeSections.menuBarMatches, "bar=\(w.drawn) menu=\(rvMenu(st))")
    }
    // item 6: while the strip is open (held by the user) the engine moves nothing: the PLANNER withholds (no dispatch-gate log), and the DISPATCH gate alone also holds
    @Test func whileTheStripIsOpenTheEngineMovesNothing() async {
        let w = RvWorld(pile: rvP, drawn: ["D2", "D1", "D3", "D4", "D6", "D5"]); w.expanded = true
        let lg = RvLogs()
        let (e, _, c) = await rvRig(w, record: rvP + rvD, logs: lg)
        for _ in 0..<12 { _ = await e.regularPassForTests(); c.adv(120) }
        #expect(w.drags.isEmpty && w.clicks == 0, "events=\(w.events)")
        #expect(!lg.v.contains { $0.contains("not dragged") }, "the planner let a move through to the dispatch gate")
        let w2 = RvWorld(pile: rvP, drawn: ["D2", "D1", "D3", "D4", "D6", "D5"]); w2.expanded = true
        let (e2, _, c2) = await rvRig(w2, record: rvP + rvD)
        for _ in 0..<12 { _ = await e2.regularPassForTests(); c2.adv(120) }
        #expect(w2.drags.isEmpty && w2.clicks == 0, "the dispatch gate alone let a move through while the strip is open: \(w2.events)")
    }
    // item 7: Try again on a failed folded drop grants one fold request and one strip session, for its next pass only
    @Test func tryAgainOnAFailedFoldedDropIsOneSessionAndOneDragForThatPassOnly() async {
        let w = RvWorld(pile: rvP, drawn: rvD); w.applyProb = 0
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        for _ in 0..<2 { _ = await e.regularPassForTests(); c.adv(120) }
        await e.setLayout(Layout.placedAll(visible: ["P1", "P3", "D1", "P2", "D2", "D3", "D4", "D5", "D6"].map(k)), moved: [k("P2")])
        for _ in 0..<3 { _ = await e.reconcileOnce(); c.adv(120) }
        for _ in 0..<10 { _ = await e.regularPassForTests(); c.adv(120) }
        #expect(w.events.filter { $0 == "open" }.count == 1 && w.drags == ["P2"])
        w.sync { w.applyProb = 1 }
        await e.retry(key: k("P2"))
        for _ in 0..<3 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.events.filter { $0 == "open" }.count == 2 && w.drags == ["P2", "P2"], "events=\(w.events)")
        let after = w.events.count
        for _ in 0..<20 { _ = await e.regularPassForTests(); c.adv(120) }
        #expect(w.events.count == after)   // nothing more without another press
        _ = st
    }
    // item 8: the last fresh pile is kept through reads with NO chevron until the bar is proven not full: pile rows stay «, never a check
    @Test func pileRowsStayChevronThroughChevronlessReadsUntilTheProof() async {
        let w = RvWorld(pile: rvP, drawn: rvD)
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        _ = await e.regularPassForTests(); c.adv(120)
        w.sync { w.mode = .absent }
        for i in 0..<2 {
            _ = await e.regularPassForTests(); c.adv(120)
            for key in rvP.map(k) { #expect(rvRowsOf(st).visible.rows.first { $0.key == key }?.barState == .behindChevron && st.perItem[key] == .notFitting, "read \(i)") }   // the fold memory (membership-only) keeps the pile as «; the core's own row for it is cannotTell (not a check either)
        }
    }
    // item 9: a chevron in an UNSETTLED read (one the pass does not act on) still restarts the proof
    @Test func aChevronInAnUnsettledReadRestartsTheProof() async {
        let w = RvWorld(pile: rvP, drawn: rvScrambled); w.mode = .absent; w.applyProb = 1; w.scramble = true
        let (e, _, c) = await rvRig(w, record: rvP + rvD)
        for round in 0..<6 {
            for _ in 0..<2 { _ = await e.regularPassForTests(); c.adv(120) }                 // two evidence reads ...
            w.sync { w.mode = .fresh; w.settledReads = false }                                  // ... an unsettled read WITH a chevron ...
            _ = await e.regularPassForTests(); c.adv(120)
            w.sync { w.mode = .absent; w.settledReads = true }                                  // ... and chevronless again: never three in a row
            _ = round
        }
        #expect(w.drags.count <= 3, "the proof was reached across an unsettled chevron read: \(w.drags.count) drags")
    }
    // item 5: an immovable key out of order is no progress: the menu says what Arrange says, not "Working…"
    @Test func anImmovableKeyOutOfOrderDoesNotKeepTheMenuWorking() async {
        let act = FakeActuator(order: ["A", "Sys2", "Sys1", "B"].map(k), hidden: [], capabilities: RvImmovable(), makeSnapshot: { o, h in FakeMenuBar.snapshot(order: o, hidden: h) })
        let st = EngineState()
        let e = LayoutEngine(observer: RvFakeObserver(act: act), actuator: act, store: InMemoryLayoutStore(Layout.placedAll(visible: ["A", "Sys1", "Sys2", "B"].map(k))),
                             capabilities: RvImmovable(), state: st, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, config: .multiMove)
        await e.start()
        for _ in 0..<6 { _ = await e.reconcileOnce() }
        #expect(rvMenu(st) != "Working…" && rvArrangeLine(st) != "Working…", "menu=\(rvMenu(st)) arrange=\(rvArrangeLine(st))")
        #expect((rvMenu(st) == ArrangeSections.menuBarMatches) == (rvArrangeLine(st) == ArrangeSections.menuBarMatches), "menu=\(rvMenu(st)) arrange=\(rvArrangeLine(st))")   // the same verdict in both
    }
}
private struct RvImmovable: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability { key == k("Sys1") || key == k("Sys2") ? Capability(canMove: false, canHide: false) : Capability(canMove: true, canHide: true) }
}

private struct RvFakeObserver: MenuBarObserver {
    let act: FakeActuator
    func observe() async throws -> [ResolvedItem] { FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await act.order, hidden: await act.hidden)) }
}


@MainActor @Suite struct RvAttribution {
    // THE INVARIANT, over random worlds WITH user actions (drops of folded / drawn keys and whole units, Re-apply, Try again): every chevron click happens
    // inside the pass of a user action or the pass chained from it (zero exceptions); every other drag is a COUNTED engine drag (within the cap, on
    // any bar, and by construction inside no strip session). Drawn-only engine moves on chevron bars are NOT forbidden: they are counted.
    @Test func everyClickIsAUsersAndEveryOtherDragIsACountedEngineDrag() async {
        var violations: [String] = []
        for seed in 0..<150 as Range<UInt64> {
            var r = RvRNG(s: seed &* 7919 &+ 5)
            let w = RvWorld(pile: rvP, drawn: rvD.shuffled(using: &r), seed: seed)
            w.applyProb = [0.0, 0.5, 1.0].randomElement(using: &r)!; w.scramble = Bool.random(using: &r)
            let (e, _, c) = await rvRig(w, record: rvP + rvD)
            var record = rvP + rvD
            var epochDrags = 0, epochAllowance = 3, absentRun = 0
            for i in 0..<24 {
                var m: RvCM = [.fresh, .recent, .stale, .absent, .absent].randomElement(using: &r)!
                if m == .absent { absentRun += 1; if absentRun >= 3 { m = .stale; absentRun = 0 } } else { absentRun = 0 }
                w.sync { w.mode = m; w.level = .complete; if Int.random(in: 0..<3, using: &r) == 0 { w.drawn.shuffle(using: &r) } }
                var windowPasses = 0
                if Int.random(in: 0..<5, using: &r) == 0 {   // a user action
                    switch Int.random(in: 0..<3, using: &r) {
                    case 0:
                        let n = Bool.random(using: &r) ? 1 : 3
                        let moved = Array(record.shuffled(using: &r).prefix(n))
                        for key in moved { record.removeAll { $0 == key }; record.insert(key, at: Int.random(in: 0...record.count, using: &r)) }
                        await e.setLayout(Layout.placedAll(visible: record.map(k)), moved: Set(moved.map(k)))
                        epochAllowance = 3 + n + 1
                    case 1: await e.userRetry(); epochAllowance = 3 + 1 + 1
                    default: await e.retry(key: k(record.randomElement(using: &r)!)); epochAllowance = 3 + 1 + 1
                    }
                    epochDrags = 0
                    windowPasses = 2
                }
                for _ in 0..<max(1, windowPasses) {
                    let before = w.events.count
                    if windowPasses > 0 { _ = await e.reconcileOnce() } else { _ = await e.regularPassForTests() }
                    c.adv(120)
                    let fresh = Array(w.events.dropFirst(before))
                    let drags = fresh.filter { $0.hasPrefix("drag") }.count
                    epochDrags += drags
                    if windowPasses == 0, fresh.contains("open") || fresh.contains("close") { violations.append("seed \(seed) read \(i): a chevron click outside any user pass: \(fresh)") }
                    if epochDrags > epochAllowance { violations.append("seed \(seed) read \(i): \(epochDrags) drags in one epoch (allowance \(epochAllowance))") }
                }
            }
            if w.events.filter({ $0 == "open" }).count != w.events.filter({ $0 == "close" }).count, !w.expanded { violations.append("seed \(seed): unbalanced strip events") }
        }
        #expect(violations.isEmpty, "\(violations.prefix(5))")
    }
}

// MARK: - gdu.144 pass 6: the reviewer's probes (RvReview5*) as permanent, strict tests

@MainActor fileprivate func rvSettle(_ e: LayoutEngine, ms: Int = 400) async {
    var quiet = 0
    for _ in 0..<2000 {
        try? await Task.sleep(for: .milliseconds(5))
        let g = await e.pollGate()
        if !g.busy { quiet += 1 } else { quiet = 0 }
        if quiet * 5 >= ms { return }
    }
}
/// A big edit (six drawn keys reversed) on the full bar `rvP + rvD`: the production drain runs the user's pass and its chain; returns after quiet.
@MainActor fileprivate func rvBigEdit(_ w: RvWorld, pile: [String] = rvP) async -> (LayoutEngine, EngineState, RvClock) {
    let (e, st, c) = await rvRig(w, record: pile + rvD, followUp: .milliseconds(30))
    for _ in 0..<2 { _ = await e.regularPassForTests(); c.adv(120) }
    await e.setLayout(Layout.placedAll(visible: (pile + rvScrambled).map(k)), moved: Set(rvD.map(k)))
    await rvSettle(e, ms: 300)
    return (e, st, c)
}

@MainActor @Suite struct RvPass6Proof {
    // item 1: an UNSETTLED incomplete read ends the pass before the pass-level evidence runs; it must still reset the proof (20 drags -> 3)
    @Test func anUnsettledIncompleteReadResetsTheProof() async {
        let w = RvWorld(pile: rvP, drawn: rvScrambled); w.mode = .absent
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        for i in 0..<45 {
            if i % 3 == 2 { w.sync { w.level = .incomplete; w.settledReads = false } } else { w.sync { w.level = .complete; w.settledReads = true } }
            w.sync { w.drawn.shuffle(using: &w.rng) }
            _ = await e.regularPassForTests(); c.adv(120)
        }
        #expect(w.drags.count <= 3, "physical drags=\(w.drags.count)")
        #expect(w.everyWindowHasChevronOrIncomplete())
        #expect(st.coreStatus == .checking && !st.isConverged)   // never proven: still assumed full
    }

    // item 3: a chevronless read while the bar is still ASSUMED full confirms nothing: no check, not converged, "Checking the menu bar…"
    @Test func aChevronlessLaunchReadOfAnAssumedFullBarConfirmsNothing() async {
        let w = RvWorld(pile: rvP, drawn: rvD); w.mode = .absent   // the order is right; only the bar's fullness is unproven
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        for i in 0..<2 {
            _ = await e.regularPassForTests(); c.adv(120)
            let rows = rvCoreRowsOf(st).visible.rows
            #expect(rows.filter { $0.barState == .matches }.isEmpty, "pass \(i): \(rowsDump(st))")
            #expect(rows.filter { $0.barState == .moving }.isEmpty, "pass \(i): \(rowsDump(st))")
            #expect(!st.isConverged)
            #expect(rvMenu(st) == ArrangeSections.checkingMenuBar && rvArrangeLine(st) == ArrangeSections.checkingMenuBar, "menu=\(rvMenu(st)) arrange=\(rvArrangeLine(st))")
            #expect(w.drags.isEmpty)
        }
    }
    @Test func aStaleChevronLaunchReadStillShowsNoCheckOnTheFoldedKeys() async {
        let w = RvWorld(pile: rvP, drawn: rvD); w.mode = .stale
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        _ = await e.regularPassForTests(); c.adv(120)
        #expect(rvCoreRowsOf(st).visible.rows.filter { r in rvP.map(k).contains(r.key) && r.barState == .matches }.isEmpty)
    }
    // item 3: a key that macOS newly folded, read without a chevron: not a check, and the bar is not converged
    @Test func aFoldShiftReadWithoutAChevronIsNoCheck() async {
        let w = RvWorld(pile: rvP, drawn: rvD)
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        _ = await e.regularPassForTests(); c.adv(120)
        w.sync { w.mode = .absent; w.pile = rvP + ["D1"]; w.drawn = Array(rvD.dropFirst()) }
        _ = await e.regularPassForTests(); c.adv(120)
        let rows = rvCoreRowsOf(st).visible.rows
        #expect(rows.first { $0.key == k("D1") }?.barState != .matches, "\(rowsDump(st))")
        #expect(rows.filter { $0.barState == .matches }.isEmpty, "\(rowsDump(st))")
        #expect(!st.isConverged && rvMenu(st) == ArrangeSections.checkingMenuBar)
    }
    // item 3: ...and it is NOT permanent: on a genuinely plain bar the QUIET POLLS alone supply the proof; then check marks and Converged are normal
    @Test func quietPollScansProveAPlainBarSoTheChecksAndConvergedComeBack() async {
        let w = RvWorld(pile: [], drawn: rvP + rvD); w.mode = .absent
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        _ = await e.regularPassForTests(); c.adv(120)
        #expect(!st.isConverged && rvMenu(st) == ArrangeSections.checkingMenuBar)
        let t = EngineTriggers(engine: e, state: st, scanner: w, resolve: { w.res($0) }, trigger: {}, sleep: { _ in }, now: { c.read() })
        var polls = 0
        while !st.isConverged, polls < 6 { polls += 1; c.adv(10); await t.poll(); await rvSettle(e, ms: 100) }
        #expect(polls <= 3, "polls=\(polls)")
        #expect(st.isConverged && rvMenu(st) == ArrangeSections.menuBarMatches)
        #expect(rvRowsOf(st).visible.rows.filter { $0.barState == .matches }.count == (rvP + rvD).count, "\(rowsDump(st))")
        #expect(w.drags.isEmpty && w.clicks == 0)
    }
    // the polls obey the SAME read-level rules: a chevron, or an incomplete scan, in between restarts the count
    @Test func aPollScanWithAChevronOrAnIncompleteReadRestartsTheProof() async {
        let w = RvWorld(pile: [], drawn: rvP + rvD); w.mode = .absent
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        let t = EngineTriggers(engine: e, state: st, scanner: w, resolve: { w.res($0) }, trigger: {}, sleep: { _ in }, now: { c.read() })
        _ = await e.regularPassForTests(); c.adv(120)   // read 1
        await t.poll(); c.adv(10)                        // read 2
        await e.notePollScan(w.res(w.snap(.fresh)), completeness: .complete)   // a chevron: reset
        await t.poll(); c.adv(10)                        // 1
        await e.notePollScan(w.res(w.snap(.absent)), completeness: .incomplete)   // another level: reset
        await t.poll(); c.adv(10)                        // 1
        await rvSettle(e, ms: 100)
        #expect(!st.isConverged && rvMenu(st) == ArrangeSections.checkingMenuBar, "proven too early: menu=\(rvMenu(st))")
        await t.poll(); await t.poll(); await rvSettle(e, ms: 100)   // 3
        #expect(st.isConverged && rvMenu(st) == ArrangeSections.menuBarMatches)
    }
    // item 3: reaching the proof (by polls alone) releases the hold, and the status stops saying the bar is full
    @Test func theProofFromPollsAloneReleasesTheHold() async {
        let w = RvWorld(pile: rvP, drawn: ["D1", "D2", "D4", "D3", "D5", "D6"]); w.applyProb = 0
        let (e, st, c) = await rvRig(w, record: rvP + rvD)
        for _ in 0..<3 { _ = await e.regularPassForTests(); c.adv(120) }
        w.sync { w.applyProb = 1; w.pile = []; w.drawn = rvP + rvD; w.mode = .absent }   // the display grew: nothing folds any more
        let t = EngineTriggers(engine: e, state: st, scanner: w, resolve: { w.res($0) }, trigger: {}, sleep: { _ in }, now: { c.read() })
        var polls = 0
        while rvMenu(st) != ArrangeSections.menuBarMatches, polls < 6 { polls += 1; c.adv(10); await t.poll(); await rvSettle(e, ms: 100) }
        #expect(polls <= 3, "polls=\(polls)")
        #expect(st.isConverged && rvMenu(st) == ArrangeSections.menuBarMatches, "menu=\(rvMenu(st))")
    }
    // the zero-folded hold text never says "folds 0 items" and names the way out
    @Test func theHoldTextWithNoFoldedItemsNamesReApply() {
        let t = ArrangeSections.barFullText(0)
        #expect(!t.contains("0 item") && !t.contains("folds"))
        #expect(t.contains("Re-apply layout"))
        #expect(ArrangeSections.barFullText(4).contains("folds 4 items"))
    }
}

@MainActor @Suite struct RvPass6OwedAttempts {
    // item 2: the chain of a big edit ends; an hour later Resume (and a reveal toggle) are REGULAR passes: not one event, nothing owed any more
    @Test func resumeAfterTheChainEndedMakesNoMove() async {
        let w = RvWorld(pile: rvP, drawn: rvD)
        let (e, _, c) = await rvBigEdit(w)
        let n0 = w.events.count
        for _ in 0..<3 { c.adv(3600); await e.setUserPaused(true); await e.setUserPaused(false); await rvSettle(e, ms: 200) }
        #expect(Array(w.events.dropFirst(n0)).isEmpty, "\(w.events.dropFirst(n0))")
    }
    @Test func aRevealToggleAfterTheChainEndedMakesNoMove() async {
        let w = RvWorld(pile: rvP, drawn: rvD)
        let (e, _, c) = await rvBigEdit(w)
        let n0 = w.events.count
        for _ in 0..<5 { c.adv(3600); await e.setReveal(hidden: false, alwaysHidden: false); await rvSettle(e, ms: 300) }
        #expect(Array(w.events.dropFirst(n0)).isEmpty, "\(w.events.dropFirst(n0))")
    }
    // ...also with failing drags (the chain ended on a failure)
    @Test func aRevealToggleAfterAFailedChainMakesNoMove() async {
        let w = RvWorld(pile: rvP, drawn: rvD); w.applyProb = 0
        let (e, _, c) = await rvBigEdit(w)
        let n0 = w.events.count
        for _ in 0..<4 { c.adv(3600); await e.setReveal(hidden: true, alwaysHidden: false); await rvSettle(e, ms: 200); c.adv(10); await e.setReveal(hidden: false, alwaysHidden: false); await rvSettle(e, ms: 200) }
        #expect(!w.events.dropFirst(n0).contains("open"), "\(w.events.dropFirst(n0))")
        #expect(w.events.dropFirst(n0).filter { $0.hasPrefix("drag") }.isEmpty, "\(w.events.dropFirst(n0))")
    }
    // what the user SEES after the chain: no stuck "Working…" / "Moving" (a plain bar and a full one)
    @Test func afterABigEditsChainTheStatusIsNeitherWorkingNorMoving() async {
        for (tag, pile, mode) in [("full", rvP, RvCM.fresh), ("plain", [String](), RvCM.absent)] {
            let w = RvWorld(pile: pile, drawn: rvD); w.mode = mode
            let (e, st, _) = await rvBigEdit(w, pile: pile)
            #expect(st.inFlight == nil, "\(tag)")
            #expect(rvMenu(st) != "Working…", "\(tag): menu=\(rvMenu(st))")
            #expect(!rvArrangeLine(st).contains("Moving") && rvArrangeLine(st) != "Working…", "\(tag): arrange=\(rvArrangeLine(st))")
        }
    }
    // however the chain ENDS (here: the dropped key's neighbour is unread, so its move is blocked and never dispatched), nothing stays owed
    @Test func aChainThatMovedNothingLeavesNothingOwed() async {
        let w = RvWorld(pile: rvP, drawn: rvD); w.staleKeys = ["D2"]
        let (e, st, _) = await rvRig(w, record: rvP + rvD, followUp: .milliseconds(30))
        await e.setLayout(Layout.placedAll(visible: (rvP + ["D2", "D1", "D3", "D4", "D5", "D6"]).map(k)), moved: [k("D1")])
        await rvSettle(e, ms: 300)
        #expect(w.drags.isEmpty)
    }
    // an owed attempt is the user's pass and its chain ONLY: a quiet poll right after also leaves nothing behind
    @Test func aPollEndsTheOwedAttempts() async {
        let w = RvWorld(pile: rvP, drawn: rvD)
        let (e, _, c) = await rvBigEdit(w)
        let n0 = w.events.count
        c.adv(3600); await e.requestReconcile(reason: "poll"); await rvSettle(e, ms: 300)
        for _ in 0..<2 { c.adv(3600); await e.requestReconcile(reason: "poll"); await rvSettle(e, ms: 150) }
        #expect(w.events.count == n0, "polls after the chain made a move: \(w.events.dropFirst(n0))")
        // ...and an attempt the user's pass could NOT make (the dropped key's neighbour is unread, so the move is blocked and not dispatched) is not kept owed: once the
        // neighbour reads again, a poll makes no drag of it (the user's pass was the only chance; the engine has no licence for that key)
        let w2 = RvWorld(pile: rvP, drawn: rvD); w2.staleKeys = ["D2"]
        let (e2, _, c2) = await rvRig(w2, record: rvP + rvD, followUp: .milliseconds(30))
        for _ in 0..<2 { _ = await e2.regularPassForTests(); c2.adv(120) }
        await e2.setLayout(Layout.placedAll(visible: (rvP + ["D2", "D1", "D3", "D4", "D5", "D6"]).map(k)), moved: [k("D1")])
        await rvSettle(e2, ms: 300)
        #expect(w2.drags.isEmpty, "the blocked move was not dispatched: \(w2.events)")
        w2.sync { w2.staleKeys = [] }
        for _ in 0..<3 { c2.adv(3600); await e2.requestReconcile(reason: "poll"); await rvSettle(e2, ms: 150) }
        #expect(w2.drags.isEmpty, "a poll after the blocked chain dragged what was owed: \(w2.events)")
    }
}

@MainActor @Suite struct RvPass6Actuator {
    // small item: the actuator also refuses an engine-initiated move when ITS snapshot shows the strip expanded (opened between the read and the drag)
    @Test func anEngineMoveWithTheStripOpenAtTheActuatorsScanIsRefused() async {
        let w = RvWorld(pile: rvP, drawn: ["D1", "D2", "D4", "D3", "D5", "D6"])
        final class Obs: MenuBarObserver, @unchecked Sendable {
            let w: RvWorld; init(_ w: RvWorld) { self.w = w }
            func observe() async throws -> [ResolvedItem] { try await w.observe() }
            func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> BarObservation {
                w.sync { w.expanded = false }; let r = try await w.observeDetailed(progress: progress); w.sync { w.expanded = true }; return r }
        }
        var lc = LiveActuator.Config(); lc.allowFallback = false
        let a = LiveActuator(platform: w, config: lc); let st = EngineState(); let c = RvClock()
        var cfg = LayoutEngine.Config(); cfg.now = { c.read() }; cfg.layoutCoalesce = .zero
        let e = LayoutEngine(observer: Obs(w), actuator: a, store: InMemoryLayoutStore(Layout.placedAll(visible: (rvP + rvD).map(k))), capabilities: RvCapsX(), state: st,
                             resolveSnapshot: { w.res($0) }, sleep: { _ in }, config: cfg)
        await e.start()
        for _ in 0..<6 { _ = await e.regularPassForTests(); c.adv(120) }
        #expect(w.drags.isEmpty, "an engine drag with the strip open at the actuator's scan: \(w.events)")
    }
}

@MainActor @Suite struct RvPass6Mutants {
    // `userRetry` clears given-up keys: after the engine gave up on a key, Re-apply lets it try again
    @Test func reApplyLetsTheEngineTryAGivenUpKeyAgain() async {
        let w = RvWorld(pile: [], drawn: ["D2", "D1", "D3", "D4", "D5", "D6"]); w.mode = .absent; w.applyProb = 0
        let (e, st, c) = await rvRig(w, record: rvD, assumeFull: false)
        for _ in 0..<12 { _ = await e.reconcileOnce(); c.adv(120) }
        let before = w.drags.count
        for _ in 0..<4 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.drags.count == before, "the engine kept dragging a given-up key")
        w.sync { w.applyProb = 1 }
        await e.userRetry()
        for _ in 0..<4 { _ = await e.reconcileOnce(); c.adv(120) }
        #expect(w.drawn == rvD && st.isConverged, "bar=\(w.drawn)")
    }

    // the budget comes back ONLY with a user's intent: `retry(key:)` and a user edit each give a full fresh budget of 3 to the next regular passes
    /// The bar is scrambled again before EVERY pass (something else keeps reordering it), so each engine drag verifies and the order is never reached:
    /// exactly the cap of 3 engine drags is spent, with no failed drag and so no hold.
    /// ejb.15 (Wiring 3), CHANGED because the core decides: the repeated scramble is `rvSwapped` (away from the churn zone), not the fully reversed bar, whose first
    /// move the core withholds (it needs the strip) so no budget would ever be spent; the budget semantics tested are unchanged.
    private func scrambledPass(_ w: RvWorld, _ e: LayoutEngine, _ c: RvClock) async { w.sync { w.drawn = rvSwapped }; _ = await e.regularPassForTests(); c.adv(120) }
    private func spentBar() async -> (RvWorld, LayoutEngine, EngineState, RvClock, Int) {
        let w = RvWorld(pile: rvP, drawn: rvSwapped)
        let (e, st, c) = await rvRig(w, record: rvP + rvD, followUp: .milliseconds(30))
        for _ in 0..<10 { await scrambledPass(w, e, c) }
        return (w, e, st, c, w.drags.count)
    }
    @Test func theSpentBudgetStaysSpentWithoutUserIntent() async {
        let (w, e, _, c, spent) = await spentBar()
        #expect(spent == 3, "spent=\(spent)")
        for _ in 0..<6 { await scrambledPass(w, e, c) }
        await e.clearFailures()   // Accessibility granted / permission resume: NOT a user's intent
        for _ in 0..<6 { await scrambledPass(w, e, c) }
        #expect(w.drags.count == spent)
    }
    // (the user's own pass, its chain and the follow-up regular pass all run inside the settle: count everything after the intent)
    @Test func tryAgainOnARowGivesTheEngineAFreshBudget() async {
        let (w, e, _, c, spent) = await spentBar()
        let n0 = w.drags.count
        // ejb.17, CHANGED because a verified drag the next read contradicts is a strike: the key the scramble keeps undoing (D4, the first inversion of `rvSwapped`) is
        // struck out after 3 drags, so the user's "Try again" must be on THAT row (a retry of D3 resets the budget but cannot free D4).
        await e.retry(key: k("D4")); await rvSettle(e, ms: 300)
        for _ in 0..<10 { await scrambledPass(w, e, c) }
        let made = w.drags.count - n0
        #expect(made >= 3, "drags after Try again: \(made)")
    }
    @Test func aUserEditGivesTheEngineAFreshBudget() async {
        let (w, e, _, c, _) = await spentBar()
        let n0 = w.drags.count
        // ejb.15 (Wiring 3), CHANGED because the core decides: the user drops D2 where the record already has it. The old edit (D2 before D1) put the first inversion on
        // the churn zone, which the core's first-inversion planner then cannot leave (it withholds strip moves), so no engine drag could follow; the budget semantics
        // are unchanged: a user edit gives the engine a fresh budget of 3 for the swapped pair.
        // ejb.17, CHANGED: the dropped key is D4 (the key the scramble undoes and the core struck out), not D2: a user edit gives back the strikes of the keys it moves.
        await e.setLayout(Layout.placedAll(visible: (rvP + rvD).map(k)), moved: [k("D4")]); await rvSettle(e, ms: 300)
        for _ in 0..<10 { await scrambledPass(w, e, c) }
        let made = w.drags.count - n0
        #expect(made >= 3, "drags after the edit: \(made)")
    }
}

@MainActor fileprivate func rowsDump(_ st: EngineState) -> String { rvRowsOf(st).visible.rows.map { "\($0.title.suffix(12)):\($0.barState.map { "\($0)" } ?? "-")" }.joined(separator: " | ") }

// MARK: ejb.19 - the first complete read of a full bar never drags (gdu.80: two agreeing reads)

@MainActor @Suite struct FirstCompleteReadOfAFullBarTests {
    private static let rec = (1...6).map { "D\($0)" }
    private static let swapped = ["D1", "D2", "D4", "D3", "D5", "D6"]

    /// Production config (`assumeFullBarAtLaunch`, the live actuator, real adapter). A drag is applied, so the bar converges.
    @Test func noDragUntilTwoAgreeingCompletePassReadsThenTheDragHappens() async {
        let w = RvWorld(pile: ["P1", "P2"], drawn: Self.swapped); w.mode = .fresh
        let (e, _, c) = await rvRig(w, record: ["P1", "P2"] + Self.rec)
        _ = await e.regularPassForTests(); c.adv(120)
        #expect(w.drags.isEmpty, "the first complete read after launch is held: no drag. \(w.events)")
        _ = await e.regularPassForTests(); c.adv(120)
        #expect(w.drags.count >= 1, "the second agreeing complete read lets the core drag (no stall): \(w.events)")
        for _ in 0..<4 { _ = await e.regularPassForTests(); c.adv(120) }
        #expect(w.drawn == Self.rec, "converged: \(w.drawn) \(w.events)")
    }

    /// The engine asks for the second read itself: ONE requestReconcile (the real draining path) on a full bar chains a follow-up pass that drags,
    /// with no poll and no further request. (reconcileOnce never sets `draining`, so it cannot exercise the chain.)
    @Test func theHeldFirstReadChainsAFollowUpPassThroughTheDrain() async {
        let w = RvWorld(pile: ["P1", "P2"], drawn: Self.swapped); w.mode = .fresh
        let (e, st, _) = await rvRig(w, record: ["P1", "P2"] + Self.rec)
        await e.requestReconcile(reason: "launch")
        await rvSettle(e, ms: 300)
        #expect(w.drags.count >= 1 && st.passCount >= 2, "the held first read chained a second pass that dragged, unprompted: \(w.events)")
    }

    /// After a display reconfiguration the pile read before it proves nothing: the first complete read is held, the second agreeing one drags.
    @Test func afterAScreenChangeTheFirstReadIsHeldAgain() async {
        let w = RvWorld(pile: ["P1", "P2"], drawn: Self.rec); w.mode = .fresh
        let (e, st, c) = await rvRig(w, record: ["P1", "P2"] + Self.rec)
        for _ in 0..<3 { _ = await e.regularPassForTests(); c.adv(120) }
        #expect(w.drags.isEmpty, "a matching bar needs no drag: \(w.events)")
        await e.screensChanged()   // schedules a reconcile with the wall clock (1 s): it does not fire in this test
        w.sync { w.drawn = Self.swapped }
        let before = st.passCount
        _ = await e.regularPassForTests(); c.adv(120)
        #expect(w.drags.isEmpty, "the first complete read after a screen change is held: no drag. \(w.events)")
        _ = await e.regularPassForTests(); c.adv(120)
        #expect(w.drags.count >= 1 && st.passCount >= before + 2, "the second agreeing read lets the core drag: \(w.events)")
    }

    /// The same after a reset point: the pile from before a sleep proves nothing (didWake clears it), so the first read after the wake is held again.
    @Test func afterAWakeTheFirstReadIsHeldAgain() async {
        let w = RvWorld(pile: ["P1", "P2"], drawn: Self.rec); w.mode = .fresh
        let (e, st, c) = await rvRig(w, record: ["P1", "P2"] + Self.rec)
        for _ in 0..<3 { _ = await e.regularPassForTests(); c.adv(120) }
        #expect(w.drags.isEmpty, "a matching bar needs no drag: \(w.events)")
        await e.didWake(settle: .seconds(3600))   // the delayed reconcile uses the wall clock: it does not fire in this test
        w.sync { w.drawn = Self.swapped }
        let before = st.passCount
        _ = await e.regularPassForTests(); c.adv(120)
        #expect(w.drags.isEmpty, "the first complete read after a wake is held: no drag. \(w.events)")
        _ = await e.regularPassForTests(); c.adv(120)
        #expect(w.drags.count >= 1 && st.passCount >= before + 2, "the second agreeing read after the wake lets the core drag: \(w.events)")
    }
}
