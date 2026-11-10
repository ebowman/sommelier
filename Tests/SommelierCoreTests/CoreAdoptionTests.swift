import CoreGraphics
import Foundation
import Testing
import DecisionCore
@testable import SommelierCore

// sommelier-ejb.9: "Use the bar's current order". The decision is Lean's (`adoptProposal`, proved in lean/Sommelier/Adopt.lean); these tests drive the REAL
// scanner types (ObservedOrder -> ReadAdapter -> Read) into the exported function and check what the engine does with the adopted record.

private func key(_ n: Int) -> ItemKey { .status(ownerKey: "app.\(n)", autosaveName: "a\(n)") }
private let chevKey = ItemKey.status(ownerKey: "com.apple.menuextra.chevron", autosaveName: "chevron")

private func observed(bar: [Int], pile: [Int] = [], fresh: Bool = true) -> ObservedOrder {
    var o = ObservedOrder(onBar: bar.map(key) + [chevKey], parked: [], systemOverflow: Set(pile.map(key)), overflowChevron: fresh ? chevKey : nil)
    o.chevronAnyKey = chevKey; o.chevronPresent = true
    return o
}

/// (adapter output, interner) for a record of `key(n)`s against a bar.
private func adapted(_ o: ObservedOrder, record: [Int], kind: ReadKind = .pass) throws -> (AdaptedRead, CoreKeys) {
    var keys = CoreKeys()
    // settled: the pile of the previous complete read agrees (the adapter's rule); no running app owns a record key that is not on the bar (so it is absent, not unread)
    let a = try ReadAdapter.adapt(o, context: ReadContext(kind: kind, previousCompletePile: o.systemOverflow, ownerEvidence: OwnerEvidence(running: [])), record: record.map(key), keys: &keys)
    return (a, keys)
}

private func shown(_ record: [Key], _ read: Read) throws -> Verdict {
    try DecisionCore.shownVerdict(try DecisionState(record: record), read)
}

@Suite struct CoreAdoptionFunctionTests {
    /// Bar: 5 6 7 open, 1 2 behind the chevron (pile); record has them the other way round and an app (9) that is not running.
    @Test func proposesTheBarOrderThroughTheRealAdapter() throws {
        // the pile is hosted left of the open items: record [5,6,7,9,1,2] says open first, folded last
        let (a, keys) = try adapted(observed(bar: [1, 2, 5, 6, 7], pile: [1, 2]), record: [5, 6, 7, 9, 1, 2])
        #expect(try shown(a.record, a.read) == .differs)
        let p = try #require(CoreAdoption.proposal(record: [5, 6, 7, 9, 1, 2].map(key), read: a.read, keys: keys))
        // slots of {1,2,5,6,7} in the record are positions 0,1,2,4,5; refilled in the read's order (1,2 then 5,6,7); 9 stays at position 3
        #expect(p == [1, 2, 5, 9, 6, 7].map(key))
        #expect(p.sorted { $0.description < $1.description } == [5, 6, 7, 9, 1, 2].map(key).sorted { $0.description < $1.description })
        // feeding the same read with the adopted record: no longer differs; every key is pinned or unlisted-and-not-on-bar => matches
        let ids = p.compactMap { keys.id(for: $0) }
        #expect(try shown(ids, a.read) == .matches)
        // and the proposal for the adopted record is none
        #expect(CoreAdoption.proposal(record: p, read: a.read, keys: keys) == nil)
    }

    @Test func noProposalWhenTheRecordAlreadyMatches() throws {
        let (a, keys) = try adapted(observed(bar: [1, 2, 5, 6], pile: [1, 2]), record: [1, 2, 5, 6])
        #expect(try shown(a.record, a.read) == .matches)
        #expect(CoreAdoption.proposal(record: [1, 2, 5, 6].map(key), read: a.read, keys: keys) == nil)
    }

    @Test func noProposalOnAnUnusableRead() throws {
        // a poll read, a stale chevron and an unsettled read are never usable
        for mk in [{ (r: inout Read) in r.kind = .poll }, { (r: inout Read) in r.chevron = .stale }, { (r: inout Read) in r.settled = false },
                   { (r: inout Read) in r.level = .incomplete }, { (r: inout Read) in r.stripOpen = true }] as [(inout Read) -> Void] {
            let (a, keys) = try adapted(observed(bar: [1, 2, 5, 6], pile: [1, 2]), record: [5, 6, 1, 2])
            var r = a.read; mk(&r)
            #expect(CoreAdoption.proposal(record: [5, 6, 1, 2].map(key), read: r, keys: keys) == nil)
        }
    }

    @Test func unreadKeysAreSetAsideAndTheVerdictIsHonest() throws {
        // key 8 is on the bar but the scan could not read it (unread): it stays in its slot; the adopted record is matchesExcept [8], never differs
        var o = observed(bar: [1, 2, 5, 6, 8], pile: [1, 2])
        o.placementUnknown = [key(8)]
        let (a, keys) = try adapted(o, record: [5, 8, 6, 1, 2])
        #expect(a.read.unread.contains(keys.id(for: key(8))!))
        let p = try #require(CoreAdoption.proposal(record: [5, 8, 6, 1, 2].map(key), read: a.read, keys: keys))
        #expect(p[1] == key(8), "an unread key keeps its slot")
        let v = try shown(p.compactMap { keys.id(for: $0) }, a.read)
        #expect(v != .differs)
        if case .matchesExcept(let u) = v { #expect(u == [keys.id(for: key(8))!]) } else { #expect(v == .matches) }
    }

    // MARK: the user's real bar (read-only fixture)

    @Test func theRealBarProposalMatchesOnTheNextReading() throws {
        let bar = try loadBar()
        let scan = try #require(bar.scans.first { $0.file == "list1.json" })
        let (a, keys) = try realRead(bar, scan)
        let rec = a.record.compactMap { keys.key(for: $0) }
        let drawn = a.read.trusted.compactMap { keys.key(for: $0) }
        let pile = a.read.pile.compactMap { keys.key(for: $0) }
        #expect(drawn.count >= 3 && pile.count >= 3, "the fixture bar has open and folded keys")
        // a record that disagrees with the bar: two folded keys out of turn (after the open keys) and two open keys swapped
        var wrong = rec
        let slots = wrong.indices.filter { drawn.contains(wrong[$0]) || pile.contains(wrong[$0]) }
        var onBar = slots.map { wrong[$0] }
        onBar = onBar.filter { !pile.contains($0) } + onBar.filter { pile.contains($0) }.reversed()   // folded keys after the open keys, reversed
        if let i = onBar.indices.first(where: { drawn.contains(onBar[$0]) }), let j = onBar.indices.dropFirst(i + 1).first(where: { drawn.contains(onBar[$0]) }) { onBar.swapAt(i, j) }
        for (s, k) in zip(slots, onBar) { wrong[s] = k }
        #expect(wrong != rec)
        let wrongIDs = wrong.compactMap { keys.id(for: $0) }
        #expect(try shown(wrongIDs, a.read) == .differs, "the disagreeing record differs from the real bar")
        let p = try #require(CoreAdoption.proposal(record: wrong, read: a.read, keys: keys))
        #expect(Set(p) == Set(wrong) && p.count == wrong.count, "a permutation: no key gained or lost")
        // not on the bar (absent or unread) keep their slots
        let pinned = Set(drawn + pile)
        for (i, k) in wrong.enumerated() where !pinned.contains(k) { #expect(p[i] == k, "off-bar key \(k) must not move") }
        // the on-bar part reads folded keys then open keys, in the read's order
        #expect(p.filter { pinned.contains($0) } == pile.filter { wrong.contains($0) } + drawn.filter { wrong.contains($0) })
        // the same read with the adopted record
        let v = try shown(p.compactMap { keys.id(for: $0) }, a.read)
        switch v {
        case .matches: break
        case .matchesExcept(let u): #expect(!u.isEmpty && u.allSatisfy { a.read.unread.contains($0) }, "only unread keys are set aside")
        default: Issue.record("the adopted record must match the bar it was adopted from, got \(v)")
        }
        print("REALBAR adopt: record \(wrong.count), on-bar \(pinned.intersection(Set(wrong)).count), moved \(zip(wrong, p).filter { $0 != $1 }.count), verdict after \(v)")
    }
}

@Suite struct CoreAdoptionPreviewTests {
    @Test func previewRefillsTheSlotsAndLeavesOtherKeysAlone() throws {
        // Visible has a key that is not in the core's record (an immovable module) and a key the layout has twice-listed never happens; the module keeps its place
        let module = ItemKey.status(ownerKey: "com.apple.menuextra.clock", autosaveName: "clock")
        let layout = Layout.placedAll(visible: [key(1), module, key(2), key(3)])
        let pv = try #require(CoreAdoption.preview(proposal: [key(3), key(1), key(2)], layout: layout))
        #expect(pv.after == [key(3), module, key(1), key(2)])
        #expect(pv.layout.visible == pv.after && pv.layout.hidden == layout.hidden && pv.layout.alwaysHidden == layout.alwaysHidden)
        #expect(pv.changes.map(\.key) == [key(3), key(1), key(2)])
        #expect(pv.changes.first == CoreAdoption.Change(key: key(3), from: 4, to: 1))
    }
    @Test func previewRefusesAStaleProposalOrNoChange() {
        let layout = Layout.placedAll(visible: [key(1), key(2)])
        #expect(CoreAdoption.preview(proposal: nil, layout: layout) == nil)
        #expect(CoreAdoption.preview(proposal: [key(1), key(2)], layout: layout) == nil, "nothing changes")
        #expect(CoreAdoption.preview(proposal: [key(2), key(7)], layout: layout) == nil, "a proposed key left Visible")
        #expect(CoreAdoption.preview(proposal: [key(2), key(2)], layout: layout) == nil)
    }
}

// MARK: the engine: adopting causes no drags

private struct OpenCaps: CapabilityProvider { func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) } }
private struct ActuatorObserver: MenuBarObserver {
    let actuator: FakeActuator
    func observe() async throws -> [ResolvedItem] { FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden)) }
}
private func ek(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }

@MainActor
@Suite struct CoreAdoptionEngineTests {
    @Test func adoptingTheBarOrderMakesNoDragsAndTheNextPassesMatch() async throws {
        let bar = ["D", "C", "B", "A"], record = ["A", "B", "C", "D"]
        let act = FakeActuator(order: bar.map(ek), hidden: [], capabilities: OpenCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        for n in 1...40 { await act.failOnCall(n, .mechanismFailed("boom")) }   // the drags fail, so the bar stays as it is and the record differs
        var c = LayoutEngine.Config.plain()
        c.recordCoreTrace = true; c.minPassInterval = .zero; c.layoutCoalesce = .zero; c.interactionRetry = .seconds(3600); c.maxOrderMovesPerPass = .max
        let state = EngineState()
        let engine = LayoutEngine(observer: ActuatorObserver(actuator: act), actuator: act, store: InMemoryLayoutStore(Layout.placedAll(visible: record.map(ek))), capabilities: OpenCaps(),
                                  state: state, interaction: nil, resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { _ in }, config: c)
        await engine.start()
        for _ in 0..<4 { _ = await engine.reconcileOnce() }   // a chevronless bar is believed after three complete reads in a row (D1)
        let shownDisplay = await engine.coreDisplayForTests()
        let proposal = try #require(shownDisplay?.adoption, "the core says differs, so the button is offered")
        #expect(proposal == bar.map(ek))
        let preview = try #require(CoreAdoption.preview(proposal: proposal, layout: state.layout))
        #expect(preview.layout.visible == bar.map(ek))

        let before = await act.calls.count
        // Save: the normal record-saving path
        _ = await engine.setLayout(preview.layout, basedOn: state.layoutRevision, moved: [])
        for _ in 0..<4 { _ = await engine.reconcileOnce() }
        let after = await act.calls, finalOrder = await act.order
        #expect(after.count == before, "adopting the bar's own order must cause no drags: \(after.dropFirst(before))")
        #expect(finalOrder == bar.map(ek))
        #expect(state.layout.visible == bar.map(ek))
        let finalDisplay = await engine.coreDisplayForTests()
        #expect(finalDisplay?.status == .matches, "the next passes find the bar matching, got \(String(describing: finalDisplay?.status))")
        #expect(finalDisplay?.adoption == nil, "nothing left to adopt")
    }
}

// MARK: real-bar fixture (read-only)

private struct RealBar: Decodable {
    struct Item: Decodable { var key: String; var bundle: String; var name: String; var pid: Int32; var onBar: Bool; var cc: Bool?; var source: String; var stale: Bool
        var overflow: Bool; var x: Double; var w: Double; var join: String; var desc: String; var title: String }
    struct Scan: Decodable { var file: String; var completeness: String; var items: [Item] }
    struct App: Decodable { var pid: Int32; var bundle: String?; var name: String; var presented: Int }
    struct CC: Decodable { var allowed: Bool; var names: [String] }
    var scans: [Scan]; var running: [App]; var families: [[String]]; var ccEntries: [CC]
}

private func loadBar() throws -> RealBar {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/realbar.json")
    return try JSONDecoder().decode(RealBar.self, from: Data(contentsOf: url))
}

private func scannerItem(_ key: ItemKey, pid: pid_t, bundle: String?, name: String, x: CGFloat, onBar: Bool, stale: Bool = false,
                         overflow: Bool = false, corroborated: Bool = true, allowed: Bool? = true, hidden: Bool = false,
                         chevron: Bool = false, width: CGFloat = 24, hostedOnly: Bool = false) -> ResolvedItem {
    var it = MenuBarItem(ownerPID: pid, ownerBundleID: bundle, ownerName: name, title: "", axDescription: "", axIdentifier: corroborated ? "id.\(key.description)" : "",
                         frame: CGRect(x: onBar ? x : -1000, y: 0, width: width, height: 24), source: hostedOnly ? .agentHostedOnly : .appExtras, isOnMenuBar: onBar,
                         isOverflowChevron: chevron, systemOverflow: overflow, joinEvidence: corroborated ? .identifier : .none)
    it.stale = stale; it.controlCenterAllowed = allowed; it.hiddenInControlCenter = hidden
    return ResolvedItem(item: it, key: key, confidence: .exact)
}

/// The adapter's read of one fixture scan, the way `ReadAdapterTests` builds it (record = the shown non-module keys, parked keys, and one synthetic key per Control Center entry no shown key belongs to).
private func realRead(_ bar: RealBar, _ scan: RealBar.Scan) throws -> (AdaptedRead, CoreKeys) {
    let level: ReadCompleteness = scan.completeness == "complete" ? .complete : (scan.completeness == "exceptSelfPositioning" ? .completeExceptSelfPositioning : .incomplete)
    let caps = CapabilityRules(hasTrackedEntry: { _ in true })
    let resolved: [ResolvedItem] = scan.items.compactMap { i in
        guard let key = ItemKey(storeKey: i.key) else { return nil }
        return scannerItem(key, pid: i.pid, bundle: i.bundle, name: i.name, x: CGFloat(i.x), onBar: i.onBar, stale: i.stale, overflow: i.overflow,
                           corroborated: i.join != "none", allowed: i.cc, hidden: i.cc == false && !i.onBar, chevron: i.desc == "Show Hidden Menu Bar Items",
                           width: CGFloat(i.w), hostedOnly: i.source == "agentHostedOnly")
    }
    let order = ObservedOrder(resolved: resolved)
    var record = order.onBar.filter { if case .module = $0 { return false } else { return true } } + order.parked
    for e in bar.ccEntries {
        let lower = Set(e.names.map { $0.lowercased() })
        if record.contains(where: { ArrangeSections.ownerBundleID($0).map { lower.contains($0.lowercased()) } ?? false }) { continue }
        record.append(ItemKey.status(ownerKey: e.names[0], autosaveName: "Item-0"))
    }
    var running: [UnreadOwner] = bar.running.map { a in
        let shown = resolved.filter { $0.item.ownerPID == a.pid }.compactMap { ArrangeSections.ownerBundleID($0.key) }
        return UnreadOwner(pid: a.pid, bundleID: a.bundle, name: a.name, ownerKeys: Array(Set([a.bundle].compactMap { $0 } + shown)))
    }
    if let m = resolved.first(where: { $0.key.description.hasPrefix("module:") }), !running.contains(where: { $0.pid == m.item.ownerPID }) {
        running.append(UnreadOwner(pid: m.item.ownerPID, bundleID: menuBarAgentBundleID, name: "MenuBarAgent", ownerKeys: [menuBarAgentBundleID]))
    }
    let ev = OwnerEvidence(running: running)
    var info: [ItemKey: ItemInfo] = [:]
    for r in resolved { info[r.key] = ItemInfo(key: r.key, title: r.item.title, axDescription: r.item.axDescription, ownerPID: r.item.ownerPID, ownerBundleID: r.item.ownerBundleID, ownerName: r.item.ownerName, width: r.item.frame.width, isOnBar: r.item.isOnMenuBar) }
    let immovable = Set(resolved.map(\.key).filter { !caps.capability(for: $0).canMove })
    var keys = CoreKeys()
    let ad = try ReadAdapter.adapt(order, context: ReadContext(kind: .pass, settled: true, level: level, observed: true, previousCompletePile: order.systemOverflow, immovable: immovable, ownerEvidence: ev, itemInfo: info, ownerFamilies: bar.families), record: record, keys: &keys)
    return (ad, keys)
}

/// ejb.29: Save re-checks the proposal against the bar as it is NOW.
@Suite struct CoreAdoptionConfirmTests {
    private func preview(_ order: [Int]) throws -> CoreAdoption.Preview {
        let layout = Layout(visible: [1, 2, 3].map { ItemKey.module(name: "k\($0)") })
        return try #require(CoreAdoption.preview(proposal: order.map { ItemKey.module(name: "k\($0)") }, layout: layout))
    }
    @Test func theSameProposalSaves() throws {
        let p = try preview([3, 1, 2])
        #expect(CoreAdoption.confirm(shown: p, current: try preview([3, 1, 2])) == .save)
    }
    @Test func aDifferentProposalRefreshesTheSheetAndSavesNothing() throws {
        let shown = try preview([3, 1, 2]), now = try preview([2, 1, 3])
        #expect(CoreAdoption.confirm(shown: shown, current: now) == .refresh(now))
    }
    @Test func noProposalAnyMoreCancelsWithTheOneLineMessage() throws {
        #expect(CoreAdoption.confirm(shown: try preview([3, 1, 2]), current: nil) == .cancel("The menu bar changed; review the new order."))
    }
}
