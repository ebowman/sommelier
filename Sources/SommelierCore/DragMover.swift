import AppKit
import CoreGraphics
import Foundation

public enum DragError: Error, Equatable, CustomStringConvertible {
    /// A mouse button is already down (the human is using the mouse); nothing was posted.
    case userBusy
    case eventCreationFailed
    public var description: String {
        switch self {
        case .userBusy: return "a mouse button is pressed (user is using the mouse); drag refused"
        case .eventCreationFailed: return "could not create CGEvent"
        }
    }
}

/// One step of a synthesized drag. `delayBefore` is the pause before posting this event.
public struct DragStep: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case move, down, dragged, up }
    public var kind: Kind
    public var point: CGPoint
    public var delayBefore: TimeInterval
}

/// Pure planning of the event sequence (unit-testable, no side effects).
public enum DragPlan {
    /// move-to-start, down, (hold), `steps` dragged events interpolated linearly to (targetX, y), up at target.
    /// The first dragged event waits `hold`; subsequent ones wait `stepDelay`; the up waits `stepDelay`.
    public static func make(from start: CGPoint, toX targetX: CGFloat, steps: Int,
                            stepDelay: TimeInterval, hold: TimeInterval) -> [DragStep] {
        let n = max(1, steps)
        var out: [DragStep] = [
            DragStep(kind: .move, point: start, delayBefore: 0),
            DragStep(kind: .down, point: start, delayBefore: 0.02),
        ]
        for i in 1...n {
            let x = start.x + (targetX - start.x) * CGFloat(i) / CGFloat(n)
            out.append(DragStep(kind: .dragged, point: CGPoint(x: x, y: start.y), delayBefore: i == 1 ? hold : stepDelay))
        }
        out.append(DragStep(kind: .up, point: CGPoint(x: targetX, y: start.y), delayBefore: stepDelay))
        return out
    }
}

/// Synthesizes Cmd+drag on the menu bar.
public struct DragMover {
    public var steps: Int
    public var stepDelay: TimeInterval
    public var holdTime: TimeInterval

    public init(steps: Int = 10, stepDelay: TimeInterval = 0.015, holdTime: TimeInterval = 0.1) {
        self.steps = steps; self.stepDelay = stepDelay; self.holdTime = holdTime
    }

    /// Drags the item's center to `targetX` (same y). Returns the time the mouse-up was posted.
    @discardableResult
    public func move(itemFrame: CGRect, toX targetX: CGFloat) throws -> Date {
        if NSEvent.pressedMouseButtons != 0 { throw DragError.userBusy }
        let start = CGPoint(x: itemFrame.midX, y: itemFrame.midY)
        let plan = DragPlan.make(from: start, toX: targetX, steps: steps, stepDelay: stepDelay, hold: holdTime)
        let saved = CGEvent(source: nil)?.location ?? .zero
        let src = CGEventSource(stateID: .hidSystemState)
        var upAt = Date()
        defer { CGWarpMouseCursorPosition(saved) }
        for s in plan {
            if s.delayBefore > 0 { Thread.sleep(forTimeInterval: s.delayBefore) }
            let type: CGEventType
            switch s.kind {
            case .move: type = .mouseMoved
            case .down: type = .leftMouseDown
            case .dragged: type = .leftMouseDragged
            case .up: type = .leftMouseUp
            }
            if s.kind == .move { CGWarpMouseCursorPosition(s.point) }
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: s.point, mouseButton: .left) else {
                throw DragError.eventCreationFailed
            }
            e.flags = .maskCommand
            e.post(tap: .cghidEventTap)
            if s.kind == .up { upAt = Date() }
        }
        Thread.sleep(forTimeInterval: 0.05)
        return upAt
    }

    /// Escape key press (to dismiss a menu a failed drag may have opened).
    public static func postEscape() {
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }
}

public enum ItemResolution {
    case match(MenuBarItem)
    case ambiguous([MenuBarItem])
    case none
}

/// Resolves a user-supplied key against scanned items. Pure.
/// Query forms: `<bundleID>` | `<bundleID>::<substring>` | `<substring>` (matches id/description/title/owner name,
/// case-insensitive). An exact identifier or "bundle::identifier" match wins over substring matches.
public enum ItemResolver {
    public static func protected(_ i: MenuBarItem) -> Bool {
        i.source == .agentHostedOnly || i.ownerBundleID == "com.apple.MenuBarAgent"
            || i.ownerBundleID == "com.apple.controlcenter" || i.axIdentifier.hasPrefix("com.apple.menuextra.")
    }

    public static func resolve(_ query: String, in items: [MenuBarItem]) -> ItemResolution {
        let pool = items.filter { $0.isOnMenuBar }
        func fields(_ i: MenuBarItem) -> [String] { [i.axIdentifier, i.axDescription, i.title, i.ownerName] }
        func bundleMatch(_ i: MenuBarItem, _ b: String) -> Bool { i.ownerBundleID?.lowercased() == b.lowercased() }
        let q = query.lowercased()
        // exact "bundle::sub" or bundle-only
        if let r = query.range(of: "::") {
            let b = String(query[..<r.lowerBound]), sub = String(query[r.upperBound...]).lowercased()
            let hits = pool.filter { bundleMatch($0, b) && (sub.isEmpty || fields($0).contains { $0.lowercased().contains(sub) }) }
            return classify(exactFirst(hits, sub))
        }
        let byBundle = pool.filter { bundleMatch($0, query) }
        if !byBundle.isEmpty { return classify(byBundle) }
        let exact = pool.filter { fields($0).contains { !$0.isEmpty && $0.lowercased() == q } }
        if !exact.isEmpty { return classify(exact) }
        return classify(pool.filter { fields($0).contains { $0.lowercased().contains(q) } })
    }

    private static func exactFirst(_ hits: [MenuBarItem], _ sub: String) -> [MenuBarItem] {
        guard !sub.isEmpty else { return hits }
        let ex = hits.filter { [$0.axIdentifier, $0.axDescription, $0.title].contains { $0.lowercased() == sub } }
        return ex.isEmpty ? hits : ex
    }

    private static func classify(_ hits: [MenuBarItem]) -> ItemResolution {
        hits.isEmpty ? .none : hits.count == 1 ? .match(hits[0]) : .ambiguous(hits)
    }

    /// Stable identity string for an item.
    public static func key(_ i: MenuBarItem) -> String {
        let label = !i.axIdentifier.isEmpty ? i.axIdentifier : !i.axDescription.isEmpty ? i.axDescription
            : String(i.title.map { $0.isNumber ? "#" : $0 })
        return "\(i.ownerBundleID ?? i.ownerName)|\(label)"
    }
}

/// Requested relation after a drag.
public enum DragRelation: Equatable, Sendable {
    case before(String), after(String), toX(CGFloat)
}

public enum DragTarget {
    /// Cursor overshoot past an item's midpoint needed to land on its far side (gdu.7: aiming exactly at the center
    /// or edge does nothing; the dragged item's center must cross the hovered item's midpoint).
    public static let overshoot: CGFloat = 6

    /// Drop x for a relation. Empirical rule (gdu.7): the dragged item lands on the far side of the last item whose
    /// midpoint its center crosses. Moving RIGHT the cursor goes to hover.midX + overshoot (lands AFTER hover);
    /// moving LEFT to hover.midX - overshoot (lands BEFORE hover). `before T` moving right therefore hovers T's
    /// left neighbor; `after T` moving left hovers T's right neighbor (`bar` = on-bar items left to right).
    /// Falls back to the target's edge -/+ 4 when the neighbor does not exist.
    public static func dropX(for relation: DragRelation, moved: MenuBarItem? = nil, target: MenuBarItem?,
                             bar: [MenuBarItem] = []) -> CGFloat? {
        switch relation {
        case .toX(let x): return x
        case .before, .after:
            guard let target else { return nil }
            let isBefore: Bool = { if case .before = relation { return true } else { return false } }()
            let edge = isBefore ? target.frame.minX - 4 : target.frame.maxX + 4
            guard let moved else { return edge }
            let movingRight = moved.frame.midX < target.frame.midX
            var hover = target
            if movingRight == isBefore {   // right+before: left neighbor; left+after: right neighbor
                let others = bar.filter { $0.frame != moved.frame }
                guard let ti = others.firstIndex(where: { $0.frame == target.frame }) else { return edge }
                let ni = isBefore ? ti - 1 : ti + 1
                guard others.indices.contains(ni) else { return edge }
                hover = others[ni]
            }
            return movingRight ? hover.frame.midX + overshoot : hover.frame.midX - overshoot
        }
    }

    /// Does the order (keys left to right) satisfy the relation (immediate adjacency)?
    public static func holds(_ relation: DragRelation, moved: String, order: [String], movedMidX: CGFloat? = nil,
                             tolerance: CGFloat = 15) -> Bool {
        guard let i = order.firstIndex(of: moved) else { return false }
        switch relation {
        case .before(let t): return order.firstIndex(of: t) == i + 1
        case .after(let t): return order.firstIndex(of: t) == i - 1
        case .toX(let x): return movedMidX.map { abs($0 - x) <= tolerance } ?? false
        }
    }
}
