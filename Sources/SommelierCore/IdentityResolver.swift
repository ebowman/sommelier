import CoreGraphics
import Foundation

/// A menu bar item together with its resolved identity.
public struct ResolvedItem: Sendable {
    public var item: MenuBarItem
    public var key: ItemKey
    public var confidence: KeyConfidence
    public init(item: MenuBarItem, key: ItemKey, confidence: KeyConfidence) {
        self.item = item; self.key = key; self.confidence = confidence
    }
    /// The owner key actually matched in the store/defaults (nil for heuristic/module keys).
    public var ownerKey: String? {
        if case .status(let o, _) = key { return o }
        return nil
    }
}

/// Maps snapshot items to `ItemKey`s.
///
/// Per owning process (items grouped by `ownerPID`, `appExtras` only):
/// 1. Pick the owner key: every `OwnerKeyRule.candidates` value that has autosave names (order store first, legacy
///    defaults second) is scored by identifier matches then by agreement between store values and on-bar x order;
///    ties go to the earlier candidate (rule order). This disambiguates stale duplicate entries (e.g. both
///    `status:iStat Menus Menubar::...` and `status:com.bjango.istatmenus.status::...`).
/// 2. Items whose AXIdentifier equals an autosave name -> `.status`, `.exact`.
/// 3. Remaining items vs remaining names:
///    * one item and one name -> `.status`; `.exact` only if the item carries a non-empty AXIdentifier and is not stale
///      (the owner attribution is then identifier-based), otherwise `.inferred`. Frame-only evidence never gives `.exact`.
///    * equal counts > 1, all items on the bar, all store values distinct -> pair by order. ASSUMPTION: the store
///      value is the distance from the trailing (right) edge, so a bigger value means further left; sort names by
///      value descending, items by x ascending, zip. `.inferred`. Only valid for on-bar items: parked items have
///      meaningless x, and hidden items' values may be huge (5000+) without being on the bar.
///    * anything else -> `.heuristic`.
/// 4. Heuristic key: `(bundle id or owner name, fingerprint, ordinal)`, fingerprint = AXIdentifier, else
///    description, else title with digits masked (live readouts like "64%"). Ordinal counts same-fingerprint items
///    of that owner by (x, y, discovery order). Deterministic while the owner's frames are stable.
/// 5. `agentHostedOnly` items -> `.module(<name>)`; the name is the store's `module:` entry when the AXIdentifier's last
///    component matches one (`com.apple.menuextra.clock` -> `Clock`), `.inferred`; otherwise AXIdentifier or description
///    verbatim with `.heuristic`; with neither -> `.heuristic("com.apple.MenuBarAgent", ...)`.
public struct IdentityResolver: Sendable {
    public var prefs: any PreferenceReader
    public var ownerInfo: @Sendable (pid_t) -> OwnerAppInfo?

    public init(prefs: any PreferenceReader = LivePreferenceReader(),
                ownerInfo: @escaping @Sendable (pid_t) -> OwnerAppInfo? = { OwnerAppInfo.live(pid: $0) }) {
        self.prefs = prefs
        self.ownerInfo = ownerInfo
    }

    public static let agentBundleID = "com.apple.MenuBarAgent"

    /// Results are in `snapshot.items` order.
    public func resolve(snapshot: MenuBarSnapshot) -> [ResolvedItem] {
        let store = prefs.orderStore()
        let storeByOwner = Self.group(store)
        var results = [ResolvedItem?](repeating: nil, count: snapshot.items.count)

        // Group app items by pid, remembering the original index.
        var groups: [pid_t: [Int]] = [:]
        for (i, it) in snapshot.items.enumerated() where it.source == .appExtras { groups[it.ownerPID, default: []].append(i) }

        var legacyCache: [String: [AutosaveEntry]] = [:]
        for (pid, idxs) in groups.sorted(by: { $0.key < $1.key }) {
            let items = idxs.map { snapshot.items[$0] }
            let first = items[0]
            var info = ownerInfo(pid) ?? OwnerAppInfo()
            if info.bundleID == nil { info.bundleID = first.ownerBundleID }
            if info.localizedName == nil { info.localizedName = first.ownerName }
            let cands = OwnerKeyRule.candidates(for: info)

            // Candidate -> entries.
            var options: [(owner: String, entries: [AutosaveEntry], fromStore: Bool)] = []
            for c in cands {
                if let e = storeByOwner[c], !e.isEmpty { options.append((c, e, true)) }
            }
            if options.isEmpty, let owner = cands.first {
                // Legacy keys live in the app's own defaults domain (bundle id; process name for bare executables).
                let domain = info.bundleID ?? owner
                let legacy = legacyCache[domain] ?? prefs.legacyEntries(domain: domain)
                legacyCache[domain] = legacy
                if !legacy.isEmpty { options.append((owner, legacy, false)) }
            }

            let bundleLabel = info.bundleID ?? first.ownerName
            var assigned: [Int: (ItemKey, KeyConfidence)] = [:]   // index within `items`
            if let best = Self.chooseOption(options.map { ($0.owner, $0.entries, $0.fromStore) }, items: items) {
                assigned = Self.assign(owner: best.owner, entries: best.entries, fromStore: best.fromStore, items: items)
            }
            var out: [(ItemKey, KeyConfidence)?] = items.indices.map { assigned[$0] }
            Self.fillHeuristics(&out, items: items, bundleLabel: bundleLabel)
            for (n, gi) in idxs.enumerated() { let (k, c) = out[n]!; results[gi] = ResolvedItem(item: items[n], key: k, confidence: c) }
        }

        // Agent-hosted-only items.
        let moduleNames = storeByModule(store)
        var hostedIdx = snapshot.items.indices.filter { snapshot.items[$0].source == .agentHostedOnly }
        hostedIdx.sort { a, b in
            let (ia, ib) = (snapshot.items[a], snapshot.items[b])
            return (ia.frame.minX, ia.frame.minY, a) < (ib.frame.minX, ib.frame.minY, b)
        }
        var heurOrdinals: [String: Int] = [:]
        for i in hostedIdx {
            let it = snapshot.items[i]
            // `_NS:<n>` identifiers are per-launch AppKit numbering of the frontmost app's MENUS (File, Edit, ...),
            // not status items; never use them as a module name.
            if it.isOverflowChevron {
                // Stable under every locale: keyed by the English name whatever the localized description says.
                results[i] = ResolvedItem(item: it, key: .module(name: MenuBarItem.overflowChevronName), confidence: .inferred)
                continue
            }
            let ident = it.axIdentifier.hasPrefix("_NS:") ? "" : it.axIdentifier
            let name = !ident.isEmpty ? ident : it.axDescription
            if !name.isEmpty {
                if let m = Self.matchModule(identifier: ident, description: it.axDescription, moduleNames: moduleNames) {
                    results[i] = ResolvedItem(item: it, key: .module(name: m), confidence: .inferred)
                } else {
                    results[i] = ResolvedItem(item: it, key: .module(name: name), confidence: .heuristic)
                }
            } else {
                let fp = Self.fingerprint(it)
                let k = "\(fp)"
                let n = heurOrdinals[k, default: 0]; heurOrdinals[k] = n + 1
                results[i] = ResolvedItem(item: it, key: .heuristic(bundleID: Self.agentBundleID, fingerprint: fp, ordinal: n), confidence: .heuristic)
            }
        }
        return results.map { $0! }
    }

    // MARK: - helpers

    static func group(_ store: [String: Double]) -> [String: [AutosaveEntry]] {
        var out: [String: [AutosaveEntry]] = [:]
        for (k, v) in store {
            guard case .status(let o, let a)? = ItemKey(storeKey: k) else { continue }
            out[o, default: []].append(AutosaveEntry(name: a, storeValue: v))
        }
        return out.mapValues { $0.sorted { $0.name < $1.name } }
    }

    func storeByModule(_ store: [String: Double]) -> [String] {
        store.keys.compactMap { if case .module(let n)? = ItemKey(storeKey: $0) { return n } else { return nil } }.sorted()
    }

    /// Value used for ordering: the store value, else the legacy preferred position.
    static func value(_ e: AutosaveEntry) -> Double? { e.storeValue ?? e.legacyPosition }

    static func isOnBar(_ i: MenuBarItem) -> Bool { i.isOnMenuBar && i.frame.width > 0 }

    static func fingerprint(_ i: MenuBarItem) -> String {
        if !i.axIdentifier.isEmpty { return i.axIdentifier }
        if !i.axDescription.isEmpty { return i.axDescription }
        return String(i.title.map { $0.isNumber ? "#" : $0 })
    }

    /// Score each option: identifier matches * 1000 + concordant on-bar pairs; earlier option wins ties.
    static func chooseOption(_ options: [(String, [AutosaveEntry], Bool)], items: [MenuBarItem])
        -> (owner: String, entries: [AutosaveEntry], fromStore: Bool)?
    {
        var best: (score: Int, idx: Int)?
        for (n, o) in options.enumerated() {
            let names = Set(o.1.map(\.name))
            var score = items.filter { names.contains($0.axIdentifier) }.count * 1000
            let bar = items.filter { isOnBar($0) && !$0.stale }.sorted { ($0.frame.minX) < ($1.frame.minX) }
            let vals: [Double?] = bar.map { i in o.1.first { $0.name == i.axIdentifier }.flatMap(value) }
            for a in 0..<vals.count { for b in (a + 1)..<max(a + 1, vals.count) {
                if let va = vals[a], let vb = vals[b], va > vb { score += 1 }   // left item has the bigger value
            } }
            if best == nil || score > best!.score { best = (score, n) }
        }
        guard let b = best else { return nil }
        return (options[b.idx].0, options[b.idx].1, options[b.idx].2)
    }

    static func assign(owner: String, entries: [AutosaveEntry], fromStore: Bool, items: [MenuBarItem]) -> [Int: (ItemKey, KeyConfidence)] {
        var out: [Int: (ItemKey, KeyConfidence)] = [:]
        var freeNames = entries
        // 2. identifier == autosave name
        for (n, it) in items.enumerated() where !it.axIdentifier.isEmpty {
            if let k = freeNames.firstIndex(where: { $0.name == it.axIdentifier }) {
                out[n] = (.status(ownerKey: owner, autosaveName: it.axIdentifier), .exact)
                freeNames.remove(at: k)
            }
        }
        let rest = items.indices.filter { out[$0] == nil }
        guard !rest.isEmpty, !freeNames.isEmpty else { return out }
        // 3a. one item, one name
        if rest.count == 1 && freeNames.count == 1 {
            let it = items[rest[0]]
            let c: KeyConfidence = (!it.axIdentifier.isEmpty && !it.stale) ? .exact : .inferred
            out[rest[0]] = (.status(ownerKey: owner, autosaveName: freeNames[0].name), c)
            return out
        }
        // 3b. order pairing (on-bar only, distinct values)
        if rest.count == freeNames.count, rest.allSatisfy({ isOnBar(items[$0]) && !items[$0].stale }) {
            let vals = freeNames.map(value)
            if vals.allSatisfy({ $0 != nil }), Set(vals.map { $0! }).count == vals.count {
                let names = freeNames.sorted { value($0)! > value($1)! }   // bigger = further left
                let byX = rest.sorted { (items[$0].frame.minX, $0) < (items[$1].frame.minX, $1) }
                for (n, name) in zip(byX, names) {
                    out[n] = (.status(ownerKey: owner, autosaveName: name.name), .inferred)
                }
            }
        }
        return out
    }

    static func fillHeuristics(_ out: inout [(ItemKey, KeyConfidence)?], items: [MenuBarItem], bundleLabel: String) {
        var ordinals: [String: Int] = [:]
        let order = items.indices.sorted { a, b in
            let (ia, ib) = (items[a], items[b])
            return (ia.frame.minX, ia.frame.minY, a) < (ib.frame.minX, ib.frame.minY, b)
        }
        for n in order where out[n] == nil {
            let fp = fingerprint(items[n])
            let o = ordinals[fp, default: 0]; ordinals[fp] = o + 1
            out[n] = (.heuristic(bundleID: bundleLabel, fingerprint: fp, ordinal: o), .heuristic)
        }
    }

    /// `com.apple.menuextra.audiovideo` -> store module `AudioVideoModule`; `...clock` -> `Clock`.
    static func matchModule(identifier: String, description: String, moduleNames: [String]) -> String? {
        func norm(_ s: String) -> String {
            var t = s.lowercased().filter { $0.isLetter || $0.isNumber }
            if t.hasSuffix("module") && t.count > 6 { t.removeLast(6) }
            return t
        }
        var probes: [String] = []
        if !identifier.isEmpty { probes.append(norm(identifier.split(separator: ".").last.map(String.init) ?? identifier)) }
        if !description.isEmpty { probes.append(norm(description)) }
        for p in probes where !p.isEmpty {
            if let m = moduleNames.first(where: { norm($0) == p }) { return m }
        }
        return nil
    }
}
