import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

/// gdu.120: an iStat Menus item is frame-trusted and not stale whenever EITHER side has a fresh frame for its key; it is stale only
/// when nothing fresh exists. Hermetic: fabricated scan input, no live AX.
private struct Src: AccessibilitySource {
    var currentPID: pid_t = 1
    var apps: [RunningAppInfo] = []
    var extras: [pid_t: [AXElementInfo]] = [:]
    var failing: Set<pid_t> = []
    var failText = "fixture timeout"
    var delay: [pid_t: TimeInterval] = [:]
    var tree = AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [])
    func runningApps() -> [RunningAppInfo] { apps }
    func extrasItems(for app: RunningAppInfo) -> [AXElementInfo] { extras[app.pid] ?? [] }
    func readExtras(for app: RunningAppInfo, timeout: Float?) -> ExtrasRead {
        if let d = delay[app.pid] { Thread.sleep(forTimeInterval: d) }
        return failing.contains(app.pid) ? .failed(failText) : .items(extrasItems(for: app))
    }
    func agentHostedTree(for agent: RunningAppInfo) -> AgentHostedTree { tree }
}

private let strip = CGRect(x: 0, y: 0, width: 2000, height: 30)
private let agentApp = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
private let istat = RunningAppInfo(pid: 20, bundleID: "com.bjango.istatmenus.status", name: "iStat Menus Menubar")
private func bar(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 3, width: 24, height: 24) }
private let wid = "com.bjango.istatmenus.weather"
private func weather(_ x: CGFloat) -> AXElementInfo { AXElementInfo(axDescription: "iStat Weather", identifier: wid, frame: bar(x)) }
private let clock = AXElementInfo(axDescription: "Clock", identifier: "com.apple.menuextra.clock", frame: bar(900))
private func tree(_ e: [AXElementInfo], failed: Int = 0, timedOut: [AXElementInfo] = []) -> AgentHostedTree {
    AgentHostedTree(stripFrame: strip, elements: e, failedReads: failed, timedOut: timedOut)
}

/// Warm scan (iStat at 300), then a scan in which iStat's own AX read fails (cached, stale app-side frame 300) while the agent
/// hosts the element fresh at 500 (the item was Command-dragged).
@Test func staleAppSideFrameWithFreshHostedFrameIsTrustedAndNotStale() {
    var s = Src(apps: [agentApp, istat])
    s.extras[20] = [weather(300)]
    s.tree = tree([weather(300), clock])
    var scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    s.failing = [20]
    s.tree = tree([weather(500), clock])
    scanner.source = s
    let item = scanner.scan().items.first { $0.axIdentifier == wid }
    #expect(item != nil)
    #expect(item?.stale == false)
    #expect(item?.frame == bar(500))
    #expect(item?.isOnMenuBar == true)
}

/// Reverse: no hosted element at all, only the stale cached app-side frame: still stale (the old frame is never believed fresh).
@Test func staleAppSideFrameWithoutHostedElementStaysStale() {
    var s = Src(apps: [agentApp, istat])
    s.extras[20] = [weather(300)]
    s.tree = tree([weather(300), clock])
    var scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    s.failing = [20]
    s.tree = tree([clock])
    scanner.source = s
    let item = scanner.scan().items.first { $0.axIdentifier == wid }
    #expect(item?.stale == true)
    #expect(item?.frame == bar(300))
}

/// The observed flip: iStat answers in its own process (fresh app-side frame 310) while the agent's copy of the group timed out and
/// is only carried (stale frame 300). The fresh read wins; the item is not stale.
@Test func freshAppSideFrameBeatsCarriedHostedFrame() {
    var s = Src(apps: [agentApp, istat])
    s.extras[20] = [weather(310)]
    s.tree = tree([clock], failed: 1, timedOut: [weather(300)])
    let item = MenuBarScanner(source: s).scan().items.first { $0.axIdentifier == wid }
    #expect(item?.stale == false)
    #expect(item?.frame == bar(310))
}

/// Both sides stale (owner read failed AND hosted copy only carried): nothing fresh exists, so the item stays stale.
@Test func bothSidesStaleStaysStale() {
    var s = Src(apps: [agentApp, istat])
    s.extras[20] = [weather(300)]
    s.tree = tree([weather(300), clock])
    var scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    s.failing = [20]
    s.tree = tree([clock], failed: 1, timedOut: [weather(300)])
    scanner.source = s
    let item = scanner.scan().items.first { $0.axIdentifier == wid }
    #expect(item?.stale == true)
}

// MARK: gdu.120 corrective: carried-frame tolerance (display/agreement only) and the reads diagnostic

private func stale(_ e: AXElementInfo) -> AXElementInfo { var s = e; s.stale = true; return s }

/// Warm scan (weather fresh at 300), then `n` scans in which iStat's app read fails and the hosted group is only carried.
private func carriedRun(_ n: Int, carriedFrame: CGFloat = 300) -> [MenuBarItem?] {
    var s = Src(apps: [agentApp, istat])
    s.extras[20] = [weather(300)]
    s.tree = tree([weather(300), clock])
    var scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    s.failing = [20]
    s.tree = tree([clock], failed: 1, timedOut: [stale(weather(carriedFrame))])
    scanner.source = s
    return (0..<n).map { _ in scanner.scan().items.first { $0.axIdentifier == wid } }
}

@Test func carriedOneScanWithUnchangedFrameIsRecentlyVerifiedButStillStale() {
    let it = carriedRun(1)[0]
    #expect(it?.stale == true && it?.recentlyVerified == true)
}

@Test func carriedThreeScansIsNoLongerRecentlyVerified() {
    let r = carriedRun(3)
    #expect(r[0]?.recentlyVerified == true && r[1]?.recentlyVerified == true)   // ScanState.recentlyVerifiedMaxScans == 2
    #expect(r[2]?.stale == true && r[2]?.recentlyVerified == false)
}

@Test func carriedWithADifferentFrameIsNotRecentlyVerified() {
    let it = carriedRun(1, carriedFrame: 340)[0]
    #expect(it?.stale == true && it?.recentlyVerified == false)
}

@Test func readsDiagnosticListsAppAndHostedOutcomePerOwner() {
    var s = Src(apps: [agentApp, istat])
    s.extras[20] = [weather(300)]; s.failing = [20]
    s.tree = tree([clock], failed: 1, timedOut: [stale(weather(300))])
    let line = MenuBarScanner(source: s).scan().selfPositioningReads
    #expect(line == "iStat Menus Menubar: app=failed hosted=carried(1)")   // the fixture's failure text has no "timed out" marker
}

private func obsItem(_ n: String, x: CGFloat, stale: Bool, recent: Bool) -> ResolvedItem {
    var it = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "o", title: n, axDescription: "", axIdentifier: n,
                         frame: CGRect(x: x, y: 3, width: 24, height: 24), source: .appExtras, isOnMenuBar: true, stale: stale)
    it.recentlyVerified = recent
    return ResolvedItem(item: it, key: .status(ownerKey: "o", autosaveName: n), confidence: .exact)
}

@Test func recentlyVerifiedRowIsOrdinaryInArrangeButStaleOneStillShowsTheBadge() {
    let a = ItemKey.status(ownerKey: "o", autosaveName: "a"), s1 = ItemKey.status(ownerKey: "o", autosaveName: "s1")
    let s2 = ItemKey.status(ownerKey: "o", autosaveName: "s2")
    let res = [obsItem("a", x: 100, stale: false, recent: false), obsItem("s1", x: 140, stale: true, recent: true), obsItem("s2", x: 180, stale: true, recent: false)]
    let o = ObservedOrder(resolved: res)
    #expect(o.staleOnBar == [s1, s2] && o.carriedRecently == [s1])
    let c = ArrangeSections.make(observed: o, layout: Layout(visible: [a, s1, s2]), items: [:], perItem: [:],
                                 capabilities: { _ in Capability(canMove: true, canHide: true) })
    #expect(c.visible.rows.first { $0.key == s1 }?.badge != .stale)
    #expect(c.visible.rows.first { $0.key == s2 }?.badge == .stale)
}

@Test func plannerTreatsARecentlyVerifiedItemExactlyLikeAStaleOne() {
    let a = ItemKey.status(ownerKey: "o", autosaveName: "a"), b = ItemKey.status(ownerKey: "o", autosaveName: "b")
    let s1 = ItemKey.status(ownerKey: "o", autosaveName: "s1")
    func plan(recent: Bool) -> Plan {
        let o = ObservedOrder(resolved: [obsItem("a", x: 100, stale: false, recent: false), obsItem("s1", x: 140, stale: true, recent: recent),
                                         obsItem("b", x: 180, stale: false, recent: false)])
        return Reconciler().plan(observed: o, layout: Layout(visible: [b, s1, a]), capabilities: { _ in Capability(canMove: true, canHide: true) })
    }
    let withFlag = plan(recent: true)
    #expect(withFlag.actions == plan(recent: false).actions)
    for act in withFlag.actions {
        guard case .move(let subject, let rel) = act else { continue }
        #expect(subject != s1)
        switch rel { case .before(let t), .after(let t): #expect(t != s1); default: break }
    }
    _ = (a, b)
}

// MARK: gdu.120 narrow fix: injectable clock, diagnostic mapping, real-output badge

private final class Clock: @unchecked Sendable {
    private let l = NSLock(); private var t = Date(timeIntervalSince1970: 1_000_000)
    var value: Date { l.lock(); defer { l.unlock() }; return t }
    func advance(_ s: TimeInterval) { l.lock(); t = t.addingTimeInterval(s); l.unlock() }
}

private func carriedAfter(_ seconds: TimeInterval) -> MenuBarSnapshot {
    var s = Src(apps: [agentApp, istat])
    s.extras[20] = [weather(300)]
    s.tree = tree([weather(300), clock])
    var scanner = MenuBarScanner(source: s)
    let c = Clock()
    scanner.now = { c.value }
    _ = scanner.scan()
    c.advance(seconds)
    s.failing = [20]
    s.tree = tree([clock], failed: 1, timedOut: [stale(weather(300))])
    scanner.source = s
    return scanner.scan()
}

@Test func carriedItemIsNotRecentlyVerified21SecondsAfterTheFreshRead() {
    let snap = carriedAfter(21)
    let it = snap.items.first { $0.axIdentifier == wid }
    #expect(it?.stale == true && it?.recentlyVerified == false)
    let res = snap.items.map { ResolvedItem(item: $0, key: .status(ownerKey: $0.ownerName, autosaveName: $0.axIdentifier), confidence: .exact) }
    let o = ObservedOrder(resolved: res)
    let k = ItemKey.status(ownerKey: istat.name, autosaveName: wid)
    #expect(o.staleOnBar.contains(k) && !o.carriedRecently.contains(k))   // badge shown
}

@Test func carriedItemIsRecentlyVerified19SecondsAfterTheFreshReadAndShowsNoBadge() {
    let snap = carriedAfter(19)
    let it = snap.items.first { $0.axIdentifier == wid }
    #expect(it?.stale == true && it?.recentlyVerified == true)
    // driven by real scanner output, not hand-built items
    let res = snap.items.map { ResolvedItem(item: $0, key: .status(ownerKey: $0.ownerName, autosaveName: $0.axIdentifier), confidence: .exact) }
    let o = ObservedOrder(resolved: res)
    let k = ItemKey.status(ownerKey: istat.name, autosaveName: wid)
    #expect(o.carriedRecently.contains(k))
    let c = ArrangeSections.make(observed: o, layout: Layout(visible: o.onBar), items: [:], perItem: [:],
                                 capabilities: { _ in Capability(canMove: true, canHide: true) })
    #expect(c.visible.rows.first { $0.key == k }?.badge != .stale)
}

@Test func invalidatingAgentStateForgetsTheFreshFrame() {
    var s = Src(apps: [agentApp, istat])
    s.extras[20] = [weather(300)]
    s.tree = tree([weather(300), clock])
    var scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    scanner.invalidateAgentState()
    s.failing = [20]
    s.tree = tree([clock], failed: 1, timedOut: [stale(weather(300))])
    scanner.source = s
    #expect(scanner.scan().items.first { $0.axIdentifier == wid }?.recentlyVerified == false)
}

@Test func readsDiagnosticMapsTimedOutMessageAndMissedBudgetToTimedOut() {
    var s = Src(apps: [agentApp, istat])
    s.extras[20] = [weather(300)]; s.failing = [20]; s.failText = "timed out (kAXErrorCannotComplete)"
    s.tree = tree([clock])
    #expect(MenuBarScanner(source: s).scan().selfPositioningReads?.contains("app=timedOut") == true)
    var b = Src(apps: [agentApp, istat])
    b.extras[20] = [weather(300)]; b.delay = [20: 0.4]; b.tree = tree([clock])
    let line = MenuBarScanner(source: b, extrasBudget: 0.05).scan().selfPositioningReads
    #expect(line?.contains("app=timedOut") == true)
}
