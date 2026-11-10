import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

/// gdu.79: an app-side frame alone never makes an item "on the bar"; the Control Center flag and the hosted tree are the authority.
/// Recorded incident (2026-11-05): after a live hide 1Password, BoltAI, Tailscale, TextSniper ... kept `appExtras` frames at x 781-803
/// with Control Center isAllowed=0 and no hosted element; `mbprobe list` said ON BAR, init-from-current wrote them visible, the engine
/// then "showed" BoltAI.
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
private let bolt = RunningAppInfo(pid: 10, bundleID: "co.podzim.boltai-mobile", name: "BoltAI")
private let onePw = RunningAppInfo(pid: 11, bundleID: "com.1password.1password", name: "1Password")
private let shown = RunningAppInfo(pid: 12, bundleID: "ie.test.shown", name: "Shown")
private let sysui = RunningAppInfo(pid: 13, bundleID: "com.apple.systemuiserver", name: "SystemUIServer")
private func bar(_ x: CGFloat, w: CGFloat = 22) -> CGRect { CGRect(x: x, y: 4, width: w, height: 22) }
private func entry(_ k: String, _ allowed: Bool) -> ControlCenterTrackedAppsStore.Entry { .init(key: k, isAllowed: allowed, menuItemKeys: [k]) }

private func source() -> Src {
    var s = Src(apps: [agent, bolt, onePw, shown, sysui])
    // BoltAI / 1Password: stale app-side frames at x 781-799, no hosted element (the recorded rv65/r68 shape).
    s.extras[10] = [AXElementInfo(axDescription: "BoltAI", identifier: "boltai", frame: bar(783))]
    s.extras[11] = [AXElementInfo(axDescription: "1Password", identifier: "1pw", frame: bar(781))]
    s.extras[12] = [AXElementInfo(axDescription: "Shown", identifier: "shown", frame: bar(900))]
    s.extras[13] = [AXElementInfo(frame: bar(1100))]
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [
        AXElementInfo(axDescription: "Shown", identifier: "shown", frame: bar(900)),
        AXElementInfo(axDescription: "Clock", frame: bar(1500)),
    ])
    return s
}

private func scan(_ entries: [ControlCenterTrackedAppsStore.Entry]?) -> MenuBarSnapshot {
    var sc = MenuBarScanner(source: source())
    sc.trackedEntries = { entries.map { .entries($0) } ?? .notConfigured }
    return sc.scan()
}
private func item(_ s: MenuBarSnapshot, _ name: String) -> MenuBarItem { s.items.first { $0.ownerName == name }! }

@Suite struct AuthorityRuleScannerTests {
    @Test func appExtrasOnlyWithIsAllowedFalseIsHiddenNeverOnBar() {
        let s = scan([entry("co.podzim.boltai-mobile", false), entry("com.1password.1password", false), entry("ie.test.shown", true)])
        for n in ["BoltAI", "1Password"] {
            let i = item(s, n)
            #expect(i.source == .appExtras && i.joinEvidence == .none)
            #expect(!i.isOnMenuBar && i.hiddenInControlCenter && !i.placementUnknown)
            #expect(i.hiddenReason == .controlCenterHidden && i.controlCenterAllowed == false)
            #expect(!s.onBarLeftToRight.contains { $0.ownerName == n })
        }
    }

    @Test func appExtrasOnlyWithIsAllowedTrueIsUnknownNotVisible() {
        let s = scan([entry("co.podzim.boltai-mobile", true), entry("com.1password.1password", false), entry("ie.test.shown", true)])
        let i = item(s, "BoltAI")
        #expect(!i.isOnMenuBar && i.placementUnknown && !i.hiddenInControlCenter && i.hiddenReason == .placementUnknown)
        #expect(i.controlCenterAllowed == true)
    }

    @Test func aHostedItemIsOnBarAsBefore() {
        let s = scan([entry("co.podzim.boltai-mobile", false), entry("ie.test.shown", true)])
        let i = item(s, "Shown")
        #expect(i.isOnMenuBar && !i.placementUnknown && !i.hiddenInControlCenter && i.joinEvidence == .identifier)
        // Even a (lagging) false flag does not override a hosted element: the agent is the authority for what it hosts.
        let s2 = scan([entry("ie.test.shown", false)])
        #expect(item(s2, "Shown").isOnMenuBar)
    }

    @Test func itemsNoEntryGovernsAndUnreadableStoreKeepTheFrameRule() {
        let s = scan([entry("co.podzim.boltai-mobile", false)])
        #expect(item(s, "SystemUIServer").isOnMenuBar)          // no tracked entry: cannot be live-hidden
        #expect(item(s, "1Password").isOnMenuBar)               // no entry for it either
        let u = scan(nil)
        #expect(item(u, "BoltAI").isOnMenuBar)                  // unreadable store: cannot judge
    }

    @Test func theClassificationRoundTripsThroughCodable() throws {
        let s = scan([entry("co.podzim.boltai-mobile", false), entry("com.1password.1password", true)])
        let back = try JSONDecoder().decode(MenuBarSnapshot.self, from: JSONEncoder().encode(s))
        #expect(item(back, "BoltAI").hiddenInControlCenter && item(back, "1Password").placementUnknown)
    }
}

@Suite struct AuthorityRuleLayoutTests {
    private func resolved(_ entries: [ControlCenterTrackedAppsStore.Entry]) -> [ResolvedItem] {
        scan(entries).items.enumerated().map { i, it in
            ResolvedItem(item: it, key: .status(ownerKey: it.ownerBundleID ?? "x", autosaveName: it.axIdentifier.isEmpty ? "n\(i)" : it.axIdentifier), confidence: .exact)
        }
    }

    @Test func isAllowedFalseItemsGoToHiddenNeverVisible() {
        let r = resolved([entry("co.podzim.boltai-mobile", false), entry("com.1password.1password", false), entry("ie.test.shown", true)])
        #expect(LayoutBuilder.unknownPlacement(in: r).isEmpty)
        let l = LayoutBuilder.build(from: r).layout
        let boltKey = ItemKey.status(ownerKey: "co.podzim.boltai-mobile", autosaveName: "boltai")
        #expect(l.hidden.contains(boltKey) && !l.visible.contains(boltKey))
        #expect(l.hidden.count >= 2)
    }

    @Test func unknownPlacementIsRefusedAndNeverWrittenAnywhere() {
        let r = resolved([entry("co.podzim.boltai-mobile", true), entry("com.1password.1password", false), entry("ie.test.shown", true)])
        let unknown = LayoutBuilder.unknownPlacement(in: r)
        #expect(unknown == [.status(ownerKey: "co.podzim.boltai-mobile", autosaveName: "boltai")])
        let msg = LayoutBuilder.unknownPlacementMessage(unknown)
        #expect(msg.hasPrefix("placement unknown for 1 items: "))
        #expect(msg.contains("no hosted element") && msg.contains("make room in the bar"))
        #expect(msg.contains("boltai"))
        let l = LayoutBuilder.build(from: r).layout
        #expect(!l.allKeys.contains(unknown[0]))
    }
}

// MARK: engine guard

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private struct AllCaps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
}
private struct ActObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] {
        FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden))
    }
}
private struct UnknownObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] {
        var r = FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden))
        for i in r.indices where r[i].key == k("A") { r[i].item.placementUnknown = true }
        return r
    }
}
private final class Lines: @unchecked Sendable {
    private let l = NSLock(); private var v: [String] = []
    func add(_ s: String) { l.lock(); v.append(s); l.unlock() }
    var all: [String] { l.lock(); defer { l.unlock() }; return v }
}

@MainActor
private func guardRig(layout: Layout, flagFalse: Set<String> = ["com.x.A"], lines: Lines = Lines(), order: [ItemKey] = [k("A"), k("B")],
                      noticeLifetime: Duration = .seconds(10)) async -> (LayoutEngine, FakeActuator, EngineState, Lines) {
    let act = FakeActuator(order: order, hidden: [k("A")], capabilities: AllCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    var cfg = LayoutEngine.Config.plain()
    cfg.layoutCoalesce = .zero
    cfg.noticeLifetime = noticeLifetime
    cfg.trackedResolver = { TrackedEntryResolver(entries: ["com.x.A", "com.x.B"].map { entry($0, !flagFalse.contains($0)) }) }
    cfg.trackedAllowed = { flagFalse.contains($0) ? false : true }
    let state = EngineState()
    let e = LayoutEngine(observer: ActObserver(actuator: act), actuator: act, store: InMemoryLayoutStore(layout), capabilities: AllCaps(), state: state,
                         resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { lines.add($0) }, config: cfg)
    await e.start()
    return (e, act, state, lines)
}

@MainActor
@Suite struct AuthorityRuleEngineTests {
    // 9o9.25: a flag-false Visible key the user did not place here is ADOPTED into Hidden once (no skip, no show write).
    @Test func aFlagFalseVisibleKeyIsAdoptedIntoHiddenOnceWithLogAndNotice() async {
        let (e, act, state, lines) = await guardRig(layout: Layout(visible: [k("A"), k("B")]))
        _ = await e.reconcileOnce()
        _ = await e.reconcileOnce()
        #expect(await act.calls.isEmpty)
        #expect(await act.hidden == [k("A")])
        #expect(state.layout.hidden == [k("A")] && state.layout.visible == [k("B")])
        if case .unsupported? = state.perItem[k("A")] { Issue.record("must not be a skip") }
        let adopted = lines.all.filter { $0 == "layout: adopted System Settings: \(k("A")) is hidden there; moved to Hidden" }
        #expect(adopted.count == 1)
        #expect(state.systemSettingsNotice?.hasPrefix("Moved ") == true && state.systemSettingsNotice?.hasSuffix(" to Hidden: it is hidden in System Settings") == true)
    }

    @Test func systemSettingsNoticeTextAndStatusLine() {
        #expect(SystemSettingsNotice.text(["Foo"]) == "Moved Foo to Hidden: it is hidden in System Settings")
        #expect(SystemSettingsNotice.text(["Foo", "Bar"]) == "Moved Foo, Bar to Hidden: they are hidden in System Settings")
        var ctx = CoreStatusContext()   // sommelier-ejb.7: the line is `CoreStatusText` (notices lead, and "matches" is never said under them)
        ctx.systemSettingsNotice = SystemSettingsNotice.text(["Foo"])
        let line = CoreStatusText.render(.matches, ctx)
        #expect(line.contains("Moved Foo to Hidden: it is hidden in System Settings") && !line.contains(CoreStatusText.matches))
        ctx.systemSettingsNotice = nil
        #expect(!CoreStatusText.render(.matches, ctx).contains("Moved Foo"))
        ctx.handDragNotice = "Adopted your menu bar drag"; ctx.systemSettingsNotice = "SS"
        #expect(CoreStatusText.render(.matches, ctx).contains("Adopted your menu bar drag"))
    }

    @Test func theNoticeClearsAfterItsLifetime() async {
        let (e, _, state, _) = await guardRig(layout: Layout(visible: [k("A"), k("B")]), noticeLifetime: .milliseconds(50))
        _ = await e.reconcileOnce()
        let cleared = await waitUntil { await MainActor.run { state.systemSettingsNotice == nil } }
        #expect(cleared)
    }

    @Test func hideUnitSiblingsMoveToHiddenTogether() async {
        let a2 = ItemKey.status(ownerKey: "com.x.A", autosaveName: "A2")
        let (e, _, state, _) = await guardRig(layout: Layout(visible: [k("A"), k("B"), a2]))
        _ = await e.reconcileOnce()
        #expect(Set(state.layout.hidden) == [k("A"), a2] && state.layout.visible == [k("B")])
        let n = state.systemSettingsNotice ?? ""
        #expect(n.hasPrefix("Moved ") && n.hasSuffix("they are hidden in System Settings"))   // plural wording: the sibling is named too
    }

    // 9o9.25: a drawn sibling means the user did not hide the whole unit: the adoption is skipped for it.
    @Test func aDrawnSiblingOfAHiddenKeyPreventsTheAdoption() async {
        let a2 = ItemKey.status(ownerKey: "com.x.A", autosaveName: "A2")
        let (e, _, state, lines) = await guardRig(layout: Layout(visible: [k("A"), k("B"), a2]), order: [k("A"), k("B"), a2])
        _ = await e.reconcileOnce()
        #expect(state.layout.visible == [k("A"), k("B"), a2] && state.layout.hidden.isEmpty)
        #expect(state.systemSettingsNotice == nil)
        #expect(lines.all.contains { $0 == "layout: not adopting System Settings hide of \(k("A")): its sibling \(a2) is on the bar" })
    }

    @Test func aPlacementUnknownKeyIsNotAdopted() async {
        let act = FakeActuator(order: [k("A"), k("B")], hidden: [k("A")], capabilities: AllCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        var cfg = LayoutEngine.Config.plain()
        cfg.layoutCoalesce = .zero
        cfg.trackedResolver = { TrackedEntryResolver(entries: ["com.x.A", "com.x.B"].map { entry($0, $0 != "com.x.A") }) }
        cfg.trackedAllowed = { $0 == "com.x.A" ? false : true }
        let lines = Lines(), st = EngineState()
        let e = LayoutEngine(observer: UnknownObserver(actuator: act), actuator: act, store: InMemoryLayoutStore(Layout(visible: [k("A"), k("B")])),
                             capabilities: AllCaps(), state: st, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in },
                             log: { lines.add($0) }, config: cfg)
        await e.start()
        _ = await e.reconcileOnce()
        #expect(st.layout.visible == [k("A"), k("B")])
        #expect(!lines.all.contains { $0.contains("adopted System Settings") })
        #expect(await act.calls.isEmpty)
    }

    @Test func aUserPlacementIntoVisibleShowsAsBefore() async {
        let (e, act, _, lines) = await guardRig(layout: Layout(visible: [k("B")], hidden: [k("A")]))
        await e.setLayout(Layout(visible: [k("A"), k("B")]))
        let ok = await waitUntil { await act.hidden.isEmpty }
        #expect(ok)
        #expect(lines.all.contains { $0.contains("membership write: show") && $0.contains("userPlaced=true") && $0.contains("isAllowed=false") })
    }

    @Test func aProgrammaticSetLayoutIsNotAUserPlacement() async {
        let (e, act, _, _) = await guardRig(layout: Layout(visible: [k("B")], hidden: [k("A")]))
        await e.setLayout(Layout(visible: [k("A"), k("B")]), userPlacement: false)
        _ = await e.reconcileOnce()
        #expect(await act.hidden == [k("A")])
        #expect(await act.calls.isEmpty)
    }

    // gdu.95: a drop of a key the layout lists visible (parked, isAllowed=false) is a user placement when moved.
    @Test func aDropOfAnAlreadyListedVisibleKeyIsAPlacementOnlyWhenMoved() async {
        let (e, act, _, lines) = await guardRig(layout: Layout(visible: [k("A"), k("B")]))
        _ = await e.reconcileOnce()
        #expect(await act.hidden == [k("A")])                       // adopted into Hidden, not shown
        await e.setLayout(Layout(visible: [k("A"), k("B")]), userPlacement: true, moved: [k("A")])
        let ok = await waitUntil { await act.hidden.isEmpty }
        #expect(ok)
        #expect(lines.all.contains { $0.contains("membership write: show") && $0.contains("userPlaced=true") })
    }

    @Test func aMovedKeyOutsideVisibleIsIgnoredAndAShownPlacementIsSpent() async {
        let (e, act, _, _) = await guardRig(layout: Layout(visible: [k("A"), k("B")]))
        await e.setLayout(Layout(visible: [k("B")], hidden: [k("A")]), userPlacement: true, moved: [k("A")])
        _ = await e.reconcileOnce()
        #expect(await act.hidden == [k("A")])                       // moved into Hidden: nothing to show
        await e.setLayout(Layout(visible: [k("A"), k("B")]), userPlacement: true, moved: [k("A")])
        #expect(await waitUntil { await act.hidden.isEmpty })
        _ = await e.reconcileOnce()                                 // A observed on the bar: placement spent
        _ = await act.setHidden(k("A"), true)                       // someone else hides it again
        _ = await e.reconcileOnce()
        #expect(await act.hidden == [k("A")])                       // (d) not re-shown
    }

    @Test func aFlagTrueKeyListedVisibleIsStillShown() async {
        let (e, act, _, _) = await guardRig(layout: Layout(visible: [k("A"), k("B")]), flagFalse: [])
        _ = await e.reconcileOnce()
        #expect(await act.hidden.isEmpty)
    }
}

private func waitUntil(_ cond: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@Test func observedOrderCarriesUnknownPlacementAsParkedButUnshowable() {
    var snap = FakeMenuBar.snapshot(order: [k("B")], hidden: [k("A")])
    snap.items[1].placementUnknown = true
    let o = ObservedOrder(resolved: FakeMenuBar.resolve(snap))
    #expect(o.parked == [k("A")] && o.placementUnknown == [k("A")])
}

// MARK: corrective: hosted elements OVER the stale frames (the shape the first fixture lacked)

private let kya = RunningAppInfo(pid: 14, bundleID: "info.marcel-dierkes.KeepingYouAwake", name: "KeepingYouAwake")
private let scriptMenu = RunningAppInfo(pid: 15, bundleID: "com.apple.ScriptMenuApp", name: "Script Menu")

@Suite struct AuthorityRuleWeakJoinTests {
    private func run(_ s: Src, _ entries: [ControlCenterTrackedAppsStore.Entry]?) -> MenuBarSnapshot {
        var sc = MenuBarScanner(source: s); sc.trackedEntries = { entries.map { .entries($0) } ?? .notConfigured }; return sc.scan()
    }

    @Test func aFlagFalseItemCannotStealAnotherItemsHostedElement() {
        var s = Src(apps: [agent, onePw, kya])
        s.extras[11] = [AXElementInfo(frame: bar(783, w: 30))]   // 1Password: stale frame, identifier-less
        s.extras[14] = [AXElementInfo(frame: bar(783, w: 30))]   // KeepingYouAwake: genuinely drawn here
        s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [AXElementInfo(frame: bar(783, w: 30))])
        let snap = run(s, [entry("com.1password.1password", false), entry("info.marcel-dierkes.KeepingYouAwake", true)])
        let pw = item(snap, "1Password"), k = item(snap, "KeepingYouAwake")
        #expect(!pw.isOnMenuBar && pw.hiddenInControlCenter && pw.hiddenReason == .controlCenterHidden && pw.joinEvidence == .none)
        #expect(k.isOnMenuBar && !k.placementUnknown)
    }

    @Test func aFlagFalseItemOverlappingThePileIsHidden() {
        var s = Src(apps: [agent, scriptMenu])
        s.extras[15] = [AXElementInfo(axDescription: "scroll", frame: bar(790, w: 22))]
        s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [
            AXElementInfo(axDescription: "Other", identifier: "other", frame: bar(789, w: 24)),
            AXElementInfo(axDescription: "x", frame: bar(795, w: 17, ), directWindowChild: true),
        ])
        let snap = run(s, [entry("com.apple.ScriptMenuApp", false)])
        let i = item(snap, "Script Menu")
        #expect(!i.isOnMenuBar && i.hiddenInControlCenter)
        #expect(snap.items.contains { $0.axIdentifier == "other" && $0.isOnMenuBar })   // the element stays its real owner's / agent-only
    }

    @Test func anAllowedItemWithOnlyAWeakJoinInThePileIsUnknown() {
        var s = Src(apps: [agent, kya])
        s.extras[14] = [AXElementInfo(frame: bar(783, w: 30))]
        s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [
            AXElementInfo(frame: bar(781, w: 28)),   // overlaps, widths differ by 2+: frameAmbiguous
            AXElementInfo(frame: bar(795, w: 17), directWindowChild: true),
        ])
        let snap = run(s, [entry("info.marcel-dierkes.KeepingYouAwake", true)])
        let i = item(snap, "KeepingYouAwake")
        #expect(!i.isOnMenuBar && i.placementUnknown)
    }

    @Test func aFlagFalseUnjoinedItemIsHiddenOnAnExceptSelfPositioningRead() {
        // Incomplete hosted read (a stale self-positioning group): the flag alone still decides.
        var s = Src(apps: [agent, bolt])
        s.extras[10] = [AXElementInfo(axDescription: "BoltAI", identifier: "boltai", frame: bar(783))]
        s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [AXElementInfo(axDescription: "Clock", frame: bar(1500))],
                                 failedReads: 1, timedOut: [], unnamedTimeouts: 1)
        let snap = run(s, [entry("co.podzim.boltai-mobile", false)])
        #expect(snap.hostedReadComplete == false)
        #expect(item(snap, "BoltAI").hiddenInControlCenter && !item(snap, "BoltAI").isOnMenuBar)
    }

    @Test func aScannerOnAFixtureSourceNeverReadsTheRealStore() {
        #expect(MenuBarScanner(source: Src()).trackedEntries() == .notConfigured)
    }
}

/// gdu.84: KeepingYouAwake (rv82 numbers): allowed, app-side 795/w30, an UNOWNED hosted element at exactly 795/w30 in the overflow pile, and
/// pile neighbours that overlap it (TextInputMenuAgent 798/w27, #4 799/w22). The exact-frame tie-break joins it as frameUnique.
@Suite struct ExactFrameTieBreakTests {
    private let kya = RunningAppInfo(pid: 20, bundleID: "info.marcel-dierkes.KeepingYouAwake", name: "KeepingYouAwake")
    private let kya2 = RunningAppInfo(pid: 21, bundleID: "ie.test.twin", name: "Twin")
    private func mk(kyaFrame: CGRect, twinFrame: CGRect? = nil) -> Src {
        var s = Src(apps: [agent, kya, kya2])
        s.extras[20] = [AXElementInfo(frame: kyaFrame)]
        if let t = twinFrame { s.extras[21] = [AXElementInfo(frame: t)] }
        s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [
            AXElementInfo(title: "TextInputMenuAgent", frame: bar(798, w: 27)),
            AXElementInfo(title: "#3", frame: bar(795, w: 30)),
            AXElementInfo(title: "#4", frame: bar(799, w: 22)),
            AXElementInfo(axDescription: MenuBarItem.overflowChevronName, frame: bar(795, w: 17)),
            AXElementInfo(axDescription: "Clock", frame: bar(1500)),
        ])
        return s
    }
    private func run(_ s: Src, allowed: [String: Bool]) -> MenuBarSnapshot {
        var sc = MenuBarScanner(source: s)
        sc.trackedEntries = { .entries(allowed.map { entry($0.key, $0.value) }) }
        return sc.scan()
    }

    @Test func allowedItemExactlyOnAnUnownedElementInThePileIsFrameUniqueAndOnBar() {
        let s = run(mk(kyaFrame: bar(795, w: 30)), allowed: ["info.marcel-dierkes.KeepingYouAwake": true])
        let i = item(s, "KeepingYouAwake")
        #expect(i.joinEvidence == .frameUnique && i.isOnMenuBar && !i.placementUnknown && i.systemOverflow)
        #expect(i.frame == bar(795, w: 30))
    }

    @Test func theSameShapeWithAFlagFalseItemStaysControlCenterHidden() {
        let s = run(mk(kyaFrame: bar(795, w: 30)), allowed: ["info.marcel-dierkes.KeepingYouAwake": false])
        let i = item(s, "KeepingYouAwake")
        #expect(i.hiddenReason == .controlCenterHidden && !i.isOnMenuBar && i.joinEvidence == .none)
    }

    @Test func twoAllowedItemsExactlyMatchingOneElementStayAmbiguous() {
        let s = run(mk(kyaFrame: bar(795, w: 30), twinFrame: bar(795, w: 30)),
                    allowed: ["info.marcel-dierkes.KeepingYouAwake": true, "ie.test.twin": true])
        #expect(!s.items.contains { $0.ownerName == "KeepingYouAwake" && $0.joinEvidence == .frameUnique })
        #expect(!s.items.contains { $0.ownerName == "Twin" && $0.joinEvidence == .frameUnique })
    }

    @Test func anAllowedItemTwoPointsOffIsStillUnknownWithAPileReason() {
        let s = run(mk(kyaFrame: bar(797, w: 30)), allowed: ["info.marcel-dierkes.KeepingYouAwake": true])
        let i = item(s, "KeepingYouAwake")
        #expect(i.placementUnknown && i.joinEvidence == .none)
        #expect(i.placementReason?.contains("weak join (frameAmbiguous)") == true)
        #expect(i.placementReason?.contains("overflow pile") == true && i.placementReason?.contains("make room in the bar") == true)
    }
}

/// gdu.85: the exact-frame tie-break is limited to the overflow pile.
@Suite struct ExactFrameTieBreakScopeTests {
    private let a = RunningAppInfo(pid: 30, bundleID: "ie.test.a", name: "A")
    private let b = RunningAppInfo(pid: 31, bundleID: "ie.test.b", name: "B")
    @Test func aOnePointCoincidenceOutsideThePileIsNotJoinedByTheExactPass() {
        // Chevron at 795; A at 1000 (right of the chevron, not stacked): B's lagging frame overlaps A's hosted element too.
        var s = Src(apps: [agent, a, b])
        s.extras[30] = [AXElementInfo(frame: bar(1000))]
        s.extras[31] = [AXElementInfo(frame: bar(1010))]
        s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [
            AXElementInfo(axDescription: MenuBarItem.overflowChevronName, frame: bar(795, w: 17)),
            AXElementInfo(frame: bar(1001)), AXElementInfo(frame: bar(1300)),
        ])
        let items = MenuBarScanner(source: s).scan().items
        #expect(items.allSatisfy { $0.joinEvidence != .frameUnique })   // gdu.28 mutual-and-exclusive rule decides (A and B both overlap)
    }
    @Test func theKyaShapeStillJoinsInThePile() {
        var s = Src(apps: [agent, a])
        s.extras[30] = [AXElementInfo(frame: bar(795, w: 30))]
        s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [
            AXElementInfo(frame: bar(798, w: 27)), AXElementInfo(frame: bar(795, w: 30)), AXElementInfo(frame: bar(799, w: 22)),
            AXElementInfo(axDescription: MenuBarItem.overflowChevronName, frame: bar(795, w: 17)),
        ])
        var sc = MenuBarScanner(source: s); sc.trackedEntries = { .entries([entry("ie.test.a", true)]) }
        let i = sc.scan().items.first { $0.ownerName == "A" }!
        #expect(i.joinEvidence == .frameUnique && i.isOnMenuBar && i.systemOverflow)
    }
}

@Test func incompleteReasonsDifferingOnlyInNumbersMergeKeepingTheHighest() {
    var l: [String] = []
    for w in ["2 unnamed timeouts, absent: 1", "5 unnamed timeouts, absent: 3", "3 unnamed timeouts, absent: 1", "other", "other"] {
        AgreedScanObserver.mergeIncompleteReason(w, into: &l)
    }
    #expect(l == ["5 unnamed timeouts, absent: 3", "other"])
}
