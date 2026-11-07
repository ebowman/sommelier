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
    var tree = AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [])
    func runningApps() -> [RunningAppInfo] { apps }
    func extrasItems(for app: RunningAppInfo) -> [AXElementInfo] { extras[app.pid] ?? [] }
    func readExtras(for app: RunningAppInfo, timeout: Float?) -> ExtrasRead {
        failing.contains(app.pid) ? .failed("fixture timeout") : .items(extrasItems(for: app))
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
