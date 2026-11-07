import Foundation
import Testing
@testable import SommelierCore

// gdu.119: a Visible drop onto the item's own slot resolves at once, records the intent neighbours, and never shows the item twice.
@Suite struct NoopDropTests {
    private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: "Item-0") }
    private let chev = ItemKey.module(name: "Show Hidden Menu Bar Items")
    private func caps(_ key: ItemKey) -> Capability {
        if case .module = key { return Capability(canMove: false, canHide: false, reason: "system module") }
        return Capability(canMove: true, canHide: true)
    }
    private func info(_ key: ItemKey) -> ItemInfo {
        ItemInfo(key: key, title: "", axDescription: "\(key)", ownerPID: 1, ownerBundleID: "com.x", ownerName: "Owner", width: 30, isOnBar: true, systemOverflow: false)
    }

    // The live rows: bar ControlCenter, Shield, MCP Maestro, FloTile; the saved layout lists the chevron module right after Shield.
    private var cc: ItemKey { k("cc") }
    private var shield: ItemKey { k("shield") }
    private var mcp: ItemKey { k("mcp") }
    private var flo: ItemKey { k("flo") }
    private var bar: [ItemKey] { [cc, shield, mcp, flo] }
    private var layoutOld: Layout { Layout(visible: [cc, shield, chev, mcp, flo], placed: [], orderMode: .placedOnly) }

    private func rows(_ layout: Layout, awaiting: Set<ItemKey> = []) -> [ArrangeRow] {
        ArrangeSections.make(observed: ObservedOrder(onBar: bar, parked: []), layout: layout, items: Dictionary(uniqueKeysWithValues: bar.map { ($0, info($0)) }),
                             perItem: [:], capabilities: caps, awaiting: awaiting).visible.rows
    }

    @Test func intentNeighboursMatchingTheBarResolveOnFirstObservation() {
        let r = rows(layoutOld)
        let slot = r.firstIndex { $0.key == shield }! + 1   // the gap right after Shield
        let intent = DropIntent.from(rows: r, slot: slot, key: shield)
        #expect(intent.left == cc && intent.right == mcp)
        var t = ArrangeTracker()
        let now = Date()
        // A layout whose whole drawn order disagrees with the bar (MCP before ControlCenter): the whole-order check can never pass.
        let skewed = Layout(visible: [mcp, cc, shield, chev, flo], placed: [shield], orderMode: .placedOnly)
        t.record([shield], passesStarted: 5, now: now, awaitingStamp: true, dropID: 17, intent: intent)
        let log = t.update(observed: ObservedOrder(onBar: bar, parked: []), layout: skewed, perItem: [shield: .inPlace], passSequence: 5,
                           showHiddenSection: false, now: now)
        #expect(t.isEmpty)
        #expect(t.timedOut.isEmpty)
        #expect(log.count == 1 && log[0].hasPrefix("drop#17 done: applied") && log[0].contains("final: between"))
    }

    @Test func intentNotMatchingKeepsWaiting() {
        let intent = DropIntent(key: shield, left: cc, right: flo)
        var t = ArrangeTracker()
        let now = Date()
        t.record([shield], passesStarted: 5, now: now, awaitingStamp: false, dropID: 3, intent: intent)
        let log = t.update(observed: ObservedOrder(onBar: bar, parked: []), layout: layoutOld, perItem: [:], passSequence: 5, showHiddenSection: false, now: now)
        #expect(log.isEmpty && !t.isEmpty)
    }

    @Test func layoutAnchorIsTheDropNeighboursNotTheChevronModule() {
        // Layout lists the chevron module after ControlCenter and MCP behind it; dropping Shield between ControlCenter and MCP.
        let layout = Layout(visible: [cc, chev, mcp, flo], placed: [], orderMode: .placedOnly)
        let r = rows(layout)
        let slot = r.firstIndex { $0.key == mcp }!
        let idx = ArrangeDrop.index(layout: layout, rows: r, slot: slot, key: shield, section: .visible)
        #expect(idx == 2)   // directly before MCP Maestro in the lifted section [cc, chev, mcp, flo]
        guard case .move(let l, _, _) = ArrangeDrop.outcome(layout: layout, key: shield, to: .visible, index: idx, capabilities: caps) else { Issue.record("no move"); return }
        let line = DropTrace.layoutLine(id: 17, key: shield, layout: l)
        #expect(line.contains("before \(mcp)"))
    }

    @Test func noGhostBesideItsOwnRealRow() {
        let layout = Layout(visible: [cc, shield, chev, mcp, flo], placed: [shield], orderMode: .placedOnly)
        let r = rows(layout, awaiting: [shield])
        #expect(r.filter { $0.key == shield }.count == 1)
        #expect(r.first { $0.key == shield }?.isGhost == false)
    }

    @Test func realMoveStillShowsAGhostAtTheTarget() {
        let layout = Layout(visible: [shield, cc, mcp, flo], placed: [shield], orderMode: .placedOnly)   // wants Shield first; the bar has it second
        let r = rows(layout, awaiting: [shield])
        #expect(r.filter { $0.key == shield }.count == 2)
    }

    @Test func timeoutBadgeCarriesTheReason() {
        #expect(ArrangeBadge.failed(ArrangeTracker.timeoutText).tooltip.contains("90 s"))
    }
}
