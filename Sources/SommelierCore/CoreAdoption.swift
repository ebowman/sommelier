import Foundation
import DecisionCore

/// ejb.9 "Use the bar's current order": the record the bar's own order would make, with no drags.
///
/// The DECISION is Lean's (`adoptProposal`, lean/Sommelier/Adopt.lean, exported as `sommelier_adopt`): it answers only when the core's shown verdict of
/// the read is `differs`, and the answer is a permutation of the record in which the keys the read pins (behind « first, then the open keys, in the
/// read's order) refill the slots those keys had and every other key stays where it is. Swift only encodes the read, decodes the record and maps the
/// answer into the Layout's Visible strip (`preview`), which is a structural re-slotting of a permutation, not a decision.
public enum CoreAdoption {
    /// The proposal for `state` and the last PASS read `read`, as engine keys; nil when the core has none (the verdict is not `differs`, which includes an
    /// unusable read) or when an id cannot be mapped back or the call fails (then nothing is offered).
    public static func proposal(state: DecisionState, read: Read, keys: CoreKeys) -> [ItemKey]? {
        guard read.kind == .pass, let ids = (try? DecisionCore.adoptProposal(state, read)) ?? nil else { return nil }
        let mapped = ids.compactMap { keys.key(for: $0) }
        return mapped.count == ids.count ? mapped : nil
    }

    /// The same for a bare record (a fresh core state for it): the pure function the bead asks for. A fresh state has not proved the bar not full, so a
    /// chevron-less read is not usable here (the engine's own state, used by `CoreDriver`, carries that proof).
    public static func proposal(record: [ItemKey], read: Read, keys: CoreKeys) -> [ItemKey]? {
        let ids = record.compactMap { keys.id(for: $0) }
        guard ids.count == record.count, let state = try? DecisionState(record: ids) else { return nil }
        return proposal(state: state, read: read, keys: keys)
    }

    /// One key whose place in the Visible strip changes (positions are 1-based, left to right).
    public struct Change: Equatable, Sendable {
        public var key: ItemKey
        public var from: Int
        public var to: Int
    }

    /// What Save would do: the layout with its Visible strip re-ordered, and the keys that change position.
    public struct Preview: Equatable, Sendable {
        public var layout: Layout
        public var before: [ItemKey]
        public var after: [ItemKey]
        public var changes: [Change]
    }

    /// Places `proposal` (a permutation of the core's record) into `layout.visible`: the proposal's keys refill, in order, the positions the same keys
    /// have in Visible; every other key of Visible (chevron, immovable, not in the core's record) keeps its position. nil when the proposal is not
    /// exactly a re-ordering of keys of Visible (the layout changed since the read: nothing is offered) or changes nothing.
    public static func preview(proposal: [ItemKey]?, layout: Layout) -> Preview? {
        guard let proposal, !proposal.isEmpty else { return nil }
        let set = Set(proposal)
        guard set.count == proposal.count else { return nil }
        var seen = Set<ItemKey>(), slots: [Int] = []
        for (i, k) in layout.visible.enumerated() where set.contains(k) && seen.insert(k).inserted { slots.append(i) }
        guard seen == set else { return nil }   // a proposed key is no longer in Visible
        var after = layout.visible
        for (slot, k) in zip(slots, proposal) { after[slot] = k }
        guard after != layout.visible else { return nil }
        var l = layout
        l.visible = after
        let b = layout.visible, a = after
        var changes: [Change] = []
        for (i, k) in a.enumerated() where b[i] != k { changes.append(Change(key: k, from: (b.firstIndex(of: k) ?? i) + 1, to: i + 1)) }
        return Preview(layout: l, before: b, after: a, changes: changes)
    }
}
