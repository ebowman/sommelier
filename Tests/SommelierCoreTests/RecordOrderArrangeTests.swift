import Foundation
import Testing
@testable import SommelierCore

// 9o9.2: the record is the order: an on-bar Visible key must also be in the recorded order to be verified (no mode switch).

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

@Test func outOfOrderVisibleKeyShowsGhostAndSpinner() {
    let want = Layout(visible: [k("c"), k("a"), k("b"), clock])
    let bar = [k("a"), k("b"), k("c"), clock]
    let st: [ItemKey: ItemStatus] = [k("c"): .pending, k("a"): .inPlace, k("b"): .inPlace]
    let c = make(bar: bar, layout: want, status: st, awaiting: [k("c")])
    #expect(c.visible.rows.count == 5 && c.visible.rows[0].isGhost && c.visible.rows[0].badge == .moving)
}

@Test func verificationRequiresTheOrderMatch() {
    let layout = Layout(visible: [k("a"), k("c"), k("b"), clock])
    let obs = ObservedOrder(onBar: [k("a"), k("b"), k("c"), clock], parked: [], systemOverflow: [], overflowChevron: nil)
    #expect(!ArrangeSections.placementMatches(k("c"), layout: layout, observed: obs))
    var t = ArrangeTracker()
    t.record([k("c")], passesStarted: 1, now: t0)
    let log = t.update(observed: obs, layout: layout, perItem: [k("c"): .inPlace], passSequence: 2, showHiddenSection: false, now: t0.addingTimeInterval(3))
    #expect(log.isEmpty && !t.isEmpty)
    // and it times out as before
    let late = t.update(observed: obs, layout: layout, perItem: [k("c"): .inPlace], passSequence: 3, showHiddenSection: false, now: t0.addingTimeInterval(ArrangeTracker.timeout + 1))
    #expect(late.contains { $0.contains("NOT applied") })
}

@Test func statusLineConvergedSuffixIsMenuBarMatches() {
    func line(_ show: Bool, converged: Bool = true) -> String {
        ArrangeSections.statusLine(perItem: [:], lastError: nil, isConverged: converged, inFlight: false, showsBarMatch: show)
    }
    #expect(line(true) == "Converged · Menu bar matches")
    #expect(line(false) == "Converged")
    #expect(!line(true, converged: false).contains("matches"))
    let pending = ArrangeSections.statusLine(perItem: [k("a"): .pending], lastError: nil, isConverged: false, inFlight: true, showsBarMatch: true)
    #expect(pending == "1 pending")
}

@Test func keysToTrackIncludesVisibleReorders() {
    let old = Layout(visible: [k("a"), k("b"), clock], hidden: [k("h"), k("i")])
    var new = old
    new.visible = [k("b"), k("h"), k("a"), clock]; new.hidden = [k("i")]
    let moved = [k("h"), k("a"), k("b")]
    #expect(keysToTrack(moved: moved, old: old, new: new) == moved)
    // a pure hidden-strip reorder is never tracked
    var re = old; re.hidden = [k("i"), k("h")]
    #expect(keysToTrack(moved: [k("h")], old: old, new: re).isEmpty)
}
