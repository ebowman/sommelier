import Foundation
import Testing
@testable import SommelierCore

// 8z5.4: the Arrange waiting machinery in macOSOwns (no order ghosts, spinners or timeouts) vs placedOnly (unchanged).

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private let clock = ItemKey.module(name: "Clock")
private func caps(_ key: ItemKey) -> Capability {
    if case .module = key { return Capability(canMove: false, canHide: false, reason: "system module") }
    return Capability(canMove: true, canHide: true)
}
private func info(_ key: ItemKey) -> ItemInfo {
    ItemInfo(key: key, title: "", axDescription: "", ownerPID: 1, ownerBundleID: "com.x", ownerName: "Owner", width: 30, isOnBar: true, systemOverflow: false)
}
private func make(bar: [ItemKey], parked: [ItemKey] = [], layout: Layout, status: [ItemKey: ItemStatus] = [:], awaiting: Set<ItemKey> = []) -> ArrangeContent {
    ArrangeSections.make(observed: ObservedOrder(onBar: bar, parked: parked, systemOverflow: [], overflowChevron: nil), layout: layout,
                         items: Dictionary(uniqueKeysWithValues: (bar + parked).map { ($0, info($0)) }), perItem: status, capabilities: caps, awaiting: awaiting)
}
private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Test func macOSOwnsShowsNoOrderGhostsOrBadgesWherePlacedOnlyDoes() {
    let want = Layout(visible: [k("c"), k("a"), k("b"), clock])
    let bar = [k("a"), k("b"), k("c"), clock]
    let st: [ItemKey: ItemStatus] = [k("c"): .pending, k("a"): .inPlace, k("b"): .inPlace]
    let macSt: [ItemKey: ItemStatus] = [k("c"): .inPlace, k("a"): .inPlace, k("b"): .inPlace]   // the engine never plans an order move
    let mac = make(bar: bar, layout: want.withOrderMode(.macOSOwns), status: macSt, awaiting: [k("c")])
    #expect(mac.visible.rows.map(\.key) == [k("a"), k("b"), k("c"), clock])
    #expect(mac.visible.rows.allSatisfy { !$0.isGhost })
    #expect(mac.visible.rows.allSatisfy { if case .failed = $0.badge { return false }; return $0.badge != .moving })
    // the same scene in placedOnly keeps today's ghost and spinner
    let placed = make(bar: bar, layout: want.withOrderMode(.placedOnly), status: st, awaiting: [k("c")])
    #expect(placed.visible.rows.count == 5 && placed.visible.rows[0].isGhost && placed.visible.rows[0].badge == .moving)
}

@Test func macOSOwnsDropIntoVisibleSpinsUntilOnBarThenVerifiesWhereverItLanded() {
    let layout = Layout(visible: [k("a"), k("c"), k("b"), clock], hidden: [])   // c asked to sit between a and b
    // not on the bar yet (parked): ghost with the spinner
    let before = make(bar: [k("a"), k("b"), clock], parked: [k("c")], layout: layout, awaiting: [k("c")])
    #expect(before.visible.rows.contains { $0.key == k("c") && $0.isGhost && $0.badge == .moving })
    // on the bar, but macOS put it at the end: no ghost, no spinner
    let bar = [k("a"), k("b"), k("c"), clock]
    let after = make(bar: bar, layout: layout, status: [k("c"): .inPlace], awaiting: [k("c")])
    #expect(after.visible.rows.allSatisfy { !$0.isGhost })
    #expect(after.visible.rows.first { $0.key == k("c") }?.badge == .inPlace)

    var t = ArrangeTracker()
    t.record([k("c")], passesStarted: 1, now: t0)
    let obs = ObservedOrder(onBar: bar, parked: [], systemOverflow: [], overflowChevron: nil)
    let log = t.update(observed: obs, layout: layout, perItem: [k("c"): .inPlace], passSequence: 2, showHiddenSection: false, now: t0.addingTimeInterval(3))
    #expect(log.contains { $0.contains("verified in place") })
    #expect(t.isEmpty && t.timedOut.isEmpty)
}

@Test func placedOnlyStillRequiresTheOrderMatch() {
    let layout = Layout(visible: [k("a"), k("c"), k("b"), clock]).withOrderMode(.placedOnly)
    let obs = ObservedOrder(onBar: [k("a"), k("b"), k("c"), clock], parked: [], systemOverflow: [], overflowChevron: nil)
    #expect(!ArrangeSections.placementMatches(k("c"), layout: layout, observed: obs))
    #expect(ArrangeSections.placementMatches(k("c"), layout: layout.withOrderMode(.macOSOwns), observed: obs))
    var t = ArrangeTracker()
    t.record([k("c")], passesStarted: 1, now: t0)
    let log = t.update(observed: obs, layout: layout, perItem: [k("c"): .inPlace], passSequence: 2, showHiddenSection: false, now: t0.addingTimeInterval(3))
    #expect(log.isEmpty && !t.isEmpty)
    // and it times out as before
    let late = t.update(observed: obs, layout: layout, perItem: [k("c"): .inPlace], passSequence: 3, showHiddenSection: false, now: t0.addingTimeInterval(ArrangeTracker.timeout + 1))
    #expect(late.contains { $0.contains("NOT applied") })
}

@Test func statusLineNamesTheOrderMode() {
    func line(_ m: OrderMode?, _ n: Int, converged: Bool = true) -> String {
        ArrangeSections.statusLine(perItem: [:], lastError: nil, isConverged: converged, inFlight: false, orderMode: m, placedCount: n)
    }
    #expect(line(.macOSOwns, 0) == "Converged · Order follows macOS")
    #expect(line(.macOSOwns, 3) == "Converged · Order follows macOS")
    #expect(line(.placedOnly, 0) == "Converged · No placed items")
    #expect(line(.placedOnly, 3) == "Converged · Keeping the order of 3 placed items")
    #expect(line(nil, 3) == "Converged")
    #expect(!line(.placedOnly, 3, converged: false).contains("placed"))
    let pending = ArrangeSections.statusLine(perItem: [k("a"): .pending], lastError: nil, isConverged: false, inFlight: true, orderMode: .macOSOwns)
    #expect(pending == "1 pending")
}

@Test func keysToTrackIsSectionChangesOnlyInMacOSOwns() {
    let old = Layout(visible: [k("a"), k("b"), clock], hidden: [k("h"), k("i")])
    var new = old
    new.visible = [k("b"), k("h"), k("a"), clock]; new.hidden = [k("i")]
    let moved = [k("h"), k("a"), k("b")]
    #expect(keysToTrack(moved: moved, old: old.withOrderMode(.macOSOwns), new: new.withOrderMode(.macOSOwns)) == [k("h")])
    #expect(keysToTrack(moved: moved, old: old.withOrderMode(.placedOnly), new: new.withOrderMode(.placedOnly)) == moved)
    // a pure hidden-strip reorder is never tracked
    var re = old; re.hidden = [k("i"), k("h")]
    #expect(keysToTrack(moved: [k("h")], old: old.withOrderMode(.placedOnly), new: re.withOrderMode(.placedOnly)).isEmpty)
}
