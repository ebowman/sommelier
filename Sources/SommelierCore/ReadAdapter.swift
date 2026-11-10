import CoreGraphics
import Foundation
import DecisionCore

/// Everything the adapter needs besides the `ObservedOrder` itself (wiring plan section 1). Plain data, so the adapter stays a pure function.
public struct ReadContext: Sendable {
    /// A pass read comes from `observeOnce`; a poll from `notePollScan`. (The actuator's post-move snapshot is a pass read with `settled: false`.)
    public var kind: ReadKind
    /// `BarObservation.settled`: two consecutive full scans agreed.
    public var settled: Bool
    /// `BarObservation.completeness` / `MenuBarSnapshot.completeness`.
    public var level: ReadCompleteness
    /// False when the observation failed (the caller has no usable bar). An empty bar also counts as not observed, whatever is passed here.
    public var observed: Bool
    /// The raw pile (`systemOverflow` of the bar) of the previous COMPLETE read, nil if there is none. Replaces the veto in `fullBarOrderGate`.
    public var previousCompletePile: Set<ItemKey>?
    /// `BarObservation.unreadOwners` (A6).
    public var unreadOwners: [UnreadOwner]
    /// Keys a hand drag left unverified (`LayoutEngine.handDragUnverified`).
    public var handDragUnverified: Set<ItemKey>
    /// Keys that fail `Capability.canMove` (system modules, anchors).
    public var immovable: Set<ItemKey>
    /// `SystemOverflowRule.churnZone(recentReads)`.
    public var churnZone: Set<ItemKey>
    public var selfPositioningOwners: Set<String>
    /// `BarObservation.cachedOwners` (fast path): apps whose items are attributed from the cache. Listed (drawn) but untrusted.
    public var cachedOwners: [UnreadOwner]
    /// Who is running, from a `runningApps()` snapshot taken after the scan's last AX read (`BarObservation.ownerEvidence`). nil = unknown: no key may be
    /// concluded absent on the strength of its owner (see `ReadAdapter.decideAbsence`, rule (i)).
    public var ownerEvidence: OwnerEvidence?
    /// Control Center entries that belong together (an app and its helpers, e.g. `["com.houdah.HoudahSpot4", "com.houdah.HoudahSpot4.HoudahSpotHelper"]`): an app of a
    /// family could own any key of the family.
    public var ownerFamilies: [[String]]
    /// Called once per unmatched unread owner (per `CoreKeys`).
    public var log: (@Sendable (String) -> Void)?
    /// What is known about each key's owner (for the owner-to-key mapping of `unreadOwners`).
    public var itemInfo: [ItemKey: ItemInfo]
    /// Frames of the keys on this read (for the alias warning only).
    public var frames: [ItemKey: CGRect]

    public init(kind: ReadKind, settled: Bool = true, level: ReadCompleteness = .complete, observed: Bool = true,
                previousCompletePile: Set<ItemKey>? = nil, unreadOwners: [UnreadOwner] = [], handDragUnverified: Set<ItemKey> = [],
                immovable: Set<ItemKey> = [], churnZone: Set<ItemKey> = [], selfPositioningOwners: Set<String> = SelfPositioning.defaultOwners,
                cachedOwners: [UnreadOwner] = [], ownerEvidence: OwnerEvidence? = nil, log: (@Sendable (String) -> Void)? = nil,
                itemInfo: [ItemKey: ItemInfo] = [:], frames: [ItemKey: CGRect] = [:], ownerFamilies: [[String]] = []) {
        self.frames = frames; self.ownerFamilies = ownerFamilies
        self.cachedOwners = cachedOwners; self.log = log; self.ownerEvidence = ownerEvidence
        self.kind = kind; self.settled = settled; self.level = level; self.observed = observed
        self.previousCompletePile = previousCompletePile; self.unreadOwners = unreadOwners; self.handDragUnverified = handDragUnverified
        self.immovable = immovable; self.churnZone = churnZone; self.selfPositioningOwners = selfPositioningOwners; self.itemInfo = itemInfo
    }

    /// The context of a `BarObservation`: its `settled`, `completeness` and `unreadOwners`.
    public init(observation o: BarObservation, kind: ReadKind, previousCompletePile: Set<ItemKey>? = nil, handDragUnverified: Set<ItemKey> = [],
                immovable: Set<ItemKey> = [], churnZone: Set<ItemKey> = [], selfPositioningOwners: Set<String> = SelfPositioning.defaultOwners,
                log: (@Sendable (String) -> Void)? = nil, itemInfo: [ItemKey: ItemInfo] = [:], ownerFamilies: [[String]] = []) {
        self.init(kind: kind, settled: o.settled, level: o.completeness, observed: !o.items.isEmpty, previousCompletePile: previousCompletePile,
                  unreadOwners: o.unreadOwners, handDragUnverified: handDragUnverified, immovable: immovable, churnZone: churnZone,
                  selfPositioningOwners: selfPositioningOwners, cachedOwners: o.cachedOwners, ownerEvidence: o.ownerEvidence, log: log, itemInfo: itemInfo, ownerFamilies: ownerFamilies)
    }
}

/// The adapter's product: the core's `Read` and the record (the order the user wants) as core keys.
public struct AdaptedRead: Equatable, Sendable {
    public var read: Read
    public var record: [Key]
    /// Unread or cached owners that matched no known key. Informational: it does not block rule (i) of `decideAbsence` (an app's item exists only while
    /// the app or a helper runs; a name that relates to no running app is a documented residual assumption, docs/verified-core.md A6).
    public var unmatchedOwners: [UnreadOwner] = []
    /// For every record key that was in none of drawn, pile, unread before the absence decision: the rule that decided it ("absent: ..." or "unread: ...").
    public var absenceRules: [ItemKey: String] = [:]
}

/// Wiring plan section 1: `ObservedOrder` + context -> `Read`. A PURE function of its inputs (the only state is the key interner, passed
/// `inout`). It never plans and never moves anything. Where today's information is ambiguous it chooses the conservative mapping: less
/// trusted, more `unread`, chevron `stale` rather than `fresh`.
///
/// Obligations it must meet (docs/verified-core.md, A7; checked by property tests):
/// record has no duplicates; `drawn` has no duplicates; `drawn` and `pile` are disjoint; `unread` and `trusted` are disjoint; the chevron is
/// never a key of any list; a stale pile appears only in `unread`; `trusted` is a subset of `drawn`.
public enum ReadAdapter {
    public static func adapt(_ order: ObservedOrder, context c: ReadContext, record: [ItemKey],
                             keys: inout CoreKeys) throws(CoreKeysError) -> AdaptedRead {
        // The chevron, by key AND by role (`ObservedOrder.chevronKeys`: every item whose role is the overflow chevron, on the bar or not, fresh or
        // stale): never interned, never in a list (A7).
        let chevronKeys = Set([order.overflowChevron, order.chevronAnyKey].compactMap { $0 }).union(order.chevronKeys)
        for k in chevronKeys { keys.rejectChevron(k) }
        func dedupe(_ l: [ItemKey]) -> [ItemKey] { var seen = Set<ItemKey>(); return l.filter { !chevronKeys.contains($0) && !keys.isChevron($0) && seen.insert($0).inserted } }

        let onBar = dedupe(order.onBar)
        let freshChevron = order.overflowChevron != nil
        // ---- chevron (A2, A3). Fresh only when this scan read the chevron itself. A carried chevron (`chevronRecent`, even one verified
        // recently) and a stale one (`chevronPresent`) are `.stale`: the conservative choice (a stale chevron licenses no pile, no fold).
        let chevron: ChevronRead = freshChevron ? .fresh : (order.chevronRecent || order.chevronPresent ? .stale : .absent)

        // ---- suspects (A1, A2, A6): on-bar items whose frame is NOT a fresh, corroborated one on this read: carried (stale) frames, frames resting
        // on no hosted element, items Control Center lists hidden or not allowed (`uncorroborated` holds all of these). Such an item keeps a
        // carried overflow flag from an earlier read, so it may be open although the flag says "behind the chevron" (iStat, carried at
        // exceptSelfPositioning). It is neither pile nor drawn: it is unread.
        let suspects = Set(order.staleOnBar).union(order.uncorroborated)
        let clean = onBar.filter { !suspects.contains($0) }

        // ---- pile (A2, A7). `rawPile` = clean ∩ systemOverflow. Only a FRESH chevron makes it the pile; otherwise it is a stale/inferred pile
        // (ObservedOrder infers it from a stale chevron's last frame) and goes to `unread` (A7: a stale pile goes to unread).
        let rawPile = clean.filter { order.systemOverflow.contains($0) }
        let rawPileSet = Set(rawPile)

        let recordKeys = dedupe(record).filter { !c.immovable.contains($0) }
        let recordSet = Set(recordKeys)
        let candidates = dedupe(onBar + order.parked + recordKeys + order.staleOff.sorted { $0.description < $1.description })

        // ---- unread (A6): keys that may be anywhere. Everything the read cannot vouch for.
        var unread = Set<ItemKey>(onBar.filter { suspects.contains($0) })    // suspects (above)
        if !freshChevron { unread.formUnion(rawPile) }                       // stale pile (A7)
        unread.formUnion(order.foldedParked)                                  // inferred folded-parked: `folded` is [], so these are unread (A2)
        unread.formUnion(order.parkedUnreadable)                              // placementUnknown, nil/allowed Control Center flag (A6)
        unread.formUnion(order.placementUnknown)                              // (A6; also inside parkedUnreadable when built from a scan)
        unread.formUnion(order.staleOff)                                      // stale off-bar items dropped by the Reconciler filter (A6)
        unread.subtract(chevronKeys)
        // Owners whose items this read did not read (failed, missed the budget, skipped; A6): every key they may own is unread (over-approximating).
        var ghosts: [UnreadOwner] = []
        for o in c.unreadOwners {
            let hits = candidates.filter { Self.owns(o, $0, info: c.itemInfo[$0]) }
            if hits.isEmpty { ghosts.append(o) }
            unread.formUnion(hits)
        }
        // Fast-path owners attributed from the cache: their keys stay listed but untrusted (positions not corroborated by a read of the app).
        var cachedKeys = Set<ItemKey>()
        for o in c.cachedOwners {
            let hits = candidates.filter { Self.owns(o, $0, info: c.itemInfo[$0]) }
            if hits.isEmpty { ghosts.append(o) }
            cachedKeys.formUnion(hits)
        }

        // ---- drawn (A1, A7) and pile before the absence decision: clean minus the raw pile minus unread, left to right.
        var drawn = clean.filter { !rawPileSet.contains($0) && !unread.contains($0) }
        var pile = freshChevron ? rawPile.filter { !unread.contains($0) } : []

        // ---- identity (A2, A4): only a RECORD key's identity is established. A pile key that is not a record key, or is hosted-only and not a record key,
        // is unread, not pile: A2 needs the identity right.
        let doubtfulPile = Set(pile.filter { !recordSet.contains($0) })
        unread.formUnion(doubtfulPile)
        pile = pile.filter { !doubtfulPile.contains($0) }

        // ---- "not on the bar" (A6): a record key that is neither drawn, pile nor unread is left out of every list ONLY if `decideAbsence` says so
        // (the three scoped rules documented there). Every other such record key is unread, with the reason recorded.
        let facts = AbsenceFacts(context: c)
        var forced = Set<ItemKey>()
        var rules: [ItemKey: String] = [:]
        for k in recordKeys where !drawn.contains(k) && !pile.contains(k) && !unread.contains(k) {
            let d = Self.decideAbsence(k, order: order, facts: facts, context: c)
            rules[k] = d.rule
            if !d.absent { forced.insert(k) }
        }
        unread.formUnion(forced)
        drawn = drawn.filter { !unread.contains($0) }
        pile = pile.filter { !unread.contains($0) }
        let unreadList = dedupe(candidates + unread.sorted { $0.description < $1.description }).filter { unread.contains($0) }
        if let log = c.log {
            // once per read, not per key: which conditions cost record keys their "absent"
            if !forced.isEmpty {
                var byReason: [String: Int] = [:]
                for k in forced { byReason[rules[k] ?? "?", default: 0] += 1 }
                log("read adapter: \(forced.count) record key(s) not shown are unread: " + byReason.sorted { $0.key < $1.key }.map { "\($0.value) x \($0.key)" }.joined(separator: "; "))
            }
            for pair in Self.aliasPairs(recordKeys, c).prefix(3) { log("read adapter: WARNING record keys \(pair.0) and \(pair.1) look like ONE item (same owner and title, or the same frame): aliases are not detected as such (A4)") }
        }

        // ---- trusted (A1): drawn RECORD keys whose position the read vouches for. A key that is not a record key has no established identity: untrusted.
        // Identity doubt is scoped: the drawn keys of an owner that has a record key forced unread are untrusted too (that key may be one of the
        // drawn ones under another name).
        var doubtOwners: [UnreadOwner] = []
        if let ev = c.ownerEvidence { doubtOwners = ev.running.filter { o in forced.contains { Self.owns(o, $0, info: c.itemInfo[$0]) } } }
        let doubtKeys = Set(drawn.filter { k in doubtOwners.contains { Self.owns($0, k, info: c.itemInfo[k]) } })
        let untrusted = Set(c.handDragUnverified).union(c.immovable).union(cachedKeys).union(doubtKeys)
        let trusted = drawn.filter { k in
            recordSet.contains(k) && !untrusted.contains(k) && (c.level == .complete || !SelfPositioning.isSelfPositioning(k, owners: c.selfPositioningOwners))
        }

        // ---- nearFold (A2): the churn zone minus the pile, in drawn order first.
        let zone = c.churnZone.subtracting(rawPileSet)
        let nearFold = dedupe(drawn.filter { zone.contains($0) } + zone.sorted { $0.description < $1.description })

        // ---- settled (A5): the scanner's settled flag (two consecutive full scans agreed on the items; a seeded scan needs one), and also false
        // when the last two complete reads disagree on the pile, or (ejb.19) a COMPLETE read WITH a chevron has no earlier complete pile to agree with
        // (the first one after launch or wake; gdu.80 waited for two agreeing reads on a full bar). A chevronless read has no pile to disagree on, and
        // the core moves nothing on one before its own proof that the bar is not full, so it stays as the scanner says.
        var settled = c.settled
        if c.level == .complete {
            if let prev = c.previousCompletePile { if prev != rawPileSet { settled = false } }
            else if chevron != .absent { settled = false }
        }

        // Intern last: all lists are final, so a thrown error leaves no half-built Read.
        func ids(_ l: [ItemKey]) throws(CoreKeysError) -> [Key] { var o: [Key] = []; o.reserveCapacity(l.count); for k in l { o.append(try keys.intern(k)) }; return o }
        let read = Read(kind: c.kind, chevron: chevron, level: Self.level(c.level), settled: settled, stripOpen: order.stripExpanded,
                        drawn: try ids(drawn), pile: try ids(pile), folded: [],                      // folded: [] (A2: only a fresh chevron's own folded list may be sent, and Swift has none)
                        trusted: try ids(trusted), nearFold: try ids(nearFold),
                        observed: c.observed && !order.onBar.isEmpty,                                // a failed observation or an empty bar is not a reading
                        unread: try ids(unreadList),
                        notFullProven: false)                                                        // IGNORED by every export (Truth.lean:2354 judges `s.view r`); always false
        let rec = try ids(recordKeys)
        assert(Set(rec).count == rec.count && Set(read.drawn).count == read.drawn.count && Set(read.drawn).isDisjoint(with: read.pile)
                 && Set(read.pile).isDisjoint(with: read.unread) && Set(read.drawn).isDisjoint(with: read.unread)
                     && Set(read.unread).isDisjoint(with: read.trusted) && Set(read.trusted).isSubset(of: Set(read.drawn)), "ReadAdapter A7 violated")
        return AdaptedRead(read: read, record: rec, unmatchedOwners: ghosts, absenceRules: rules)
    }

    /// Normalised names of the running apps and the Control Center families, once per read (for `candidateOwners`).
    struct AbsenceFacts {
        var runningNorm: [[String]]
        var families: [Set<String>]
        init(context c: ReadContext) {
            families = c.ownerFamilies.map { Set($0.map(ReadAdapter.normalisedOwner)) }
            runningNorm = (c.ownerEvidence?.running ?? []).map { o in ([o.bundleID, o.name].compactMap { $0 } + o.ownerKeys).filter { !$0.isEmpty }.map(ReadAdapter.normalisedOwner) }
        }
    }

    /// An agent-hosted key: a `module:` key, or any key whose owner is the MenuBarAgent (a `status:` / `heuristic:` key with that owner, or an item
    /// info that says so). Decided from the KEY alone when no `ItemInfo` is available.
    static func isHostedOnly(_ key: ItemKey, _ info: ItemInfo?) -> Bool {
        if case .module = key { return true }
        if ArrangeSections.ownerBundleID(key)?.caseInsensitiveCompare(menuBarAgentBundleID) == .orderedSame { return true }
        return info?.ownerBundleID == menuBarAgentBundleID
    }

    /// Normalised owner name for the helper/relative test: lower case, team-id prefix (`86Z3GCJ4MF.`) removed, a `file://` path reduced to its last component.
    static func normalisedOwner(_ s: String) -> String {
        var n = Substring(s)
        if n.hasPrefix("file://"), let last = n.split(separator: "/").last { n = Substring(String(last).removingPercentEncoding ?? String(last)) }
        let u = Array(n.utf8)
        if u.count > 11, u[10] == UInt8(ascii: "."), u[0..<10].allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) }) { n = n.dropFirst(11) }   // team id prefix
        return n.lowercased()
    }

    /// Could `a` and `b` be the same app or an app and its helper? Equal, dotted prefix of each other, or a long common prefix (`...Hazel` / `...HazelHelper`,
    /// `dayone-mac` / `dayone-mac-agent`). Over-approximating is sound for absence: it only makes an app look MORE possibly running.
    static func related(_ a: String, _ b: String) -> Bool { relatedNormalised(normalisedOwner(a), normalisedOwner(b)) }
    static func relatedNormalised(_ x: String, _ y: String) -> Bool {
        if x.isEmpty || y.isEmpty { return false }
        return x == y || x.hasPrefix(y + ".") || y.hasPrefix(x + ".") || (x.count >= 8 && y.hasPrefix(x)) || (y.count >= 8 && x.hasPrefix(y))
    }

    /// Running apps that could own `key`: by name match (`owns`), by a helper/relative relation of the owner names (`related`), or by a Control Center family. (Only the apps themselves matter for rule (i): if any exists the key is not absent.)
    static func candidateOwners(of key: ItemKey, facts: AbsenceFacts, context c: ReadContext) -> [UnreadOwner] {
        guard let ev = c.ownerEvidence else { return [] }
        let ko = ArrangeSections.ownerBundleID(key).map(normalisedOwner)
        func familyOf(_ n: String) -> Set<Int> { Set(facts.families.indices.filter { facts.families[$0].contains(n) }) }
        let koFam = ko.map(familyOf) ?? []
        // apps that own the key by name, or are related to its owner string (a helper or relative: `related`), or share a Control Center family with it
        var direct: [Int] = []
        for (i, o) in ev.running.enumerated() {
            let ns = facts.runningNorm[i]
            if owns(o, key, info: c.itemInfo[key]) || (ko != nil && (ns.contains { relatedNormalised($0, ko!) } || ns.contains { !familyOf($0).isDisjoint(with: koFam) })) { direct.append(i) }
        }
        return direct.map { ev.running[$0] }
    }

    struct AbsenceDecision { var absent: Bool; var rule: String }

    /// THE rule for "not on the bar" (A6). `key` is a record key that is in none of drawn, pile, unread. It is left out of every list ONLY if:
    ///
    /// * **(B) Control Center hidden.** The scan saw `key` itself off the bar and Control Center says hidden (a parked key with no `parkedUnreadable` or
    ///   `placementUnknown` flag): absent. Residual assumption: the Control Center flag is authoritative.
    /// * **(i) No candidate owner is running.** `key` is an app key (never a `module:` or agent-hosted key: its owner is unknown) and no app in the running
    ///   list (`OwnerEvidence.running`, from a `runningApps()` snapshot taken after the scan's last AX read) could own it: its own name, a helper or relative of that name
    ///   (`related`), or a Control Center family (`ReadContext.ownerFamilies`). Nothing else about the read matters.
    ///   Residual assumptions (docs/verified-core.md, A6): an app's status item exists only while the app or one of its helper processes is running;
    ///   `runningApps()` omits `.prohibited` processes.
    ///
    /// EVERYTHING ELSE is unread: with no owner evidence, a `module:` / hosted-only key, or an app key whose owner is running.
    static func decideAbsence(_ key: ItemKey, order: ObservedOrder, facts: AbsenceFacts, context c: ReadContext) -> AbsenceDecision {
        if order.parked.contains(key), !order.parkedUnreadable.contains(key), !order.placementUnknown.contains(key) {
            return AbsenceDecision(absent: true, rule: "absent: (B) parked and hidden by Control Center")
        }
        if isHostedOnly(key, c.itemInfo[key]) { return AbsenceDecision(absent: false, rule: "unread: module/hosted key is never absent") }
        guard c.ownerEvidence != nil else { return AbsenceDecision(absent: false, rule: "unread: no owner evidence") }
        if candidateOwners(of: key, facts: facts, context: c).isEmpty { return AbsenceDecision(absent: true, rule: "absent: (i) no candidate owner is running") }
        return AbsenceDecision(absent: false, rule: "unread: an owner may be running, nothing shows the item is gone")
    }

    /// Pairs of record keys that look like ONE item (same owner and non-empty title, or the same frame on this read). A warning only: an alias is
    /// two record keys for one item; a clean read cannot detect it (both are record keys). Watched live (ejb.8).
    static func aliasPairs(_ record: [ItemKey], _ c: ReadContext) -> [(ItemKey, ItemKey)] {
        var out: [(ItemKey, ItemKey)] = []
        for (i, a) in record.enumerated() { for b in record[(i + 1)...] {
            if let x = c.itemInfo[a], let y = c.itemInfo[b], x.ownerPID == y.ownerPID, !x.title.isEmpty, x.title == y.title { out.append((a, b)); continue }
            if let fa = c.frames[a], let fb = c.frames[b], fa.width > 1, abs(fa.minX - fb.minX) < 1, abs(fa.width - fb.width) < 1 { out.append((a, b)) }
        } }
        return out
    }

    static func level(_ l: ReadCompleteness) -> ReadLevel {
        switch l { case .complete: return .complete; case .completeExceptSelfPositioning: return .exceptSelfPositioning; case .incomplete: return .incomplete }
    }

    /// Does `owner` possibly own `key`? Matches on pid, bundle id, display name or any owner-key candidate name (`OwnerKeyRule`) against what `itemInfo`
    /// and the key itself say, ignoring case. Over-approximating is sound (A6: an `unread` key may be anywhere); under-approximating is not.
    static func owns(_ o: UnreadOwner, _ key: ItemKey, info: ItemInfo?) -> Bool {
        let names = ([o.bundleID, o.name].compactMap { $0 } + o.ownerKeys).filter { !$0.isEmpty }
        func named(_ s: String?) -> Bool { guard let s, !s.isEmpty else { return false }; return names.contains { $0.caseInsensitiveCompare(s) == .orderedSame } }
        if let i = info, i.ownerPID == o.pid || named(i.ownerBundleID) || named(i.ownerName) { return true }
        return named(ArrangeSections.ownerBundleID(key))
    }
}
