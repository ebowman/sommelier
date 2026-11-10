import CoreGraphics
import Foundation
import Testing
import DecisionCore
@testable import SommelierCore

// gdu.145: duplicate heuristic keys in the record. Every fixture here is anonymised (neutral owners and device names, a neutral date).

private func st(_ owner: String, _ name: String = "Item-0") -> ItemKey { .status(ownerKey: owner, autosaveName: name) }
private func he(_ owner: String, _ fp: String = "", _ n: Int = 0) -> ItemKey { .heuristic(bundleID: owner, fingerprint: fp, ordinal: n) }
private let agent = IdentityResolver.agentBundleID

/// The 15 heuristic keys of the user's record, anonymised: 13 owner duplicates beside a status key, 2 agent-hosted copies. The shapes are kept
/// (empty fingerprint, a title with a masked percentage, a date, a device name with a number, a status sentence).
private let aliasKeys: [ItemKey] = [
    he("com.apple.systemuiserver"), he("com.bjango.istatmenus.status", "com.bjango.istatmenus.combined"), he("signal", " \n ##%"),
    he("ie.boboco.FloTile", "FlöTile"), he("info.marcel-dierkes.KeepingYouAwake"),
    he("co.podzim.boltai-mobile", "BoltAI"), he("85C27NK92C.com.flexibits.fantastical2.mac.helper", "6. March 2020"),
    he("com.valerijs.boguckis.store.TextSniper"), he("com.robinlu.mac.Tooth-Fairy"), he("com.robinlu.mac.Tooth-Fairy", "Owner’s AirPods"),
    he("at.obdev.MicroSnitch", "Micro Snitch, no microphone or camera is active"), he("com.iconfactory.Tot"), he("at.EternalStorms.Yoink"),
    he(agent, " \n ##%"), he(agent, "Shield Lefthalf Filled With A Checkmark Badge"),
]

/// The anonymised record: real items (status and module keys, in an order that interleaves) with each alias placed beside its item.
private func aliasLayout() -> (layout: Layout, real: [ItemKey]) {
    let tm = st("com.apple.systemuiserver", "com.apple.menuextra.TimeMachine")
    let istat = st("com.bjango.istatmenus.status", "com.bjango.istatmenus.cpu")
    let sig = st("signal"), flo = st("ie.boboco.FloTile"), kya = st("info.marcel-dierkes.KeepingYouAwake")
    let wifi = ItemKey.module(name: "WiFi"), clock = ItemKey.module(name: "Clock")
    let vis: [ItemKey] = [tm, aliasKeys[0], istat, wifi, aliasKeys[1], sig, aliasKeys[2], flo, aliasKeys[3], kya, aliasKeys[4], aliasKeys[13], aliasKeys[14], clock]
    let hid: [ItemKey] = [st("co.podzim.boltai-mobile"), st("85C27NK92C.com.flexibits.fantastical2.mac.helper", "Fantastical"), st("com.valerijs.boguckis.store.TextSniper"),
                          aliasKeys[5], aliasKeys[6], aliasKeys[7], st("com.robinlu.mac.Tooth-Fairy"), st("com.robinlu.mac.Tooth-Fairy", "Item-1"), aliasKeys[8], aliasKeys[9],
                          st("at.obdev.MicroSnitch"), aliasKeys[10], st("com.iconfactory.Tot"), aliasKeys[11], st("at.EternalStorms.Yoink"), aliasKeys[12]]
    let l = Layout(visible: vis, hidden: hid, alwaysHidden: [], newItemPolicy: .visibleAtEnd)
    return (l, (vis + hid).filter { !aliasKeys.contains($0) })
}

// MARK: D1: the one predicate

private func dups(_ l: Layout, observed: [ItemKey], unread: Set<String> = [], complete: Bool = true) -> [ItemKey] {
    HeuristicKeyRule.duplicates(in: l, observed: Set(observed), unreadOwners: unread, complete: complete)
}

@Test func aTrueDuplicateIsDropped_theRestKeepsItsOrder_idempotent() {
    let o = "com.x.app", other = st("com.x.other")
    let alias = he(o, "Some App")
    let l = Layout(visible: [st(o), alias, other], hidden: [], alwaysHidden: [], newItemPolicy: .visibleAtEnd)
    let obs = [st(o), other]    // the owner is running, fully read, its one item is under its status key; the heuristic key is not observed
    #expect(dups(l, observed: obs) == [alias])
    let (m, dropped) = HeuristicKeyRule.migrate(l, observed: Set(obs))
    #expect(dropped == [alias] && m.visible == [st(o), other])
    #expect(HeuristicKeyRule.migrate(m, observed: Set(obs)).dropped.isEmpty)
}

@Test func toothFairyShape_twoStaleStatusKeysAndTwoLiveHeuristicKeys_nothingIsDropped() {
    let o = "com.x.fairy"
    let (s0, s1, h0, h1) = (st(o), st(o, "Item-1"), he(o, ""), he(o, "Owner’s AirPods"))
    let l = Layout(visible: [s0, s1, h0, h1], hidden: [], alwaysHidden: [], newItemPolicy: .visibleAtEnd)
    // running: its two items are observed, as heuristic keys; the status keys are only in the record
    #expect(dups(l, observed: [h0, h1]).isEmpty)
    #expect(dups(l, observed: [h0, h1, st("com.x.other")]).isEmpty)
    // NOT running at the first complete scan: nothing of the owner is observed
    #expect(dups(l, observed: [st("com.x.other")]).isEmpty)
    #expect(HeuristicKeyRule.migrate(l, observed: [h0, h1]).layout == l)
    #expect(HeuristicKeyRule.migrate(l, observed: [st("com.x.other")]).layout == l)
}

@Test func anOwnerThatIsNotRunning_unread_orPartiallyRead_keepsItsHeuristicKeys() {
    let o = "com.x.app"
    let alias = he(o, "T")
    let l = Layout(visible: [st(o), alias], hidden: [], alwaysHidden: [], newItemPolicy: .visibleAtEnd)
    #expect(dups(l, observed: []).isEmpty, "not running: nothing of the owner is observed")
    #expect(dups(l, observed: [st(o)], unread: [ReadAdapter.normalisedOwner(o)]).isEmpty, "unread / cache-attributed owner")
    #expect(dups(l, observed: [st(o)], complete: false).isEmpty, "partially read scan")
    #expect(dups(l, observed: [st(o)]) == [alias], "control: the same scan, fully read, drops it")
}

@Test func aHeuristicKeyIsNeverADuplicateWhileOneOfTheOwnersObservedItemsIsNotUnderAStatusKey() {
    let o = "com.x.app"
    let (seen, gone) = (he(o, "Seen"), he(o, "Gone"))
    let l = Layout(visible: [st(o), seen, gone], hidden: [], alwaysHidden: [], newItemPolicy: .visibleAtEnd)
    #expect(dups(l, observed: [st(o), seen]).isEmpty, "an observed heuristic item is real and unaccounted: its owner's other keys stay")
    #expect(dups(l, observed: [st(o), seen, gone]).isEmpty)
}

@Test func anAgentHostedHeuristicKeyIsDroppableOnlyWhenNoHostedElementIsUnjoined() {
    let a1 = he(agent, "One"), a2 = he(agent, "Two")
    let l = Layout(visible: [st("com.x.a"), a1, a2], hidden: [], alwaysHidden: [], newItemPolicy: .visibleAtEnd)
    #expect(dups(l, observed: [st("com.x.a")]) == [a1, a2], "every hosted element joined: the copies go")
    #expect(dups(l, observed: [st("com.x.a"), a1]) == [], "a hosted element is observed unjoined: it may be what a1/a2 is; keep both")
    #expect(dups(l, observed: [st("com.x.a")], unread: [ReadAdapter.normalisedOwner(agent)]).isEmpty, "MenuBarAgent unread")
    #expect(dups(l, observed: [st("com.x.a")], complete: false).isEmpty)
    // an item whose ONLY key is an unobserved agent heuristic key follows the same rule (kept while an unjoined element is on the bar)
    let only = Layout(visible: [a1], hidden: [], alwaysHidden: [], newItemPolicy: .visibleAtEnd)
    #expect(dups(only, observed: [a2]).isEmpty)
    #expect(dups(only, observed: [a1]).isEmpty, "observed: kept")
}

@Test func ownersAreComparedTheWayTheAdapterDoes_caseAndTeamIdPrefix() {
    let l = Layout(visible: [st("86Z3GCJ4MF.com.x.Helper"), he("com.x.helper", "x")], hidden: [], alwaysHidden: [], newItemPolicy: .visibleAtEnd)
    #expect(dups(l, observed: [st("86Z3GCJ4MF.com.x.Helper")]) == [he("com.x.helper", "x")])
}

// MARK: D2: the new-item gate

@Test func aTransientUnjoinedReadIsNotRecorded_aRealSecondItemIsAdmittedAfterTwoCompleteScans() {
    let owner = "com.x.app"
    var layout = Layout(visible: [st(owner)], hidden: [], alwaysHidden: [], newItemPolicy: .visibleAtEnd)
    var gate = HeuristicNewItemGate()
    func scan(_ r: [ItemKey], complete: Bool = true) {
        gate.note(observed: r, layout: layout, complete: complete)
        let new = r.filter { layout.section(of: $0) == nil }.map { NewItem($0, .visible) }
        for n in gate.filter(new, complete: complete).admitted { layout.append(n.key, to: n.section) }
    }
    // joined, unjoined (one scan), joined, unjoined (one scan), joined: the transient fingerprint key is never recorded
    for r in [[st(owner)], [he(owner, "Some App")], [st(owner)], [he(owner, "Some App")], [st(owner)]] { scan(r) }
    #expect(layout.visible == [st(owner)])
    // a genuinely new second identifier-less item (the status key is read too): held on the first sighting, admitted on the second
    let second = he(owner, "Second")
    scan([st(owner), second])
    #expect(layout.visible == [st(owner)], "first sighting")
    scan([st(owner), second], complete: false)    // an incomplete scan neither counts nor resets
    #expect(layout.visible == [st(owner)])
    scan([st(owner), second])
    #expect(layout.visible == [st(owner), second], "second consecutive complete scan")
}

@Test func aMissedCompleteScanResetsTheCount_andStatusKeysAreNeverHeld() {
    let k = he("com.x.plain", "T")
    let layout = Layout.empty
    var gate = HeuristicNewItemGate()
    gate.note(observed: [k], layout: layout, complete: true)
    gate.note(observed: [], layout: layout, complete: true)
    gate.note(observed: [k], layout: layout, complete: true)
    #expect(gate.filter([NewItem(k, .visible)], complete: true).admitted.isEmpty)
    gate.note(observed: [k], layout: layout, complete: true)
    #expect(gate.filter([NewItem(k, .visible)], complete: true).admitted.count == 1)
    #expect(gate.filter([NewItem(k, .visible)], complete: false).admitted.isEmpty, "never on an incomplete scan")
    #expect(HeuristicNewItemGate().filter([NewItem(st("com.x.new"), .visible)], complete: false).admitted.count == 1)
}

// MARK: the engine: trigger, backup, no drag

private struct OpenCaps: CapabilityProvider { func capability(for key: ItemKey) -> Capability { Capability(canMove: true, canHide: true) } }
private struct ActuatorObserver: MenuBarObserver {
    let actuator: FakeActuator
    var unread: [UnreadOwner] = []
    func observe() async throws -> [ResolvedItem] { FakeMenuBar.resolve(FakeMenuBar.snapshot(order: await actuator.order, hidden: await actuator.hidden)) }
    func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> BarObservation {
        BarObservation(items: try await observe(), settled: true, unreadOwners: unread)
    }
}
private func ek(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private func tempLayoutURL() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gdu145-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("layout.json")
}

@MainActor
@Suite struct Gdu145EngineTests {
    private func engine(bar: [ItemKey], store: any LayoutStore, unread: [UnreadOwner] = []) -> (LayoutEngine, FakeActuator, EngineState) {
        let act = FakeActuator(order: bar, hidden: [], capabilities: OpenCaps(), makeSnapshot: { FakeMenuBar.snapshot(order: $0, hidden: $1) })
        var c = LayoutEngine.Config.plain()
        c.minPassInterval = .zero; c.layoutCoalesce = .zero; c.interactionRetry = .seconds(3600); c.maxOrderMovesPerPass = .max
        let state = EngineState()
        return (LayoutEngine(observer: ActuatorObserver(actuator: act, unread: unread), actuator: act, store: store, capabilities: OpenCaps(), state: state, interaction: nil,
                             resolveSnapshot: { FakeMenuBar.resolve($0) }, sleep: { _ in }, log: { _ in }, config: c), act, state)
    }

    @Test func migrationRunsAfterTheFirstCompleteScan_notAtLoad_writesABackup_andCausesNoDrag() async throws {
        let url = try tempLayoutURL()
        let store = FileLayoutStore(url: url)
        let alias = he("com.x.A", "fp")
        try store.save(Layout.placedAll(visible: [ek("A"), alias, ek("B"), ek("C")]))
        let original = try Data(contentsOf: url)
        let (eng, act, state) = engine(bar: [ek("A"), ek("B"), ek("C")], store: store)
        await eng.start()
        #expect(state.layout.visible.contains(alias), "a bare load changes nothing: nothing is observed yet")
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("gdu145-backup").path))
        for _ in 0..<5 { _ = await eng.reconcileOnce() }
        #expect(state.layout.visible == [ek("A"), ek("B"), ek("C")])
        #expect(try store.load().visible == [ek("A"), ek("B"), ek("C")], "saved")
        let backup = url.appendingPathExtension("gdu145-backup")
        #expect(try Data(contentsOf: backup) == original, "the backup is the layout as it was before the migration")
        let calls1 = await act.calls, order1 = await act.order
        #expect(calls1.isEmpty, "a migration never causes a drag: \(calls1)")
        #expect(order1 == [ek("A"), ek("B"), ek("C")])
        // idempotent: a new engine on the migrated file adds no backup and changes nothing
        let (eng2, act2, state2) = engine(bar: [ek("A"), ek("B"), ek("C")], store: store)
        await eng2.start()
        for _ in 0..<5 { _ = await eng2.reconcileOnce() }
        let calls2 = await act2.calls
        #expect(state2.layout.visible == [ek("A"), ek("B"), ek("C")] && calls2.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("gdu145-backup-2").path))
        // an existing backup is never overwritten
        try store.save(Layout.placedAll(visible: [ek("A"), alias, ek("B"), ek("C")]))
        let name = try store.backupBeforeMigration()
        let kept = try Data(contentsOf: backup)
        #expect(name == "layout.json.gdu145-backup-2" && kept == original)
    }

    @Test func theMarkerIsPersisted_andASecondLaunchNeverMigrates_aSometimesAbsentSecondItemKeepsItsKey() async throws {
        let url = try tempLayoutURL()
        let store = FileLayoutStore(url: url)
        let alias = he("com.x.A", "fp")
        try store.save(Layout.placedAll(visible: [ek("A"), alias, ek("B")]))
        let (eng, _, _) = engine(bar: [ek("A"), ek("B")], store: store)
        await eng.start()
        for _ in 0..<5 { _ = await eng.reconcileOnce() }
        #expect(try store.load().migrations == ["gdu145"])
        #expect(try store.load().visible == [ek("A"), ek("B")])
        // a later launch: the app now has a real second item that is only sometimes shown (absent now); it is recorded again, then must survive launches
        var l = try store.load()
        l.visible.insert(alias, at: 1)
        try store.save(l)
        for _ in 0..<2 {
            let (e2, act2, st2) = engine(bar: [ek("A"), ek("B")], store: store)
            await e2.start()
            for _ in 0..<5 { _ = await e2.reconcileOnce() }
            #expect(st2.layout.visible == [ek("A"), alias, ek("B")], "the marker is present: no migration")
            #expect(try store.load().visible == [ek("A"), alias, ek("B")])
            let calls = await act2.calls
            #expect(calls.isEmpty)
        }
        let dir = url.deletingLastPathComponent()
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("gdu145-backup") }
        #expect(backups == ["layout.json.gdu145-backup"], "exactly one backup: \(backups)")
    }

    @Test func theMarkerIsWrittenEvenWhenNothingWasDropped_withNoBackup() async throws {
        let url = try tempLayoutURL()
        let store = FileLayoutStore(url: url)
        try store.save(Layout.placedAll(visible: [ek("A"), ek("B")]))
        let (eng, _, state) = engine(bar: [ek("A"), ek("B")], store: store)
        await eng.start()
        for _ in 0..<3 { _ = await eng.reconcileOnce() }
        #expect(try store.load().migrations == ["gdu145"] && state.layout.migrations == ["gdu145"])
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("gdu145-backup").path))
    }

    @Test func aBackupFailure_noMigration_noMarker_retriedNextLaunch() async throws {
        struct FailingBackup: LayoutStore {
            let inner: InMemoryLayoutStore
            func load() throws -> Layout { try inner.load() }
            func save(_ layout: Layout) throws { try inner.save(layout) }
            func backupBeforeMigration() throws -> String? { throw NSError(domain: "test", code: 1) }
        }
        let alias = he("com.x.A", "fp")
        let rec = Layout.placedAll(visible: [ek("A"), alias, ek("B")])
        let mem = InMemoryLayoutStore(rec)
        let (eng, _, state) = engine(bar: [ek("A"), ek("B")], store: FailingBackup(inner: mem))
        await eng.start()
        for _ in 0..<5 { _ = await eng.reconcileOnce() }
        #expect(state.layout.visible == [ek("A"), alias, ek("B")] && state.layout.migrations.isEmpty)
        #expect(try mem.load() == rec)
    }

    @Test func aStaleArrangeCompositionNeverWritesTheDroppedAliasesBack_orErasesTheMarker() async throws {
        let alias = he("com.x.A", "fp")
        let store = InMemoryLayoutStore(Layout.placedAll(visible: [ek("A"), alias, ek("B"), ek("C")]))
        let (eng, _, state) = engine(bar: [ek("A"), ek("B"), ek("C")], store: store)
        await eng.start()
        let stale = state.layout            // an Arrange window built on the pre-migration layout
        let rev = state.layoutRevision
        for _ in 0..<5 { _ = await eng.reconcileOnce() }
        #expect(!state.layout.visible.contains(alias))
        var edit = stale
        edit.visible = [ek("B"), ek("A"), alias, ek("C")]
        await eng.setLayout(edit, basedOn: rev, moved: [ek("B")])
        #expect(state.layout.visible == [ek("B"), ek("A"), ek("C")], "\(state.layout.visible)")
        #expect(state.layout.migrations == ["gdu145"])
        #expect(try store.load().migrations == ["gdu145"] && !(try store.load().allKeys.contains(alias)))
    }

    @Test func layoutFilesCodeTheMarkerBackwardCompatibly() throws {
        let old = Data(#"{"schemaVersion":1,"visible":["module:Clock"],"hidden":[],"alwaysHidden":[],"newItemPolicy":"visibleAtEnd"}"#.utf8)
        #expect(try Layout.decode(old).layout.migrations.isEmpty)
        #expect(try JSONDecoder().decode(Layout.self, from: old).migrations.isEmpty)
        let l = Layout(visible: [ek("A")], migrations: ["gdu145"])
        let enc = JSONEncoder(); let data = try enc.encode(l)
        #expect(try JSONDecoder().decode(Layout.self, from: data) == l)
        #expect(try Layout.decode(data).layout.migrations == ["gdu145"])
        #expect(!String(decoding: try enc.encode(Layout(visible: [ek("A")])), as: UTF8.self).contains("migrations"), "absent when empty")
    }

    @Test func anObservedHeuristicKeyIsNeverMigratedAway() async throws {
        let alias = he("com.x.A", "fp")
        let store = InMemoryLayoutStore(Layout.placedAll(visible: [ek("A"), alias, ek("B")]))
        let (eng, act, state) = engine(bar: [ek("A"), alias, ek("B")], store: store)
        await eng.start()
        for _ in 0..<5 { _ = await eng.reconcileOnce() }
        #expect(state.layout.visible == [ek("A"), alias, ek("B")])
        let calls = await act.calls
        #expect(calls.isEmpty)
    }

    @Test func aFingerprintReadOfAKnownOwnerIsRecordedOnlyAfterTwoCompleteScans() async throws {
        let alias = he("com.x.A", "fp")
        let store = InMemoryLayoutStore(Layout.placedAll(visible: [ek("A"), ek("B"), ek("C")]))
        // A's item reads without its identifier: only its fingerprint key is on the bar
        let (eng, _, state) = engine(bar: [alias, ek("B"), ek("C")], store: store)
        await eng.start()
        _ = await eng.reconcileOnce()
        #expect(state.layout.allKeys == [ek("A"), ek("B"), ek("C")], "one scan: held, the record did not grow: \(state.layout.allKeys)")
        for _ in 0..<4 { _ = await eng.reconcileOnce() }
        #expect(state.layout.allKeys.contains(alias), "seen on consecutive complete settled scans: admitted, never refused forever")
    }

    @Test func toothFairyShape_isNeverMigrated_whetherItsItemsAreOnTheBarOrNot() async throws {
        let f0 = ek("F"), f1 = ItemKey.status(ownerKey: "com.x.F", autosaveName: "Item-1"), h0 = he("com.x.F", "a"), h1 = he("com.x.F", "b")
        for onBar in [true, false] {
            let url = try tempLayoutURL()
            let store = FileLayoutStore(url: url)
            try store.save(Layout.placedAll(visible: [ek("B"), f0, f1, h0, h1, ek("C")]))
            let (eng, _, state) = engine(bar: onBar ? [ek("B"), h0, h1, ek("C")] : [ek("B"), ek("C")], store: store)
            await eng.start()
            for _ in 0..<5 { _ = await eng.reconcileOnce() }
            #expect(state.layout.allKeys == [ek("B"), f0, f1, h0, h1, ek("C")], "onBar \(onBar): \(state.layout.allKeys)")
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("gdu145-backup").path))
        }
    }

    @Test func anUnreadOwnersHeuristicKeysAreKeptAtMigration() async throws {
        let alias = he("com.x.A", "fp")
        let store = InMemoryLayoutStore(Layout.placedAll(visible: [ek("A"), alias, ek("B")]))
        let unread = [UnreadOwner(pid: 1, bundleID: "com.x.A", name: "A", ownerKeys: ["com.x.A"])]
        let (eng, _, state) = engine(bar: [ek("A"), ek("B")], store: store, unread: unread)
        await eng.start()
        for _ in 0..<5 { _ = await eng.reconcileOnce() }
        #expect(state.layout.visible == [ek("A"), alias, ek("B")])
    }
}

// MARK: the user's record against the real-bar scans (B)

private struct RealBar: Decodable {
    struct Item: Decodable { var key: String; var bundle: String; var name: String; var pid: Int32; var onBar: Bool; var cc: Bool?; var source: String; var stale: Bool
        var overflow: Bool; var x: Double; var w: Double; var join: String; var desc: String; var title: String }
    struct Scan: Decodable { var file: String; var completeness: String; var items: [Item] }
    struct App: Decodable { var pid: Int32; var bundle: String?; var name: String; var presented: Int }
    struct CC: Decodable { var allowed: Bool; var names: [String] }
    var scans: [Scan]; var running: [App]; var families: [[String]]; var ccEntries: [CC]
}

private func scannerItem(_ key: ItemKey, pid: pid_t, bundle: String?, name: String, x: CGFloat, onBar: Bool, stale: Bool, overflow: Bool, corroborated: Bool,
                         allowed: Bool?, hidden: Bool, chevron: Bool, width: CGFloat, hostedOnly: Bool) -> ResolvedItem {
    var it = MenuBarItem(ownerPID: pid, ownerBundleID: bundle, ownerName: name, title: "", axDescription: "", axIdentifier: corroborated ? "id.\(key.description)" : "",
                         frame: CGRect(x: onBar ? x : -1000, y: 0, width: width, height: 24), source: hostedOnly ? .agentHostedOnly : .appExtras, isOnMenuBar: onBar,
                         isOverflowChevron: chevron, systemOverflow: overflow, joinEvidence: corroborated ? .identifier : .none)
    it.stale = stale; it.controlCenterAllowed = allowed; it.hiddenInControlCenter = hidden
    return ResolvedItem(item: it, key: key, confidence: .exact)
}

/// The adapter's read of one fixture scan with `extra` record keys added (the alias keys of the anonymised record), and the counts.
private func replay(_ scan: RealBar.Scan, _ bar: RealBar, record extra: [ItemKey], dropping: Set<ItemKey> = []) throws -> (drawn: Int, trusted: Int, unread: Set<ItemKey>, observed: Set<ItemKey>, record: [ItemKey]) {
    let level: ReadCompleteness = scan.completeness == "complete" ? .complete : (scan.completeness == "exceptSelfPositioning" ? .completeExceptSelfPositioning : .incomplete)
    let caps = CapabilityRules(hasTrackedEntry: { _ in true })
    let resolved: [ResolvedItem] = scan.items.compactMap { i in
        guard let key = ItemKey(storeKey: i.key) else { return nil }
        return scannerItem(key, pid: i.pid, bundle: i.bundle, name: i.name, x: CGFloat(i.x), onBar: i.onBar, stale: i.stale, overflow: i.overflow,
                           corroborated: i.join != "none", allowed: i.cc, hidden: i.cc == false && !i.onBar, chevron: i.desc == "Show Hidden Menu Bar Items",
                           width: CGFloat(i.w), hostedOnly: i.source == "agentHostedOnly")
    }
    let order = ObservedOrder(resolved: resolved)
    var record = order.onBar.filter { if case .module = $0 { return false } else { return true } } + order.parked
    for e in bar.ccEntries {
        let lower = Set(e.names.map { $0.lowercased() })
        if record.contains(where: { ArrangeSections.ownerBundleID($0).map { lower.contains($0.lowercased()) } ?? false }) { continue }
        record.append(ItemKey.status(ownerKey: e.names[0], autosaveName: "Item-0"))
    }
    for k in extra where !record.contains(k) { record.append(k) }
    record.removeAll { dropping.contains($0) }
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
    let ad = try ReadAdapter.adapt(order, context: ReadContext(kind: .pass, settled: true, level: level, observed: true, previousCompletePile: order.systemOverflow, immovable: immovable, ownerEvidence: ev, itemInfo: info, ownerFamilies: bar.families), record: record, keys: &keys)
    func names(_ l: [Key]) -> Set<ItemKey> { Set(l.compactMap { keys.key(for: $0) }) }
    return (ad.read.drawn.count, ad.read.trusted.count, names(ad.read.unread), Set(resolved.map(\.key)), record)
}

@Test func theUsersRecordAgainstTheRealBar_aliasDoubtsDisappearAfterMigration() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/realbar.json")
    let bar = try JSONDecoder().decode(RealBar.self, from: Data(contentsOf: url))
    let scan = try #require(bar.scans.first { $0.file == "list1.json" })
    // the anonymised record: the scan's own keys plus the user's alias keys and the two Tooth Fairy status keys
    let extra = aliasKeys + [st("com.robinlu.mac.Tooth-Fairy"), st("com.robinlu.mac.Tooth-Fairy", "Item-1")]
    let before = try replay(scan, bar, record: extra)
    let layout = Layout(visible: before.record, hidden: [], alwaysHidden: [], newItemPolicy: .visibleAtEnd)
    // every owner of the fixture scan is fully read (a complete scan); the adapter's own unread keys concern its trust, not this predicate
    let (migrated, dropped) = HeuristicKeyRule.migrate(layout, observed: before.observed, unreadOwners: [], complete: true)
    let after = try replay(scan, bar, record: extra, dropping: Set(dropped))
    print("GDU145 replay list1.json: before migration drawn \(before.drawn), trusted \(before.trusted), unread \(before.unread.count); dropped \(dropped.count) keys; after drawn \(after.drawn), trusted \(after.trusted), unread \(after.unread.count)")
    print("GDU145 still unread after: \(after.unread.sorted { $0.description < $1.description }.map(\.description))")
    #expect(dropped.count == 13, "11 owner duplicates + 2 agent copies: \(dropped.map(\.description))")
    #expect(Set(dropped) == Set(aliasKeys).subtracting([aliasKeys[8], aliasKeys[9]]))
    #expect(before.observed.contains(aliasKeys[8]) && before.observed.contains(aliasKeys[9]), "the anonymised Tooth Fairy keys MATCH the fixture's items")
    #expect(migrated.allKeys.contains(aliasKeys[8]) && migrated.allKeys.contains(aliasKeys[9]), "both live Tooth Fairy heuristic keys are kept")
    #expect(migrated.allKeys.contains(st("com.robinlu.mac.Tooth-Fairy")) && migrated.allKeys.contains(st("com.robinlu.mac.Tooth-Fairy", "Item-1")), "its stale status keys are left alone")
    #expect(after.trusted > before.trusted)
    #expect(migrated.allKeys.count == layout.allKeys.count - dropped.count)
    // the order of the surviving record keys is unchanged
    #expect(migrated.allKeys == layout.allKeys.filter { !dropped.contains($0) })
}
