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

    public init(key: ItemKey, title: String, axDescription: String, ownerPID: pid_t, ownerBundleID: String?,
                ownerName: String, width: CGFloat, isOnBar: Bool) {
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
                                  isOnBar: i.isOnMenuBar)
        }
        return out
    }

    /// Result is exactly the keys of `fresh` (vanished items are dropped); a fresh width <= 1 (parked item) keeps the
    /// previous non-trivial width when one is known.
    public static func merge(previous: [ItemKey: ItemInfo], fresh: [ItemKey: ItemInfo]) -> [ItemKey: ItemInfo] {
        var out = fresh
        for (k, var v) in fresh where v.width <= 1 {
            if let p = previous[k], p.width > 1 { v.width = p.width; out[k] = v }
        }
        return out
    }
}
