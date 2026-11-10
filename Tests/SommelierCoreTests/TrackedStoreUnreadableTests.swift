import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

/// gdu.87: the notarized build launched from Finder is denied Control Center's tracked-applications store (macOS App Data privacy).
/// An unreadable store is an observation problem, never a frame rule: every item the store would govern is NOT on the bar, the snapshot
/// carries the reason, and the engine refuses to act (and says why) until a scan can read the store again.

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
private let jump = RunningAppInfo(pid: 10, bundleID: "com.p5sys.jump.connect", name: "Jump Desktop Connect")
private let shown = RunningAppInfo(pid: 12, bundleID: "ie.test.shown", name: "Shown")
private let sysui = RunningAppInfo(pid: 13, bundleID: "com.apple.systemuiserver", name: "SystemUIServer")
private func bar(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 4, width: 22, height: 22) }

private func source() -> Src {
    var s = Src(apps: [agent, jump, shown, sysui])
    s.extras[10] = [AXElementInfo(axDescription: "Jump", identifier: "jump", frame: bar(783))]   // stale app-side frame, no hosted element
    s.extras[12] = [AXElementInfo(axDescription: "Shown", identifier: "shown", frame: bar(900))]
    s.extras[13] = [AXElementInfo(frame: bar(1100))]
    s.tree = AgentHostedTree(stripFrame: s.tree.stripFrame, elements: [
        AXElementInfo(axDescription: "Shown", identifier: "shown", frame: bar(900)),
        AXElementInfo(axDescription: "Clock", frame: bar(1500)),
    ])
    return s
}

private func scan(_ read: TrackedStoreRead) -> MenuBarSnapshot {
    var sc = MenuBarScanner(source: source())
    sc.trackedEntries = { read }
    return sc.scan()
}
private func item(_ s: MenuBarSnapshot, _ name: String) -> MenuBarItem { s.items.first { $0.ownerName == name }! }
private let denied = "access denied reading /Users/x/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist"

@Suite struct TrackedStoreUnreadableScannerTests {
    @Test func unreadableStoreMakesEveryGovernedItemNotOnTheBarAndCarriesTheReason() {
        let s = scan(.unreadable(denied))
        let j = item(s, "Jump Desktop Connect")
        #expect(!j.isOnMenuBar && j.placementUnknown && !s.onBarLeftToRight.contains { $0.ownerName == "Jump Desktop Connect" })
        #expect(j.placementReason?.contains("unreadable") == true)
        #expect(s.trackedStoreProblem == denied)
        #expect(s.completeness == .incomplete && s.hostedReadComplete == false)
        #expect(s.completenessReason == "Control Center's hidden-item list is unreadable: " + denied)
    }

    @Test func aHostedItemAndAppleExtrasStayOnTheBarWhileTheStoreIsUnreadable() {
        let s = scan(.unreadable(denied))
        #expect(item(s, "Shown").isOnMenuBar && !item(s, "Shown").placementUnknown)
        #expect(item(s, "SystemUIServer").isOnMenuBar)
    }

    @Test func notConfiguredKeepsTheFrameRuleAndNoProblem() {
        let s = scan(.notConfigured)
        #expect(item(s, "Jump Desktop Connect").isOnMenuBar && s.trackedStoreProblem == nil)
        #expect(s.completenessReason == nil)
    }

    @Test func aReadableStoreHasNoProblem() {
        let s = scan(.entries([.init(key: "com.p5sys.jump.connect", isAllowed: false, menuItemKeys: [])]))
        #expect(s.trackedStoreProblem == nil && item(s, "Jump Desktop Connect").hiddenInControlCenter)
    }

    @Test func theDedicatedReasonIsTheSnapshotTextAndSurvivesTheNumericMerge() {
        let s = scan(.unreadable(denied))
        let dedicated = "Control Center's hidden-item list is unreadable: " + denied
        #expect(s.completenessReason == dedicated)
        // The observer throws before merging, but any combination with a numeric reason (gdu.85) must keep both, untouched.
        var l: [String] = []
        AgreedScanObserver.mergeIncompleteReason("3 unnamed timeouts, absent: 1", into: &l)
        AgreedScanObserver.mergeIncompleteReason(dedicated, into: &l)
        AgreedScanObserver.mergeIncompleteReason("7 unnamed timeouts, absent: 2", into: &l)
        #expect(l == ["7 unnamed timeouts, absent: 2", dedicated])
    }
}

@Suite struct TrackedStoreReadLiveTests {
    private func access(cf: Data?, file: Data?, status: StoreFileStatus = .missing) -> LivePrefsAccess {
        LivePrefsAccess(read: { cf }, write: { _ in true }, fileBlob: { file }, fileStatus: { status })
    }
    private func blob() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [["bundle": "ie.test.a"], ["isAllowed": false]] as [Any], format: .binary, options: 0)
    }

    @Test func anExistingFileThatCannotBeReadIsUnreadableWithTheReason() {
        #expect(ControlCenterTrackedAppsStore.readLive(access: access(cf: nil, file: nil, status: .unreadable(denied))) == .unreadable(denied))
    }

    @Test func aMissingFileIsNotConfiguredNotUnreadable() {
        #expect(ControlCenterTrackedAppsStore.readLive(access: access(cf: nil, file: nil, status: .missing)) == .notConfigured)
    }

    @Test func aReadableFileWithoutTheKeyMeansNothingIsTracked() {
        #expect(ControlCenterTrackedAppsStore.readLive(access: access(cf: nil, file: nil, status: .readableWithoutBlob)) == .entries([]))
    }

    @Test func anUnparseableBlobIsUnreadable() {
        guard case .unreadable = ControlCenterTrackedAppsStore.readLive(access: access(cf: Data([1, 2, 3]), file: nil)) else {
            Issue.record("expected unreadable"); return
        }
    }

    @Test func fileFallbackIsUsedWhenCFPreferencesHasNothing() throws {
        let b = try blob()
        guard case .entries = ControlCenterTrackedAppsStore.readLive(access: access(cf: nil, file: b, status: .unreadable("x"))) else {
            Issue.record("file fallback ignored"); return
        }
    }

    @Test func fileStatusClassifiesMissingDeniedAndReadable() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory() + "/sommelier-nonexistent-\(UUID().uuidString).plist")
        #expect(ControlCenterTrackedAppsStore.fileStatus(at: missing) == .missing)
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "/sommelier-denied-\(UUID().uuidString).plist")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path); try? FileManager.default.removeItem(at: url) }
        #expect(ControlCenterTrackedAppsStore.fileStatus(at: url) == .readableWithoutBlob)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        guard case .unreadable(let why) = ControlCenterTrackedAppsStore.fileStatus(at: url) else { Issue.record("expected unreadable"); return }
        #expect(why.contains("access denied") && why.contains(url.path))
    }

    @Test func theBackgroundProbeUsesAccessChecksOnly() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "/sommelier-probe-\(UUID().uuidString).plist")
        #expect(ControlCenterTrackedAppsStore.probeAccess(fileURL: url) == .unknown)
        try Data([0]).write(to: url)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path); try? FileManager.default.removeItem(at: url) }
        #expect(ControlCenterTrackedAppsStore.probeAccess(fileURL: url) == .granted)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        #expect(ControlCenterTrackedAppsStore.probeAccess(fileURL: url) == .denied)
    }
}

@Suite struct TrackedStoreUnreadableEngineTests {
    private struct Scripted: SnapshotScanning {
        final class Box: @unchecked Sendable { var i = 0; var snaps: [MenuBarSnapshot]; init(_ s: [MenuBarSnapshot]) { snaps = s } }
        let box: Box
        func scanVisible() async -> MenuBarSnapshot { await scan() }
        func scan() async -> MenuBarSnapshot { let s = box.snaps[min(box.i, box.snaps.count - 1)]; box.i += 1; return s }
    }
    private struct Caps: CapabilityProvider {
        func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
    }
    private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }

    private func problemSnap(_ order: [String]) -> MenuBarSnapshot {
        var s = FakeMenuBar.snapshot(order: order.map(k), hidden: [])
        s.trackedStoreProblem = denied; s.hostedReadComplete = false; s.completenessReason = "Control Center's hidden-item list is unreadable: " + denied
        return s
    }

    @MainActor private func rig(_ snaps: [MenuBarSnapshot], layout: Layout) async -> (engine: LayoutEngine, state: EngineState, actuator: FakeActuator, store: InMemoryLayoutStore) {
        let act = FakeActuator(order: ["A", "B", "C"].map(k), hidden: [], capabilities: Caps(),
                               makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        let box = Scripted.Box(snaps)
        let observer = AgreedScanObserver(scanner: Scripted(box: box), resolve: { FakeMenuBar.resolve($0) },
                                          maxScans: 6, deadline: 15, accessibilityTrusted: { true }, sleep: { _ in })
        let store = InMemoryLayoutStore(layout)
        let state = EngineState()
        let engine = LayoutEngine(observer: observer, actuator: act, store: store, capabilities: Caps(), state: state, busy: { false },
                                  resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, config: .plain())
        await engine.start()
        return (engine, state, act, store)
    }

    @MainActor @Test func anUnreadableStoreIsAnObserveErrorWithNoActionsNoAdoptionAndNoLayoutChange() async throws {
        let layout = Layout.placedAll(visible: ["B", "A"].map(k))   // differs from the bar: a normal pass would drag
        let r = await rig([problemSnap(["A", "B", "C"])], layout: layout)   // C is a "new item" a normal pass would append
        let rep = await r.engine.reconcileOnce()
        #expect(rep.outcome == .observeFailed)
        #expect(r.state.lastError == .observe(ObserveError.trackedStoreMessage(denied)))
        #expect(r.state.lastError.map { "\($0)" }?.contains("will not act") == true)
        #expect(await r.actuator.calls.isEmpty)
        #expect(r.state.observed.onBar.isEmpty)
        #expect(try r.store.load() == layout)
        #expect(r.state.layout == layout)
    }

    @MainActor @Test func theNextReadableScanClearsTheErrorAndProceeds() async throws {
        let layout = Layout.placedAll(visible: ["B", "A", "C"].map(k))
        let clean = FakeMenuBar.snapshot(order: ["A", "B", "C"].map(k), hidden: [])
        let r = await rig([problemSnap(["A", "B", "C"]), clean], layout: layout)
        _ = await r.engine.reconcileOnce()
        #expect({ if case .observe? = r.state.lastError { return true } else { return false } }())
        _ = await r.engine.reconcileOnce()
        #expect(r.state.lastError == nil)
        #expect(!(await r.actuator.calls.isEmpty))   // the reorder now runs
    }

    @MainActor private func retryRig(_ box: Scripted.Box, layout: Layout) async -> (engine: LayoutEngine, state: EngineState, actuator: FakeActuator) {
        let act = FakeActuator(order: ["A", "B", "C"].map(k), hidden: [], capabilities: Caps(),
                               makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        let observer = AgreedScanObserver(scanner: Scripted(box: box), resolve: { FakeMenuBar.resolve($0) },
                                          maxScans: 6, deadline: 15, accessibilityTrusted: { true }, sleep: { _ in })
        var cfg = LayoutEngine.Config.plain()
        cfg.storeRetryBase = .milliseconds(20); cfg.storeRetryCap = .milliseconds(40)
        let state = EngineState()
        let engine = LayoutEngine(observer: observer, actuator: act, store: InMemoryLayoutStore(layout), capabilities: Caps(), state: state,
                                  busy: { false }, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, config: cfg)
        await engine.start()
        return (engine, state, act)
    }
    private func waitFor(_ cond: @escaping @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<600 { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
        return false
    }

    @MainActor @Test func theEngineRetriesByItselfAndRecoversWithoutAnyBarChange() async {
        let box = Scripted.Box([problemSnap(["A", "B", "C"])])      // every scan unreadable
        let r = await retryRig(box, layout: Layout.placedAll(visible: ["B", "A", "C"].map(k)))
        await r.engine.requestReconcile()                            // the ordinary trigger path, not reconcileOnce
        #expect(await waitFor { await MainActor.run { if case .observe? = r.state.lastError { return true } else { return false } } })
        #expect(await r.actuator.calls.isEmpty)
        let scansWhileDenied = box.i
        #expect(await waitFor { box.i > scansWhileDenied + 1 })      // it keeps retrying on its own while denied
        #expect(await r.actuator.calls.isEmpty)
        box.snaps = [FakeMenuBar.snapshot(order: ["A", "B", "C"].map(k), hidden: [])]   // the store becomes readable; the bar is identical
        #expect(await waitFor { await MainActor.run { r.state.lastError == nil } })
        #expect(await waitFor { await !r.actuator.calls.isEmpty })
    }

    @MainActor @Test func thePollRequestsAPassWhileTheStoreErrorIsSetEvenWithAnUnchangedBar() async {
        struct NoScans: SnapshotScanning {
            func scanVisible() async -> MenuBarSnapshot { MenuBarSnapshot(items: [], capturedAt: Date()) }
            func scan() async -> MenuBarSnapshot { MenuBarSnapshot(items: [], capturedAt: Date()) }
        }
        final class Hits: @unchecked Sendable { var n = 0 }
        let hits = Hits()
        let act = FakeActuator(order: [], hidden: [], capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        let state = EngineState()
        let engine = LayoutEngine(observer: FixtureObserver([[]]), actuator: act, store: InMemoryLayoutStore(.empty), capabilities: Caps(),
                                  state: state, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, config: .plain())
        let t = EngineTriggers(engine: engine, state: state, scanner: NoScans(), resolve: { FakeMenuBar.resolve($0) },
                               gate: { PollGate() }, trigger: { hits.n += 1 }, sleep: { _ in })
        await t.poll()
        #expect(hits.n == 0)
        state.lastError = .observe(ObserveError.trackedStoreMessage(denied))
        await t.poll()
        #expect(hits.n == 1)
    }

    @MainActor @Test func theObserverRefusesLayoutInitWithTheReason() async {
        let box = Scripted.Box([problemSnap(["A", "B"])])
        let o = AgreedScanObserver(scanner: Scripted(box: box), resolve: { FakeMenuBar.resolve($0) }, maxScans: 6, deadline: 15,
                                   accessibilityTrusted: { true }, sleep: { _ in })
        guard case .refuse(let m) = await LayoutInit.evaluate(observer: o) else { Issue.record("expected refusal"); return }
        #expect(m.contains("Cannot read Control Center's hidden-item list") && m.contains("not writing"))
    }
}

@MainActor @Suite struct ControlCenterDataPermissionTests {
    @Test func stateComesFromTheInjectedCheckerAndRequestReReads() {
        let fake = FakePermissionChecker()
        fake.setControlCenterData(.denied)
        let model = PermissionsModel(checker: fake)
        #expect(model.controlCenterData == .unknown)
        model.refresh()
        #expect(model.controlCenterData == .denied)
        #expect(!model.isReady == !(model.accessibility == .granted))   // never gates the Accessibility readiness
        fake.setControlCenterData(.granted)
        model.requestControlCenterData()
        #expect(fake.controlCenterDataRequests == 1 && model.controlCenterData == .granted)
        model.openSettings(.controlCenterData)
        #expect(fake.openedPanes == [.controlCenterData])
    }

    @Test func theBackgroundProbeIsSkippedWhileGrantedAndGrantedFiresOnce() {
        final class Counting: PermissionChecker, @unchecked Sendable {
            var probes = 0; var state = PermissionState.denied
            func accessibility(prompt: Bool) -> PermissionState { .granted }
            func screenRecording() -> PermissionState { .granted }
            func requestScreenRecording() {}
            func openSettings(_ pane: PermissionPane) {}
            func controlCenterData() -> PermissionState { probes += 1; return state }
            func requestControlCenterData() {}
        }
        let c = Counting()
        let model = PermissionsModel(checker: c)
        var fired = 0
        model.onControlCenterDataGranted = { fired += 1 }
        model.refresh(); model.refresh()
        #expect(c.probes == 2 && fired == 0)               // denied: probed on every tick
        c.state = .granted
        model.refresh()
        #expect(fired == 1 && c.probes == 3)
        model.refresh(); model.refresh()
        #expect(c.probes == 3 && fired == 1)               // granted: slowed to grantedProbeInterval
        model.requestControlCenterData()                    // an explicit request always re-probes
        #expect(c.probes == 4)
    }

    @Test func settingsURLOpensPrivacyAndSecurity() {
        #expect(LivePermissionChecker.settingsURL(for: .controlCenterData).absoluteString
                == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
    }
}
