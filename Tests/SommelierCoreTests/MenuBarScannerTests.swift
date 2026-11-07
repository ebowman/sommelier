import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

struct FixtureSource: AccessibilitySource {
    var currentPID: pid_t = 1
    var apps: [RunningAppInfo] = []
    var extras: [pid_t: [AXElementInfo]] = [:]
    /// Pids whose reads fail; `succeedOnRetry` makes them succeed when a longer timeout is passed.
    var failing: Set<pid_t> = []
    var succeedOnRetry = false
    var tree = AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [])
    func runningApps() -> [RunningAppInfo] { apps }
    func extrasItems(for app: RunningAppInfo) -> [AXElementInfo] { extras[app.pid] ?? [] }
    func readExtras(for app: RunningAppInfo, timeout: Float?) -> ExtrasRead {
        if failing.contains(app.pid) && !(succeedOnRetry && timeout != nil) { return .failed("fixture timeout") }
        return .items(extrasItems(for: app))
    }
    func agentHostedTree(for agent: RunningAppInfo) -> AgentHostedTree { tree }
}

private let agent = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
private func bar(_ x: CGFloat, w: CGFloat = 24) -> CGRect { CGRect(x: x, y: 3, width: w, height: 24) }
private func parkedFrame() -> CGRect { CGRect(x: 2, y: 1204, width: 24, height: 24) }

@Test func joinByIdentifier() {
    let a = RunningAppInfo(pid: 10, bundleID: "a.b", name: "A")
    var s = FixtureSource(apps: [agent, a])
    s.extras[10] = [AXElementInfo(axDescription: "old", identifier: "id.one", frame: bar(100))]
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [
        AXElementInfo(axDescription: "different", identifier: "id.one", frame: bar(500)),
    ])
    let snap = MenuBarScanner(source: s).scan()
    #expect(snap.items.count == 1)
    #expect(snap.items[0].source == .appExtras)
    #expect(snap.items[0].ownerName == "A")
}

@Test func joinByFrameWhenIdentifierEmpty() {
    let a = RunningAppInfo(pid: 10, bundleID: "a.b", name: "A")
    var s = FixtureSource(apps: [agent, a])
    s.extras[10] = [AXElementInfo(frame: bar(100))]
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [AXElementInfo(frame: bar(102))])
    let snap = MenuBarScanner(source: s).scan()
    #expect(snap.items.count == 1)
    #expect(snap.items[0].source == .appExtras)
}

@Test func unmatchedHostedBecomesAgentOnly() {
    var s = FixtureSource(apps: [agent])
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [
        AXElementInfo(axDescription: "Clock", frame: bar(900)),
        AXElementInfo(frame: bar(800)),
    ])
    let snap = MenuBarScanner(source: s).scan()
    #expect(snap.items.map(\.ownerName) == ["System item", "Clock"])
    #expect(snap.items.allSatisfy { $0.source == .agentHostedOnly && $0.ownerPID == 99 })
}

@Test func multipleItemsPerAppKeepOrder() {
    let a = RunningAppInfo(pid: 10, bundleID: "a.b", name: "A")
    let b = RunningAppInfo(pid: 11, bundleID: "c.d", name: "B")
    var s = FixtureSource(apps: [agent, a, b])
    s.extras[10] = [AXElementInfo(axDescription: "A1", identifier: "a1", frame: bar(300)),
                    AXElementInfo(axDescription: "A2", identifier: "a2", frame: bar(200))]
    s.extras[11] = [AXElementInfo(axDescription: "B1", identifier: "b1", frame: bar(250))]
    let snap = MenuBarScanner(source: s).scan()
    #expect(snap.onBarLeftToRight.map(\.axDescription) == ["A2", "B1", "A1"])
    // Equal x keeps discovery order.
    s.extras[10] = [AXElementInfo(axDescription: "A1", frame: bar(200)), AXElementInfo(axDescription: "A2", frame: bar(200))]
    s.extras[11] = []
    #expect(MenuBarScanner(source: s).scan().onBarLeftToRight.map(\.axDescription) == ["A1", "A2"])
}

@Test func parkedClassification() {
    let a = RunningAppInfo(pid: 10, bundleID: "a.b", name: "A")
    var s = FixtureSource(apps: [agent, a])
    s.extras[10] = [AXElementInfo(axDescription: "off", frame: parkedFrame()),
                    AXElementInfo(axDescription: "zero", frame: CGRect(x: 50, y: 3, width: 0, height: 0)),
                    AXElementInfo(axDescription: "on", frame: bar(60))]
    let snap = MenuBarScanner(source: s).scan()
    #expect(snap.onBarLeftToRight.map(\.axDescription) == ["on"])
    #expect(snap.parked.map(\.axDescription) == ["off", "zero"])
}

@Test func fallbackStripWhenNoAgentWindow() {
    let a = RunningAppInfo(pid: 10, bundleID: "a.b", name: "A")
    var s = FixtureSource(apps: [a])
    s.extras[10] = [AXElementInfo(axDescription: "on", frame: bar(60)),
                    AXElementInfo(axDescription: "off", frame: parkedFrame())]
    let snap = MenuBarScanner(source: s).scan()
    #expect(snap.onBarLeftToRight.map(\.axDescription) == ["on"])
    #expect(snap.parked.map(\.axDescription) == ["off"])
}

@Test func selfExclusion() {
    let me = RunningAppInfo(pid: 1, bundleID: "ie.boboco.sommelier", name: "Me")
    let a = RunningAppInfo(pid: 10, bundleID: "a.b", name: "A")
    var s = FixtureSource(currentPID: 1, apps: [agent, me, a])
    s.extras[1] = [AXElementInfo(frame: bar(10))]
    s.extras[10] = [AXElementInfo(frame: bar(40))]
    #expect(MenuBarScanner(source: s).scan().items.map(\.ownerName) == ["A"])
    #expect(MenuBarScanner(source: s, includeSelf: true).scan().items.map(\.ownerName) == ["Me", "A"])
}

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

private func istatTree() -> AgentHostedTree {
    AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [
        AXElementInfo(axDescription: "Clock", identifier: "com.apple.menuextra.clock", frame: bar(900)),
        AXElementInfo(axDescription: "iStat Weather", identifier: "com.bjango.istatmenus.weather", frame: bar(300)),
        AXElementInfo(axDescription: "iStat CPU", identifier: "com.bjango.istatmenus.cpu", frame: bar(400)),
    ])
}

@Test func appReadTimeoutStillYieldsFullOnBarListWithPrefixAttribution() {
    let istat = RunningAppInfo(pid: 20, bundleID: "com.bjango.istatmenus.status", name: "iStat Menus Menubar")
    let istatMain = RunningAppInfo(pid: 21, bundleID: "com.bjango.istatmenus", name: "iStat Menus")
    var s = FixtureSource(apps: [agent, istatMain, istat])
    s.failing = [20]
    s.tree = istatTree()
    let logs = LogBox()
    let snap = MenuBarScanner(source: s, log: { logs.add($0) }).scan()
    #expect(snap.onBarLeftToRight.map(\.axDescription) == ["iStat Weather", "iStat CPU", "Clock"])
    let owners = snap.onBarLeftToRight.map(\.ownerBundleID)
    #expect(owners == ["com.bjango.istatmenus.status", "com.bjango.istatmenus.status", menuBarAgentBundleID])
    #expect(snap.onBarLeftToRight[2].source == .agentHostedOnly)
    #expect(logs.all.contains { $0.contains("iStat Menus Menubar") })
}

@Test func failedReadRetriedWithLongerTimeout() {
    let istat = RunningAppInfo(pid: 20, bundleID: "com.bjango.istatmenus.status", name: "iStat")
    var s = FixtureSource(apps: [agent, istat])
    s.failing = [20]; s.succeedOnRetry = true
    s.extras[20] = [AXElementInfo(axDescription: "iStat Weather", identifier: "com.bjango.istatmenus.weather", frame: bar(300))]
    s.tree = istatTree()
    let snap = MenuBarScanner(source: s).scan()
    // Weather joins the retried app item by identifier (one item); CPU has no app item and the app
    // no longer counts as failed, so it stays agent-hosted-only.
    #expect(snap.items.filter { $0.axDescription == "iStat Weather" }.count == 1)
    #expect(snap.items.first { $0.axDescription == "iStat Weather" }?.ownerBundleID == "com.bjango.istatmenus.status")
    #expect(snap.items.first { $0.axDescription == "iStat CPU" }?.source == .agentHostedOnly)
}

// gdu.29: the frontmost app's main menu (AXMenuBarItem without AXMenuExtra, 0x0) is mirrored into the agent tree.
private func mainMenu() -> [AXElementInfo] {
    let z = CGRect(x: 0, y: 30, width: 0, height: 0)
    return [AXElementInfo(title: "Apple", frame: z, isMainMenuEntry: true),
            AXElementInfo(title: "iStat Menus Menubar", identifier: "_NS:433", frame: z, isMainMenuEntry: true),
            AXElementInfo(title: "File", identifier: "_NS:450", frame: z, isMainMenuEntry: true),
            AXElementInfo(title: "Help", identifier: "_NS:541", frame: z, isMainMenuEntry: true)]
}

private func mainMenuFixture(withMenu: Bool, timedOutMenu: Bool = false) -> FixtureSource {
    let a = RunningAppInfo(pid: 10, bundleID: "a.b", name: "A")
    var s = FixtureSource(apps: [agent, a])
    s.extras[10] = [AXElementInfo(axDescription: "off", frame: parkedFrame()),
                    AXElementInfo(axDescription: "zero", frame: CGRect(x: 50, y: 3, width: 0, height: 0)),
                    AXElementInfo(axDescription: "on", identifier: "on.id", frame: bar(60))]
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [
        AXElementInfo(axDescription: "on", identifier: "on.id", frame: bar(60)),
        AXElementInfo(axDescription: "Clock", frame: bar(900)),
        // A genuine hosted item that is momentarily 0 wide but is NOT a main-menu entry: unchanged by the filter.
        AXElementInfo(axDescription: "Drawing", frame: CGRect(x: 700, y: 3, width: 0, height: 24)),
    ] + (withMenu ? mainMenu() : []),
        failedReads: timedOutMenu ? 1 : 0, timedOut: timedOutMenu ? mainMenu().map { var m = $0; m.stale = true; return m } : [])
    return s
}

@Test func mainMenuEntriesAreDroppedGenuineItemsKept() {
    let without = MenuBarScanner(source: mainMenuFixture(withMenu: false)).scan()
    let with = MenuBarScanner(source: mainMenuFixture(withMenu: true)).scan()
    #expect(with.items.map(\.axDescription) == without.items.map(\.axDescription))
    #expect(with.items.map(\.title).allSatisfy { !["Apple", "File", "Help", "iStat Menus Menubar"].contains($0) })
    #expect(with.items.filter { $0.ownerBundleID == menuBarAgentBundleID && $0.axIdentifier.hasPrefix("_NS:") }.isEmpty)
    #expect(with.parked.map(\.axDescription) == without.parked.map(\.axDescription))
    // genuine parked (nonzero width, x 0..3, y ~1204) and the zero-width genuine items are exactly as before
    #expect(with.parked.map(\.axDescription).contains("off"))
    #expect(with.items.map(\.axDescription).contains("Drawing"))
}

@Test func timedOutMainMenuGroupIsNotAFailure() {
    let t = MenuBarScanner.droppingMainMenu(mainMenuFixture(withMenu: true, timedOutMenu: true).tree)
    #expect(t.timedOut.isEmpty && t.failedReads == 0)
    #expect(t.elements.count == 3)
    let snap = MenuBarScanner(source: mainMenuFixture(withMenu: false, timedOutMenu: true)).scan()
    #expect(snap.items.allSatisfy { $0.axIdentifier != "_NS:450" })
}

@Test func oldScanCacheMainMenuRecordsAreIgnoredOnLoad() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gdu29-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let z = CGRect(x: 0, y: 30, width: 0, height: 0)
    let writer = ScanState(url: url)
    writer.lastHosted = [AXElementInfo(title: "File", identifier: "_NS:450", frame: z),
                         AXElementInfo(title: "Apple", frame: z),
                         AXElementInfo(axDescription: "Clock", identifier: "com.apple.menuextra.clock", frame: bar(900))]
    writer.save()
    let reader = ScanState(url: url)
    reader.loadIfNeeded()
    #expect(reader.lastHosted.map(\.axDescription) == ["Clock"])
}

// MARK: - gdu.28: join evidence

@Test func frameJoinIsCorroboratedOnlyWhenMutualAndExclusive() {
    let a = RunningAppInfo(pid: 10, bundleID: "a.b", name: "A"), b = RunningAppInfo(pid: 11, bundleID: "c.d", name: "B")
    var s = FixtureSource(apps: [agent, a, b])
    // Well separated: unique pairs.
    s.extras[10] = [AXElementInfo(frame: bar(100))]
    s.extras[11] = [AXElementInfo(frame: bar(200))]
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [AXElementInfo(frame: bar(101)), AXElementInfo(frame: bar(201))])
    #expect(MenuBarScanner(source: s).scan().items.map(\.joinEvidence) == [.frameUnique, .frameUnique])
    // B's app-side frame lags and overlaps A's hosted element too: neither pairing can be trusted.
    s.extras[11] = [AXElementInfo(frame: bar(110))]
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [AXElementInfo(frame: bar(101)), AXElementInfo(frame: bar(300))])   // 1 pt off, outside the pile: only the gdu.28 rule (gdu.85); 4 pt variant below
    let amb = MenuBarScanner(source: s).scan().items
    #expect(amb.allSatisfy { $0.joinEvidence != .frameUnique })
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [AXElementInfo(frame: bar(104)), AXElementInfo(frame: bar(300))])
    #expect(MenuBarScanner(source: s).scan().items.allSatisfy { $0.joinEvidence != .frameUnique })
    // A width disagreement over 2 pt is not corroboration either.
    s.extras[10] = [AXElementInfo(frame: bar(100, w: 24))]; s.extras[11] = []
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [AXElementInfo(frame: bar(100, w: 40))])
    #expect(MenuBarScanner(source: s).scan().items.first?.joinEvidence == .frameAmbiguous)
}

@Test func identifierAndUniqueDescriptionJoinsAreCorroboratedDuplicateDescriptionIsNot() {
    let a = RunningAppInfo(pid: 10, bundleID: "a.b", name: "A"), b = RunningAppInfo(pid: 11, bundleID: "c.d", name: "B")
    var s = FixtureSource(apps: [agent, a, b])
    s.extras[10] = [AXElementInfo(axDescription: "Solo", frame: bar(100)), AXElementInfo(identifier: "id.x", frame: bar(150))]
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [AXElementInfo(axDescription: "Solo", frame: bar(500)), AXElementInfo(identifier: "id.x", frame: bar(550))])
    let r = MenuBarScanner(source: s).scan().items
    #expect(Set(r.map(\.joinEvidence)) == [.description, .identifier])
    s.extras[10] = [AXElementInfo(axDescription: "Twin", frame: bar(100))]
    s.extras[11] = [AXElementInfo(axDescription: "Twin", frame: bar(200))]
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [AXElementInfo(axDescription: "Twin", frame: bar(100)), AXElementInfo(axDescription: "Twin", frame: bar(200))])
    #expect(MenuBarScanner(source: s).scan().items.allSatisfy { $0.joinEvidence == .frameAmbiguous })
}

// gdu.28 corrective: system overflow (gdu.45) stacks several hosted elements on one identical frame.
@Test func stackedIdenticalHostedFramesAreAmbiguousNeverUnique() {
    let a = RunningAppInfo(pid: 10, bundleID: "a.b", name: "A")
    var s = FixtureSource(apps: [agent, a])
    s.extras[10] = [AXElementInfo(frame: bar(800))]
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [
        AXElementInfo(title: "t1", frame: bar(800)), AXElementInfo(title: "t2", frame: bar(800)), AXElementInfo(title: "t3", frame: bar(800)),   // distinct items (fully identical ones are deduped as group+button)
    ])
    let items = MenuBarScanner(source: s).scan().items
    let owned = items.filter { $0.source == .appExtras }
    #expect(owned.count == 1)
    #expect(owned[0].joinEvidence == .frameAmbiguous)
    #expect(!items.contains { $0.joinEvidence == .frameUnique })
}

// MARK: - 9o9.10: corroboration by elimination / title (live 2026-11-07 fixture: Corsair ControlCenter + VPN Switch beside iStat Weather)

/// Numbers from the live `mbprobe list --json --debug` capture. The iStat Weather element (identifier-joined, x 1136 w41) overlaps
/// both identifier-less neighbours, so the mutual-and-exclusive frame rule can never call either of them unique: root cause of the
/// `frameAmbiguous` verdicts (MenuBarScanner.joinEvidence: `hostedHits`/`ownerHits` count the identifier-claimed neighbour).
private func vpnFixture(corsairW: CGFloat = 24, extraCandidate: Bool = false, hostedTitle: String = "") -> FixtureSource {
    let istat = RunningAppInfo(pid: 10, bundleID: "com.bjango.istatmenus.status", name: "iStat")
    let corsair = RunningAppInfo(pid: 11, bundleID: "com.corsair.ControlCenter", name: "ControlCenter")
    let vpn = RunningAppInfo(pid: 12, bundleID: "ie.boboco.vpnswitch", name: "VPN Switch")
    var s = FixtureSource(apps: [agent, istat, corsair, vpn])
    func f(_ x: CGFloat, _ w: CGFloat) -> CGRect { CGRect(x: x, y: 2.5, width: w, height: 24) }
    s.extras[10] = [AXElementInfo(identifier: "com.bjango.istatmenus.weather", frame: f(1136, 41))]
    s.extras[11] = [AXElementInfo(frame: f(1136, corsairW))]
    s.extras[12] = [AXElementInfo(title: "Shield Lefthalf Filled With A Checkmark Badge", frame: f(1162, 24))]
    if extraCandidate { s.apps.append(RunningAppInfo(pid: 13, bundleID: "x.y", name: "X")); s.extras[13] = [AXElementInfo(frame: f(1190, 24))] }
    s.tree = AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [
        AXElementInfo(identifier: "com.bjango.istatmenus.weather", frame: f(1136, 41)),
        AXElementInfo(frame: f(1136, 24)),
        AXElementInfo(title: hostedTitle, frame: f(1162, 24)),
    ])
    return s
}

@Test func liveFixtureNeighbourPairTrustedAsFrameUnique() {
    let items = MenuBarScanner(source: vpnFixture()).scan().items
    let c = items.first { $0.ownerBundleID == "com.corsair.ControlCenter" }
    let v = items.first { $0.ownerBundleID == "ie.boboco.vpnswitch" }
    #expect(c?.joinEvidence == .frameUnique)
    #expect(v?.joinEvidence == .frameUnique)
}

@Test func eliminationNotAppliedWhenCountsDiffer() {
    let items = MenuBarScanner(source: vpnFixture(extraCandidate: true)).scan().items
    #expect(!items.contains { $0.joinEvidence == .elimination })
}

@Test func eliminationNotAppliedWhenWidthsDisagree() {
    let items = MenuBarScanner(source: vpnFixture(corsairW: 40)).scan().items
    #expect(!items.contains { $0.joinEvidence == .elimination })
    #expect(items.first { $0.ownerBundleID == "com.corsair.ControlCenter" }?.joinEvidence.corroborated == false)
}

@Test func uniqueTitleOnHostedElementCorroboratesByDescription() {
    let items = MenuBarScanner(source: vpnFixture(hostedTitle: "Shield Lefthalf Filled With A Checkmark Badge")).scan().items
    #expect(items.first { $0.ownerBundleID == "ie.boboco.vpnswitch" }?.joinEvidence == .description)
}

@Test func liveShapeVpnJoinsByDescriptionAndCorsairStaysCorroborated() {
    let t = "Shield Lefthalf Filled With A Checkmark Badge"
    var s = vpnFixture()
    s.tree.elements[2] = AXElementInfo(title: t, axDescription: t, frame: CGRect(x: 1162, y: 2.5, width: 24, height: 24))
    let items = MenuBarScanner(source: s).scan().items
    #expect(items.first { $0.ownerBundleID == "ie.boboco.vpnswitch" }?.joinEvidence == .description)
    #expect(items.first { $0.ownerBundleID == "com.corsair.ControlCenter" }?.joinEvidence == .frameUnique)
}

@Test func eliminationFallbackWhenFrameRuleFails() {
    // Both owners' app-side frames lag onto each other's element: frame rule ambiguous, one-to-one left-to-right pairing holds.
    let a = RunningAppInfo(pid: 21, bundleID: "a.a", name: "A"), b = RunningAppInfo(pid: 22, bundleID: "b.b", name: "B")
    var s = FixtureSource(apps: [agent, a, b])
    s.extras[21] = [AXElementInfo(frame: bar(1136))]
    s.extras[22] = [AXElementInfo(frame: bar(1148))]
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [AXElementInfo(frame: bar(1136)), AXElementInfo(frame: bar(1162))])
    let items = MenuBarScanner(source: s).scan().items
    let ext = items.filter { $0.source == .appExtras }
    #expect(ext.filter { $0.joinEvidence == .elimination }.count == 2)
}

@Test func sharedDescriptionNeverClaimsAnElement() {
    // Two hosted elements share the description "Shared". Candidate A (description "Shared", frame on H1) gets an ambiguous
    // description match; candidate B (no description) overlaps H1 only. A's ambiguous match must not claim H1, and
    // B must not be promoted to frameUnique/elimination against it (gdu.94).
    let a = RunningAppInfo(pid: 21, bundleID: "a.a", name: "A"), b = RunningAppInfo(pid: 22, bundleID: "b.b", name: "B")
    func f(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 2.5, width: 24, height: 24) }
    var s = FixtureSource(apps: [agent, a, b])
    s.extras[21] = [AXElementInfo(axDescription: "Shared", frame: f(1136))]
    s.extras[22] = [AXElementInfo(frame: f(1136))]
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [
        AXElementInfo(axDescription: "Shared", frame: f(1100)), AXElementInfo(axDescription: "Shared", frame: f(1136))])
    let items = MenuBarScanner(source: s).scan().items.filter { $0.source == .appExtras }
    #expect(items.count == 2)
    #expect(items.first { $0.ownerBundleID == "a.a" }?.joinEvidence == .frameAmbiguous)
    #expect(items.first { $0.ownerBundleID == "b.b" }?.joinEvidence == .frameAmbiguous)
}

@Test func eliminationDoesNotRepairACandidateAnEarlierRunPaired() {
    // 9o9.13: run 1 (H1 1100, H2 1148) pairs X 1076 / Y 1172. Run 2 (G1 1198 w26, G2 1224 w26) could also reach Y (within ~2 pt
    // wider elements); with the free list rebuilt per run only Z is left, the counts differ, and Y stays on H2.
    let x = RunningAppInfo(pid: 21, bundleID: "x.x", name: "X"), y = RunningAppInfo(pid: 22, bundleID: "y.y", name: "Y"),
        z = RunningAppInfo(pid: 23, bundleID: "z.z", name: "Z")
    var s = FixtureSource(apps: [agent, x, y, z])
    s.extras[21] = [AXElementInfo(frame: bar(1076))]
    s.extras[22] = [AXElementInfo(frame: bar(1172))]
    s.extras[23] = [AXElementInfo(frame: bar(1250))]
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [
        AXElementInfo(frame: bar(1100)), AXElementInfo(frame: bar(1148)),
        AXElementInfo(frame: bar(1198, w: 26)), AXElementInfo(frame: bar(1224, w: 26))])
    let items = MenuBarScanner(source: s).scan().items.filter { $0.source == .appExtras }
    let yItem = items.first { $0.ownerBundleID == "y.y" }
    #expect(yItem?.joinEvidence == .elimination)
    #expect(yItem?.frame.minX == 1148)
    #expect(items.first { $0.ownerBundleID == "z.z" }?.joinEvidence != .elimination)
}

@Test func eliminationRefusesAnElementWhoseDescriptionMatchesAnotherCandidate() {
    // 9o9.13: A "Shared" (far away) matches both "Shared" elements only ambiguously; B and C (no description) must not take
    // those elements by elimination.
    let a = RunningAppInfo(pid: 21, bundleID: "a.a", name: "A"), b = RunningAppInfo(pid: 22, bundleID: "b.b", name: "B"),
        c = RunningAppInfo(pid: 23, bundleID: "c.c", name: "C")
    var s = FixtureSource(apps: [agent, a, b, c])
    s.extras[21] = [AXElementInfo(axDescription: "Shared", frame: bar(1300))]
    s.extras[22] = [AXElementInfo(frame: bar(1100))]
    s.extras[23] = [AXElementInfo(frame: bar(1124))]
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [
        AXElementInfo(axDescription: "Shared", frame: bar(1100)), AXElementInfo(axDescription: "Shared", frame: bar(1124))])
    let items = MenuBarScanner(source: s).scan().items.filter { $0.source == .appExtras }
    #expect(items.filter { $0.joinEvidence == .elimination }.isEmpty)
}
