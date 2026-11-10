import Testing
import Foundation
@testable import SommelierCore

// e7t: the 10 s poll compares the observer's agreement signature, confirms a change with a second scan, backs off while
// quiet and skips while the engine is busy.

private struct Caps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
}

private final class ScanQueue: SnapshotScanning, @unchecked Sendable {
    private let lock = NSLock(); private var snaps: [MenuBarSnapshot] = []; private var _scans = 0
    func set(_ s: [[MenuBarItem]]) { lock.lock(); snaps = s.map { MenuBarSnapshot(items: $0, capturedAt: Date()) }; lock.unlock() }
    private func next() -> MenuBarSnapshot {
        lock.lock(); defer { lock.unlock() }
        _scans += 1
        return snaps.count > 1 ? snaps.removeFirst() : snaps[0]
    }
    var scans: Int { lock.lock(); defer { lock.unlock() }; return _scans }
    func scanVisible() async -> MenuBarSnapshot { next() }
    func scan() async -> MenuBarSnapshot { await scanVisible() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0; private var l: [String] = []
    func hit() { lock.lock(); n += 1; lock.unlock() }
    func add(_ s: String) { lock.lock(); l.append(s); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    var logs: [String] { lock.lock(); defer { lock.unlock() }; return l }
}

private final class GateBox: @unchecked Sendable {
    private let lock = NSLock(); private var g = PollGate()
    var value: PollGate { get { lock.lock(); defer { lock.unlock() }; return g } set { lock.lock(); g = newValue; lock.unlock() } }
}

private func it(_ n: String, x: CGFloat, w: CGFloat = 24, stale: Bool = false, onBar: Bool = true) -> MenuBarItem {
    MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: n, title: n, axDescription: "", axIdentifier: n,
                frame: CGRect(x: x, y: 0, width: w, height: 24), source: .appExtras, isOnMenuBar: onBar, stale: stale)
}

private let resolver: @Sendable (MenuBarSnapshot) -> [ResolvedItem] = { s in
    s.items.map { i in
        if i.ownerName == "WiFi" { return ResolvedItem(item: i, key: .module(name: "WiFi"), confidence: .exact) }
        if i.ownerName.hasPrefix("H") { return ResolvedItem(item: i, key: .heuristic(bundleID: i.ownerName, fingerprint: "f", ordinal: 0), confidence: .heuristic) }
        return ResolvedItem(item: i, key: .status(ownerKey: i.ownerName, autosaveName: i.title), confidence: .inferred)
    }
}

private let base = [it("A", x: 100), it("B", x: 140), it("S1", x: 180), it("S2", x: 220), it("WiFi", x: 260)]

private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock(); private var d = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return d }
    func advance(_ s: TimeInterval) { lock.lock(); d = d.addingTimeInterval(s); lock.unlock() }
}

private final class ReportBox: @unchecked Sendable {
    private let lock = NSLock(); private var l: [PollSuppression?] = []
    func add(_ s: PollSuppression?) { lock.lock(); l.append(s); lock.unlock() }
    var all: [PollSuppression?] { lock.lock(); defer { lock.unlock() }; return l }
}

@MainActor
private struct Rig {
    let triggers: EngineTriggers
    let scans: ScanQueue
    let gate: GateBox
    let fired: Counter
    let sleeps: Counter
    var clock = ClockBox()
    var reports = ReportBox()
}

@MainActor
private func rig(_ initial: [MenuBarItem] = base, config: PollConfig = PollConfig()) async -> Rig {
    let clock = ClockBox(), reports = ReportBox()
    let act = FakeActuator(order: [], hidden: [], capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let state = EngineState()
    let engine = LayoutEngine(observer: FixtureObserver([[]]), actuator: act, store: InMemoryLayoutStore(.empty), capabilities: Caps(),
                              state: state, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, config: .plain())
    let scans = ScanQueue(); scans.set([initial])
    let gate = GateBox(), fired = Counter(), sleeps = Counter()
    let t = EngineTriggers(engine: engine, state: state, scanner: scans, resolve: resolver, config: config,
                           signature: BarSignature(selfPositioningOwners: ["S1", "S2"]),
                           log: { fired.add($0) }, gate: { gate.value }, trigger: { fired.hit() }, sleep: { _ in sleeps.hit() },
                           now: { clock.now }, reportSuppression: { reports.add($0) })
    await t.poll()   // establishes the baseline
    return Rig(triggers: t, scans: scans, gate: gate, fired: fired, sleeps: sleeps, clock: clock, reports: reports)
}

@MainActor
@Suite struct PollTriggerTests {
    @Test func selfPositioningOrderFlipDoesNotTrigger() async {
        let r = await rig()
        r.scans.set([[it("A", x: 100), it("B", x: 140), it("S2", x: 180), it("S1", x: 220, stale: true), it("WiFi", x: 260)]])
        await r.triggers.poll()
        #expect(r.fired.count == 0)
        #expect(r.sleeps.count == 0)   // no change detected, so no confirming scan either
    }

    @Test func volatileModulePresenceFlickerDoesNotTrigger() async {
        let r = await rig()
        r.scans.set([Array(base.dropLast())])
        await r.triggers.poll()
        #expect(r.fired.count == 0 && r.sleeps.count == 0)
    }

    @Test func zeroWidthHeuristicNoiseDoesNotTrigger() async {
        let r = await rig()
        r.scans.set([base + [it("HMenuBarAgent", x: 0, w: 0)]])
        await r.triggers.poll()
        #expect(r.fired.count == 0 && r.sleeps.count == 0)
    }

    @Test func selfPositioningItemsVanishingDoesNotTrigger() async {
        let r = await rig()
        r.scans.set([[it("A", x: 100), it("B", x: 140), it("WiFi", x: 260)]])   // the whole of iStat missing from the fast scan
        await r.triggers.poll()
        #expect(r.fired.count == 0 && r.sleeps.count == 0)
    }

    @Test func agentMainMenuHeuristicAndShowHiddenModuleDoNotTrigger() async {
        let r = await rig()
        let agent = MenuBarItem(ownerPID: 1, ownerBundleID: "com.apple.MenuBarAgent", ownerName: "HAgent", title: "x", axDescription: "",
                                axIdentifier: "x", frame: CGRect(x: 5, y: 0, width: 24, height: 24), source: .appExtras, isOnMenuBar: true)
        let hidden = it("ShowHidden", x: 50)
        // Key-level rule: both are exempt by key, whatever their width.
        let sig = BarSignature(selfPositioningOwners: [])
        let a = [ResolvedItem(item: agent, key: .heuristic(bundleID: "com.apple.MenuBarAgent", fingerprint: "f", ordinal: 0), confidence: .heuristic),
                 ResolvedItem(item: hidden, key: .module(name: "Show Hidden Menu Bar Items"), confidence: .exact),
                 ResolvedItem(item: it("A", x: 100), key: .status(ownerKey: "A", autosaveName: "A"), confidence: .inferred)]
        #expect(sig.value(a) == sig.value([a[2]]))
        #expect(sig.value(a)?.presence == ["status:A::A"])
    }

    @Test func thirdPartyAppearingTriggersAfterTheConfirmingScan() async {
        let r = await rig()
        let before = r.scans.scans
        r.scans.set([base + [it("C", x: 300)]])
        await r.triggers.poll()
        #expect(r.fired.count == 1)
        #expect(r.sleeps.count == 1)
        #expect(r.scans.scans == before + 2)   // the detecting scan and the confirming scan
        #expect(r.fired.logs.contains { $0.contains("presence +[status:C::C]") })
    }

    @Test func thirdPartyMovingTriggers() async {
        let r = await rig()
        r.scans.set([[it("B", x: 100), it("A", x: 140), it("S1", x: 180), it("S2", x: 220), it("WiFi", x: 260)]])
        await r.triggers.poll()
        #expect(r.fired.count == 1)
        #expect(r.fired.logs.contains { $0.contains("order reordered") })
    }

    @Test func oneScanFlickerDoesNotTrigger() async {
        let r = await rig()
        r.scans.set([base + [it("C", x: 300)], base])   // appears for one scan only
        await r.triggers.poll()
        #expect(r.fired.count == 0)
        #expect(r.sleeps.count == 1)   // it was confirmed, not trusted
        #expect(r.fired.logs.contains { $0.contains("not confirmed") })
    }

    @Test func periodIsFixedAndWorstCaseDetectionStaysWithinTwelveSeconds() async {
        let c = PollConfig()
        #expect(c.interval == 10 && c.confirmDelay == 1)
        #expect(c.worstCaseDetection <= 12)
    }

    @Test func heuristicAndStaleParkedKeysDoNotTrigger() async {
        let r = await rig()
        r.scans.set([base + [it("H1", x: 0, onBar: false)]])                 // heuristic parked: noise
        await r.triggers.poll()
        r.scans.set([base + [it("P", x: 0, stale: true, onBar: false)]])      // stale parked: a flag, not a change
        await r.triggers.poll()
        #expect(r.fired.count == 0 && r.sleeps.count == 0)
        r.scans.set([base + [it("P", x: 0, onBar: false)]])                   // a fresh identified parked key is a change
        await r.triggers.poll()
        #expect(r.fired.count == 1)
    }

    @Test func skipsWhileBusyHeldUnsettledOrRightAfterAUserAction() async {
        for gate in [PollGate(busy: true), PollGate(holdActive: true), PollGate(observationSettled: false),
                     PollGate(secondsSinceUserAction: 2)] {
            let r = await rig()
            r.scans.set([base + [it("C", x: 300)]])
            r.gate.value = gate
            let before = r.scans.scans
            await r.triggers.poll()
            #expect(r.fired.count == 0)
            #expect(r.scans.scans == before)   // not even scanned
        }
    }

    private func engineSig(_ items: [MenuBarItem]) -> BarSignature.Value {
        let rule = BarSignature(selfPositioningOwners: ["S1", "S2"])
        return rule.value(resolver(MenuBarSnapshot(items: items, capturedAt: Date())))!.forPoll(selfPositioningOwners: ["S1", "S2"])
    }

    @Test func aChangeRightAfterAPassIsCaughtByTheNextPoll() async {
        let r = await rig()
        // The pass observed the bar WITHOUT C (the launch pass ran before the status item existed); C appears afterwards.
        r.gate.value = PollGate(passesStarted: 1, engineSignature: engineSig(base), engineSignatureSerial: 1)
        r.scans.set([base + [it("C", x: 300)]])
        await r.triggers.poll()
        #expect(r.fired.count == 1)
        #expect(r.fired.logs.contains { $0.contains("presence +[status:C::C]") })
    }

    @Test func aNewEngineObservationReplacesTheInPollBaseline() async {
        let r = await rig()   // in-poll baseline = base
        r.gate.value = PollGate(passesStarted: 1, engineSignature: engineSig(base + [it("C", x: 300)]), engineSignatureSerial: 1)
        r.scans.set([base + [it("C", x: 300)]])   // the pass adopted C and the bar still has it
        await r.triggers.poll()
        #expect(r.fired.count == 0 && r.sleeps.count == 0)
    }

    @Test func anUnsettledSkipKeepsTheReferenceSoARealChangeTriggersOnceSettled() async {
        let r = await rig()
        r.scans.set([base + [it("C", x: 300)]])
        r.gate.value = PollGate(observationSettled: false)
        await r.triggers.poll()
        #expect(r.fired.count == 0)
        r.gate.value = PollGate(observationSettled: true)
        await r.triggers.poll()
        #expect(r.fired.count == 1)
    }

    /// Drives the "pass ran" step: the engine publishes `items` as its observation under a new serial.
    private func passPublishes(_ r: Rig, _ items: [MenuBarItem], serial: Int) {
        r.gate.value = PollGate(passesStarted: serial, engineSignature: engineSig(items), engineSignatureSerial: serial)
    }

    @Test func steadyDisagreementTriggersOnePassNotACadence() async {
        // The fast scan always reads F (extra parked-looking item C); the engine's full observation always reads E (no C).
        let r = await rig()
        let f = base + [it("C", x: 300)]
        r.scans.set([f])
        passPublishes(r, base, serial: 1)
        await r.triggers.poll()
        #expect(r.fired.count == 1)
        for n in 2...6 {   // each pass publishes E again under a NEW serial: the guard line is reached every time
            passPublishes(r, base, serial: n)
            await r.triggers.poll()
        }
        #expect(r.fired.count == 1)
        #expect(r.fired.logs.contains { $0.contains("not repeating") })
    }

    @Test func aRepeatedIdenticalChangeTriggersAgainAfterThePassFixedIt() async {
        let r = await rig()
        let x = [it("B", x: 100), it("A", x: 140), it("S1", x: 180), it("S2", x: 220), it("WiFi", x: 260)]
        r.scans.set([x]); passPublishes(r, base, serial: 1)
        await r.triggers.poll()
        #expect(r.fired.count == 1)
        r.scans.set([base]); passPublishes(r, base, serial: 2)   // the pass fixed the bar
        await r.triggers.poll()
        #expect(r.fired.count == 1)
        r.scans.set([x])                                           // the user repeats the same drag
        await r.triggers.poll()
        #expect(r.fired.count == 2)
    }

    @Test func steadyDisagreementWithOneRealChangeCostsExactlyOneExtraPass() async {
        var cfg = PollConfig(); cfg.maxPollPassesPerMinute = 100   // the fake clock does not advance: this test is about the guard, not the cap
        let r = await rig(config: cfg)
        let f = base + [it("C", x: 300)]
        let x = f + [it("D", x: 340)]
        r.scans.set([f]); passPublishes(r, base, serial: 1)
        await r.triggers.poll()
        #expect(r.fired.count == 1)                       // F vs E
        r.scans.set([x]); passPublishes(r, base, serial: 2)
        await r.triggers.poll()
        #expect(r.fired.count == 2)                       // the real change D
        r.scans.set([f]); passPublishes(r, base, serial: 3)   // the pass leaves F vs E again
        await r.triggers.poll()
        #expect(r.fired.count == 3)                       // the single extra pass
        for n in 4...8 { passPublishes(r, base, serial: n); await r.triggers.poll() }
        #expect(r.fired.count == 3)                       // then steady, no cadence
    }

    @Test func aPassStartingDuringTheConfirmationCancelsIt() async {
        let act = FakeActuator(order: [], hidden: [], capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        let state = EngineState()
        let engine = LayoutEngine(observer: FixtureObserver([[]]), actuator: act, store: InMemoryLayoutStore(.empty), capabilities: Caps(),
                                  state: state, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, config: .plain())
        let scans = ScanQueue(), g = GateBox(), fired = Counter()
        let t = EngineTriggers(engine: engine, state: state, scanner: scans, resolve: resolver,
                               signature: BarSignature(selfPositioningOwners: ["S1", "S2"]),
                               gate: { g.value }, trigger: { fired.hit() }, sleep: { _ in g.value = PollGate(busy: true) })
        scans.set([base]); await t.poll()   // baseline
        scans.set([base + [it("C", x: 300)]]); await t.poll()
        #expect(fired.count == 0)
    }

    // gdu.58: cap on poll-triggered passes.
    private func flap(_ r: Rig, polls n: Int, every: TimeInterval = 10) async {
        let f1 = base + [it("C", x: 300)], f2 = base + [it("D", x: 300)]
        for i in 0..<n {
            let f = i % 2 == 0 ? f1 : f2
            r.scans.set([f, f])   // detecting scan and confirming scan
            await r.triggers.poll()
            r.clock.advance(every)
        }
    }

    @Test func twoStateFlapperIsCappedSuppressedAndResumes() async {
        let r = await rig()
        await flap(r, polls: 6)   // 60 s of alternation
        #expect(r.fired.count == 2)   // never more than 2 passes in the first minute
        let sup = r.fired.logs.filter { $0.hasPrefix("poll: suppressed for 5 min — flapping keys:") }
        #expect(sup.count == 1)
        #expect(sup[0].contains("status:C::C") && sup[0].contains("status:D::D"))
        #expect(r.reports.all.count == 1 && r.reports.all[0]?.keys.count == 2)
        // Rest of the 5 min window: still scanning, no passes, no repeated log.
        await flap(r, polls: 20)
        #expect(r.fired.count == 2)
        #expect(r.fired.logs.filter { $0.hasPrefix("poll: suppressed") }.count == 1)
        // Past the window: resumes, the first change triggers as usual.
        await flap(r, polls: 12)
        #expect(r.fired.logs.contains("poll: suppression ended, resuming"))
        #expect(r.reports.all.contains { $0 == nil })
        #expect(r.fired.count >= 3)
    }

    @Test func genuineChangeDuringSuppressionIsNotTriggeredByThePoll() async {
        let r = await rig()
        await flap(r, polls: 4)
        #expect(r.fired.count == 2)
        let before = r.fired.count
        r.scans.set([base + [it("Z", x: 300)]])
        await r.triggers.poll()   // documented: the poll triggers nothing while suppressed
        #expect(r.fired.count == before)
    }

    @Test func steadyBarIsNotAffectedByTheCap() async {
        let r = await rig()
        for _ in 0..<40 { r.scans.set([base]); await r.triggers.poll(); r.clock.advance(10) }
        #expect(r.fired.count == 0)
        #expect(r.reports.all.isEmpty)
        #expect(!r.fired.logs.contains { $0.contains("suppressed") })
    }

    @Test func capCountsOnlyPollTriggeredPasses() async {
        // Triggers from other reasons never reach the poll's counter: with one real change per minute the poll is never capped.
        let r = await rig()
        var items = base
        for n in 0..<4 {
            items = base + [it("N\(n)", x: 300)]
            r.scans.set([items, items]); await r.triggers.poll()
            r.clock.advance(70)
        }
        #expect(r.fired.count == 4)
        #expect(!r.fired.logs.contains { $0.contains("suppressed") })
    }

    @Test func suppressionStatusLineIsNotAnErrorAndNamesTheItems() {
        let line = ArrangeSections.statusLine(perItem: [:], lastError: nil, isConverged: true, inFlight: false, pollPausedNames: ["Foo", "Bar"])
        #expect(line == "Poll paused 5 min: Foo, Bar flapping")
        #expect(ArrangeSections.statusLine(perItem: [:], lastError: nil, isConverged: true, inFlight: false) == ArrangeSections.checkingMenuBar)
    }

    // gdu.60: the e7t confirm pass of a steady disagreement is free; flappers stay capped.
    private let fSig = base + [it("C", x: 300)]
    private func real(_ n: String) -> [MenuBarItem] { fSig + [it(n, x: 340)] }
    /// One poll per step (detecting + confirming scan read the same bar); returns the times (s) at which a pass was requested.
    private func seq(_ r: Rig, _ steps: [([MenuBarItem], TimeInterval)], pass: Bool = true) async -> [Double] {
        var serial = 0, t = 0.0
        var times: [Double] = []
        for (items, adv) in steps {
            serial += 1
            r.scans.set([items, items])
            if pass { passPublishes(r, base, serial: serial) }
            let before = r.fired.count
            await r.triggers.poll()
            if r.fired.count > before { times.append(t) }
            r.clock.advance(adv); t += adv
        }
        return times
    }
    private func suppressions(_ r: Rig) -> [String] { r.fired.logs.filter { $0.hasPrefix("poll: suppressed") } }
    private func alternate(_ states: [[MenuBarItem]], every: TimeInterval, for total: TimeInterval) -> [([MenuBarItem], TimeInterval)] {
        (0..<Int(total / every)).map { (states[$0 % states.count], every) }
    }
    private var flapA: [MenuBarItem] { base + [it("C", x: 300)] }
    private var flapB: [MenuBarItem] { base + [it("D", x: 300)] }

    @Test func confirmPassesOfSteadyDisagreementAreFree() async {
        // (i) the reviewer's sequence: F steady, then three real changes, each followed by its confirm pass.
        let r = await rig()
        let t = await seq(r, [(fSig, 120), (real("X"), 10), (fSig, 10), (real("Y"), 10), (fSig, 31), (real("Z"), 10), (fSig, 10)])
        #expect(t.count == 7)
        #expect(suppressions(r).isEmpty && !r.fired.logs.contains { $0.contains("flapping") } && r.reports.all.isEmpty)
    }

    @Test func steadyDisagreementAfterAnEarlierRealChangeIsNotCapped() async {
        // (ii)
        let r = await rig()
        r.scans.set([base + [it("Q", x: 300)], base + [it("Q", x: 300)]]); await r.triggers.poll()
        r.clock.advance(200)
        let t = await seq(r, [(fSig, 120), (real("D"), 10), (fSig, 10), (real("E"), 10), (fSig, 10)])
        #expect(t.count == 5)
        #expect(suppressions(r).isEmpty && r.reports.all.isEmpty)
    }

    @Test func twoRealChangesFiveSecondsApartThenTheConfirmAreBothAppliedAndNotFlapping() async {
        // (vi): the confirm is still free after two changes (the second must not reset the pre-change signature).
        let r = await rig()
        let t = await seq(r, [(fSig, 120), (real("X"), 5), (real("Y"), 10), (fSig, 10), (fSig, 10)])
        #expect(t == [0, 120, 125, 135])
        #expect(suppressions(r).isEmpty && !r.fired.logs.contains { $0.contains("flapping") } && r.reports.all.isEmpty)
    }

    @Test func aReturnAfterAnotherPassIsNotFree() async {
        // F steady, X (pre F), W 70 s later (X was steady for a minute, so W's pre is X), then F: not a confirm, so counted.
        let r = await rig()
        let t = await seq(r, [(fSig, 120), (real("X"), 70), (real("W"), 10), (fSig, 10), (real("V"), 10)])
        #expect(t == [0, 120, 190, 200])          // V would be the third counted pass in a minute (W, F, V)
        #expect(suppressions(r).count == 1)
    }

    @Test(arguments: [10.0, 15, 20, 25, 29]) func twoStateFlapperFromFreshIsSuppressedAfterTwoPasses(_ every: TimeInterval) async {
        // (iii) from fresh, and again once its 300 s window has ended (polling continues through the window, as live).
        let r = await rig()
        let t = await seq(r, alternate([flapA, flapB], every: every, for: 640), pass: false)
        #expect(t.filter { $0 < 200 }.count == 2)
        #expect(t.filter { $0 >= 300 }.count == 2)
        #expect(t.count == 4 && suppressions(r).count == 2)
        #expect(suppressions(r)[0].contains("status:C::C") && suppressions(r)[0].contains("status:D::D"))
        #expect(r.reports.all.first??.keys.count == 2)
        #expect(r.fired.logs.filter { $0.contains("suppressed") }.count == 2)   // logged once per window
    }

    @Test(arguments: [10.0, 15, 20, 29]) func flapperWhoseStateTriggeredAMinuteEarlierRunsAtMostThreePasses(_ every: TimeInterval) async {
        // (iii) trade-off: the state that had been steady for >= 60 s earns one free confirm, so up to 3 passes.
        let r = await rig()
        _ = await seq(r, [(flapB, 200)], pass: false)
        let t = await seq(r, alternate([flapA, flapB], every: every, for: 640), pass: false)
        #expect(t.filter { $0 < 200 }.count <= 3 && t.filter { $0 < 200 }.count >= 2)
        #expect(t.filter { $0 >= 300 }.count == 2)   // afterwards it is a plain flapper again
        #expect(suppressions(r).count == 2)
    }

    @Test func threeStateAndIrregularCyclesAreSuppressedWithinAMinute() async {
        // (iv)
        let a = base + [it("A1", x: 300)], b = base + [it("B1", x: 300)], c = base + [it("C1", x: 300)]
        for every in [10.0, 15, 20] {
            let r = await rig()
            let t = await seq(r, alternate([a, b, c], every: every, for: 120), pass: false)
            #expect(t.count <= 3 && (t.last ?? 0) < 60 && suppressions(r).count >= 1)
        }
        let r = await rig()
        let t = await seq(r, [(a, 30), (b, 30), (a, 10), (c, 20), (b, 30), (a, 10), (c, 20), (b, 30), (a, 10), (c, 20)], pass: false)
        #expect(t.count <= 3 && suppressions(r).count == 1)
    }

    @Test(arguments: [31.0, 40, 59]) func slowTwoStateFlapperStaysUnderTwoPassesPerMinuteAndEndsAtTheFirstRepeat(_ every: TimeInterval) async {
        // (v) a period >= 31 s never fills the cap by itself (<= 2 passes in any minute); with the repeat horizon (gdu.60) its
        // first repeat (the third pass) takes two slots, so it is still suppressed, after 3 passes.
        let r = await rig()
        let t = await seq(r, alternate([flapA, flapB], every: every, for: 600), pass: false)
        #expect(!suppressions(r).isEmpty)
        for x in t { #expect(t.filter { $0 >= x && $0 < x + 60 }.count <= 2) }
        #expect(t.prefix { $0 < 3 * every + 1 }.count == 3)
    }

    private func value(order: [String], parked: [String] = []) -> BarSignature.Value {
        BarSignature.Value(order: order, presence: [], parked: parked, staleParked: [])
    }

    @Test func flappingKeysSingleLongMoveListsOnlyThatItem() {
        let a = value(order: ["a", "b", "c", "d", "e", "f"]), b = value(order: ["b", "c", "d", "e", "f", "a"])
        #expect(EngineTriggers.flappingKeys(a, b) == ["a"])
    }

    @Test func flappingKeysOrderToParkedListsThatKey() {
        let a = value(order: ["a", "b", "c"]), b = value(order: ["a", "c"], parked: ["b"])
        #expect(EngineTriggers.flappingKeys(a, b) == ["b"])
    }

    @Test func flappingKeysSwapListsOneOfTheTwo() {
        let a = value(order: ["a", "b", "c", "d"]), b = value(order: ["a", "c", "b", "d"])
        #expect(EngineTriggers.flappingKeys(a, b).count == 1)   // one of the two left the longest common order (deterministic: "b")
        #expect(EngineTriggers.flappingKeys(a, a).isEmpty)
    }

    @Test func expiredSuppressionIsNotShown() {
        let key = ItemKey.status(ownerKey: "Foo", autosaveName: "Foo")
        let now = Date(timeIntervalSince1970: 2_000_000)
        let live = PollSuppression(until: now.addingTimeInterval(5), keys: [key])
        #expect(ArrangeSections.pollPausedNames(suppression: live, items: [:], now: now) != nil)
        #expect(ArrangeSections.pollPausedNames(suppression: live, items: [:], now: now.addingTimeInterval(5)) == nil)
        #expect(ArrangeSections.pollPausedNames(suppression: nil, items: [:], now: now) == nil)
    }

    @Test func flappingKeysAreTheSymmetricDifference() {
        let s = BarSignature(selfPositioningOwners: [])
        let a = s.value([ResolvedItem(item: it("A", x: 1), key: .status(ownerKey: "A", autosaveName: "A"), confidence: .inferred),
                         ResolvedItem(item: it("C", x: 2), key: .status(ownerKey: "C", autosaveName: "C"), confidence: .inferred)])!
        let b = s.value([ResolvedItem(item: it("A", x: 1), key: .status(ownerKey: "A", autosaveName: "A"), confidence: .inferred)])!
        #expect(EngineTriggers.flappingKeys(a, b) == ["status:C::C"])
    }
}

// gdu.56: launch/quit detection that does not depend on NSWorkspace notifications (agent apps).
@MainActor
private final class FakeApps: RunningAppsSource {
    var list: [RunningApp] = []
    var handler: (@MainActor () -> Void)?
    func current() -> [RunningApp] { list }
    func startObserving(_ onChange: @escaping @MainActor () -> Void) { handler = onChange }
    func stopObserving() { handler = nil }
}

@MainActor
@Suite struct LaunchQuitTriggerTests {
    private func make(owners: Set<Int32>? = nil) -> (EngineTriggers, FakeApps, Counter) {
        let state = EngineState()
        let engine = LayoutEngine(observer: FixtureObserver([[]]), actuator: FakeActuator(order: [], hidden: [], capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) }), store: InMemoryLayoutStore(.empty), capabilities: Caps(),
                                  state: state, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, config: .plain())
        let apps = FakeApps(), hits = Counter(), scans = ScanQueue(); scans.set([base])
        let t = EngineTriggers(engine: engine, state: state, scanner: scans, resolve: resolver,
                               apps: apps, ownerPIDs: { owners }, launchQuitTrigger: { hits.hit() })
        return (t, apps, hits)
    }
    private let agent = RunningApp(pid: 500, bundleID: "x.dummy", policy: .accessory)

    @Test func accessoryLaunchAndQuitEachRequestOnePass() async {
        let (t, apps, hits) = make()
        t.start(); defer { t.stop() }
        apps.list = [agent]; await t.syncApps()
        #expect(hits.count == 1)
        apps.list = []; await t.syncApps()
        #expect(hits.count == 2)
    }

    @Test func notificationAndKVOWithinDebounceMakeOneRequestWindow() async {
        // Both paths request the same-reason delayed reconcile; the engine replaces the pending one, so close arrivals are one pass.
        // Here: KVO diff requests once, the notification re-arms (a second call of the same reason), no third from repeated KVO.
        let (t, apps, hits) = make()
        t.start(); defer { t.stop() }
        apps.list = [agent]
        await t.syncApps()
        await t.syncApps()   // repeated KVO: no diff, nothing
        #expect(hits.count == 1)
        await t.syncApps(notified: (agent, true))
        #expect(hits.count == 2)   // re-arm, replaces the pending request in the engine
    }

    @Test func lateLaunchNotificationRearmsAfterKVOPass() async {
        let (t, apps, hits) = make()
        t.start(); defer { t.stop() }
        apps.list = [agent]; await t.syncApps()
        #expect(hits.count == 1)
        await t.syncApps(notified: (agent, true))   // arrives after the KVO pass has run
        #expect(hits.count == 2)
    }

    @Test func nonOwnerAccessoryQuitIgnoredOwnerQuitFires() async {
        let (t, apps, hits) = make(owners: [500])
        t.start(); defer { t.stop() }
        let other = RunningApp(pid: 600, bundleID: "o", policy: .accessory)
        apps.list = [agent, other]; await t.syncApps()
        let base = hits.count
        apps.list = [agent]
        await t.syncApps(notified: (other, false))
        #expect(hits.count == base)
        apps.list = []
        await t.syncApps(notified: (agent, false))
        #expect(hits.count == base + 1)
    }

    @Test func prohibitedAppsAndUnownedQuitsAreIgnored() async {
        let (t, apps, hits) = make(owners: [])
        t.start(); defer { t.stop() }
        apps.list = [RunningApp(pid: 7, bundleID: nil, policy: .prohibited)]; await t.syncApps()
        #expect(hits.count == 0)
        apps.list = [agent]; await t.syncApps()
        #expect(hits.count == 1)
        apps.list = []; await t.syncApps()   // known owners exist and exclude pid 500
        #expect(hits.count == 1)
    }

    @Test func quitOfOwnerFiresAndBurstIsOneRequest() async {
        let (t, apps, hits) = make(owners: [500])
        t.start(); defer { t.stop() }
        apps.list = [agent, RunningApp(pid: 501, bundleID: "h", policy: .accessory), RunningApp(pid: 502, bundleID: "h2", policy: .regular)]
        await t.syncApps()
        #expect(hits.count == 1)   // three launches in one change = one request
        apps.list = [RunningApp(pid: 501, bundleID: "h", policy: .accessory), RunningApp(pid: 502, bundleID: "h2", policy: .regular)]
        await t.syncApps()
        #expect(hits.count == 2)
    }
}



// gdu.60: sequences from the reviewer's probe suite, as permanent tests. `run` returns the times (s) of requested passes and of
// suppressions; items nil = poll skipped (busy).
@MainActor
@Suite struct PollCapHorizonTests {
    static let F = base + [it("C", x: 300)]
    static func real(_ n: String) -> [MenuBarItem] { F + [it(n, x: 340)] }
    static let A = base + [it("C", x: 300)], B = base + [it("D", x: 300)]
    func engineSig(_ items: [MenuBarItem]) -> BarSignature.Value {
        let rule = BarSignature(selfPositioningOwners: ["S1", "S2"])
        return rule.value(resolver(MenuBarSnapshot(items: items, capturedAt: Date())))!.forPoll(selfPositioningOwners: ["S1", "S2"])
    }
    func run(_ steps: [([MenuBarItem]?, TimeInterval)], pass: Bool) async -> (passes: [Double], supp: [Double], logs: [String]) {
        let r = await rig()
        var serial = 0, t = 0.0
        var passes: [Double] = [], supp: [Double] = []
        func nSupp() -> Int { r.fired.logs.filter { $0.hasPrefix("poll: suppressed") }.count }
        for (items, adv) in steps {
            serial += 1
            if let items {
                r.scans.set([items, items])
                r.gate.value = pass ? PollGate(passesStarted: serial, engineSignature: engineSig(base), engineSignatureSerial: serial) : PollGate()
            } else { r.gate.value = PollGate(busy: true) }
            let b = r.fired.count, l = nSupp()
            await r.triggers.poll()
            if r.fired.count > b { passes.append(t) }
            if nSupp() > l { supp.append(t) }
            r.clock.advance(adv); t += adv
        }
        return (passes, supp, r.fired.logs)
    }
    func cyc(_ s: [[MenuBarItem]], _ every: TimeInterval, _ total: TimeInterval) -> [([MenuBarItem]?, TimeInterval)] {
        (0..<Int(total / every)).map { (s[$0 % s.count], every) }
    }
    func maxPerMinute(_ p: [Double]) -> Int { p.map { x in p.filter { $0 >= x && $0 < x + 60 }.count }.max() ?? 0 }

    @Test func i_distinctRealChangesKeepTheirFreeConfirms() async {
        let F = Self.F
        let r = await run([(F, 120), (Self.real("X"), 10), (F, 10), (Self.real("Y"), 10), (F, 31), (Self.real("Z"), 10), (F, 10)], pass: true)
        #expect(r.passes == [0, 120, 130, 140, 150, 181, 191] && r.supp.isEmpty)
    }

    @Test func vi_twoChangesFiveSecondsApartThenConfirm() async {
        let F = Self.F
        let r = await run([(F, 120), (Self.real("X"), 5), (Self.real("Y"), 10), (F, 10), (F, 10)], pass: true)
        #expect(r.passes == [0, 120, 125, 135] && r.supp.isEmpty)
    }

    @Test(arguments: [10.0, 14, 15, 20, 25]) func vii_steadyThenSaSbSaIsSuppressed(_ step: TimeInterval) async {
        // F steady, then X, F, Bq, F, X, ...: the second X is a repeat (no free confirm, takes two slots), so it ends after
        // 5 passes (3 counted + 2 free) and at most 5 steps after the first change; and again after the window.
        let F = Self.F
        let r = await run([(F, 120)] + cyc([Self.real("X"), F, Self.real("Bq"), F], step, 640), pass: true)
        let first = r.supp[0]
        #expect(r.passes.filter { $0 < first }.count <= 6)           // includes the F@0 pass
        #expect(first - 120 <= 5 * step)
        #expect(r.supp.count == 2)                                    // suppressed again after the 300 s window
        #expect(maxPerMinute(r.passes) <= 4)
    }

    @Test(arguments: [15.0, 20]) func vii_sameWithoutEnginePublications(_ step: TimeInterval) async {
        let S = base
        let r = await run([(S, 120)] + cyc([Self.A, S, Self.B, S], step, 640), pass: false)
        #expect(r.passes.filter { $0 < r.supp[0] }.count <= 5)
        #expect(r.supp.count == 2 && maxPerMinute(r.passes) <= 4)
    }

    @Test func viii_slowTwoStateFlappers() async {
        let fresh = await run(cyc([Self.A, Self.B], 30, 600), pass: false)
        #expect(maxPerMinute(fresh.passes) <= 2 && fresh.passes.filter { $0 < fresh.supp[0] }.count == 3)
        let steadyS = await run([(base, 120)] + cyc([Self.A, base], 30, 600), pass: false)
        #expect(maxPerMinute(steadyS.passes) <= 2 && !steadyS.supp.isEmpty)
        let steadyF = await run([(Self.F, 120)] + cyc([Self.real("X"), Self.F], 29, 600), pass: true)
        #expect(maxPerMinute(steadyF.passes) <= 3 && !steadyF.supp.isEmpty)
    }

    @Test func ix_identicalRealChangeTwiceCostsTwoSlots() async {
        let F = Self.F, X = Self.real("X")
        let a = await run([(F, 120), (X, 10), (F, 20), (X, 10), (F, 10), (F, 10)], pass: true)
        #expect(a.passes == [0, 120, 130, 150] && a.supp == [160])
        let b = await run([(F, 120), (X, 10), (F, 55), (X, 10), (F, 10), (F, 10)], pass: true)
        #expect(b.passes == [0, 120, 130, 185] && b.supp == [195])   // still a repeat inside the 5 min horizon
    }

    @Test func x_afterSkippedPollsFlappersAreBounded() async {
        let two = await run([(Self.A, 10)] + Array(repeating: (nil, 10), count: 7) + cyc([Self.B, Self.A], 10, 300), pass: false)
        #expect(two.passes.filter { $0 >= 70 }.count <= 3 && two.supp.count >= 1)
        let four = await run([(Self.A, 10)] + Array(repeating: (nil, 10), count: 7) + cyc([Self.B, Self.A, base, Self.A], 15, 600), pass: false)
        #expect(four.passes.filter { $0 >= 70 && $0 < four.supp[0] }.count <= 5 && four.supp.count == 2)
    }

    @Test func xi_theConfirmRunsExactlyOnce() async {
        let r = await run([(Self.F, 120), (Self.real("X"), 10)] + Array(repeating: (Self.F, 10), count: 6), pass: true)
        #expect(r.passes == [0, 120, 130] && r.supp.isEmpty)
    }
}
