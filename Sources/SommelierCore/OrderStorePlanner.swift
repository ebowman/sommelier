import Foundation

/// Pure planning of the order-store (`TrailingItemPreferredPositions`) write for a fallback move (gdu.25).
///
/// Values are distances from the trailing edge: a LARGER value is further LEFT. The planner receives the participating
/// keys in their desired left-to-right order (subject already at its new slot) and the store values, and returns the
/// smallest set of writes that gives the subject a value strictly between its new neighbours:
///
/// 1. both neighbours exist and an integer fits strictly between them: the subject alone gets the midpoint
///    `floor((L + R) / 2)`; no other key is written (duplicates elsewhere in the store are irrelevant);
/// 2. only one neighbour exists (leftmost / rightmost slot): the subject gets `R + 2` / `L - 2` (when that is >= 1);
/// 3. no gap (adjacent integers), equal neighbour values (duplicates straddling the slot), inverted neighbours, or no
///    room at the end: the contiguous run around the slot is re-based. The run starts as the subject alone and grows
///    one neighbour at a time until it sits between two untouched anchors with room for a spacing of at least 2 (or
///    reaches an end of the participant list); its keys are spread evenly between the anchors keeping their order.
///    Keys outside the run are never written.
public enum OrderStorePlanner {
    public struct Plan: Equatable, Sendable {
        /// Store key -> new value; only entries whose value changes.
        public var updates: [String: Double]
        /// True when the contiguous-run re-base was needed (rule 3), false for a single midpoint (rules 1-2).
        public var rebased: Bool
    }

    /// `order`: participant store keys, left to right, subject at its desired slot. `values`: current store values for
    /// every key in `order` except possibly the subject. Returns nil when `subject` is not in `order` or a non-subject
    /// key has no value.
    public static func plan(order: [String], subject: String, values: [String: Double]) -> Plan? {
        guard let i = order.firstIndex(of: subject) else { return nil }
        var vals: [Double?] = []
        for k in order {
            if k == subject { vals.append(nil) } else if let v = values[k] { vals.append(v) } else { return nil }
        }
        let n = order.count
        let left: Double? = i > 0 ? vals[i - 1] : nil
        let right: Double? = i < n - 1 ? vals[i + 1] : nil

        func finish(_ new: [String: Double], rebased: Bool) -> Plan {
            Plan(updates: new.filter { values[$0.key] != $0.value }, rebased: rebased)
        }
        // Rules 1 and 2.
        switch (left, right) {
        case let (l?, r?):
            if l - r >= 2 {
                let m = ((l + r) / 2).rounded(.down)
                if m < l && m > r { return finish([subject: m], rebased: false) }
            }
        case let (l?, nil):
            if l - 2 >= 1 { return finish([subject: l - 2], rebased: false) }
        case let (nil, r?):
            return finish([subject: r + 2], rebased: false)
        case (nil, nil):
            return finish([subject: values[subject] ?? 100], rebased: false)   // alone: nothing to order against
        }

        // Rule 3: grow the run [a, b] until it fits between its anchors.
        var a = i, b = i
        while true {
            let count = b - a + 1
            let top: Double? = a > 0 ? vals[a - 1] : nil
            let bottomAnchor: Double? = b < n - 1 ? vals[b + 1] : nil
            let known = (a...b).compactMap { vals[$0] }
            var base: Double
            if let bottomAnchor { base = bottomAnchor }
            else if let lowest = known.min() { base = lowest - 2 }     // the run keeps its own lowest value as the floor
            else if a > 0 { a -= 1; continue }                          // nothing to anchor the floor on yet
            else { base = 0 }
            base = base.rounded(.down)
            var step = 2.0
            if let top {
                step = ((top - base) / Double(count + 1)).rounded(.down)
                if step < 2 {
                    if a > 0 { a -= 1; continue }
                    if b < n - 1 { b += 1; continue }
                    step = 2   // unreachable: a == 0 means top == nil
                }
            }
            var new: [String: Double] = [:]
            for k in a...b { new[order[k]] = base + step * Double(b - k + 1) }
            return finish(new, rebased: true)
        }
    }
}
