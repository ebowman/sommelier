import Foundation

/// gdu.145: the rules that keep heuristic (fingerprint) keys out of the record when they are only a second name for an item the record already
/// holds under a status key, and that clean such keys out of an existing record.
///
/// Mechanism (docs/architecture.md, Identity): when a read joins an item without its identifier, or an agent-hosted element cannot be joined
/// to its owner, `IdentityResolver` mints `.heuristic(owner, fingerprint, ordinal)`. The engine used to record every unknown observed key, so
/// the record grew a second key for the same item, and under the verified core an alias key of a running owner is `unread`, which makes the
/// owner's drawn keys untrusted (docs/verified-core.md, A6).
public enum HeuristicKeyRule {
    /// Owner string compared the way the read adapter compares owners (case, team-id prefix).
    static func owner(_ k: ItemKey) -> String? {
        switch k {
        case .status(let o, _): return ReadAdapter.normalisedOwner(o)
        case .heuristic(let b, _, _): return ReadAdapter.normalisedOwner(b)
        case .module: return nil
        }
    }

    static func isAgentHeuristic(_ k: ItemKey) -> Bool {
        if case .heuristic(let b, _, _) = k { return b.caseInsensitiveCompare(IdentityResolver.agentBundleID) == .orderedSame }
        return false
    }

    // MARK: the one predicate (D1)

    /// The record's heuristic keys that are a duplicate of an accounted-for item on this scan. The single predicate behind the migration, the
    /// Arrange "Not running" hiding, and (by exclusion) the new-item gate. A heuristic key K of owner O is a duplicate iff ALL of:
    /// - the scan is complete and settled (`complete`);
    /// - K is NOT observed;
    /// - O is running and fully read: O has an observed item (so it is running) and O is not in `unreadOwners` (unread or cached);
    /// - every item the scan observes for O is under a status key that is actually seen on this scan: at least one observed status key of O,
    ///   and NO observed heuristic key of O. Status keys that are only in the record (stale, never observed) count for nothing.
    /// An agent-hosted heuristic key (owner MenuBarAgent) is a duplicate iff it is not observed, MenuBarAgent is not unread, and the scan
    /// observes no agent-hosted heuristic key at all (every hosted element joined to its owner).
    /// So an owner that is not running, unread or partially read keeps every key, and so does an owner whose live items read as heuristic keys
    /// (Tooth Fairy: its status keys are the stale ones; its heuristic keys are the live ones). Status and module keys are never duplicates.
    public static func duplicates(in layout: Layout, observed: Set<ItemKey>, unreadOwners: Set<String>, complete: Bool) -> [ItemKey] {
        guard complete else { return [] }
        var statusSeen = Set<String>(), heuristicSeen = Set<String>()
        var agentUnjoined = false
        for k in observed {
            switch k {
            case .status: if let o = owner(k) { statusSeen.insert(o) }
            case .heuristic:
                if isAgentHeuristic(k) { agentUnjoined = true }
                else if let o = owner(k) { heuristicSeen.insert(o) }
            case .module: break
            }
        }
        let agent = ReadAdapter.normalisedOwner(IdentityResolver.agentBundleID)
        var out: [ItemKey] = []
        var seen = Set<ItemKey>()
        for k in layout.allKeys where seen.insert(k).inserted {
            guard case .heuristic = k, !observed.contains(k) else { continue }
            if isAgentHeuristic(k) {
                if !agentUnjoined, !unreadOwners.contains(agent) { out.append(k) }
            } else if let o = owner(k), statusSeen.contains(o), !heuristicSeen.contains(o), !unreadOwners.contains(o) {
                out.append(k)
            }
        }
        return out
    }

    // MARK: migration (step 4)

    /// Removes `duplicates(...)` from the record. Pure: status and module keys are never dropped, an observed key is never dropped, and the keys
    /// that stay keep their relative order (so no real item moves).
    public static func migrate(_ layout: Layout, observed: Set<ItemKey>, unreadOwners: Set<String> = [], complete: Bool = true) -> (layout: Layout, dropped: [ItemKey]) {
        let dropped = duplicates(in: layout, observed: observed, unreadOwners: unreadOwners, complete: complete)
        guard !dropped.isEmpty else { return (layout, []) }
        let gone = Set(dropped)
        var out = layout
        out.visible = layout.visible.filter { !gone.contains($0) }
        out.hidden = layout.hidden.filter { !gone.contains($0) }
        out.alwaysHidden = layout.alwaysHidden.filter { !gone.contains($0) }
        return (out, dropped)
    }
}

/// gdu.145 step 2 (D2): which unknown observed keys may become record keys. Status and module keys always may. A heuristic key may not
/// - while the read is not complete and settled;
/// - until it has been observed on two consecutive complete settled scans (a one-scan transient unjoined read is never recorded).
/// It is never refused forever: a real second item that keeps reading as a heuristic key is admitted on its second sighting. The duplicates
/// that were already in the record arose from transient reads, which this corroboration filters; the ones already there are cleaned by
/// `HeuristicKeyRule.migrate`.
public struct HeuristicNewItemGate: Sendable {
    /// Consecutive complete reads that saw this not-yet-recorded heuristic key (and no complete read missed it in between).
    private(set) var sightings: [ItemKey: Int] = [:]
    public init() {}

    public static let sightingsNeeded = 2

    /// Call once per read with every key of the read. Counts sightings on complete (settled) reads only; an incomplete read neither counts nor resets.
    public mutating func note(observed: [ItemKey], layout: Layout, complete: Bool) {
        guard complete else { return }
        let seen = Set(observed.filter { if case .heuristic = $0 { return layout.section(of: $0) == nil }; return false })
        for k in sightings.keys where !seen.contains(k) { sightings[k] = nil }
        for k in seen { sightings[k, default: 0] += 1 }
    }

    /// The new items the engine may record, and the held ones with the reason.
    public func filter(_ items: [NewItem], complete: Bool) -> (admitted: [NewItem], held: [(NewItem, String)]) {
        var admitted: [NewItem] = [], held: [(NewItem, String)] = []
        for n in items {
            guard case .heuristic = n.key else { admitted.append(n); continue }
            if !complete { held.append((n, "the read is not complete and settled")); continue }
            if sightings[n.key, default: 0] < Self.sightingsNeeded { held.append((n, "not yet seen on two consecutive complete settled scans")); continue }
            admitted.append(n)
        }
        return (admitted, held)
    }
}
