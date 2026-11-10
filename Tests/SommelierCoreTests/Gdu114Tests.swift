import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

/// gdu.114 (2026-11-06 10:13): three unnamed MenuBarAgent-hosted elements at y=183 (16x16, far below the bar) became
/// `heuristic:com.apple.MenuBarAgent::#N` keys, were appended Visible and "shown" every pass (Control Center had no entry).
private struct HostSrc: AccessibilitySource {
    var currentPID: pid_t = 1
    var apps: [RunningAppInfo] = []
    var tree: AgentHostedTree
    func runningApps() -> [RunningAppInfo] { apps }
    func extrasItems(for app: RunningAppInfo) -> [AXElementInfo] { [] }
    func readExtras(for app: RunningAppInfo, timeout: Float?) -> ExtrasRead { .items([]) }
    func agentHostedTree(for agent: RunningAppInfo) -> AgentHostedTree { tree }
}

@Suite struct Gdu114ScannerTests {
    let strip = CGRect(x: 0, y: 0, width: 2000, height: 30)

    @Test func thePredicateDropsOnlyUnnamedElementsOffTheStrip() {
        let off = CGRect(x: 542, y: 175, width: 16, height: 16)
        let on = CGRect(x: 542, y: 4, width: 16, height: 22)
        #expect(MenuBarScanner.isOffBarNoise(frame: off, identifier: "", description: "", strip: strip))
        #expect(!MenuBarScanner.isOffBarNoise(frame: on, identifier: "", description: "", strip: strip))
        #expect(!MenuBarScanner.isOffBarNoise(frame: off, identifier: "x", description: "", strip: strip))
        #expect(!MenuBarScanner.isOffBarNoise(frame: off, identifier: "", description: "Wi-Fi", strip: strip))
    }

    @Test func aScanEmitsNoItemForAnOffBarUnnamedHostedElement() {
        let agent = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
        let tree = AgentHostedTree(stripFrame: strip, elements: [
            AXElementInfo(frame: CGRect(x: 542, y: 175, width: 16, height: 16)),
            AXElementInfo(frame: CGRect(x: 565, y: 175, width: 16, height: 16)),
            AXElementInfo(frame: CGRect(x: 800, y: 4, width: 22, height: 22)),
            AXElementInfo(axDescription: "Clock", frame: CGRect(x: 1500, y: 4, width: 40, height: 22)),
        ])
        var sc = MenuBarScanner(source: HostSrc(apps: [agent], tree: tree))
        sc.trackedEntries = { .notConfigured }
        let snap = sc.scan()
        let hosted = snap.items.filter { $0.source == .agentHostedOnly }
        #expect(hosted.count == 2)
        #expect(hosted.allSatisfy { $0.frame.midY < 30 })
    }
}

@Suite struct Gdu114LayoutTests {
    @Test func pruneRemovesOnlyEmptyFingerprintAgentHeuristics() {
        let j0 = ItemKey.heuristic(bundleID: "com.apple.MenuBarAgent", fingerprint: "", ordinal: 0)
        let j3 = ItemKey.heuristic(bundleID: "com.apple.MenuBarAgent", fingerprint: "", ordinal: 3)
        let real = ItemKey.heuristic(bundleID: "org.signal", fingerprint: "Signal #", ordinal: 0)
        let agentNamed = ItemKey.heuristic(bundleID: "com.apple.MenuBarAgent", fingerprint: "x", ordinal: 0)
        let st = ItemKey.status(ownerKey: "com.x.A", autosaveName: "A")
        let mod = ItemKey.module(name: "Clock")
        let l = Layout(visible: [j0, st, real, j3], hidden: [mod, j3, agentNamed], alwaysHidden: [j0])
        let (out, removed) = l.prunedAgentNoise()
        #expect(out.visible == [st, real])
        #expect(out.hidden == [mod, agentNamed])
        #expect(out.alwaysHidden.isEmpty)
        #expect(removed.count == 4)
        let (again, none) = out.prunedAgentNoise()
        #expect(again == out && none.isEmpty)
    }
}

private func kk(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private struct Caps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
}
private struct Obs: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] {
        FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden))
    }
}
private final class Log: @unchecked Sendable {
    private let l = NSLock(); private var v: [String] = []
    func add(_ s: String) { l.lock(); v.append(s); l.unlock() }
    var all: [String] { l.lock(); defer { l.unlock() }; return v }
}

@MainActor
@Suite struct Gdu114EngineTests {
    @Test func aShowOfAKeyWithNoControlCenterEntryIsRefusedOnceAndTheNextPassConverges() async {
        let act = FakeActuator(order: [kk("A"), kk("C")], hidden: [kk("C")], capabilities: Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        var cfg = LayoutEngine.Config.plain()
        cfg.layoutCoalesce = .zero
        cfg.trackedResolver = { TrackedEntryResolver(entries: [.init(key: "com.x.A", isAllowed: true, menuItemKeys: ["com.x.A"])]) }
        cfg.trackedAllowed = { _ in true }
        let state = EngineState(); let lines = Log()
        let e = LayoutEngine(observer: Obs(actuator: act), actuator: act, store: InMemoryLayoutStore(Layout(visible: [kk("A"), kk("C")])), capabilities: Caps(), state: state,
                             resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { lines.add($0) }, config: cfg)
        await e.start()
        _ = await e.reconcileOnce()
        #expect(await act.calls.isEmpty)
        #expect(!lines.all.contains { $0.contains("membership write: show") })
        #expect(lines.all.contains { $0.contains("refusing show of") && $0.contains("no Control Center entry") })
        if case .unsupported(let why)? = state.perItem[kk("C")] { #expect(why.contains("no Control Center entry")) }
        else { Issue.record("expected unsupported, got \(String(describing: state.perItem[kk("C")]))") }
        let before = lines.all.filter { $0.contains("refusing show of") }.count
        let r = await e.reconcileOnce()
        #expect(r.outcome == .converged)
        #expect(lines.all.filter { $0.contains("refusing show of") }.count == before)
    }
}
