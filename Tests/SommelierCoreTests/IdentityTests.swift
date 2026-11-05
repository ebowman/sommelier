import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

struct FixturePrefs: PreferenceReader {
    var store: [String: Double] = [:]
    var legacy: [String: [AutosaveEntry]] = [:]
    func orderStore() -> [String: Double] { store }
    func legacyEntries(domain: String) -> [AutosaveEntry] { legacy[domain] ?? [] }
}

private func bar(_ x: CGFloat, w: CGFloat = 24) -> CGRect { CGRect(x: x, y: 3, width: w, height: 24) }
private let parked = CGRect(x: 2, y: 1204, width: 24, height: 24)

private func item(pid: pid_t = 10, bid: String? = "a.b", name: String = "A", id: String = "", desc: String = "", title: String = "",
                  frame: CGRect, source: MenuBarItemSource = .appExtras, stale: Bool = false) -> MenuBarItem {
    MenuBarItem(ownerPID: pid, ownerBundleID: bid, ownerName: name, title: title, axDescription: desc, axIdentifier: id,
                frame: frame, source: source, isOnMenuBar: frame.minY < 40 && frame.width > 0, stale: stale)
}

private func resolver(_ p: FixturePrefs, _ infos: [pid_t: OwnerAppInfo] = [:]) -> IdentityResolver {
    IdentityResolver(prefs: p, ownerInfo: { infos[$0] })
}

private func snap(_ items: [MenuBarItem]) -> MenuBarSnapshot { MenuBarSnapshot(items: items, capturedAt: Date(timeIntervalSince1970: 0)) }

// MARK: ItemKey

@Test func storeKeyRoundTrip() {
    let keys = [
        "status:com.bjango.istatmenus.status::com.bjango.istatmenus.cpu",
        "status:com.stairways.keyboardmaestro.engine::Main Status Menu",
        "status:MBDummy::Dummy-A",
        "status:x.y::weird:name: with::colons",
        "status:com.1password.1password::bb3cc23c-6950-4e96-8b40-850e09f46934",
        "module:WiFi", "module:BentoBox-0",
    ]
    for k in keys {
        let parsed = ItemKey(storeKey: k)
        #expect(parsed != nil, "\(k)")
        #expect(parsed?.description == k)
    }
    #expect(ItemKey(storeKey: "status:com.keyboardmaestro::Main Status Menu")
            == .status(ownerKey: "com.keyboardmaestro", autosaveName: "Main Status Menu"))
    // First "::" splits; later colons stay in the autosave name.
    #expect(ItemKey(storeKey: "status:x.y::weird:name: with::colons") == .status(ownerKey: "x.y", autosaveName: "weird:name: with::colons"))
}

@Test func storeKeyRejectsMalformed() {
    #expect(ItemKey(storeKey: "status:Item-0") == nil)   // present in the real store; no separator
    #expect(ItemKey(storeKey: "module:") == nil)
    #expect(ItemKey(storeKey: "plist:status:a::b") == nil)
    #expect(ItemKey(storeKey: "garbage") == nil)
}

@Test func heuristicKeyRoundTripAndCodable() throws {
    let k = ItemKey.heuristic(bundleID: "a.b", fingerprint: "Eric’s AirPods Pro #2", ordinal: 3)
    #expect(ItemKey(storeKey: k.description) == k)
    let data = try JSONEncoder().encode([k, .status(ownerKey: "o", autosaveName: "a b:c"), .module(name: "Clock")])
    let back = try JSONDecoder().decode([ItemKey].self, from: data)
    #expect(back.count == 3 && back[0] == k && back[2] == .module(name: "Clock"))
}

// MARK: OwnerKeyRule

@Test func ownerRuleInstalledPrefersBundleID() {
    let info = OwnerAppInfo(bundleID: "ie.boboco.FloTile", localizedName: "FlöTile", executableName: "FloTile",
                            executablePath: "/Applications/FloTile.app/Contents/MacOS/FloTile", bundleDirName: "FloTile", bundleName: "FloTile")
    #expect(OwnerKeyRule.candidates(for: info) == ["ie.boboco.FloTile", "FloTile", "FlöTile"])
}

@Test func ownerRuleUninstalledPrefersExecutableName() {
    let info = OwnerAppInfo(bundleID: "ie.boboco.mbdummy", localizedName: "MBDummy", executableName: "MBDummy",
                            executablePath: "/Users/x/src/sommelier/build/MBDummy.app/Contents/MacOS/MBDummy", bundleDirName: "MBDummy")
    #expect(OwnerKeyRule.candidates(for: info) == ["MBDummy", "ie.boboco.mbdummy"])
}

@Test func ownerRuleExecutableDiffersFromEverythingElse() {
    let info = OwnerAppInfo(bundleID: "ie.boboco.mbdummyz", localizedName: "dir", executableName: "MBDummyzexe",
                            executablePath: "/Users/x/Applications/MBDummyzdir.app/Contents/MacOS/MBDummyzexe",
                            bundleDirName: "MBDummyzdir", bundleName: "MBDummyzname")
    #expect(OwnerKeyRule.candidates(for: info).first == "MBDummyzexe")
    #expect(OwnerKeyRule.candidates(for: info).contains("ie.boboco.mbdummyz"))
}

@Test func ownerRuleHelperUnderApplicationSupportIsInstalled() {
    #expect(OwnerKeyRule.isInstalledLocation("/Users/x/Library/Application Support/iStat Menus 7/iStat Menus Menubar.app/Contents/MacOS/m"))
    #expect(!OwnerKeyRule.isInstalledLocation("/private/var/folders/2v/T/AppTranslocation/X/d/iStat Menus.app/Contents/MacOS/m"))
    #expect(OwnerKeyRule.isInstalledLocation("/System/Library/CoreServices/Script Menu.app/Contents/MacOS/Script Menu"))
}

// MARK: Resolver branches

@Test func singleItemSingleNameWithIdentifierIsExact() {
    var p = FixturePrefs(); p.store["status:a.b::Item-0"] = 100
    let r = resolver(p).resolve(snapshot: snap([item(id: "maestro.status", frame: bar(500))]))
    #expect(r[0].key == .status(ownerKey: "a.b", autosaveName: "Item-0"))
    #expect(r[0].confidence == .exact)
}

@Test func singleItemWithoutIdentifierIsInferredNotExact() {
    var p = FixturePrefs(); p.store["status:a.b::Item-0"] = 100
    let r = resolver(p).resolve(snapshot: snap([item(frame: bar(500))]))
    #expect(r[0].key == .status(ownerKey: "a.b", autosaveName: "Item-0"))
    #expect(r[0].confidence == .inferred)
}

@Test func staleSingleItemIsNotExact() {
    var p = FixturePrefs(); p.store["status:a.b::Item-0"] = 100
    let r = resolver(p).resolve(snapshot: snap([item(id: "x", frame: bar(500), stale: true)]))
    #expect(r[0].confidence == .inferred)
}

private let istatNames = ["weather", "network", "disks", "battery", "sensors", "memory", "cpu", "time"]
private func istatSnapshot(identifiers: Bool) -> MenuBarSnapshot {
    // left to right, bigger store value = further left
    snap(istatNames.enumerated().map { n, name in
        item(pid: 20, bid: "com.bjango.istatmenus.status", name: "iStat Menus Menubar",
             id: identifiers ? "com.bjango.istatmenus.\(name)" : "", frame: bar(CGFloat(1000 + n * 40)))
    })
}
private func istatPrefs() -> FixturePrefs {
    var p = FixturePrefs()
    for (n, name) in istatNames.enumerated() { p.store["status:com.bjango.istatmenus.status::com.bjango.istatmenus.\(name)"] = Double(600 - n * 60) }
    // Stale second owner key with the same names and a scrambled order (as on the real machine).
    for (n, name) in istatNames.enumerated() { p.store["status:iStat Menus Menubar::com.bjango.istatmenus.\(name)"] = Double(100 + (n * 5 % 8) * 50) }
    return p
}
private let istatInfo: [pid_t: OwnerAppInfo] = [20: OwnerAppInfo(
    bundleID: "com.bjango.istatmenus.status", localizedName: "iStat Menus Menubar", executableName: "iStat Menus Menubar",
    executablePath: "/Applications/iStat Menus.app/Contents/Resources/iStat Menus Menubar.app/Contents/MacOS/iStat Menus Menubar")]

@Test func istatEightItemsResolveByIdentifier() {
    let r = resolver(istatPrefs(), istatInfo).resolve(snapshot: istatSnapshot(identifiers: true))
    #expect(r.count == 8)
    for (n, name) in istatNames.enumerated() {
        #expect(r[n].key == .status(ownerKey: "com.bjango.istatmenus.status", autosaveName: "com.bjango.istatmenus.\(name)"))
        #expect(r[n].confidence == .exact)
    }
}

@Test func istatEightItemsPairByStoreOrderWhenIdentifiersMissing() {
    let r = resolver(istatPrefs(), istatInfo).resolve(snapshot: istatSnapshot(identifiers: false))
    // Both owner keys have the same 8 names; the one whose values agree with x order must win.
    for (n, name) in istatNames.enumerated() {
        #expect(r[n].key == .status(ownerKey: "com.bjango.istatmenus.status", autosaveName: "com.bjango.istatmenus.\(name)"), "slot \(n)")
        #expect(r[n].confidence == .inferred)
    }
}

@Test func orderPairingRefusesParkedItems() {
    var p = FixturePrefs(); p.store["status:a.b::X"] = 300; p.store["status:a.b::Y"] = 200
    let r = resolver(p).resolve(snapshot: snap([item(frame: parked), item(frame: parked)]))
    #expect(r.allSatisfy { $0.confidence == .heuristic })
}

@Test func orderPairingRefusesTiedValues() {
    var p = FixturePrefs(); p.store["status:a.b::X"] = 300; p.store["status:a.b::Y"] = 300
    let r = resolver(p).resolve(snapshot: snap([item(frame: bar(100)), item(frame: bar(200))]))
    #expect(r.allSatisfy { $0.confidence == .heuristic })
}

@Test func partialIdentifierMatchThenSingleRemainder() {
    var p = FixturePrefs(); p.store["status:a.b::A"] = 300; p.store["status:a.b::B"] = 200
    let r = resolver(p).resolve(snapshot: snap([item(id: "A", frame: bar(100)), item(frame: bar(200))]))
    #expect(r[0].key == .status(ownerKey: "a.b", autosaveName: "A") && r[0].confidence == .exact)
    #expect(r[1].key == .status(ownerKey: "a.b", autosaveName: "B") && r[1].confidence == .inferred)
}

@Test func executableNameOwnerKeyFromStore() {
    var p = FixturePrefs(); p.store["status:MBDummy::Dummy-A"] = 783; p.store["status:MBDummy::Dummy-B"] = 813
    let infos: [pid_t: OwnerAppInfo] = [10: OwnerAppInfo(bundleID: "ie.boboco.mbdummy", localizedName: "MBDummy", executableName: "MBDummy",
                                  executablePath: "/x/build/MBDummy.app/Contents/MacOS/MBDummy")]
    let r = resolver(p, infos).resolve(snapshot: snap([
        item(bid: "ie.boboco.mbdummy", name: "MBDummy", id: "Dummy-B", frame: bar(100)),
        item(bid: "ie.boboco.mbdummy", name: "MBDummy", id: "Dummy-A", frame: bar(130)),
    ]))
    #expect(r[0].key.description == "status:MBDummy::Dummy-B" && r[0].confidence == .exact)
    #expect(r[1].key.description == "status:MBDummy::Dummy-A")
}

@Test func bothFloTileKeysPickedByOrderEvidenceTieGoesToRuleOrder() {
    var p = FixturePrefs(); p.store["status:FloTile::Item-0"] = 731; p.store["status:ie.boboco.FloTile::Item-0"] = 157
    let infos: [pid_t: OwnerAppInfo] = [10: OwnerAppInfo(bundleID: "ie.boboco.FloTile", executableName: "FloTile", executablePath: "/Applications/FloTile.app/Contents/MacOS/FloTile")]
    let r = resolver(p, infos).resolve(snapshot: snap([item(bid: "ie.boboco.FloTile", name: "FloTile", frame: bar(100))]))
    #expect(r[0].key.description == "status:ie.boboco.FloTile::Item-0")   // installed -> bundle id first
}

@Test func legacyDefaultsUsedWhenStoreHasNoEntry() {
    var p = FixturePrefs()
    p.legacy["a.b"] = [AutosaveEntry(name: "Item-0", legacyPosition: 42)]
    let r = resolver(p).resolve(snapshot: snap([item(frame: bar(100))]))
    #expect(r[0].key == .status(ownerKey: "a.b", autosaveName: "Item-0"))
    #expect(r[0].confidence == .inferred)
}

@Test func noPreferencesYieldsHeuristicWithDuplicateOrdinals() {
    let items = [
        item(desc: "Same", frame: bar(300)), item(desc: "Same", frame: bar(100)), item(desc: "Other", frame: bar(200)),
    ]
    let r = resolver(FixturePrefs()).resolve(snapshot: snap(items))
    // ordinals count left to right: x=100 -> 0, x=300 -> 1
    #expect(r[1].key == .heuristic(bundleID: "a.b", fingerprint: "Same", ordinal: 0))
    #expect(r[0].key == .heuristic(bundleID: "a.b", fingerprint: "Same", ordinal: 1))
    #expect(r[2].key == .heuristic(bundleID: "a.b", fingerprint: "Other", ordinal: 0))
    #expect(Set(r.map(\.key)).count == 3)
}

@Test func identifierLessTwoItemAppIsDeterministicAcrossScans() {
    // Two items, no identifiers, no preferences: the same keys regardless of discovery order.
    let a = item(title: "64%", frame: bar(100)), b = item(title: "70%", frame: bar(160))
    let r1 = resolver(FixturePrefs()).resolve(snapshot: snap([a, b]))
    let r2 = resolver(FixturePrefs()).resolve(snapshot: snap([b, a]))
    #expect(r1[0].key == r2[1].key && r1[1].key == r2[0].key)
    #expect(r1[0].key != r1[1].key)
    // Live readouts: digits masked so "64%" and "65%" are the same fingerprint.
    let r3 = resolver(FixturePrefs()).resolve(snapshot: snap([item(title: "65%", frame: bar(100))]))
    #expect(r3[0].key == .heuristic(bundleID: "a.b", fingerprint: "##%", ordinal: 0))
}

@Test func twoIdentifierLessItemsWithStoreNamesPairByOrder() {
    var p = FixturePrefs(); p.store["status:a.b::Item-0"] = 400; p.store["status:a.b::Item-1"] = 300
    let r1 = resolver(p).resolve(snapshot: snap([item(frame: bar(100)), item(frame: bar(160))]))
    #expect(r1[0].key.description == "status:a.b::Item-0" && r1[1].key.description == "status:a.b::Item-1")
    #expect(r1.allSatisfy { $0.confidence == .inferred })
}

@Test func agentHostedModules() {
    var p = FixturePrefs(); p.store["module:Clock"] = 0; p.store["module:AudioVideoModule"] = 652
    let items = [
        item(pid: 99, bid: "com.apple.MenuBarAgent", name: "Clock", id: "com.apple.menuextra.clock", desc: "Clock", frame: bar(900), source: .agentHostedOnly),
        item(pid: 99, bid: "com.apple.MenuBarAgent", name: "AV", id: "com.apple.menuextra.audiovideo", frame: bar(800), source: .agentHostedOnly),
        item(pid: 99, bid: "com.apple.MenuBarAgent", name: "X", id: "com.apple.menuextra.unknown", frame: bar(700), source: .agentHostedOnly),
        item(pid: 99, bid: "com.apple.MenuBarAgent", name: "Desc", desc: "Some thing", frame: bar(600), source: .agentHostedOnly),
        item(pid: 99, bid: "com.apple.MenuBarAgent", name: "System item", title: "Apple", frame: bar(500), source: .agentHostedOnly),
        item(pid: 99, bid: "com.apple.MenuBarAgent", name: "System item", id: "_NS:433", title: "File", frame: parked, source: .agentHostedOnly),
    ]
    let r = resolver(p).resolve(snapshot: snap(items))
    #expect(r[0].key == .module(name: "Clock") && r[0].confidence == .inferred)
    #expect(r[1].key == .module(name: "AudioVideoModule") && r[1].confidence == .inferred)
    #expect(r[2].key == .module(name: "com.apple.menuextra.unknown") && r[2].confidence == .heuristic)
    #expect(r[3].key == .module(name: "Some thing") && r[3].confidence == .heuristic)
    #expect(r[4].key == .heuristic(bundleID: "com.apple.MenuBarAgent", fingerprint: "Apple", ordinal: 0))
    // per-launch AppKit menu ids must not become module names
    if case .heuristic = r[5].key {} else { Issue.record("expected heuristic for _NS: id, got \(r[5].key)") }
}

@Test func resolveIsDeterministicAcrossRepeatedCalls() {
    let s = istatSnapshot(identifiers: false)
    let a = resolver(istatPrefs(), istatInfo).resolve(snapshot: s).map(\.key)
    let b = resolver(istatPrefs(), istatInfo).resolve(snapshot: s).map(\.key)
    #expect(a == b)
}

@Test func preferenceReaderMergesStoreAndLegacy() {
    var p = FixturePrefs(); p.store["status:o::A"] = 10
    p.legacy["o"] = [AutosaveEntry(name: "A", legacyPosition: 5, legacyVisible: 1), AutosaveEntry(name: "B", legacyPosition: 7)]
    let e = p.autosaveEntries(ownerKey: "o")
    #expect(e.count == 2)
    #expect(e[0] == AutosaveEntry(name: "A", storeValue: 10, legacyPosition: 5, legacyVisible: 1))
    #expect(e[1] == AutosaveEntry(name: "B", storeValue: nil, legacyPosition: 7, legacyVisible: nil))
}

// MARK: - gdu.28: corroborated keys for identifier-less items

private func ev(_ i: MenuBarItem, _ e: JoinEvidence) -> MenuBarItem { var j = i; j.joinEvidence = e; return j }

/// Owner X has two identical identifier-less items (same description); owner Y has one. All paired by a mutual-exclusive frame.
private func twinFixture(shift: CGFloat = 0, otherFirst: Bool = false, newHandles: Bool = false) -> [MenuBarItem] {
    var x1 = ev(item(pid: 10, bid: "x.app", name: "X", desc: "Twin", frame: bar(300 + shift)), .frameUnique)
    var x2 = ev(item(pid: 10, bid: "x.app", name: "X", desc: "Twin", frame: bar(400 + shift)), .frameUnique)
    let y = ev(item(pid: 20, bid: "y.app", name: "Y", desc: "Twin", frame: bar(350 + shift)), .frameUnique)
    let other1 = item(pid: 30, bid: "z.app", name: "Z", id: "z.id", frame: bar(100 + shift))
    let other2 = item(pid: 31, bid: "w.app", name: "W", id: "w.id", frame: bar(500 + shift))
    if newHandles { x1.ownerPID = 10; x2.ownerPID = 10 }   // a respawn changes AX handles, never owner pids; handles are not in the key
    return otherFirst ? [other2, y, x2, other1, x1] : [other1, x1, y, x2, other2]
}

@Test func corroboratedKeysAreDistinctAndStableAcrossOtherReorderAndRespawn() {
    let r = resolver(FixturePrefs())
    func keys(_ items: [MenuBarItem]) -> [String: String] {
        // label each item by (owner, x order within owner) so results from differently ordered inputs compare
        var out: [String: String] = [:]
        let res = r.resolve(snapshot: snap(items))
        for owner in ["x.app", "y.app"] {
            let mine = zip(items, res).filter { $0.0.ownerBundleID == owner }.sorted { $0.0.frame.minX < $1.0.frame.minX }
            for (n, p) in mine.enumerated() { out["\(owner)#\(n)"] = p.1.key.description; #expect(p.1.confidence == .corroborated) }
        }
        return out
    }
    let base = keys(twinFixture())
    #expect(Set(base.values).count == 3)                                   // distinct, even with identical descriptions
    #expect(base["x.app#0"] == "heuristic:x.app::Twin#0" && base["x.app#1"] == "heuristic:x.app::Twin#1")
    #expect(base["y.app#0"] == "heuristic:y.app::Twin#0")                  // ordinals are per owner
    #expect(keys(twinFixture(otherFirst: true)) == base)                  // other items reordered / snapshot order changed
    #expect(keys(twinFixture(shift: 37)) == base)                         // respawn: new frames shifted by 37 px, new handles
    #expect(keys(twinFixture(shift: 37, newHandles: true)) == base)
    // The key text carries no frame, pid or handle.
    #expect(!base.values.contains { $0.contains("37") || $0.contains("300") })
}

@Test func ownItemMoveDoesNotChangeTheKeyOfASingletonButUncorroboratedStaysHeuristic() {
    let a = ev(item(pid: 10, bid: "x.app", name: "X", desc: "Solo", frame: bar(100)), .description)
    let moved = ev(item(pid: 10, bid: "x.app", name: "X", desc: "Solo", frame: bar(700)), .description)
    let r1 = resolver(FixturePrefs()).resolve(snapshot: snap([a])), r2 = resolver(FixturePrefs()).resolve(snapshot: snap([moved]))
    #expect(r1[0].key == r2[0].key && r1[0].confidence == .corroborated && r1[0].frameTrusted)
    let amb = ev(item(pid: 10, bid: "x.app", name: "X", desc: "Solo", frame: bar(100)), .frameAmbiguous)
    let plain = item(pid: 10, bid: "x.app", name: "X", desc: "Solo", frame: bar(100))
    for i in [amb, plain] {
        let r = resolver(FixturePrefs()).resolve(snapshot: snap([i]))
        #expect(r[0].key == r1[0].key)                      // same key text either way ...
        #expect(r[0].confidence == .heuristic && !r[0].frameTrusted)   // ... but not trusted for frame checks
    }
    // an identifier already makes the frame trustworthy
    #expect(resolver(FixturePrefs()).resolve(snapshot: snap([item(id: "id", frame: bar(100))]))[0].frameTrusted)
}

@Test func corroborationNeverChangesAStoredInferredKeyAndOldKeysStillLoad() throws {
    // gdu.28 keeps the key format, so a layout written before it loads unchanged; an old heuristic key string parses to the
    // same key the resolver now emits as `.corroborated`, and an `.inferred` store key stays `.inferred`.
    let old = "heuristic:x.app::Twin#1"
    #expect(ItemKey(storeKey: old) == .heuristic(bundleID: "x.app", fingerprint: "Twin", ordinal: 1))
    let r = resolver(FixturePrefs()).resolve(snapshot: snap(twinFixture()))
    #expect(r.contains { $0.key.description == old && $0.confidence == .corroborated })
    var p = FixturePrefs(); p.store["status:a.b::Item-0"] = 100
    let single = ev(item(frame: bar(100)), .frameUnique)
    let k = resolver(p).resolve(snapshot: snap([single]))[0]
    #expect(k.key.description == "status:a.b::Item-0" && k.confidence == .inferred && k.frameTrusted)
    // MenuBarItem JSON written before the field existed still decodes (joinEvidence defaults to none)
    let json = try JSONEncoder().encode(item(frame: bar(100)))
    #expect(try JSONDecoder().decode(MenuBarItem.self, from: json).joinEvidence == .none)
    let with = try JSONEncoder().encode(ev(item(frame: bar(100)), .frameUnique))
    #expect(try JSONDecoder().decode(MenuBarItem.self, from: with).joinEvidence == .frameUnique)
}

// gdu.28 corrective: which corroboration lets a heuristic-keyed identifier-less item support a verified move.
@Test func verifiedMoveNeedsNonFrameCorroborationForIdentifierLessHeuristicItems() {
    func run(_ e: JoinEvidence, _ c: KeyConfidence) -> Bool {
        let a = ResolvedItem(item: ev(item(pid: 1, bid: "a.app", name: "A", desc: "A", frame: bar(100)), e),
                             key: .heuristic(bundleID: "a.app", fingerprint: "A", ordinal: 0), confidence: c)
        let b = ResolvedItem(item: item(pid: 2, bid: "b.app", name: "B", id: "b.id", frame: bar(200)),
                             key: .status(ownerKey: "b.app", autosaveName: "b.id"), confidence: .exact)
        return ActuationVerifier.moveVerdict(subject: a.key, relation: .before(b.key), resolved: [a, b]).ok
    }
    #expect(run(.description, .corroborated))     // unique-description join: can support a verified move
    #expect(!run(.frameUnique, .corroborated))    // frame-only corroboration: still cannot
    #expect(!run(.none, .heuristic))              // no evidence: cannot
    #expect(!run(.frameAmbiguous, .heuristic))
}
