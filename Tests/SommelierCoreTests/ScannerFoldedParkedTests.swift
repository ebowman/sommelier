import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// gdu.121 (corrective): the scanner must read the Control Center flag for PARKED (off-strip frame) and NOT-HOSTED candidates too; the first
// pass looked it up only for on-bar frames, so `foldedParked` stayed empty live. These tests build items THROUGH MenuBarScanner.

private struct Src: AccessibilitySource {
    var currentPID: pid_t = 1
    var apps: [RunningAppInfo] = []
    var extras: [pid_t: [AXElementInfo]] = [:]
    var tree = AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [])
    func runningApps() -> [RunningAppInfo] { apps }
    func extrasItems(for app: RunningAppInfo) -> [AXElementInfo] { extras[app.pid] ?? [] }
    func readExtras(for app: RunningAppInfo, timeout: Float?) -> ExtrasRead { .items(extrasItems(for: app)) }
    func agentHostedTree(for agent: RunningAppInfo) -> AgentHostedTree { tree }
}

private let agent = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
private func bar(_ x: CGFloat, w: CGFloat = 24) -> CGRect { CGRect(x: x, y: 3, width: w, height: 24) }
private let parkedRect = CGRect(x: 563, y: 749, width: 30, height: 24)
private func app(_ n: Int) -> RunningAppInfo { RunningAppInfo(pid: pid_t(100 + n), bundleID: "ie.test.app\(n)", name: "App\(n)") }
private func entry(_ n: Int, _ allowed: Bool) -> ControlCenterTrackedAppsStore.Entry { .init(key: "ie.test.app\(n)", isAllowed: allowed, menuItemKeys: ["ie.test.app\(n)"]) }
private func el(_ n: Int, _ f: CGRect) -> AXElementInfo { AXElementInfo(axDescription: "App\(n)", identifier: "id\(n)", frame: f) }
private let chevronEl = AXElementInfo(axDescription: MenuBarItem.overflowChevronName, frame: CGRect(x: 483, y: 3, width: 17.5, height: 24))

private func scanner(_ src: Src, _ entries: [ControlCenterTrackedAppsStore.Entry]?) -> MenuBarScanner {
    var sc = MenuBarScanner(source: src)
    sc.trackedEntries = { entries.map { .entries($0) } ?? .notConfigured }
    return sc
}
private func item(_ s: MenuBarSnapshot, _ n: Int) -> MenuBarItem { s.items.first { $0.ownerName == "App\(n)" }! }

@Suite struct ScannerControlCenterFlagForParkedTests {
    private func parkedSource() -> Src {
        var s = Src(apps: [agent, app(1)])
        s.extras[101] = [el(1, parkedRect)]
        s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [AXElementInfo(axDescription: "Clock", frame: bar(1500))])
        return s
    }

    @Test func parkedFrameWithAllowedEntryCarriesTheFlag() {
        let i = item(scanner(parkedSource(), [entry(1, true)]).scan(), 1)
        #expect(!i.isOnMenuBar && i.hiddenReason == .parkedFrame && i.controlCenterAllowed == true)
        #expect(!i.hiddenInControlCenter && !i.placementUnknown)
    }

    @Test func parkedFrameWithDisallowedEntryCarriesFalse() {
        // Current behaviour: the on-bar gate never ran for an off-strip frame, so hiddenInControlCenter stays false (unchanged); only the flag is new.
        let i = item(scanner(parkedSource(), [entry(1, false)]).scan(), 1)
        #expect(!i.isOnMenuBar && i.hiddenReason == .parkedFrame && i.controlCenterAllowed == false)
        #expect(!i.hiddenInControlCenter && !i.placementUnknown)
    }

    @Test func unreadableStoreLeavesTheFlagNil() {
        let i = item(scanner(parkedSource(), nil).scan(), 1)
        #expect(!i.isOnMenuBar && i.hiddenReason == .parkedFrame && i.controlCenterAllowed == nil)
    }

    @Test func noEntryForTheBundleLeavesTheFlagNil() {
        let i = item(scanner(parkedSource(), [entry(7, true)]).scan(), 1)
        #expect(i.controlCenterAllowed == nil)
    }

    @Test func notHostedCandidateWithAllowedEntryCarriesTheFlag() {
        var s = Src(apps: [agent, app(1)])
        s.extras[101] = [el(1, bar(900))]
        s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [el(1, bar(900)), AXElementInfo(axDescription: "Clock", frame: bar(1500))])
        let sc = scanner(s, [entry(1, true)])
        _ = sc.scan()                                  // names App1 as seen hosted
        var s2 = s
        s2.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [AXElementInfo(axDescription: "Clock", frame: bar(1500))])
        var sc2 = sc; sc2.source = s2
        let i = item(sc2.scan(), 1)
        #expect(i.notHostedByAgent && !i.isOnMenuBar && i.controlCenterAllowed == true)
    }

    @Test func anOnBarCorroboratedCandidateKeepsTodaysValues() {
        var s = Src(apps: [agent, app(1)])
        s.extras[101] = [el(1, bar(900))]
        s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [el(1, bar(900)), AXElementInfo(axDescription: "Clock", frame: bar(1500))])
        for allowed in [true, false] {
            let i = item(scanner(s, [entry(1, allowed)]).scan(), 1)
            #expect(i.isOnMenuBar && !i.notHostedByAgent && !i.hiddenInControlCenter && !i.placementUnknown)
            #expect(i.controlCenterAllowed == allowed && i.joinEvidence == .identifier)
        }
    }
}

// MARK: - End to end: scanner -> ObservedOrder -> Reconciler

private let chevronKey = ItemKey.module(name: MenuBarItem.overflowChevronName)
private func key(_ n: Int) -> ItemKey { .status(ownerKey: "ie.test.app\(n)", autosaveName: "id\(n)") }
private func caps(_ key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }

private func resolve(_ s: MenuBarSnapshot) -> [ResolvedItem] {
    s.items.map { it in
        if it.isOverflowChevron { return ResolvedItem(item: it, key: chevronKey, confidence: .exact) }
        let n = Int(it.ownerName.dropFirst(3)) ?? 0
        return ResolvedItem(item: it, key: it.ownerName.hasPrefix("App") ? key(n) : .module(name: it.axDescription), confidence: .exact)
    }
}

@Suite struct ScannerFoldedParkedEndToEndTests {
    /// Apps 1-4 drawn; 5-6 parked off-strip; 7-8 not hosted (seen hosted earlier, absent from this complete read).
    private func scanned(chevron: Bool) -> [ResolvedItem] {
        let apps = (1...8).map(app)
        var s = Src(apps: [agent] + apps)
        for n in 1...4 { s.extras[pid_t(100 + n)] = [el(n, bar(520 + CGFloat(n) * 30))] }
        for n in 5...6 { s.extras[pid_t(100 + n)] = [el(n, parkedRect)] }
        for n in 7...8 { s.extras[pid_t(100 + n)] = [el(n, bar(590 + CGFloat(n - 7) * 30))] }
        let drawn = (1...4).map { el($0, bar(520 + CGFloat($0) * 30)) }
        let seen = (7...8).map { el($0, bar(590 + CGFloat($0 - 7) * 30)) }
        let clock = AXElementInfo(axDescription: "Clock", frame: bar(1500))
        let strip = s.tree.stripFrame
        let entries = (1...8).map { entry($0, true) }
        let sc = scanner(s, entries)
        s.tree = AgentHostedTree(stripFrame: strip, elements: drawn + seen + [clock])
        var first = sc; first.source = s
        _ = first.scan()                                // names 7 and 8 as seen hosted
        s.tree = AgentHostedTree(stripFrame: strip, elements: drawn + [clock] + (chevron ? [chevronEl] : []))
        var second = sc; second.source = s
        return resolve(second.scan())
    }

    @Test func parkedAndNotHostedItemsBecomeFoldedThroughTheRealScanner() {
        let r = scanned(chevron: true)
        for n in 5...8 { #expect(r.first { $0.key == key(n) }?.item.controlCenterAllowed == true) }
        let o = ObservedOrder(resolved: r)
        #expect(o.foldedParked == Set((5...8).map(key)))
        let layout = Layout(visible: (5...8).map(key) + (1...4).map(key))
        let plan = Reconciler().plan(observed: o, layout: layout, capabilities: caps)
        #expect(!plan.actions.contains { if case .show = $0 { true } else { false } })
        for n in 5...8 { #expect(plan.skipped.contains { $0.key == key(n) && $0.reason == Reconciler.foldedParkedSkipReason }) }
    }

    @Test func withoutTheChevronNothingIsFoldedAndShowsArePlanned() {
        let o = ObservedOrder(resolved: scanned(chevron: false))
        #expect(o.foldedParked.isEmpty)
        let layout = Layout(visible: (5...8).map(key) + (1...4).map(key))
        let plan = Reconciler().plan(observed: o, layout: layout, capabilities: caps)
        let shown = Set(plan.actions.compactMap { a -> ItemKey? in if case .show(let x) = a { x } else { nil } })
        #expect(shown == Set((5...8).map(key)))
    }
}
