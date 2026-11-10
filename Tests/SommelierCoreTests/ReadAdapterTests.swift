import CoreGraphics
import Foundation
import Testing
import DecisionCore
@testable import SommelierCore

// sommelier-ejb.13: ReadAdapter, CoreKeys, OutcomeMapper, and the scanner's unread supply. Nothing here touches the engine.

private func k(_ n: Int) -> ItemKey { .status(ownerKey: "app.\(n)", autosaveName: "a\(n)") }
private let chev = ItemKey.status(ownerKey: "com.apple.menuextra.chevron", autosaveName: "chevron")

private func order(_ bar: [Int], parked: [Int] = [], pile: [Int] = [], chevron: Bool? = nil) -> ObservedOrder {
    // chevron: true = fresh (in onBar), false = stale (in onBar, not fresh), nil = none
    var o = ObservedOrder(onBar: bar.map(k) + (chevron == nil ? [] : [chev]), parked: parked.map(k), systemOverflow: Set(pile.map(k)),
                          overflowChevron: chevron == true ? chev : nil)
    if chevron != nil { o.chevronAnyKey = chev; o.chevronPresent = true }
    return o
}
private func adapt(_ o: ObservedOrder, _ c: ReadContext = ReadContext(kind: .pass), record: [Int] = [], keys: inout CoreKeys) throws -> AdaptedRead {
    try ReadAdapter.adapt(o, context: c, record: record.map(k), keys: &keys)
}
/// Adapts and returns the read plus a way to name its keys as small ints (`k(n)` -> n).
private func run(_ o: ObservedOrder, _ c: ReadContext = ReadContext(kind: .pass), record: [Int] = []) throws -> (Read, [Int], [Int]) {
    var keys = CoreKeys()
    let a = try adapt(o, c, record: record, keys: &keys)
    func n(_ l: [Key]) -> [Int] { l.map { id in (0..<64).first { k($0) == keys.key(for: id) } ?? -1 } }
    var r = a.read
    let rec = n(a.record)
    let out = [n(r.drawn), n(r.pile), n(r.trusted), n(r.unread), n(r.nearFold)]
    r.drawn = out[0].map(Key.init); r.pile = out[1].map(Key.init); r.trusted = out[2].map(Key.init); r.unread = out[3].map(Key.init); r.nearFold = out[4].map(Key.init)
    return (r, rec, [])
}
private func ints(_ l: [Key]) -> [Int] { l.map(Int.init) }

// MARK: CoreKeys

@Test func coreKeysAreBijectiveStableAndNeverReused() throws {
    var ck = CoreKeys()
    let a = try ck.intern(k(1)), b = try ck.intern(k(2))
    #expect(a != b && ck.count == 2)
    #expect(try ck.intern(k(1)) == a && ck.count == 2)
    #expect(ck.key(for: a) == k(1) && ck.key(for: b) == k(2) && ck.id(for: k(2)) == b)
    #expect(ck.key(for: 99) == nil && ck.id(for: k(3)) == nil)
    var seen: Set<UInt32> = [a, b]
    for i in 0..<200 { #expect(seen.insert(try ck.intern(k(i))).inserted == (i != 1 && i != 2)) }
    #expect(ck.count == 200)
}

@Test func theChevronIsNeverInternedAndIsRejectedWithATypedError() throws {
    var ck = CoreKeys()
    let before = try ck.intern(k(1))
    ck.rejectChevron(chev)
    #expect(throws: CoreKeysError.chevron(chev)) { try ck.intern(chev) }
    #expect(ck.id(for: chev) == nil && ck.count == 1 && ck.isChevron(chev))
    #expect(try ck.intern(k(2)) == before + 1)       // the rejected attempt consumed no id
    // a key interned before it was recognised as the chevron: its id is never handed out again and it no longer resolves
    var late = CoreKeys()
    let id = try late.intern(k(7))
    late.rejectChevron(k(7))
    #expect(late.key(for: id) == nil && late.id(for: k(7)) == nil)
    #expect(try late.intern(k(8)) == id + 1)
}

@Test func coreKeysIsSendable() { let c = CoreKeys(); let _: any Sendable = c }

// MARK: Read fields (table tests)

@Test func kindIsPassedThrough() throws {
    for kind in ReadKind.allCases { #expect(try run(order([1, 2]), ReadContext(kind: kind)).0.kind == kind) }
}

@Test func settledFollowsTheObservationAndAPileDisagreementOfTwoCompleteReads() throws {
    let o = order([1, 2, 3], pile: [1], chevron: true)
    #expect(try run(o, ReadContext(kind: .pass, settled: true)).0.settled)
    #expect(try !run(o, ReadContext(kind: .pass, settled: false)).0.settled)
    #expect(try run(o, ReadContext(kind: .pass, previousCompletePile: Set([k(1)]))).0.settled)                  // same pile
    #expect(try !run(o, ReadContext(kind: .pass, previousCompletePile: Set([k(1), k(2)]))).0.settled)          // pile grew
    #expect(try !run(o, ReadContext(kind: .pass, previousCompletePile: Set<ItemKey>())).0.settled)            // pile appeared
    #expect(try run(o, ReadContext(kind: .pass, level: .incomplete, previousCompletePile: Set<ItemKey>())).0.settled)   // only COMPLETE reads are compared
    #expect(try run(o, ReadContext(kind: .pass, previousCompletePile: nil)).0.settled)
}

@Test func levelMapsOneToOne() throws {
    #expect(try run(order([1]), ReadContext(kind: .pass, level: .complete)).0.level == .complete)
    #expect(try run(order([1]), ReadContext(kind: .pass, level: .completeExceptSelfPositioning)).0.level == .exceptSelfPositioning)
    #expect(try run(order([1]), ReadContext(kind: .pass, level: .incomplete)).0.level == .incomplete)
}

@Test func observedIsFalseOnAFailedObservationOrAnEmptyBar() throws {
    #expect(try run(order([1])).0.observed)
    #expect(try !run(order([1]), ReadContext(kind: .pass, observed: false)).0.observed)
    #expect(try !run(order([])).0.observed)
}

@Test func stripOpenFollowsStripExpanded() throws {
    var o = order([1, 2], chevron: true)
    #expect(try !run(o).0.stripOpen)
    o.stripExpanded = true
    #expect(try run(o).0.stripOpen)
}

@Test func chevronIsFreshOnlyForAFreshChevronAndStaleForAnyCarriedOne() throws {
    #expect(try run(order([1], chevron: true)).0.chevron == .fresh)
    #expect(try run(order([1], chevron: false)).0.chevron == .stale)          // present but not fresh
    var recent = order([1]); recent.chevronRecent = true
    #expect(try run(recent).0.chevron == .stale)                              // recently verified: conservative = stale, not fresh
    #expect(try run(order([1])).0.chevron == .absent)
}

@Test func drawnIsOnBarMinusPileMinusChevronInOrderWithoutDuplicates() throws {
    var o = order([5, 1, 3, 1, 2], pile: [5, 1], chevron: true)
    o.onBar.insert(chev, at: 0)
    let (r, _, _) = try run(o)
    #expect(ints(r.drawn) == [3, 2])
}

@Test func pileIsOnBarIntersectSystemOverflowOnlyWithAFreshChevron() throws {
    let fresh = try run(order([5, 1, 3], pile: [5, 1, 9], chevron: true), record: [5, 1, 3]).0       // 9 is not on the bar
    #expect(ints(fresh.pile) == [5, 1] && ints(fresh.drawn) == [3])
    let stale = try run(order([5, 1, 3], pile: [5, 1], chevron: false), record: [5, 1, 3]).0
    #expect(stale.pile.isEmpty && ints(stale.drawn) == [3] && Set(ints(stale.unread)) == [5, 1])   // a stale pile goes to unread
    let none = try run(order([5, 1, 3], pile: [5, 1]), record: [5, 1, 3]).0
    #expect(none.pile.isEmpty && Set(ints(none.unread)) == [5, 1])
}

@Test func foldedIsAlwaysEmptyAndInferredFoldedParkedIsUnread() throws {
    var o = order([1, 2], parked: [7, 8], chevron: true)
    o.foldedParked = [k(7)]
    let r = try run(o).0
    #expect(r.folded.isEmpty && ints(r.unread).contains(7))
}

@Test func trustedExcludesEachUntrustedClass() throws {
    var o = order([1, 2, 3, 4, 5, 6, 7, 8])
    o.uncorroborated = [k(2)]
    o.staleOnBar = [k(3)]
    let c = ReadContext(kind: .pass, unreadOwners: [UnreadOwner(pid: 600, bundleID: "app.6")], handDragUnverified: [k(4)], immovable: [k(5)])
    let r = try run(o, c, record: [1, 2, 3, 4, 5, 6, 7, 8]).0
    #expect(ints(r.trusted) == [1, 7, 8])
    #expect(ints(r.drawn) == [1, 4, 5, 7, 8])          // 2 (uncorroborated), 3 (stale) and 6 (unread owner) leave drawn: they are unread
    #expect(ints(r.unread) == [2, 3, 6])
}

@Test func selfPositioningKeysAreTrustedOnlyOnACompleteRead() throws {
    let istat = ItemKey.status(ownerKey: "com.bjango.istatmenus.status", autosaveName: "cpu")
    let o = ObservedOrder(onBar: [k(1), istat, k(2)], parked: [])
    var keys = CoreKeys()
    for (lvl, expectIStat) in [(ReadCompleteness.complete, true), (.completeExceptSelfPositioning, false), (.incomplete, false)] {
        let a = try ReadAdapter.adapt(o, context: ReadContext(kind: .pass, level: lvl), record: [k(1), istat, k(2)], keys: &keys)
        let id = try keys.intern(istat)
        #expect(a.read.trusted.contains(id) == expectIStat, "level \(lvl)")
        #expect(a.read.drawn.contains(id))
        #expect(a.read.trusted.contains(try keys.intern(k(1))))
    }
}

@Test func unreadCollectsEverySourceInADeterministicOrder() throws {
    var o = order([1, 2, 3], parked: [7, 8, 9, 10, 11], chevron: true)
    o.placementUnknown = [k(7)]
    o.parkedUnreadable = [k(8)]                    // nil Control Center flag, or allowed
    o.foldedParked = [k(9)]
    o.staleOff = [k(12)]
    let c = ReadContext(kind: .pass, unreadOwners: [UnreadOwner(pid: 1, bundleID: "app.2")])
    let r = try run(o, c).0
    #expect(Set(ints(r.unread)) == [2, 7, 8, 9, 12])           // 10 and 11 are parked and hidden by Control Center: not unread
    #expect(ints(r.unread) == [2, 7, 8, 9, 12])                 // onBar, then parked, then stale off-bar
    #expect(!ints(r.trusted).contains(2))
}

@Test func unreadOwnersMapToKeysByPidBundleIdOrNameOverApproximating() throws {
    let info = ItemInfo(key: k(1), title: "t", axDescription: "", ownerPID: 42, ownerBundleID: "x.y", ownerName: "Foo", width: 24, isOnBar: true)
    let named = ItemKey.status(ownerKey: "Some Process", autosaveName: "s")
    var o = ObservedOrder(onBar: [k(1), k(2), k(3), named, .module(name: "Clock")], parked: [])
    o.uncorroborated = []
    func unreadFor(_ owner: UnreadOwner) throws -> Set<String> {
        var keys = CoreKeys()
        let c = ReadContext(kind: .pass, unreadOwners: [owner], itemInfo: [k(1): info])
        let a = try ReadAdapter.adapt(o, context: c, record: [], keys: &keys)
        return Set(a.read.unread.compactMap { keys.key(for: $0)?.description })
    }
    #expect(try unreadFor(UnreadOwner(pid: 42, bundleID: nil)) == [k(1).description])                       // by pid via itemInfo
    #expect(try unreadFor(UnreadOwner(pid: 1, bundleID: "X.Y")) == [k(1).description])                     // by bundle id, case-insensitive
    #expect(try unreadFor(UnreadOwner(pid: 1, bundleID: nil, name: "foo")) == [k(1).description])          // by process name
    #expect(try unreadFor(UnreadOwner(pid: 1, bundleID: "app.3")) == [k(3).description])                    // by the key's own owner key
    #expect(try unreadFor(UnreadOwner(pid: 1, bundleID: nil, name: "Some Process")) == [named.description])  // owner key that is a process name
    #expect(try unreadFor(UnreadOwner(pid: 9, bundleID: "nobody")).isEmpty)
}

@Test func nearFoldIsTheChurnZoneMinusThePile() throws {
    let o = order([1, 2, 3, 4], pile: [1], chevron: true)
    let r = try run(o, ReadContext(kind: .pass, churnZone: [k(1), k(2), k(4)])).0
    #expect(ints(r.nearFold) == [2, 4])
}

@Test func notFullProvenIsAlwaysFalse() throws {
    for lvl in [ReadCompleteness.complete, .incomplete] { #expect(try !run(order([1], chevron: true), ReadContext(kind: .pass, level: lvl)).0.notFullProven) }
}

@Test func recordDropsTheChevronAndImmovablesAndDuplicates() throws {
    let o = order([1, 2, 3], chevron: true)
    var keys = CoreKeys()
    let c = ReadContext(kind: .pass, immovable: [k(2)])
    let a = try ReadAdapter.adapt(o, context: c, record: [k(3), k(1), k(3), chev, k(2), k(4)], keys: &keys)
    #expect(a.record.compactMap { keys.key(for: $0) } == [k(3), k(1), k(4)])
    // a chevron seen on an earlier read stays out of the record on later reads
    let b = try ReadAdapter.adapt(ObservedOrder(onBar: [k(1)], parked: []), context: ReadContext(kind: .pass), record: [chev, k(1)], keys: &keys)
    #expect(b.record.compactMap { keys.key(for: $0) } == [k(1)])
}

private let istatKey = ItemKey.status(ownerKey: "com.bjango.istatmenus.status", autosaveName: "cpu")

/// A scanner item as the Reconciler sees it. Everything the live scanner can produce: stale/carried frames and overflow flags, corroborated or not.
private func scannerItem(_ key: ItemKey, pid: pid_t, bundle: String?, name: String, x: CGFloat, onBar: Bool, stale: Bool = false, recent: Bool = false,
                         overflow: Bool = false, corroborated: Bool = true, allowed: Bool? = true, hidden: Bool = false, unknown: Bool = false,
                         chevron: Bool = false, expanded: Bool = false, width: CGFloat = 24, hostedOnly: Bool = false) -> ResolvedItem {
    var it = MenuBarItem(ownerPID: pid, ownerBundleID: bundle, ownerName: name, title: "", axDescription: "", axIdentifier: corroborated ? "id.\(key.description)" : "",
                         frame: CGRect(x: onBar ? x : -1000, y: 0, width: width, height: 24), source: hostedOnly ? .agentHostedOnly : .appExtras, isOnMenuBar: onBar,
                         isOverflowChevron: chevron, systemOverflow: overflow, joinEvidence: corroborated ? .identifier : .none)
    it.stale = stale; it.recentlyVerified = recent; it.controlCenterAllowed = allowed; it.hiddenInControlCenter = hidden; it.placementUnknown = unknown
    it.stripExpanded = expanded
    return ResolvedItem(item: it, key: key, confidence: .exact)
}


@Test func anIStatCarriedAtExceptSelfPositioningUnderAFreshChevronIsUnreadNeverPileOrTrusted() throws {
    // iStat's items are stale (carried from the last read), keep their old overflow flag ("behind the chevron"), and the read is exceptSelfPositioning.
    // The user may have opened them since: the read must not claim they are behind the chevron (A2).
    let chevItem = ItemKey.status(ownerKey: "com.apple.menuextra.chevron", autosaveName: "chevron")
    let items = [
        scannerItem(k(1), pid: 101, bundle: "app.1", name: "A", x: 100, onBar: true, overflow: true),
        scannerItem(istatKey, pid: 200, bundle: "com.bjango.istatmenus.status", name: "iStat", x: 100, onBar: true, stale: true, recent: true, overflow: true, corroborated: false),
        scannerItem(chevItem, pid: 99, bundle: "agent", name: "agent", x: 140, onBar: true, chevron: true),
        scannerItem(k(2), pid: 102, bundle: "app.2", name: "B", x: 200, onBar: true),
    ]
    let order = ObservedOrder(resolved: items)
    #expect(order.overflowChevron == chevItem && order.systemOverflow.contains(istatKey) && order.staleOnBar == [istatKey])
    var keys = CoreKeys()
    let a = try ReadAdapter.adapt(order, context: ReadContext(kind: .pass, level: .completeExceptSelfPositioning), record: [k(1), istatKey, k(2)], keys: &keys)
    let iid = try keys.intern(istatKey)
    #expect(a.read.chevron == .fresh)
    #expect(!a.read.pile.contains(iid) && !a.read.drawn.contains(iid) && !a.read.trusted.contains(iid))
    #expect(a.read.unread == [iid])
    #expect(a.read.pile.compactMap { keys.key(for: $0) } == [k(1)] && a.read.drawn.compactMap { keys.key(for: $0) } == [k(2)])
}

@Test func aChevronIsExcludedByRoleSoAStaleOffBarChevronIsNeverInterned() throws {
    let other = ItemKey.status(ownerKey: "weird", autosaveName: "chev2")
    let items = [resolved(1, onBar: true), scannerItem(other, pid: 99, bundle: "agent", name: "agent", x: 0, onBar: false, stale: true, chevron: true)]
    let order = ObservedOrder(resolved: items)
    #expect(order.chevronKeys == [other] && order.staleOff.isEmpty && order.parked.isEmpty)    // dropped by the filter, but known by role
    var keys = CoreKeys()
    let a = try ReadAdapter.adapt(order, context: ReadContext(kind: .pass), record: [k(1), other], keys: &keys)
    #expect(keys.id(for: other) == nil && keys.count == 1 && a.record.count == 1)
    #expect(throws: CoreKeysError.chevron(other)) { try keys.intern(other) }
}

@Test func anUnreadOwnerMatchesByOwnerKeyCandidatesNotJustTheDisplayName() throws {
    // an app outside installed locations: its items are keyed by the EXECUTABLE name, which is neither its bundle id nor its display name
    let exeKey = ItemKey.status(ownerKey: "my-exe", autosaveName: "x")
    var keys = CoreKeys()
    let order = ObservedOrder(onBar: [k(1), exeKey], parked: [])
    let owner = UnreadOwner(pid: 77, bundleID: "com.me.app", name: "My Display Name", ownerKeys: ["my-exe", "com.me.app"])
    let a = try ReadAdapter.adapt(order, context: ReadContext(kind: .pass, unreadOwners: [owner]), record: [k(1), exeKey], keys: &keys)
    #expect(a.read.unread.compactMap { keys.key(for: $0) } == [exeKey] && a.unmatchedOwners.isEmpty)
}

@Test func aGhostOwnerDoesNotBlockTheNotRunningConclusionAndAnUnreadOwnersKeyLogsOncePerRead() throws {
    final class Lines: @unchecked Sendable { var l: [String] = []; let lock = NSLock(); func add(_ s: String) { lock.lock(); l.append(s); lock.unlock() } }
    let lines = Lines()
    var keys = CoreKeys()
    var order = ObservedOrder(onBar: [k(1), k(2), chev], parked: [k(3)], systemOverflow: [k(1)], overflowChevron: chev)
    order.chevronAnyKey = chev
    let ghost = UnreadOwner(pid: 5, bundleID: "ghost", name: "Ghost")
    let ev = OwnerEvidence(running: [ghost])
    let ctx = ReadContext(kind: .pass, unreadOwners: [ghost], ownerEvidence: ev, log: { lines.add($0) })
    let a = try ReadAdapter.adapt(order, context: ctx, record: [k(1), k(2), k(3), k(4)], keys: &keys)
    #expect(a.unmatchedOwners == [ghost])
    // k1 pile, k2 drawn; k3 parked and hidden by Control Center (B); k4's owner is not running: (i) holds whatever else is going on (the ghost does not block it)
    #expect(a.read.unread.isEmpty)
    #expect(a.absenceRules[k(4)]?.hasPrefix("absent: (i)") == true && a.absenceRules[k(3)]?.hasPrefix("absent: (B)") == true)
    #expect(lines.l.isEmpty)
    // a running owner of k4 that the scan did not read: nothing shows k4 is gone: unread, logged ONCE per read (not per key)
    let owner4 = UnreadOwner(pid: 6, bundleID: "app.4", name: "Four", ownerKeys: ["app.4"])
    let ctx4 = ReadContext(kind: .pass, ownerEvidence: OwnerEvidence(running: [owner4]), log: { lines.add($0) })
    let b = try ReadAdapter.adapt(ObservedOrder(onBar: [k(1)], parked: []), context: ctx4, record: [k(1), k(4), k(7)], keys: &keys)
    #expect(b.read.unread.compactMap { keys.key(for: $0) } == [k(4)])
    #expect(lines.l.count == 1)
    // and with no evidence at all nothing may be concluded absent
    let blind = try ReadAdapter.adapt(order, context: ReadContext(kind: .pass), record: [k(1), k(2), k(3), k(4)], keys: &keys)
    #expect(blind.read.unread.compactMap { keys.key(for: $0) } == [k(4)])
}

@Test func aCachedFastPathOwnerIsListedDrawnButUntrustedNotUnread() throws {
    var keys = CoreKeys()
    let info = ItemInfo(key: k(1), title: "", axDescription: "", ownerPID: 42, ownerBundleID: "app.1", ownerName: "A", width: 24, isOnBar: true)
    let ctx = ReadContext(kind: .poll, cachedOwners: [UnreadOwner(pid: 42, bundleID: "app.1", name: "A")], itemInfo: [k(1): info])
    let a = try ReadAdapter.adapt(ObservedOrder(onBar: [k(1), k(2)], parked: []), context: ctx, record: [k(1), k(2)], keys: &keys)
    #expect(a.read.drawn.compactMap { keys.key(for: $0) } == [k(1), k(2)] && a.read.unread.isEmpty)
    #expect(a.read.trusted.compactMap { keys.key(for: $0) } == [k(2)])
}

// MARK: outcome mapper (wiring plan section 2)

private let someSnap = MenuBarSnapshot(items: [], capturedAt: Date(timeIntervalSince1970: 0))

@Test func verifiedMapsToVerifiedAndPostedIsTheTouchedMouseFlag() {
    for touched in [false, true] {
        let m = OutcomeMapper.map(.verified(someSnap), touchedMouse: touched)
        #expect(m.outcome == .verified && m.posted == touched)
    }
}

@Test func userBusyMapsToBusy() {
    for touched in [false, true] {
        let m = OutcomeMapper.map(.failed(.userBusy, nil), touchedMouse: touched)
        #expect(m.outcome == .busy && m.posted == touched)
    }
}

@Test func refusalsMapToRefused() {
    let refusals: [ActuationError] = [
        .mechanismFailed("X \(ActuationError.overflowRefusalMarker); nothing is aimed at a folded key"),
        .unsupportedItem(reason: "cannot move"), .notFound,
        .mechanismFailed("X \(ActuationError.stripNotAllowedMarker)"),
    ]
    for e in refusals { for touched in [false, true] {
        let m = OutcomeMapper.map(.failed(e, someSnap), touchedMouse: touched)
        #expect(m.outcome == .refused && m.posted == touched, "\(e)")
    } }
}

@Test func everythingElseMapsToFailedIncludingStripHoldFailures() {
    let failures: [ActuationError] = [
        .notVerified(expected: "a", observed: "b"), .timeout, .permissionDenied, .mechanismFailed("could not post mouse events"),
        .conflictingManager("Bartender"), .liveWriteFailed("x"), .memberStale("x"),
        .mechanismFailed(ActuationError.stripOpenFailureMessage), .mechanismFailed(ActuationError.stripUnplaceableMessage),
        .mechanismFailed(ActuationError.stripMoveDidNotHoldMessage),
    ]
    for e in failures { for touched in [false, true] {
        let m = OutcomeMapper.map(.failed(e, nil), touchedMouse: touched)
        #expect(m.outcome == .failed && m.posted == touched, "\(e)")
    } }
    #expect(ActuationError.mechanismFailed(ActuationError.stripOpenFailureMessage).isStripHoldFailure)
}

@Test func theStripRefusalIsDistinctFromTheOverflowRefusal() {
    let e = ActuationError.mechanismFailed("X \(ActuationError.stripNotAllowedMarker)")
    #expect(e.isStripNotAllowedRefusal && !e.isOverflowRefusal && !e.isStripHoldFailure)
    #expect(!ActuationError.mechanismFailed("X \(ActuationError.overflowRefusalMarker)").isStripNotAllowedRefusal)
}

// MARK: Reconciler additions (staleOff, parkedUnreadable, chevronAnyKey)

private func resolved(_ n: Int, onBar: Bool, stale: Bool = false, allowed: Bool? = true, hidden: Bool = false, unknown: Bool = false, chevron: Bool = false) -> ResolvedItem {
    var it = MenuBarItem(ownerPID: pid_t(100 + n), ownerBundleID: "app.\(n)", ownerName: "App\(n)", title: "", axDescription: "", axIdentifier: "id\(n)",
                         frame: CGRect(x: onBar ? CGFloat(100 + n * 30) : -1000, y: 0, width: 24, height: 24), source: .appExtras, isOnMenuBar: onBar,
                         isOverflowChevron: chevron, joinEvidence: .identifier)
    it.stale = stale; it.controlCenterAllowed = allowed; it.hiddenInControlCenter = hidden; it.placementUnknown = unknown
    return ResolvedItem(item: it, key: chevron ? chev : k(n), confidence: .exact)
}

@Test func observedOrderCollectsStaleOffItemsAndUnreadableParkedKeys() {
    let o = ObservedOrder(resolved: [
        resolved(1, onBar: true), resolved(2, onBar: true, stale: true),
        resolved(3, onBar: false, stale: true),                     // dropped by the filter: staleOff
        resolved(4, onBar: false, allowed: nil),                    // nil Control Center flag
        resolved(5, onBar: false, unknown: true),                   // placement unknown
        resolved(6, onBar: false, allowed: false),                  // hidden by Control Center: really parked
        resolved(7, onBar: false, allowed: true, hidden: true),     // hidden: really parked
        resolved(8, onBar: false, allowed: true),                   // allowed, not drawn
    ])
    #expect(o.staleOff == [k(3)])
    #expect(o.parkedUnreadable == [k(4), k(5), k(8)])
    #expect(o.parked == [4, 5, 6, 7, 8].map(k) && o.onBar == [1, 2].map(k))
    #expect(o.chevronAnyKey == nil)
    let c = ObservedOrder(resolved: [resolved(1, onBar: true), resolved(9, onBar: true, stale: true, chevron: true)])
    #expect(c.chevronAnyKey == chev && c.overflowChevron == nil && c.chevronPresent)
}

@Test func anAdaptedScanSendsStaleOffAndUnreadableParkedKeysToUnread() throws {
    let o = ObservedOrder(resolved: [resolved(1, onBar: true), resolved(3, onBar: false, stale: true), resolved(4, onBar: false, allowed: nil), resolved(6, onBar: false, allowed: false)])
    let r = try run(o).0
    #expect(ints(r.unread) == [4, 3] || Set(ints(r.unread)) == [3, 4])
    #expect(!ints(r.unread).contains(6))
}

// MARK: scanner: a failed app's keys land in unread

private struct UnreadSource: AccessibilitySource {
    var currentPID: pid_t = 1
    var apps: [RunningAppInfo]
    var extras: [pid_t: [AXElementInfo]] = [:]
    var failing: Set<pid_t> = []
    var tree: AgentHostedTree
    func runningApps() -> [RunningAppInfo] { apps }
    func extrasItems(for app: RunningAppInfo) -> [AXElementInfo] { extras[app.pid] ?? [] }
    func readExtras(for app: RunningAppInfo, timeout: Float?) -> ExtrasRead {
        failing.contains(app.pid) ? .failed("fixture timeout") : .items(extrasItems(for: app))
    }
    func agentHostedTree(for agent: RunningAppInfo) -> AgentHostedTree { tree }
}

@Test func aFailedAppsKeysLandInUnreadAndOkAppsStayTrusted() throws {
    let agent = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
    let good = RunningAppInfo(pid: 10, bundleID: "app.good", name: "Good")
    let bad = RunningAppInfo(pid: 11, bundleID: "app.bad", name: "Bad")
    func bar(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 3, width: 24, height: 24) }
    var s = UnreadSource(apps: [agent, good, bad], tree: AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [
        AXElementInfo(axDescription: "Good", identifier: "good1", frame: bar(300)), AXElementInfo(axDescription: "Bad", identifier: "bad1", frame: bar(200))]))
    s.extras[10] = [AXElementInfo(axDescription: "Good", identifier: "good1", frame: bar(300))]
    s.extras[11] = [AXElementInfo(axDescription: "Bad", identifier: "bad1", frame: bar(200))]
    var scanner = MenuBarScanner(source: s)
    let first = scanner.scan()                                     // everything reads fine: nothing unread, and the cache is filled
    #expect(first.unreadOwners.isEmpty)
    s.failing = [11]
    scanner.source = s                                             // same scanner: the failed app falls back to its cached (stale) items
    let snap = scanner.scan()
    #expect(snap.unreadOwners.map(\.pid) == [11] && snap.unreadOwners[0].bundleID == "app.bad" && snap.unreadOwners[0].ownerKeys.contains("app.bad"))
    // through the observer and the adapter
    let resolver = IdentityResolver(prefs: FixturePrefs(), ownerInfo: { _ in nil })
    let items = resolver.resolve(snapshot: snap)
    let obs = BarObservation(items: items, settled: true, scans: 1, completeness: snap.completeness, unreadOwners: snap.unreadOwners)
    let ord = ObservedOrder(resolved: items)
    var info: [ItemKey: ItemInfo] = [:]
    for r in items { info[r.key] = ItemInfo(key: r.key, title: r.item.title, axDescription: r.item.axDescription, ownerPID: r.item.ownerPID, ownerBundleID: r.item.ownerBundleID, ownerName: r.item.ownerName, width: 24, isOnBar: r.item.isOnMenuBar) }
    var keys = CoreKeys()
    let a = try ReadAdapter.adapt(ord, context: ReadContext(observation: obs, kind: .pass, itemInfo: info), record: items.map(\.key), keys: &keys)
    let badKeys = items.filter { $0.item.ownerPID == 11 }.map(\.key)
    let goodKeys = items.filter { $0.item.ownerPID == 10 }.map(\.key)
    #expect(!badKeys.isEmpty && !goodKeys.isEmpty)
    let unreadKeys = Set(a.read.unread.compactMap { keys.key(for: $0) })
    #expect(Set(badKeys).isSubset(of: unreadKeys) && unreadKeys.isDisjoint(with: goodKeys))
    let trustedKeys = Set(a.read.trusted.compactMap { keys.key(for: $0) })
    #expect(trustedKeys.isDisjoint(with: badKeys))
}

@Test func theFastPathAndTheSkipSetReportTheirAppsUnread() {
    let agent = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
    let empty = RunningAppInfo(pid: 12, bundleID: "app.empty", name: "Empty")
    let a = RunningAppInfo(pid: 10, bundleID: "app.a", name: "A")
    let s = UnreadSource(apps: [agent, a, empty], extras: [10: [AXElementInfo(axDescription: "A", identifier: "a1", frame: CGRect(x: 300, y: 3, width: 24, height: 24))]],
                         tree: AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [AXElementInfo(axDescription: "A", identifier: "a1", frame: CGRect(x: 300, y: 3, width: 24, height: 24))]))
    var scanner = MenuBarScanner(source: s)
    let first = scanner.scan()
    #expect(first.unreadOwners.isEmpty)
    let second = scanner.scan()            // "Empty" read empty last time: skipped for the empty TTL, so unread
    #expect(second.unreadOwners.map(\.pid) == [12])
    var s2 = s
    s2.apps.append(RunningAppInfo(pid: 13, bundleID: "app.new", name: "New"))   // launched since the last full scan: no cache
    scanner.source = s2
    let fast = scanner.scanVisible()       // an app with a valid cache is attributed from it (cached, untrusted); one without is unread
    #expect(Set(fast.cachedOwners.map(\.pid)) == [10, 12])
    #expect(fast.unreadOwners.map(\.pid) == [13])
}

// MARK: ejb.13 corrective pass 2: one real item under two keys (fast path)

@Test func aCachedAppsItemSurfacedAsAModuleKeyLeavesTheRecordKeyUnreadAndTheModuleKeyUntrusted() throws {
    let old = ItemKey.status(ownerKey: "app.42", autosaveName: "old")
    let thing = ItemKey.module(name: "New thing")
    var keys = CoreKeys()
    let info = ItemInfo(key: old, title: "", axDescription: "", ownerPID: 42, ownerBundleID: "app.42", ownerName: "A", width: 24, isOnBar: true)
    let ctx = ReadContext(kind: .poll, cachedOwners: [UnreadOwner(pid: 42, bundleID: "app.42", name: "A", ownerKeys: ["app.42"])], itemInfo: [old: info])
    let a = try ReadAdapter.adapt(ObservedOrder(onBar: [thing], parked: []), context: ctx, record: [old], keys: &keys)
    #expect(a.read.drawn.compactMap { keys.key(for: $0) } == [thing])          // drawn ...
    #expect(a.read.trusted.isEmpty)                                            // ... but untrusted (A4)
    #expect(a.read.unread.compactMap { keys.key(for: $0) } == [old])           // the record's key for the same item is unread, not lost
}

@Test func ownerNamesAreLookedUpOncePerLaunchNotOncePerPoll() {
    final class Count: @unchecked Sendable { var n = 0; let l = NSLock(); func hit() { l.lock(); n += 1; l.unlock() }; var value: Int { l.lock(); defer { l.unlock() }; return n } }
    let count = Count()
    let agent = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
    let a = RunningAppInfo(pid: 10, bundleID: "app.a", name: "A"), b = RunningAppInfo(pid: 11, bundleID: "app.b", name: "B")
    let tree = AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [])
    var scanner = MenuBarScanner(source: UnreadSource(apps: [agent, a, b], tree: tree))
    scanner.ownerInfo = { _ in count.hit(); return nil }
    _ = scanner.scanVisible()
    let afterFirst = count.value
    #expect(afterFirst == 3)                                  // one lookup per running app (the agent included)
    _ = scanner.scanVisible(); _ = scanner.scanVisible()
    #expect(count.value == afterFirst)                         // later polls do not look again
    scanner.source = UnreadSource(apps: [agent, a], tree: tree)   // b quit
    _ = scanner.scanVisible()
    scanner.source = UnreadSource(apps: [agent, a, b], tree: tree)   // b launched again: a new launch is looked up again
    _ = scanner.scanVisible()
    #expect(count.value == afterFirst + 1)
}

// MARK: the reviewer's reproduction: real scanner, observer, resolver and adapter

private struct ScanningBox: SnapshotScanning, @unchecked Sendable {
    let scanner: MenuBarScanner
    func scanVisible() async -> MenuBarSnapshot { scanner.scanVisible() }
    func scan() async -> MenuBarSnapshot { scanner.scan() }
}

/// App `a` returns an EMPTY successful read while its item is on the bar: the hosted element matches nothing, so it surfaces as `module:a1`, while the
/// record holds `heuristic:app.a::a1#0`. Repeated over two scans (emptyTTL 0 so the second scan reads again instead of skipping the app).
@Test func anEmptySuccessfulReadWithAnOnBarItemLeavesTheRecordKeyUnreadAndTheModuleKeyUntrusted() async throws {
    let agent = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
    let a = RunningAppInfo(pid: 10, bundleID: "app.a", name: "A")
    let b = RunningAppInfo(pid: 11, bundleID: "app.b", name: "B")
    func bar(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 3, width: 24, height: 24) }
    var src = UnreadSource(apps: [agent, a, b], tree: AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [
        AXElementInfo(axDescription: "a1", identifier: "a1", frame: bar(300)), AXElementInfo(axDescription: "B one", identifier: "b1", frame: bar(200))]))
    src.extras[11] = [AXElementInfo(axDescription: "B one", identifier: "b1", frame: bar(200))]   // b reads fine; a reads EMPTY
    let scanner = MenuBarScanner(source: src, emptyTTL: 0)
    let resolver = IdentityResolver(prefs: FixturePrefs(), ownerInfo: { _ in nil })
    let observer = AgreedScanObserver(scanner: ScanningBox(scanner: scanner), resolve: { resolver.resolve(snapshot: $0) }, maxScans: 4, deadline: 15,
                                      accessibilityTrusted: { true }, sleep: { _ in })
    let obs = try await observer.observeDetailed(progress: nil)
    #expect(obs.scans == 2 && obs.settled)
    let ev = try #require(obs.ownerEvidence)
    #expect(Set(ev.running.map(\.pid)) == [10, 11, 99])                 // everyone running after the last AX read
    #expect(obs.unreadOwners.isEmpty)                                    // neither unread nor cached: the read SUCCEEDED
    let module = try #require(obs.items.first { $0.item.axIdentifier == "a1" || $0.key.description.contains("a1") }?.key)
    #expect(module.description.hasPrefix("module:"))
    let recA = ItemKey.heuristic(bundleID: "app.a", fingerprint: "a1", ordinal: 0)
    let bKey = try #require(obs.items.first { $0.item.ownerPID == 11 }?.key)
    var info: [ItemKey: ItemInfo] = [:]
    for r in obs.items { info[r.key] = ItemInfo(key: r.key, title: "", axDescription: "", ownerPID: r.item.ownerPID, ownerBundleID: r.item.ownerBundleID, ownerName: r.item.ownerName, width: 24, isOnBar: r.item.isOnMenuBar) }
    var keys = CoreKeys()
    let ad = try ReadAdapter.adapt(ObservedOrder(resolved: obs.items), context: ReadContext(observation: obs, kind: .pass, itemInfo: info), record: [recA, bKey], keys: &keys)
    let drawn = ad.read.drawn.compactMap { keys.key(for: $0) }, unread = ad.read.unread.compactMap { keys.key(for: $0) }, trusted = ad.read.trusted.compactMap { keys.key(for: $0) }
    #expect(drawn.contains(module) && !trusted.contains(module))         // drawn, untrusted (A4)
    #expect(unread == [recA])                                            // the record's key for the same item is unread, not lost (A6)
    #expect(trusted.contains(bKey))                                      // b was read fully and has no record key in doubt: still trusted
}

@Test func aPileKeyOutsideTheRecordIsUnreadNotPile() throws {
    // A2 needs the identity of a pile key to be right: a key the record does not hold may be a record key's item under another key scheme
    let r = try run(order([5, 1, 3], pile: [5, 1], chevron: true), record: [5, 3]).0
    #expect(ints(r.pile) == [5] && ints(r.unread).contains(1) && !ints(r.drawn).contains(1))
}

@Test func hostedOnlyIsDecidedFromTheKeyAloneForMenuBarAgentKeys() {
    #expect(ReadAdapter.isHostedOnly(.heuristic(bundleID: menuBarAgentBundleID, fingerprint: "x", ordinal: 0), nil))
    #expect(ReadAdapter.isHostedOnly(.status(ownerKey: menuBarAgentBundleID, autosaveName: "x"), nil))
    #expect(ReadAdapter.isHostedOnly(.module(name: "Clock"), nil))
    #expect(!ReadAdapter.isHostedOnly(.heuristic(bundleID: "app.a", fingerprint: "x", ordinal: 0), nil))
}

@Test func twoRecordKeysThatLookLikeOneItemLogAWarning() throws {
    final class Lines: @unchecked Sendable { var l: [String] = []; let lock = NSLock(); func add(_ s: String) { lock.lock(); l.append(s); lock.unlock() } }
    let lines = Lines()
    func info(_ key: ItemKey, title: String) -> ItemInfo { ItemInfo(key: key, title: title, axDescription: "", ownerPID: 7, ownerBundleID: "app.7", ownerName: "A", width: 24, isOnBar: true) }
    var keys = CoreKeys()
    let ctx = ReadContext(kind: .pass, log: { lines.add($0) }, itemInfo: [k(1): info(k(1), title: "Same"), k(2): info(k(2), title: "Same"), k(3): info(k(3), title: "Other")],
                          frames: [k(4): CGRect(x: 10, y: 0, width: 24, height: 24), k(5): CGRect(x: 10.4, y: 0, width: 24, height: 24)])
    _ = try ReadAdapter.adapt(ObservedOrder(onBar: [k(1), k(2), k(3), k(4), k(5)], parked: []), context: ctx, record: [k(1), k(2), k(3), k(4), k(5)], keys: &keys)
    #expect(lines.l.filter { $0.contains("WARNING") }.count == 2)    // (k1,k2) share owner and title; (k4,k5) share a frame
}

/// The reviewer's reproduction (pass 4): app `a` reads FINE and its item resolves to `heuristic:app.a::a1#0` (drawn); the record holds `module:a1` for the
/// same item (the key the earlier empty-read case produces). Real scanner, observer, resolver and adapter. The record key must not vanish.
@Test func aRecordModuleKeyForAnItemTheReadShowsAsAHeuristicKeyIsUnreadAndTheHeuristicKeyUntrusted() async throws {
    let agent = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
    let a = RunningAppInfo(pid: 10, bundleID: "app.a", name: "A")
    func bar(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 3, width: 24, height: 24) }
    var src = UnreadSource(apps: [agent, a], tree: AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [
        AXElementInfo(axDescription: "a1", identifier: "a1", frame: bar(300))]))
    src.extras[10] = [AXElementInfo(axDescription: "a1", identifier: "a1", frame: bar(300))]
    let scanner = MenuBarScanner(source: src, emptyTTL: 0)
    let resolver = IdentityResolver(prefs: FixturePrefs(), ownerInfo: { _ in nil })
    let observer = AgreedScanObserver(scanner: ScanningBox(scanner: scanner), resolve: { resolver.resolve(snapshot: $0) }, maxScans: 4, deadline: 15,
                                      accessibilityTrusted: { true }, sleep: { _ in })
    let obs = try await observer.observeDetailed(progress: nil)
    let shown = try #require(obs.items.first { $0.item.ownerPID == 10 }?.key)
    #expect(shown.description == "heuristic:app.a::a1#0")
    let recorded = ItemKey.module(name: "a1")
    var info: [ItemKey: ItemInfo] = [:]
    for r in obs.items { info[r.key] = ItemInfo(key: r.key, title: "", axDescription: "", ownerPID: r.item.ownerPID, ownerBundleID: r.item.ownerBundleID, ownerName: r.item.ownerName, width: 24, isOnBar: r.item.isOnMenuBar) }
    var keys = CoreKeys()
    let ad = try ReadAdapter.adapt(ObservedOrder(resolved: obs.items), context: ReadContext(observation: obs, kind: .pass, itemInfo: info), record: [recorded], keys: &keys)
    #expect(ad.read.unread.compactMap { keys.key(for: $0) } == [recorded])                       // not lost
    #expect(ad.read.drawn.compactMap { keys.key(for: $0) } == [shown] && ad.read.trusted.isEmpty) // drawn, untrusted: not a known key
}

@Test func aHelperProcessOwningTheItemUnderItsOwnBundleIdDoesNotLetTheRecordKeyVanish() throws {
    // record: status:app.a::x (app a is NOT running any more); the bar shows the item under the helper's own bundle id
    let recorded = ItemKey.status(ownerKey: "app.a", autosaveName: "x")
    let shown = ItemKey.status(ownerKey: "app.a.helper", autosaveName: "x")
    let helper = UnreadOwner(pid: 20, bundleID: "app.a.helper", name: "Helper", ownerKeys: ["app.a.helper"])
    var keys = CoreKeys()
    let ev = OwnerEvidence(running: [helper])
    let info = ItemInfo(key: shown, title: "", axDescription: "", ownerPID: 20, ownerBundleID: "app.a.helper", ownerName: "Helper", width: 24, isOnBar: true)
    let ad = try ReadAdapter.adapt(ObservedOrder(onBar: [shown], parked: []), context: ReadContext(kind: .pass, ownerEvidence: ev, itemInfo: [shown: info]), record: [recorded], keys: &keys)
    #expect(ad.read.unread.compactMap { keys.key(for: $0) } == [recorded] && ad.read.trusted.isEmpty)
}

// MARK: pass 5: the reviewer's reproduction with production immovability

/// The reviewer's scenario (scratchpad/adv/ReviewerE13Tests.swift): app `a` reads EMPTY while its item is on the bar. The hosted element surfaces as
/// `module:a1`; in production every `module:` key is IMMOVABLE (CapabilityRules.canMove), and that must not make it "known".
@Test func reviewerE13_anUnattributedModuleKeyCountedImmovableDoesNotLetTheRecordKeyVanish() async throws {
    let agent = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
    let a = RunningAppInfo(pid: 10, bundleID: "app.a", name: "A")
    let b = RunningAppInfo(pid: 11, bundleID: "app.b", name: "B")
    func bar(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 3, width: 24, height: 24) }
    var src = UnreadSource(apps: [agent, a, b], tree: AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [
        AXElementInfo(axDescription: "a1", identifier: "a1", frame: bar(300)), AXElementInfo(axDescription: "B one", identifier: "b1", frame: bar(200))]))
    src.extras[11] = [AXElementInfo(axDescription: "B one", identifier: "b1", frame: bar(200))]
    let scanner = MenuBarScanner(source: src, emptyTTL: 0)
    let resolver = IdentityResolver(prefs: FixturePrefs(), ownerInfo: { _ in nil })
    let observer = AgreedScanObserver(scanner: ScanningBox(scanner: scanner), resolve: { resolver.resolve(snapshot: $0) }, maxScans: 4, deadline: 15,
                                      accessibilityTrusted: { true }, sleep: { _ in })
    let obs = try await observer.observeDetailed(progress: nil)
    let recA = ItemKey.heuristic(bundleID: "app.a", fingerprint: "a1", ordinal: 0)
    let bKey = try #require(obs.items.first { $0.item.ownerPID == 11 }?.key)
    var info: [ItemKey: ItemInfo] = [:]
    for r in obs.items { info[r.key] = ItemInfo(key: r.key, title: "", axDescription: "", ownerPID: r.item.ownerPID, ownerBundleID: r.item.ownerBundleID, ownerName: r.item.ownerName, width: 24, isOnBar: r.item.isOnMenuBar) }
    let caps = CapabilityRules(hasTrackedEntry: { _ in true })
    let immovable = Set(obs.items.map(\.key).filter { !caps.capability(for: $0).canMove })
    #expect(immovable.contains { $0.description.hasPrefix("module:") })      // production: the module key IS immovable
    var keys = CoreKeys()
    let ad = try ReadAdapter.adapt(ObservedOrder(resolved: obs.items), context: ReadContext(observation: obs, kind: .pass, immovable: immovable, itemInfo: info), record: [recA, bKey], keys: &keys)
    let drawn = ad.read.drawn.compactMap { keys.key(for: $0) }, unread = ad.read.unread.compactMap { keys.key(for: $0) }, trusted = ad.read.trusted.compactMap { keys.key(for: $0) }
    #expect(unread == [recA], "A6: recA's item is on the bar (as module:a1) but recA must be unread")
    #expect(ad.absenceRules[recA]?.hasPrefix("unread:") == true)
    #expect(trusted == [bKey] && drawn.contains { $0.description.hasPrefix("module:") })
}

// MARK: the user's real bar (read-only probe data, Tests/SommelierCoreTests/Fixtures/realbar.json)

private struct RealBar: Decodable {
    struct Item: Decodable { var key: String; var bundle: String; var name: String; var pid: Int32; var onBar: Bool; var cc: Bool?; var source: String; var stale: Bool
        var overflow: Bool; var x: Double; var w: Double; var join: String; var desc: String; var title: String }
    struct Scan: Decodable { var file: String; var completeness: String; var items: [Item] }
    struct App: Decodable { var pid: Int32; var bundle: String?; var name: String; var presented: Int }
    struct CC: Decodable { var allowed: Bool; var names: [String] }
    var scans: [Scan]; var running: [App]; var families: [[String]]; var ccEntries: [CC]
}

private func loadRealBar() throws -> RealBar {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/realbar.json")
    return try JSONDecoder().decode(RealBar.self, from: Data(contentsOf: url))
}

@Test func theRealBarAbsentKeysAreDecidedByTheScopedRules() throws {
    let bar = try loadRealBar()
    let caps = CapabilityRules(hasTrackedEntry: { _ in true })
    for scan in bar.scans where scan.file == "list1.json" || scan.file == "list2.json" {
        let level: ReadCompleteness = scan.completeness == "complete" ? .complete : (scan.completeness == "exceptSelfPositioning" ? .completeExceptSelfPositioning : .incomplete)
        let resolved: [ResolvedItem] = scan.items.compactMap { i in
            guard let key = ItemKey(storeKey: i.key) else { return nil }
            return scannerItem(key, pid: i.pid, bundle: i.bundle, name: i.name, x: CGFloat(i.x), onBar: i.onBar, stale: i.stale, overflow: i.overflow,
                               corroborated: i.join != "none", allowed: i.cc, hidden: i.cc == false && !i.onBar, chevron: i.desc == "Show Hidden Menu Bar Items",   // the probe dump omits the chevron flag; the pile (systemOverflow) lies left of this item
                               width: CGFloat(i.w), hostedOnly: i.source == "agentHostedOnly")
        }
        let order = ObservedOrder(resolved: resolved)
        // the record: every shown non-module key, plus one synthetic key per Control Center entry no shown key belongs to (the layout file is not in the probe)
        var record = order.onBar.filter { if case .module = $0 { return false } else { return true } } + order.parked
        var synthetic: [ItemKey] = []
        for e in bar.ccEntries {
            let lower = Set(e.names.map { $0.lowercased() })
            if record.contains(where: { ArrangeSections.ownerBundleID($0).map { lower.contains($0.lowercased()) } ?? false }) { continue }
            let key = ItemKey.status(ownerKey: e.names[0], autosaveName: "Item-0")
            synthetic.append(key); record.append(key)
        }
        // running apps: the scanner's cache (every app it reads) + the agent (shown module items); owner keys = every owner string of the keys the app shows
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
        let ctx = ReadContext(kind: .pass, level: level, ownerEvidence: ev, itemInfo: info, ownerFamilies: bar.families)
        let ad = try ReadAdapter.adapt(order, context: ReadContext(kind: ctx.kind, settled: true, level: level, observed: true, immovable: immovable, ownerEvidence: ev, itemInfo: info, ownerFamilies: bar.families), record: record, keys: &keys)
        func names(_ l: [Key]) -> Set<ItemKey> { Set(l.compactMap { keys.key(for: $0) }) }
        let rec = Set(ad.record.compactMap { keys.key(for: $0) })
        let drawn = names(ad.read.drawn).intersection(rec), pile = names(ad.read.pile).intersection(rec), trusted = names(ad.read.trusted).intersection(rec), unread = names(ad.read.unread).intersection(rec)
        let nonRecordShown = names(ad.read.drawn).union(names(ad.read.pile)).union(names(ad.read.unread)).subtracting(rec)
        let absent = rec.subtracting(drawn).subtracting(pile).subtracting(unread)
        func byRule(_ ks: Set<ItemKey>) -> String { Dictionary(grouping: ks, by: { ad.absenceRules[$0].map { String($0.prefix(while: { $0 != ")" })) + ")" } ?? "listed by the read" }).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", ") }
        let syntheticSet = Set(synthetic)
        print("REALBAR \(scan.file) level=\(level): record \(rec.count) (\(rec.count - syntheticSet.count) shown + \(syntheticSet.count) Control Center entries not shown): drawn \(drawn.count), trusted \(trusted.count), pile \(pile.count), unread \(unread.count), absent \(absent.count). Absent by rule: \(byRule(absent)). Unread by rule: \(byRule(unread)). Shown keys outside the record (system modules, listed untrusted/unread): \(nonRecordShown.count). Synthetic keys: absent \(byRule(absent.intersection(syntheticSet))); unread \(byRule(unread.intersection(syntheticSet)))")
        for k in unread.subtracting(syntheticSet).sorted(by: { $0.description < $1.description }) { print("REALBAR   shown key unread: \(k) (\(ad.absenceRules[k] ?? "stale/uncorroborated/unreadable parked"))") }
        for k in unread.intersection(syntheticSet).sorted(by: { $0.description < $1.description }).prefix(8) { print("REALBAR   synthetic unread: \(k) -> \(ad.absenceRules[k] ?? "-")") }
        // not-running apps (no candidate owner) are absent by (i); a synthetic key whose owner could be running is not
        for k in syntheticSet {
            let noOwner = ReadAdapter.candidateOwners(of: k, facts: ReadAdapter.AbsenceFacts(context: ReadContext(kind: .pass, ownerEvidence: ev, itemInfo: info, ownerFamilies: bar.families)), context: ReadContext(kind: .pass, ownerEvidence: ev, itemInfo: info, ownerFamilies: bar.families)).isEmpty
            if noOwner { #expect(absent.contains(k), "not running => absent by (i): \(k)"); #expect(ad.absenceRules[k]?.hasPrefix("absent: (i)") == true) }
        }
        #expect(!absent.isEmpty && !drawn.isEmpty)
        // every record key that is on the bar is drawn, pile or unread (A6)
        for k in order.onBar where rec.contains(k) { #expect(drawn.contains(k) || pile.contains(k) || unread.contains(k)) }
    }
}

/// Pass 6: any app can set the AX description / identifier the resolver turns into a `module:` key. An app that reads empty while its item is on the bar,
/// described as a macOS module ("VPN", "Battery", "com.apple.menuextra.thing"), must not make its own record key "absent": its owner is running.
@Test(arguments: ["VPN", "Battery", "Clock", "com.apple.menuextra.thing"], [0.0, 20.0])
func aSpoofedSystemModuleNameDoesNotLetTheRecordKeyVanish(name: String, emptyTTL: Double) async throws {
    let agent = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
    let a = RunningAppInfo(pid: 10, bundleID: "app.a", name: "A")
    func bar(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 3, width: 24, height: 24) }
    let src = UnreadSource(apps: [agent, a], tree: AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [
        AXElementInfo(axDescription: name, identifier: name.hasPrefix("com.apple.") ? name : "", frame: bar(300))]))
    let scanner = MenuBarScanner(source: src, emptyTTL: emptyTTL)
    let resolver = IdentityResolver(prefs: FixturePrefs(), ownerInfo: { _ in nil })
    let observer = AgreedScanObserver(scanner: ScanningBox(scanner: scanner), resolve: { resolver.resolve(snapshot: $0) }, maxScans: 4, deadline: 15,
                                      accessibilityTrusted: { true }, sleep: { _ in })
    let obs = try await observer.observeDetailed(progress: nil)
    let shown = try #require(obs.items.first { $0.item.ownerPID == 99 }?.key)
    #expect(shown.description.hasPrefix("module:"))
    let recA = ItemKey.heuristic(bundleID: "app.a", fingerprint: "x", ordinal: 0)
    var info: [ItemKey: ItemInfo] = [:]
    for r in obs.items { info[r.key] = ItemInfo(key: r.key, title: "", axDescription: "", ownerPID: r.item.ownerPID, ownerBundleID: r.item.ownerBundleID, ownerName: r.item.ownerName, width: 24, isOnBar: r.item.isOnMenuBar) }
    let caps = CapabilityRules(hasTrackedEntry: { _ in true })
    var keys = CoreKeys()
    let ad = try ReadAdapter.adapt(ObservedOrder(resolved: obs.items), context: ReadContext(observation: obs, kind: .pass, immovable: Set(obs.items.map(\.key).filter { !caps.capability(for: $0).canMove }), itemInfo: info), record: [recA], keys: &keys)
    #expect(ad.read.unread.compactMap { keys.key(for: $0) } == [recA], "A6: the owner is running, so its key is unread whatever the shown module is called")
}

/// (i) judges "not running" from a `runningApps()` snapshot taken AFTER the scan's last AX read: an app that launched between scan start and the hosted read
/// (its item is already on the bar) is in it, so its record key is not absent.
private final class ChangingApps: @unchecked Sendable {
    let lock = NSLock(); var calls = 0
    let first: [RunningAppInfo], later: [RunningAppInfo]
    init(first: [RunningAppInfo], later: [RunningAppInfo]) { self.first = first; self.later = later }
    func next() -> [RunningAppInfo] { lock.lock(); defer { lock.unlock() }; calls += 1; return calls == 1 ? first : later }
}
private struct LaunchingSource: AccessibilitySource {
    var currentPID: pid_t = 1
    let apps: ChangingApps
    let tree: AgentHostedTree
    func runningApps() -> [RunningAppInfo] { apps.next() }
    func extrasItems(for app: RunningAppInfo) -> [AXElementInfo] { [] }
    func readExtras(for app: RunningAppInfo, timeout: Float?) -> ExtrasRead { .items([]) }
    func agentHostedTree(for agent: RunningAppInfo) -> AgentHostedTree { tree }
}

@Test func anAppThatLaunchedBetweenScanStartAndTheHostedReadIsNotAbsent() throws {
    let agent = RunningAppInfo(pid: 99, bundleID: menuBarAgentBundleID, name: "MenuBarAgent")
    let late = RunningAppInfo(pid: 30, bundleID: "app.late", name: "Late")
    let box = ChangingApps(first: [agent], later: [agent, late])     // the START snapshot lacks `late`; the one after the reads has it
    let tree = AgentHostedTree(stripFrame: CGRect(x: 0, y: 0, width: 2000, height: 30), elements: [
        AXElementInfo(axDescription: "late item", identifier: "late1", frame: CGRect(x: 300, y: 3, width: 24, height: 24))])
    let snap = MenuBarScanner(source: LaunchingSource(apps: box, tree: tree)).scan()
    let resolver = IdentityResolver(prefs: FixturePrefs(), ownerInfo: { _ in nil })
    let items = resolver.resolve(snapshot: snap)
    #expect(snap.ownerEvidence?.running.contains { $0.pid == 30 } == true)
    let recLate = ItemKey.heuristic(bundleID: "app.late", fingerprint: "late1", ordinal: 0)
    var keys = CoreKeys()
    let obs = BarObservation(items: items, settled: true, scans: 1, completeness: snap.completeness, unreadOwners: snap.unreadOwners, cachedOwners: snap.cachedOwners, ownerEvidence: snap.ownerEvidence)
    let ad = try ReadAdapter.adapt(ObservedOrder(resolved: items), context: ReadContext(observation: obs, kind: .pass), record: [recLate], keys: &keys)
    #expect(ad.read.unread.compactMap { keys.key(for: $0) } == [recLate], "A6: the app launched before the read ended; its item is on the bar")
}
