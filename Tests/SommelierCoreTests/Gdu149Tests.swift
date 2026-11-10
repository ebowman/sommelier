import Foundation
import Testing
@testable import SommelierCore

// gdu.149 (live incident): reordering ONE item inside a section moved its app's whole hide unit and dragged every sibling. A drop inside
// the section the key already sits in moves that key alone (`moved == [key]`); the unit travels together only on a membership change.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
/// iStat Menus: nine keys, one owner, therefore one hide unit.
private func ist(_ n: String) -> ItemKey { .status(ownerKey: "com.bjango.istatmenus", autosaveName: n) }
private let iNames = ["Net", "Sens", "Batt", "Mem", "Disks", "CPU", "Weather", "Time", "WiFi"]

/// The live record (shape of the 2026-11-10 incident): iStat keys interleaved with other apps.
private let liveOrder: [ItemKey] = [k("TM"), ist("Net"), ist("Sens"), k("Astro"), k("MicCam"), ist("Batt"), ist("Mem"), ist("Disks"), ist("WiFi"),
                                    k("Focus"), k("KYA"), k("Jump"), k("Signal"), ist("CPU"), ist("Weather"), k("CC"), k("Gate"), k("MCP"),
                                    k("VPN"), k("Flo"), ist("Time")]

private struct Caps149: CapabilityProvider {
    func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
}
private func caps(_ key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }

private struct Obs149: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] {
        FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden))
    }
}
private final class Lines149: @unchecked Sendable {
    private let l = NSLock(); private var v: [String] = []
    func add(_ s: String) { l.lock(); v.append(s); l.unlock() }
    var all: [String] { l.lock(); defer { l.unlock() }; return v }
}

private func drop(_ l: Layout, _ key: ItemKey, _ s: LayoutSection, _ idx: Int?) -> (Layout, [ItemKey])? {
    if case .move(let n, let m, _) = ArrangeDrop.outcome(layout: l, key: key, to: s, index: idx, capabilities: caps) { return (n, m) }
    return nil
}

@MainActor
private func rig(_ record: Layout, bar: [ItemKey]) async -> (engine: LayoutEngine, act: FakeActuator, lines: Lines149) {
    let act = FakeActuator(order: bar, hidden: [], capabilities: Caps149(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
    var cfg = LayoutEngine.Config.plain()
    cfg.layoutCoalesce = .zero
    let lines = Lines149()
    let engine = LayoutEngine(observer: Obs149(actuator: act), actuator: act, store: InMemoryLayoutStore(record), capabilities: Caps149(),
                              state: EngineState(), resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { lines.add($0) }, config: cfg)
    await engine.start()
    return (engine, act, lines)
}

@MainActor
@Suite struct ReorderMovesOnlyTheDroppedKeyTests {
    @Test func liveScenarioDropMemoryAtSlot5ChangesOnlyMemory() {
        let old = Layout(visible: liveOrder)
        let (n, moved) = drop(old, ist("Mem"), .visible, 5)!
        var expected = liveOrder; expected.remove(at: 6); expected.insert(ist("Mem"), at: 5)
        #expect(n.visible == expected)
        #expect(moved == [ist("Mem")])
        #expect(n.hidden.isEmpty && n.alwaysHidden.isEmpty)
    }

    @Test func engineMakesExactlyOneDragAndNeverATouchesASibling() async {
        let old = Layout(visible: liveOrder)
        let (n, moved) = drop(old, ist("Mem"), .visible, 5)!
        let r = await rig(old, bar: liveOrder)
        _ = await r.engine.setLayout(n, moved: Set(moved))
        for _ in 0..<8 { _ = await r.engine.reconcileOnce() }
        let moves = await r.act.calls.compactMap { if case .move(let key, _) = $0 { key } else { nil } }
        #expect(moves == [ist("Mem")])
        #expect(r.lines.all.contains { $0.contains("setLayout: user moved") && $0.contains(ist("Mem").description) })
        #expect(await r.act.order.filter { liveOrder.contains($0) }.count == liveOrder.count)
    }

    @Test func sameSectionReorderInHiddenMovesOneKeyAndChangesNoMembership() async {
        let hid = [ist("Net"), k("H1"), ist("Mem"), k("H2"), ist("CPU")]
        let old = Layout(visible: [k("TM"), k("A")], hidden: hid)
        let (n, moved) = drop(old, ist("Mem"), .hidden, 0)!
        #expect(moved == [ist("Mem")])
        #expect(n.hidden == [ist("Mem"), ist("Net"), k("H1"), k("H2"), ist("CPU")])
        #expect(n.visible == old.visible && n.alwaysHidden.isEmpty)
        let (a, am) = drop(Layout(visible: [k("TM")], alwaysHidden: hid), ist("Net"), .alwaysHidden, nil)!
        #expect(am == [ist("Net")] && a.alwaysHidden == [k("H1"), ist("Mem"), k("H2"), ist("CPU"), ist("Net")])
        // membership untouched in the engine: the backstop keeps the named key, no hidden-batch is issued for a Hidden reorder
        let r = await rig(old, bar: [k("TM"), k("A")])
        _ = await r.engine.setLayout(n, moved: Set(moved))
        for _ in 0..<3 { _ = await r.engine.reconcileOnce() }
        let batches = await r.act.calls.filter { if case .applyHiddenBatch = $0 { true } else { false } }
        #expect(batches.isEmpty)
    }

    @Test func crossSectionDropMovesTheUnitTogetherButReportsOnlyTheDroppedKey() async {
        let old = Layout(visible: liveOrder)
        let (n, moved) = drop(old, ist("Mem"), .hidden, nil)!
        #expect(moved == [ist("Mem")])
        #expect(Set(n.hidden) == Set(iNames.map(ist)) && n.hidden.first == ist("Mem"))
        #expect(n.visible == liveOrder.filter { !iNames.map(ist).contains($0) })
        let r = await rig(old, bar: liveOrder)
        _ = await r.engine.setLayout(n, moved: Set(moved))
        for _ in 0..<4 { _ = await r.engine.reconcileOnce() }
        var hiddenByEngine = Set<ItemKey>()
        for case .applyHiddenBatch(let ch) in await r.act.calls { for (key, h) in ch where h { hiddenByEngine.insert(key) } }
        for case .setHidden(let key, true) in await r.act.calls { hiddenByEngine.insert(key) }
        #expect(hiddenByEngine == Set(iNames.map(ist)))
    }

    @Test func backstopDropsKeysThatDidNotMoveAndKeepsAnUnchangedShowRequest() {
        let old = Layout(visible: [k("A"), ist("x"), ist("y"), k("B")])
        let new = Layout(visible: [k("A"), ist("y"), k("B"), ist("x")])
        // the caller names the whole unit; only the pair that really changed place relative to something counts, and a key that kept its place does not
        let named: Set<ItemKey> = [ist("x"), k("A")]
        #expect(LayoutEngine.effectiveUserMoved(named: named, old: old, new: new) == [ist("x")])
        #expect(LayoutEngine.effectiveUserMoved(named: [k("A")], old: old, new: old) == [k("A")])
        let hid = Layout(visible: [k("A")], hidden: [ist("x"), ist("y")])
        #expect(LayoutEngine.effectiveUserMoved(named: [ist("x"), ist("y")], old: old, new: hid) == [ist("x"), ist("y")])
    }

    /// Property: random layouts with multi-key owners, random same-section drops: exactly the dropped key's relative order changes.
    @Test func randomSameSectionDropsChangeExactlyOneKeysRelativeOrder() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let count = Int.random(in: 4...16, using: &rng)
            let keys: [ItemKey] = (0..<count).map { i in Bool.random(using: &rng) ? ist("i\(i)") : (Bool.random(using: &rng) ? .status(ownerKey: "com.o\(i % 3)", autosaveName: "m\(i)") : k("s\(i)")) }
            var buckets: [[ItemKey]] = [[], [], []]
            for key in keys { buckets[Int.random(in: 0...2, using: &rng)].append(key) }
            let l = Layout(visible: buckets[0], hidden: buckets[1], alwaysHidden: buckets[2])
            guard let key = keys.randomElement(using: &rng), let s = l.section(of: key) else { continue }
            let n = l.keys(in: s).count
            guard let (new, moved) = drop(l, key, s, Int.random(in: 0...n, using: &rng)) else { continue }
            #expect(moved == [key])
            for sec in LayoutSection.allCases { #expect(Set(new.keys(in: sec)) == Set(l.keys(in: sec))) }
            let o = l.keys(in: s).filter { $0 != key }, nw = new.keys(in: s).filter { $0 != key }
            #expect(o == nw)   // every other key keeps its relative order
        }
    }
}
