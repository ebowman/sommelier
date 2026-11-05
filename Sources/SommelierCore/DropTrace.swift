import Foundation

/// gdu.102: pure text builders for the per-drop log trail. Every stage of one Arrange gesture carries the same `drop#<n>` prefix so
/// `grep 'drop#7' sommelier.log` tells the whole story. No behaviour: text only.
public struct DropTrace {
    public static let maxListItems = 12

    public static func tag(_ id: Int) -> String { "drop#\(id)" }

    /// "Title(key)" for one neighbour.
    private static func label(_ k: ItemKey, _ name: (ItemKey) -> String) -> String { "\(name(k))(\(k))" }

    /// What the user intended: the dragged item, the destination slot, and the real rows (ghosts, boundary, the item itself skipped)
    /// left and right of the slot, plus the observation state at that moment.
    public static func intentLine(id: Int, key: ItemKey, section: LayoutSection, slot: Int, rows: [ArrangeRow],
                                  observed: ObservedOrder, settled: Bool, displayName: (ItemKey) -> String) -> String {
        let at = min(max(0, slot), rows.count)
        let left = rows[..<at].last { !$0.isGhost && !$0.isBoundary && $0.key != key }?.key
        let right = rows[at...].first { !$0.isGhost && !$0.isBoundary && $0.key != key }?.key
        let l = left.map { label($0, displayName) } ?? "start"
        let r = right.map { label($0, displayName) } ?? "end"
        return "\(tag(id)) intent: \(label(key, displayName)) -> \(section.rawValue) slot \(slot); between \(l) and \(r); "
            + "observed: onBar=\(observed.onBar.count) stale=\(observed.staleOnBar.count) settled=\(settled)"
    }

    /// The layout the drop produced: the key's neighbours in its section and whether it is now a user-placed key.
    public static func layoutLine(id: Int, key: ItemKey, layout: Layout) -> String {
        guard let sec = layout.section(of: key) else { return "\(tag(id)) layout: \(key) in no section; placed=no" }
        let keys = layout.keys(in: sec)
        let i = keys.firstIndex(of: key)!
        let l = i > 0 ? "\(keys[i - 1])" : "start"
        let r = i + 1 < keys.count ? "\(keys[i + 1])" : "end"
        return "\(tag(id)) layout: \(sec.rawValue) after \(l) before \(r); placed=\(layout.placedSet.contains(key) ? "yes" : "no")"
    }

    public static func rejectedLine(id: Int, why: String) -> String { "\(tag(id)) rejected: \(why)" }
    public static func doneLine(id: Int, outcome: String) -> String { "\(tag(id)) done: \(outcome)" }

    /// "L2 L1 [K] R1 R2" from the observed bar order (two each side), or "K not on the bar".
    public static func around(_ key: ItemKey, in onBar: [ItemKey], radius: Int = 2) -> String {
        guard let i = onBar.firstIndex(of: key) else { return "\(key) not on the bar" }
        let lo = max(0, i - radius), hi = min(onBar.count - 1, i + radius)
        return (lo...hi).map { $0 == i ? "[\(onBar[$0])]" : "\(onBar[$0])" }.joined(separator: " ")
    }

    /// "between A and B" (or start / end) for `key` in the observed bar order; "not on the bar" when absent.
    public static func between(_ key: ItemKey, in onBar: [ItemKey]) -> String {
        guard let i = onBar.firstIndex(of: key) else { return "not on the bar" }
        return "between \(i > 0 ? "\(onBar[i - 1])" : "start") and \(i + 1 < onBar.count ? "\(onBar[i + 1])" : "end")"
    }

    /// Joins at most `maxListItems` entries, then "…".
    public static func truncated(_ items: [String], max: Int = maxListItems, separator: String = ",") -> String {
        items.count <= max ? items.joined(separator: separator) : items.prefix(max).joined(separator: separator) + "…"
    }
}
