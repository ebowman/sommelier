import Testing
import Foundation
@testable import SommelierCore

private struct Scripted: SnapshotScanning {
    final class Box: @unchecked Sendable { var i = 0; var snaps: [MenuBarSnapshot]; init(_ s: [MenuBarSnapshot]) { snaps = s } }
    let box: Box
    func scanVisible() async -> MenuBarSnapshot { await scan() }
    func scan() async -> MenuBarSnapshot { let s = box.snaps[min(box.i, box.snaps.count - 1)]; box.i += 1; return s }
}

private func item(_ n: String, x: CGFloat, w: CGFloat = 24, stale: Bool = false) -> MenuBarItem {
    MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: n, title: n, axDescription: "", axIdentifier: n,
                frame: CGRect(x: x, y: 0, width: w, height: 24), source: .appExtras, isOnMenuBar: true, stale: stale)
}

private func snap(_ extra: [MenuBarItem]) -> MenuBarSnapshot {
    MenuBarSnapshot(items: [item("A", x: 100), item("B", x: 140)] + extra, capturedAt: Date())
}

private func observer(_ snaps: [MenuBarSnapshot]) -> (AgreedScanObserver, Scripted.Box) {
    let box = Scripted.Box(snaps)
    return (AgreedScanObserver(scanner: Scripted(box: box), resolve: { s in
        s.items.map { ResolvedItem(item: $0, key: .status(ownerKey: $0.axIdentifier, autosaveName: $0.axIdentifier), confidence: .exact) }
    }, maxScans: 6, deadline: 15, accessibilityTrusted: { true }, sleep: { _ in }), box)
}

@Test func scansDifferingOnlyInWidthZeroItemAgree() async throws {
    let (o, box) = observer([snap([item("Menu1", x: 300, w: 0)]), snap([item("Menu2", x: 310, w: 0)])])
    let r = try await o.observe()
    #expect(box.i == 2)
    #expect(r.count == 3)
}

@Test func staleFinalScanIsStillRefused() async {
    let (o, _) = observer([snap([item("S", x: 200, stale: true)])])
    await #expect(throws: ObserveError.noAgreement(scans: 6)) { try await o.observe() }
}

@Test func untrustedThrowsPermissionDenied() async {
    let box = Scripted.Box([snap([])])
    let o = AgreedScanObserver(scanner: Scripted(box: box), resolve: { _ in [] }, accessibilityTrusted: { false })
    await #expect(throws: ObserveError.permissionDenied) { try await o.observe() }
}
