import Foundation

/// Error state of the overflow panel (gdu.49). An entry whose activation failed is outlined with a caption until its own
/// clear fires. The entry is retained for that time even when the entries refresh no longer lists it (an app that is not
/// running disappears from the hidden items), so the caption stays readable for the whole interval.
public struct OverflowFeedbackModel: Sendable {
    public private(set) var errors: [ItemKey: String] = [:]
    private var retained: [ItemKey: (entry: OverflowEntry, index: Int)] = [:]

    public init() {}

    /// Records a failure for `entry`, remembering its position in the `current` rendered list.
    public mutating func fail(_ entry: OverflowEntry, message: String, in current: [OverflowEntry]) {
        errors[entry.key] = message
        retained[entry.key] = (entry, current.firstIndex { $0.key == entry.key } ?? current.count)
    }

    /// Clears one key only; other keys' errors and retained entries are untouched.
    public mutating func clear(_ key: ItemKey) {
        errors[key] = nil
        retained[key] = nil
    }

    /// `entries` plus the retained failed entries that dropped out of it, each back at its remembered position.
    public func rendered(_ entries: [OverflowEntry]) -> [OverflowEntry] {
        var out = entries
        let present = Set(entries.map(\.key))
        for (k, r) in retained.sorted(by: { $0.value.index < $1.value.index }) where !present.contains(k) {
            out.insert(r.entry, at: min(r.index, out.count))
        }
        return out
    }
}
