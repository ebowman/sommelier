import CoreGraphics
import Foundation
import Testing
import DecisionCore
@testable import SommelierCore

// sommelier-ejb.13: the HEAVY property test of ReadAdapter, in its own test target so that `make test` runs it in a separate `swift test` invocation,
// never concurrently with the timing-sensitive engine tests (it takes about 1 s of CPU). Plain `swift test` runs both targets, one after the other.

// MARK: property tests: the A7 / A6 obligations over random observations built through the real Reconciler path

private struct LCG {
    var s: UInt64
    mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    mutating func chance(_ pct: Int) -> Bool { below(100) < pct }
}

private extension Array {
    func shuffled(using g: inout LCG) -> [Element] {
        var a = self
        if a.count > 1 { for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, g.below(i + 1)) } }
        return a
    }
}

private enum AppState: CaseIterable {
    case normal, notRunning, emptyRead, omitOne, failedRead, cached, agentHosted, twoKeys, quitBetween
    /// renames across key schemes: the record holds the item under one scheme, the read shows it under another (the app is read fine)
    case renameModuleToHeuristic, renameHeuristicToModule, helperOwned, agentHeuristic
}

/// One scan of a random world, built through the real Reconciler path. The world has apps in every failure mode the scanner can have, each with record
/// keys whose items are TRULY on the bar or not; `truth` is what the adapter must never lose.
private struct World {
    var items: [ResolvedItem] = []
    var record: [ItemKey] = []
    var trueOnBar: Set<ItemKey> = []
    var surfacedAs: [ItemKey: [ItemKey]] = [:]
    var running: [UnreadOwner] = []
    var unreadOwners: [UnreadOwner] = []
    var cachedOwners: [UnreadOwner] = []
    var info: [ItemKey: ItemInfo] = [:]
    var states: [AppState] = []
    var nilCCParked = 0   // really-on-bar items the scan shows parked with a NIL Control Center flag
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

private func makeWorld(_ rng: inout LCG, fast: Bool, calm: Bool, clean: Bool = false, renameOne: Bool = false) -> World {   // calm: no hosted-only keys anywhere, so no world-wide doubt masks a per-owner rule
    var w = World()
    var x: CGFloat = 100
    func owner(_ n: Int, bundle: String?, keys: [String]) -> UnreadOwner { UnreadOwner(pid: pid_t(100 + n), bundleID: bundle, name: "Display \(n)", ownerKeys: keys) }
    func note(_ r: ResolvedItem) { w.info[r.key] = ItemInfo(key: r.key, title: "", axDescription: "", ownerPID: r.item.ownerPID, ownerBundleID: r.item.ownerBundleID, ownerName: r.item.ownerName, width: 24, isOnBar: r.item.isOnMenuBar) }
    func add(_ r: ResolvedItem, for rec: ItemKey) { w.items.append(r); note(r); w.surfacedAs[rec, default: []].append(r.key) }
    let agent = menuBarAgentBundleID
    let renamed = rng.below(10)
    for n in 0..<11 {
        let isIStat = n == 10
        var st = AppState.allCases[rng.below(AppState.allCases.count)]
        if clean { st = [.normal, .normal, .normal, .notRunning, .normal, .normal][rng.below(6)]; if renameOne && n == renamed { st = [AppState.renameModuleToHeuristic, .renameHeuristicToModule, .helperOwned, .agentHeuristic][rng.below(4)] } }
        else if calm { st = [.normal, .normal, .normal, .notRunning, .failedRead, .emptyRead, .quitBetween][rng.below(7)] }
        if isIStat { st = rng.chance(60) ? .normal : .failedRead }
        if fast { switch st { case .normal, .emptyRead, .omitOne, .twoKeys: st = rng.chance(70) ? .cached : .failedRead; default: break } }
        w.states.append(st)
        let bundle = isIStat ? "com.bjango.istatmenus.status" : "app.\(n)"
        // apps outside installed locations key their items by the EXECUTABLE name, which is neither the bundle id nor the display name (OwnerKeyRule)
        let exeKeyed = !isIStat && (st == .helperOwned ? rng.chance(85) : rng.chance(30))
        let me = owner(n, bundle: bundle, keys: exeKeyed ? ["exe-\(n)", bundle] : [bundle])
        // the app's record keys (a status key, or a heuristic key as the reviewer's reproduction has)
        var recKeys: [ItemKey] = (0..<(1 + rng.below(2))).map { j in
            isIStat ? istatKey : (rng.chance(30) ? .heuristic(bundleID: exeKeyed ? "exe-\(n)" : bundle, fingerprint: "f\(j)", ordinal: 0) : .status(ownerKey: exeKeyed ? "exe-\(n)" : bundle, autosaveName: "a\(j)"))
        }
        if st == .renameModuleToHeuristic { recKeys = recKeys.indices.map { .module(name: "alias-\(n)-\($0)") } }
        if st == .renameHeuristicToModule { recKeys = recKeys.indices.map { .heuristic(bundleID: bundle, fingerprint: "r\($0)", ordinal: 0) } }
        let appQuit = st == .helperOwned && !exeKeyed && rng.chance(50)   // only the HELPER is running; its bundle id relates to the app's (`app.n` / `app.n.helper`)
        let isRunning = st != .notRunning && !appQuit   // a launch during the scan is in the FRESH running list (re-read after the hosted tree) but was never queried
        let helperBundle = "app.\(n).helper"
        if isRunning { w.running.append(me) }
        var presented = 0
        var helperPresented = 0
        for (j, rk) in recKeys.enumerated() {
            if w.record.contains(rk) { continue }
            w.record.append(rk)
            let truly = (st == .notRunning || st == .quitBetween) ? false : rng.chance(70)
            if truly { w.trueOnBar.insert(rk) }
            x += 30
            func status(onBar: Bool, stale: Bool = false, nilCC: Bool = false) -> ResolvedItem {
                scannerItem(rk, pid: pid_t(100 + n), bundle: bundle, name: "Display \(n)", x: x, onBar: onBar, stale: stale, recent: stale && rng.chance(40),
                            overflow: rng.chance(35), corroborated: rng.chance(85), allowed: nilCC ? nil : [true, true, nil, false][rng.below(4)], hidden: rng.chance(10),
                            unknown: !onBar && rng.chance(15), width: (clean ? rng.below(1000) < 5 : rng.chance(calm ? 15 : 8)) ? 1 : 24)   // width 1: presented by the app, dropped by the Reconciler
            }
            func module() -> ResolvedItem { scannerItem(.module(name: "New thing \(n) \(j)"), pid: 99, bundle: agent, name: "System item", x: x, onBar: true, overflow: rng.chance(35), hostedOnly: true) }
            func parkedMaybe() { if rng.chance(40) { add(status(onBar: false, stale: rng.chance(20)), for: rk) } }
            switch st {
            case .normal, .cached:
                if truly && rng.chance(10) { add(status(onBar: false, nilCC: true), for: rk); presented += 1; w.nilCCParked += 1 }   // Control Center says nothing: parked, but the item is really on the bar
                else if truly { add(status(onBar: true, stale: rng.chance(isIStat ? 50 : 12)), for: rk); presented += 1 } else { parkedMaybe(); if !w.surfacedAs[rk, default: []].isEmpty { presented += 1 } }
            case .omitOne:
                if truly && j == 0 { add(module(), for: rk) }
                else if truly { add(status(onBar: true), for: rk); presented += 1 } else { parkedMaybe(); if !w.surfacedAs[rk, default: []].isEmpty { presented += 1 } }
            case .agentHosted:
                if truly { add(module(), for: rk) }
            case .emptyRead:
                if truly { add(module(), for: rk) }   // (an empty read with NO sign at all is the residual assumption of A6, not generated)
            case .twoKeys:
                if truly { add(status(onBar: true), for: rk); add(module(), for: rk); presented += 1 }
            case .failedRead:
                if truly { if calm || rng.chance(50) { add(status(onBar: true, stale: true), for: rk) } else if rng.chance(50) { add(module(), for: rk) } }
            case .renameModuleToHeuristic:
                if truly { add(scannerItem(.heuristic(bundleID: bundle, fingerprint: "f\(j)", ordinal: 0), pid: pid_t(100 + n), bundle: bundle, name: "Display \(n)", x: x, onBar: true, overflow: rng.chance(35)), for: rk); presented += 1 }
            case .renameHeuristicToModule:
                if truly { add(module(), for: rk) }
            case .helperOwned:
                if truly {
                    add(scannerItem(.status(ownerKey: helperBundle, autosaveName: "h\(j)"), pid: pid_t(600 + n), bundle: helperBundle, name: "Helper \(n)", x: x, onBar: true, overflow: rng.chance(35)), for: rk)
                    helperPresented += 1
                }
            case .agentHeuristic:
                if truly { add(scannerItem(.heuristic(bundleID: agent, fingerprint: "x\(j)", ordinal: 0), pid: 99, bundle: agent, name: "System item", x: x, onBar: true, hostedOnly: true), for: rk) }
            case .notRunning, .quitBetween: break
            }
        }
        switch st {
        case .helperOwned:
            let h = UnreadOwner(pid: pid_t(600 + n), bundleID: helperBundle, name: "Helper \(n)", ownerKeys: [helperBundle])
            w.running.append(h)
        case .cached: w.cachedOwners.append(me)
        case .failedRead, .quitBetween: w.unreadOwners.append(me)
        default: break
        }
    }
    // Control Center's own module in the record (no app owner): on the bar or not
    let clock = ItemKey.module(name: "Clock")
    w.record.append(clock)
    if rng.chance(70) { w.trueOnBar.insert(clock); add(scannerItem(clock, pid: 99, bundle: agent, name: "System item", x: 1500, onBar: true, hostedOnly: true), for: clock) }
    // a MenuBarAgent-hosted item the record holds under a heuristic key (no ItemInfo unless it is shown)
    let hosted = ItemKey.heuristic(bundleID: agent, fingerprint: "wifi", ordinal: 0)
    w.record.append(hosted)
    if rng.chance(60) { w.trueOnBar.insert(hosted); add(scannerItem(hosted, pid: 99, bundle: agent, name: "System item", x: 1600, onBar: true, hostedOnly: true), for: hosted) }
    return w
}

@Test func theA7AndA6ObligationsHoldOverRandomScansThroughTheReconciler() throws {
    var rng = LCG(s: 20261110)
    var keys = CoreKeys()
    var stats: [String: Int] = [:]
    var violations: [(case: Int, what: String)] = []
    let chevItem = ItemKey.status(ownerKey: "com.apple.menuextra.chevron", autosaveName: "chevron")
    let cases = 700
    for iter in 0..<cases {
        func viol(_ ok: Bool, _ what: @autoclosure () -> String) { if !ok { violations.append((iter, what())) } }
        let fast = rng.chance(25)
        let calm = rng.chance(20)
        let clean = !calm && rng.chance(45)                 // a world where the whole-read rule can hold: every app read fine, nothing unknown ...
        let renameOne = clean && rng.chance(50)             // ... or exactly one app's item shown under another key scheme
        var w = makeWorld(&rng, fast: fast && !calm && !clean, calm: calm, clean: clean, renameOne: renameOne)
        for s in w.states { stats["state.\(s)", default: 0] += 1 }
        stats["nilCCParkedOnBar", default: 0] += w.nilCCParked
        let level = clean ? (rng.chance(12) ? ReadCompleteness.incomplete : .complete) : [ReadCompleteness.complete, .complete, .completeExceptSelfPositioning, .incomplete][rng.below(4)]
        var items = w.items
        // An incomplete hosted read may OMIT on-bar items with no other sign (the read is then not usable: A6 holds only for usable reads, so the
        // adapter must not call their keys "not on the bar").
        if level != .complete { items = items.filter { !$0.item.isOnMenuBar || (clean && !($0.item.source == .agentHostedOnly)) || rng.chance(clean ? 40 : 70) } }   // a clean world loses only hosted-only items: the app counts still match
        if rng.chance(70) { let shown = Set(items.map(\.key)); w.info = w.info.filter { shown.contains($0.key) } }   // the engine's memory of a key may be absent
        switch rng.below(6) {
        case 0: items.append(scannerItem(chevItem, pid: 99, bundle: "agent", name: "agent", x: 50 + CGFloat(rng.below(300)), onBar: true, chevron: true, expanded: rng.chance(30))); stats["fresh", default: 0] += 1
        case 1: items.append(scannerItem(chevItem, pid: 99, bundle: "agent", name: "agent", x: 50 + CGFloat(rng.below(300)), onBar: true, stale: true, recent: rng.chance(50), chevron: true)); stats["stale", default: 0] += 1
        case 2: items.append(scannerItem(chevItem, pid: 99, bundle: "agent", name: "agent", x: 0, onBar: false, stale: true, chevron: true)); stats["staleOff", default: 0] += 1
        case 3: items.append(scannerItem(chevItem, pid: 99, bundle: "agent", name: "agent", x: 0, onBar: false, chevron: true))
        default: break
        }
        if rng.chance(25), let d = items.first { var dup = d; dup.item.frame.origin.x += 3; items.append(dup) }          // a duplicate scan row
        let order = ObservedOrder(resolved: items.shuffled(using: &rng))
        let pool = Array(Set(w.record))
        let record = (w.record + (items.contains { $0.key == chevItem } && rng.chance(60) ? [chevItem] : []) + (rng.chance(20) ? [w.record[rng.below(w.record.count)]] : [])).shuffled(using: &rng)
        let hand = Set(pool.filter { _ in rng.chance(12) })
        // PRODUCTION immovability: every key failing CapabilityRules.canMove (every module: key), over the keys of the world and of the record
        let caps = CapabilityRules(hasTrackedEntry: { _ in true })
        let immovable = Set((pool + items.map(\.key) + w.record).filter { !caps.capability(for: $0).canMove })
        let ctx = ReadContext(kind: fast ? .poll : .pass, settled: rng.chance(70), level: level, observed: rng.chance(95),
                              previousCompletePile: rng.chance(50) ? Set(pool.filter { _ in rng.chance(30) }) : nil, unreadOwners: w.unreadOwners,
                              handDragUnverified: hand, immovable: immovable, churnZone: Set(pool.filter { _ in rng.chance(20) }),
                              cachedOwners: w.cachedOwners, ownerEvidence: (clean && rng.chance(5)) ? nil : OwnerEvidence(running: w.running), itemInfo: w.info)
        let a = try ReadAdapter.adapt(order, context: ctx, record: record, keys: &keys)
        let r = a.read
        func nodup(_ l: [Key]) -> Bool { Set(l).count == l.count }
        viol(nodup(a.record), "record Nodup")
        viol(nodup(r.drawn) && nodup(r.pile) && nodup(r.unread) && nodup(r.trusted) && nodup(r.nearFold), "lists Nodup")
        viol(Set(r.drawn).isDisjoint(with: r.pile), "drawn ∩ pile = ∅")
        viol(Set(r.pile).isDisjoint(with: r.unread) && Set(r.drawn).isDisjoint(with: r.unread), "pile and drawn are disjoint from unread")
        viol(Set(r.unread).isDisjoint(with: r.trusted), "unread ∩ trusted = ∅")
        viol(Set(r.trusted).isSubset(of: Set(r.drawn)), "trusted ⊆ drawn")
        let all = a.record + r.drawn + r.pile + r.folded + r.trusted + r.nearFold + r.unread
        viol(all.allSatisfy { keys.key(for: $0) != nil && keys.key(for: $0) != chevItem } && keys.id(for: chevItem) == nil, "the chevron is never a key")
        func id(_ k: ItemKey) -> Key? { keys.id(for: k) }
        func inList(_ l: [Key], _ k: ItemKey) -> Bool { id(k).map(l.contains) ?? false }
        // blocker 1: a pile key was read fresh and corroborated, against a fresh chevron; a suspect is neither drawn nor pile but unread
        let suspects = order.staleOnBar.union(order.uncorroborated)
        if order.overflowChevron == nil { viol(r.pile.isEmpty, "no pile without a fresh chevron"); stats["noFreshChevron", default: 0] += 1 }
        for key in order.onBar where !order.chevronKeys.contains(key) {
            if suspects.contains(key) { viol(!inList(r.drawn, key) && !inList(r.pile, key) && inList(r.unread, key), "a stale/uncorroborated item is unread, not drawn or pile"); stats["suspect", default: 0] += 1 }
            if order.overflowChevron == nil, order.systemOverflow.contains(key) { viol(inList(r.unread, key) && !inList(r.drawn, key), "a stale pile only appears in unread"); stats["stalePile", default: 0] += 1 }
        }
        // A6, stated over the RECORD and the TRUE items, not over the keys present in the ObservedOrder: a record key of an item that is really on
        // the bar is in exactly one of drawn, pile or unread -- whatever key (or none) the scanner surfaced it under.
        for rk in record where w.trueOnBar.contains(rk) && !ctx.immovable.contains(rk) {
            guard let rid = id(rk) else { viol(false, "A6: a true on-bar record key is in exactly one of drawn, pile, unread (it is in none): \(rk) level \(level) rule \(a.absenceRules[rk] ?? "-") states \(w.states.map { "\($0)" }) surfaced \(w.surfacedAs[rk] ?? [])"); continue }
            viol([r.drawn.contains(rid), r.pile.contains(rid), r.unread.contains(rid)].filter { $0 }.count == 1, "A6: a true on-bar record key is in exactly one of drawn, pile, unread: \(rk) drawn=\(r.drawn.contains(rid)) pile=\(r.pile.contains(rid)) unread=\(r.unread.contains(rid)) level \(level) rule \(a.absenceRules[rk] ?? "-") states \(w.states.map { "\($0)" }) surfaced \(w.surfacedAs[rk] ?? [])")
            stats["trueOnBarChecked", default: 0] += 1
        }
        // A4: an item surfaced under a key the record does not hold (module:) is never trusted; trusted excludes every untrusted class
        let recordSet = Set(record)
        for key in order.onBar where !recordSet.contains(key) && ReadAdapter.isHostedOnly(key, w.info[key]) {
            viol(!inList(r.trusted, key), "A4: an unknown hosted-only key is untrusted"); stats["unknownHosted", default: 0] += 1
        }
        for key in hand { viol(!inList(r.trusted, key), "a hand-drag-unverified key is untrusted"); if order.onBar.contains(key) { stats["handDragOnBar", default: 0] += 1 } }
        for key in ctx.immovable { viol(!inList(r.trusted, key), "an immovable key is untrusted") }
        for key in suspects { viol(!inList(r.trusted, key), "a stale/uncorroborated key is untrusted") }
        for o in w.cachedOwners { for key in order.onBar where w.info[key]?.ownerPID == o.pid { viol(!inList(r.trusted, key), "a cached owner's key is untrusted") } }
        for o in w.unreadOwners { for key in order.onBar where w.info[key]?.ownerPID == o.pid { viol(inList(r.unread, key), "an unread owner's key is unread"); stats["unreadOwnerHit", default: 0] += 1 } }
        if level != .complete { viol(!r.trusted.contains { SelfPositioning.isSelfPositioning(keys.key(for: $0)!) }, "self-positioning keys untrusted off a complete read") }
        viol(r.folded.isEmpty && !r.notFullProven, "folded [] and notFullProven false")
        let recordNow = Set(record).subtracting(ctx.immovable)
        viol(r.trusted.allSatisfy { recordNow.contains(keys.key(for: $0)!) }, "identity: every trusted key is a record key")
        viol(r.pile.allSatisfy { recordNow.contains(keys.key(for: $0)!) }, "identity: every pile key is a record key")
        for rule in a.absenceRules.values { stats["rule " + rule.prefix(while: { $0 != ")" }) + ")", default: 0] += 1 }
        if clean { stats["cleanWorlds", default: 0] += 1 }
        if clean && renameOne { stats["renameWorlds", default: 0] += 1 }
        if calm { stats["calmWorlds", default: 0] += 1 }
        if a.absenceRules.values.contains(where: { $0.hasPrefix("absent: (i)") }) { stats["worldsWithIAbsent", default: 0] += 1 }
    }
    for (name, floor) in [("fresh", 60), ("stale", 60), ("staleOff", 60), ("suspect", 300), ("stalePile", 50), ("noFreshChevron", 400), ("trueOnBarChecked", 2000),
                          ("unknownHosted", 300), ("handDragOnBar", 100), ("unreadOwnerHit", 100), ("renameWorlds", 30), ("worldsWithIAbsent", 200), ("nilCCParkedOnBar", 40)] + AppState.allCases.map({ ("state.\($0)", 60) }) {
        #expect(stats[name, default: 0] > floor, "generator coverage \(name): \(stats[name, default: 0])")
    }
    print("PROPERTY absence decisions over \(cases) worlds: \(stats.filter { $0.key.hasPrefix("rule ") }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")); worlds where (i) decided an absence: \(stats["worldsWithIAbsent", default: 0]); clean worlds \(stats["cleanWorlds", default: 0]), renamed \(stats["renameWorlds", default: 0]), calm \(stats["calmWorlds", default: 0])")
    if let first = violations.first { print("PROPERTY first violation at case \(first.case) of \(cases): \(first.what); \(violations.count) in total") }
    #expect(violations.isEmpty, "first violation at case \(violations.first?.case ?? -1): \(violations.first?.what ?? "")")
}

