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
                              state: state, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in })
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
                                  state: state, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in })
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
        #expect(line == "Converged · Poll paused 5 min: Foo, Bar flapping")
        #expect(ArrangeSections.statusLine(perItem: [:], lastError: nil, isConverged: true, inFlight: false) == "Converged")
    }

    @Test func flappingKeysAreTheSymmetricDifference() {
        let s = BarSignature(selfPositioningOwners: [])
        let a = s.value([ResolvedItem(item: it("A", x: 1), key: .status(ownerKey: "A", autosaveName: "A"), confidence: .inferred),
                         ResolvedItem(item: it("C", x: 2), key: .status(ownerKey: "C", autosaveName: "C"), confidence: .inferred)])!
        let b = s.value([ResolvedItem(item: it("A", x: 1), key: .status(ownerKey: "A", autosaveName: "A"), confidence: .inferred)])!
        #expect(EngineTriggers.flappingKeys(a, b) == ["status:C::C"])
    }
}
