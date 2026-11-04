import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

/// Scanner-level completeness levels (gdu.51): stale iStat items alone do not make a read incomplete for membership.
private struct Src: AccessibilitySource {
    var currentPID: pid_t = 1
    var apps: [RunningAppInfo] = []
    var extras: [pid_t: [AXElementInfo]] = [:]
    var failing: Set<pid_t> = []
    var trees: [AgentHostedTree] = []
    let n = Counter()
    let notes = Notes()
    final class Notes: @unchecked Sendable { var v: [Bool] = []; let l = NSLock(); func add(_ b: Bool) { l.lock(); v.append(b); l.unlock() } }
    func noteUnresolvedGroups(selfPositioning: Bool) { notes.add(selfPositioning) }
    final class Counter: @unchecked Sendable { var v = 0; let l = NSLock(); func next() -> Int { l.lock(); defer { l.unlock() }; v += 1; return v } }
    func runningApps() -> [RunningAppInfo] { apps }
    func extrasItems(for app: RunningAppInfo) -> [AXElementInfo] { extras[app.pid] ?? [] }
    func readExtras(for app: RunningAppInfo, timeout: Float?) -> ExtrasRead {
        failing.contains(app.pid) ? .failed("timed out") : .items(extrasItems(for: app))
    }
    func agentHostedTree(for agent: RunningAppInfo) -> AgentHostedTree { trees[min(n.next(), trees.count) - 1] }
    func agentHostedTree(for agent: RunningAppInfo, retry: Bool) -> AgentHostedTree { agentHostedTree(for: agent) }
}

private let agent = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
private let istatApp = RunningAppInfo(pid: 20, bundleID: "com.bjango.istatmenus.status", name: "iStat Menus Menubar")
private let dummy = RunningAppInfo(pid: 10, bundleID: "ie.test.dummy", name: "Dummy")
private let other = RunningAppInfo(pid: 11, bundleID: "ie.test.other", name: "Other")
private let strip = CGRect(x: 0, y: 0, width: 2000, height: 30)
private func bar(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 3, width: 24, height: 24) }
private let cpu = AXElementInfo(axDescription: "CPU", identifier: "com.bjango.istatmenus.cpu", frame: bar(500))
private let mem = AXElementInfo(axDescription: "Memory", identifier: "com.bjango.istatmenus.memory", frame: bar(540))
private let dummyEl = AXElementInfo(axDescription: "Dummy A", identifier: "Dummy-A", frame: bar(300))
private let otherEl = AXElementInfo(axDescription: "Other", identifier: "other-1", frame: bar(350))

private func stale(_ e: AXElementInfo) -> AXElementInfo { var s = e; s.stale = true; return s }
private func tree(_ e: [AXElementInfo], failed: Int = 0, timedOut: [AXElementInfo] = [], unnamed: Int = 0, top: Int = 0) -> AgentHostedTree {
    AgentHostedTree(stripFrame: strip, elements: e, failedReads: failed, timedOut: timedOut, unnamedTimeouts: unnamed, topFailures: top)
}

private func source(_ trees: [AgentHostedTree], failing: Set<pid_t> = []) -> Src {
    var s = Src(apps: [agent, dummy, other, istatApp])
    s.extras[10] = [dummyEl]; s.extras[11] = [otherEl]; s.extras[20] = [cpu, mem]
    s.trees = trees; s.failing = failing
    return s
}

private let full = tree([dummyEl, otherEl, cpu, mem])

@Test func staleSelfPositioningOnlyIsCompleteExceptSelfPositioning() {
    // Named timeouts (the live source remembers what the failed groups held).
    let s = source([full, tree([dummyEl, otherEl], failed: 2, timedOut: [stale(cpu), stale(mem)])])
    let scanner = MenuBarScanner(source: s)
    #expect(scanner.scan().completeness == .complete)
    let r = scanner.scan()
    #expect(r.completeness == .completeExceptSelfPositioning)
    #expect(r.hostedReadComplete == false)
    #expect(r.items.filter(\.stale).count == 2)
}

@Test func unnamedSelfPositioningTimeoutsAreAttributedFromThePreviousTree() {
    let s = source([full, tree([dummyEl, otherEl], failed: 2, unnamed: 2)])
    let scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    #expect(scanner.scan().completeness == .completeExceptSelfPositioning)
}

@Test func staleThirdPartyItemIsIncomplete() {
    let s = source([full, tree([dummyEl, cpu, mem], failed: 1, timedOut: [stale(otherEl)])])
    let scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    #expect(scanner.scan().completeness == .incomplete)
}

@Test func selfPositioningPlusThirdPartyFailuresIsIncomplete() {
    // 3 failed groups, but only the 2 iStat items are known: one failure is unexplained.
    let s = source([full, tree([dummyEl, otherEl], failed: 3, timedOut: [stale(cpu), stale(mem)], unnamed: 1)])
    let scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    #expect(scanner.scan().completeness == .incomplete)
}

@Test func topLevelFailureIsNeverAttributed() {
    let s = source([full, tree([dummyEl, otherEl], failed: 2, timedOut: [stale(cpu), stale(mem)], top: 1)])
    let scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    #expect(scanner.scan().completeness == .incomplete)
}

@Test func thirdPartyAppSideStaleItemKeepsTheReadIncomplete() {
    // Other's extras read fails and its cached item is carried stale while iStat's groups time out.
    let s1 = source([full])
    let scanner = MenuBarScanner(source: s1)
    _ = scanner.scan()
    let s2 = source([tree([dummyEl, otherEl], failed: 2, timedOut: [stale(cpu), stale(mem)])], failing: [11])
    var sc = scanner; sc.source = s2
    #expect(sc.scan().completeness == .incomplete)
}

@Test func hiddenNamedUnitIsJudgedOnAnExceptSelfPositioningReadButNotOnAnIncompleteOne() {
    // Dummy-A's element vanished (hide) while iStat's groups time out: its absence is still proof (every failure is iStat's).
    let s = source([full, tree([otherEl], failed: 2, timedOut: [stale(cpu), stale(mem)])])
    let scanner = MenuBarScanner(source: s)
    _ = scanner.scan()                     // names Dummy-A as seen hosted
    let r = scanner.scan()
    #expect(r.completeness == .completeExceptSelfPositioning)
    let d = r.items.first { $0.axIdentifier == "Dummy-A" }
    #expect(d?.notHostedByAgent == true && d?.isOnMenuBar == false)
    // Same absence on a read incomplete for another reason proves nothing (gdu.38 rule unchanged).
    let s3 = source([full, tree([cpu, mem], failed: 1, timedOut: [stale(otherEl)])])
    let sc3 = MenuBarScanner(source: s3)
    _ = sc3.scan()
    let r3 = sc3.scan()
    #expect(r3.completeness == .incomplete)     // a third-party group timed out
    #expect(r3.items.first { $0.axIdentifier == "Dummy-A" }?.notHostedByAgent == false)
}

@Test func selfPositioningOwnersOwnItemsAreNeverJudgedNotHosted() {
    let s = source([full, tree([dummyEl, otherEl], failed: 2, timedOut: [stale(cpu), stale(mem)])])
    let scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    let r = scanner.scan()
    #expect(r.items.filter { $0.ownerBundleID == istatApp.bundleID }.allSatisfy { !$0.notHostedByAgent })
}

// MARK: - gdu.51 corrective: attribution by identity

@Test func unnamedTimeoutOfANonSelfPositioningGroupIsNotCoveredByIStatItems() {
    // scan 2: one named iStat timeout (cpu) plus one UNNAMED timeout; the only missing previously-hosted item is Other's.
    let s = source([full, tree([dummyEl, mem], failed: 2, timedOut: [stale(cpu)], unnamed: 1)], failing: [20])
    let scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    let r = scanner.scan()
    #expect(r.completeness == .incomplete)
    let o = r.items.first { $0.axIdentifier == "other-1" }
    #expect(o?.notHostedByAgent != true)
    #expect(o?.isOnMenuBar == true)
}

@Test func unnamedTimeoutsCoveredByMissingIStatElementsStayTheMiddleLevel() {
    let s = source([full, tree([dummyEl, otherEl], failed: 2, unnamed: 2)])
    let scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    #expect(scanner.scan().completeness == .completeExceptSelfPositioning)
}

@Test func topLevelFailureInTheConfirmReReadIsKept() {
    // Read 1 lacks Dummy-A without an error (triggers the confirm re-read); the re-read has a top-level failure and timed-out iStat groups.
    let s = source([full, tree([otherEl, cpu, mem]), tree([otherEl], failed: 3, timedOut: [stale(cpu), stale(mem)], top: 1)])
    let scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    let r = scanner.scan()
    #expect(r.completeness == .incomplete)
}

@Test func onlyAttributedGroupsAreCapped() {
    let cache = AXElementCache()
    let iStatGroup = AXUIElementCreateApplication(1), slowOther = AXUIElementCreateApplication(2)
    cache.setSlow([iStatGroup, slowOther])
    #expect(!cache.isCapped(iStatGroup) && !cache.isCapped(slowOther))   // not attributed: both keep the full retry round
    cache.noteUnresolvedAttribution(selfPositioning: true)
    #expect(cache.isCapped(iStatGroup))
    cache.setSlow([slowOther])                                           // iStat's group resolved
    #expect(!cache.isCapped(iStatGroup))
    cache.noteUnresolvedAttribution(selfPositioning: false)
    #expect(!cache.isCapped(slowOther))
}

// MARK: - gdu.51 diagnosability: reason strings

private func reason(_ second: AgentHostedTree, failing: Set<pid_t> = [], log: (@Sendable (String) -> Void)? = nil) -> MenuBarSnapshot {
    var scanner = MenuBarScanner(source: source([full]), log: log ?? { _ in })
    _ = scanner.scan()
    scanner.source = source([second], failing: failing)
    return scanner.scan()
}

@Test func reasonTopLevelFailure() {
    let r = reason(tree([dummyEl, otherEl], failed: 3, timedOut: [stale(cpu), stale(mem)], top: 1))
    #expect(r.completeness == .incomplete && r.completenessReason == "top-level failure")
}

@Test func reasonNamedTimeoutNotSelfPositioning() {
    let r = reason(tree([dummyEl, cpu, mem], failed: 1, timedOut: [stale(otherEl)]))
    #expect(r.completenessReason == "named timeout not self-positioning (\(otherEl.identityKey))")
}

@Test func reasonUnnamedTimeoutsNotCovered() {
    let r = reason(tree([dummyEl, otherEl], failed: 3, timedOut: [stale(cpu), stale(mem)], unnamed: 1))
    #expect(r.completenessReason == "1 unnamed timeouts, only 0 self-positioning groups absent")
}

@Test func reasonNonSelfPositioningElementMissing() {
    let r = reason(tree([dummyEl], failed: 1, unnamed: 1))
    #expect(r.completenessReason == "non-self-positioning element missing (\(otherEl.identityKey))")
}

@Test func reasonStaleAppSideItem() {
    let r = reason(tree([dummyEl, otherEl], failed: 2, timedOut: [stale(cpu), stale(mem)]), failing: [11])
    #expect(r.completenessReason == "stale app-side item of ie.test.other")
}

@Test func noReasonWhenCompleteOrMiddleLevel() {
    #expect(reason(full).completenessReason == nil)
    let m = reason(tree([dummyEl, otherEl], failed: 2, timedOut: [stale(cpu), stale(mem)]))
    #expect(m.completeness == .completeExceptSelfPositioning && m.completenessReason == nil)
}

private final class Lines: @unchecked Sendable { let l = NSLock(); var v: [String] = []; func add(_ s: String) { l.lock(); v.append(s); l.unlock() } }

@Test func incompleteReasonIsLoggedOncePerTenSeconds() {
    let lines = Lines()
    let t = tree([dummyEl, otherEl], failed: 3, timedOut: [stale(cpu), stale(mem)], unnamed: 1)
    let scanner = MenuBarScanner(source: source([full, t, t, t]), log: { lines.add($0) })
    for _ in 0..<4 { _ = scanner.scan() }
    #expect(lines.v.filter { $0.hasPrefix("incomplete: ") } == ["incomplete: 1 unnamed timeouts, only 0 self-positioning groups absent"])
}

@Test func levelDisplayNamesForJson() {
    #expect(ReadCompleteness.complete.displayName == "complete")
    #expect(ReadCompleteness.completeExceptSelfPositioning.displayName == "exceptSelfPositioning")
    #expect(ReadCompleteness.incomplete.displayName == "incomplete")
}

// MARK: - gdu.53: long iStat streaks keep their attribution

private let streakScan = tree([dummyEl, otherEl], failed: 2, unnamed: 2)

@Test func tenConsecutiveIStatOnlyUnnamedTimeoutScansStayCompleteExceptSelfPositioning() {
    let s = source([full] + Array(repeating: streakScan, count: 10))
    let scanner = MenuBarScanner(source: s)
    #expect(scanner.scan().completeness == .complete)
    for i in 1...10 { #expect(scanner.scan().completeness == .completeExceptSelfPositioning, "scan \(i)") }
    #expect(s.notes.v.count == 11 && s.notes.v.dropFirst().allSatisfy { $0 })      // groups stay attributed (capped) for the whole streak
}

@Test func nonIStatUnnamedTimeoutInTheMiddleOfAStreakIsIncompleteOnlyForThatScan() {
    let bad = tree([dummyEl, otherEl], failed: 3, unnamed: 3)     // one more unnamed timeout than iStat groups
    let s = source([full] + Array(repeating: streakScan, count: 5) + [bad] + Array(repeating: streakScan, count: 2))
    let scanner = MenuBarScanner(source: s)
    _ = scanner.scan()
    for _ in 1...5 { #expect(scanner.scan().completeness == .completeExceptSelfPositioning) }
    #expect(scanner.scan().completeness == .incomplete)
    #expect(scanner.scan().completeness == .completeExceptSelfPositioning)
}

@Test func vanishedThirdPartyElementDuringALongStreakIsIncomplete() {
    let s = source([full] + Array(repeating: streakScan, count: 4)
                   + [tree([dummyEl], failed: 2, unnamed: 2)])      // Other's element vanished while iStat times out
    let scanner = MenuBarScanner(source: s)
    for _ in 0..<5 { _ = scanner.scan() }
    #expect(scanner.scan().completeness == .incomplete)
}

@Test func iStatQuittingPrunesTheRecord() {
    var s = source([full] + Array(repeating: streakScan, count: 5)
                   + [tree([dummyEl, otherEl]), tree([dummyEl, otherEl], failed: 1, unnamed: 1)])
    let scanner = MenuBarScanner(source: s)
    for _ in 0..<6 { _ = scanner.scan() }
    s.apps = [agent, dummy, other]                                      // iStat quit
    var sc = scanner; sc.source = s
    #expect(sc.scan().completeness == .complete)
    #expect(sc.scan().completeness == .incomplete)                      // an unnamed timeout can no longer be iStat's
}

@Test func freshProcessAttributesUnnamedIStatTimeoutsOnItsFirstScan() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-cache-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let first = MenuBarScanner(source: source([full] + Array(repeating: streakScan, count: 6)), cacheURL: url)
    for _ in 0..<7 { _ = first.scan() }                                 // streak longer than the carry-over: lastHosted has no iStat
    let reborn = MenuBarScanner(source: source([streakScan]), cacheURL: url)
    #expect(reborn.scan().completeness == .completeExceptSelfPositioning)
}

@Test func cappedGroupsStayCappedForTheStreak() {
    let cache = AXElementCache()
    let g = AXUIElementCreateApplication(1), other = AXUIElementCreateApplication(2)
    cache.setSlow([g]); cache.noteUnresolvedAttribution(selfPositioning: true)
    for _ in 0..<10 { cache.setSlow([g]); cache.noteUnresolvedAttribution(selfPositioning: true); #expect(cache.isCapped(g)) }
    cache.setSlow([g, other]); cache.noteUnresolvedAttribution(selfPositioning: false)   // unattributed extra failure: nobody capped
    #expect(!cache.isCapped(g) && !cache.isCapped(other))
    cache.setSlow([g]); cache.noteUnresolvedAttribution(selfPositioning: true)           // next streak read: capped again
    #expect(cache.isCapped(g))
    cache.setSlow([other]); #expect(!cache.isCapped(g))                 // resolved: leaves the set
}
