import Testing
import Foundation
import CoreGraphics
@testable import SommelierCore

private func it(_ n: String, x: CGFloat, w: CGFloat = 30, onBar: Bool = true, stale: Bool = false, bundle: String? = nil) -> MenuBarItem {
    MenuBarItem(ownerPID: 100, ownerBundleID: bundle ?? "app.\(n)", ownerName: n, title: "", axDescription: "", axIdentifier: n,
                frame: onBar ? CGRect(x: x, y: 0, width: w, height: 24) : CGRect(x: -1, y: 0, width: 30, height: 24),
                source: .appExtras, isOnMenuBar: onBar, stale: stale)
}
private func snap(_ names: [String], parked: [String] = [], incomplete: Bool = false) -> MenuBarSnapshot {
    var items = names.enumerated().map { it($1, x: 100 + CGFloat($0) * 40) }
    items += parked.map { it($0, x: 0, onBar: false) }
    return MenuBarSnapshot(items: items, capturedAt: Date(timeIntervalSince1970: 0), hostedReadComplete: incomplete ? false : nil)
}

private final class Fake: SnapshotScanning, @unchecked Sendable {
    var fast: [MenuBarSnapshot]
    var full: [MenuBarSnapshot]
    var clock = Date(timeIntervalSince1970: 1000)
    var fastCalls = 0, fullCalls = 0
    init(fast: [MenuBarSnapshot], full: [MenuBarSnapshot]) { self.fast = fast; self.full = full }
    func scanVisible() async -> MenuBarSnapshot { fastCalls += 1; return fast.count > 1 ? fast.removeFirst() : fast[0] }
    func scan() async -> MenuBarSnapshot { fullCalls += 1; return full.count > 1 ? full.removeFirst() : full[0] }
    func detector(maxFullScans: Int = 3) -> SettleDetector {
        SettleDetector(scanner: self, now: { self.clock }, sleep: { self.clock = self.clock.addingTimeInterval($0) },
                       maxFullScans: maxFullScans)
    }
}

@Test func verdictWithDifferentOrderDoesNotSettleThenSettlesWhenAgreeing() async {
    let f = Fake(fast: [snap(["A", "B", "C"])], full: [snap(["A", "C", "B"]), snap(["A", "B", "C"])])
    let out = await f.detector().settled(maxWait: 3, stableFor: 0.15)
    #expect(out.settled)
    #expect(out.fullScans == 2)
    #expect(f.fastCalls == 4)     // a second fast pair after the disagreement
    #expect(out.trace.contains("verdict disagreed with fast observation"))
}

@Test func persistentlyDisagreeingVerdictExhaustsAndIsNotSettled() async {
    let f = Fake(fast: [snap(["A", "B", "C"])], full: [snap(["A", "C", "B"])])
    let out = await f.detector().settled(maxWait: 30, stableFor: 0.15)
    #expect(!out.settled)
    #expect(out.fullScans == 3)
    #expect(out.trace.contains("verdict disagreed with fast observation"))
    #expect(out.trace.contains("maxFullScans"))
    let g = Fake(fast: [snap(["A", "B"])], full: [snap(["B", "A"])])
    let o2 = await g.detector(maxFullScans: 1).settled()
    #expect(!o2.settled && o2.fullScans == 1)
}

@Test func agreeingVerdictCostsNoExtraScan() async {
    let f = Fake(fast: [snap(["A", "B"])], full: [snap(["A", "B"])])
    let out = await f.detector().settled()
    #expect(out.settled && out.fullScans == 1 && f.fastCalls == 2 && out.trace.isEmpty)
}

@Test func incompleteFastObservationNeedsTwoAgreeingFullScans() async {
    let f = Fake(fast: [snap(["A", "B"], incomplete: true)], full: [snap(["B", "A"]), snap(["B", "A"])])
    let out = await f.detector().settled()
    #expect(out.settled && out.fullScans == 2)
    #expect(out.trace.contains("fast observation incomplete"))
    let g = Fake(fast: [snap(["A", "B"], incomplete: true)], full: [snap(["B", "A"]), snap(["A", "B"]), snap(["B", "A"])])
    #expect(!(await g.detector().settled()).settled)
}

@Test func verdictAgreementIgnoresStaleNoiseAndSelfPositioning() {
    let fast = MenuBarSnapshot(items: [it("A", x: 100), it("N", x: 140, w: 1), it("S", x: 180, stale: true), it("B", x: 220),
                                       it("cpu", x: 260, bundle: "com.bjango.istatmenus.status")], capturedAt: Date())
    // verdict: noise gone, S fresh in another slot, iStat elsewhere
    let verdict = MenuBarSnapshot(items: [it("A", x: 100), it("B", x: 140), it("cpu", x: 180, bundle: "com.bjango.istatmenus.status"),
                                          it("S", x: 220)], capturedAt: Date())
    #expect(SettleDetector.verdictAgrees(fast: fast, verdict: verdict))
    #expect(!SettleDetector.verdictAgrees(fast: snap(["A", "B"]), verdict: snap(["B", "A"])))
    // parked set only matters when the fast scan reports it
    #expect(SettleDetector.verdictAgrees(fast: snap(["A"]), verdict: snap(["A"], parked: ["H"])))
    #expect(SettleDetector.verdictAgrees(fast: snap(["A"], parked: ["H"]), verdict: snap(["A"], parked: ["H"])))
    #expect(!SettleDetector.verdictAgrees(fast: snap(["A"], parked: ["H"]), verdict: snap(["A"])))
}
