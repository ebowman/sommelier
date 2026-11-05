import Foundation

/// Error state of the overflow panel (gdu.49). An entry whose activation failed is outlined with a caption until its own
/// clear fires. The entry is retained for that time even when the entries refresh no longer lists it (an app that is not
/// running disappears from the hidden items), so the caption stays readable for the whole interval.
public struct OverflowFeedbackModel: Sendable {
    public private(set) var errors: [ItemKey: String] = [:]
    /// Neutral captions for a successful activation that carried a note (no outline).
    public private(set) var notes: [ItemKey: String] = [:]
    private var retained: [ItemKey: (entry: OverflowEntry, index: Int)] = [:]

    public init() {}

    /// Records a failure for `entry`, remembering its position in the `current` rendered list.
    public mutating func fail(_ entry: OverflowEntry, message: String, in current: [OverflowEntry]) {
        errors[entry.key] = message
        retained[entry.key] = (entry, current.firstIndex { $0.key == entry.key } ?? current.count)
    }

    public mutating func note(_ key: ItemKey, message: String) { notes[key] = message }

    /// Clears one key only; other keys' errors and retained entries are untouched.
    public mutating func clear(_ key: ItemKey) {
        errors[key] = nil
        notes[key] = nil
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

/// Caption for a finished activation (pure). Failures are errors; a successful activation with a note gets a neutral caption.
public enum ActivationCaption {
    public enum Severity: Equatable, Sendable { case error, neutral }
    public static func make(_ r: ActivationResult) -> (text: String, severity: Severity)? {
        switch r {
        case .failed(let e): return (e.description, .error)
        case .opened(let o):
            guard let n = o.note else { return nil }
            let clauses = n.split(separator: ",").compactMap { p -> String? in
                switch p {
                case "overflowStripStillExpanded": return "overflow strip left expanded"
                case "menuStillOpenAtCap": return "still open"
                case "overflowStripStateUnknown": return "overflow strip state unknown"
                default: return nil
                }
            }
            return clauses.isEmpty ? nil : (("menu opened; " + clauses.joined(separator: "; ")), .neutral)
        }
    }
}
