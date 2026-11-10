import Foundation
import Testing
import DecisionCore
@testable import SommelierCore

// ejb.30: observe-only. The engine reads, decides and displays; nothing it does can change the bar, Control Center or a file.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private func he(_ owner: String, _ fp: String) -> ItemKey { .heuristic(bundleID: owner, fingerprint: fp, ordinal: 0) }
private struct OpenCaps: CapabilityProvider { func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) } }
private final class Sink: @unchecked Sendable {
    private let lock = NSLock(); private var l: [String] = []
    func add(_ s: String) { lock.lock(); l.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return l }
}
private struct ActuatorObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] { FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden)) }
    func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> BarObservation {
        BarObservation(items: try await observe(), settled: true)
    }
}
/// Records every write the engine asks of the store it was given (the engine wraps it, so under the flag none may arrive).
private final class SpyStore: LayoutStore, @unchecked Sendable {
    private let lock = NSLock()
    private var layout: Layout
    private(set) var saves = 0, backups = 0
    init(_ l: Layout) { layout = l }
    func load() throws -> Layout { lock.lock(); defer { lock.unlock() }; return layout }
    func save(_ l: Layout) throws { lock.lock(); defer { lock.unlock() }; saves += 1; layout = l }
    func backupBeforeMigration() throws -> String? { lock.lock(); defer { lock.unlock() }; backups += 1; return "backup" }
}

private struct Rig { let engine: LayoutEngine; let actuator: FakeActuator; let state: EngineState; let store: SpyStore; let sink: Sink; let gate: ObserveOnlyGate }

/// A bar that needs everything: order moves (A..D reversed), a hide (H is drawn, recorded Hidden), a show (S is hidden, recorded Visible),
/// a new item (N is on the bar, not in the record) and a migration drop (the heuristic alias of A).
@MainActor
private func rig(observeOnly: Bool, gate: ObserveOnlyGate? = nil, order: [ItemKey]? = nil, recorded: Layout? = nil, hiddenOnBar: Set<ItemKey> = [k("S")]) async -> Rig {
    let alias = he("com.x.A", "fp")
    let record = recorded ?? Layout(visible: [k("A"), alias, k("B"), k("C"), k("D"), k("S")], hidden: [k("H")], alwaysHidden: [], newItemPolicy: .visibleAtEnd)
    let act = FakeActuator(order: order ?? [k("D"), k("C"), k("B"), k("A"), k("H"), k("N")], hidden: hiddenOnBar, capabilities: OpenCaps(),
                           makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    var c = LayoutEngine.Config.plain()
    c.recordCoreTrace = true; c.minPassInterval = .zero; c.layoutCoalesce = .zero; c.interactionRetry = .seconds(3600); c.observeGate = gate ?? ObserveOnlyGate(fixed: observeOnly)
    let sink = Sink(), state = EngineState(), store = SpyStore(record)
    let engine = LayoutEngine(observer: ActuatorObserver(actuator: act), actuator: act, store: store, capabilities: OpenCaps(), state: state,
                              resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { sink.add($0) }, config: c)
    await engine.start()
    return Rig(engine: engine, actuator: act, state: state, store: store, sink: sink, gate: c.observeGate)
}

@MainActor
@Suite struct ObserveOnlyEngineTests {
    @Test func aWorldThatNeedsEverythingChangesNothing() async {
        let r = await rig(observeOnly: true)
        let original = r.store.saves
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        // a user drop (composed layout), a Re-apply, a panel reveal, more passes
        var edited = r.state.layout
        edited.visible.removeAll { $0 == k("D") }; edited.visible.insert(k("D"), at: 0)
        _ = await r.engine.setLayout(edited, moved: [k("D")])
        _ = await r.engine.reconcileOnce()
        await r.engine.userRetry(); await r.engine.requestReconcile()
        _ = await r.engine.reconcileOnce()
        await r.engine.setReveal(hidden: true, alwaysHidden: false)
        _ = await r.engine.reconcileOnce()
        await r.engine.setReveal(hidden: false, alwaysHidden: false)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }

        let calls = await r.actuator.calls, strip = await r.actuator.stripEvents, order = await r.actuator.order
        #expect(calls.isEmpty, "a mutating actuator call reached the actuator: \(calls)")
        #expect(strip.isEmpty)
        #expect(order == [k("D"), k("C"), k("B"), k("A"), k("H"), k("N")], "the bar was changed")
        #expect(r.store.saves == original && r.store.backups == 0, "the store was written: saves \(r.store.saves), backups \(r.store.backups)")
        let lines = r.sink.lines
        #expect(lines.contains { $0.hasPrefix("observe-only: would move ") && $0.contains("(engine, strip:") }, Comment(rawValue: "would-move lines: \(lines.filter { $0.contains("observe-only") })"))
        #expect(lines.contains { $0.hasPrefix("observe-only: would hide ") })
        #expect(lines.contains { $0.hasPrefix("observe-only: would show ") })
        #expect(lines.contains { $0.hasPrefix("observe-only: would drop ") })
        #expect(lines.contains { $0 == "observe-only: would save layout" })
        #expect(!lines.contains { $0.contains("gdu.145 migration dropped") || $0.contains("backup written") })
        #expect(!r.state.layout.migrations.contains("gdu145"))
        let a = await r.engine.coreAudit()
        #expect(a.emitted >= 1)
        #expect(a.emitted == a.resolved && a.violations == 0 && !a.awaiting, "emitted \(a.emitted) resolved \(a.resolved) violations \(a.violations)")
        for t in a.trace { if case .result(_, let o, let posted, _) = t { #expect(o == .busy && !posted) } }
        #expect(r.state.observeOnly)
        let text = CoreStatusText.text(state: r.state, trusted: true, conflicting: nil)
        #expect(text.hasPrefix(ObserveOnly.leader), Comment(rawValue: text))
    }

    @Test func theSameWorldWithoutTheFlagChangesTheBar() async {   // the control: the test above is not vacuous
        let r = await rig(observeOnly: false)
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        let calls = await r.actuator.calls
        #expect(!calls.isEmpty)
        #expect(!r.sink.lines.contains { $0.contains("observe-only") })
        #expect(!r.state.observeOnly)
        #expect(!CoreStatusText.text(state: r.state, trusted: true, conflicting: nil).hasPrefix(ObserveOnly.leader))
    }

    @Test func aSecondUserMoveIsLoggedWithItsFlagsAndAnsweredOnce() async {
        let act = FakeActuator(order: [k("B"), k("A")], hidden: [], capabilities: OpenCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        var c = LayoutEngine.Config.plain(); c.recordCoreTrace = true; c.minPassInterval = .zero; c.layoutCoalesce = .zero; c.observeGate = ObserveOnlyGate(fixed: true)
        let sink = Sink(), state = EngineState()
        let engine = LayoutEngine(observer: ActuatorObserver(actuator: act), actuator: act, store: InMemoryLayoutStore(Layout.placedAll(visible: [k("A"), k("B")])), capabilities: OpenCaps(),
                                  state: state, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { sink.add($0) }, config: c)
        await engine.start()
        for _ in 0..<3 { _ = await engine.reconcileOnce() }
        let calls = await act.calls
        #expect(calls.isEmpty)
        #expect(sink.lines.contains { $0.hasPrefix("observe-only: would move ") && ($0.hasSuffix("(engine, strip: false)") || $0.hasSuffix("(engine, strip: true)")) }, Comment(rawValue: "\(sink.lines)"))
        let a = await engine.coreAudit()
        #expect(a.emitted >= 1 && a.emitted == a.resolved && a.violations == 0)
    }
}

@Suite struct ObserveOnlyActuatorTests {
    /// The real protocol's requirements, read from its source: a new requirement must be classified in `ObserveOnlyActuator.classification`.
    private func protocolRequirements() throws -> Set<String> {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SommelierCore/MenuBarActuator.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(text.range(of: "public protocol MenuBarActuator: Sendable {"))
        var body = text[start.upperBound...]
        let end = try #require(body.range(of: "\n}\n"))
        body = body[..<end.lowerBound]
        var names = Set<String>()
        for raw in body.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("///") || line.hasPrefix("//") { continue }
            if line.hasPrefix("func "), let n = line.dropFirst(5).split(whereSeparator: { $0 == "(" || $0 == "<" }).first { names.insert(String(n)) }
            else if line.hasPrefix("var "), let n = line.dropFirst(4).split(separator: ":").first { names.insert(n.trimmingCharacters(in: .whitespaces)) }
        }
        return names
    }

    @Test func everyProtocolRequirementIsClassified() throws {
        let reqs = try protocolRequirements()
        #expect(reqs.count >= 14, "parsed \(reqs)")
        #expect(reqs == Set(ObserveOnlyActuator.classification.keys), "unclassified: \(reqs.subtracting(ObserveOnlyActuator.classification.keys)), stale: \(Set(ObserveOnlyActuator.classification.keys).subtracting(reqs))")
    }

    @Test func mutatingCallsAreRefusedAndLogged_readOnlyAndConfigurationPassThrough() async {
        let spy = FakeActuator(order: [k("A"), k("B")], hidden: [], capabilities: OpenCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        let sink = Sink()
        let a = ObserveOnlyActuator(inner: spy, gate: ObserveOnlyGate(fixed: true), log: { sink.add($0) })
        let m = await a.move(k("A"), relation: .after(k("B")))
        let h = await a.setHidden(k("A"), true)
        let b = await a.applyHiddenBatch([k("A"): true, k("B"): false])
        for r in [m, h, b] { #expect(r.error == .userBusy && !r.isVerified) }
        // configuration and reads are allowed, none of them mutates
        await a.setChurnZone([k("A")]); await a.setRecordOrder([k("A")]); await a.setSingleDrag(true); await a.setEngineInitiated(true); await a.setStripAllowed(false)
        _ = await a.lastBatchRespawned; _ = await a.lastBatchUnconfirmed; _ = await a.lastBatchRefused; _ = await a.lastBatchUnsettled
        let touched = await a.lastMoveTouchedMouse, strip = await a.lastMoveOpenedStrip
        #expect(!touched && !strip)
        let calls = await spy.calls, events = await spy.stripEvents, order = await spy.order
        #expect(calls.isEmpty && events.isEmpty && order == [k("A"), k("B")])
        #expect(sink.lines.count == 4 && sink.lines.allSatisfy { $0.hasPrefix("observe-only: would ") })
        // every mutating entry of the classification is among the three refused above
        #expect(ObserveOnlyActuator.classification.filter { $0.value == .mutating }.keys.sorted() == ["applyHiddenBatch", "move", "setHidden"])
    }

    @Test func theStoreWrapperSkipsEveryWrite() throws {
        let inner = SpyStore(Layout.placedAll(visible: [k("A")]))
        let sink = Sink()
        let s = ObserveOnlyStore(inner: inner, gate: ObserveOnlyGate(fixed: true), log: { sink.add($0) })
        try s.save(Layout.placedAll(visible: [k("B")]))
        #expect(try s.backupBeforeMigration() == nil)
        #expect(inner.saves == 0 && inner.backups == 0)
        #expect(try s.load().visible == [k("A")])
        #expect(sink.lines.first == "observe-only: would save layout")
    }
}

@MainActor
@Suite struct ObserveOnlyStatusTests {
    @Test func everyStatusStartsWithTheLeader_andMatchesMayStillFollow() {
        let statuses: [Status?] = [nil, .moving, .matches, .matchesExcept([]), .matchesExcept([1, 2]), .differs(.stopped), .differs(.barFull), .differs(.needsReapply(3)), .differs(.plain), .checking]
        for s in statuses { for trusted in [true, false] { for conflict in [nil, "Bartender"] as [String?] {
            var c = CoreStatusContext(); c.observeOnly = true; c.trusted = trusted; c.conflicting = conflict
            let t = CoreStatusText.render(s, c)
            #expect(t.hasPrefix("Observe only: "), Comment(rawValue: t))
            c.observeOnly = false
            #expect(t == "Observe only: " + CoreStatusText.render(s, c))
        } } }
        var c = CoreStatusContext(); c.observeOnly = true
        #expect(CoreStatusText.render(.matches, c) == "Observe only: Menu bar matches")
        c.userPaused = true   // a D7 leader still blocks "matches"
        #expect(!CoreStatusText.render(.matches, c).contains("Menu bar matches"))
    }
}

// MARK: the gate (the single source of truth)

/// An in-memory stand-in for the app's UserDefaults key, shared by "launches".
private final class Pref: @unchecked Sendable {
    private let lock = NSLock(); private var v: Bool?
    init(_ v: Bool? = nil) { self.v = v }
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ b: Bool) { lock.lock(); v = b; lock.unlock() }
    func gate(env: Bool = false) -> ObserveOnlyGate { ObserveOnlyGate(stored: value, forcedByEnv: env, persist: { [self] in set($0) }) }
}

@Suite struct ObserveOnlyGateTests {
    @Test func defaultsOnWhenTheKeyWasNeverSet() {
        let p = Pref()
        let g = p.gate()
        #expect(g.isOn && g.source == .defaultOn && !g.forcedByEnv)
        #expect(g.logLine == "observe-only: ON (default)")
        #expect(p.value == nil, "reading the default must not write the preference")
    }

    @Test func turningItOffIsRememberedAcrossLaunches_andTurningItOnToo() {
        let p = Pref()
        let g1 = p.gate()
        #expect(g1.turnOff() && !g1.isOn && g1.source == .setting)
        #expect(g1.logLine == "observe-only: OFF (armed by user)")
        let g2 = p.gate()   // the next launch
        #expect(!g2.isOn, "the choice to arm must survive a relaunch")
        g2.turnOn()
        #expect(p.gate().isOn && p.gate().logLine == "observe-only: ON (setting)")
    }

    @Test func theEnvironmentForcesItOnAndNothingCanTurnItOff() {
        let p = Pref(false)   // the user had armed it
        let g = p.gate(env: true)
        #expect(g.isOn && g.source == .env && g.forcedByEnv)
        #expect(g.logLine == "observe-only: ON (forced by env)")
        #expect(!g.turnOff(), "turning off must be refused")
        #expect(g.isOn)
        #expect(p.value == false, "a refused request writes nothing")
        #expect(ObserveOnly.isOn(["SOMMELIER_OBSERVE_ONLY": "1"]))
        #expect(!ObserveOnly.isOn([:]) && !ObserveOnly.isOn(["SOMMELIER_OBSERVE_ONLY": "0"]) && !ObserveOnly.isOn(["SOMMELIER_OBSERVE_ONLY": "true"]))
    }

    @Test func productionGateReadsAndWritesUserDefaults() throws {
        let suite = "ie.boboco.sommelier.tests.observeonly.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        #expect(ObserveOnlyGate.production(defaults: d, environment: [:]).isOn)
        let g = ObserveOnlyGate.production(defaults: d, environment: [:])
        #expect(g.turnOff())
        #expect(d.object(forKey: ObserveOnly.defaultsKey) as? Bool == false)
        #expect(!ObserveOnlyGate.production(defaults: d, environment: [:]).isOn)
        #expect(ObserveOnlyGate.production(defaults: d, environment: ["SOMMELIER_OBSERVE_ONLY": "1"]).isOn)
    }
}

// MARK: runtime switching in the engine

@MainActor
@Suite struct ObserveOnlySwitchTests {
    /// Order work only (no membership, no migration): A..D reversed on the bar.
    private func orderOnlyRig(_ gate: ObserveOnlyGate) async -> Rig {
        let rec = Layout(visible: [k("A"), k("B"), k("C"), k("D")], hidden: [], alwaysHidden: [], newItemPolicy: .visibleAtEnd, migrations: ["gdu145"])
        return await rig(observeOnly: true, gate: gate, order: [k("D"), k("C"), k("B"), k("A")], recorded: rec, hiddenOnBar: [])
    }

    @Test func armingLeavesNoKeySkipped_andGrantsNoStrip() async {
        let gate = ObserveOnlyGate(fixed: true)
        let r = await orderOnlyRig(gate)
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }   // observing: every Action is answered busy/not posted (the core marks its subject skipped)
        #expect(await r.actuator.calls.isEmpty)
        let before = await r.engine.coreAudit().trace.count
        gate.turnOff()
        _ = await r.engine.reconcileOnce()   // the arming pass
        let trace = await r.engine.coreAudit().trace
        let names = trace[before...].compactMap { t -> String? in if case .event(let n, let site) = t, site.hasPrefix("arming") { return n }; return nil }
        #expect(names == ["userRetry", "passBoundary"], "arming events (userRetry clears, passBoundary revokes its strip grant): \(names)")
        for _ in 0..<14 { _ = await r.engine.reconcileOnce() }
        let finalOrder = await r.actuator.order
        #expect(finalOrder == [k("A"), k("B"), k("C"), k("D")], "keys stayed skipped: \(finalOrder)")
        let after = await r.engine.coreAudit().trace[before...]
        #expect(after.contains { if case .emitted = $0 { return true }; return false })
        let strips = after.filter { if case .emitted(_, _, let strip, _) = $0 { return strip }; return false }
        #expect(strips.isEmpty, "arming must not grant a strip session")
        #expect(r.sink.lines.contains("observe-only: OFF (armed by user)"))
        let a = await r.engine.coreAudit()
        #expect(a.emitted == a.resolved && a.violations == 0)
    }

    /// The read memory that lets a single read decide is dropped at arming, so on a bar with a chevron the first complete read is HELD by the adapter
    /// (`ReadAdapter`: a complete read with a chevron and no earlier complete pile is unsettled) and a second agreeing read is needed, as after a wake.
    /// (The fake bar has no chevron, so the end-to-end "first drag after two reads" is not observable here; the memory is asserted directly.)
    @Test func armingDropsTheReadMemory_soTwoFreshAgreeingReadsAreNeeded() async {
        let gate = ObserveOnlyGate(fixed: true)
        let r = await orderOnlyRig(gate)
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        let observing = await r.engine.readMemoryForTests
        #expect(observing.pile != nil && observing.churnReads > 0 && observing.hasBarRead, "the control: observing builds read memory")
        await r.engine.syncObserveGateForTests()   // gate still on: nothing changes
        #expect(await r.engine.readMemoryForTests.pile != nil)
        gate.turnOff()
        await r.engine.syncObserveGateForTests()
        let armed = await r.engine.readMemoryForTests
        #expect(armed.pile == nil && armed.churnReads == 0 && !armed.hasBarRead, "arming left read memory: \(armed)")
    }

    @Test func theMigrationRunsOnlyAfterArming() async {
        let gate = ObserveOnlyGate(fixed: true)
        let r = await rig(observeOnly: true, gate: gate)
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        #expect(!r.state.layout.migrations.contains("gdu145"))
        #expect(r.store.backups == 0 && r.store.saves == 0)
        #expect(r.sink.lines.filter { $0.hasPrefix("observe-only: would drop ") }.count == 1, "logged once, not per scan")
        gate.turnOff()
        for _ in 0..<8 { _ = await r.engine.reconcileOnce() }
        #expect(r.state.layout.migrations.contains("gdu145"), "the migration must run after arming")
        #expect(r.store.saves >= 1)
        #expect(!r.state.layout.visible.contains(he("com.x.A", "fp")))
    }

    @Test func switchingOnMidRunStopsNewActions() async {
        let gate = ObserveOnlyGate(fixed: false)
        let r = await rig(observeOnly: false, gate: gate)
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        let n = await r.actuator.calls.count
        #expect(n > 0, "the control: acting before the switch")
        gate.turnOn()
        let marker = r.sink.lines.count
        for _ in 0..<8 { _ = await r.engine.reconcileOnce() }
        #expect(await r.actuator.calls.count == n, "an action started after the switch")
        let after = Array(r.sink.lines[marker...])
        #expect(after.contains { $0 == "observe-only: ON (switched on); nothing new will be changed" })
        #expect(r.state.observeOnly)
        #expect(CoreStatusText.text(state: r.state, trusted: true, conflicting: nil).hasPrefix(ObserveOnly.leader))
        gate.turnOff()   // and back: arms again
        for _ in 0..<14 { _ = await r.engine.reconcileOnce() }
        #expect(await r.actuator.calls.count > n)
        #expect(!r.state.observeOnly)
    }

    @Test func switchingOnFlipsTheEngineGuards_theWouldMoveLineComesFromTheEngine() async {
        let gate = ObserveOnlyGate(fixed: false)
        let r = await rig(observeOnly: false, gate: gate)
        _ = await r.engine.reconcileOnce()
        gate.turnOn()
        let marker = r.sink.lines.count
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        let after = Array(r.sink.lines[marker...])
        #expect(after.contains { $0.hasPrefix("observe-only: would move ") && $0.contains("(engine, strip:") }, Comment(rawValue: "\(after.filter { $0.contains("observe-only") })"))
    }

    @Test func theEngineIsBuiltWithTheWrappers_bypassingItsOwnGuards() async {
        let gate = ObserveOnlyGate(fixed: true)
        let r = await rig(observeOnly: true, gate: gate)
        let held = await r.engine.actuatorForTests
        #expect(held is ObserveOnlyActuator, "the engine must hold the wrapper, not the raw actuator")
        let refused = await held.move(k("D"), relation: .before(k("A")))
        #expect(refused.error == .userBusy && !refused.isVerified)
        let refusedBatch = await held.applyHiddenBatch([k("H"): true])
        #expect(refusedBatch.error == .userBusy)
        #expect(await r.actuator.calls.isEmpty, "a call went through the wrapper while the gate was on")
        gate.turnOff()
        _ = await held.move(k("D"), relation: .before(k("A")))
        #expect(await r.actuator.calls.count == 1, "with the gate off the wrapper must pass through")
    }
}

// MARK: honesty of the status

@MainActor
@Suite struct ObserveOnlyHonestyTests {
    /// The reviewer's world: the ORDER matches, item H is drawn but the record says Hidden. The core sees a matching order; membership differs.
    @Test func aMembershipDifferenceNeverReadsMenuBarMatches() async {
        let record = Layout(visible: [k("A"), k("B")], hidden: [k("H")], alwaysHidden: [], newItemPolicy: .visibleAtEnd)
        let r = await rig(observeOnly: true, order: [k("A"), k("B"), k("H")], recorded: record)
        for _ in 0..<6 { _ = await r.engine.reconcileOnce() }
        let text = CoreStatusText.text(state: r.state, trusted: true, conflicting: nil)
        #expect(text.hasPrefix("Observe only: would hide 1"), Comment(rawValue: text))
        #expect(!text.contains("Menu bar matches"), Comment(rawValue: text))
        #expect(await r.actuator.calls.isEmpty)
    }

    @Test func theLeaderIsRenderedAndBlocksMatches() {
        var c = CoreStatusContext(); c.observeOnly = true; c.wouldHide = 2; c.wouldShow = 1
        #expect(CoreStatusText.render(.matches, c) == "Observe only: would hide 2, show 1")
        c.wouldHide = 0
        #expect(CoreStatusText.render(.differs(.plain), c) == "Observe only: would show 1 \u{b7} Sommelier has no move to make right now")
        c.observeOnly = false   // only while observing
        #expect(CoreStatusText.render(.matches, c) == "Menu bar matches")
    }
}

// MARK: no write while observing, even a backup of a corrupt file

@Suite struct ObserveOnlyStoreFileTests {
    @Test func aCorruptLayoutIsNotCopiedToBakWhileObserving() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("layout.json")
        try Data("{ not json".utf8).write(to: f)
        let bak = f.appendingPathExtension("bak")
        let gate = ObserveOnlyGate(fixed: true)
        let s = ObserveOnlyStore(inner: FileLayoutStore(url: f), gate: gate, log: { _ in })
        #expect(throws: (any Error).self) { try s.load() }
        #expect(!FileManager.default.fileExists(atPath: bak.path), "observe-only wrote layout.json.bak")
        gate.turnOff()
        #expect(throws: (any Error).self) { try s.load() }
        #expect(FileManager.default.fileExists(atPath: bak.path), "with the gate off the backup is written as before")
    }
}
