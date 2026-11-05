import Testing
import Foundation
@testable import SommelierCore

private struct Scripted: SnapshotScanning {
    final class Box: @unchecked Sendable { var i = 0; var snaps: [MenuBarSnapshot]; init(_ s: [MenuBarSnapshot]) { snaps = s } }
    let box: Box
    func scanVisible() async -> MenuBarSnapshot { await scan() }
    func scan() async -> MenuBarSnapshot { let s = box.snaps[min(box.i, box.snaps.count - 1)]; box.i += 1; return s }
}

private func it(_ n: String, x: CGFloat, onBar: Bool = true, unknown: Bool = false) -> MenuBarItem {
    MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: n, title: n, axDescription: "", axIdentifier: n,
                frame: CGRect(x: x, y: 0, width: 24, height: 24), source: .appExtras, isOnMenuBar: onBar,
                placementUnknown: unknown)
}

private func snap(_ items: [MenuBarItem], complete: Bool? = nil, spOnly: Bool = false) -> MenuBarSnapshot {
    MenuBarSnapshot(items: items, capturedAt: Date(), hostedReadComplete: complete, incompleteOnlyForSelfPositioning: spOnly)
}

private func observer(_ snaps: [MenuBarSnapshot]) -> AgreedScanObserver {
    let box = Scripted.Box(snaps)
    return AgreedScanObserver(scanner: Scripted(box: box), resolve: { s in
        s.items.map { ResolvedItem(item: $0, key: .status(ownerKey: $0.ownerName, autosaveName: $0.title), confidence: .exact) }
    }, maxScans: 6, deadline: 15, accessibilityTrusted: { true }, sleep: { _ in })
}

private let a = it("A", x: 100)
private let kUnknown = it("K", x: 0, onBar: false, unknown: true)
private let kPlaced = it("K", x: 140)

@Test func initRefusesWhenAnEarlierScanMarkedAnItemUnknown() async {
    // Scan 1: K unknown; scans 2 and 3 place it on the bar and agree. The final result alone looks clean.
    let o = observer([snap([a, kUnknown]), snap([a, kPlaced]), snap([a, kPlaced])])
    guard case .refuse(let m) = await LayoutInit.evaluate(observer: o) else { Issue.record("expected refusal"); return }
    #expect(m.contains("status:K::K") && m.contains("not writing"))
}

@Test func initRefusesWhenTheFinalScanIsUnknown() async {
    let o = observer([snap([a, kUnknown]), snap([a, kUnknown])])
    guard case .refuse(let m) = await LayoutInit.evaluate(observer: o) else { Issue.record("expected refusal"); return }
    #expect(m.contains("status:K::K"))
}

@Test func initWritesWhenAllScansCompleteAndPlaced() async {
    let o = observer([snap([a, kPlaced]), snap([a, kPlaced])])
    guard case .build(let items, let n, let notes) = await LayoutInit.evaluate(observer: o) else { Issue.record("expected build"); return }
    #expect(n == 2 && items.count == 2 && notes.isEmpty)
}

@Test func initRefusesAnAgreedResultFromAnIncompleteRead() async {
    let o = observer([snap([a, kPlaced], complete: false), snap([a, kPlaced], complete: false)])
    guard case .refuse(let m) = await LayoutInit.evaluate(observer: o) else { Issue.record("expected refusal"); return }
    #expect(m == "layout init needs a complete read; retry when the bar settles")
}

@Test func initIncompleteRefusalAppendsTheScannersReasons() async {
    var s1 = snap([a, kPlaced], complete: false); s1.completenessReason = "named timeout not self-positioning (id:X)"
    var s2 = snap([a, kPlaced], complete: false); s2.completenessReason = "named timeout not self-positioning (id:X)"
    guard case .refuse(let m) = await LayoutInit.evaluate(observer: observer([s1, s2])) else { Issue.record("expected refusal"); return }
    #expect(m.hasPrefix("layout init needs a complete read") && m.contains("incomplete: named timeout not self-positioning (id:X)"))
}

@Test func initUnknownRefusalUsesThePerItemReason() async {
    var u = kUnknown; u.placementReason = "weak join (frameAmbiguous) with a hosted element in the overflow pile; make room in the bar so the item is drawn, or hide it in Control Center"
    guard case .refuse(let m) = await LayoutInit.evaluate(observer: observer([snap([a, u]), snap([a, u])])) else { Issue.record("expected refusal"); return }
    #expect(m.contains("weak join (frameAmbiguous)") && m.contains("overflow pile") && !m.contains("retry when the bar settles"))
}

@Test func initAcceptsASelfPositioningOnlyIncompleteRead() async {
    let o = observer([snap([a, kPlaced], complete: false, spOnly: true), snap([a, kPlaced], complete: false, spOnly: true)])
    guard case .build(let items, _, _) = await LayoutInit.evaluate(observer: o) else { Issue.record("expected build"); return }
    #expect(items.count == 2)
}

@Test func initWritesSelfPositioningStaleAgreedReadWithNote() async {
    let owner = SelfPositioning.defaultOwners.sorted().first!
    let sp = MenuBarItem(ownerPID: 2, ownerBundleID: owner, ownerName: owner, title: "I1", axDescription: "", axIdentifier: "I1",
                         frame: CGRect(x: 200, y: 0, width: 24, height: 24), source: .appExtras, isOnMenuBar: true, stale: true)
    let s = snap([a, sp], complete: false, spOnly: true)
    let box = Scripted.Box([s, s])
    let o = AgreedScanObserver(scanner: Scripted(box: box), resolve: { s in
        s.items.map { ResolvedItem(item: $0, key: .status(ownerKey: $0.ownerName, autosaveName: $0.title), confidence: .exact) }
    }, maxScans: 6, deadline: 15, accessibilityTrusted: { true }, sleep: { _ in })
    guard case .build(_, _, let notes) = await LayoutInit.evaluate(observer: o) else { Issue.record("expected build"); return }
    #expect(notes.count == 1 && notes[0].contains("self-positioning items were stale"))
}
