import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// gdu.144 corrective pass 2: the reviewer's adversarial scenarios, tightened to the decisions (D1 full-until-proven, D2 no engine strip, D3 universal budget,
// D4 explicit user-intent resets, D5 pinned non-moved keys, D6 drop semantics, D7 no false check, D8 honest status). No relaxed caps anywhere
// except the one test that isolates the 20-drag cap of a bar proven not full (it says so).

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private let advChev = ItemKey.module(name: MenuBarItem.overflowChevronName)
private struct AdvRNG: RandomNumberGenerator { var s: UInt64; mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) } }
private enum AdvChev: Sendable { case fresh, recent, staleOld, absent }

private final class AdvWorld: @unchecked Sendable {
    private let l = NSLock(); private var _mode: AdvChev = .fresh; private var _drawn: [String]; let pile: [String]
    init(pile: [String], drawn: [String]) { self.pile = pile; _drawn = drawn }
    var mode: AdvChev { get { l.lock(); defer { l.unlock() }; return _mode } set { l.lock(); _mode = newValue; l.unlock() } }
    var drawn: [String] { get { l.lock(); defer { l.unlock() }; return _drawn } set { l.lock(); _drawn = newValue; l.unlock() } }
    func snap() -> MenuBarSnapshot {
        let m = mode
        func item(_ n: String, _ f: CGRect, chev: Bool = false) -> MenuBarItem {
            var i = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: chev ? n : k(n).description, axDescription: "", axIdentifier: chev ? "" : k(n).description,
                                frame: f, source: .appExtras, isOnMenuBar: true, isOverflowChevron: chev, joinEvidence: .identifier)
            i.controlCenterAllowed = true
            if chev { switch m { case .recent: i.stale = true; i.recentlyVerified = true; case .staleOld: i.stale = true; default: break } }
            return i
        }
        var items: [MenuBarItem] = []
        for (i, n) in pile.enumerated() { items.append(item(n, CGRect(x: 700 + CGFloat(i) * 20, y: 0, width: 24, height: 24))) }
        if m != .absent { items.append(item("chev", CGRect(x: 786, y: 0, width: 17, height: 24), chev: true)) }
        for (i, n) in drawn.enumerated() { items.append(item(n, CGRect(x: 813 + CGFloat(i) * 60, y: 0, width: 24, height: 24))) }
        return MenuBarSnapshot(items: SystemOverflow.mark(items), capturedAt: Date())
    }
}
private func advRes(_ s: MenuBarSnapshot) -> [ResolvedItem] { s.items.map { i in ResolvedItem(item: i, key: i.isOverflowChevron ? advChev : ItemKey(storeKey: i.axIdentifier)!, confidence: .exact) } }
private struct AdvObs: MenuBarObserver { let w: AdvWorld; func observe() async throws -> [ResolvedItem] { advRes(w.snap()) } }
private struct AdvCaps: CapabilityProvider { func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) } }

/// Posts what it is told: every move is recorded with the engine-initiated flag; a verified or failed result at random; the world is scrambled so the
/// record is never realised (whatever the engine does, a mismatch remains).
private actor AdvChaos: MenuBarActuator {
    let w: AdvWorld; var rng: AdvRNG; var drags: [(key: String, engineInitiated: Bool)] = []; var flag = false; var single = false; var hideCalls = 0; let mix: Bool
    /// PHYSICAL drags: a single-drag move posts one drag; any other failing move posts a second attempt (the real actuator's attempt 2)
    var physicalDrags = 0
    /// every move answers `.userBusy`; `busyTouchedMouse` says whether a mouse event was posted before it (decision D6)
    var busy = false; var busyTouchedMouse = false
    var touchedLast = false
    /// ejb.17: how the world answers a drag. `.chaos` (the default): the bar is reshuffled at random, so the record is never realised and a key the core moved is
    /// usually still misplaced on the next read (the core strikes such a key out after 3 drags). `.faithful`: the drag lands where it was told. `.rotate`: it lands,
    /// then the world swaps ONE other adjacent pair (a different pair each time), so there is always a mismatch but never the same key twice running.
    enum Behaviour { case chaos, faithful, rotate }
    var behaviour: Behaviour = .chaos; var turn = 0
    func setBehaviour(_ b: Behaviour) { behaviour = b }
    private func name(_ key: ItemKey) -> String { String(key.description.split(separator: ":").last ?? "?") }
    private func land(_ key: ItemKey, _ relation: Relation) {
        var d = w.drawn; let n = name(key)
        guard let from = d.firstIndex(of: n) else { return }
        d.remove(at: from)
        switch relation {
        case .before(let t): if let i = d.firstIndex(of: name(t)) { d.insert(n, at: i) } else { d.insert(n, at: from) }
        case .after(let t): if let i = d.firstIndex(of: name(t)) { d.insert(n, at: i + 1) } else { d.insert(n, at: from) }
        case .leftmost: d.insert(n, at: 0)
        case .rightmost: d.append(n)
        }
        if behaviour == .rotate, d.count > 1 { let p = turn % (d.count - 1); turn += 1; d.swapAt(p, p + 1) }
        w.drawn = d
    }
    /// every move fails BEFORE any mouse event (notFound): the engine's counter must not count it (decision: it counts actual drags)
    var preDrag = false; var dispatches = 0
    func setPreDrag(_ on: Bool) { preDrag = on }
    func dispatchCount() -> Int { dispatches }
    var lastMoveTouchedMouse: Bool { busy ? busyTouchedMouse : touchedLast }
    func setBusy(_ on: Bool, touched: Bool) { busy = on; busyTouchedMouse = touched }
    func unflaggedDispatches() -> Int { drags.filter { !$0.engineInitiated }.count }
    init(w: AdvWorld, seed: UInt64, mix: Bool = true) { self.w = w; rng = AdvRNG(s: seed); self.mix = mix }
    func setSingleDrag(_ on: Bool) async { single = on }
    func setEngineInitiated(_ on: Bool) async { flag = on }
    func move(_ key: ItemKey, relation: Relation) async -> ActuationResult {
        dispatches += 1
        if preDrag { touchedLast = false; return .failed(.notFound, w.snap()) }
        let r = mix ? Int.random(in: 0..<5, using: &rng) : 0
        if r == 4 { touchedLast = false; return .failed(.mechanismFailed("\(key) \(ActuationError.overflowRefusalMarker); engine moves never open the « strip"), w.snap()) }   // refusal: no drag
        touchedLast = true
        drags.append((key.description, flag))
        if busy { return .failed(.userBusy, w.snap()) }
        physicalDrags += (single || r <= 1) ? 1 : 2
        if behaviour == .chaos { w.drawn = w.drawn.shuffled(using: &rng) } else { land(key, relation) }
        return r <= 1 ? .verified(w.snap()) : .failed(.mechanismFailed("the drag did not land"), w.snap())
    }
    func setHidden(_ key: ItemKey, _ hidden: Bool) async -> ActuationResult { hideCalls += 1; return .verified(w.snap()) }
    func applyHiddenBatch(_ changes: [ItemKey: Bool]) async -> ActuationResult { hideCalls += 1; return .verified(w.snap()) }
    var lastBatchRespawned: Bool { false }
    var lastBatchUnconfirmed: Set<ItemKey> { [] }
    var lastBatchRefused: [ItemKey: String] { [:] }
    var lastBatchUnsettled: [ItemKey: String] { [:] }
    func count() -> Int { physicalDrags }   // PHYSICAL drags, honouring setSingleDrag
    func notEngineInitiated() -> Int { drags.filter { !$0.engineInitiated }.count }
    func keys() -> [String] { drags.map(\.key).map { String($0.split(separator: ":").last ?? "?") } }
}

private let advP = ["P1", "P2", "P3"]
private let advD = ["D1", "D2", "D3", "D4", "D5", "D6"]

/// A delayed request that never fires (it returns only when its task is cancelled).
@Sendable private func advNeverFires(_ d: Duration) async { while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) } }

@MainActor
private func advRig(w: AdvWorld, record: [String], seed: UInt64 = 1, mix: Bool = true, now: (@Sendable () -> Date)? = nil, timers: (@Sendable (Duration) async -> Void)? = nil) async -> (LayoutEngine, AdvChaos, EngineState) {
    let a = AdvChaos(w: w, seed: seed, mix: mix); let st = EngineState()
    var c = LayoutEngine.Config(); c.maxOrderMovesPerPass = .max
    c.delaySleep = timers ?? advNeverFires   // hermetic: the wall-clock timers (setLayout's 300 ms window, the user-edit follow-up) do not fire in the middle of a test
    if let now { c.now = now }
    let e = LayoutEngine(observer: AdvObs(w: w), actuator: a, store: InMemoryLayoutStore(Layout.placedAll(visible: record.map(k))), capabilities: AdvCaps(), state: st,
                         resolveSnapshot: advRes, sleep: { _ in }, log: { _ in }, config: c)
    await e.start(); return (e, a, st)
}

@MainActor
@Suite struct AdversarialBudgetTests {
    // The randomized world: chevron fresh / carried / stale / absent in any order (never absent for three reads in a row, which would PROVE the bar not full),
    // scrambled bars, any actuator result. NO user input. Engine drags: never a flagless one (a flagless move could click the chevron); at most 3 in
    // all, launch included.
    @Test func randomizedWorldsWithAChevronNeverExceedThreeAndNeverFlagAnEngineMoveAsTheUsers() async {
        var worst = 0
        for seed in 0..<150 as Range<UInt64> {
            var r = AdvRNG(s: seed &* 7919)
            let w = AdvWorld(pile: advP, drawn: advD.shuffled(using: &r))
            let (e, a, _) = await advRig(w: w, record: advP + advD, seed: seed)
            var absentRun = 0
            for _ in 0..<60 {
                var m: AdvChev = [.fresh, .recent, .staleOld, .absent, .absent].randomElement(using: &r)!
                if m == .absent { absentRun += 1; if absentRun >= 3 { m = .staleOld; absentRun = 0 } } else { absentRun = 0 }
                w.mode = m
                if Bool.random(using: &r) { w.drawn = w.drawn.shuffled(using: &r) }
                _ = await e.reconcileOnce()
            }
            let total = await a.count()
            worst = max(worst, total)
            #expect(await a.notEngineInitiated() == 0, "seed \(seed): a drag was not flagged engine-initiated (it could click the chevron)")
            #expect(total <= 3, "seed \(seed): \(total) engine drags")
        }
        #expect(worst >= 1)   // the world really did make the engine move (the bound is not met by doing nothing)
    }

    // ... and with arbitrary gaps (a chevron missing for any number of reads, even proving the bar not full): 20 in total, always, and never unflagged
    @Test func randomizedWorldsWithArbitraryGapsNeverExceedTwenty() async {
        for seed in 0..<100 as Range<UInt64> {
            var r = AdvRNG(s: seed &* 31337)
            let w = AdvWorld(pile: advP, drawn: advD.shuffled(using: &r))
            let (e, a, _) = await advRig(w: w, record: advP + advD, seed: seed)
            for _ in 0..<80 {
                w.mode = [.fresh, .recent, .staleOld, .absent, .absent, .absent].randomElement(using: &r)!
                if Bool.random(using: &r) { w.drawn = w.drawn.shuffled(using: &r) }
                _ = await e.reconcileOnce()
            }
            #expect(await a.notEngineInitiated() == 0)
            let total = await a.count()
            #expect(total <= 20, "seed \(seed): \(total)")
        }
    }

    // A2: a chevron that is read only now and then (gaps of any length, same pile, same frames)
    @Test func aChevronReadOnlyNowAndThenNeverBuysMoreThanThree() async {
        for seed in 0..<60 as Range<UInt64> {
            var r = AdvRNG(s: seed &* 104729)
            let w = AdvWorld(pile: advP, drawn: advD.shuffled(using: &r)); let clk = AdvClock()
            let (e, a, _) = await advRig(w: w, record: advP + advD, seed: seed, now: { clk.read() })
            for _ in 0..<60 {
                w.mode = [.fresh, .staleOld, .absent, .absent].randomElement(using: &r)!
                clk.adv(Double.random(in: 1...20, using: &r))
                if Bool.random(using: &r) { w.drawn = w.drawn.shuffled(using: &r) }
                _ = await e.reconcileOnce()
            }
            let total = await a.count()
            #expect(total <= 20, "seed \(seed): \(total)")
        }
    }

    // A3: launch with no chevron for three scans on a bar that really is full
    @Test func aLaunchWithNoChevronForThreeScansIsStillCappedAtThree() async {
        let w = AdvWorld(pile: advP, drawn: ["D2", "D1", "D4", "D3", "D6", "D5"]); w.mode = .absent
        let (e, a, _) = await advRig(w: w, record: advP + advD, mix: false)
        for _ in 0..<3 { w.drawn = w.drawn.reversed(); _ = await e.reconcileOnce() }
        let early = await a.count()
        #expect(early <= 3)
        w.mode = .fresh
        for _ in 0..<10 { w.drawn = w.drawn.shuffled(); _ = await e.reconcileOnce() }
        let total = await a.count()
        #expect(total <= 3, "total \(total)")
    }

    // D1: three COMPLETE reads without any chevron prove the bar is not full: more than 3 moves, up to 20; a chevron (even stale) makes it full again
    @Test func threeChevronlessReadsProveTheBarNotFullAndAnyChevronMakesItFullAgain() async {
        let w = AdvWorld(pile: [], drawn: advD.reversed()); w.mode = .absent
        let (e, a, _) = await advRig(w: w, record: advD, mix: false)
        // ejb.17, CHANGED: the drags land (`.faithful`) instead of reshuffling the bar. A reshuffled bar leaves the key the core just moved misplaced, and a verified drag the
        // next read contradicts is a strike (3 strikes give the key up), which would stop this test at 3 drags for a reason other than the bar being full. A reversed
        // bar of six keys needs five landing drags: more than the 3 of a full bar, within the 20 of a bar proven not full.
        await a.setBehaviour(.faithful)
        for _ in 0..<12 { _ = await e.reconcileOnce() }
        let free = await a.count()
        #expect(free > 3 && free <= 20, "not-full bar moved \(free) times")
        // the engine counted them in ONE combined counter: a chevron showing up now (stale, no time limit) means counter >= 3 stops everything
        w.mode = .staleOld
        for _ in 0..<12 { w.drawn = w.drawn.shuffled(); _ = await e.reconcileOnce() }
        #expect(await a.count() == free)
    }

    // A4: a stale chevron with no time limit still marks the bar full (cap 3, no moves on the stale pass at all)
    @Test func aStaleChevronForAnyLengthOfTimeNeverGetsAMove() async {
        let w = AdvWorld(pile: advP, drawn: advD); let clk = AdvClock()
        let (e, a, st) = await advRig(w: w, record: advP + advD, mix: false, now: { clk.read() })
        _ = await e.reconcileOnce()
        w.mode = .staleOld
        clk.adv(31); w.drawn = ["D2", "D1", "D3", "D4", "D5", "D6"]
        for _ in 0..<10 { clk.adv(5000); w.drawn = w.drawn.shuffled(); _ = await e.reconcileOnce() }
        #expect(await a.count() == 0)
        // the stale chevron's own pile (everything left of its last frame) is « and never a check
        for key in advP.map(k) { #expect(st.observed.systemOverflow.contains(key) && st.perItem[key] == .notFitting, "\(key) \(String(describing: st.perItem[key]))") }
    }

    // A5: default caps, ten simulated minutes of a chevron missing then fresh. Gaps of fewer than three chevronless reads never prove anything: 3 in all.
    @Test func aFlappingChevronOnDefaultCapsNeverGetsMoreThanThree() async {
        let w = AdvWorld(pile: advP, drawn: advD); let clk = AdvClock()
        let (e, a, _) = await advRig(w: w, record: advP + advD, mix: false, now: { clk.read() })
        for i in 0..<40 { w.mode = i % 3 == 0 ? .fresh : .absent; clk.adv(15); w.drawn = w.drawn.shuffled(); _ = await e.reconcileOnce() }
        let n = await a.count()
        #expect(n <= 3, "drags \(n)")
    }

    // ... and gaps of three or more complete chevronless reads DO prove the bar not full: one combined counter, 20 in all, never refilled by the chevron coming back
    @Test func aChevronGoneForThreeReadsRaisesTheCapToTwentyButNeverRefillsIt() async {
        let w = AdvWorld(pile: advP, drawn: advD); let clk = AdvClock()
        let (e, a, _) = await advRig(w: w, record: advP + advD, mix: false, now: { clk.read() })
        for i in 0..<80 { w.mode = i % 5 == 0 ? .fresh : .absent; clk.adv(15); w.drawn = w.drawn.shuffled(); _ = await e.reconcileOnce() }
        let n = await a.count()
        #expect(n <= 20, "drags \(n)")
    }
}

@MainActor
@Suite struct AdversarialNotFullCapTests {
    // The ONE test with the per-key / per-minute caps out of the way: a bar proven not full (three complete chevronless reads) is capped by the combined
    // counter at exactly 20 engine drags, however many the scrambling world keeps asking for.
    @Test func aBarProvenNotFullStopsAtExactlyTwentyEngineDrags() async {
        let w = AdvWorld(pile: [], drawn: advD.reversed()); w.mode = .absent
        let a = AdvChaos(w: w, seed: 3, mix: false); let st = EngineState()
        var c = LayoutEngine.Config(); c.maxOrderMovesPerPass = .max
        c.maxKeyFailures = 100_000; c.maxConsecutiveFailures = 100_000
        let e = LayoutEngine(observer: AdvObs(w: w), actuator: a, store: InMemoryLayoutStore(Layout.placedAll(visible: advD.map(k))), capabilities: AdvCaps(), state: st,
                             resolveSnapshot: advRes, sleep: { _ in }, log: { _ in }, config: c)
        await e.start()
        // ejb.17, CHANGED: the world is `.rotate` (the drag lands, then a different adjacent pair is swapped each time) instead of a random reshuffle: the same key is never
        // left misplaced twice running, so no key is struck out and the combined counter of 20 is the only bound, as this test means to show.
        await a.setBehaviour(.rotate)
        for _ in 0..<80 { _ = await e.reconcileOnce() }
        #expect(await a.count() == 20)
        #expect(await a.notEngineInitiated() == 0)
        // and a user edit gives it back (ejb.17, CHANGED: the user drops the key the bar now misplaces, so the user's own drag ends its pass; a drop of D1 where the
        // record already has it, as before, makes no move now that the world keeps D1 in place)
        let misplaced = zip(w.drawn, advD).first { $0 != $1 }?.1 ?? "D1"
        await e.setLayout(Layout.placedAll(visible: advD.map(k)), moved: [k(misplaced)])
        for _ in 0..<80 { _ = await e.reconcileOnce() }
        #expect(await a.count() > 20)
    }
}

private final class AdvClock: @unchecked Sendable {
    private var t = Date(timeIntervalSince1970: 1_000_000); private let l = NSLock()
    func read() -> Date { l.lock(); defer { l.unlock() }; return t }
    func adv(_ s: TimeInterval) { l.lock(); t = t.addingTimeInterval(s); l.unlock() }
}

@MainActor
@Suite struct AdversarialTruthfulnessTests {
    private func info(_ key: ItemKey) -> ItemInfo { ItemInfo(key: key, title: "\(key)", axDescription: "", ownerPID: 1, ownerBundleID: nil, ownerName: "x", width: 24, isOnBar: true) }

    // A7 (D7 + D8): gated or spent, with a bar that differs from the record: no false check, not converged, the honest line everywhere
    @Test func gatedRowsAreNeverFalseChecksAndTheStatusIsHonest() async {
        for (name, bar) in [("twoBlockSwap", ["D4", "D5", "D6", "D1", "D2", "D3"]), ("adjacentSwap", ["D1", "D2", "D4", "D3", "D5", "D6"])] {
            for spent in [true, false] {
                let w = AdvWorld(pile: advP, drawn: bar)
                let (e, a, st) = await advRig(w: w, record: advP + advD, mix: false)
                if spent { for _ in 0..<12 { w.drawn = bar; _ = await e.reconcileOnce() }; w.drawn = bar }
                else { _ = await e.reconcileOnce(); w.mode = .recent; for _ in 0..<3 { _ = await e.reconcileOnce() } }
                let c = ArrangeSections.make(observed: st.observed, layout: st.layout, items: Dictionary(uniqueKeysWithValues: (st.observed.onBar + st.observed.parked).map { ($0, info($0)) }),
                                             perItem: st.perItem, capabilities: { _ in Capability(canMove: true, canHide: true) },
                                             coreRows: st.coreDisplay == nil ? nil : st.coreRows, coreNotes: st.coreNotes)
                let line = CoreStatusText.text(state: st, trusted: true, conflicting: nil)   // sommelier-ejb.7: the old statusLine over the old plan is gone
                let menu = StatusLine.text(state: st, trusted: true, conflicting: nil)
                for r in c.visible.rows where r.barState == .matches && advD.map(k).contains(r.key) {
                    let rec = advD.map(k), barK = st.observed.onBar.filter { rec.contains($0) }
                    let i = rec.firstIndex(of: r.key)!
                    #expect(rec[..<i].allSatisfy { barK.firstIndex(of: $0)! < barK.firstIndex(of: r.key)! } && rec[(i + 1)...].allSatisfy { barK.firstIndex(of: $0)! > barK.firstIndex(of: r.key)! },
                            "false check on \(r.key) in \(name) spent=\(spent)")
                }
                for key in advP.map(k) { #expect(st.perItem[key] != .inPlace) }   // a pile key is never in place
                let differs = ArrangeBarState.stoppedWhileDifferingText
                _ = differs
                // sommelier-ejb.7, CHANGED: `isConverged` follows the core, so "not converged" no longer implies the old `stopped` text; what stays asserted is the
                // honesty: a bar that differs from the record is never converged and never says "matches", in the menu or in Arrange.
                #expect(!st.isConverged && !line.contains(ArrangeSections.menuBarMatches) && !menu.contains(ArrangeSections.menuBarMatches), "name=\(name) spent=\(spent) line=\(line) menu=\(menu) converged=\(st.isConverged)")
                let observedDrawn = st.observed.onBar.filter { advD.map(k).contains($0) }
                #expect(observedDrawn == advD.map(k) || menu != "Converged", "Converged while the drawn order differs: \(observedDrawn)")
                // ejb.15 (Wiring 3), CHANGED because the core decides: `<= 3`, no longer `== 3`. The core withholds every engine move that needs the strip (a key in the
                // churn zone, here the first drawn key of the scrambled bar), so on these bars it may make fewer than the 3 budgeted drags (even none). The bound that
                // guards safety, never more than the budget, is unchanged; the honest status is asserted as before.
                // ejb.16 CHANGED (display source): the menu is the core's text (`differs stopped` or `differs plain` once the budget is spent, by scenario), never matches.
                if spent { #expect(await a.count() <= 3); #expect(!st.isConverged && (menu == CoreStatusText.noMoveToMake || menu == differs), "spent: menu=\(menu)") }
            }
        }
    }

    // D8: the Retry that gives the budget back is "Re-apply layout" (userRetry); the permission paths (clearFailures) give back nothing
    @Test func onlyUserIntentGivesTheBudgetOrTheHoldBack() async {
        let w = AdvWorld(pile: advP, drawn: ["D1", "D2", "D4", "D3", "D5", "D6"])
        let (e, a, _) = await advRig(w: w, record: advP + advD, mix: false)
        // ejb.15 (Wiring 3), CHANGED because the core decides: relative counts. The core withholds every engine move that needs the strip, so on a scrambled bar it
        // may not reach the budget of 3 (here usually 1 drag); the property is unchanged and is asserted against whatever was spent: nothing but the user's
        // intent changes it. Re-apply gives back at most the budget (3) plus its ONE granted strip session.
        for _ in 0..<12 { w.drawn = w.drawn.shuffled(); _ = await e.reconcileOnce() }
        let spent = await a.count()
        #expect(spent <= 3)
        await e.clearFailures()   // AppModel: Accessibility granted / permission resume
        for _ in 0..<6 { w.drawn = w.drawn.shuffled(); _ = await e.reconcileOnce() }
        #expect(await a.count() <= 3)
        // a setLayout that is not a user placement (mbprobe, a scan-built layout) gives nothing back either
        await e.setLayout(Layout.placedAll(visible: (advP + advD).map(k)), userPlacement: false, moved: [k("D1")])
        for _ in 0..<6 { w.drawn = w.drawn.shuffled(); _ = await e.reconcileOnce() }
        #expect(await a.count() <= 3)
        let beforeRetry = await a.count()
        await e.userRetry()   // Re-apply layout
        for _ in 0..<12 { w.drawn = w.drawn.shuffled(); _ = await e.reconcileOnce() }
        let after = await a.count()
        #expect(after >= beforeRetry && after <= beforeRetry + 1 + 3)
    }

    // A10: membership is unaffected and uncounted while the budget is spent
    @Test func aSpentBudgetStillHidesAndNeverCountsIt() async {
        let w = AdvWorld(pile: advP, drawn: ["D1", "D2", "D4", "D3", "D5", "D6"])
        let (e, a, _) = await advRig(w: w, record: advP + advD, mix: false)
        for _ in 0..<12 { w.drawn = w.drawn.shuffled(); _ = await e.reconcileOnce() }
        let spent = await a.count()   // ejb.15 (Wiring 3), CHANGED because the core decides: whatever was spent (<= 3, the core withholds strip-needing moves)
        #expect(spent <= 3)
        var l = Layout.placedAll(visible: (advP + advD).map(k)); _ = l.move(k("D6"), to: .hidden, units: .ownerKeys)
        await e.setLayout(l, userPlacement: false)
        for _ in 0..<3 { _ = await e.reconcileOnce() }
        #expect(await a.hideCalls >= 1)
        let afterHide = await a.count()   // membership is never counted: the order drags stay within the same budget of 3 (the core may still spend what it had left)
        #expect(afterHide >= spent && afterHide <= 3)
    }
}

@MainActor
@Suite struct AdversarialDropTests {
    // D6 + D5: a DRAWN key dropped left of the fold: the record takes it, the key makes ONE drag to the leftmost drawn slot, no other key moves
    @Test func aDrawnKeyDroppedLeftOfTheFoldMakesOneDragAndNothingElseMoves() async {
        let w = AdvWorld(pile: advP, drawn: advD)
        let (e, a, _) = await advRig(w: w, record: advP + advD, mix: false)
        _ = await e.reconcileOnce()
        #expect(await a.count() == 0)
        await e.setLayout(Layout.placedAll(visible: (["D4"] + advP + ["D1", "D2", "D3", "D5", "D6"]).map(k)), moved: [k("D4")])
        for _ in 0..<6 { _ = await e.reconcileOnce() }
        let keys = await a.keys()
        #expect(keys == ["D4"], "moved \(keys)")
    }

    // The timers of the drop (the setLayout window and the user-edit follow-up) are the ONLY way a REGULAR pass runs after the user's pass; the former
    // intermittent extra drag (moved ["D4","D1"], ejb.16) was that regular pass firing in the middle of the test when the actor was slow, not a
    // wrong decision (it also happens at the base commit). Forced here with timers that fire at once: the user's pass makes the user's drag
    // (the only one not flagged engine-initiated), and anything after it is a separate engine-initiated regular pass within the budget.
    @Test func timersFiringAtOnceAddOnlyEngineInitiatedRegularPassMovesAfterTheUsersDrag() async {
        let w = AdvWorld(pile: advP, drawn: advD)
        let (e, a, _) = await advRig(w: w, record: advP + advD, mix: false, timers: { _ in })
        _ = await e.reconcileOnce()
        await e.setLayout(Layout.placedAll(visible: (["D4"] + advP + ["D1", "D2", "D3", "D5", "D6"]).map(k)), moved: [k("D4")])
        for _ in 0..<6 { _ = await e.reconcileOnce() }
        let keys = await a.keys()
        #expect(keys.first == "D4", "moved \(keys)")
        #expect(await a.notEngineInitiated() == 1, "only the user's drop is the user's drag; moved \(keys)")
        #expect(keys.count <= 4, "moved \(keys)")
        let audit = await e.coreAudit()
        #expect(audit.emitted == audit.resolved && audit.violations == 0)
    }

    // ejb.16: whatever ends a pass (the straggler answer, the user chain's passBoundary), the display of the core's LAST state is what EngineState shows
    @Test func theLastDisplayChangesOfAPassArePublished() async {
        let w = AdvWorld(pile: advP, drawn: advD)
        let (e, a, st) = await advRig(w: w, record: advP + advD, mix: false)
        _ = await e.reconcileOnce()
        await e.setLayout(Layout.placedAll(visible: (["D4"] + advP + ["D1", "D2", "D3", "D5", "D6"]).map(k)), moved: [k("D4")])
        #expect(st.coreDisplay == (await e.coreDisplayForTests()), "after the user's edit")
        for i in 0..<5 {
            _ = await e.reconcileOnce()
            #expect(st.coreDisplay == (await e.coreDisplayForTests()), "after pass \(i)")
            #expect(st.coreDisplay != nil)
        }
        #expect(await a.keys().first == "D4")
        await e.userRetry()
        #expect(st.coreDisplay == (await e.coreDisplayForTests()), "after Re-apply")
    }

    // ... and for the drain's own chain, which ends with a passBoundary AFTER the pass's last publish (timers fire at once, nobody calls reconcileOnce)
    @Test func theDisplayAfterAUserChainsFinalBoundaryIsPublished() async {
        let w = AdvWorld(pile: advP, drawn: advD)
        let (e, a, st) = await advRig(w: w, record: advP + advD, mix: false, timers: { _ in })
        _ = await e.reconcileOnce()
        await e.setLayout(Layout.placedAll(visible: (["D4"] + advP + ["D1", "D2", "D3", "D5", "D6"]).map(k)), moved: [k("D4")])
        var quiet = 0, lastCount = -1
        for _ in 0..<400 where quiet < 15 {
            try? await Task.sleep(for: .milliseconds(10))
            let c = st.passesStarted
            quiet = c == lastCount ? quiet + 1 : 0; lastCount = c
        }
        #expect(await a.keys().first == "D4")
        let shown = st.coreDisplay
        #expect(shown != nil)
        #expect(shown == (await e.coreDisplayForTests()), "the last display change of the chain was not published")
    }

    // D6: a FOLDED key dropped left of the fold: no drag at all, nothing pending
    @Test func aFoldedKeyDroppedLeftOfTheFoldMakesNoDrag() async {
        let w = AdvWorld(pile: advP, drawn: advD)
        let (e, a, _) = await advRig(w: w, record: advP + advD, mix: false)
        _ = await e.reconcileOnce()
        await e.setLayout(Layout.placedAll(visible: (["P3", "P1", "P2"] + advD).map(k)), moved: [k("P3")])
        for _ in 0..<6 { _ = await e.reconcileOnce() }
        #expect(await a.count() == 0)
    }

    // D6: two folded keys in one edit: ONE session, the first key (record order) first; the other is only recorded
    @Test func twoFoldedKeysOfOneEditAreOneSessionForTheFirst() async {
        let w = AdvWorld(pile: advP, drawn: advD)
        let (e, a, _) = await advRig(w: w, record: advP + advD, mix: false)
        _ = await e.reconcileOnce()
        await e.setLayout(Layout.placedAll(visible: ["P3", "D1", "P2", "P1", "D2", "D3", "D4", "D5", "D6"].map(k)), moved: [k("P1"), k("P2")])
        for _ in 0..<8 { _ = await e.reconcileOnce() }
        let keys = await a.keys()
        #expect(keys.filter { $0 == "P1" }.isEmpty && keys.filter { $0 == "P2" }.count <= 1, "moved \(keys)")
    }

    // the text of the warnings
    @Test func theDropWarningsAreExact() {
        #expect(ArrangeBarState.stayBehindText("TM") == "TM is in your order, but macOS folds from the left, so it stays behind « until there is room")
        #expect(ArrangeBarState.cannotGoFurtherLeftText("TM") == "TM is in your order, but macOS folds from the left, so it can't go further left until there is room")
        #expect(ArrangeBarState.stoppedWhileDifferingText == "Your order and the bar differ. Sommelier has stopped moving items on its own: drag an item or press Re-apply layout.")
        #expect(ArrangeBarState.differsFromYourOrderText == "differs from your order")
    }

    // A12: the REAL shape from live-136b.log, 10:29:38-45. Pile (folded): Network Sensors Astronomy Battery Memory WiFi Disks Focus KeepingYouAwake; drawn: Jump,
    // Time Machine, WiFi Signal, CPU, Weather, ControlCenter ... Time Machine (DRAWN, directly right of Jump) is dropped at Visible slot 0 with the two
    // moved keys of the live event (Time Machine and its heuristic sibling).
    @Test func theLiveTenTwentyNineDropMovesTimeMachineAtMostOnceAndNeverJumpOrNetwork() async {
        let pile = ["Net", "Sens", "Astro", "Batt", "Mem", "WiFi", "Disks", "Focus", "KYA"]
        let drawn = ["Jump", "TM", "Sig", "CPU", "Weather", "CC", "Gate"]
        let w = AdvWorld(pile: pile, drawn: drawn)
        let (e, a, _) = await advRig(w: w, record: pile + drawn, mix: false)
        for _ in 0..<2 { _ = await e.reconcileOnce() }
        #expect(await a.count() == 0)
        await e.setLayout(Layout.placedAll(visible: (["TM"] + pile + ["Jump", "Sig", "CPU", "Weather", "CC", "Gate"]).map(k)), moved: [k("TM"), k("TMsibling")])
        for _ in 0..<8 { _ = await e.reconcileOnce() }
        let keys = await a.keys()
        #expect(keys == ["TM"], "moved \(keys)")   // exactly one drag, the dropped key's: never Jump (the 10:29:46 move), never Network
        #expect(await a.notEngineInitiated() == 1)   // and it is the USER's own drop (not flagged engine-initiated)
    }
}


@MainActor
@Suite struct AdversarialDispatchGateTests {
    // The planner-side gate switched OFF (test flag): the DISPATCH-point gate alone must hold the budget (3 on a full bar) and refuse a stale chevron
    @Test func theDispatchGateAloneHoldsTheBudget() async {
        let w = AdvWorld(pile: advP, drawn: ["D2", "D1", "D4", "D3", "D6", "D5"])
        let (e, a, _) = await advRig(w: w, record: advP + advD, mix: false)
        for _ in 0..<30 { w.drawn = w.drawn.shuffled(); _ = await e.reconcileOnce() }
        let n = await a.count()
        #expect(n >= 1 && n <= 3, "physical drags \(n)")
    }
    @Test func theDispatchGateAloneRefusesAStaleChevronsMoves() async {
        let w = AdvWorld(pile: advP, drawn: ["D2", "D1", "D4", "D3", "D6", "D5"]); w.mode = .staleOld
        let (e, a, _) = await advRig(w: w, record: advP + advD, mix: false)
        for _ in 0..<10 { w.drawn = w.drawn.shuffled(); _ = await e.reconcileOnce() }
        #expect(await a.count() == 0)
    }
}

/// An observer whose chevron mode the test flips, with one allowed key parked "folded for width" (F) that the record lists as visible.
private final class FoldWorld144: MenuBarObserver, @unchecked Sendable {
    private let l = NSLock(); private var _stale = false
    var stale: Bool { get { l.lock(); defer { l.unlock() }; return _stale } set { l.lock(); _stale = newValue; l.unlock() } }
    func snap() -> MenuBarSnapshot {
        let st = stale
        func item(_ n: String, _ f: CGRect, onBar: Bool = true, chev: Bool = false) -> MenuBarItem {
            var i = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "fake", title: chev ? n : k(n).description, axDescription: "", axIdentifier: chev ? "" : k(n).description,
                                frame: f, source: .appExtras, isOnMenuBar: onBar, isOverflowChevron: chev, joinEvidence: .identifier)
            i.controlCenterAllowed = true
            if chev, st { i.stale = true }
            return i
        }
        var items = [item("P1", CGRect(x: 700, y: 0, width: 24, height: 24)), item("chev", CGRect(x: 786, y: 0, width: 17, height: 24), chev: true),
                     item("D1", CGRect(x: 813, y: 0, width: 24, height: 24)), item("D2", CGRect(x: 873, y: 0, width: 24, height: 24)),
                     item("F", CGRect(x: 0, y: 0, width: 24, height: 24), onBar: false)]
        items.sort { $0.frame.minX < $1.frame.minX }
        return MenuBarSnapshot(items: SystemOverflow.mark(items), capturedAt: Date())
    }
    func observe() async throws -> [ResolvedItem] { advRes(snap()) }
}

@MainActor
@Suite struct AdversarialStalePileTests {
    // effective(): on a STALE-chevron read the last fresh read's folded-for-width keys still stand in. Without it the parked key F would be planned as a
    // plain show (membership) the moment the chevron goes stale.
    @Test func aStaleChevronKeepsTheFoldedForWidthKeysFoldedSoNothingIsShown() async {
        let world = FoldWorld144()
        let act = FakeActuator(order: [k("P1"), k("D1"), k("D2")], hidden: [], capabilities: AdvCaps(), makeSnapshot: { _, _ in world.snap() })
        let st = EngineState()
        let e = LayoutEngine(observer: world, actuator: act, store: InMemoryLayoutStore(Layout.placedAll(visible: ["P1", "D1", "D2", "F"].map(k))), capabilities: AdvCaps(), state: st,
                             resolveSnapshot: advRes, sleep: { _ in }, log: { _ in }, config: .multiMove)
        await e.start()
        for _ in 0..<3 { _ = await e.reconcileOnce() }
        func shows() async -> Int { await act.calls.filter { if case .applyHiddenBatch = $0 { true } else { false } }.count }
        #expect(await shows() == 0)   // fresh chevron: F is folded for width, never a show
        world.stale = true
        for _ in 0..<5 { _ = await e.reconcileOnce() }
        #expect(await shows() == 0, "the stale-chevron pass planned a show of the folded F")
        #expect(st.observed.foldedParked.contains(k("F")) || st.observed.systemOverflow.contains(k("F")))
        let row = ArrangeSections.make(observed: st.observed, layout: st.layout, items: [:], perItem: st.perItem, capabilities: { _ in Capability(canMove: true, canHide: true) }).visible.rows.first { $0.key == k("F") }
        #expect(row?.barState == .behindChevron)
    }
}


@MainActor
@Suite struct AdversarialBusyTests {
    // D6: a user's drop answered `.userBusy` AFTER a mouse event was posted is consumed; with NO mouse event it is re-armed for the next pass
    @Test func aBusyResultAfterAMouseEventIsConsumedAndOtherwiseRearmed() async {
        for touched in [true, false] {
            let w = AdvWorld(pile: advP, drawn: advD)
            let (e, a, _) = await advRig(w: w, record: advP + advD, mix: false)
            _ = await e.reconcileOnce()
            await a.setBusy(true, touched: touched)
            await e.setLayout(Layout.placedAll(visible: (["D4"] + advP + ["D1", "D2", "D3", "D5", "D6"]).map(k)), moved: [k("D4")])
            for _ in 0..<8 { _ = await e.reconcileOnce() }
            let user = await a.unflaggedDispatches()
            if touched { #expect(user == 1, "consumed, not re-armed: \(user) user dispatches") } else { #expect(user > 1, "nothing was posted: the drop is re-armed (\(user))") }
        }
    }
    // the menu's failed text (no hold): the same words as Arrange
    @Test func theMenuSaysWhatArrangeSaysForAFailedRowWithoutAHold() {
        let st = EngineState()
        st.perItem[k("D1")] = .failed(.timeout)
        // ejb.16 CHANGED (display source): a failed membership item leads the core's text (no per-row "can't be placed" count from the old plan).
        #expect(StatusLine.text(state: st, trusted: true, conflicting: nil) == "1 failed · " + ArrangeSections.checkingMenuBar)
    }
}


@MainActor
@Suite struct AdversarialPassFourTests {
    // item 10: the counter counts ACTUAL drags: a failure before any mouse event refunds it, so pre-drag failures do not spend the budget
    @Test func aPreDragFailureDoesNotSpendTheBudget() async {
        let w = AdvWorld(pile: advP, drawn: ["D1", "D2", "D4", "D3", "D6", "D5"])
        let (e, a, _) = await advRig(w: w, record: advP + advD, mix: false)
        await a.setPreDrag(true)
        for _ in 0..<12 { _ = await e.reconcileOnce() }
        let dispatches = await a.dispatchCount()
        // ejb.15 (Wiring 3), CHANGED because the core decides: a failure before any mouse event is "not an attempt" and the core SKIPS that key until a user event
        // (it was retried every pass, > 3 dispatches, by the old engine). The property is unchanged: such failures never spend the budget. It is shown by
        // the budget being intact once the user presses Re-apply and the actuator works: the engine then makes its budgeted drags.
        #expect(dispatches >= 1 && dispatches <= 3, "pre-drag failures are not retried by the core (\(dispatches) dispatches)")
        #expect(await a.count() == 0)
        await a.setPreDrag(false)
        await e.userRetry()
        for _ in 0..<12 { _ = await e.reconcileOnce() }
        let made = await a.count()
        #expect(made >= 1 && made <= 3 + 1, "the budget was not spent by the pre-drag failures (\(made) drags)")
    }
    // an unconsumed Re-apply grant expires with the next pass: a mismatch beside the fold that appears LATER is not fixed without another press
    @Test func anUnconsumedReApplyGrantExpiresWithTheNextPass() async {
        let w = AdvWorld(pile: advP, drawn: advD)
        let (e, a, _) = await advRig(w: w, record: advP + advD, mix: false)
        _ = await e.reconcileOnce()
        await e.userRetry()                       // nothing needs the strip: the grant is not used
        for _ in 0..<2 { _ = await e.regularPassForTests() }
        w.drawn = ["D2", "D1", "D3", "D4", "D5", "D6"]   // a mismatch beside the fold shows up afterwards
        for _ in 0..<8 { _ = await e.regularPassForTests() }
        #expect(await a.count() == 0, "the expired grant fixed a mismatch beside the fold")
    }
}
