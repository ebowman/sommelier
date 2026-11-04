import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// MARK: - Fixtures

private func key(_ n: String) -> ItemKey { .status(ownerKey: "app.\(n)", autosaveName: n) }

private func item(_ n: String, x: CGFloat, onBar: Bool = true, stale: Bool = false, pid: pid_t? = nil, ident: String? = nil) -> MenuBarItem {
    MenuBarItem(ownerPID: pid ?? pid_t(abs(n.hashValue % 30000) + 100), ownerBundleID: "app.\(n)", ownerName: n, title: "",
                axDescription: "", axIdentifier: ident ?? n,
                frame: onBar ? CGRect(x: x, y: 0, width: 30, height: 24) : CGRect(x: -1, y: 0, width: 30, height: 24),
                source: .appExtras, isOnMenuBar: onBar, stale: stale)
}

private func resolved(_ names: [String], parked: [String] = [], stale: Set<String> = [], conf: KeyConfidence = .exact) -> [ResolvedItem] {
    names.enumerated().map { ResolvedItem(item: item($1, x: 100 + CGFloat($0) * 40, stale: stale.contains($1)), key: key($1), confidence: conf) }
    + parked.map { ResolvedItem(item: item($0, x: 0, onBar: false), key: key($0), confidence: conf) }
}

private func mod(_ n: String, x: CGFloat) -> ResolvedItem {
    var i = item(n, x: x); i.source = .agentHostedOnly
    return ResolvedItem(item: i, key: .module(name: n), confidence: .inferred)
}

// MARK: - Verification predicates

@Test func moveVerdictBeforeAfter() {
    let r = resolved(["A", "B", "C", "D"])
    #expect(ActuationVerifier.moveVerdict(subject: key("B"), relation: .before(key("C")), resolved: r).ok)
    #expect(!ActuationVerifier.moveVerdict(subject: key("B"), relation: .before(key("D")), resolved: r).ok)   // not adjacent
    #expect(!ActuationVerifier.moveVerdict(subject: key("C"), relation: .before(key("B")), resolved: r).ok)   // wrong side
    #expect(ActuationVerifier.moveVerdict(subject: key("C"), relation: .after(key("B")), resolved: r).ok)
    #expect(!ActuationVerifier.moveVerdict(subject: key("A"), relation: .after(key("C")), resolved: r).ok)
    let v = ActuationVerifier.moveVerdict(subject: key("A"), relation: .after(key("C")), resolved: r)
    #expect(v.error == .notVerified(expected: v.expected, observed: "between (bar start) and \(key("B"))"))
}

@Test func moveVerdictLeftRightMostIgnoresModules() {
    let r = [mod("Wifi", x: 60)] + resolved(["A", "B", "C"]).enumerated().map { (i, x) -> ResolvedItem in
        var y = x; y.item.frame.origin.x = 100 + CGFloat(i) * 40; return y } + [mod("Clock", x: 400)]
    #expect(ActuationVerifier.moveVerdict(subject: key("A"), relation: .leftmost, resolved: r).ok)   // module at x=60 does not count
    #expect(!ActuationVerifier.moveVerdict(subject: key("B"), relation: .leftmost, resolved: r).ok)
    #expect(ActuationVerifier.moveVerdict(subject: key("C"), relation: .rightmost, resolved: r).ok)   // Clock to its right does not count
    #expect(!ActuationVerifier.moveVerdict(subject: key("B"), relation: .rightmost, resolved: r).ok)
}

@Test func moveVerdictRefusesStaleParkedAbsentAndHeuristic() {
    #expect(!ActuationVerifier.moveVerdict(subject: key("B"), relation: .before(key("C")),
                                           resolved: resolved(["A", "B", "C"], stale: ["B"])).ok)            // stale subject
    #expect(!ActuationVerifier.moveVerdict(subject: key("B"), relation: .before(key("C")),
                                           resolved: resolved(["A", "B", "C"], stale: ["C"])).ok)            // stale neighbor
    #expect(!ActuationVerifier.moveVerdict(subject: key("B"), relation: .before(key("C")),
                                           resolved: resolved(["A", "C"], parked: ["B"])).ok)                // parked
    #expect(!ActuationVerifier.moveVerdict(subject: key("B"), relation: .before(key("C")), resolved: resolved(["A", "C"])).ok)   // absent
    var h = resolved(["A", "B"], conf: .heuristic)
    h[0].item.axIdentifier = ""; h[1].item.axIdentifier = ""
    #expect(!ActuationVerifier.moveVerdict(subject: key("A"), relation: .before(key("B")), resolved: h).ok)    // uncorroborated heuristic
    h[0].item.axIdentifier = "A"; h[1].item.axIdentifier = "B"
    #expect(ActuationVerifier.moveVerdict(subject: key("A"), relation: .before(key("B")), resolved: h).ok)     // corroborated by identifier
}

@Test func visibilityVerdict() {
    let r = resolved(["A"], parked: ["B"])
    #expect(ActuationVerifier.visibilityVerdict(key: key("A"), hidden: false, resolved: r).ok)
    #expect(!ActuationVerifier.visibilityVerdict(key: key("A"), hidden: true, resolved: r).ok)
    #expect(ActuationVerifier.visibilityVerdict(key: key("B"), hidden: true, resolved: r).ok)
    #expect(!ActuationVerifier.visibilityVerdict(key: key("B"), hidden: false, resolved: r).ok)
    #expect(!ActuationVerifier.visibilityVerdict(key: key("Z"), hidden: true, resolved: r).ok)                  // absent
    #expect(!ActuationVerifier.visibilityVerdict(key: key("A"), hidden: false, resolved: resolved(["A"], stale: ["A"])).ok)
}

@Test func dragRelationExtensions() {
    #expect(DragTarget.holds(.leftmost, moved: "a", order: ["a", "b"]))
    #expect(!DragTarget.holds(.leftmost, moved: "b", order: ["a", "b"]))
    #expect(DragTarget.holds(.rightmost, moved: "b", order: ["a", "b"]))
    #expect(DragRelation(.before(key("A"))) == .before(key("A").description))
}

// MARK: - Fake platform: a tiny menu bar world

private final class World: ActuatorPlatform, @unchecked Sendable {
    enum DragBehavior { case apply, noop, menuOpensAndNoop, fail(DragError) }

    var order: [String]
    var hidden: Set<String> = []
    var dropScans = 0, dropName = ""        // next N scans omit `dropName` entirely
    var flickerAfterRestart = 0, dropAfterDrag = 0
    var restartDrift: [[String: Double]] = []      // one entry consumed per restart: the agent re-bases these store values
    var restartReorder: [[String]] = []            // one entry consumed per restart: the frame order after it (store untouched)
    var failStoreWrite = false
    var emptyScans = 0                       // next N scans return nothing at all
    var flickerScans = 0, flickerName = ""  // next N scans show `flickerName` parked
    var restartParks: Set<String> = []       // restart permanently parks these (collateral)
    var staleScans = 0                  // next N scans (fast or full) report `staleName` as stale
    var staleName = ""
    var trusted = true, buttons = 0, bartender: String? = nil
    var untracked: Set<String> = []
    var modules: Set<String> = []          // item names that resolve to `.module` keys
    var shared: [String: String] = [:]     // item name -> shared tracked key (several items per app)
    func tracked(_ n: String) -> String { shared[n] ?? "tracked.\(n)" }
    var dragScript: [DragBehavior] = []
    var dragCalls: [(steps: Int, toX: CGFloat)] = []
    var menu = false
    var escapes = 0, fullScans = 0, fastScans = 0, restarts = 0, allowedWrites: [[String: Bool]] = [], storeWrites: [[String: Double]] = []
    var pendingAllowed: [String: Bool] = [:]
    var restartAppliesAllowed = true, restartAppliesStore = true
    var store: [String: Double]
    var clock = Date(timeIntervalSince1970: 1000)
    // Live (cfprefsd-notified) path scripting.
    var liveAvailable = false, liveThrows = false
    var liveApplyAfterScans: Int? = 2        // the Nth full scan after the live write shows it; nil = never
    var liveIncompleteScans = 0              // that many scans right after the write report an incomplete hosted read
    var liveWrites: [[String: Bool]] = []
    var livePending: [String: Bool]?
    var liveScanCount = 0
    // Identifier-less items (of7): the live hide is applied at write time (the agent takes ~25 ms) but the app-side frame of
    // an unnamed item stays on-bar ("ghost") unless the actuator recorded it as assumed-hidden.
    var unnamed: Set<String> = []
    var liveInstant = false
    var ghosts: Set<String> = []
    var hostedTamper: (@Sendable (inout [HostedEntry]) -> Void)?   // applied to hosted layouts read after the live write
    var preScansIncomplete = 0               // the first N full scans report an incomplete hosted read
    var probeOnlyTamper: (@Sendable (inout [HostedEntry]) -> Void)?   // applied to raw probes only (poll scans stay right)
    var allowedLiveValues: [String: Bool]?   // Control Center store readback (nil = unavailable)
    func readAllowedLive(_ keys: [String]) -> [String: Bool]? { allowedLiveValues.map { $0.filter { keys.contains($0.key) } } }
    var cachedLayout: [HostedEntry]?         // what the scanner cache offers as a recent complete layout
    var hostedReads = 0
    var dropAfterWrite = ""                  // after the live write this item reads as parked app-side (hosted tree unchanged)
    var assumedPIDs: Set<pid_t> = [], assumedRecords: [(owners: [AssumedHiddenOwner], after: Int?)] = [], clearedPIDs: [Set<pid_t>] = []
    func pidOf(_ n: String) -> pid_t { item(n, x: 0).ownerPID }
    func layout(attributed: Bool) -> [HostedEntry] {
        order.enumerated().map { HostedEntry(sig: unnamed.contains($1) ? "" : $1, minX: 100 + CGFloat($0) * 40, width: 30, ownerPID: attributed ? pidOf($1) : nil) }
    }
    func hostedLayout() async -> [HostedEntry]? {
        hostedReads += 1
        var l = layout(attributed: false)
        if !liveWrites.isEmpty { hostedTamper?(&l); probeOnlyTamper?(&l) }
        return l
    }
    func recentCompleteHostedLayout(maxAge: TimeInterval) -> [HostedEntry]? { cachedLayout }
    func recordAssumedHidden(_ owners: [AssumedHiddenOwner], hostedAfter: Int?) {
        assumedRecords.append((owners, hostedAfter)); for o in owners { assumedPIDs.insert(o.pid) }
    }
    func clearAssumedHidden(pids: Set<pid_t>) { clearedPIDs.append(pids); assumedPIDs.subtract(pids) }
    func nameOf(_ i: MenuBarItem) -> String { i.axIdentifier.isEmpty ? i.ownerName : i.axIdentifier }

    var liveHideShowAvailable: Bool { liveAvailable }
    func setAllowedLive(_ c: [String: Bool]) throws {
        if liveThrows { throw PreferenceWriterError.writeFailed("injected live failure") }
        liveWrites.append(c)
        if !dropAfterWrite.isEmpty { flickerName = dropAfterWrite; flickerScans = 5 }
        if liveInstant {
            let before = Set(order)
            applyLive(c)
            ghosts.formUnion(before.subtracting(order).intersection(unnamed))
            ghosts.formIntersection(hidden)
            return
        }
        livePending = c; liveScanCount = 0
    }
    private func applyLive(_ allowedByTracked: [String: Bool]) {
        for n in Array(order) + Array(hidden).sorted() {
            guard let allowed = allowedByTracked[tracked(n)] else { continue }
            if allowed { hidden.remove(n); if !order.contains(n) { order.append(n) } }
            else if let i = order.firstIndex(of: n) { order.remove(at: i); hidden.insert(n) }
        }
    }

    init(_ names: [String]) {
        order = names
        store = Dictionary(uniqueKeysWithValues: names.enumerated().map { (key($1).description, 1000 - Double($0) * 100) })
    }

    func snapshot() -> MenuBarSnapshot {
        if emptyScans > 0 { emptyScans -= 1; return MenuBarSnapshot(items: [], capturedAt: clock) }
        var items = order.enumerated().filter { !(dropScans > 0 && $1 == dropName) }.map {
            item($1, x: 100 + CGFloat($0) * 40, onBar: !(flickerScans > 0 && $1 == flickerName), stale: staleScans > 0 && $1 == staleName,
                 ident: unnamed.contains($1) ? "" : nil) }
        items += hidden.sorted().map { n in
            let g = ghosts.contains(n) && !assumedPIDs.contains(pidOf(n))
            var i = item(n, x: g ? 500 : 0, onBar: g, ident: unnamed.contains(n) ? "" : nil)
            if !g { i.frame = CGRect(x: -1, y: 0, width: 30, height: 24) }
            return i
        }
        if staleScans > 0 { staleScans -= 1 }
        if dropScans > 0 { dropScans -= 1 }
        if flickerScans > 0 { flickerScans -= 1 }
        return MenuBarSnapshot(items: items, capturedAt: clock)
    }
    func scanVisible() async -> MenuBarSnapshot { fastScans += 1; return snapshot() }
    func scan() async -> MenuBarSnapshot {
        fullScans += 1
        var incomplete = false
        if let p = livePending {
            liveScanCount += 1
            if liveScanCount <= liveIncompleteScans { incomplete = true }
            else if let n = liveApplyAfterScans, liveScanCount >= n { applyLive(p); livePending = nil }
        }
        var s = snapshot()
        var lay = layout(attributed: true)
        if !liveWrites.isEmpty { hostedTamper?(&lay) }
        s.hostedLayout = lay
        if preScansIncomplete > 0 { preScansIncomplete -= 1; incomplete = true }
        if incomplete { s.hostedReadComplete = false }
        return s
    }
    func accessibilityTrusted() -> Bool { trusted }
    func pressedMouseButtons() -> Int { buttons }
    func conflictingManager() -> String? { bartender }
    func resolve(_ s: MenuBarSnapshot) -> [ResolvedItem] {
        s.items.map { ResolvedItem(item: $0, key: modules.contains(nameOf($0)) ? .module(name: nameOf($0)) : key(nameOf($0)), confidence: .exact) }
    }
    func trackedKey(for r: ResolvedItem) -> String? { untracked.contains(nameOf(r.item)) ? nil : tracked(nameOf(r.item)) }
    func drag(itemFrame: CGRect, toX: CGFloat, steps: Int) async throws -> Date {
                dragCalls.append((steps, toX))
        let b = dragScript.isEmpty ? DragBehavior.apply : dragScript.removeFirst()
        switch b {
        case .fail(let e): throw e
        case .noop: break
        case .menuOpensAndNoop: menu = true
        case .apply:
            let mids = order.enumerated().map { (name: $1, mid: 100 + CGFloat($0) * 40 + 15) }   // positions during the drag
            let name = mids.first { $0.mid == itemFrame.midX }!.name
            let crossed = mids.filter { $0.name != name && $0.mid < toX }.count
            order.removeAll { $0 == name }
            order.insert(name, at: crossed)
        }
        dropScans = dropAfterDrag
        return clock
    }
    func menuProbe(for item: MenuBarItem) -> MenuProbe { MenuProbe(hasMenu: menu, windowCount: 0) }
    func pressEscape() { escapes += 1; menu = false }
    func readOrderStore() throws -> [String: Double] { store }
    func writeOrderStore(_ u: [String: Double], allowModules: Bool) throws {
        if failStoreWrite { throw PreferenceWriterError.writeFailed("injected") }
        storeWrites.append(u); for (k, v) in u { store[k] = v } }
    func waitForOrderStoreQuiet() async {}
    func writeAllowed(_ c: [String: Bool]) throws { allowedWrites.append(c); pendingAllowed = c }
    func readAllowed(_ keys: [String]) throws -> [String: Bool] { pendingAllowed.filter { keys.contains($0.key) } }
    func restartAgent(timeout: TimeInterval, expectedChange: Int) async -> AgentRestartOutcome {
        restarts += 1
        ghosts = []
        flickerScans = flickerAfterRestart
        if restartAppliesAllowed {
            for n in Array(order) + Array(hidden).sorted() {
                guard let allowed = pendingAllowed[tracked(n)] else { continue }
                if allowed { hidden.remove(n); if !order.contains(n) { order.append(n) } }
                else if let i = order.firstIndex(of: n) { order.remove(at: i); hidden.insert(n) }
            }
            pendingAllowed = [:]
        }
        for n in restartParks { if let i = order.firstIndex(of: n) { order.remove(at: i); hidden.insert(n) } }
        if !restartDrift.isEmpty { for (k, v) in restartDrift.removeFirst() { store[key(k).description] = v } }
        if restartAppliesStore {
            order.sort { (store[key($0).description] ?? 0) > (store[key($1).description] ?? 0) }
        }
        if !restartReorder.isEmpty { order = restartReorder.removeFirst() }
        return AgentRestartOutcome(recovered: true, elapsedMS: 1)
    }
    func sleep(_ s: TimeInterval) async { clock = clock.addingTimeInterval(s) }
    func now() -> Date { return clock }
}

private func actuator(_ w: World, fallback: Bool = true, forceFallback: Bool = false) -> LiveActuator {
    var c = LiveActuator.Config()
    c.allowFallback = fallback
    c.forceFallback = forceFallback
    return LiveActuator(platform: w, config: c)
}

private func liveActuator(_ w: World, live: Bool = true) -> LiveActuator {
    var c = LiveActuator.Config()
    c.liveHideShow = live
    return LiveActuator(platform: w, config: c)
}

// MARK: - Settle

@Test func settleReturnsFullScanAfterTwoAgreeingPolls() async {
    let w = World(["A", "B", "C"])
    let out = await SettleDetector(scanner: w, now: { w.now() }, sleep: { await w.sleep($0) }).settled(maxWait: 3, stableFor: 0.15)
    #expect(out.settled)
    #expect(out.fullScans == 1)
    #expect(w.fastScans == 2)
    #expect(out.snapshot.onBarLeftToRight.count == 3)
}

@Test func settleAgreeToleratesOnePointOnly() {
    func snap(_ dx: CGFloat) -> MenuBarSnapshot {
        MenuBarSnapshot(items: [item("A", x: 100 + dx), item("B", x: 140)], capturedAt: Date(timeIntervalSince1970: 0))
    }
    #expect(SettleDetector.agree(snap(0), snap(0.9)))
    #expect(!SettleDetector.agree(snap(0), snap(1.5)))
    let swapped = MenuBarSnapshot(items: [item("B", x: 100), item("A", x: 140)], capturedAt: Date(timeIntervalSince1970: 0))
    #expect(!SettleDetector.agree(snap(0), swapped))   // same frames, different keys
    let fewer = MenuBarSnapshot(items: [item("A", x: 100)], capturedAt: Date(timeIntervalSince1970: 0))
    #expect(!SettleDetector.agree(snap(0), fewer))
}

@Test func staleSubjectNeverSettles() async {
    let w = World(["A", "B", "C"])
    w.staleName = "B"; w.staleScans = 1_000_000          // B stays stale forever
    let det = SettleDetector(scanner: w, now: { w.now() }, sleep: { await w.sleep($0) }, isSubject: { $0.axIdentifier == "B" })
    let out = await det.settled(maxWait: 1, stableFor: 0.15)
    #expect(!out.settled)
    // A stale item that is NOT the subject does not block settling.
    let w2 = World(["A", "B", "C"])
    w2.staleName = "C"; w2.staleScans = 1_000_000
    let out2 = await SettleDetector(scanner: w2, now: { w2.now() }, sleep: { await w2.sleep($0) },
                                    isSubject: { $0.axIdentifier == "B" }).settled(maxWait: 1, stableFor: 0.15)
    #expect(out2.settled)
}

@Test func staleSubjectSettlesOnceFresh() async {
    let w = World(["A", "B"])
    w.staleName = "B"; w.staleScans = 3                  // stale for the first 3 scans, then fresh
    let out = await SettleDetector(scanner: w, now: { w.now() }, sleep: { await w.sleep($0) },
                                   isSubject: { $0.axIdentifier == "B" }).settled(maxWait: 3, stableFor: 0.15)
    #expect(out.settled)
    #expect(!out.snapshot.items.contains { $0.stale })
}

// MARK: - move: precheck

@Test func moveRefusesWithoutSideEffects() async {
    let w = World(["A", "B", "C"])
    w.trusted = false
    #expect((await actuator(w).move(key("A"), relation: .after(key("C")))).error == .permissionDenied)
    w.trusted = true; w.bartender = "Bartender 7 is running"
    #expect((await actuator(w).move(key("A"), relation: .after(key("C")))).error == .conflictingManager("Bartender 7 is running"))
    #expect(w.fullScans == 0 && w.dragCalls.isEmpty)
    w.bartender = nil
    #expect((await actuator(w).move(key("Z"), relation: .after(key("C")))).error == .notFound)
    #expect((await actuator(w).move(key("A"), relation: .after(key("Z")))).error == .notFound)
    #expect((await actuator(w).move(key("A"), relation: .after(key("A")))).error == .notFound)
    #expect((await actuator(w).move(.module(name: "Clock"), relation: .leftmost)).error == .notFound)
    #expect(w.dragCalls.isEmpty)
}

@Test func moveUnsupportedAndParkedAndAlreadySatisfied() async {
    let w = World(["A", "B", "C"])
    w.hidden = ["P"]
    if case .unsupportedItem? = (await actuator(w).move(key("P"), relation: .leftmost)).error {} else { Issue.record("parked item should be unsupported") }
    let r = await actuator(w).move(key("A"), relation: .before(key("B")))
    #expect(r.isVerified)
    #expect(w.dragCalls.isEmpty)     // already satisfied: no drag
}

@Test func moveUserBusyAfterWaitingTwoSeconds() async {
    let w = World(["A", "B", "C"])
    w.buttons = 1
    let t0 = w.now()
    let r = await actuator(w).move(key("A"), relation: .after(key("C")))
    #expect(r.error == .userBusy)
    #expect(w.dragCalls.isEmpty)
    #expect(w.now().timeIntervalSince(t0) >= 2.0)
}

// MARK: - move: retry / fallback sequencing

@Test func moveVerifiedFirstAttempt() async {
    let w = World(["A", "B", "C", "D"])
    let r = await actuator(w).move(key("A"), relation: .after(key("C")))
    #expect(r.isVerified)
    #expect(w.order == ["B", "C", "A", "D"])
    #expect(w.dragCalls.count == 1)
    #expect(w.dragCalls[0].steps == 10)
    #expect(w.restarts == 0)
}

@Test func moveRelativeToModuleTargetUsesDragWithoutFallback() async {
    let w = World(["WiFi", "A", "B", "C"])
    w.modules = ["WiFi"]
    let r = await actuator(w, fallback: false).move(key("C"), relation: .after(.module(name: "WiFi")))
    #expect(r.isVerified)
    #expect(w.order == ["WiFi", "C", "A", "B"])
    #expect(w.dragCalls.count == 1 && w.restarts == 0 && w.storeWrites.isEmpty)
}

@Test func moveLeftmostRightmost() async {
    let w = World(["A", "B", "C", "D"])
    #expect((await actuator(w).move(key("C"), relation: .leftmost)).isVerified)
    #expect(w.order == ["C", "A", "B", "D"])
    #expect((await actuator(w).move(key("C"), relation: .rightmost)).isVerified)
    #expect(w.order == ["A", "B", "D", "C"])
}

@Test func moveRetriesOnceThenVerifies() async {
    let w = World(["A", "B", "C", "D"])
    w.dragScript = [.noop]
    let r = await actuator(w).move(key("A"), relation: .after(key("C")))
    #expect(r.isVerified)
    #expect(w.dragCalls.map(\.steps) == [10, 20])
    #expect(w.restarts == 0 && w.storeWrites.isEmpty)
}

@Test func moveFallsBackToOrderStoreAfterTwoFailedDrags() async {
    let w = World(["A", "B", "C", "D"])
    w.dragScript = [.noop, .noop]
    let r = await actuator(w).move(key("A"), relation: .after(key("C")))
    #expect(r.isVerified)
    #expect(w.dragCalls.count == 2)
    #expect(w.restarts == 1)
    #expect(w.storeWrites.count == 1)
    // gdu.25: only the subject is written, with the midpoint between its new neighbours C (800) and D (700).
    #expect(w.storeWrites[0] == [key("A").description: 750])
    #expect(w.order == ["B", "C", "A", "D"])
}

@Test func moveWithoutFallbackReportsNotVerifiedWithObservedPosition() async {
    let w = World(["A", "B", "C", "D"])
    w.dragScript = [.noop, .noop]
    let r = await actuator(w, fallback: false).move(key("A"), relation: .after(key("C")))
    guard case .failed(.notVerified(let expected, let observed), let snap?) = r else { Issue.record("expected notVerified, got \(r)"); return }
    #expect(expected.contains("immediately after"))
    #expect(observed.contains("between (bar start)"))
    #expect(snap.onBarLeftToRight.count == 4)
    #expect(w.restarts == 0)
}

@Test func moveFallbackThatDoesNotTakeEffectIsNotVerified() async {
    let w = World(["A", "B", "C", "D"])
    w.dragScript = [.noop, .noop]
    w.restartAppliesStore = false
    let r = await actuator(w).move(key("A"), relation: .after(key("C")))
    if case .failed(.notVerified, _) = r {} else { Issue.record("expected notVerified, got \(r)") }
    #expect(w.restarts == 1)
}

@Test func moveFallbackNeedsStoreEntries() async {
    let w = World(["A", "B", "C"])
    w.dragScript = [.noop, .noop]
    w.store = [:]
    let r = await actuator(w).move(key("A"), relation: .after(key("C")))
    if case .failed(.mechanismFailed(let m), _) = r { #expect(m.contains("order-store entry")) } else { Issue.record("got \(r)") }
    #expect(w.restarts == 0)
}

@Test func moveForcedFallbackSkipsDrags() async {
    let w = World(["A", "B", "C"])
    let r = await actuator(w, forceFallback: true).move(key("C"), relation: .leftmost)
    #expect(r.isVerified)
    #expect(w.dragCalls.isEmpty)
    #expect(w.order == ["C", "A", "B"])
}

// MARK: - move: menu opened, event failures

@Test func menuOpenedPostsEscapeAndCountsAsFailedAttempt() async {
    let w = World(["A", "B", "C", "D"])
    w.dragScript = [.menuOpensAndNoop]
    let r = await actuator(w).move(key("A"), relation: .after(key("C")))
    #expect(r.isVerified)            // second attempt moved it
    #expect(w.escapes == 1)
    #expect(w.dragCalls.count == 2)
    #expect(!w.menu)
}

@Test func menuOpenedOnEveryAttemptIsMechanismFailed() async {
    let w = World(["A", "B", "C", "D"])
    w.dragScript = [.menuOpensAndNoop, .menuOpensAndNoop]
    let r = await actuator(w, fallback: false).move(key("A"), relation: .after(key("C")))
    #expect(r.error == .mechanismFailed("menu opened"))
    #expect(w.escapes == 2)
}

@Test func dragErrorsMapToTypedResults() async {
    let w = World(["A", "B", "C"])
    w.dragScript = [.fail(.userBusy)]
    #expect((await actuator(w).move(key("A"), relation: .after(key("C")))).error == .userBusy)
    w.dragScript = [.fail(.eventCreationFailed)]
    if case .mechanismFailed? = (await actuator(w).move(key("A"), relation: .after(key("C")))).error {} else { Issue.record("expected mechanismFailed") }
    #expect(w.dragCalls.count == 2)   // no retry after a mechanism failure
}

@Test func dragMoverAlwaysPostsMouseUpAfterMouseDown() {
    let plan = DragPlan.make(from: CGPoint(x: 10, y: 5), toX: 90, steps: 4, stepDelay: 0, hold: 0)
    var posted: [DragStep.Kind] = []
    // Event creation fails on the 3rd dragged event.
    var draggedSeen = 0
    let out = DragMover.execute(plan: plan, sleep: { _ in }, post: { s in
        if s.kind == .dragged { draggedSeen += 1; if draggedSeen == 3 { return false } }
        posted.append(s.kind)
        return true
    })
    #expect(out.error == .eventCreationFailed)
    #expect(posted.last == .up)
    #expect(posted.filter { $0 == .down }.count == posted.filter { $0 == .up }.count)
    // Failure before the mouseDown posts no mouseUp.
    var posted2: [DragStep.Kind] = []
    let out2 = DragMover.execute(plan: plan, sleep: { _ in }, post: { s in if s.kind == .down { return false }; posted2.append(s.kind); return true })
    #expect(out2.error == .eventCreationFailed)
    #expect(!posted2.contains(.up))
}

// MARK: - hide / show batches

@Test func batchHideShowOneWriteOneRestart() async {
    let w = World(["A", "B", "C", "D"])
    let out = await actuator(w).applyHiddenBatchDetailed([key("B"): true, key("C"): true])
    #expect(out.result.isVerified)
    #expect(out.perKey.count == 2 && out.perKey.values.allSatisfy(\.isVerified))
    #expect(w.allowedWrites.count == 1)
    #expect(w.allowedWrites[0] == ["tracked.B": false, "tracked.C": false])     // isAllowed == !hidden
    #expect(w.restarts == 1)
    #expect(w.order == ["A", "D"] && w.hidden == ["B", "C"])
    let back = await actuator(w).applyHiddenBatchDetailed([key("B"): false, key("C"): false])
    #expect(back.result.isVerified)
    #expect(w.allowedWrites.count == 2 && w.allowedWrites[1] == ["tracked.B": true, "tracked.C": true])
    #expect(w.restarts == 2)
    #expect(Set(w.order) == ["A", "B", "C", "D"])
}

@Test func batchAlreadySatisfiedDoesNothing() async {
    let w = World(["A", "B"])
    let r = await actuator(w).setHidden(key("A"), false)
    #expect(r.isVerified)
    #expect(w.allowedWrites.isEmpty && w.restarts == 0)
}

@Test func batchIsAllOrNothingAtTheWriteStage() async {
    let w = World(["A", "B", "C"])
    w.untracked = ["C"]
    let out = await actuator(w).applyHiddenBatchDetailed([key("A"): true, key("C"): true])
    if case .failed(.unsupportedItem, _) = out.result {} else { Issue.record("got \(out.result)") }
    #expect(out.perKey.count == 2 && out.perKey.values.allSatisfy { !$0.isVerified })   // A is refused too
    #expect(w.allowedWrites.isEmpty && w.restarts == 0)
    let missing = await actuator(w).applyHiddenBatchDetailed([key("A"): true, key("Z"): true])
    #expect(missing.result.error == .notFound)
    #expect(w.allowedWrites.isEmpty)
    let sys = await actuator(w).applyHiddenBatchDetailed([.module(name: "Clock"): true])
    #expect(sys.result.error == .notFound)
}

@Test func batchPartialVerificationShapesPerKeyAndAggregate() async {
    let w = World(["A", "B", "C"])
    // After the restart B is still on the bar (e.g. an app re-adds it): A hides, B does not.
    w.restartAppliesAllowed = false
    let out = await actuator(w).applyHiddenBatchDetailed([key("A"): true, key("B"): true])
    #expect(!out.result.isVerified)
    #expect(out.perKey[key("A")]?.isVerified == false)
    if case .failed(.notVerified(_, let observed), _) = out.result { #expect(observed.contains("failed:")) } else { Issue.record("got \(out.result)") }
    #expect(w.restarts == 2)       // the flags landed but nothing changed: one restart retry, then give up
    #expect(w.allowedWrites.count == 1)
}

@Test func batchSiblingsOfTheSameAppAreVerifiedToo() async {
    // B and C belong to one app (one isAllowed flag): hiding B also hides C, and C is verified and reported.
    let w = World(["A", "B", "C"])
    w.shared = ["B": "tracked.BC", "C": "tracked.BC"]
    let out = await actuator(w).applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified)
    #expect(Set(out.perKey.keys) == [key("B"), key("C")])
    #expect(w.allowedWrites == [["tracked.BC": false]])
    #expect(w.order == ["A"])
}

@Test func batchRejectsConflictingRequestsForOneApp() async {
    let w = World(["A", "B"])
    w.shared = ["A": "tracked.AB", "B": "tracked.AB"]
    let out = await actuator(w).applyHiddenBatchDetailed([key("A"): true, key("B"): false])
    if case .failed(.mechanismFailed, _) = out.result {} else { Issue.record("got \(out.result)") }
    #expect(w.allowedWrites.isEmpty && w.restarts == 0)
    let empty = await actuator(w).applyHiddenBatchDetailed([:])
    #expect(empty.result.isVerified && empty.perKey.isEmpty)
}

@Test func actuationsAreSerialized() async {
    let w = World(["A", "B", "C", "D"])
    let act = actuator(w)
    async let r1 = act.move(key("A"), relation: .after(key("B")))
    async let r2 = act.move(key("D"), relation: .before(key("A")))
    let (a, b) = await (r1, r2)
    #expect(a.isVerified && b.isVerified, "\(a) \(b) order=\(w.order)")
    #expect(w.dragCalls.count == 2, "drags=\(w.dragCalls.count) order=\(w.order)")
}

// MARK: - Corrective pass: dropped reads are not verdicts

@Test func movePrecheckDoesNotTrustASingleScanThatDroppedTheItem() async {
    let w = World(["A", "B", "C", "D"])
    w.dropScans = 1; w.dropName = "A"          // the first full scan misses A
    let r = await actuator(w).move(key("A"), relation: .after(key("C")))
    #expect(r.isVerified)
    #expect(w.order == ["B", "C", "A", "D"])
}

@Test func moveVerificationSurvivesADroppedScanAfterTheDrag() async {
    let w = World(["A", "B", "C", "D"])
    w.dropName = "A"; w.dropAfterDrag = 1       // the verdict scan after the drag misses A once
    let r = await actuator(w).move(key("A"), relation: .after(key("C")))
    #expect(r.isVerified)
    #expect(w.dragCalls.count == 1)             // no second drag because of a read glitch
}

@Test func emptyScanIsNeverAVerdict() async {
    let w = World(["A", "B", "C"])
    w.emptyScans = 2
    let r = await actuator(w).move(key("A"), relation: .after(key("C")))
    #expect(r.isVerified)
    // Truly absent item: still notFound, but only after confirmation scans.
    let w2 = World(["A", "B"])
    let before = w2.fullScans
    #expect((await actuator(w2).move(key("Z"), relation: .after(key("B")))).error == .notFound)
    #expect(w2.fullScans - before >= 2 && w2.fastScans >= 1)
}

@Test func batchNotFoundIsConfirmedByAnotherScan() async {
    let w = World(["A", "B", "C"])
    w.dropScans = 1; w.dropName = "B"
    let out = await actuator(w).applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified)
}

// MARK: - Corrective pass: collateral check

@Test func collateralTransientFlickerIsNotCounted() async {
    let w = World(["A", "B", "C", "D"])
    w.flickerName = "D"; w.flickerAfterRestart = 3     // D reads as parked in the scans right after the restart only
    let out = await actuator(w).applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified)
}

@Test func collateralPersistentOffBarIsCounted() async {
    let w = World(["A", "B", "C", "D"])
    w.restartParks = ["D"]      // the restart really takes D off the bar
    let out = await actuator(w).applyHiddenBatchDetailed([key("B"): true])
    guard case .failed(.notVerified(let e, let o), _) = out.result else { Issue.record("got \(out.result)"); return }
    #expect(e == "no other item changes")
    #expect(o.contains("off the bar") && o.contains(key("D").description))
}

@Test func itemsOffBeforeAndOnAfterRestartAreNotCollateral() async {
    // P was parked (not part of the batch); the restart brings it back on the bar: that is re-layout, not a change.
    let w = World(["A", "B", "C"])
    w.hidden = ["P"]
    w.untracked = ["P"]
    w.shared = [:]
    let out = await actuator(w).applyHiddenBatchDetailed([key("B"): true])
    // simulate P reappearing during the restart
    #expect(out.result.isVerified)
    w.hidden.remove("P"); w.order.append("P")
    let back = await actuator(w).applyHiddenBatchDetailed([key("B"): false])
    #expect(back.result.isVerified)
}

// MARK: - Corrective pass: order drift after a restart (docs/findings-restart-collateral.md)

@Test func hideRestoresNonBatchOrderWhenTheRestartReSortsItems() async {
    let w = World(["A", "B", "C", "D"])
    w.restartDrift = [["C": 2000]]                  // the agent re-bases C's value above everything
    let out = await actuator(w).applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified)
    #expect(w.order == ["A", "C", "D"])             // pre-restart relative order kept
    #expect(w.restarts == 2)                        // one for the batch, one for the repair
    #expect(w.storeWrites.count == 1)
    #expect(w.storeWrites[0][key("C").description] == 800)   // C's pre-restart value written back
}

@Test func showPutsTheItemBackInItsPreRestartSlot() async {
    let w = World(["A", "B", "C", "D"])
    #expect((await actuator(w).applyHiddenBatchDetailed([key("B"): true])).result.isVerified)
    w.restartDrift = [["B": 1]]                     // on return the agent files B at the far right
    let out = await actuator(w).applyHiddenBatchDetailed([key("B"): false])
    #expect(out.result.isVerified)
    #expect(w.order == ["A", "B", "C", "D"])
}

@Test func noRepairWhenOrderIsUnchanged() async {
    let w = World(["A", "B", "C", "D"])
    _ = await actuator(w).applyHiddenBatchDetailed([key("B"): true])
    #expect(w.restarts == 1 && w.storeWrites.isEmpty)
}

// MARK: - Second corrective pass

@Test func emptyScanThatStaysEmptyNeverSettles() async {
    let w = World(["A", "B"])
    w.emptyScans = 1_000
    let out = await SettleDetector(scanner: w, now: { w.now() }, sleep: { await w.sleep($0) }).settled(maxWait: 1, stableFor: 0.15)
    #expect(!out.settled)
    #expect(out.snapshot.onBarLeftToRight.isEmpty)
    // and the actuator turns it into a timeout, not a verified result
    let w2 = World(["A", "B", "C"])
    w2.emptyScans = 1_000
    let r = await actuator(w2).move(key("A"), relation: .after(key("C")))
    #expect(!r.isVerified)
}

@Test func frameOnlyDriftTriggersRepairAndIsFixed() async {
    let w = World(["A", "B", "C", "D"])
    w.restartReorder = [["C", "A", "D"]]            // store values untouched, but the frame order changed
    let act = actuator(w)
    let out = await act.applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified)
    #expect(w.order == ["A", "C", "D"])
    #expect(w.restarts == 2)
    #expect(await act.driftRepairs == 1)
}

@Test func driftThatSurvivesTheRepairFailsTheBatch() async {
    let w = World(["A", "B", "C", "D"])
    w.restartReorder = [["C", "A", "D"], ["C", "A", "D"]]
    let out = await actuator(w).applyHiddenBatchDetailed([key("B"): true])
    guard case .failed(.notVerified(let e, let o), _) = out.result else { Issue.record("got \(out.result)"); return }
    #expect(e.contains("relative order kept") && o.contains("did not restore"))
    #expect(w.restarts == 2)
}

@Test func failedRepairWriteFailsTheBatch() async {
    let w = World(["A", "B", "C", "D"])
    w.restartDrift = [["C": 2000]]
    w.failStoreWrite = true
    let out = await actuator(w).applyHiddenBatchDetailed([key("B"): true])
    guard case .failed(.notVerified(_, let o), _) = out.result else { Issue.record("got \(out.result)"); return }
    #expect(o.contains("could not be applied"))
}

@Test func noDriftNoRepair() async {
    let w = World(["A", "B", "C", "D"])
    let act = actuator(w)
    _ = await act.applyHiddenBatchDetailed([key("B"): true])
    #expect(await act.driftRepairs == 0 && w.restarts == 1)
}

@Test func selfPositioningOwnersAreNotDrift() async {
    let w = World(["A", "B", "C", "D"])
    w.restartReorder = [["C", "A", "D"]]            // C moves itself (like iStat); A and D keep their order
    var c = LiveActuator.Config()
    c.selfPositioningOwners = ["app.C"]
    let act = LiveActuator(platform: w, config: c)
    let out = await act.applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified)
    #expect(w.restarts == 1)
    #expect(await act.driftRepairs == 0)
}

@Test func visibilityVerdictAcceptsNotHostedAsHidden() {
    let k = key("A")
    var r = FakeMenuBar.resolved(onBar: [k])
    r[0].item.notHostedByAgent = true
    r[0].item.isOnMenuBar = false
    #expect(r[0].item.hiddenReason == .notHosted)
    #expect(ActuationVerifier.visibilityVerdict(key: k, hidden: true, resolved: r).ok)
    #expect(!ActuationVerifier.visibilityVerdict(key: k, hidden: false, resolved: r).ok)
}


// MARK: - live (cfprefsd-notified) hide/show

@Test func liveVerifiedOnSecondPollWithoutRestart() async {
    let w = World(["A", "B", "C"])
    w.liveAvailable = true; w.liveIncompleteScans = 1; w.liveApplyAfterScans = 2
    let out = await liveActuator(w).applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified)
    #expect(out.mechanism == .live)
    #expect(w.restarts == 0 && w.allowedWrites.isEmpty)
    #expect(w.liveWrites == [["tracked.B": false]])
    #expect(w.order == ["A", "C"] && w.hidden == ["B"])
    #expect((out.elapsedMS ?? 0) >= 1000)          // two polls of 0.5 s on the fake clock
}

@Test func liveUnavailableUsesRespawnExactlyAsBefore() async {
    let w = World(["A", "B", "C"])
    w.liveAvailable = false
    let out = await liveActuator(w).applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified && out.mechanism == .respawn)
    #expect(w.liveWrites.isEmpty && w.restarts == 1 && w.allowedWrites == [["tracked.B": false]])
}

@Test func liveWriteThrowFallsBackToOneRestart() async {
    let w = World(["A", "B", "C"])
    w.liveAvailable = true; w.liveThrows = true
    let out = await liveActuator(w).applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified && out.mechanism == .respawn)
    #expect(w.restarts == 1 && w.allowedWrites.count == 1)
}

@Test func liveTwoCompleteUnsatisfiedReadsFallBackToOneRestart() async {
    let w = World(["A", "B", "C"])
    w.liveAvailable = true; w.liveApplyAfterScans = nil
    let a = liveActuator(w)
    let out = await a.applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified && out.mechanism == .respawn)
    #expect(w.restarts == 1 && w.liveWrites.count == 1 && w.allowedWrites.count == 1)
    #expect(await a.trace.contains { $0.contains("2 scans, 2 complete") && $0.contains("two complete reads unsatisfied") })
}

@Test func liveOneUnsatisfiedCompleteReadThenSatisfiedIsLive() async {
    let w = World(["A", "B", "C"])
    w.liveAvailable = true; w.liveApplyAfterScans = 2     // scan 1 complete but pre-write state, scan 2 shows it
    let out = await liveActuator(w).applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified && out.mechanism == .live && w.restarts == 0)
}

@Test func liveEightIncompleteReadsThenFallback() async {
    let w = World(["A", "B", "C"])
    w.liveAvailable = true; w.liveIncompleteScans = 100; w.liveApplyAfterScans = 1
    let a = liveActuator(w)
    let out = await a.applyHiddenBatchDetailed([key("B"): true])
    #expect(out.mechanism == .respawn && out.result.isVerified)
    #expect(w.restarts == 1)
    #expect(await a.trace.contains { $0.contains("8 scans, 0 complete") && $0.contains("max scans") })
}

@Test func liveSevenIncompleteThenOneCompleteSatisfiedIsLive() async {
    let w = World(["A", "B", "C"])
    w.liveAvailable = true; w.liveIncompleteScans = 7; w.liveApplyAfterScans = 8
    let a = liveActuator(w)
    let out = await a.applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified && out.mechanism == .live && w.restarts == 0)
    #expect(await a.trace.contains { $0.contains("8 scans, 1 complete") })
}

@Test func liveIncompleteReadsAloneAreNotFailure() async {
    let w = World(["A", "B"])
    w.liveAvailable = true; w.liveIncompleteScans = 5; w.liveApplyAfterScans = 6
    let out = await liveActuator(w).applyHiddenBatchDetailed([key("A"): true])
    #expect(out.result.isVerified && out.mechanism == .live && w.restarts == 0)
}

@Test func liveSiblingsOfTheSameAppAreVerifiedToo() async {
    let w = World(["A", "B", "C"])
    w.liveAvailable = true; w.shared = ["B": "tracked.BC", "C": "tracked.BC"]
    let out = await liveActuator(w).applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified && out.mechanism == .live)
    #expect(Set(out.perKey.keys) == [key("B"), key("C")])
    #expect(w.liveWrites == [["tracked.BC": false]] && w.order == ["A"] && w.restarts == 0)
}

@Test func liveShowRoundTrip() async {
    let w = World(["A", "B"])
    w.liveAvailable = true; w.liveApplyAfterScans = 1
    let a = liveActuator(w)
    #expect((await a.applyHiddenBatchDetailed([key("B"): true])).mechanism == .live)
    let back = await a.applyHiddenBatchDetailed([key("B"): false])
    #expect(back.result.isVerified && back.mechanism == .live && w.restarts == 0)
    #expect(Set(w.order) == ["A", "B"])
}

@Test func liveDisabledInConfigBypassesTheLivePath() async {
    let w = World(["A", "B"])
    w.liveAvailable = true
    let out = await liveActuator(w, live: false).applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified && out.mechanism == .respawn)
    #expect(w.liveWrites.isEmpty && w.restarts == 1)
}

// MARK: - ControlCenterTrackedAppsStore.setAllowedBatchLive (injected CFPreferences)

private func trackedBlob(_ entries: [(String, Bool)]) -> Data {
    var list: [Any] = []
    for (k, allowed) in entries {
        let loc: [String: Any] = ["bundle": ["_0": k]]
        list.append(loc)
        list.append(["location": loc, "menuItemLocations": [loc], "isAllowed": allowed] as [String: Any])
    }
    return try! PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
}

private final class FakePrefs: @unchecked Sendable {
    var blob: Data?
    var file: Data?
    var syncOK = true
    var dropWrites = false
    var writes = 0
    init(_ b: Data?) { blob = b }
    var access: LivePrefsAccess {
        LivePrefsAccess(read: { self.blob },
                        write: { d in self.writes += 1; if !self.dropWrites { self.blob = d }; return self.syncOK },
                        fileBlob: { self.file })
    }
}

@Test func liveStoreWritesAndReadsBackThroughPrefs() throws {
    let p = FakePrefs(trackedBlob([("ie.x", true), ("ie.y", true)]))
    var s = ControlCenterTrackedAppsStore(url: URL(fileURLWithPath: "/nonexistent/cc.plist"))
    try s.setAllowedBatchLive(["ie.x": false], access: p.access)
    #expect(p.writes == 1)
    #expect(try ControlCenterTrackedAppsStore.allowedLive(["ie.x", "ie.y"], access: p.access) == ["ie.x": false, "ie.y": true])
    #expect(s.liveBackup != nil)
}

@Test func liveStoreRefusesModuleSystemAndUnknownKeysWithoutWriting() throws {
    let p = FakePrefs(trackedBlob([("ie.x", true)]))
    var s = ControlCenterTrackedAppsStore(url: URL(fileURLWithPath: "/nonexistent/cc.plist"))
    #expect(throws: PreferenceWriterError.self) { try s.setAllowedBatchLive(["module:Clock": false], access: p.access) }
    #expect(throws: PreferenceWriterError.self) { try s.setAllowedBatchLive(["com.apple.Safari": false], access: p.access) }
    #expect(throws: PreferenceWriterError.self) { try s.setAllowedBatchLive(["ie.x": false, "ie.nope": false], access: p.access) }
    #expect(p.writes == 0)
    #expect(try ControlCenterTrackedAppsStore.allowedLive(["ie.x"], access: p.access) == ["ie.x": true])
}

@Test func liveStoreThrowsWhenSynchronizeFailsOrValueDoesNotTake() {
    let p = FakePrefs(trackedBlob([("ie.x", true)]))
    var s = ControlCenterTrackedAppsStore(url: URL(fileURLWithPath: "/nonexistent/cc.plist"))
    p.syncOK = false
    #expect(throws: PreferenceWriterError.self) { try s.setAllowedBatchLive(["ie.x": false], access: p.access) }
    p.blob = trackedBlob([("ie.x", true)]); p.syncOK = true; p.dropWrites = true
    #expect(throws: PreferenceWriterError.self) { try s.setAllowedBatchLive(["ie.x": false], access: p.access) }
}

@Test func liveStoreFallsBackToFileBlobAndReportsWhenBothFail() throws {
    let p = FakePrefs(nil)
    var s = ControlCenterTrackedAppsStore(url: URL(fileURLWithPath: "/nonexistent/cc.plist"))
    #expect(throws: PreferenceWriterError.self) { try s.setAllowedBatchLive(["ie.x": false], access: p.access) }
    p.file = trackedBlob([("ie.x", true)])
    // Read-back also goes through CFPreferences: with nothing stored there yet, the write must land.
    try s.setAllowedBatchLive(["ie.x": false], access: p.access)
    #expect(try ControlCenterTrackedAppsStore.allowedLive(["ie.x"], access: p.access) == ["ie.x": false])
}

// MARK: - fallback: duplicate position values (gdu.25)

@Test func fallbackWithDuplicateValuesElsewhereWritesOnlyTheSubjectMidpoint() async {
    let w = World(["A", "B", "C", "D"])
    w.store = [key("A").description: 1000, key("B").description: 900, key("C").description: 900, key("D").description: 700]
    let r = await actuator(w, forceFallback: true).move(key("D"), relation: .before(key("B")))
    #expect(r.isVerified)
    #expect(w.order == ["A", "D", "B", "C"])
    #expect(w.storeWrites == [[key("D").description: 950]])     // one write, one key, midpoint of 1000 and 900
    #expect(w.restarts == 1)
}

@Test func fallbackWithEqualNeighbourValuesRebasesOnlyTheRunAndVerifies() async {
    let w = World(["A", "B", "C", "D"])
    w.store = [key("A").description: 1000, key("B").description: 1000, key("C").description: 800, key("D").description: 700]
    let r = await actuator(w, forceFallback: true).move(key("D"), relation: .after(key("A")))
    #expect(r.isVerified)
    #expect(w.order == ["A", "D", "B", "C"])
    #expect(w.storeWrites.count == 1 && w.restarts == 1)
    #expect(Set(w.storeWrites[0].keys) == [key("A").description, key("D").description])   // B and C untouched
    #expect(w.store[key("B").description] == 1000 && w.store[key("C").description] == 800)
}

@Test func fallbackNeverRunsWhenDisallowed() async {
    let w = World(["A", "B", "C"])
    w.dragScript = [.noop, .noop]
    let r = await actuator(w, fallback: false).move(key("A"), relation: .after(key("C")))
    #expect(!r.isVerified)
    #expect(w.storeWrites.isEmpty && w.restarts == 0)
    let w2 = World(["A", "B", "C"])
    #expect(!(await actuator(w2, fallback: false, forceFallback: true).move(key("A"), relation: .after(key("C")))).isVerified)
    #expect(w2.storeWrites.isEmpty && w2.restarts == 0 && w2.dragCalls.isEmpty)
}

// MARK: - overflow area (gdu.25)

@Test func moveOfAnOverflowedItemSkipsDragsAndFailsHonestly() async {
    let w = World(["A", "B", "Show Hidden Menu Bar Items", "C", "D"])
    w.modules = ["Show Hidden Menu Bar Items"]
    let r = await actuator(w, fallback: false).move(key("A"), relation: .after(key("B")))
    guard case .failed(.mechanismFailed(let why), _)? = Optional(r) else { Issue.record("expected mechanismFailed, got \(r)"); return }
    #expect(why.contains("overflow"))
    #expect(w.dragCalls.isEmpty && w.restarts == 0 && w.storeWrites.isEmpty)
}

@Test func moveToAnOverflowedTargetFallsBackWhenAllowed() async {
    let w = World(["A", "B", "Show Hidden Menu Bar Items", "C", "D"])
    w.modules = ["Show Hidden Menu Bar Items"]
    let r = await actuator(w).move(key("D"), relation: .before(key("B")))
    #expect(r.isVerified)
    #expect(w.dragCalls.isEmpty)
    #expect(w.restarts == 1 && w.storeWrites.count == 1)
}

@Test func overflowedDetectsItemsBeforeTheChevronAndStackedFrames() {
    func r(_ n: String, x: CGFloat, w: CGFloat = 30, module: Bool = false) -> ResolvedItem {
        ResolvedItem(item: item(n, x: x), key: module ? .module(name: n) : key(n), confidence: .exact)
    }
    var a = r("A", x: 100), b = r("B", x: 140)
    a.item.frame.size.width = 30; b.item.frame.size.width = 30
    let chev = r("Show Hidden Menu Bar Items", x: 200, module: true)
    let c = r("C", x: 230)
    #expect(ActuationVerifier.overflowed([a, b, chev, c]) == [key("A"), key("B")])
    #expect(ActuationVerifier.overflowed([a, b, c]).isEmpty)
    var s = b; s.item.frame.origin.x = 100                        // B stacked exactly on A, no chevron read
    #expect(ActuationVerifier.overflowed([a, s, c]) == [key("A"), key("B")])
}

// MARK: - identifier-less items: write-time hosted-element evidence (of7)

@Test func unnamedLiveHideIsVerifiedByExactElementEvidence() async {
    let w = World(["A", "B", "C"])
    w.liveAvailable = true; w.liveInstant = true; w.unnamed = ["B"]
    let a = liveActuator(w)
    let out = await a.applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified && out.mechanism == .live)
    #expect(w.restarts == 0 && w.allowedWrites.isEmpty)
    #expect(w.assumedPIDs == [w.pidOf("B")])
    #expect(w.assumedRecords.first?.owners == [AssumedHiddenOwner(pid: w.pidOf("B"), bundleID: "app.B", items: 1, trackedKey: "tracked.B")])
    #expect(w.assumedRecords.first?.after == 2)
    let trace = await a.trace
    #expect(trace.contains { $0.contains("baseline = pre-write full scan") })
    #expect(trace.contains { $0.contains("verified by hosted-element evidence") })
    // A show by us clears the state before the verification scans read it.
    let back = await a.applyHiddenBatchDetailed([key("B"): false])
    #expect(back.result.isVerified && back.mechanism == .live && w.restarts == 0)
    #expect(w.assumedPIDs.isEmpty && w.clearedPIDs.contains([w.pidOf("B")]))
}

@Test func coincidentalVanishWithAMatchingCountIsAmbiguous() async {
    // B vanishes as expected, but ANOTHER element is replaced at the same time (count identical): not the unit's elements
    // only -> nothing recorded, the ghost stays on-bar, the poll cannot confirm and the pre-existing respawn runs once.
    let w = World(["A", "B", "C"])
    w.liveAvailable = true; w.liveInstant = true; w.unnamed = ["B"]
    w.hostedTamper = { $0[1].sig = "someone-else" }
    let out = await liveActuator(w).applyHiddenBatchDetailed([key("B"): true])
    #expect(w.assumedRecords.isEmpty && w.assumedPIDs.isEmpty)
    #expect(out.mechanism == .respawn && w.restarts == 1)
    #expect(out.result.isVerified)
}

@Test func pollScanEvidenceCoversIncompleteOrEarlyProbes() async {
    let w = World(["A", "B", "C"])
    w.liveAvailable = true; w.liveInstant = true; w.unnamed = ["B"]
    w.probeOnlyTamper = { $0.removeAll() }          // every timed probe is unusable
    let a = liveActuator(w)
    let out = await a.applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified && out.mechanism == .live && w.restarts == 0)
    #expect(w.assumedPIDs == [w.pidOf("B")])
    #expect(await a.trace.contains { $0.contains("hosted-element evidence (poll scan #1)") })
}

@Test func anotherItemLeavingTheBarRejectsTheEvidence() async {
    // The hosted tree matches, but a different app-side item also left the bar (c): evidence rejected, assumption cleared.
    let w = World(["A", "B", "C"])
    w.liveAvailable = true; w.liveInstant = true; w.unnamed = ["B"]
    w.dropAfterWrite = "C"
    let a = liveActuator(w)
    _ = await a.applyHiddenBatchDetailed([key("B"): true])
    #expect(await a.trace.contains { $0.contains("element evidence rejected") })
    #expect(w.assumedPIDs.isEmpty)
}

@Test func incompleteBaselineScanIsRetriedWithinFourSecondsThenCache() async {
    let w = World(["A", "B", "C"])
    w.liveAvailable = true; w.liveInstant = true; w.unnamed = ["B"]; w.preScansIncomplete = 2
    let a = liveActuator(w)
    let out = await a.applyHiddenBatchDetailed([key("B"): true])
    #expect(out.mechanism == .live && w.restarts == 0)
    #expect(await a.trace.contains { $0.contains("baseline = retried full scan") })

    let v = World(["A", "B", "C"])
    v.liveAvailable = true; v.liveInstant = true; v.unnamed = ["B"]; v.preScansIncomplete = 1000
    v.cachedLayout = v.layout(attributed: true)
    let b = liveActuator(v)
    _ = await b.applyHiddenBatchDetailed([key("B"): true])
    #expect(await b.trace.contains { $0.contains("baseline = scanner cache") })
}

@Test func namedItemsNeverReadTheHostedTree() async {
    let w = World(["A", "B", "C"])
    w.liveAvailable = true; w.liveApplyAfterScans = 1
    let out = await liveActuator(w).applyHiddenBatchDetailed([key("B"): true])
    #expect(out.mechanism == .live && w.hostedReads == 0 && w.assumedRecords.isEmpty)
}

@Test func unnamedHideAlreadyHiddenInTheStoreWritesNothing() async {
    // The store says hidden (isAllowed false) but the app-side frame is stale on-bar: no write, no respawn, a record, .verified.
    let w = World(["A", "B", "C"])
    w.liveAvailable = true; w.unnamed = ["B"]; w.allowedLiveValues = ["tracked.B": false]
    let a = liveActuator(w)
    let out = await a.applyHiddenBatchDetailed([key("B"): true])
    #expect(out.result.isVerified && out.mechanism == .alreadyApplied)
    #expect(w.liveWrites.isEmpty && w.allowedWrites.isEmpty && w.restarts == 0)
    #expect(w.assumedPIDs == [w.pidOf("B")])
    #expect(await a.trace.contains { $0.contains("already hidden per Control Center store; recorded assumed-hidden") })
}

@Test func storeSayingShownOrNamedItemsAreNotShortCircuited() async {
    let w = World(["A", "B", "C"])
    w.liveAvailable = true; w.liveInstant = true; w.unnamed = ["B"]; w.allowedLiveValues = ["tracked.B": true]
    let out = await liveActuator(w).applyHiddenBatchDetailed([key("B"): true])
    #expect(out.mechanism == .live && w.liveWrites.count == 1)
    let v = World(["A", "B", "C"])
    v.liveAvailable = true; v.liveApplyAfterScans = 1; v.allowedLiveValues = ["tracked.B": false]   // B is named
    let o2 = await liveActuator(v).applyHiddenBatchDetailed([key("B"): true])
    #expect(o2.mechanism == .live && v.liveWrites.count == 1 && v.assumedRecords.isEmpty)
}

// gdu.47: a batch asking the opposite of a write made moments ago rescans before it trusts its pre-write snapshot.
@Test func oppositeBatchRightAfterAWriteWaitsAndRescans() async {
    let w = World(["A", "B", "C"])
    var c = LiveActuator.Config()
    c.recentWriteSettle = 1e6   // the fake clock only moves by sleeps: make "moments ago" cover the whole test
    let a = LiveActuator(platform: w, config: c)
    let hide = await a.applyHiddenBatchDetailed([key("B"): true])
    #expect(hide.result.isVerified)
    let show = await a.applyHiddenBatchDetailed([key("B"): false])
    #expect(show.result.isVerified)
    #expect(await a.trace.contains { $0.contains("opposite of a write made") })
    #expect(w.allowedWrites == [["tracked.B": false], ["tracked.B": true]])   // one write per direction
    #expect(Set(w.order) == ["A", "B", "C"])
}
