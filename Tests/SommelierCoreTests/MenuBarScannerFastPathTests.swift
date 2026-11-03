import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

/// Fixture whose behaviour can change between scans (the scanner's `source` is reassigned) and that records calls.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var extras = 0
    private var trees = 0
    func extrasRead() { lock.lock(); extras += 1; lock.unlock() }
    func treeRead() -> Int { lock.lock(); defer { lock.unlock() }; trees += 1; return trees }
    var extrasReads: Int { lock.lock(); defer { lock.unlock() }; return extras }
    var treeReads: Int { lock.lock(); defer { lock.unlock() }; return trees }
}

private struct ScriptedSource: AccessibilitySource {
    var currentPID: pid_t = 1
    var apps: [RunningAppInfo] = []
    var extras: [pid_t: [AXElementInfo]] = [:]
    var delay: [pid_t: TimeInterval] = [:]
    /// Trees returned by successive agent reads; the last one repeats.
    var trees: [AgentHostedTree] = []
    /// Makes agent reads slow (injectable); the scanner's fast-path deadline must not wait for it.
    var treeDelay: TimeInterval = 0
    let calls = Calls()
    func runningApps() -> [RunningAppInfo] { apps }
    func extrasItems(for app: RunningAppInfo) -> [AXElementInfo] { extras[app.pid] ?? [] }
    func readExtras(for app: RunningAppInfo, timeout: Float?) -> ExtrasRead {
        calls.extrasRead()
        if let d = delay[app.pid] { Thread.sleep(forTimeInterval: d) }
        return .items(extrasItems(for: app))
    }
    func agentHostedTree(for agent: RunningAppInfo) -> AgentHostedTree {
        let n = calls.treeRead()
        if treeDelay > 0 { Thread.sleep(forTimeInterval: treeDelay) }
        return trees[min(n, trees.count) - 1]
    }
}

private let agentApp = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
private let strip = CGRect(x: 0, y: 0, width: 2000, height: 30)
private func bar(_ x: CGFloat, w: CGFloat = 24) -> CGRect { CGRect(x: x, y: 3, width: w, height: 24) }
private func tree(_ e: [AXElementInfo], failed: Int = 0, timedOut: [AXElementInfo] = [], unnamed: Int = 0) -> AgentHostedTree {
    AgentHostedTree(stripFrame: strip, elements: e, failedReads: failed, timedOut: timedOut, unnamedTimeouts: unnamed)
}

private let appA = RunningAppInfo(pid: 10, bundleID: "a.b", name: "A")
private let appB = RunningAppInfo(pid: 11, bundleID: "c.d", name: "B")

/// A: id "a1" at 300, B: no id/description (frame-only join) at 200; Clock is agent-only at 900.
private func world(shift: CGFloat = 0, trees: [AgentHostedTree]? = nil) -> ScriptedSource {
    var s = ScriptedSource(apps: [agentApp, appA, appB])
    s.extras[10] = [AXElementInfo(axDescription: "A one", identifier: "a1", frame: bar(300))]
    s.extras[11] = [AXElementInfo(frame: bar(200))]
    s.trees = trees ?? [tree([
        AXElementInfo(axDescription: "A one", identifier: "a1", frame: bar(300 + shift)),
        AXElementInfo(frame: bar(200)),
        AXElementInfo(axDescription: "Clock", identifier: "clock", frame: bar(900)),
    ])]
    return s
}

private func owners(_ s: MenuBarSnapshot) -> [String] { s.onBarLeftToRight.map { $0.ownerName } }

@Test func fastPathAttributesOwnersFromLastFullScanWithoutReadingExtras() {
    let s = world()
    var scanner = MenuBarScanner(source: s)
    let full = scanner.scan()
    #expect(owners(full) == ["B", "A", "Clock"])
    let readsAfterFull = s.calls.extrasReads

    let fast = scanner.scanVisible()
    #expect(s.calls.extrasReads == readsAfterFull)          // no per-app reads in the fast path
    #expect(owners(fast) == owners(full))                    // same owners, same order
    #expect(fast.onBarLeftToRight.map(\.source) == full.onBarLeftToRight.map(\.source))
    #expect(fast.items.allSatisfy { !$0.stale })
}

@Test func fastPathJoinsByIdentifierWhenTheItemMoved() {
    var scanner = MenuBarScanner(source: world())
    _ = scanner.scan()
    // A's item shifted by 40 pt: the identifier still attributes it; frame comes from the hosted tree.
    scanner.source = world(shift: 40)
    let fast = scanner.scanVisible()
    let a = fast.items.first { $0.axIdentifier == "a1" }
    #expect(a?.ownerName == "A")
    #expect(a?.frame.minX == 340)
}

@Test func fastPathWithoutCacheFallsBackToAgentHostedOnly() {
    var scanner = MenuBarScanner(source: world())
    #expect(scanner.isWarm == false)
    let fast = scanner.scanVisible()
    #expect(fast.items.count == 3)
    #expect(fast.items.allSatisfy { $0.source == .agentHostedOnly })
}

@Test func cacheFileMakesAFreshScannerWarm() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let first = MenuBarScanner(source: world(), cacheURL: url)
    let full = first.scan()
    let second = MenuBarScanner(source: world(), cacheURL: url)
    #expect(second.isWarm)
    #expect(owners(second.scanVisible()) == owners(full))
}

@Test func budgetMissKeepsCachedItemsAndFinishesInTime() {
    var s = world()
    var scanner = MenuBarScanner(source: s, extrasBudget: 0.15)
    let first = scanner.scan()
    #expect(first.items.allSatisfy { !$0.stale })

    // Now A answers far too slowly for the budget.
    s.delay[10] = 1.5
    scanner.source = s
    let t0 = Date()
    let second = scanner.scan()
    #expect(Date().timeIntervalSince(t0) < 1.0)
    let a = second.items.first { $0.axIdentifier == "a1" }
    #expect(a != nil)
    #expect(a?.ownerName == "A")                  // attributed from the cached items
    #expect(owners(second) == owners(first))
    #expect(second.onBarLeftToRight.count == first.onBarLeftToRight.count)
}

@Test func budgetMissCachedItemNotInAgentTreeIsMarkedStale() {
    var s = world()
    var scanner = MenuBarScanner(source: s, extrasBudget: 0.15)
    _ = scanner.scan()
    s.delay[10] = 1.5
    // The agent tree no longer lists A's item, so the cached app item is unverified.
    s.trees = [tree([AXElementInfo(frame: bar(200)), AXElementInfo(axDescription: "Clock", identifier: "clock", frame: bar(900))])]
    scanner.source = s
    let a = scanner.scan().items.first { $0.axIdentifier == "a1" }
    #expect(a?.stale == true)
}

private func a1Info() -> AXElementInfo { AXElementInfo(axDescription: "A one", identifier: "a1", frame: bar(300)) }

@Test func timedOutElementIsCarriedForwardAsStale() {
    let full = world().trees[0]
    let s = world(trees: [full])
    var scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    var s2 = s
    s2.trees = [tree(full.elements.filter { $0.identifier != "a1" }, failed: 1, timedOut: [a1Info()])]
    scanner.source = s2
    let snap = scanner.scan()
    let a = snap.items.first { $0.axIdentifier == "a1" }
    #expect(a?.stale == true)
    #expect(a?.staleCount == 1)
    #expect(a?.isOnMenuBar == true)
    #expect(snap.onBarLeftToRight.count == 3)
    #expect(snap.items.filter { $0.stale }.count == 1)
}

@Test func missingWithoutReadErrorIsGoneNotCarried() {
    let full = world().trees[0]
    let s = world(trees: [full])
    var scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    // Another read failed elsewhere (failedReads 1) but nothing timed out for a1: it is simply gone.
    var s2 = s
    s2.extras[10] = []
    s2.trees = [tree(full.elements.filter { $0.identifier != "a1" }, failed: 1)]
    scanner.source = s2
    let snap = scanner.scan()
    #expect(snap.items.contains { $0.axIdentifier == "a1" } == false)
    #expect(snap.items.allSatisfy { !$0.stale })
}

@Test func staleItemDroppedWhenOwnerPidIsGone() {
    let full = world().trees[0]
    let s = world(trees: [full])
    var scanner = MenuBarScanner(source: s)
    _ = scanner.scan()                       // caches that pid 10 (A) owns a1
    var s2 = s
    s2.apps = [agentApp, appB]               // A quit
    s2.extras[10] = nil
    s2.trees = [tree(full.elements.filter { $0.identifier != "a1" }, failed: 1, timedOut: [a1Info()])]
    scanner.source = s2
    #expect(scanner.scan().items.contains { $0.axIdentifier == "a1" } == false)
    // The fast path applies the same rule.
    #expect(scanner.scanVisible().items.contains { $0.axIdentifier == "a1" } == false)
}

@Test func staleItemDroppedAfterThreeConsecutiveStaleScans() {
    let full = world().trees[0]
    let s = world(trees: [full])
    var scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    var s2 = s
    s2.trees = [tree(full.elements.filter { $0.identifier != "a1" }, failed: 1, timedOut: [a1Info()])]
    scanner.source = s2
    for n in 1...3 {
        let a = scanner.scan().items.first { $0.axIdentifier == "a1" }
        #expect(a?.stale == true)
        #expect(a?.staleCount == n)
    }
    let fourth = scanner.scan()
    #expect(fourth.items.contains { $0.axIdentifier == "a1" && $0.stale } == false)
}

@Test func staleItemsAreNeverPersisted() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let ghost = AXElementInfo(axDescription: "Ghost", identifier: "ghost.unique", frame: bar(500))
    let full = tree(world().trees[0].elements + [ghost])
    var scanner = MenuBarScanner(source: world(trees: [full]), cacheURL: url)
    _ = scanner.scan()
    #expect(try String(contentsOf: url, encoding: .utf8).contains("ghost.unique"))   // fresh items are persisted
    var s2 = world(trees: [tree(world().trees[0].elements, failed: 1, timedOut: [ghost])])
    s2.trees = [tree(world().trees[0].elements, failed: 1, timedOut: [ghost])]
    scanner.source = s2
    let snap = scanner.scanVisible()
    #expect(snap.items.contains { $0.axIdentifier == "ghost.unique" && $0.stale })
    #expect(try String(contentsOf: url, encoding: .utf8).contains("ghost.unique") == false)
    // A fresh process loading the file does not resurrect it either.
    let reborn = MenuBarScanner(source: world(), cacheURL: url)
    #expect(reborn.scanVisible().items.contains { $0.axIdentifier == "ghost.unique" } == false)
}

@Test func fastPathReturnsByDeadlineWithStaleItemsWhenAgentIsSlow() {
    let s = world()
    var scanner = MenuBarScanner(source: s)
    scanner.fastDeadline = 0.2
    let full = scanner.scan()
    var slow = s
    slow.treeDelay = 3                        // the agent read would take 3 s
    scanner.source = slow
    let t0 = Date()
    let fast = scanner.scanVisible()
    let elapsed = Date().timeIntervalSince(t0)
    #expect(elapsed < 0.6)
    #expect(fast.onBarLeftToRight.count == full.onBarLeftToRight.count)
    #expect(fast.items.filter { $0.isOnMenuBar }.allSatisfy { $0.stale })
    #expect(owners(fast) == owners(full))
}

@Test func transientlyMissingItemIsConfirmedByReReadAndNotDropped() {
    let full = world().trees[0]
    let gap = tree(full.elements.filter { $0.identifier != "clock" })   // read succeeded but one item is absent
    let s = world(trees: [full])
    var scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    var s2 = s
    s2.trees = [gap, full]                      // first read has the gap, the confirming re-read is complete
    scanner.source = s2
    let snap = scanner.scan()
    #expect(s2.calls.treeReads == 2)
    #expect(snap.items.contains { $0.axIdentifier == "clock" })
    #expect(snap.onBarLeftToRight.count == 3)
    #expect(snap.items.allSatisfy { !$0.stale })
}

@Test func axElementCastRejectsNonAXValues() {
    #expect(axElement(from: "not an element" as NSString) == nil)
    #expect(axElement(from: nil) == nil)
    #expect(axValue(from: NSNumber(value: 3)) == nil)
    #expect(axElement(from: AXUIElementCreateSystemWide()) != nil)
}

@Test func unnamedTimeoutCarriesPreviouslyVisibleItemsBoundedly() {
    let full = world().trees[0]
    let s = world(trees: [full])
    var scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    var s2 = s
    // A group timed out and the source (fresh process) cannot say which items it held.
    s2.trees = [tree(full.elements.filter { $0.identifier != "a1" }, failed: 1, unnamed: 1)]
    scanner.source = s2
    let first = scanner.scanVisible()
    #expect(first.items.first { $0.axIdentifier == "a1" }?.stale == true)
    #expect(s2.calls.treeReads == 2)                      // scan + this one: no confirming re-read (absence explained)
    _ = scanner.scanVisible(); _ = scanner.scanVisible()
    #expect(scanner.scanVisible().items.contains { $0.axIdentifier == "a1" } == false)   // 4th scan: believed gone
}

@Test func fastPathKeepsAppOnlyItemsTheAgentTreeNeverShows() {
    var s = world()
    let c = RunningAppInfo(pid: 12, bundleID: "e.f", name: "C")
    s.apps.append(c)
    s.extras[12] = [AXElementInfo(axDescription: "C only", identifier: "c1", frame: bar(1000))]   // not in the agent tree
    var scanner = MenuBarScanner(source: s)
    let full = scanner.scan()
    scanner.source = s
    let fast = scanner.scanVisible()
    #expect(owners(fast) == owners(full))
    #expect(fast.items.first { $0.axIdentifier == "c1" }?.stale == false)
}
