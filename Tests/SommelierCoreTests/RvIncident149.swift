// ported (unchanged apart from this header) from the independent reviewer's gdu.149 suite: ejb.32 runs it through the Lean gesture path.
import Foundation
import Testing
@testable import SommelierCore

func rv9k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
func rv9i(_ n: String) -> ItemKey { .status(ownerKey: "com.bjango.istatmenus", autosaveName: n) }
func rv9m(_ n: String) -> ItemKey { .module(name: n) }
struct Rv9Caps: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability {
        if case .module = key { return Capability(canMove: false, canHide: false, reason: "system module") }
        return Capability(canMove: true, canHide: true)
    }
}
func rv9cap(_ key: ItemKey) -> Capability { Rv9Caps().capability(for: key) }
struct Rv9Obs: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] { FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden)) }
}
final class Rv9Lines: @unchecked Sendable { private let l = NSLock(); private var v: [String] = []
    func add(_ s: String) { l.lock(); v.append(s); l.unlock() }; var all: [String] { l.lock(); defer { l.unlock() }; return v } }
final class Rv9Clock: @unchecked Sendable { private let l = NSLock(); private var t = Date(timeIntervalSince1970: 9000)
    func read() -> Date { l.lock(); defer { l.unlock() }; return t }; func adv(_ s: TimeInterval) { l.lock(); t = t.addingTimeInterval(s); l.unlock() } }
func rv9info(_ key: ItemKey) -> ItemInfo { ItemInfo(key: key, title: "\(key)", axDescription: "", ownerPID: 1, ownerBundleID: nil, ownerName: "x", width: 24, isOnBar: true) }

let rv9Live: [ItemKey] = [rv9k("TimeMachine"), rv9i("Network"), rv9i("Sensors"), rv9k("Astronomy"), rv9m("MicCamera"), rv9i("Battery"), rv9i("Memory"),
    rv9i("Disks"), rv9m("WiFi"), rv9m("Focus"), rv9k("KYA"), rv9k("Jump"), rv9k("WiFiSignal"), rv9i("CPU"), rv9i("Weather"), rv9k("ControlCenterApp"),
    rv9k("GateOpener"), rv9k("MCPMaestro"), rv9k("VPNSwitch"), rv9k("FloTile"), rv9i("Time"), rv9m("com.apple.menuextra.controlcenter"), rv9m("Clock")]

@MainActor func rv9engine(record: Layout, bar: [ItemKey], hidden: Set<ItemKey> = []) async -> (LayoutEngine, FakeActuator, Rv9Lines, Rv9Clock, EngineState) {
    let act = FakeActuator(order: bar, hidden: hidden, capabilities: Rv9Caps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    let clock = Rv9Clock()
    var cfg = LayoutEngine.Config(); cfg.assumeFullBarAtLaunch = false; cfg.layoutCoalesce = .zero; cfg.now = { clock.read() }
    let lines = Rv9Lines(); let st = EngineState()
    let e = LayoutEngine(observer: Rv9Obs(actuator: act), actuator: act, store: InMemoryLayoutStore(record), capabilities: Rv9Caps(),
                         state: st, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { lines.add($0) }, config: cfg)
    await e.start()
    return (e, act, lines, clock, st)
}

@MainActor @Suite struct Rv149Incident {
    @Test func liveIncidentViaUIRowsSlot5() async {
        let old = Layout(visible: rv9Live)
        let c = ArrangeSections.make(observed: ObservedOrder(onBar: rv9Live, parked: []), layout: old,
                                     items: Dictionary(uniqueKeysWithValues: rv9Live.map { ($0, rv9info($0)) }), perItem: [:], capabilities: rv9cap)
        let rows = c.visible.rows
        print("RV149 rows: \(rows.map { "\($0.key)" })")
        guard case .move(let n, let moved, _) = ArrangeDrop.drop(layout: old, rows: rows, slot: 5, key: rv9i("Memory"), section: .visible, capabilities: rv9cap) else { Issue.record("no move"); return }
        print("RV149 moved=\(moved)")
        print("RV149 newVisible=\(n.visible)")
        var exp = rv9Live; exp.removeAll { $0 == rv9i("Memory") }; exp.insert(rv9i("Memory"), at: 5)
        #expect(n.visible == exp)
        let (e, act, lines, clock, _) = await rv9engine(record: old, bar: rv9Live)
        _ = await e.setLayout(n, basedOn: nil, moved: Set(moved))
        for _ in 0..<10 { _ = await e.reconcileOnce(); clock.adv(20) }
        let moves = await act.calls.compactMap { if case .move(let k, let r) = $0 { "\(k) \(r)" } else { nil } }
        print("RV149 MOVES (\(moves.count)): \(moves)")
        let other = await act.calls.filter { if case .move = $0 { return false }; return true }
        print("RV149 OTHER CALLS: \(other.count)")
        print("RV149 final bar=\(await act.order)")
        for l in lines.all where l.contains("user moved") || l.contains("Moving") || l.contains("hide unit") || l.contains("all items governed") { print("RV149 LOG: \(l)") }
        #expect(moves.count == 1)
    }
}
