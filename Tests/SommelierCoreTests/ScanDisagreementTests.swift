import Testing
import Foundation
@testable import SommelierCore

private func ri(_ name: String, x: CGFloat, w: CGFloat = 24, stale: Bool = false, title: String = "t") -> ResolvedItem {
    let k = ItemKey.status(ownerKey: "o", autosaveName: name)
    var it = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: "o", title: title, axDescription: "", axIdentifier: name,
                         frame: CGRect(x: x, y: 0, width: w, height: 24), source: .appExtras, isOnMenuBar: true)
    it.stale = stale
    return ResolvedItem(item: it, key: k, confidence: .exact)
}

@Test func disagreementNamesStaleAndMovedKeys() {
    let rule = BarSignature(selfPositioningOwners: [])
    // Last scan: A stale; the previous scan was usable but had B, C in the other order.
    let prev = [ri("B", x: 10), ri("C", x: 40), ri("E", x: 55), ri("A", x: 70)]
    let last = [ri("C", x: 10), ri("E", x: 40), ri("B", x: 55), ri("A", x: 70, stale: true)]
    let d = ScanDisagreement.make(scans: 6, previous: prev, last: last, rule: rule)
    #expect(d.staleKeys == ["status:o::A"])
    #expect(d.changedKeys == ["status:o::B"])   // one call yields both lists; B jumped past C and E
    let d2 = ScanDisagreement.make(scans: 6, previous: prev, last: [ri("C", x: 10), ri("E", x: 40), ri("B", x: 55), ri("A", x: 70)], rule: rule)
    #expect(d2.staleKeys.isEmpty)
    #expect(d2.changedKeys == ["status:o::B"])
    #expect(d.message.contains("stale in the last scan: status:o::A"))
    #expect(d2.message.contains("differed between the last two scans: status:o::B"))
}

@Test func disagreementReportsBothListsWhenPreviousWasUsableAndLastHasDifferingStale() {
    let rule = BarSignature(selfPositioningOwners: [])
    // Previous usable; last has a stale parked-style difference: new key D appears (changed) while stale A blocks the signature.
    let d = ScanDisagreement.make(scans: 3, previous: [ri("A", x: 10)], last: [ri("A", x: 10, stale: true), ri("D", x: 40)], rule: rule)
    #expect(d.staleKeys == ["status:o::A"])
    #expect(d.changedKeys == ["status:o::D"])
    #expect(d.message.contains("stale in the last scan"))
}

@Test func earlyInsertionReportsOnlyTheInsertedKey() {
    let rule = BarSignature(selfPositioningOwners: [])
    let prev = [ri("A", x: 10), ri("B", x: 40), ri("C", x: 70)]
    let last = [ri("N", x: 10), ri("A", x: 40), ri("B", x: 70), ri("C", x: 100)]
    #expect(ScanDisagreement.make(scans: 2, previous: prev, last: last, rule: rule).changedKeys == ["status:o::N"])
    #expect(OrderDiff.changedKeys(["a", "b", "c"], ["n", "a", "b", "c"]).isEmpty)   // n is absent from a: not "moved"
}

@Test func barToParkedReportsThatKey() {
    let rule = BarSignature(selfPositioningOwners: [])
    func parked(_ n: String) -> ResolvedItem {
        var r = ri(n, x: -1000); r.item.isOnMenuBar = false; return r
    }
    let prev = [ri("A", x: 10), ri("B", x: 40)]
    let d = ScanDisagreement.make(scans: 2, previous: prev, last: [ri("A", x: 10), parked("B")], rule: rule)
    #expect(d.changedKeys == ["status:o::B"])
}

@Test func staleVerdictAnyStaleItemRefusedNoOwnerExempt() {
    let rule = BarSignature()   // default self-positioning owners
    let owner = SelfPositioning.defaultOwners.sorted().first!
    func mine(_ n: String, stale: Bool) -> ResolvedItem {
        var r = ri(n, x: 10, stale: stale)
        r.key = .status(ownerKey: owner, autosaveName: n)
        return r
    }
    #expect(rule.staleVerdict([ri("A", x: 10), mine("I1", stale: false)]) == .clean)
    #expect(rule.staleVerdict([ri("A", x: 10), mine("I1", stale: true)]) == .refuse(["status:\(owner)::I1"]))   // gdu.120: was written as selfPositioningOnly
    var parkedStale = ri("P", x: -1000, stale: true); parkedStale.item.isOnMenuBar = false
    #expect(rule.staleVerdict([ri("A", x: 10), mine("I1", stale: true), parkedStale]) == .refuse(["status:\(owner)::I1", "status:o::P"]))
    // an agreed scan can contain a stale parked ordinary item (the rule only blocks on-bar ones), so the refusal is reachable
    #expect(rule.value([ri("A", x: 10), parkedStale]) != nil)
}

@Test func signatureIgnoresWidthZeroNamelessElement() {
    let rule = BarSignature(selfPositioningOwners: [])
    let base = [ri("A", x: 10), ri("B", x: 40)]
    let noisy = base + [ri("", x: 0, w: 0, title: "")]
    #expect(rule.value(base) != nil)
    #expect(rule.value(base) == rule.value(noisy))
    // and it cannot block agreement even when stale
    #expect(rule.value(base + [ri("Z", x: 0, w: 0, stale: true)]) == rule.value(base))
}
