import CoreGraphics
import Foundation

/// Pure verification predicates (docs/architecture.md (c) step 4). Input is the resolved items of a settled full scan.
public enum ActuationVerifier {
    public struct Verdict: Equatable, Sendable {
        public var ok: Bool
        public var expected: String
        public var observed: String
        public var error: ActuationError? { ok ? nil : .notVerified(expected: expected, observed: observed) }
    }

    static func onBar(_ r: ResolvedItem) -> Bool { r.item.isOnMenuBar && r.item.frame.width > 0 }

    /// On-bar items left to right (stable for equal x).
    public static func barOrder(_ resolved: [ResolvedItem]) -> [ResolvedItem] {
        let bar = resolved.enumerated().filter { onBar($0.element) }
        return bar.sorted { ($0.element.item.frame.minX, $0.offset) < ($1.element.item.frame.minX, $1.offset) }.map(\.element)
    }

    static func isModule(_ r: ResolvedItem) -> Bool { if case .module = r.key { return true } else { return false } }

    /// A heuristic key is a fingerprint, not a store key: it cannot support a verified claim unless a non-frame
    /// attribute (AXIdentifier) corroborates the item.
    static func uncorroborated(_ r: ResolvedItem) -> Bool { r.confidence == .heuristic && r.item.axIdentifier.isEmpty }

    static func name(_ r: ResolvedItem) -> String { r.key.description }

    static func position(of key: ItemKey, in order: [ResolvedItem]) -> String {
        guard let i = order.firstIndex(where: { $0.key == key }) else { return "not on the bar" }
        let l = i > 0 ? name(order[i - 1]) : "(bar start)"
        let r = i + 1 < order.count ? name(order[i + 1]) : "(bar end)"
        return "between \(l) and \(r)"
    }

    public static func moveVerdict(subject: ItemKey, relation: Relation, resolved: [ResolvedItem]) -> Verdict {
        let expected: String
        switch relation {
        case .before(let t): expected = "\(subject) immediately before \(t)"
        case .after(let t): expected = "\(subject) immediately after \(t)"
        case .leftmost: expected = "\(subject) first of the movable items"
        case .rightmost: expected = "\(subject) last of the movable items (left of the system modules)"
        }
        let order = barOrder(resolved)
        func fail(_ why: String) -> Verdict { Verdict(ok: false, expected: expected, observed: why) }
        guard let me = resolved.first(where: { $0.key == subject }) else { return fail("item absent from the final scan") }
        guard onBar(me) else { return fail("item is not on the bar") }
        if me.item.stale { return fail("item read is stale (cached frame)") }
        if uncorroborated(me) { return fail("item identity is heuristic without an AX identifier; cannot confirm") }
        var neighbor: ResolvedItem?
        let ok: Bool
        switch relation {
        case .before(let t), .after(let t):
            guard let n = resolved.first(where: { $0.key == t }), onBar(n) else { return fail("relation target \(t) is not on the bar") }
            if n.item.stale { return fail("relation target \(t) is stale") }
            if uncorroborated(n) { return fail("relation target \(t) has an uncorroborated heuristic identity") }
            neighbor = n
            guard let i = order.firstIndex(where: { $0.key == subject }), let j = order.firstIndex(where: { $0.key == t }) else {
                return fail("item not in bar order")
            }
            if case .before = relation { ok = j == i + 1 } else { ok = j == i - 1 }
        case .leftmost:
            ok = order.first(where: { !isModule($0) })?.key == subject
        case .rightmost:
            ok = order.last(where: { !isModule($0) })?.key == subject
        }
        _ = neighbor
        return Verdict(ok: ok, expected: expected, observed: ok ? expected : position(of: subject, in: order))
    }

    public static func visibilityVerdict(key: ItemKey, hidden: Bool, resolved: [ResolvedItem]) -> Verdict {
        let expected = "\(key) \(hidden ? "parked off the bar" : "on the bar")"
        func fail(_ why: String) -> Verdict { Verdict(ok: false, expected: expected, observed: why) }
        guard let me = resolved.first(where: { $0.key == key }) else { return fail("item absent from the final scan") }
        if me.item.stale { return fail("item read is stale (cached frame)") }
        if uncorroborated(me) { return fail("item identity is heuristic without an AX identifier; cannot confirm") }
        let on = onBar(me)
        return Verdict(ok: on != hidden, expected: expected, observed: on ? "on the bar" : "parked off the bar")
    }
}
