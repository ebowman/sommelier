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
    let prev = [ri("B", x: 10), ri("C", x: 40), ri("A", x: 70)]
    let last = [ri("C", x: 10), ri("B", x: 40), ri("A", x: 70, stale: true)]
    let d = ScanDisagreement.make(scans: 6, previous: prev, last: last, rule: rule)
    #expect(d.staleKeys == ["status:o::A"])
    #expect(d.changedKeys == ["status:o::B", "status:o::C"])   // one call yields both lists
    let d2 = ScanDisagreement.make(scans: 6, previous: prev, last: [ri("C", x: 10), ri("B", x: 40), ri("A", x: 70)], rule: rule)
    #expect(d2.staleKeys.isEmpty)
    #expect(d2.changedKeys == ["status:o::B", "status:o::C"])
    #expect(d.message.contains("stale in the last scan: status:o::A"))
    #expect(d2.message.contains("differed between the last two scans: status:o::B, status:o::C"))
}

@Test func disagreementReportsBothListsWhenPreviousWasUsableAndLastHasDifferingStale() {
    let rule = BarSignature(selfPositioningOwners: [])
    // Previous usable; last has a stale parked-style difference: new key D appears (changed) while stale A blocks the signature.
    let d = ScanDisagreement.make(scans: 3, previous: [ri("A", x: 10)], last: [ri("A", x: 10, stale: true), ri("D", x: 40)], rule: rule)
    #expect(d.staleKeys == ["status:o::A"])
    #expect(d.message.contains("stale in the last scan"))
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
