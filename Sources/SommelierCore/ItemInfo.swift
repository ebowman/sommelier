import CoreGraphics
import Foundation

/// Display metadata for one menu bar item, as of the last adopted scan.
public struct ItemInfo: Equatable, Sendable {
    public var key: ItemKey
    public var title: String
    public var axDescription: String
    public var ownerPID: pid_t
    public var ownerBundleID: String?
    public var ownerName: String
    public var width: CGFloat
    public var isOnBar: Bool
    /// macOS moved it into its own overflow behind the chevron: reported on the bar, but not drawn (gdu.45).
    public var systemOverflow: Bool

    public init(key: ItemKey, title: String, axDescription: String, ownerPID: pid_t, ownerBundleID: String?,
                ownerName: String, width: CGFloat, isOnBar: Bool, systemOverflow: Bool = false) {
        self.systemOverflow = systemOverflow
        self.key = key; self.title = title; self.axDescription = axDescription; self.ownerPID = ownerPID
        self.ownerBundleID = ownerBundleID; self.ownerName = ownerName; self.width = width; self.isOnBar = isOnBar
    }

    /// Indexes fresh (non-stale) resolved items by key; the first occurrence of a duplicate key wins.
    public static func index(from resolved: [ResolvedItem]) -> [ItemKey: ItemInfo] {
        var out: [ItemKey: ItemInfo] = [:]
        for r in resolved where !r.item.stale && out[r.key] == nil {
            let i = r.item
            out[r.key] = ItemInfo(key: r.key, title: i.title, axDescription: i.axDescription, ownerPID: i.ownerPID,
                                  ownerBundleID: i.ownerBundleID, ownerName: i.ownerName, width: i.frame.width,
                                  isOnBar: i.isOnMenuBar, systemOverflow: i.systemOverflow)
        }
        return out
    }

    /// Keys that appear in `resolved` only as stale (carried-forward) reads: present, but with no fresh data this scan.
    public static func staleOnlyKeys(from resolved: [ResolvedItem]) -> Set<ItemKey> {
        let fresh = Set(resolved.filter { !$0.item.stale }.map(\.key))
        return Set(resolved.filter { $0.item.stale }.map(\.key)).subtracting(fresh)
    }

    /// Result is the keys of `fresh` (vanished items are dropped) plus the `retaining` keys (stale reads, not yet confirmed
    /// gone) that keep their previous info; a fresh width <= 1 (parked item) keeps the previous non-trivial width when one is known.
    public static func merge(previous: [ItemKey: ItemInfo], fresh: [ItemKey: ItemInfo],
                             retaining: Set<ItemKey> = []) -> [ItemKey: ItemInfo] {
        var out = fresh
        for k in retaining where out[k] == nil { if let p = previous[k] { out[k] = p } }
        for (k, var v) in fresh where v.width <= 1 {
            if let p = previous[k], p.width > 1 { v.width = p.width; out[k] = v }
        }
        return out
    }
}
