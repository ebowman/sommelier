import Foundation

/// Maps an item's owner identifiers to the Control Center `trackedApplications` entry that governs its visibility
/// (bead sommelier-gdu.68). Planner (capabilities) and actuator (`trackedKey(for:)`) both use this one type.
///
/// Live finding 2026-11-05 (docs/findings-untracked-hide.md): helper processes (Hazel Helper, HoudahSpot Helper,
/// Fantastical Helper, Keyboard Maestro Engine, Little Snitch Agent, ...) have no entry of their own; they are listed in
/// the `menuItemLocations` of their PARENT app's entry, and flipping the parent's `isAllowed` adds/removes the helper's
/// hosted element. So the parent entry is the hide unit of the helper.
///
/// Resolution order, first match wins:
/// 1. an entry whose key equals a candidate (the owner has its own entry; this also wins when a different entry lists it);
/// 2. the single non-Apple entry whose `menuItemLocations` list a candidate. Several different parents listing the same
///    id is ambiguous and resolves to nil (never guess which flag to flip).
public struct TrackedEntryResolver: Sendable {
    public let entries: [ControlCenterTrackedAppsStore.Entry]
    private let byKey: Set<String>
    private let parentsOf: [String: [String]]

    public init(entries: [ControlCenterTrackedAppsStore.Entry]) {
        self.entries = entries
        byKey = Set(entries.map(\.key))
        var p: [String: [String]] = [:]
        for e in entries where !e.key.hasPrefix("com.apple.") {
            for m in e.menuItemKeys where m != e.key && !(p[m]?.contains(e.key) ?? false) { p[m, default: []].append(e.key) }
        }
        parentsOf = p
    }

    /// Keys only (no `menuItemLocations` knowledge): exact matches resolve, helpers do not.
    public init(keys: Set<String>) {
        self.init(entries: keys.sorted().map { .init(key: $0, isAllowed: true, menuItemKeys: []) })
    }

    /// The store as it is now; nil when unreadable.
    public static func current(store: ControlCenterTrackedAppsStore = ControlCenterTrackedAppsStore()) -> TrackedEntryResolver? {
        (try? store.entries()).map { TrackedEntryResolver(entries: $0) }
    }

    public func trackedKey(candidates: [String]) -> String? {
        if let own = candidates.first(where: byKey.contains) { return own }
        for c in candidates {
            if let ps = parentsOf[c], ps.count == 1 { return ps[0] }
        }
        return nil
    }

    /// Candidates of an item key: its owner key / heuristic bundle id, plus the process bundle id when known.
    public func trackedKey(for key: ItemKey, bundleID: String?) -> String? {
        var c: [String] = []
        switch key {
        case .status(let owner, _): c.append(owner)
        case .heuristic(let b, _, _): c.append(b)
        case .module: return nil
        }
        if let bundleID { c.append(bundleID) }
        return trackedKey(candidates: c)
    }

    /// True when the resolved entry is a parent (the owner has no entry of its own).
    public func isViaParent(candidates: [String]) -> Bool {
        !candidates.contains(where: byKey.contains) && trackedKey(candidates: candidates) != nil
    }
}
