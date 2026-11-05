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

// MARK: - Agreement rule (gdu.46)

private func plain(_ n: String, x: CGFloat, id: Bool = true, stale: Bool = false, onBar: Bool = true, w: CGFloat = 24) -> MenuBarItem {
    MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: n, title: n, axDescription: "", axIdentifier: id ? n : "",
                frame: CGRect(x: x, y: 0, width: w, height: 24), source: .appExtras, isOnMenuBar: onBar, stale: stale)
}

private func obs(_ snaps: [MenuBarSnapshot], selfPositioning: Set<String> = ["S1", "S2"], maxScans: Int = 6) -> (AgreedScanObserver, Scripted.Box) {
    let box = Scripted.Box(snaps)
    return (AgreedScanObserver(scanner: Scripted(box: box), resolve: { s in
        s.items.map { ResolvedItem(item: $0, key: .status(ownerKey: $0.ownerName, autosaveName: $0.title), confidence: .inferred) }
    }, maxScans: maxScans, deadline: 15, selfPositioningOwners: selfPositioning, accessibilityTrusted: { true }, sleep: { _ in }), box)
}

private func bar(_ items: [MenuBarItem], complete: Bool? = nil) -> MenuBarSnapshot {
    MenuBarSnapshot(items: items, capturedAt: Date(), hostedReadComplete: complete)
}

@Test func duplicateKeysAreCollapsedToTheFirstByPosition() async throws {
    let dup = bar([plain("A", x: 100), plain("B", x: 140), plain("A", x: 300)])
    let (o, _) = obs([dup, dup])
    let r = try await o.observe()
    #expect(r.map(\.key.description).sorted() == ["status:A::A", "status:B::B"])
    #expect(r.first { $0.key.description == "status:A::A" }?.item.frame.minX == 100)
}

@Test func selfPositioningAndIdentifierlessOrderNoiseStillAgrees() async throws {
    let s1 = bar([plain("A", x: 100), plain("S1", x: 140), plain("S2", x: 170), plain("N1", x: 200, id: false), plain("N2", x: 230, id: false), plain("B", x: 260)])
    let s2 = bar([plain("A", x: 100), plain("S2", x: 140), plain("S1", x: 170), plain("N2", x: 200, id: false), plain("N1", x: 230, id: false), plain("B", x: 260)])
    let (o, box) = obs([s1, s2])
    let r = try await o.observeDetailed(progress: nil)
    #expect(r.settled)
    #expect(box.i == 2)
}

@Test func identifierlessPresenceStillCounts() async {
    let a = bar([plain("A", x: 100), plain("N1", x: 140, id: false), plain("B", x: 170)])
    let b = bar([plain("A", x: 100), plain("B", x: 140)])
    let (o, _) = obs([a, b, a, b, a, b])
    let r = try? await o.observeDetailed(progress: nil)
    #expect(r?.settled == false)
}

@Test func identifiedThirdPartyOrderDisagreementDoesNotAgree() async throws {
    let a = bar([plain("A", x: 100), plain("B", x: 140), plain("C", x: 180)])
    let b = bar([plain("A", x: 100), plain("C", x: 140), plain("B", x: 180)])
    let (o, box) = obs([a, b, a, b, a, b])
    await #expect(throws: ObserveError.noAgreement(scans: 6)) { try await o.observe() }
    #expect(box.i == 6)
    // The lenient call returns the LATEST complete read, flagged unsettled.
    box.i = 0
    let r = try await o.observeDetailed(progress: nil)
    #expect(!r.settled)
    #expect(r.items.filter { $0.item.isOnMenuBar }.sorted { $0.item.frame.minX < $1.item.frame.minX }.map(\.item.ownerName) == ["A", "C", "B"])
}

@Test func volatileWiFiPresenceDoesNotBlockAgreement() async throws {
    func wifi() -> MenuBarItem { plain("WiFi", x: 60) }
    let (base, _) = obs([])
    _ = base
    let box = Scripted.Box([bar([wifi(), plain("A", x: 100)]), bar([plain("A", x: 100)])])
    let o = AgreedScanObserver(scanner: Scripted(box: box), resolve: { s in
        s.items.map { ResolvedItem(item: $0, key: $0.ownerName == "WiFi" ? .module(name: "WiFi") : .status(ownerKey: $0.ownerName, autosaveName: $0.title), confidence: .inferred) }
    }, accessibilityTrusted: { true }, sleep: { _ in })
    let r = try await o.observeDetailed(progress: nil)
    #expect(r.settled && box.i == 2)
}

@Test func staleParkedItemsAgreeButStaleOnBarBlocks() async throws {
    let parked = bar([plain("A", x: 100), plain("P", x: -1, stale: true, onBar: false)])
    let (o, _) = obs([parked, parked])
    #expect(try await o.observeDetailed(progress: nil).settled)
    let onbar = bar([plain("A", x: 100), plain("S", x: 140, stale: true)])
    let (o2, _) = obs([onbar])
    let r = try await o2.observeDetailed(progress: nil)
    #expect(!r.settled)   // never agrees: returned as the latest complete read, unsettled
}

@Test func incompleteHostedReadsAreNeverReturnedAsUnsettled() async {
    let a = bar([plain("A", x: 100), plain("B", x: 140)], complete: false)
    let b = bar([plain("B", x: 100), plain("A", x: 140)], complete: false)
    let (o, _) = obs([a, b, a, b, a, b])
    await #expect(throws: ObserveError.noAgreement(scans: 6)) { try await o.observeDetailed(progress: nil) }
}

@Test func progressReceivesTheFirstCompleteScanOnce() async throws {
    final class Box: @unchecked Sendable { let l = NSLock(); var n = 0; func bump() { l.lock(); n += 1; l.unlock() } }
    let b = Box()
    let a = bar([plain("A", x: 100), plain("B", x: 140)])
    let (o, _) = obs([a, a, a])
    _ = try await o.observeDetailed(progress: { _ in b.bump() })
    #expect(b.n == 1)
}

@Test func progressAlsoReceivesAnIncompleteFirstScan() async throws {
    final class Box: @unchecked Sendable { let l = NSLock(); var n = 0; func bump() { l.lock(); n += 1; l.unlock() } }
    let b = Box()
    let partial = bar([plain("A", x: 100)], complete: false)
    let full = bar([plain("A", x: 100), plain("B", x: 140)], complete: true)
    let (o, _) = obs([partial, full, full])
    let r = try await o.observeDetailed(progress: { _ in b.bump() })
    #expect(b.n == 1 && r.settled && r.items.count == 2)
}


// MARK: - gdu.51: stale items of self-positioning owners

private func spBar(_ items: [MenuBarItem], level: ReadCompleteness = .completeExceptSelfPositioning) -> MenuBarSnapshot {
    MenuBarSnapshot(items: items, capturedAt: Date(), hostedReadComplete: level == .complete ? true : false,
                    incompleteOnlyForSelfPositioning: level == .completeExceptSelfPositioning)
}

@Test func completenessLevelsOnTheSnapshot() {
    #expect(MenuBarSnapshot(items: [], capturedAt: Date()).completeness == .complete)
    #expect(MenuBarSnapshot(items: [], capturedAt: Date(), hostedReadComplete: true).completeness == .complete)
    #expect(MenuBarSnapshot(items: [], capturedAt: Date(), hostedReadComplete: false).completeness == .incomplete)
    #expect(spBar([]).completeness == .completeExceptSelfPositioning)
    #expect(spBar([]).hostedReadComplete == false)       // compatibility flag stays strict
}

@Test func agreesAcrossScansDifferingOnlyByStaleSelfPositioningItems() async throws {
    let a = spBar([plain("A", x: 100), plain("S1", x: 140, stale: true), plain("S2", x: 170, stale: true), plain("B", x: 200)])
    let b = spBar([plain("A", x: 100), plain("S1", x: 140), plain("S2", x: 170), plain("B", x: 200)], level: .complete)
    let (o, box) = obs([a, b])
    let r = try await o.observeDetailed(progress: nil)
    #expect(r.settled && box.i == 2)
    #expect(r.completeness == .completeExceptSelfPositioning)
    let (o2, _) = obs([a, a])
    let r2 = try await o2.observeDetailed(progress: nil)
    #expect(r2.settled && r2.items.count == 4)
}

@Test func staleThirdPartyOnBarItemStillBlocksAgreement() async {
    let a = spBar([plain("A", x: 100), plain("S1", x: 140, stale: true), plain("T", x: 170, stale: true)], level: .incomplete)
    let (o, _) = obs([a, a, a, a, a, a])
    await #expect(throws: ObserveError.noAgreement(scans: 6)) { try await o.observe() }
}

@Test func cleanCompleteObservationReportsComplete() async throws {
    let a = bar([plain("A", x: 100), plain("B", x: 140)], complete: true)
    let (o, _) = obs([a, a])
    #expect(try await o.observeDetailed(progress: nil).completeness == .complete)
}

// MARK: - Seeded observation (gdu.71)

private func seedOf(_ s: MenuBarSnapshot, level: ReadCompleteness = .complete, normalize: @escaping @Sendable ([ResolvedItem]) -> [ResolvedItem] = { $0 }) -> ObservationSeed {
    ObservationSeed(items: s.items.map { ResolvedItem(item: $0, key: .status(ownerKey: $0.ownerName, autosaveName: $0.title), confidence: .inferred) },
                    completeness: level, normalize: normalize)
}

@Test func seedAgreeingWithTheFirstFreshScanSettlesAfterOneScan() async throws {
    let a = bar([plain("A", x: 100), plain("B", x: 140)])
    let (o, box) = obs([a])
    let r = try await o.observeDetailed(progress: nil, seed: seedOf(a))
    #expect(r.settled && r.scans == 1 && box.i == 1)
}

@Test func seedDisagreeingFallsBackToTwoAgreeingFreshScans() async throws {
    let a = bar([plain("A", x: 100), plain("B", x: 140)])
    let b = bar([plain("B", x: 100), plain("A", x: 140)])
    let (o, box) = obs([b, b])
    let r = try await o.observeDetailed(progress: nil, seed: seedOf(a))
    #expect(r.settled && r.scans == 2 && box.i == 2)
    // The seed never counts toward the disagreement budget: it cannot make a never-agreeing bar settle.
    let (o2, box2) = obs([b, a, b, a, b, a])
    let r2 = try await o2.observeDetailed(progress: nil, seed: seedOf(a))
    #expect(!r2.settled && box2.i == 6)
}

@Test func incompleteOrStaleSeedIsIgnored() async throws {
    let a = bar([plain("A", x: 100), plain("B", x: 140)])
    let (o, box) = obs([a, a])
    let r = try await o.observeDetailed(progress: nil, seed: seedOf(a, level: .incomplete))
    #expect(r.settled && r.scans == 2 && box.i == 2)
}

@Test func seedIsComparedThroughItsNormalizer() async throws {
    // The engine's view drops one item (e.g. our own status item); the fresh raw scan still has it.
    let raw = bar([plain("A", x: 100), plain("Own", x: 140), plain("B", x: 180)])
    let seedScan = bar([plain("A", x: 100), plain("B", x: 180)])
    let (o, box) = obs([raw])
    let drop: @Sendable ([ResolvedItem]) -> [ResolvedItem] = { $0.filter { $0.item.ownerName != "Own" } }
    let r = try await o.observeDetailed(progress: nil, seed: seedOf(seedScan, normalize: drop))
    #expect(r.settled && r.scans == 1 && box.i == 1)
    #expect(r.items.count == 3)                                   // the observation itself stays raw; the wrapper filters it
}
